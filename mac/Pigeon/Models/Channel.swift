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
    }
}

extension Channel {
    var publicURL: URL {
        URL(string: "https://t.me/\(username)")!
    }
}
