import Foundation

enum ChannelIdentifier {
    nonisolated(unsafe) private static let usernameRegex = /[a-z][a-z0-9_]{3,30}[a-z0-9]/

    /// Normalises any of these forms to a lowercase username:
    ///   - "ircfspace"
    ///   - "@ircfspace"
    ///   - "t.me/ircfspace"
    ///   - "https://t.me/ircfspace"
    ///   - "https://t.me/s/ircfspace"
    /// Returns nil if input is empty or clearly invalid.
    static func normalise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var working = trimmed
        for prefix in ["https://", "http://"] where working.hasPrefix(prefix) {
            working = String(working.dropFirst(prefix.count))
        }
        if working.hasPrefix("t.me/s/") {
            working = String(working.dropFirst("t.me/s/".count))
        } else if working.hasPrefix("t.me/") {
            working = String(working.dropFirst("t.me/".count))
        }
        if working.hasPrefix("@") {
            working = String(working.dropFirst())
        }

        // Strip any trailing path/query.
        if let slash = working.firstIndex(of: "/") {
            working = String(working[..<slash])
        }
        if let q = working.firstIndex(of: "?") {
            working = String(working[..<q])
        }

        guard working.wholeMatch(of: Self.usernameRegex) != nil else {
            return nil
        }
        return working
    }
}
