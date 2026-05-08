import Foundation

/// Rewrites Telegram CDN URLs to route through Google Translate's
/// host-rewrite proxy (`<dashed-host>.translate.goog`). Used for media —
/// images, video posters — so they bypass DNS-poisoned/blocked CDN
/// hostnames the same way the channel HTML does.
///
/// `https://cdn4.telesco.pe/file/abc.jpg`
///   →  `https://cdn4-telesco-pe.translate.goog/file/abc.jpg?_x_tr_sl=auto&_x_tr_tl=fa`
enum TelegramURLRewriter {
    /// Hostnames whose responses are rewritten. Anything else is passed
    /// through untouched (e.g., `t.me`, `raw.githubusercontent.com`).
    private static let proxiedHosts: Set<String> = [
        "telesco.pe",
        "cdn-telegram.org",
        "telegram.org"
    ]

    static func rewrite(_ url: URL?) -> URL? {
        guard var url else { return nil }

        // Protocol-relative URLs (e.g. `//telegram.org/img/...`) come back
        // from CSS `url()` parsing without a scheme. Promote to https.
        if url.scheme == nil {
            url = URL(string: "https:\(url.absoluteString)") ?? url
        }

        guard let host = url.host?.lowercased(), shouldProxy(host: host) else {
            return url
        }

        let dashedHost = host.replacingOccurrences(of: ".", with: "-")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = "\(dashedHost).translate.goog"
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "_x_tr_sl", value: "auto"))
        query.append(URLQueryItem(name: "_x_tr_tl", value: "fa"))
        components.queryItems = query
        return components.url ?? url
    }

    private static func shouldProxy(host: String) -> Bool {
        proxiedHosts.contains(host) || proxiedHosts.contains { host.hasSuffix(".\($0)") }
    }

    static func isProxiedHost(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".translate.goog")
    }
}

