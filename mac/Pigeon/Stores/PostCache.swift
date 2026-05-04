import Foundation

/// In-memory cache of parsed posts per channel, with a TTL.
/// Single source of truth for post lists shown in the UI.
@MainActor
@Observable
final class PostCache {
    struct Bucket {
        var posts: [Post]
        var fetchedAt: Date
        var channelInfo: HTMLPostParser.ChannelInfo
    }

    private(set) var buckets: [String: Bucket] = [:]
    var ttl: TimeInterval = 60 * 15  // 15 minutes

    func bucket(for username: String) -> Bucket? {
        buckets[username.lowercased()]
    }

    func isFresh(_ username: String) -> Bool {
        guard let b = buckets[username.lowercased()] else { return false }
        return Date.now.timeIntervalSince(b.fetchedAt) < ttl
    }

    func store(_ result: HTMLPostParser.ParseResult) {
        buckets[result.channel.username] = Bucket(
            posts: result.posts,
            fetchedAt: .now,
            channelInfo: result.channel
        )
    }

    func evict(_ username: String) {
        buckets.removeValue(forKey: username.lowercased())
    }
}
