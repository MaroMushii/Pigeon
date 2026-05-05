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

    static var allPending: [EndpointResult] {
        [
            EndpointResult(id: "mirror", name: "GitHub Mirror", detail: "raw.githubusercontent.com"),
            EndpointResult(id: "proxy", name: "GT Proxy (pinned)", detail: "t-me.translate.goog via NWConnection"),
        ]
    }
}

/// Isolated health checker that owns its own PinnedHTTPSClient and URLSession so
/// health check traffic never touches TelegramClient's rate limiter or lastGoodIP state.
actor HealthChecker {
    private let pinned = PinnedHTTPSClient()
    private let session: URLSession

    private static let mirrorURL = "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/index.json"
    private static let proxyHostname = "t-me.translate.goog"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    func checkAll() async -> [EndpointResult] {
        async let mirror = checkMirror()
        async let proxy = checkProxy()
        return await [mirror, proxy]
    }

    private func checkMirror() async -> EndpointResult {
        var result = EndpointResult(id: "mirror", name: "GitHub Mirror", detail: "raw.githubusercontent.com")
        guard let url = URL(string: Self.mirrorURL) else {
            result.status = .failed("Invalid URL")
            return result
        }
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

    private func checkProxy() async -> EndpointResult {
        var result = EndpointResult(id: "proxy", name: "GT Proxy (pinned)", detail: "t-me.translate.goog via NWConnection")
        let start = Date.now
        do {
            _ = try await pinned.getWithIPRotation(
                sni: Self.proxyHostname,
                path: "/",
                headers: ["User-Agent": UserAgents.random()]
            )
            let latency = Int(Date.now.timeIntervalSince(start) * 1000)
            result.status = .ok(latencyMs: latency)
        } catch {
            result.status = .failed(error.localizedDescription)
        }
        return result
    }
}
