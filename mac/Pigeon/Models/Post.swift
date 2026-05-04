import Foundation

struct Post: Identifiable, Hashable, Sendable {
    let id: String
    let channelUsername: String
    let authorName: String
    let authorPhotoURL: String?
    let bodyHTML: String
    let plainText: String
    let media: [Media]
    let reactions: [Reaction]
    let viewsLabel: String?
    let postedAt: Date?
    let edited: Bool
    let permalink: URL?

    var hasMedia: Bool { !media.isEmpty }

    var firstMediaThumbnail: URL? {
        media.first?.thumbnailURL ?? media.first?.assetURL
    }
}
