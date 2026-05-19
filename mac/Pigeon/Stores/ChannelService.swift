import AppKit
import Foundation
import SwiftData

/// Coordinates SwiftData persistence + remote fetches for channels.
/// Always invoked from the main actor — SwiftData's `ModelContext` is
/// not Sendable and must stay on a single isolation domain.
///
/// Also owns transient network state — which channels are currently
/// fetching (`inflight`) and the most recent failure (`lastError`).
/// Views observe these directly; they're not navigation state and
/// don't belong in `AppState`.
@MainActor
@Observable
final class ChannelService {
    enum AddError: Error, LocalizedError {
        case invalidUsername
        case alreadyExists(displayName: String)
        case channelNotFound
        case fetchFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidUsername: "That doesn't look like a Telegram channel."
            case .alreadyExists(let name): "\u{201C}\(name)\u{201D} is already in your sidebar."
            case .channelNotFound: "That channel is private or doesn't exist on Telegram."
            case .fetchFailed(let e): "Couldn't load channel: \(e.localizedDescription)"
            }
        }
    }

    /// A refresh failure scoped to a single channel — the channel returned
    /// a per-channel-shaped error (404, malformed payload, rate limit).
    /// Surfaced on the matching sidebar row until cleared on success or
    /// dismissed. The owning channel is the dictionary key in
    /// `channelErrors`; this struct intentionally doesn't repeat it.
    struct ChannelError: Sendable {
        let message: String
        let at: Date
    }

    /// A refresh failure that's app-wide — the network path itself is
    /// broken (no internet, pinned IPs unreachable, transport timeout).
    /// Surfaced on the toolbar; clicking opens the diagnosis sheet.
    /// Single slot: every channel that fails for this reason produces the
    /// same message, so there's no per-channel data worth preserving.
    struct ConnectionError: Sendable {
        let message: String
        let at: Date
    }

    /// How often the auto-refresh loop wakes and re-evaluates which
    /// channels are due. Each channel has its own per-source interval
    /// (see `FetchSource.refreshInterval`); this is just the polling
    /// granularity. 30s gives a worst-case 30s overshoot which is fine.
    static let autoRefreshTickInterval: Duration = .seconds(30)

    /// Most recent per-channel failure, keyed by username. Each row in
    /// the sidebar reads its own entry. Cleared on that channel's next
    /// successful refresh or via `dismissChannelError(_:)`. Read-only
    /// from outside — mutations go through the named methods so the
    /// classifier in `recordFailure` stays authoritative.
    private(set) var channelErrors: [String: ChannelError] = [:]

    /// Most recent network-path failure. Cleared on *any* successful
    /// refresh (the network is back), or via `dismissConnectionError()`.
    private(set) var connectionError: ConnectionError?

    /// In-flight per-channel refreshes, keyed by username. Owning the
    /// `Task` (not just a flag) is what makes `cancelAll()` reach
    /// per-channel refreshes started from sidebar / context-menu /
    /// empty-state — those callers fire-and-forget; the service holds
    /// the only handle that can cancel them. Observed: spinner views
    /// (`ChannelRow`, `EmptyFeedState`, toolbar refresh/cancel morph)
    /// re-render when the keyset changes.
    private var inflightTasks: [String: Task<Void, Error>] = [:]

    /// Set of usernames currently being refreshed. Computed from
    /// `inflightTasks` so existing sites keep their `.inflight.contains(...)`
    /// reads unchanged.
    var inflight: Set<String> { Set(inflightTasks.keys) }

    /// True when the mirror returned a snapshot whose schema version is
    /// newer than this build understands. We fall back to the GT path so
    /// the user keeps reading; the sidebar surfaces a banner suggesting
    /// an app update. Cleared on the next successful mirror decode in
    /// case a server-side rollback resolves the skew.
    private(set) var schemaOutdated: Bool = false

    /// Latest `health.json` snapshot from the mirror — sweep finish time
    /// plus per-channel failure list. Refreshed on init and on every
    /// auto-refresh tick. Nil before the first successful fetch (e.g.
    /// during the brief window after install before the network is up).
    /// Sidebar's staleness footer reads this in preference to the
    /// per-channel `lastFetchedAt` heuristic.
    private(set) var mirrorHealth: MirrorHealth?

    /// Cached unread-post count across all channels. Mirrors what the dock
    /// badge displays. Maintained incrementally on `markRead` and
    /// recomputed authoritatively on add/refresh/remove. Reading SwiftData
    /// from `updateDockBadge` on every scroll-induced markRead pegged the
    /// main actor; this cache makes the hot path O(1).
    private(set) var unreadCount: Int = 0

    @ObservationIgnored private let client: any TelegramFetching
    @ObservationIgnored private let parser = HTMLPostParser()
    @ObservationIgnored private let jsonDecoder = JSONFeedDecoder()
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var autoRefreshLoopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Per-spawn identity for `refreshTask`. Each time the slot is replaced
    /// (cancel + spawn) we mint a new UUID; the prior task's `defer` only
    /// clears the slot if it still matches its own token. A UUID avoids the
    /// (theoretical) wrap-around hazard of a counter and the (very real)
    /// readability hit of remembering which generation is current.
    @ObservationIgnored private var refreshGeneration: UUID = UUID()
    @ObservationIgnored private let validatorStore = MirrorValidatorStore()

    init(
        client: any TelegramFetching,
        context: ModelContext,
        settings: SettingsStore
    ) {
        self.client = client
        self.context = context
        self.settings = settings
        Self.seedChannelUnreadCountsIfNeeded(in: context)
        self.unreadCount = Self.recomputeUnreadCount(in: context)
    }

    /// Kick off the auto-refresh ticker and the initial mirror-health
    /// fetch. The app's entry point (`PigeonApp`) calls this immediately
    /// after constructing the service. Kept out of `init` so tests can
    /// construct a service whose Task lifecycle is fully controlled by
    /// the test body — no background ticker racing the assertions.
    func start() {
        startAutoRefreshLoop()
        Task { await self.refreshMirrorHealth() }
    }

    /// Bump this when `Channel.unreadCount` semantics change in a way
    /// that requires a re-seed (e.g. a migration adds the column at 0,
    /// or the counted-set definition shifts). Existing installs with a
    /// lower stored value get one re-seed pass on next launch.
    private static let unreadSeedVersion = 1
    private static let unreadSeedVersionKey = "channelUnreadSeedVersion"

    /// Versioned startup pass: populate each channel's stored
    /// `unreadCount` from its persisted posts the first time this build
    /// runs (or whenever `unreadSeedVersion` bumps). Pre-fix this ran on
    /// every launch — cheap on small datasets, but unnecessary, and the
    /// only thing protecting against drift the rest of the code already
    /// maintains incrementally. Re-seed on demand via `unreadSeedVersionKey`.
    private static func seedChannelUnreadCountsIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: unreadSeedVersionKey)
        guard stored < unreadSeedVersion else { return }
        let descriptor = FetchDescriptor<Channel>()
        guard let channels = try? context.fetch(descriptor) else { return }
        for channel in channels {
            channel.unreadCount = channel.posts.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
        }
        defaults.set(unreadSeedVersion, forKey: unreadSeedVersionKey)
    }

    deinit {
        autoRefreshLoopTask?.cancel()
        refreshTask?.cancel()
    }

    func dismissChannelError(_ username: String) {
        channelErrors.removeValue(forKey: username)
    }

    func dismissConnectionError() {
        connectionError = nil
    }

    /// Add a new channel: validates the username, fetches the page, parses
    /// metadata, persists a `Channel` row, persists initial posts.
    func addChannel(rawIdentifier: String) async throws -> Channel {
        guard let username = ChannelIdentifier.normalise(rawIdentifier) else {
            throw AddError.invalidUsername
        }

        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.username == username })
        if let existing = try? context.fetch(descriptor).first {
            throw AddError.alreadyExists(displayName: existing.displayName)
        }

        // Defensive: a previous remove (or a crash before remove finished)
        // can leave stale validators in UserDefaults. Without this clear the
        // fetch below could 304 against a channel we have no posts for.
        validatorStore.clear(username: username)

        let outcome: FetchOutcome
        do {
            outcome = try await fetch(username: username)
        } catch TelegramClient.FetchError.channelNotFound {
            throw AddError.channelNotFound
        } catch {
            throw AddError.fetchFailed(underlying: error)
        }

        // A brand-new channel can't satisfy a 304 — we have no validators
        // for it yet, so the request omitted If-None-Match. Treat
        // `.unchanged` as a contract violation rather than fail silently.
        guard case .changed(let result, let source) = outcome else {
            throw AddError.fetchFailed(underlying: FetchUnchangedOnAddError())
        }

        let channel = Channel(
            username: result.channel.username,
            displayName: result.channel.title,
            photoURL: result.channel.photoURL,
            channelDescription: result.channel.descriptionHTML,
            subscriberCount: result.channel.subscriberCount
        )
        channel.lastFetchedAt = .now
        channel.lastFetchSource = source.rawValue
        context.insert(channel)
        // Initial posts are marked read — the user is actively viewing the
        // channel they just added; they shouldn't see a fresh unread badge
        // for content they explicitly chose to subscribe to.
        upsertPosts(result.posts, into: channel, markNewAsRead: true)
        try context.save()
        recomputeUnreadCountAndBadge()
        return channel
    }

    /// Internal sentinel — should never escape `addChannel` into UI text in
    /// practice. If a user sees this, the mirror returned 304 to a request
    /// without conditional headers, which means our HTTP layer is broken.
    private struct FetchUnchangedOnAddError: Error, LocalizedError {
        var errorDescription: String? { "Mirror returned 304 to an unconditional request." }
    }

    /// Refresh an existing channel's posts and metadata in place. Marks
    /// the channel as in-flight for the duration of the network call,
    /// clears its `channelErrors` entry (and `connectionError`) on
    /// success, classifies + stores the failure on throw.
    ///
    /// De-dupes by username: a second call while the first is still
    /// in-flight joins the existing `Task` instead of starting a duplicate
    /// fetch. That's what lets `refreshAll` blindly iterate every channel
    /// without skipping the ones the auto-loop or a context-menu refresh
    /// already started — they all converge on the same Task.
    func refresh(_ channel: Channel) async throws {
        let username = channel.username
        if let existing = inflightTasks[username] {
            try await existing.value
            return
        }
        // Create the Task but DON'T let its body clear `inflightTasks` —
        // a concurrent re-entry could repopulate the slot with a new
        // Task and the old defer would clobber it. The creator (this
        // function) owns the slot for the duration of its own await,
        // clearing on exit via the outer defer. De-dupe joiners don't
        // run the defer, so the dict has exactly one owner.
        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRefresh(channel)
        }
        inflightTasks[username] = task
        // Identity-guard: `refreshAll(force: true)` can synchronously
        // replace the slot with a fresh task. When this older task's
        // cancellation eventually unwinds, its defer must NOT clobber
        // the replacement's slot.
        defer {
            if inflightTasks[username] == task {
                inflightTasks.removeValue(forKey: username)
            }
        }
        try await task.value
    }

    /// Actual per-channel refresh body. Always run inside the Task held
    /// in `inflightTasks` so cancellation propagates and the inflight
    /// entry is cleared exactly once.
    private func performRefresh(_ channel: Channel) async throws {
        let username = channel.username
        do {
            let outcome = try await fetch(username: username)
            switch outcome {
            case .unchanged(let source):
                // Server confirmed nothing changed. Bump the freshness
                // clock so auto-refresh scheduling and "last updated" UI
                // are accurate, but don't touch posts/media/reactions —
                // doing so would defeat the entire point of conditional
                // GET (it'd still re-fire @Observable updates).
                channel.lastFetchedAt = .now
                channel.lastFetchSource = source.rawValue
                try context.save()
                clearErrorsOnSuccess(username: username)
            case .changed(let result, let source):
                // Guard each write so @Observable only fires when a value
                // actually changed. Unconditional writes were causing ChannelRow
                // and ChannelHeader to re-render on every refresh cycle even
                // when title/photo/subs hadn't changed — 111 body re-runs in a
                // single 175ms hitch window per the Instruments trace.
                if channel.displayName != result.channel.title {
                    channel.displayName = result.channel.title
                }
                if let photoURL = result.channel.photoURL, channel.photoURL != photoURL {
                    channel.photoURL = photoURL
                }
                if let desc = result.channel.descriptionHTML, channel.channelDescription != desc {
                    channel.channelDescription = desc
                }
                if let subs = result.channel.subscriberCount, channel.subscriberCount != subs {
                    channel.subscriberCount = subs
                }
                channel.lastFetchedAt = .now
                if channel.lastFetchSource != source.rawValue {
                    channel.lastFetchSource = source.rawValue
                }
                upsertPosts(result.posts, into: channel)
                try context.save()
                recomputeUnreadCountAndBadge()
                clearErrorsOnSuccess(username: username)
            }
        } catch {
            // Cancellation is not a user-visible failure — the user
            // clicked cancel, so just propagate without bucketing.
            if !(error is CancellationError) {
                recordFailure(username: username, error: error)
            }
            throw error
        }
    }

    /// Clear both error surfaces this channel could be on. A successful
    /// round-trip proves the network is up, so the global
    /// `connectionError` clears regardless of which channel succeeded.
    private func clearErrorsOnSuccess(username: String) {
        channelErrors.removeValue(forKey: username)
        connectionError = nil
    }

    /// Bucket a refresh failure into the two visible error surfaces.
    /// Network-path errors (no internet, pinned IPs unreachable, transport
    /// timeout) → `connectionError`. Anything else (404, decoder failure,
    /// rate limit, etc.) → `channelErrors[username]`.
    private func recordFailure(username: String, error: Error) {
        let message = Self.userFacingMessage(for: error)
        if Self.isConnectionError(error) {
            connectionError = ConnectionError(message: message, at: .now)
        } else {
            channelErrors[username] = ChannelError(message: message, at: .now)
        }
    }

    /// Predicate for "this is a network-path failure, not a channel-shaped
    /// failure." The set is deliberately narrow: only failures that would
    /// resolve by toggling Wi-Fi or unblocking the pinned host count as
    /// connection errors. A 404 / parse failure / rate limit stays
    /// per-channel — those will keep failing even on a healthy network.
    ///
    /// The `URLError` set covers what Iranian DPI / DNS-poisoning tends
    /// to surface as: `.cannotFindHost` shows up when the system resolver
    /// returns a poisoned answer, `.cannotLoadFromNetwork` when the
    /// pinned path is cooperatively torn down mid-handshake.
    private static func isConnectionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .cannotLoadFromNetwork,
                 .networkConnectionLost, .dnsLookupFailed,
                 .internationalRoamingOff, .callIsActive,
                 .dataNotAllowed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        if let pinnedError = error as? PinnedHTTPSClient.ClientError {
            switch pinnedError {
            case .connectionFailed, .timedOut, .truncated:
                return true
            case .invalidIP, .malformedResponse, .statusCode, .bodyTooLarge:
                return false
            }
        }
        if let fetchError = error as? TelegramClient.FetchError {
            switch fetchError {
            case .noInternet, .allMethodsFailed:
                return true
            case .rateLimited, .invalidResponse, .channelNotFound:
                return false
            }
        }
        return false
    }

    /// Map raw error types to a short, actionable user-facing string.
    /// `error.localizedDescription` on `URLError` yields system messages
    /// like "A server with the specified hostname could not be found."
    /// — accurate, but not the language we want surfaced in a sidebar
    /// tooltip. Conformance to `LocalizedError` on our own error types
    /// (`TelegramClient.FetchError`, `PinnedHTTPSClient.ClientError`)
    /// already gives nice strings; we only need to override `URLError`.
    private static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return "No internet connection."
            case .timedOut:
                return "Network request timed out."
            case .cannotFindHost, .dnsLookupFailed:
                return "Server name couldn't be resolved."
            case .cannotConnectToHost, .networkConnectionLost,
                 .cannotLoadFromNetwork:
                return "Couldn't reach server — connection dropped."
            case .secureConnectionFailed:
                return "Secure connection failed."
            default:
                return "Network error."
            }
        }
        return error.localizedDescription
    }

    /// Returns persisted posts if the channel was fetched within the
    /// freshness TTL; otherwise refreshes from network and returns the
    /// merged set. Cache-hit path doesn't touch `inflight`/`lastError`.
    func postsForDisplay(_ channel: Channel, forceRefresh: Bool = false) async throws -> [Post] {
        if !forceRefresh, isFresh(channel) {
            return channel.posts
        }
        try await refresh(channel)
        return channel.posts
    }

    /// Sweep every persisted channel. `force: true` (the default, used by
    /// the manual toolbar button) refreshes every channel regardless of
    /// freshness. `force: false` (used by the auto-refresh ticker) only
    /// refreshes channels whose `lastFetchedAt` is past their per-source
    /// TTL — that's the whole job the dedicated auto-loop used to do.
    ///
    /// Channels already in flight are no longer skipped: per-channel
    /// de-dupe lives inside `refresh(_:)` itself, so a blind iteration
    /// here either joins the existing fetch or starts a fresh one. Net
    /// effect: every channel is guaranteed to have a fresh result (or a
    /// fresh classified error) by the time this Task completes.
    ///
    /// Non-force calls (the auto-tick) join a still-running sweep
    /// instead of cancelling and restarting it — N channels × sequential
    /// fetches can easily exceed the 30 s tick interval, and restarting
    /// from scratch every tick means the auto-loop would never finish
    /// a full pass on a slow network.
    ///
    /// Returns the underlying Task so callers can `await` completion if
    /// they need to (tests, future "wait until first sweep" UI). The
    /// toolbar button uses it as fire-and-forget, hence
    /// `@discardableResult`.
    @discardableResult
    func refreshAll(force: Bool = true) -> Task<Void, Never> {
        if !force, let existing = refreshTask {
            return existing
        }
        refreshTask?.cancel()
        if force {
            // `force: true` means "preempt now, fetch fresh now." Cancel
            // every in-flight per-channel task and clear the dict so the
            // replacement sweep doesn't join a stale (cancelled) fetch
            // via `refresh(_:)`'s de-dupe check. The cancelled tasks'
            // own defers are identity-guarded and won't clobber the
            // refreshed slots.
            for task in inflightTasks.values { task.cancel() }
            inflightTasks.removeAll()
        }
        let myGen = UUID()
        refreshGeneration = myGen
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGeneration == myGen {
                    self.refreshTask = nil
                }
            }
            await self.refreshMirrorHealth()
            let descriptor = FetchDescriptor<Channel>()
            guard let channels = try? self.context.fetch(descriptor) else { return }
            for channel in channels {
                guard !Task.isCancelled else { break }
                if !force, self.isFresh(channel) { continue }
                _ = try? await self.refresh(channel)
            }
        }
        refreshTask = task
        return task
    }

    /// Stop every in-flight refresh — sweep and per-channel both — and
    /// drop the inflight set so spinners clear at the next render. The
    /// auto-refresh ticker keeps running on its 30 s cadence; its
    /// per-source TTL gate (`refreshAll(force: false)` + `isFresh`) is
    /// strong enough that most recently-touched channels won't be picked
    /// back up. No persistent paused state — Cancel means *stop now*,
    /// not *stay stopped*.
    func cancelAll() {
        refreshTask?.cancel()
        for task in inflightTasks.values { task.cancel() }
        // The Task's own `defer` clears its `inflightTasks` entry once
        // cancellation propagates. Don't clobber the dict here — that
        // would orphan the still-running fetch (cancellation is
        // cooperative; the task hasn't exited yet).
    }

    func remove(_ channel: Channel) {
        validatorStore.clear(username: channel.username)
        context.delete(channel)
        do {
            try context.save()
        } catch {
            AppLog.mount.error("[ChannelService] remove save failed: \(error.localizedDescription, privacy: .public)")
        }
        recomputeUnreadCountAndBadge()
    }

    func isFresh(_ channel: Channel) -> Bool {
        guard let last = channel.lastFetchedAt else { return false }
        return Date.now.timeIntervalSince(last) < settings.cacheTTL
    }

    // MARK: - Upsert

    /// Per-channel post retention cap. Eviction uses newest-first ordering so
    /// the oldest posts are removed. Mirrors the mirror scraper's RETAIN_LIMIT
    /// but higher — the app accumulates across many scraper runs, so we allow
    /// more history while still bounding SwiftData growth.
    private static let maxPostsPerChannel = 200

    /// Merge `snapshots` into `channel.posts`. Existing posts (matched by
    /// `id`) are updated in place; previously persisted posts not in this
    /// snapshot are preserved — `t.me/s/<channel>` only returns the most
    /// recent ~20 posts, so absence is not deletion.
    ///
    /// After merging, evicts posts beyond `maxPostsPerChannel` (oldest first)
    /// and updates the stored `channel.lastPostAt`.
    ///
    /// `markNewAsRead` controls the unread state of *newly inserted* posts.
    /// Pass `true` only when the user is the proximate cause of the fetch
    /// (initial channel add); the default `false` is what auto-refresh and
    /// manual refresh both want — fresh posts should appear unread.
    private func upsertPosts(
        _ snapshots: [PostSnapshot],
        into channel: Channel,
        markNewAsRead: Bool = false
    ) {
        var existingByID: [String: Post] = [:]
        for p in channel.posts { existingByID[p.id] = p }

        for snap in snapshots {
            if let existing = existingByID[snap.id] {
                existing.updateScalars(from: snap)
                replaceMedia(of: existing, with: snap.media)
                replaceReactions(of: existing, with: snap.reactions)
            } else {
                insertNewPost(from: snap, into: channel, isRead: markNewAsRead)
            }
        }

        evictOldPosts(in: channel)
        // Derive lastPostAt from the incoming snapshots (already in memory)
        // rather than re-traversing the relationship. Guard the write — an
        // identical value still fires @Observable and marks the context dirty.
        let newLastPostAt = snapshots.compactMap(\.postedAt).max()
        if newLastPostAt != channel.lastPostAt {
            channel.lastPostAt = newLastPostAt
        }
        let freshUnread = channel.posts.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
        if channel.unreadCount != freshUnread {
            channel.unreadCount = freshUnread
        }
    }

    private func evictOldPosts(in channel: Channel) {
        guard channel.posts.count > Self.maxPostsPerChannel else { return }
        let sorted = channel.posts.sorted {
            ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast)
        }
        for post in sorted.dropFirst(Self.maxPostsPerChannel) {
            context.delete(post)
        }
    }

    private func insertNewPost(from snap: PostSnapshot, into channel: Channel, isRead: Bool) {
        let post = Post(
            id: snap.id,
            channelUsername: snap.channelUsername,
            authorName: snap.authorName,
            authorPhotoURL: snap.authorPhotoURL,
            bodyHTML: snap.bodyHTML,
            plainText: snap.plainText,
            viewsLabel: snap.viewsLabel,
            postedAt: snap.postedAt,
            edited: snap.edited,
            permalink: snap.permalink,
            isRead: isRead,
            reply: snap.reply
        )
        context.insert(post)
        post.channel = channel
        for m in snap.media {
            let model = Media(from: m)
            context.insert(model)
            model.post = post
        }
        for r in snap.reactions {
            let model = Reaction(from: r)
            context.insert(model)
            model.post = post
        }
    }

    /// ID-based entry point called by `PostCard`, which holds a
    /// `PostDisplaySnapshot` (not the live model). Looks up the `Post` by
    /// id (an indexed `@Attribute(.unique)` column) and delegates to
    /// `markRead(_:)`. Not strictly O(1) — it's still a SwiftData query —
    /// but the dwell gate in `PostCard` rate-limits this to ~1 call per
    /// 600 ms per card, well below the threshold where the lookup would
    /// register on a scroll trace.
    func markRead(postID: String) {
        let descriptor = FetchDescriptor<Post>(predicate: #Predicate { $0.id == postID })
        guard let post = (try? context.fetch(descriptor))?.first else { return }
        markRead(post)
    }

    /// Mark a single post as read. No-op if already read. Decrements the
    /// cached `unreadCount` instead of re-querying SwiftData. Persistence
    /// is left to `mainContext`'s autosave — explicit `save()` here used
    /// to peg the main actor on scroll-driven calls and dropped frames
    /// during fast flings. The caller (`PostCard`) gates this behind a
    /// dwell timer, so the call rate is at most ~one per 600 ms per card.
    ///
    /// When `post` is the *latest* in its channel, this method also
    /// sweeps all older unread posts to `isRead = true`. That matches
    /// chat-app "you reached the latest, you're caught up" semantics:
    /// fast-scrolling past 9 unread posts to dwell on the 10th (newest)
    /// shouldn't leave the sidebar badge stuck at 9. The dwell on the
    /// latest is the trigger; the cascade is the catch-up.
    func markRead(_ post: Post) {
        guard !post.isRead else { return }
        post.isRead = true
        if post.channel?.isMuted != true {
            unreadCount = max(0, unreadCount - 1)
        }
        post.channel?.unreadCount = max(0, (post.channel?.unreadCount ?? 0) - 1)
        updateDockBadge()
        // Defer the sweep to the next run-loop turn so the current render
        // pass (which triggered this dwell callback) completes before we
        // fire up to N simultaneous isRead writes on the channel's posts.
        if let channel = post.channel, isLatestPost(post, in: channel) {
            Task { @MainActor [weak self] in
                self?.sweepOlderUnread(in: channel, latest: post)
                self?.updateDockBadge()
            }
        }
    }

    /// Whether `post` is the most recently `postedAt` post in `channel`.
    /// Uses the stored `channel.lastPostAt` for O(1) lookup rather than
    /// scanning all posts. If two posts share the same timestamp the cascade
    /// sweep fires twice — harmless.
    private func isLatestPost(_ post: Post, in channel: Channel) -> Bool {
        guard let postDate = post.postedAt, let latestDate = channel.lastPostAt else { return false }
        return postDate == latestDate
    }

    /// Sweep every still-unread post in `channel` to `isRead = true`,
    /// excluding `latest` (whose state was already flipped by the caller).
    /// Decrements the cached `unreadCount` by the sweep size in one batch
    /// rather than per-post — fewer observable mutations during the
    /// post-dwell window where the dock badge is about to refresh.
    private func sweepOlderUnread(in channel: Channel, latest: Post) {
        var swept = 0
        for other in channel.posts where !other.isRead && other.id != latest.id {
            other.isRead = true
            swept += 1
        }
        guard swept > 0 else { return }
        if !channel.isMuted {
            unreadCount = max(0, unreadCount - swept)
        }
        channel.unreadCount = max(0, channel.unreadCount - swept)
    }

    /// Mark every unread post in a channel as read in one batch. Resets
    /// the channel's stored `unreadCount` and updates the global dock-badge
    /// cache. Respects the muted flag: muted channels don't contribute to
    /// the global count.
    func markAllRead(_ channel: Channel) {
        let unread = channel.posts.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        for post in unread { post.isRead = true }
        let swept = unread.count
        channel.unreadCount = 0
        if !channel.isMuted {
            unreadCount = max(0, unreadCount - swept)
        }
        do {
            try context.save()
        } catch {
            AppLog.feed.error("[ChannelService] markAllRead save failed: \(error.localizedDescription, privacy: .public)")
        }
        updateDockBadge()
    }

    /// Toggle a channel's muted state. Muted channels keep refreshing and
    /// their per-channel unread count keeps incrementing — only the global
    /// dock-badge aggregation excludes them. Recomputes authoritatively
    /// because the aggregation rule, not just the data, changed.
    func setMuted(_ channel: Channel, _ muted: Bool) {
        guard channel.isMuted != muted else { return }
        channel.isMuted = muted
        do {
            try context.save()
        } catch {
            AppLog.mount.error("[ChannelService] setMuted save failed: \(error.localizedDescription, privacy: .public)")
        }
        recomputeUnreadCountAndBadge()
    }

    // MARK: - Dock badge

    /// Pushes the cached `unreadCount` onto the app's dock tile. Read from
    /// the in-memory cache, never SwiftData — `markRead` fires on every
    /// scroll-driven visibility change, and a `fetchCount` per call pegged
    /// the main actor on fast scrolls. Empty string clears the badge (an
    /// explicit "0" would leave a "0" pill on the icon).
    /// Recompute the global unread total from SwiftData and push it onto
    /// the dock badge if it actually changed. Used after operations that
    /// can shift unread aggregation in non-trivial ways (channel add /
    /// remove, full refresh, mute toggle) — the `markRead` hot path uses
    /// the incremental decrement instead, since per-scroll `fetchCount`s
    /// were pegging the main actor.
    private func recomputeUnreadCountAndBadge() {
        let fresh = Self.recomputeUnreadCount(in: context)
        guard fresh != unreadCount else { return }
        unreadCount = fresh
        updateDockBadge()
    }

    func updateDockBadge() {
        // `NSApp` is an implicitly-unwrapped optional that's only non-nil
        // after the AppKit runloop is up. Calls during `App.init` would
        // crash; calls during shutdown could too. Guard rather than bang.
        guard let app = NSApplication.shared as NSApplication? else { return }
        app.dockTile.badgeLabel = unreadCount > 0 ? String(unreadCount) : ""
    }

    /// Diff `post.media` against `snapshots` keyed by `(kind, assetURL)`.
    /// Equal keys are mutated in place so SwiftData / `@Observable` only
    /// re-emits when something actually changed; new keys are inserted,
    /// missing keys are deleted.
    private func replaceMedia(of post: Post, with snapshots: [MediaSnapshot]) {
        var existing: [String: Media] = [:]
        for media in post.media {
            existing[Self.mediaKey(kindRaw: media.kindRaw, assetURL: media.assetURL)] = media
        }

        var seen: Set<String> = []
        for snap in snapshots {
            let key = Self.mediaKey(kindRaw: snap.kind.rawValue, assetURL: snap.assetURL)
            seen.insert(key)
            if let current = existing[key] {
                // Update mutable scalars only when they actually changed —
                // assigning the same value still triggers SwiftData change
                // tracking, defeating the diff.
                if current.thumbnailURL != snap.thumbnailURL { current.thumbnailURL = snap.thumbnailURL }
                if current.durationLabel != snap.durationLabel { current.durationLabel = snap.durationLabel }
                if current.aspectRatio != snap.aspectRatio { current.aspectRatio = snap.aspectRatio }
            } else {
                let model = Media(from: snap)
                context.insert(model)
                model.post = post
            }
        }

        for (key, media) in existing where !seen.contains(key) {
            context.delete(media)
        }
    }

    /// Diff `post.reactions` against `snapshots` keyed by `emoji`. Counts
    /// change frequently; emoji set rarely. Mutating count in place avoids
    /// a delete+insert storm on every refresh.
    private func replaceReactions(of post: Post, with snapshots: [ReactionSnapshot]) {
        var existing: [String: Reaction] = [:]
        for reaction in post.reactions {
            existing[reaction.emoji] = reaction
        }

        var seen: Set<String> = []
        for snap in snapshots {
            seen.insert(snap.emoji)
            if let current = existing[snap.emoji] {
                if current.count != snap.count { current.count = snap.count }
            } else {
                let model = Reaction(from: snap)
                context.insert(model)
                model.post = post
            }
        }

        for (emoji, reaction) in existing where !seen.contains(emoji) {
            context.delete(reaction)
        }
    }

    private static func mediaKey(kindRaw: String, assetURL: URL?) -> String {
        // `assetURL` can legitimately be nil (e.g. a video poster with no
        // direct asset link) — bucket those together by kind alone.
        "\(kindRaw)|\(assetURL?.absoluteString ?? "")"
    }

    // MARK: - Fetch chain

    /// Result of a successful fetch.
    ///
    ///   - `.changed`: a new payload arrived — caller should upsert.
    ///   - `.unchanged`: mirror responded 304 Not Modified — caller should
    ///     bump `lastFetchedAt` but skip every other write. Only the mirror
    ///     transport can produce this; the GT proxy has no conditional-GET
    ///     story so it always returns `.changed`.
    private enum FetchOutcome {
        case changed(HTMLPostParser.ParseResult, source: FetchSource)
        case unchanged(source: FetchSource)
    }

    /// Fetch order:
    ///   1. Pigeon mirror snapshot on raw.githubusercontent.com (primary —
    ///      fast, fresh ~5min, hard to block, decodes our exact schema).
    ///      Sent with `If-None-Match` / `If-Modified-Since` from the last
    ///      successful response; a 304 short-circuits the upsert path.
    ///   2. Pinned GT proxy on `t-me.translate.goog` (fallback for channels
    ///      not yet mirrored, or when GitHub raw is unreachable). No
    ///      conditional-GET — the proxy doesn't expose validators we trust.
    ///
    /// We never attempt direct `t.me` per the project brief.
    private func fetch(username: String) async throws -> FetchOutcome {
        let (etag, lastModified) = validatorStore.validators(for: username)
        let mirrorBase = SettingsStore.defaultMirrorBaseURL
        AppLog.mirror.pub("[fetch] attempting mirror for <\(username)> etag=<\(etag ?? "nil")>")
        do {
            let mirror = try await client.fetchMirrorSnapshot(
                username: username,
                baseURL: mirrorBase,
                ifNoneMatch: etag,
                ifModifiedSince: lastModified
            )
            switch mirror {
            case .unchanged:
                AppLog.mirror.pub("[fetch] mirror 304 unchanged for <\(username)>")
                return .unchanged(source: .mirror)
            case .fresh(let data, let newETag, let newLastModified):
                AppLog.mirror.pub("[fetch] mirror 200 for <\(username)> bytes=<\(data.count)>")
                do {
                    let result = try jsonDecoder.decode(data, mirrorBaseURL: mirrorBase)
                    validatorStore.persist(
                        username: username,
                        etag: newETag,
                        lastModified: newLastModified
                    )
                    schemaOutdated = false
                    AppLog.mirror.pub("[fetch] mirror decoded <\(result.posts.count)> posts for <\(username)>")
                    return .changed(result, source: .mirror)
                } catch let error as JSONFeedDecoder.DecodeError {
                    if case .unsupportedSchema = error {
                        // Newer schema than this build understands — surface
                        // a banner and fall through to GT so reading isn't blocked.
                        schemaOutdated = true
                        AppLog.mirror.pub("[fetch] mirror unsupported schema for <\(username)>, falling through to GT")
                    } else {
                        // Malformed JSON — clear validators so the next request
                        // isn't a conditional GET against broken data.
                        validatorStore.persist(username: username, etag: nil, lastModified: nil)
                        AppLog.mirror.pub("[fetch] mirror decode error for <\(username)>: \(error.localizedDescription)")
                    }
                } catch {
                    validatorStore.persist(username: username, etag: nil, lastModified: nil)
                    AppLog.mirror.pub("[fetch] mirror decode error for <\(username)>: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Mirror unreachable or returned unexpected status — fall through to GT.
            AppLog.mirror.pub("[fetch] mirror failed for <\(username)>: \(error.localizedDescription), falling through to GT")
        }

        AppLog.net.pub("[fetch] trying GT proxy for <\(username)>")
        let page = try await client.fetchChannelPage(username: username)
        AppLog.net.pub("[fetch] GT proxy succeeded for <\(username)> via method=<\(page.method.rawValue)>")
        let result = try parser.parse(page.html, fallbackUsername: username)
        AppLog.net.pub("[fetch] parsed <\(result.posts.count)> posts from GT for <\(username)>")
        return .changed(result, source: .gt)
    }

    /// Sum unread posts across non-muted channels. Channel-first (rather
    /// than a `Post` predicate that traverses the optional `channel`
    /// relationship) sidesteps `#Predicate` macro brittleness around
    /// `?.` + `??` chains. Dataset is small (dozens of channels), so the
    /// in-memory sum is fine.
    private static func recomputeUnreadCount(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { !$0.isMuted })
        let channels = (try? context.fetch(descriptor)) ?? []
        return channels.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Auto-refresh loop

    /// Periodic background ticker. Wakes every `autoRefreshTickInterval`
    /// (30 s) and delegates the actual sweep to `refreshAll(force:
    /// false)` — same code path the manual button uses, just with the
    /// per-source TTL gate engaged so we don't hammer upstream.
    ///
    /// Continues running while the app process is alive — including when
    /// all windows are closed — so the dock badge stays current.
    private func startAutoRefreshLoop() {
        autoRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshTickInterval)
                guard let self, !Task.isCancelled else { return }
                self.refreshAll(force: false)
            }
        }
    }

    /// Fetch `health.json` and replace `mirrorHealth` on success. A failure
    /// (network blip, 404 in the brief window before the first sweep ever
    /// runs, schema skew) leaves the previous value untouched — better to
    /// show a slightly stale stamp than to flicker the footer back to
    /// "never". The sidebar's staleness colouring already turns red past
    /// 30 min, which is the real signal a user needs.
    private func refreshMirrorHealth() async {
        do {
            mirrorHealth = try await client.fetchMirrorHealth(
                baseURL: SettingsStore.defaultMirrorBaseURL
            )
        } catch {
            // health.json is decorative — don't surface to the UI. But a
            // persistent failure is worth knowing about (mirror relocated,
            // schema skew, network down for the whole device) so the next
            // person debugging "why is the staleness footer stuck" has a
            // breadcrumb.
            AppLog.mirror.pub("[ChannelService] health fetch failed: \(error.localizedDescription)")
        }
    }
}
