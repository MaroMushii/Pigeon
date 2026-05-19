import Foundation
import os

/// Process-local map from fully-resolved image URL to the SHA-256 hex its
/// bytes must match before Nuke will hand them to the UI.
///
/// Populated by `JSONFeedDecoder` whenever a signature-verified snapshot is
/// decoded. Consulted by `VerifyingDataLoader` on every Nuke fetch. URLs
/// without a registered hash are loaded normally — this is intentional:
///
///   - Cached images (already on Nuke's disk) load from disk on app restart
///     before any snapshot refresh re-populates the registry. They were
///     verified once when first fetched; the local cache is trusted.
///   - Un-mirrored channels reached via the GT proxy have no signed hash to
///     register, and fail-closed there would block legitimate fallbacks.
///
/// The threat model is mirror-served byte tampering. Once a hash IS
/// registered (i.e. the snapshot was signed), every fetch for that URL
/// MUST match or the image fails to load. Mismatch → `.hashMismatch` error
/// surfaced to Nuke → broken-image state in the UI.
///
/// Thread-safe via `OSAllocatedUnfairLock`; this is hotter than an actor
/// hop on the image-fetch path and the critical section is a hash-map read.
final class ImageHashRegistry: @unchecked Sendable {

    static let shared = ImageHashRegistry()

    /// Soft cap. Each entry is ~100 bytes; 10k is ~1 MB. Long-running
    /// sessions with many channels can drift well past the working set,
    /// so we drop the oldest quarter when we hit the ceiling. Eviction
    /// order is insertion order — older registrations are likelier to be
    /// for posts that have scrolled out of view.
    private static let maxEntries = 10_000
    private static let evictionBatch = maxEntries / 4

    private struct State {
        var map: [URL: String] = [:]
        var insertionOrder: [URL] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register an expected SHA-256 (lowercase hex) for the bytes served at
    /// `url`. Overwrites any previous registration — later snapshots may
    /// legitimately change image content (rare, but Telegram does sometimes
    /// re-upload an avatar at the same URL).
    func register(url: URL, sha256Hex: String) {
        lock.withLock { state in
            if state.map[url] == nil {
                state.insertionOrder.append(url)
            }
            state.map[url] = sha256Hex.lowercased()
            if state.map.count > Self.maxEntries {
                let drop = state.insertionOrder.prefix(Self.evictionBatch)
                for u in drop { state.map.removeValue(forKey: u) }
                state.insertionOrder.removeFirst(min(Self.evictionBatch, state.insertionOrder.count))
            }
        }
    }

    /// Lookup the expected hash for `url`, or `nil` if none registered.
    func expectedHash(for url: URL) -> String? {
        lock.withLock { $0.map[url] }
    }

    /// Test-only reset.
    func _reset() {
        lock.withLock { state in
            state.map.removeAll()
            state.insertionOrder.removeAll()
        }
    }
}
