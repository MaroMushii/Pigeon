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
        case fetchFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidUsername: "That doesn't look like a Telegram channel."
            case .alreadyExists(let name): "“\(name)” is already in your sidebar."
            case .fetchFailed(let e): "Couldn't load channel: \(e.localizedDescription)"
            }
        }
    }

    /// Snapshot of the most recent refresh failure, surfaced in the UI
    /// (toolbar warning + popover) until cleared on success or dismissed.
    struct ChannelError: Sendable {
        let channel: String
        let message: String
        let at: Date
    }

    /// 15-minute freshness window before a channel auto-refetches on
    /// selection. Manual refresh (⌘R) always bypasses this.
    static let freshnessTTL: TimeInterval = 60 * 15

    /// How often the auto-refresh loop wakes and re-evaluates which
    /// channels are due. Each channel has its own per-source interval
    /// (see `FetchSource.refreshInterval`); this is just the polling
    /// granularity. 30s gives a worst-case 30s overshoot which is fine.
    static let autoRefreshTickInterval: Duration = .seconds(30)

    /// Channels with an in-flight network refresh. Views render a
    /// spinner when their channel's username is in this set.
    var inflight: Set<String> = []

    /// Most recent refresh failure across any channel. Nil after a
    /// successful refresh or an explicit `clearLastError()`.
    var lastError: ChannelError?

    /// True when the mirror returned a snapshot whose schema version is
    /// newer than this build understands. We fall back to the GT path so
    /// the user keeps reading; the sidebar surfaces a banner suggesting
    /// an app update. Cleared on the next successful mirror decode in
    /// case a server-side rollback resolves the skew.
    private(set) var schemaOutdated: Bool = false

    /// Cached unread-post count across all channels. Mirrors what the dock
    /// badge displays. Maintained incrementally on `markRead` and
    /// recomputed authoritatively on add/refresh/remove. Reading SwiftData
    /// from `updateDockBadge` on every scroll-induced markRead pegged the
    /// main actor; this cache makes the hot path O(1).
    private(set) var unreadCount: Int = 0

    @ObservationIgnored private let client: TelegramClient
    @ObservationIgnored private let parser = HTMLPostParser()
    @ObservationIgnored private let jsonDecoder = JSONFeedDecoder()
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults = .standard

    init(client: TelegramClient, context: ModelContext) {
        self.client = client
        self.context = context
        self.unreadCount = Self.recomputeUnreadCount(in: context)
        startAutoRefreshLoop()
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    func clearLastError() {
        lastError = nil
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
        clearMirrorValidators(username: username)

        let outcome: FetchOutcome
        do {
            outcome = try await fetch(username: username)
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
        unreadCount = Self.recomputeUnreadCount(in: context)
        updateDockBadge()
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
    /// clears `lastError` on success, sets it on throw.
    @discardableResult
    func refresh(_ channel: Channel) async throws -> [Post] {
        let username = channel.username
        inflight.insert(username)
        defer { inflight.remove(username) }
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
                lastError = nil
                return channel.posts
            case .changed(let result, let source):
                channel.displayName = result.channel.title
                channel.photoURL = result.channel.photoURL ?? channel.photoURL
                channel.channelDescription = result.channel.descriptionHTML ?? channel.channelDescription
                channel.subscriberCount = result.channel.subscriberCount ?? channel.subscriberCount
                channel.lastFetchedAt = .now
                channel.lastFetchSource = source.rawValue
                upsertPosts(result.posts, into: channel)
                try context.save()
                unreadCount = Self.recomputeUnreadCount(in: context)
                updateDockBadge()
                lastError = nil
                return channel.posts
            }
        } catch {
            lastError = ChannelError(
                channel: username,
                message: error.localizedDescription,
                at: .now
            )
            throw error
        }
    }

    /// Returns persisted posts if the channel was fetched within the
    /// freshness TTL; otherwise refreshes from network and returns the
    /// merged set. Cache-hit path doesn't touch `inflight`/`lastError`.
    func postsForDisplay(_ channel: Channel, forceRefresh: Bool = false) async throws -> [Post] {
        if !forceRefresh, isFresh(channel) {
            return channel.posts
        }
        return try await refresh(channel)
    }

    func remove(_ channel: Channel) {
        clearMirrorValidators(username: channel.username)
        context.delete(channel)
        try? context.save()
        unreadCount = Self.recomputeUnreadCount(in: context)
        updateDockBadge()
    }

    func isFresh(_ channel: Channel) -> Bool {
        guard let last = channel.lastFetchedAt else { return false }
        return Date.now.timeIntervalSince(last) < Self.freshnessTTL
    }

    // MARK: - Upsert

    /// Merge `snapshots` into `channel.posts`. Existing posts (matched by
    /// `id`) are updated in place; previously persisted posts not in this
    /// snapshot are preserved — `t.me/s/<channel>` only returns the most
    /// recent ~20 posts, so absence is not deletion. Eviction is a future
    /// concern.
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
            isRead: isRead
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
        // Muted-channel posts never contributed to `unreadCount`, so a
        // decrement here would break the cache. `!= true` matches the
        // prior unconditional decrement for orphan posts (nil channel).
        if post.channel?.isMuted != true {
            unreadCount = max(0, unreadCount - 1)
        }

        if let channel = post.channel, isLatestPost(post, in: channel) {
            sweepOlderUnread(in: channel, latest: post)
        }

        updateDockBadge()
    }

    /// Whether `post` is the most recently `postedAt` post in `channel`.
    /// Posts with a nil `postedAt` can never be "the latest" — ranking
    /// them as `.distantPast` keeps them from poisoning the comparison.
    private func isLatestPost(_ post: Post, in channel: Channel) -> Bool {
        let latest = channel.posts.max {
            ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast)
        }
        return latest?.id == post.id
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
    }

    /// Toggle a channel's muted state. Muted channels keep refreshing and
    /// their per-channel unread count keeps incrementing — only the global
    /// dock-badge aggregation excludes them. Recomputes authoritatively
    /// because the aggregation rule, not just the data, changed.
    func setMuted(_ channel: Channel, _ muted: Bool) {
        guard channel.isMuted != muted else { return }
        channel.isMuted = muted
        try? context.save()
        unreadCount = Self.recomputeUnreadCount(in: context)
        updateDockBadge()
    }

    // MARK: - Dock badge

    /// Pushes the cached `unreadCount` onto the app's dock tile. Read from
    /// the in-memory cache, never SwiftData — `markRead` fires on every
    /// scroll-driven visibility change, and a `fetchCount` per call pegged
    /// the main actor on fast scrolls. Empty string clears the badge (an
    /// explicit "0" would leave a "0" pill on the icon).
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
        let etag = defaults.string(forKey: Self.etagKey(username))
        let lastModified = defaults.string(forKey: Self.lastModifiedKey(username))
        let mirrorBase = SettingsStore.defaultMirrorBaseURL
        if let mirror = try? await client.fetchMirrorSnapshot(
            username: username,
            baseURL: mirrorBase,
            ifNoneMatch: etag,
            ifModifiedSince: lastModified
        ) {
            switch mirror {
            case .unchanged:
                return .unchanged(source: .mirror)
            case .fresh(let data, let newETag, let newLastModified):
                do {
                    let result = try jsonDecoder.decode(data, mirrorBaseURL: mirrorBase)
                    persistMirrorValidators(
                        username: username,
                        etag: newETag,
                        lastModified: newLastModified
                    )
                    // Successful mirror decode — clear any stale skew flag in
                    // case the server rolled back to a supported schema.
                    schemaOutdated = false
                    return .changed(result, source: .mirror)
                } catch let error as JSONFeedDecoder.DecodeError {
                    if case .unsupportedSchema = error {
                        // Mirror runs a newer schema than this build
                        // understands. Surface a banner and drop through to
                        // GT so reading isn't blocked.
                        schemaOutdated = true
                    } else {
                        // Malformed JSON — clear validators so we don't keep
                        // sending stale ones, then fall through to the GT
                        // proxy.
                        persistMirrorValidators(username: username, etag: nil, lastModified: nil)
                    }
                } catch {
                    // Other (transport) errors — fall through to GT.
                    persistMirrorValidators(username: username, etag: nil, lastModified: nil)
                }
            }
        }

        let page = try await client.fetchChannelPage(username: username)
        let result = try parser.parse(page.html, fallbackUsername: username)
        return .changed(result, source: .gt)
    }

    private static func etagKey(_ username: String) -> String {
        "mirror.etag.\(username.lowercased())"
    }

    private static func lastModifiedKey(_ username: String) -> String {
        "mirror.lastModified.\(username.lowercased())"
    }

    private func persistMirrorValidators(
        username: String,
        etag: String?,
        lastModified: String?
    ) {
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

    private func clearMirrorValidators(username: String) {
        defaults.removeObject(forKey: Self.etagKey(username))
        defaults.removeObject(forKey: Self.lastModifiedKey(username))
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

    /// Periodic background refresh. Wakes every `autoRefreshTickInterval`
    /// (30s), enumerates all channels, and refreshes any whose
    /// `lastFetchedAt` is older than its source-specific interval
    /// (mirror: 5 min, GT: 2 min). Refreshes run sequentially to avoid
    /// hammering either upstream and to keep the main actor responsive
    /// across the SwiftData mutations the refresh performs.
    ///
    /// Continues running while the app process is alive — including when
    /// all windows are closed — so the dock badge stays current.
    private func startAutoRefreshLoop() {
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshTickInterval)
                guard !Task.isCancelled else { return }
                await self?.tickAutoRefresh()
            }
        }
    }

    private func tickAutoRefresh() async {
        let descriptor = FetchDescriptor<Channel>()
        guard let channels = try? context.fetch(descriptor) else { return }

        let now = Date.now
        for channel in channels {
            if Task.isCancelled { return }
            let interval = channel.fetchSource.refreshInterval
            let due: Bool
            if let last = channel.lastFetchedAt {
                due = now.timeIntervalSince(last) >= interval
            } else {
                due = true
            }
            guard due, !inflight.contains(channel.username) else { continue }
            // Failures are surfaced via `lastError` inside `refresh`. The
            // loop deliberately swallows the throw so one bad channel can't
            // stall the others.
            _ = try? await refresh(channel)
        }
    }
}
