import Foundation
import os

/// Fetches Telegram channel content. Two transports, in priority order:
///
///   1. **Pigeon mirror snapshot** — `raw.githubusercontent.com/MaroMushii/
///      Pigeon/export/<channel>.json`. Updated every ~2 min by our
///      Cloudflare Worker scraping `t.me` from outside Iran. Iran rarely
///      blocks GitHub raw. Fast, fresh, hard to censor, decodes straight
///      into our domain types.
///
///   2. **Pinned-IP HTTPS to `t-me.translate.goog`** — rotates 4 Google
///      anycast IPs × 4 GT translation variants. Bypasses DNS poisoning
///      by skipping the system resolver. Used for un-mirrored channels
///      and as a freshness fallback if GitHub is unreachable.
///
/// Per the project brief, **direct** `t.me` requests are never attempted.
actor TelegramClient {
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
                return ChannelPage(
                    html: html,
                    sourceURL: URL(string: "https://t.me/s/\(user)")!,
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

