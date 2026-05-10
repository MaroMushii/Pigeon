import Foundation
import SwiftData

/// Value-type snapshot of a `Post` for the feed UI. `PostCard` takes this
/// instead of the live `@Model` so SwiftUI cannot observe individual
/// property mutations (reaction counts, viewsLabel) during refresh and
/// issue re-renders mid-scroll. Cards only re-render when the parent
/// explicitly rebuilds the snapshot array via `recomputeSortedPosts`.
struct PostDisplaySnapshot: Identifiable, Equatable {
    let id: String
    let channelUsername: String
    let bodyHTML: String
    let plainText: String
    let isRead: Bool
    let postedAt: Date?
    let edited: Bool
    let viewsLabel: String?
    let permalink: URL?
    let media: [MediaSnapshot]
    let reactions: [ReactionSnapshot]
}

extension Post {
    func displaySnapshot() -> PostDisplaySnapshot {
        PostDisplaySnapshot(
            id: id,
            channelUsername: channelUsername,
            bodyHTML: bodyHTML,
            plainText: plainText,
            isRead: isRead,
            postedAt: postedAt,
            edited: edited,
            viewsLabel: viewsLabel,
            permalink: permalink,
            media: media.map {
                MediaSnapshot(
                    kind: $0.kind,
                    assetURL: $0.assetURL,
                    thumbnailURL: $0.thumbnailURL,
                    durationLabel: $0.durationLabel,
                    aspectRatio: $0.aspectRatio
                )
            },
            reactions: reactions.map { ReactionSnapshot(emoji: $0.emoji, count: $0.count) }
        )
    }
}

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
        if authorName != snapshot.authorName { authorName = snapshot.authorName }
        if authorPhotoURL != snapshot.authorPhotoURL { authorPhotoURL = snapshot.authorPhotoURL }
        if bodyHTML != snapshot.bodyHTML { bodyHTML = snapshot.bodyHTML }
        if plainText != snapshot.plainText { plainText = snapshot.plainText }
        if viewsLabel != snapshot.viewsLabel { viewsLabel = snapshot.viewsLabel }
        if postedAt != snapshot.postedAt { postedAt = snapshot.postedAt }
        if edited != snapshot.edited { edited = snapshot.edited }
        if permalink != snapshot.permalink { permalink = snapshot.permalink }
    }
}
