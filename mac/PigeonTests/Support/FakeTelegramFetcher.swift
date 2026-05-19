import Foundation
@testable import Pigeon

/// Controllable `TelegramFetching` for ChannelService behavior tests.
/// Implemented as an actor — automatic `Sendable`, no manual locking,
/// no `@unchecked` escape hatch.
///
/// Two design choices worth knowing:
///
/// 1. `Behavior` controls both the mirror snapshot path AND the GT
///    fallback. Production's `ChannelService.fetch` tries mirror first,
///    falls through to GT on any throw — if the test wants the mirror's
///    error to be the user-visible one, GT has to fail with the same
///    shape. Having one setting drive both keeps tests honest about
///    end-to-end classification.
///
/// 2. No polling. Instead of exposing "is a fetch in flight?", the fake
///    lets tests `await waitForSnapshotCalls(n)` — resolves immediately
///    when the count is already met, or stores a continuation that
///    resolves the moment the nth call enters. Tests assert intermediate
///    state without `while !predicate { sleep }` polling.
actor FakeTelegramFetcher: TelegramFetching {
    /// Stand-in base URL for `VerifiedSnapshot.base`. `SettingsStore
    /// .defaultMirrorBaseURL` is `@MainActor`-isolated and not reachable
    /// from inside this actor; the value doesn't matter for tests because
    /// the JSON they decode resolves its own asset paths against it.
    static let fixtureBaseURL = URL(string: "https://test-mirror.invalid/")!


    enum Behavior: Sendable {
        case successUnchanged
        case successFresh(Data)
        case throwError(any Error)
        case suspend
    }

    private var behavior: Behavior = .throwError(TelegramClient.FetchError.invalidResponse)
    /// FIFO queue per username. A cancelled production sweep can leave
    /// its child continuation parked here while the replacement sweep
    /// spawns a fresh child for the same username; both must coexist,
    /// resolved in entry order by `throwSnapshot` / `resolveSnapshot`.
    private var suspendedSnapshots: [String: [CheckedContinuation<TelegramClient.MirrorFetchResult, Error>]] = [:]
    private var snapshotCallWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private(set) var snapshotCallCount: Int = 0
    private(set) var snapshotUsernames: [String] = []

    // MARK: - Configuration

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    /// Suspend until at least `count` `fetchMirrorSnapshot` calls have
    /// entered the fake. Returns immediately if the threshold is already
    /// met. Replaces polling for `hasPendingSnapshot`.
    func waitForSnapshotCalls(_ count: Int) async {
        if snapshotCallCount >= count { return }
        await withCheckedContinuation { cont in
            snapshotCallWaiters.append((threshold: count, continuation: cont))
        }
    }

    func resolveSnapshot(for username: String, with result: TelegramClient.MirrorFetchResult) {
        guard var queue = suspendedSnapshots[username], !queue.isEmpty else { return }
        let cont = queue.removeFirst()
        suspendedSnapshots[username] = queue.isEmpty ? nil : queue
        cont.resume(returning: result)
    }

    func throwSnapshot(for username: String, error: any Error) {
        guard var queue = suspendedSnapshots[username], !queue.isEmpty else { return }
        let cont = queue.removeFirst()
        suspendedSnapshots[username] = queue.isEmpty ? nil : queue
        cont.resume(throwing: error)
    }

    // MARK: - TelegramFetching

    func fetchMirrorSnapshot(
        username: String,
        baseURL: URL,
        ifNoneMatch etag: String?,
        ifModifiedSince lastModified: String?
    ) async throws -> TelegramClient.MirrorFetchResult {
        snapshotCallCount += 1
        snapshotUsernames.append(username)
        // Resolve any waiters whose threshold has now been met.
        snapshotCallWaiters.removeAll { entry in
            if snapshotCallCount >= entry.threshold {
                entry.continuation.resume()
                return true
            }
            return false
        }

        switch behavior {
        case .successUnchanged: return .unchanged
        case .successFresh(let data): return .fresh(data, etag: nil, lastModified: nil)
        case .throwError(let err): throw err
        case .suspend:
            return try await withCheckedThrowingContinuation { cont in
                suspendedSnapshots[username, default: []].append(cont)
            }
        }
    }

    /// Production's mirror→GT fallback re-throws here on any mirror
    /// failure. Mirroring the same `Behavior` on this method ensures
    /// tests see the configured error shape end-to-end, not a sentinel
    /// from this fake leaking through the fallback.
    func fetchChannelPage(username: String) async throws -> TelegramClient.ChannelPage {
        switch behavior {
        case .successUnchanged, .successFresh:
            return TelegramClient.ChannelPage(
                html: "<html></html>",
                sourceURL: URL(string: "https://t.me/s/\(username)")!,
                method: .googleAuto
            )
        case .throwError(let err): throw err
        case .suspend:
            // No separate suspend pool for the GT path — these tests
            // exercise the mirror path. Surface as invalidResponse so
            // an unexpected GT call is loud, not a hang.
            throw TelegramClient.FetchError.invalidResponse
        }
    }

    func fetchMirrorHealth(baseURL: URL) async throws -> MirrorHealth {
        throw TelegramClient.FetchError.invalidResponse
    }

    /// Same accounting as `fetchMirrorSnapshot` — production's
    /// `ChannelService.fetch` now calls this method instead, so the snapshot
    /// call counters / waiters need to bump from here too. The mapping from
    /// `Behavior` to verified-snapshot outcome is:
    ///
    ///   - `.successFresh(data)` → VerifiedSnapshot stamped at `now`
    ///   - `.successUnchanged`   → `notMirroredAnywhere` (no analog of 304
    ///                              in the new tier-walked flow). Tests that
    ///                              relied on .unchanged semantics need to
    ///                              be migrated; this maps to "all tiers
    ///                              missing the channel" so GT fallback
    ///                              gets exercised loudly rather than
    ///                              silently passing.
    ///   - `.throwError(err)`   → re-throw
    ///   - `.suspend`           → park on the same per-username queue used
    ///                              by `fetchMirrorSnapshot`, then map the
    ///                              resolved `MirrorFetchResult` into a
    ///                              `VerifiedSnapshot` the same way.
    func fetchVerifiedSnapshot(username: String) async throws -> TelegramClient.VerifiedSnapshot {
        snapshotCallCount += 1
        snapshotUsernames.append(username)
        snapshotCallWaiters.removeAll { entry in
            if snapshotCallCount >= entry.threshold {
                entry.continuation.resume()
                return true
            }
            return false
        }

        switch behavior {
        case .successUnchanged:
            throw TelegramClient.VerifyError.notMirroredAnywhere
        case .successFresh(let data):
            return TelegramClient.VerifiedSnapshot(
                data: data,
                base: Self.fixtureBaseURL,
                fetchedAt: .now
            )
        case .throwError(let err):
            throw err
        case .suspend:
            let result = try await withCheckedThrowingContinuation { cont in
                suspendedSnapshots[username, default: []].append(cont)
            }
            switch result {
            case .unchanged:
                throw TelegramClient.VerifyError.notMirroredAnywhere
            case .fresh(let data, _, _):
                return TelegramClient.VerifiedSnapshot(
                    data: data,
                    base: Self.fixtureBaseURL,
                    fetchedAt: .now
                )
            }
        }
    }
}
