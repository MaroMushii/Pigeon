import Foundation
import SwiftData

@Model
final class Channel {
    @Attribute(.unique) var username: String
    var displayName: String
    var photoURL: String?
    var channelDescription: String?
    var subscriberCount: String?
    var addedAt: Date
    var lastFetchedAt: Date?
    /// Which transport last successfully populated this channel. Drives the
    /// auto-refresh cadence: mirror channels poll every 5 min, GT-proxy
    /// channels every 2 min (matching their respective upstream freshness).
    /// `nil` until the first successful fetch — treated as `.mirror` for
    /// scheduling purposes.
    var lastFetchSource: FetchSource.RawValue?
    @Relationship(deleteRule: .cascade, inverse: \Post.channel)
    var posts: [Post] = []

    init(
        username: String,
        displayName: String,
        photoURL: String? = nil,
        channelDescription: String? = nil,
        subscriberCount: String? = nil
    ) {
        self.username = username.lowercased()
        self.displayName = displayName
        self.photoURL = photoURL
        self.channelDescription = channelDescription
        self.subscriberCount = subscriberCount
        self.addedAt = .now
        self.lastFetchedAt = nil
        self.lastFetchSource = nil
    }
}

extension Channel {
    var publicURL: URL {
        URL(string: "https://t.me/\(username)")!
    }

    var fetchSource: FetchSource {
        lastFetchSource.flatMap(FetchSource.init(rawValue:)) ?? .mirror
    }

    var unreadCount: Int {
        posts.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }
}

/// Which transport produced the channel's most recent successful fetch.
enum FetchSource: String, Sendable {
    case mirror   // raw.githubusercontent.com snapshot
    case gt       // pinned-IP t-me.translate.goog

    /// Auto-refresh interval in seconds. Mirror cron updates ~every 5 min;
    /// GT proxy is real-time so we can poll more aggressively (2 min).
    var refreshInterval: TimeInterval {
        switch self {
        case .mirror: 60 * 5
        case .gt: 60 * 2
        }
    }
}
