import Foundation

/// Per-channel conditional-GET state for the mirror transport. The mirror
/// returns ETag and Last-Modified on every 200; we send them back as
/// `If-None-Match` / `If-Modified-Since` on the next request so a 304
/// short-circuits the upsert path entirely. Stored in `UserDefaults`
/// because the validators are tiny strings and survive across launches —
/// SwiftData would be overkill for two keys per channel.
///
/// Lives as a value type with an injected `UserDefaults` so tests can
/// hand it an ephemeral suite. The keys are namespaced (`mirror.etag.<u>`,
/// `mirror.lastModified.<u>`) and lowercased to dedupe casing variants
/// of the same channel.
struct MirrorValidatorStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func validators(for username: String) -> (etag: String?, lastModified: String?) {
        (
            defaults.string(forKey: Self.etagKey(username)),
            defaults.string(forKey: Self.lastModifiedKey(username))
        )
    }

    /// Replace stored validators with the values from the most recent
    /// 200 response. Empty / nil values clear the key entirely so the
    /// next request is unconditional.
    func persist(username: String, etag: String?, lastModified: String?) {
        let eKey = Self.etagKey(username)
        let lKey = Self.lastModifiedKey(username)
        if let etag, !etag.isEmpty {
            defaults.set(etag, forKey: eKey)
        } else {
            defaults.removeObject(forKey: eKey)
        }
        if let lastModified, !lastModified.isEmpty {
            defaults.set(lastModified, forKey: lKey)
        } else {
            defaults.removeObject(forKey: lKey)
        }
    }

    /// Wipe both validators for `username`. Called when the channel is
    /// removed or re-added so a future fetch can't 304 against stale
    /// validators for data we no longer hold locally.
    func clear(username: String) {
        defaults.removeObject(forKey: Self.etagKey(username))
        defaults.removeObject(forKey: Self.lastModifiedKey(username))
    }

    private static func etagKey(_ username: String) -> String {
        "mirror.etag.\(username.lowercased())"
    }

    private static func lastModifiedKey(_ username: String) -> String {
        "mirror.lastModified.\(username.lowercased())"
    }
}
