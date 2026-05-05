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

    init(client: TelegramClient, context: ModelContext) {
        self.client = client
        self.context = context
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

        let result: HTMLPostParser.ParseResult
        do {
            result = try await fetch(username: username)
        } catch {
            throw AddError.fetchFailed(underlying: error)
        }

        let channel = Channel(
            username: result.channel.username,
            displayName: result.channel.title,
            photoURL: result.channel.photoURL,
            channelDescription: result.channel.descriptionHTML,
            subscriberCount: result.channel.subscriberCount
        )
        channel.lastFetchedAt = .now
        context.insert(channel)
        upsertPosts(result.posts, into: channel)
        try context.save()
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
            let result = try await fetch(username: username)
            channel.displayName = result.channel.title
            channel.photoURL = result.channel.photoURL ?? channel.photoURL
            channel.channelDescription = result.channel.descriptionHTML ?? channel.channelDescription
            channel.subscriberCount = result.channel.subscriberCount ?? channel.subscriberCount
            channel.lastFetchedAt = .now
            upsertPosts(result.posts, into: channel)
            try context.save()
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
    private func upsertPosts(_ snapshots: [PostSnapshot], into channel: Channel) {
        var existingByID: [String: Post] = [:]
        for p in channel.posts { existingByID[p.id] = p }

        for snap in snapshots {
            if let existing = existingByID[snap.id] {
                existing.updateScalars(from: snap)
                replaceMedia(of: existing, with: snap.media)
                replaceReactions(of: existing, with: snap.reactions)
            } else {
                insertNewPost(from: snap, into: channel)
            }
        }
    }

    private func insertNewPost(from snap: PostSnapshot, into channel: Channel) {
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
            permalink: snap.permalink
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

    /// Fetch order:
    ///   1. Pigeon mirror snapshot on raw.githubusercontent.com (primary —
    ///      fast, fresh ~2min, hard to block, decodes our exact schema).
    ///   2. Pinned GT proxy on `t-me.translate.goog` (fallback for channels
    ///      not yet mirrored, or when GitHub raw is unreachable).
    ///
    /// We never attempt direct `t.me` per the project brief.
    private func fetch(username: String) async throws -> HTMLPostParser.ParseResult {
        if let data = try? await client.fetchMirrorSnapshot(username: username) {
            do {
                return try jsonDecoder.decode(data)
            } catch {
                // Mirror returned malformed JSON — drop through to live fetch.
            }
        }

        let page = try await client.fetchChannelPage(username: username)
        return try parser.parse(page.html, fallbackUsername: username)
    }
}
