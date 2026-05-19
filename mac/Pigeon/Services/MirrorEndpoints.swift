import Foundation

/// Ordered list of mirror tiers Pigeon tries when fetching a channel snapshot.
///
/// Each entry is a base URL; the snapshot path `channels/<u>/snapshot.json`
/// (and its sibling `.sig` file) is appended to it. The first tier that
/// returns a payload whose Ed25519 signature verifies wins — every tier is
/// independently trust-checked, so the order is just a freshness / latency
/// preference, not a trust gradient.
///
/// **Why multiple tiers:** when this was written in 2026-05, raw.gh was
/// blocked in Iran, jsDelivr and Statically were blocked, and the GT proxy
/// to `t-me.translate.goog` was blocked. The only data plane reaching users
/// was Iran-domestic GitHub mirrors operated by unknown third parties.
/// Signature verification is what makes those safe to depend on.
///
/// Each request gets a short timeout (~2 s) so a stalled tier doesn't block
/// the whole chain. Tier-walking happens inside `TelegramClient`.
enum MirrorEndpoints {

    /// Snapshot/sig URLs for a single channel under one base.
    struct ChannelURLs: Sendable {
        let snapshot: URL
        let signature: URL
        /// Base used for resolving repo-relative media paths in the decoded
        /// snapshot. Stored so the decoder can build asset URLs against the
        /// same host that served the snapshot (otherwise we'd fetch JSON
        /// from scorpian.ir but try to load images from raw.gh).
        let base: URL
    }

    /// Per-request timeout per tier. Tuned to fail fast on blocked hosts —
    /// raw.gh in Iran 504s or hangs rather than 4xx-ing, so we don't want
    /// to wait the URLSession default 60 s before moving to the next tier.
    static let perTierTimeout: TimeInterval = 4

    /// Base URLs in priority order. Tier-walking is sequential — if you want
    /// to add a new domestic mirror, append it here.
    ///
    /// Entries are functions so future tiers with non-standard URL shapes
    /// (e.g. `/blob/` vs `/raw/`) can slot in without changing the call site.
    static let production: [(name: String, urls: @Sendable (String) -> ChannelURLs)] = [
        (
            "raw.githubusercontent.com",
            githubRawProvider(base: "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export")
        ),
        (
            "scorpian.ir",
            githubRawProvider(base: "https://scorpian.ir/raw/MaroMushii/Pigeon/export")
        )
        // Add more Iran-domestic mirrors here as they're discovered + tested.
    ]

    /// URL builder for any host that serves the GitHub raw layout
    /// (`<base>/channels/<u>/snapshot.json`). Captures `base` so each tier
    /// gets its own closure pointing at its own root.
    private static func githubRawProvider(base: String) -> @Sendable (String) -> ChannelURLs {
        guard let baseURL = URL(string: base) else {
            fatalError("MirrorEndpoints: invalid base URL constant <\(base)>")
        }
        return { username in
            let user = username.lowercased()
            return ChannelURLs(
                snapshot: baseURL.appending(path: "channels/\(user)/snapshot.json"),
                signature: baseURL.appending(path: "channels/\(user)/snapshot.json.sig"),
                base: baseURL
            )
        }
    }
}
