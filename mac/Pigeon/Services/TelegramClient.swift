import Foundation
import os

/// Fetches Telegram channel content. Two transports, in priority order:
///
///   1. **Signed mirror snapshot** — walked across `MirrorEndpoints.production`
///      (raw.githubusercontent.com → Iran-domestic GitHub raw mirrors).
///      Refreshed every ~5 min by `mirror/scrape.ts` running in GitHub
///      Actions; each `snapshot.json` is published with a detached
///      Ed25519 signature, and every tier is independently verified by
///      `MirrorSignature` before its bytes are trusted. See
///      `fetchVerifiedSnapshot`.
///
///   2. **Pinned-IP HTTPS to `t-me.translate.goog`** — rotates 4 Google
///      anycast IPs × 4 GT translation variants. Bypasses DNS poisoning
///      by skipping the system resolver. Used for un-mirrored channels
///      (i.e. `VerifyError.notMirroredAnywhere`) only; we never fall back
///      to GT on a verification failure, since a tampering mirror would
///      otherwise trigger a downgrade.
///
/// Per the project brief, **direct** `t.me` requests are never attempted.
///
/// The fetching surface is also exposed as a `Sendable` protocol so tests
/// can substitute a controllable fake. Production stays the same — the
/// concrete actor conforms — but `ChannelService` accepts any conforming
/// implementation, which is what lets behavioral tests drive timing and
/// inject specific errors without making real network calls.
protocol TelegramFetching: Sendable {
    func fetchChannelPage(username: String) async throws -> TelegramClient.ChannelPage
    func fetchMirrorSnapshot(
        username: String,
        baseURL: URL,
        ifNoneMatch etag: String?,
        ifModifiedSince lastModified: String?
    ) async throws -> TelegramClient.MirrorFetchResult
    func fetchVerifiedSnapshot(username: String) async throws -> TelegramClient.VerifiedSnapshot
    func fetchMirrorHealth(baseURL: URL) async throws -> MirrorHealth
}

actor TelegramClient: TelegramFetching {
    enum FetchError: Error, LocalizedError {
        case noInternet
        case allMethodsFailed(underlying: [Error])
        case rateLimited
        case invalidResponse
        case channelNotFound

        var errorDescription: String? {
            switch self {
            case .noInternet: "No internet connection."
            case .allMethodsFailed: "All bypass methods failed."
            case .rateLimited: "Rate-limited. Try again in a minute."
            case .invalidResponse: "Telegram returned an unexpected response."
            case .channelNotFound: "That channel is private or doesn't exist on Telegram."
            }
        }
    }

    /// Errors raised by `fetchVerifiedSnapshot` after walking every mirror
    /// tier. Each carries enough context for the UI to explain *why* the
    /// channel can't be shown — "data integrity failed" is meaningfully
    /// different from "mirror unreachable" or "channel not mirrored yet".
    enum VerifyError: Error, LocalizedError {
        /// Every tier returned 404. The channel isn't in any mirror's
        /// manifest yet. Caller may fall through to the GT proxy.
        case notMirroredAnywhere
        /// At least one tier returned data but none verified. `failures`
        /// records the per-tier outcome; check the cases on each to tell
        /// "all signatures invalid" (active attack signal) from
        /// "everyone offline" (network blackout).
        case allTiersFailed(failures: [TierFailure])

        struct TierFailure: Sendable {
            let tierName: String
            let kind: Kind

            enum Kind: Sendable {
                case network        // transport failure, timeout, non-200/304/404 status
                case notFound       // 404 — channel not mirrored at this tier
                case missingSignature  // snapshot.json returned 200 but the .sig file 404'd — producer published partial state
                case signatureInvalid
                case snapshotStale(ageSeconds: Double)
                case malformed      // sig file wrong size, fetched_at unparseable
            }
        }

        var errorDescription: String? {
            switch self {
            case .notMirroredAnywhere:
                "This channel isn't in the mirror yet."
            case .allTiersFailed:
                "Mirror integrity check failed. Could not verify any source."
            }
        }
    }

    /// Result of a successful tier-walk: the verified payload, the base URL
    /// that served it (used by the decoder for resolving repo-relative
    /// asset paths), and the parsed `fetched_at` (already proven fresh).
    struct VerifiedSnapshot: Sendable {
        let data: Data
        let base: URL
        let fetchedAt: Date
    }

    struct ChannelPage: Sendable {
        let html: String
        let sourceURL: URL
        let method: ProxyMethod
    }

    /// Result of a conditional mirror fetch. `unchanged` means the server
    /// returned 304 Not Modified — the caller should keep persisted state
    /// untouched but bump its freshness clock. `fresh` carries the new body
    /// plus the validators to send back next time.
    enum MirrorFetchResult: Sendable {
        case fresh(Data, etag: String?, lastModified: String?)
        case unchanged
    }

    enum ProxyMethod: String, Sendable, CaseIterable {
        case googleAuto, googleFa, googleRu, googleAr

        var queryItems: [URLQueryItem] {
            let common = [
                URLQueryItem(name: "_x_tr_hl", value: "en"),
                URLQueryItem(name: "_x_tr_pto", value: "wapp")
            ]
            switch self {
            case .googleAuto:
                return [
                    URLQueryItem(name: "_x_tr_sl", value: "auto"),
                    URLQueryItem(name: "_x_tr_tl", value: "fa")
                ] + common
            case .googleFa:
                return [
                    URLQueryItem(name: "_x_tr_sl", value: "fa"),
                    URLQueryItem(name: "_x_tr_tl", value: "en")
                ] + common
            case .googleRu:
                return [
                    URLQueryItem(name: "_x_tr_sl", value: "ru"),
                    URLQueryItem(name: "_x_tr_tl", value: "en")
                ] + common
            case .googleAr:
                return [
                    URLQueryItem(name: "_x_tr_sl", value: "ar"),
                    URLQueryItem(name: "_x_tr_tl", value: "en")
                ] + common
            }
        }
    }

    private static let proxyHostname = "t-me.translate.goog"

    private let pinned = PinnedHTTPSClient()
    private let session: URLSession
    private let minRequestInterval: TimeInterval = 3
    private var lastRequestAt: Date = .distantPast

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Fetch a channel's t.me/s/<username> page through the pinned GT proxy.
    /// IP rotation is delegated to `PinnedHTTPSClient`; this method only
    /// rotates GT translation variants.
    func fetchChannelPage(username: String) async throws -> ChannelPage {
        let user = username.lowercased()
        var failures: [Error] = []

        for method in ProxyMethod.allCases {
            AppLog.net.pub("[GT] trying method=<\(method.rawValue)> for <\(user)>")
            do {
                try await rateLimit()
                let html = try await fetchPinned(username: user, method: method)
                AppLog.net.pub("[GT] method=<\(method.rawValue)> succeeded for <\(user)> htmlBytes=<\(html.utf8.count)>")
                guard let sourceURL = URL(string: "https://t.me/s/\(user)") else {
                    throw FetchError.invalidResponse
                }
                return ChannelPage(
                    html: html,
                    sourceURL: sourceURL,
                    method: method
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FetchError.channelNotFound {
                // 3xx from the proxy is a definitive "doesn't exist" — no point
                // trying other methods or IPs, they'll all say the same thing.
                AppLog.net.pub("[GT] method=<\(method.rawValue)> got 3xx for <\(user)> — channel not found")
                throw FetchError.channelNotFound
            } catch {
                AppLog.net.pub("[GT] method=<\(method.rawValue)> failed for <\(user)>: \(error.localizedDescription)")
                failures.append(error)
                continue
            }
        }
        let descriptions = failures.map { $0.localizedDescription }.joined(separator: " | ")
        AppLog.net.error("[GT] all methods failed for <\(user, privacy: .public)>: \(descriptions, privacy: .public)")
        throw FetchError.allMethodsFailed(underlying: failures)
    }

    /// Fetch a channel snapshot from Pigeon's GitHub-hosted mirror, using
    /// HTTP conditional-GET semantics. Pass the `ETag` and `Last-Modified`
    /// values from the previous successful response (if any); the server
    /// returns 304 when the snapshot hasn't changed, saving the body
    /// transfer entirely.
    ///
    /// `baseURL` is the mirror prefix (passed in by the caller — typically
    /// `SettingsStore.defaultMirrorBaseURL`). The snapshot path
    /// `channels/<u>/snapshot.json` is appended to it.
    ///
    /// Throws `.invalidResponse` on 404 (channel not yet mirrored) or any
    /// other non-200/304 status.
    func fetchMirrorSnapshot(
        username: String,
        baseURL: URL,
        ifNoneMatch etag: String? = nil,
        ifModifiedSince lastModified: String? = nil
    ) async throws -> MirrorFetchResult {
        let user = username.lowercased()
        let url = baseURL.appending(path: "channels/\(user)/snapshot.json")
        var req = URLRequest(url: url)
        req.setValue(UserAgents.random(), forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified, !lastModified.isEmpty {
            req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        // Avoid stale cached snapshots when a refresh is requested. URLCache
        // would otherwise short-circuit our conditional headers.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            let newETag = http.value(forHTTPHeaderField: "ETag")
            let newLastModified = http.value(forHTTPHeaderField: "Last-Modified")
            return .fresh(data, etag: newETag, lastModified: newLastModified)
        case 304:
            return .unchanged
        default:
            throw FetchError.invalidResponse
        }
    }

    /// Fetch a channel snapshot, verifying its Ed25519 signature against the
    /// hardcoded public key and rejecting stale data. Walks `MirrorEndpoints
    /// .production` in order, returning the first tier that both verifies
    /// and parses a `fetched_at` within `MirrorSignature.maxFreshnessAge`.
    ///
    /// **Tier semantics:** every tier is independently trust-checked. If a
    /// tier returns tampered bytes, we move to the next one — one hostile
    /// mirror doesn't poison the chain. Only if EVERY tier fails does this
    /// throw `VerifyError.allTiersFailed`.
    ///
    /// **Conditional GETs are NOT used here.** The cost is one full snapshot
    /// download per refresh per channel (~50–200 KB). Re-adding ETag support
    /// across multiple tiers (each with their own validators) is complexity
    /// we don't need until bandwidth becomes a real problem.
    func fetchVerifiedSnapshot(username: String) async throws -> VerifiedSnapshot {
        let user = username.lowercased()
        var failures: [VerifyError.TierFailure] = []

        for tier in MirrorEndpoints.production {
            let urls = tier.urls(user)
            AppLog.mirror.pub("[verify] trying tier=<\(tier.name)> for <\(user)>")

            let outcome = await fetchAndVerifyTier(urls: urls, tierName: tier.name)
            switch outcome {
            case .ok(let snap):
                AppLog.mirror.pub("[verify] tier=<\(tier.name)> OK for <\(user)> bytes=<\(snap.data.count)>")
                return snap
            case .notFound:
                AppLog.mirror.pub("[verify] tier=<\(tier.name)> 404 for <\(user)>")
                failures.append(VerifyError.TierFailure(tierName: tier.name, kind: .notFound))
            case .failure(let kind):
                AppLog.mirror.error("[verify] tier=<\(tier.name, privacy: .public)> failed for <\(user, privacy: .public)>: \(String(describing: kind), privacy: .public)")
                failures.append(VerifyError.TierFailure(tierName: tier.name, kind: kind))
            }
        }

        throw Self.classifyTierFailures(failures)
    }

    /// Decide which `VerifyError` to surface after every tier has been tried
    /// and none returned a verified snapshot. If every tier 404'd, the channel
    /// simply isn't in any mirror (caller may fall through to GT). Otherwise
    /// at least one tier returned data we couldn't verify — escalate as a
    /// hard error so we don't silently downgrade to the GT proxy on what
    /// might be an active tampering attempt.
    private static func classifyTierFailures(_ failures: [VerifyError.TierFailure]) -> VerifyError {
        let allNotFound = failures.allSatisfy { failure in
            if case .notFound = failure.kind { return true }
            return false
        }
        return allNotFound ? .notMirroredAnywhere : .allTiersFailed(failures: failures)
    }

    /// Per-tier attempt. Returns a tagged enum because we want to
    /// distinguish "channel not in this tier" (404, may try next tier or
    /// fall to GT) from "tier returned bad data" (escalates to all-tiers
    /// hard-fail if it happens on every tier).
    private enum TierOutcome {
        case ok(VerifiedSnapshot)
        case notFound
        case failure(VerifyError.TierFailure.Kind)
    }

    private func fetchAndVerifyTier(
        urls: MirrorEndpoints.ChannelURLs,
        tierName: String
    ) async -> TierOutcome {
        async let jsonResult = fetchBytes(url: urls.snapshot, timeout: MirrorEndpoints.perTierTimeout)
        async let sigResult = fetchBytes(url: urls.signature, timeout: MirrorEndpoints.perTierTimeout)

        // Resolve independently so we can distinguish "channel not mirrored
        // at this tier" (snapshot.json is 404) from "producer published the
        // snapshot but not its signature" (snapshot 200 / sig 404 — a
        // producer-side regression, not a missing channel).
        let jsonOutcome: Result<Data, Error>
        let sigOutcome: Result<Data, Error>
        do { jsonOutcome = .success(try await jsonResult) } catch { jsonOutcome = .failure(error) }
        do { sigOutcome = .success(try await sigResult) } catch { sigOutcome = .failure(error) }

        let json: Data
        switch jsonOutcome {
        case .success(let data): json = data
        case .failure(FetchError.channelNotFound): return .notFound
        case .failure: return .failure(.network)
        }

        let sig: Data
        switch sigOutcome {
        case .success(let data): sig = data
        case .failure(FetchError.channelNotFound): return .failure(.missingSignature)
        case .failure: return .failure(.network)
        }

        guard sig.count == 64 else {
            return .failure(.malformed)
        }
        guard MirrorSignature.verify(payload: json, signature: sig) else {
            return .failure(.signatureInvalid)
        }

        // Parse just `fetched_at` to check freshness — full decode happens
        // upstream once we've committed to this tier. Doing it here means a
        // stale-but-signed snapshot advances to the next tier instead of
        // bubbling all the way to the UI as a soft "stale" error.
        guard let fetchedAt = Self.parseFetchedAt(json) else {
            // Signature verified but we can't parse fetched_at — the
            // producer published a structurally-broken-but-signed snapshot.
            // Loud log because it means the mirror pipeline has a regression
            // (json shape change without a coordinated app update).
            AppLog.mirror.error("[verify] tier=<\(tierName, privacy: .public)> snapshot has unparseable fetched_at after sig-verify — producer pipeline bug")
            return .failure(.malformed)
        }
        guard MirrorSignature.isFresh(fetchedAt: fetchedAt) else {
            let age = Date.now.timeIntervalSince(fetchedAt)
            return .failure(.snapshotStale(ageSeconds: age))
        }

        return .ok(VerifiedSnapshot(data: json, base: urls.base, fetchedAt: fetchedAt))
    }

    /// GET `url` with a tight timeout. Maps 404 to a sentinel error so the
    /// tier orchestrator can distinguish "not mirrored here" from "couldn't
    /// reach this mirror." Any other non-200 is a generic transport failure.
    private func fetchBytes(url: URL, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(UserAgents.random(), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw FetchError.channelNotFound
        default:
            throw FetchError.invalidResponse
        }
    }

    /// Extract just `fetched_at` from a snapshot's bytes. We've already
    /// verified the signature, so JSON parse failure here is "malformed but
    /// validly signed" — almost certainly a producer bug, not an attack.
    /// Allocates a formatter per call to dodge `ISO8601DateFormatter`'s
    /// undocumented thread-safety story; this runs once per channel per
    /// refresh, so the alloc is negligible.
    private static func parseFetchedAt(_ data: Data) -> Date? {
        struct OnlyFetchedAt: Decodable { let fetched_at: String? }
        guard let dto = try? JSONDecoder().decode(OnlyFetchedAt.self, from: data),
              let raw = dto.fetched_at
        else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    /// Fetch the mirror's `health.json` — a tiny document the scraper
    /// writes at the end of every sweep. Reports how many channels
    /// succeeded/failed and when the sweep finished. Used by the sidebar
    /// to surface "mirror updated N min ago" backed by the actual sweep
    /// time rather than the user's local last-fetch heuristic.
    ///
    /// No conditional GET (the file is ~hundreds of bytes), no proxy
    /// (raw.githubusercontent.com is reachable). Throws `.invalidResponse`
    /// for any non-200 — including 404 in the brief window before the
    /// first sweep ever lands the file.
    func fetchMirrorHealth(baseURL: URL) async throws -> MirrorHealth {
        let url = baseURL.appending(path: "health.json")
        var req = URLRequest(url: url)
        req.setValue(UserAgents.random(), forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        return try MirrorHealthDecoder().decode(data)
    }

    // MARK: - Private

    private func rateLimit() async throws {
        let now = Date.now
        let nextAllowed = lastRequestAt.addingTimeInterval(minRequestInterval)
        if nextAllowed > now {
            lastRequestAt = nextAllowed
            try await Task.sleep(for: .seconds(nextAllowed.timeIntervalSince(now)))
        } else {
            lastRequestAt = now
        }
    }

    private func fetchPinned(username: String, method: ProxyMethod) async throws -> String {
        let response = try await pinned.getWithIPRotation(
            sni: Self.proxyHostname,
            path: "/s/\(username)",
            queryItems: method.queryItems,
            headers: [
                "User-Agent": UserAgents.random(),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9,fa;q=0.8",
                "Referer": "https://translate.google.com/",
                "Origin": "https://translate.google.com",
                "Pragma": "no-cache",
                "Cache-Control": "no-cache",
                "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Site": "none",
                "Upgrade-Insecure-Requests": "1"
            ]
        )

        switch response.status {
        case 200..<300:
            guard let html = String(data: response.body, encoding: .utf8) else {
                throw FetchError.invalidResponse
            }
            if html.contains("Sorry, this channel doesn") {
                throw FetchError.channelNotFound
            }
            return html
        case 301, 302, 303, 307, 308:
            throw FetchError.channelNotFound
        case 429:
            throw FetchError.rateLimited
        default:
            throw PinnedHTTPSClient.ClientError.statusCode(response.status)
        }
    }
}

