import Foundation
import SwiftData

/// Coordinates SwiftData persistence + remote fetches for channels.
/// Always invoked from the main actor — SwiftData's ModelContext is
/// not Sendable and must stay on a single isolation domain.
@MainActor
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

    private let client: TelegramClient
    private let parser = HTMLPostParser()
    private let jsonDecoder = JSONFeedDecoder()
    private let cache: PostCache

    init(client: TelegramClient, cache: PostCache) {
        self.client = client
        self.cache = cache
    }

    /// Add a new channel: validates the username, fetches the page, parses
    /// metadata, persists a `Channel` row, primes the post cache.
    func addChannel(rawIdentifier: String, in context: ModelContext) async throws -> Channel {
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
        try context.save()

        cache.store(result)
        return channel
    }

    /// Refresh an existing channel's posts and metadata in place.
    @discardableResult
    func refresh(_ channel: Channel) async throws -> [Post] {
        let result = try await fetch(username: channel.username)
        channel.displayName = result.channel.title
        channel.photoURL = result.channel.photoURL ?? channel.photoURL
        channel.channelDescription = result.channel.descriptionHTML ?? channel.channelDescription
        channel.subscriberCount = result.channel.subscriberCount ?? channel.subscriberCount
        channel.lastFetchedAt = .now
        cache.store(result)
        return result.posts
    }

    /// Returns cached posts if fresh; otherwise fetches and caches.
    func postsForDisplay(_ channel: Channel, forceRefresh: Bool = false) async throws -> [Post] {
        if !forceRefresh, cache.isFresh(channel.username),
           let bucket = cache.bucket(for: channel.username) {
            return bucket.posts
        }
        return try await refresh(channel)
    }

    func remove(_ channel: Channel, in context: ModelContext) {
        cache.evict(channel.username)
        context.delete(channel)
        try? context.save()
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
