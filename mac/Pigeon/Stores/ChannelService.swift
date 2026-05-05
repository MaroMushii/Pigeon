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

    @ObservationIgnored private let client: TelegramClient
    @ObservationIgnored private let parser = HTMLPostParser()
    @ObservationIgnored private let jsonDecoder = JSONFeedDecoder()
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init(client: TelegramClient, context: ModelContext) {
        self.client = client
        self.context = context
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

        let outcome: FetchOutcome
        do {
            outcome = try await fetch(username: username)
        } catch {
            throw AddError.fetchFailed(underlying: error)
        }

        let channel = Channel(
            username: outcome.result.channel.username,
            displayName: outcome.result.channel.title,
            photoURL: outcome.result.channel.photoURL,
            channelDescription: outcome.result.channel.descriptionHTML,
            subscriberCount: outcome.result.channel.subscriberCount
        )
        channel.lastFetchedAt = .now
        channel.lastFetchSource = outcome.source.rawValue
        context.insert(channel)
        // Initial posts are marked read — the user is actively viewing the
        // channel they just added; they shouldn't see a fresh unread badge
        // for content they explicitly chose to subscribe to.
        upsertPosts(outcome.result.posts, into: channel, markNewAsRead: true)
        try context.save()
        updateDockBadge()
        return channel
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
            channel.displayName = outcome.result.channel.title
            channel.photoURL = outcome.result.channel.photoURL ?? channel.photoURL
            channel.channelDescription = outcome.result.channel.descriptionHTML ?? channel.channelDescription
            channel.subscriberCount = outcome.result.channel.subscriberCount ?? channel.subscriberCount
            channel.lastFetchedAt = .now
            channel.lastFetchSource = outcome.source.rawValue
            upsertPosts(outcome.result.posts, into: channel)
            try context.save()
            updateDockBadge()
            lastError = nil
            return channel.posts
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
        context.delete(channel)
        try? context.save()
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

    /// Persist `isRead = true` for a single post. Cheap save; called from
    /// the feed's onScrollVisibilityChange hook. No-op if already read.
    func markRead(_ post: Post) {
        guard !post.isRead else { return }
        post.isRead = true
        try? context.save()
        updateDockBadge()
    }

    // MARK: - Dock badge

    /// Recomputes the total unread post count across all channels and sets
    /// it on the app's dock tile. Called after every successful refresh,
    /// addChannel, and markRead — anywhere `isRead` or the post set can
    /// change. Empty string clears the badge (an explicit "0" would leave
    /// a "0" pill on the icon).
    func updateDockBadge() {
        // `NSApp` is an implicitly-unwrapped optional that's only non-nil
        // after the AppKit runloop is up. Calls during `App.init` would
        // crash; calls during shutdown could too. Guard rather than bang.
        guard let app = NSApplication.shared as NSApplication? else { return }
        let descriptor = FetchDescriptor<Post>(predicate: #Predicate { !$0.isRead })
        let count = (try? context.fetchCount(descriptor)) ?? 0
        app.dockTile.badgeLabel = count > 0 ? String(count) : ""
    }

    private func replaceMedia(of post: Post, with snapshots: [MediaSnapshot]) {
        for old in post.media { context.delete(old) }
        for snap in snapshots {
            let model = Media(from: snap)
            context.insert(model)
            model.post = post
        }
    }

    private func replaceReactions(of post: Post, with snapshots: [ReactionSnapshot]) {
        for old in post.reactions { context.delete(old) }
        for snap in snapshots {
            let model = Reaction(from: snap)
            context.insert(model)
            model.post = post
        }
    }

    // MARK: - Fetch chain

    /// Result of a successful fetch, carrying both the parsed payload and
    /// which transport produced it. Source drives the auto-refresh cadence
    /// — see `FetchSource.refreshInterval`.
    private struct FetchOutcome {
        let result: HTMLPostParser.ParseResult
        let source: FetchSource
    }

    /// Fetch order:
    ///   1. Pigeon mirror snapshot on raw.githubusercontent.com (primary —
    ///      fast, fresh ~5min, hard to block, decodes our exact schema).
    ///   2. Pinned GT proxy on `t-me.translate.goog` (fallback for channels
    ///      not yet mirrored, or when GitHub raw is unreachable).
    ///
    /// We never attempt direct `t.me` per the project brief.
    private func fetch(username: String) async throws -> FetchOutcome {
        if let data = try? await client.fetchMirrorSnapshot(username: username) {
            do {
                let result = try jsonDecoder.decode(data)
                return FetchOutcome(result: result, source: .mirror)
            } catch {
                // Mirror returned malformed JSON — drop through to live fetch.
            }
        }

        let page = try await client.fetchChannelPage(username: username)
        let result = try parser.parse(page.html, fallbackUsername: username)
        return FetchOutcome(result: result, source: .gt)
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
