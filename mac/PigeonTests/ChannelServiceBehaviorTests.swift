import XCTest
import SwiftData
@testable import Pigeon

/// Behavior tests for `ChannelService.refresh` / `refreshAll` / `cancelAll`
/// — the parts of the refactor whose correctness depends on Task lifecycle
/// and error classification, not on pure-function output.
///
/// Each test creates its own service + fake + in-memory SwiftData
/// container so they don't see each other's state. `service.start()`
/// is deliberately NOT called — tests own the Task lifecycle, no
/// background ticker races the assertions.
final class ChannelServiceBehaviorTests: XCTestCase {

    @MainActor
    fileprivate func makeService() throws -> (ChannelService, FakeTelegramFetcher, Channel) {
        let container = try InMemoryModelContainer.make()
        let context = ModelContext(container)
        let fetcher = FakeTelegramFetcher()
        let suiteName = "pigeon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = ChannelService(
            client: fetcher,
            context: context,
            settings: SettingsStore(defaults: defaults)
        )
        let channel = InMemoryModelContainer.insertChannel(username: "alpha", in: context)
        return (service, fetcher, channel)
    }
}

extension ChannelServiceBehaviorTests {

    // MARK: - Task de-dupe

    @MainActor
    func test_refresh_dedupesConcurrentCallsForSameChannel() async throws {
        let (service, fetcher, channel) = try makeService()
        await fetcher.setBehavior(.suspend)

        // `Task { @MainActor in ... }` inherits MainActor isolation, so
        // capturing the @Model `channel` is safe. `async let` does NOT
        // inherit MainActor and trips strict-concurrency Sendable checks.
        let first = Task { @MainActor in try await service.refresh(channel) }
        let second = Task { @MainActor in try await service.refresh(channel) }

        await fetcher.waitForSnapshotCalls(1)

        let callCount = await fetcher.snapshotCallCount
        XCTAssertEqual(callCount, 1, "second concurrent refresh should join the first, not start a new fetch")
        XCTAssertEqual(service.inflight, ["alpha"])

        // Pre-signing builds resolved this as `.unchanged` (304 semantics).
        // The verified-snapshot path has no 304 — resolve with a minimal
        // empty-channel snapshot instead. Dedup behaviour is what matters
        // here, not the snapshot's content.
        let emptySnapshot = Data(#"""
        {"schema":2,"fetched_at":"2026-05-19T12:00:00Z","channel":{"username":"alpha","title":"Alpha","description_html":null,"photo_url":null,"photo_path":null,"photo_sha256":null,"subscriber_count":null},"posts":[]}
        """#.utf8)
        await fetcher.resolveSnapshot(for: "alpha", with: .fresh(emptySnapshot, etag: nil, lastModified: nil))
        _ = try await first.value
        _ = try await second.value

        let finalCount = await fetcher.snapshotCallCount
        XCTAssertEqual(finalCount, 1)
        XCTAssertTrue(service.inflight.isEmpty)
    }

    // MARK: - Error classification

    @MainActor
    func test_refresh_classifiesNoInternetAsConnectionError() async throws {
        let (service, fetcher, channel) = try makeService()
        await fetcher.setBehavior(.throwError(URLError(.notConnectedToInternet)))

        do { try await service.refresh(channel) } catch { /* expected */ }

        XCTAssertNotNil(service.connectionError)
        XCTAssertEqual(service.connectionError?.message, "No internet connection.")
        XCTAssertNil(service.channelErrors["alpha"], "transport failure is global, shouldn't blame the channel")
    }

    @MainActor
    func test_refresh_classifiesPerChannelErrorOnChannelNotFound() async throws {
        let (service, fetcher, channel) = try makeService()
        await fetcher.setBehavior(.throwError(TelegramClient.FetchError.channelNotFound))

        do { try await service.refresh(channel) } catch { /* expected */ }

        XCTAssertNotNil(service.channelErrors["alpha"])
        XCTAssertNil(service.connectionError, "channel-shaped error shouldn't poison the global connection slot")
    }

    @MainActor
    func test_refresh_clearsBothErrorSurfacesOnSuccess() async throws {
        let (service, fetcher, channel) = try makeService()

        await fetcher.setBehavior(.throwError(URLError(.notConnectedToInternet)))
        do { try await service.refresh(channel) } catch { /* expected */ }
        XCTAssertNotNil(service.connectionError)

        await fetcher.setBehavior(.throwError(TelegramClient.FetchError.channelNotFound))
        do { try await service.refresh(channel) } catch { /* expected */ }
        XCTAssertNotNil(service.channelErrors["alpha"])

        await fetcher.setBehavior(.successUnchanged)
        try await service.refresh(channel)

        XCTAssertNil(service.channelErrors["alpha"])
        XCTAssertNil(service.connectionError, "any successful round-trip proves the network is back")
    }

    // MARK: - cancelAll reaches per-channel in-flight tasks

    @MainActor
    func test_cancelAll_cancelsInFlightPerChannelRefresh() async throws {
        let (service, fetcher, channel) = try makeService()
        await fetcher.setBehavior(.suspend)

        let refreshTask = Task { @MainActor in try await service.refresh(channel) }
        await fetcher.waitForSnapshotCalls(1)
        XCTAssertEqual(service.inflight, ["alpha"])

        service.cancelAll()
        // Unblock the suspended fetch via a CancellationError so the
        // task's catch path runs through without surfacing a user error.
        await fetcher.throwSnapshot(for: "alpha", error: CancellationError())

        do {
            _ = try await refreshTask.value
        } catch {
            // CancellationError or downstream cancellation — both fine.
        }

        XCTAssertTrue(service.inflight.isEmpty, "cancel must clear the inflight slot")
        XCTAssertNil(service.channelErrors["alpha"], "cancellation is not a user-visible failure")
    }

    // MARK: - Auto-tick join (force:false doesn't restart in-progress sweep)

    @MainActor
    func test_refreshAll_nonForceJoinsExistingSweep() async throws {
        let (service, fetcher, _) = try makeService()
        await fetcher.setBehavior(.suspend)

        let first = service.refreshAll(force: true)
        await fetcher.waitForSnapshotCalls(1)

        let joined = service.refreshAll(force: false)
        XCTAssertTrue(first == joined, "non-force call should return the same Task, not start a new sweep")
        let callCount = await fetcher.snapshotCallCount
        XCTAssertEqual(callCount, 1)

        await fetcher.resolveSnapshot(for: "alpha", with: .unchanged)
        await first.value
    }

    // MARK: - Generation token: force:true while a sweep is running

    @MainActor
    func test_refreshAll_forceTrueReplacesRunningSweepWithoutOrphaningSlot() async throws {
        let (service, fetcher, _) = try makeService()
        await fetcher.setBehavior(.suspend)

        let firstSweep = service.refreshAll(force: true)
        await fetcher.waitForSnapshotCalls(1)

        let secondSweep = service.refreshAll(force: true)
        XCTAssertFalse(firstSweep == secondSweep, "force:true should produce a fresh Task")

        // Let the old (now-cancelled) sweep unwind through cancellation.
        await fetcher.throwSnapshot(for: "alpha", error: CancellationError())
        await firstSweep.value

        await fetcher.waitForSnapshotCalls(2)
        await fetcher.resolveSnapshot(for: "alpha", with: .unchanged)
        await secondSweep.value

        // The generation-token logic should have cleared the slot when
        // the second sweep finished — a follow-up call must NOT join a
        // stale Task.
        await fetcher.setBehavior(.successUnchanged)
        let third = service.refreshAll(force: false)
        XCTAssertFalse(third == firstSweep)
        XCTAssertFalse(third == secondSweep)
        await third.value
    }
}
