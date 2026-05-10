import Foundation
import SwiftData

struct ReactionSnapshot: Identifiable, Hashable, Sendable {
    var id: String { emoji }
    let emoji: String
    let count: String
}

@Model
final class Reaction: Identifiable {
    var emoji: String
    var count: String
    var post: Post?

    init(emoji: String, count: String) {
        self.emoji = emoji
        self.count = count
    }

    convenience init(from snapshot: ReactionSnapshot) {
        self.init(emoji: snapshot.emoji, count: snapshot.count)
    }
}
