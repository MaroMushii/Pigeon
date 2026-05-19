import CryptoKit
import Foundation
import Nuke
import os

/// Wraps Nuke's `DataLoading` to enforce SHA-256 integrity on image bytes
/// against hashes registered in `ImageHashRegistry`.
///
/// **What's protected:** any image whose URL was published in a
/// signature-verified snapshot. The decoder registers the hash → URL pair
/// at decode time; this loader checks the downloaded bytes match before
/// declaring the request successful. A mismatch escalates to a Nuke error
/// and the UI shows a broken-image state.
///
/// **What's NOT protected:** images whose URLs aren't in the registry —
/// avatars from GT-proxied (un-mirrored) channels, ancient cached entries
/// from before this loader was installed, etc. These pass through
/// unverified by design (see `ImageHashRegistry`'s doc for the rationale).
///
/// **Progressive rendering:** chunks pass through `didReceiveData` as they
/// arrive so partial decode still works. Verification happens at the end
/// of the byte stream. A mid-stream mismatch surfaces as a completion
/// error, which is good enough — the partial-rendered tile gets swapped
/// for the broken-image placeholder.
///
/// SAFETY: `@unchecked Sendable`. The only mutable state is a per-request
/// `SHA256` hasher held inside an `OSAllocatedUnfairLock`. Hasher state is
/// never shared across requests. `inner` (the wrapped loader) is itself
/// Sendable per Nuke's `DataLoading` contract. The class itself holds no
/// mutable state.
final class VerifyingDataLoader: DataLoading, @unchecked Sendable {

    enum ImageVerifyError: Error, LocalizedError {
        case hashMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .hashMismatch:
                "Image bytes do not match the signed snapshot's hash."
            }
        }
    }

    private let inner: any DataLoading

    init(wrapping inner: any DataLoading) {
        self.inner = inner
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let url = request.url
        let expected = url.flatMap { ImageHashRegistry.shared.expectedHash(for: $0) }

        // Fast path: no registered hash → pass through. Avoids hasher
        // allocation and lock contention for the vast majority of cache-warm
        // images that load straight from Nuke's disk cache.
        guard let expected else {
            return inner.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }

        // Incremental SHA-256 — feed each chunk as it arrives, finalize at
        // completion. Avoids buffering the full image payload (large videos
        // and high-res photos can be MBs). Hasher state lives in an
        // `OSAllocatedUnfairLock`; the only contention is between Nuke's
        // data callback and our completion closure, both invoked on Nuke's
        // loader queue.
        let hasher = OSAllocatedUnfairLock(initialState: SHA256())

        return inner.loadData(
            with: request,
            didReceiveData: { [hasher] chunk, response in
                hasher.withLock { $0.update(data: chunk) }
                didReceiveData(chunk, response)
            },
            completion: { [expected, url, hasher] error in
                if let error {
                    completion(error)
                    return
                }
                let digest = hasher.withLock { $0.finalize() }
                let actual = digest.map { String(format: "%02x", $0) }.joined()
                if actual == expected {
                    completion(nil)
                } else {
                    AppLog.mirror.error(
                        "[verify] image hash mismatch for <\(url?.absoluteString ?? "?", privacy: .public)> expected=<\(expected, privacy: .public)> actual=<\(actual, privacy: .public)>"
                    )
                    completion(ImageVerifyError.hashMismatch(expected: expected, actual: actual))
                }
            }
        )
    }
}
