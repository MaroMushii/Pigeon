import Foundation
import Nuke
import os
import XCTest
@testable import Pigeon

/// Tests for `VerifyingDataLoader` — the byte-level image integrity gate
/// between Nuke and the URL the registry knows the expected hash for.
///
/// We don't drive real HTTP here. `FakeDataLoader` impersonates Nuke's
/// `DataLoading` and synchronously delivers a fixed payload, which lets
/// us drive the verifier's three branches:
///
///   1. URL has no registered hash → pass-through, no hashing.
///   2. Registered hash matches the bytes → completion(nil).
///   3. Registered hash mismatches the bytes → completion(ImageVerifyError).
///
/// The registry is shared singleton state; we reset in `tearDown` so each
/// test starts from a known-empty state.
final class VerifyingDataLoaderTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        ImageHashRegistry.shared._reset()
    }

    /// Drives `loadData` and returns (completion error, total bytes
    /// delivered to the data callback). Callback state lives behind an
    /// `OSAllocatedUnfairLock` — the same pattern production uses — so the
    /// @Sendable closures don't have to lie about thread-safety even if a
    /// future fake decides to dispatch its callbacks across threads.
    @discardableResult
    private func runLoader(
        loader: VerifyingDataLoader,
        url: URL
    ) -> (completionError: Error?, deliveredBytes: Int) {
        let state = OSAllocatedUnfairLock(initialState: CallbackState())
        let done = XCTestExpectation(description: "completion called")
        _ = loader.loadData(
            with: URLRequest(url: url),
            didReceiveData: { chunk, _ in
                state.withLock { $0.delivered += chunk.count }
            },
            completion: { err in
                state.withLock { $0.capturedError = err }
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)
        return state.withLock { ($0.capturedError, $0.delivered) }
    }

    private func makeResponse(for url: URL) -> URLResponse {
        URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: -1, textEncodingName: nil)
    }

    func test_passthrough_whenURLHasNoRegisteredHash() {
        let url = URL(string: "https://test.invalid/unregistered.jpg")!
        let payload = Data("totally unverified".utf8)
        let fake = FakeDataLoader(chunks: [payload], response: makeResponse(for: url))
        let loader = VerifyingDataLoader(wrapping: fake)

        let (err, bytes) = runLoader(loader: loader, url: url)

        XCTAssertNil(err)
        XCTAssertEqual(bytes, payload.count)
    }

    func test_completionSucceeds_whenHashMatches() {
        let url = URL(string: "https://test.invalid/match.jpg")!
        let payload = Data("hello mirror".utf8)
        let expected = MirrorSignature.sha256Hex(of: payload)
        ImageHashRegistry.shared.register(url: url, sha256Hex: expected)

        let fake = FakeDataLoader(chunks: [payload], response: makeResponse(for: url))
        let loader = VerifyingDataLoader(wrapping: fake)

        let (err, bytes) = runLoader(loader: loader, url: url)

        XCTAssertNil(err)
        XCTAssertEqual(bytes, payload.count)
    }

    func test_completionFails_whenHashMismatches() {
        let url = URL(string: "https://test.invalid/mismatch.jpg")!
        let actualPayload = Data("served bytes".utf8)
        // Register a hash that does NOT match what FakeDataLoader will
        // serve — simulates a mirror that's serving tampered image bytes
        // for a URL whose hash was signed into the snapshot.
        ImageHashRegistry.shared.register(url: url, sha256Hex: MirrorSignature.sha256Hex(of: Data("different bytes".utf8)))

        let fake = FakeDataLoader(chunks: [actualPayload], response: makeResponse(for: url))
        let loader = VerifyingDataLoader(wrapping: fake)

        let (err, _) = runLoader(loader: loader, url: url)

        guard let err, case VerifyingDataLoader.ImageVerifyError.hashMismatch = err else {
            return XCTFail("expected ImageVerifyError.hashMismatch, got <\(String(describing: err))>")
        }
    }

    func test_incrementalHashing_matchesAcrossMultipleChunks() {
        // The whole point of switching to incremental SHA256 was to drop the
        // buffer-everything-then-hash approach. This test feeds the payload
        // as 3 separate chunks and expects success — proves `update(data:)`
        // is being called per chunk and `finalize()` covers them all.
        let url = URL(string: "https://test.invalid/chunked.jpg")!
        let parts = [Data("part1".utf8), Data("part2".utf8), Data("part3".utf8)]
        let whole = parts.reduce(Data(), +)
        ImageHashRegistry.shared.register(url: url, sha256Hex: MirrorSignature.sha256Hex(of: whole))

        let fake = FakeDataLoader(chunks: parts, response: makeResponse(for: url))
        let loader = VerifyingDataLoader(wrapping: fake)

        let (err, bytes) = runLoader(loader: loader, url: url)

        XCTAssertNil(err)
        XCTAssertEqual(bytes, whole.count)
    }

    func test_completionPropagatesInnerError() {
        // If the wrapped loader's request fails, the verifier must surface
        // that error verbatim — not eat it and substitute a hash-mismatch.
        let url = URL(string: "https://test.invalid/network-fail.jpg")!
        ImageHashRegistry.shared.register(url: url, sha256Hex: "deadbeef")

        struct StubNetworkError: Error {}
        let fake = FakeDataLoader(chunks: [], response: makeResponse(for: url), completionError: StubNetworkError())
        let loader = VerifyingDataLoader(wrapping: fake)

        let (err, _) = runLoader(loader: loader, url: url)
        XCTAssertTrue(err is StubNetworkError)
    }
}

// MARK: - FakeDataLoader

/// Synchronous fake — calls `didReceiveData` for each chunk, then calls
/// `completion` with either the configured error or `nil`. Returns a no-op
/// `Cancellable` because nothing here can be cancelled mid-flight (the
/// whole sequence runs before `loadData` returns).
///
/// All stored properties are immutable after init, and the error type is
/// constrained to `Sendable`, so this is genuinely Sendable — no
/// `@unchecked` escape hatch.
private final class FakeDataLoader: DataLoading, Sendable {
    private let chunks: [Data]
    private let response: URLResponse
    private let completionError: (any Error & Sendable)?

    init(chunks: [Data], response: URLResponse, completionError: (any Error & Sendable)? = nil) {
        self.chunks = chunks
        self.response = response
        self.completionError = completionError
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        for chunk in chunks {
            didReceiveData(chunk, response)
        }
        completion(completionError)
        return NoopCancellable()
    }
}

private final class NoopCancellable: Cancellable, Sendable {
    func cancel() {}
}

/// State held behind `OSAllocatedUnfairLock` inside `runLoader`. A value
/// type carrying the captured callback results — Sendable by composition,
/// no `@unchecked` escape hatch needed.
private struct CallbackState {
    var delivered: Int = 0
    var capturedError: Error?
}
