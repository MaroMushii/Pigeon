import Foundation
import SwiftData
@testable import Pigeon

/// Spin up a fresh in-memory `ModelContainer` with the same schema the
/// app uses. Each test should call this in `setUp` so tests can't see
/// each other's persisted data.
@MainActor
enum InMemoryModelContainer {
    static func make() throws -> ModelContainer {
        let schema = Schema([Channel.self, Post.self, Media.self, Reaction.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Helper to insert a `Channel` with sensible defaults so the test
    /// body doesn't drown in init parameters it doesn't care about.
    static func insertChannel(
        username: String,
        in context: ModelContext,
        lastFetchedAt: Date? = nil
    ) -> Channel {
        let channel = Channel(
            username: username,
            displayName: username,
            photoURL: nil,
            channelDescription: nil,
            subscriberCount: nil
        )
        channel.lastFetchedAt = lastFetchedAt
        context.insert(channel)
        try? context.save()
        return channel
    }
}
