import Foundation

struct EndpointResult: Identifiable, Sendable {
    enum Status: Sendable {
        case pending
        case ok(latencyMs: Int)
        case failed(String)
    }

    let id: String
    let name: String
    let detail: String
    var status: Status = .pending

    static func mirror(baseURL: URL) -> EndpointResult {
        EndpointResult(
            id: "mirror",
            name: "Mirror",
            detail: baseURL.host() ?? baseURL.absoluteString
        )
    }

    static func proxy(ip: String) -> EndpointResult {
        EndpointResult(
            id: "proxy:\(ip)",
            name: "GT \(ip)",
            detail: "t-me.translate.goog SNI"
        )
    }

    static func allPending(mirrorBaseURL: URL) -> [EndpointResult] {
        [.mirror(baseURL: mirrorBaseURL)] + PinnedHTTPSClient.translateGoogIPs.map(EndpointResult.proxy(ip:))
    }
}

/// Isolated health checker that owns its own PinnedHTTPSClient and URLSession so
/// health check traffic never touches TelegramClient's rate limiter or lastGoodIP state.
actor HealthChecker {
    private let pinned = PinnedHTTPSClient()
    private let session: URLSession

    private static let proxyHostname = "t-me.translate.goog"

    /// Hard ceiling for any single probe. Caps the user-visible spinner even
    /// when underlying I/O ignores cancellation (e.g. NWConnection's read
    /// callback never firing on a server that holds the socket open silently).
    private static let probeDeadline: TimeInterval = 12

    /// Per-IP timeout passed into `pinned.get` for one diagnostic probe.
    /// We probe each IP individually (no rotation) so each row reports its
    /// own latency or failure, and the worst-case wall time stays bounded
    /// by `probeDeadline`. Shorter than TelegramClient's 30s default so a
    /// silently-stalled IP fails fast instead of hogging the spinner.
    private static let proxyPerIPTimeout: TimeInterval = 6

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config)
    }

    /// `baseURL` is the same prefix the app uses for snapshot fetches —
    /// resolved by the caller from `SettingsStore`. We probe `<base>/index.json`
    /// because every well-formed mirror exports it; a 200 there confirms the
    /// user's configured base is actually serving snapshots.
    func checkMirror(baseURL: URL) async -> EndpointResult {
        await withDeadline(template: .mirror(baseURL: baseURL)) {
            await self.runMirror(baseURL: baseURL)
        }
    }

    /// Probes a single pinned Google anycast IP. Bypasses `getWithIPRotation`
    /// so each IP gets its own row in the diagnostic — first-success rotation
    /// would mask which IPs are actually filtered.
    func checkProxy(ip: String) async -> EndpointResult {
        await withDeadline(template: .proxy(ip: ip)) { await self.runProxy(ip: ip) }
    }

    /// Defense-in-depth backstop on top of the per-phase timeouts inside
    /// `PinnedHTTPSClient` (connect + receive each honor their own deadline).
    /// Race the probe against a timer; whichever finishes first wins, the
    /// other is cancelled. In practice the probe always completes within
    /// `~2 × proxyPerIPTimeout` (one budget per phase), so this timer
    /// should rarely fire — it exists to cap the user-visible spinner if
    /// a future change to the pinned client regresses the inner timeout
    /// guarantees.
    private func withDeadline(
        template: EndpointResult,
        _ probe: @Sendable @escaping () async -> EndpointResult
    ) async -> EndpointResult {
        let deadline = Self.probeDeadline
        return await withTaskGroup(of: EndpointResult.self) { group in
            group.addTask { await probe() }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                var timedOut = template
                timedOut.status = .failed("Timed out after \(Int(deadline))s")
                return timedOut
            }
            let first = await group.next() ?? template
            group.cancelAll()
            return first
        }
    }

    private func runMirror(baseURL: URL) async -> EndpointResult {
        var result = EndpointResult.mirror(baseURL: baseURL)
        let url = baseURL.appending(path: "index.json")
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date.now
        do {
            let (_, response) = try await session.data(for: req)
            let latency = Int(Date.now.timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                result.status = .failed("No HTTP response")
                return result
            }
            if (200..<300).contains(http.statusCode) {
                result.status = .ok(latencyMs: latency)
            } else {
                result.status = .failed("HTTP \(http.statusCode)")
            }
        } catch {
            result.status = .failed(error.localizedDescription)
        }
        return result
    }

    private func runProxy(ip: String) async -> EndpointResult {
        var result = EndpointResult.proxy(ip: ip)
        let start = Date.now
        do {
            _ = try await pinned.get(
                ip: ip,
                sni: Self.proxyHostname,
                path: "/",
                headers: ["User-Agent": UserAgents.random()],
                timeout: Self.proxyPerIPTimeout
            )
            let latency = Int(Date.now.timeIntervalSince(start) * 1000)
            result.status = .ok(latencyMs: latency)
        } catch {
            result.status = .failed(error.localizedDescription)
        }
        return result
    }
}
