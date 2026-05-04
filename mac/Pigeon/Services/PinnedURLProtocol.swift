import Foundation

/// Intercepts any URLSession request to a `*.translate.goog` host and
/// dispatches it through `PinnedHTTPSClient` instead — guaranteeing that
/// the actual TCP connection lands on a pinned Google anycast IP and
/// bypasses system DNS entirely.
///
/// Registered via `URLSessionConfiguration.protocolClasses` on the session
/// we hand to Nuke. We don't register globally — that'd intercept every
/// URLSession in the process, including the one Foundation uses internally.
final class PinnedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let pinned = PinnedHTTPSClient()
    private var pinnedTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host.hasSuffix(".translate.goog")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let path = components.path.isEmpty ? "/" : components.path
        let queryItems = components.queryItems ?? []
        var headers: [String: String] = request.allHTTPHeaderFields ?? [:]
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = UserAgents.random()
        }
        if headers["Referer"] == nil {
            headers["Referer"] = "https://translate.google.com/"
        }
        if headers["Accept"] == nil {
            headers["Accept"] = "image/avif,image/webp,image/png,image/jpeg,*/*;q=0.8"
        }

        let proto = self
        let urlCopy = url
        pinnedTask = Task { @Sendable [headers] in
            do {
                let response = try await Self.pinned.getWithIPRotation(
                    sni: host,
                    path: path,
                    queryItems: queryItems,
                    headers: headers,
                    timeout: 30
                )
                if Task.isCancelled { return }

                let httpResponse = HTTPURLResponse(
                    url: urlCopy,
                    statusCode: response.status,
                    httpVersion: "HTTP/1.0",
                    headerFields: response.headers
                )!
                proto.client?.urlProtocol(proto, didReceive: httpResponse, cacheStoragePolicy: .allowed)
                proto.client?.urlProtocol(proto, didLoad: response.body)
                proto.client?.urlProtocolDidFinishLoading(proto)
            } catch {
                if Task.isCancelled { return }
                proto.client?.urlProtocol(proto, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        pinnedTask?.cancel()
        pinnedTask = nil
    }
}
