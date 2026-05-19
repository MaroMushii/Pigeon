import XCTest
@testable import Pigeon

/// Tests for `ImageHashRegistry` — the per-URL expected-hash map consulted
/// by `VerifyingDataLoader`. The interesting cases are eviction order
/// (insertion order, not LRU) and case normalization (registry lowercases
/// on write, the loader compares lowercased hex; mismatch on either side
/// would silently bypass verification).
///
/// Each test resets the singleton in tearDown so cross-test contamination
/// can't leak. A leaked registration would make a later test "pass"
/// spuriously by recognizing a URL it should have known nothing about.
final class ImageHashRegistryTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        ImageHashRegistry.shared._reset()
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - register / lookup

    func test_register_then_lookup_returnsExpectedHash() {
        let u = url("https://test.invalid/a.jpg")
        ImageHashRegistry.shared.register(url: u, sha256Hex: "abcd")
        XCTAssertEqual(ImageHashRegistry.shared.expectedHash(for: u), "abcd")
    }

    func test_expectedHash_returnsNilForUnregisteredURL() {
        XCTAssertNil(ImageHashRegistry.shared.expectedHash(for: url("https://test.invalid/missing.jpg")))
    }

    func test_register_lowercasesHex() {
        // VerifyingDataLoader compares against the registry value byte-for-byte
        // after lowercasing the computed digest. The registry must match.
        let u = url("https://test.invalid/a.jpg")
        ImageHashRegistry.shared.register(url: u, sha256Hex: "ABCDef")
        XCTAssertEqual(ImageHashRegistry.shared.expectedHash(for: u), "abcdef")
    }

    func test_register_overwritesPreviousValue() {
        // Telegram occasionally re-uploads avatars at the same URL; later
        // snapshots may legitimately publish a new hash for an old URL.
        let u = url("https://test.invalid/a.jpg")
        ImageHashRegistry.shared.register(url: u, sha256Hex: "old")
        ImageHashRegistry.shared.register(url: u, sha256Hex: "new")
        XCTAssertEqual(ImageHashRegistry.shared.expectedHash(for: u), "new")
    }

    // MARK: - eviction

    func test_register_evictsOldestEntriesAtSoftCap() {
        // Fill past the 10k cap by 1 — older entries (in insertion order)
        // should be the ones evicted, not the newer ones.
        for i in 0..<10_001 {
            ImageHashRegistry.shared.register(url: url("https://test.invalid/\(i).jpg"), sha256Hex: "h\(i)")
        }
        // First quarter of original 10k should be gone; newest entry must
        // remain.
        XCTAssertNil(ImageHashRegistry.shared.expectedHash(for: url("https://test.invalid/0.jpg")))
        XCTAssertEqual(ImageHashRegistry.shared.expectedHash(for: url("https://test.invalid/10000.jpg")), "h10000")
    }

    func test_register_overwritingExistingDoesNotMoveItInEvictionOrder() {
        // Insertion order is the eviction key — re-registering an existing
        // URL must NOT promote it to "newest". Otherwise an attacker who can
        // trigger repeated registrations of one URL could pin it past the
        // soft cap indefinitely while evicting legitimate entries.
        //
        // Stay strictly under the 10k cap until the deliberate overflow step,
        // so the cap-triggered eviction we're testing fires only once, with
        // a known set of insertion-order entries.
        let pinned = url("https://test.invalid/pinned.jpg")
        ImageHashRegistry.shared.register(url: pinned, sha256Hex: "p1")
        for i in 0..<9_998 {
            ImageHashRegistry.shared.register(url: url("https://test.invalid/\(i).jpg"), sha256Hex: "h\(i)")
        }
        // map.count = 9999. Re-register pinned — count stays 9999, and the
        // claim is that pinned's slot in insertionOrder doesn't move.
        ImageHashRegistry.shared.register(url: pinned, sha256Hex: "p2")
        // Push two more new entries: count goes to 10001, triggering eviction
        // of the oldest 2500. `pinned` was first in, so it must be among
        // those evicted.
        ImageHashRegistry.shared.register(url: url("https://test.invalid/overflow-1.jpg"), sha256Hex: "x1")
        ImageHashRegistry.shared.register(url: url("https://test.invalid/overflow-2.jpg"), sha256Hex: "x2")
        XCTAssertNil(ImageHashRegistry.shared.expectedHash(for: pinned))
    }
}
