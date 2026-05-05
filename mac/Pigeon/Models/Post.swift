import Foundation
import SwiftData

/// Transient parser/decoder output for a single post. `Sendable`, no
/// SwiftData dependency. Persisted to disk by upserting into a
/// `Post` (`@Model`) on the main actor.
struct PostSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let channelUsername: String
    let authorName: String
    let authorPhotoURL: String?
    let bodyHTML: String
    let plainText: String
    let media: [MediaSnapshot]
    let reactions: [ReactionSnapshot]
    let viewsLabel: String?
    let postedAt: Date?
    let edited: Bool
    let permalink: URL?
}

/// Persistent post record. Survives app relaunch so cold starts can show
/// last-known feed instantly while a refresh runs in the background.
@Model
final class Post {
    /// `data-post` attribute from t.me, e.g. `"durov/123"`. Globally unique
    /// across channels — safe to mark unique.
    @Attribute(.unique) var id: String
    var channelUsername: String
    var authorName: String
    var authorPhotoURL: String?
    var bodyHTML: String
    var plainText: String
    @Relationship(deleteRule: .cascade, inverse: \Media.post)
    var media: [Media] = []
    @Relationship(deleteRule: .cascade, inverse: \Reaction.post)
    var reactions: [Reaction] = []
    var viewsLabel: String?
    var postedAt: Date?
    var edited: Bool
    var permalink: URL?
    /// `false` until the post scrolls into view in the feed. Drives the
    /// per-channel unread count and the dock-tile badge total. New posts
    /// arriving via auto-refresh start as unread; posts captured during
    /// `addChannel` are marked read on insert (the user is actively
    /// adding the channel and is about to see them).
    var isRead: Bool
    var channel: Channel?

    init(
        id: String,
        channelUsername: String,
        authorName: String,
        authorPhotoURL: String? = nil,
        bodyHTML: String,
        plainText: String,
        viewsLabel: String? = nil,
        postedAt: Date? = nil,
        edited: Bool = false,
        permalink: URL? = nil,
        isRead: Bool = false
    ) {
        self.id = id
        self.channelUsername = channelUsername
        self.authorName = authorName
        self.authorPhotoURL = authorPhotoURL
        self.bodyHTML = bodyHTML
        self.plainText = plainText
        self.viewsLabel = viewsLabel
        self.postedAt = postedAt
        self.edited = edited
        self.permalink = permalink
        self.isRead = isRead
    }

    /// Mutate self with the latest snapshot. Caller is responsible for
    /// rebuilding the `media` / `reactions` relationship arrays — they
    /// require a `ModelContext` to insert child rows and are easier to
    /// handle outside this method.
    func updateScalars(from snapshot: PostSnapshot) {
        authorName = snapshot.authorName
        authorPhotoURL = snapshot.authorPhotoURL
        bodyHTML = snapshot.bodyHTML
        plainText = snapshot.plainText
        viewsLabel = snapshot.viewsLabel
        postedAt = snapshot.postedAt
        edited = snapshot.edited
        permalink = snapshot.permalink
    }
}
