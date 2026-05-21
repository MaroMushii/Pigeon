import Foundation

/// Curated list of popular Persian-language channels surfaced as chips
/// inside `AddChannelSheet`. The mirror backfills these on its first
/// scrape, so they load instantly from `raw.githubusercontent.com` —
/// hence the "pre-cached" copy in the sheet.
/// Username is the join key everywhere — bundled avatar filename, chip
/// label (rendered as `@username`), mirror snapshot path. The
/// post-subscription title comes from the mirror snapshot via
/// `ChannelService`, so there's no separate display name to maintain in
/// the catalogue.
struct PopularChannelInfo: Sendable, Hashable {
    let username: String

    /// Bundled avatar lives at
    /// `Resources/popular-channel-avatars/<username>.jpg` by convention.
    /// Every popular channel is expected to ship one — the chip view's
    /// initials fallback exists only to keep the build from cratering
    /// while the avatar set is being filled in.
    var avatarFilename: String { "\(username).jpg" }
}

/// Owns the static catalogue of popular channels and the transient
/// "currently being added" set used by `PopularChannelChips`. Scoped to
/// the main actor — chip taps mutate inflight state synchronously while
/// the async add runs.
///
/// The catalogue lives in `Resources/popular-channels.json` so it can be
/// curated without a recompile and so non-engineers can edit the list.
@MainActor
@Observable
final class PopularChannelsStore {
    /// Channels currently mid-add. Drives the chip's spinner state.
    var inflight: Set<String> = []

    @ObservationIgnored
    let channels: [PopularChannelInfo] = PopularChannelsStore.loadCatalogue()

    /// Read the bundled JSON catalogue. A missing or corrupt resource is a
    /// build-time failure, not a runtime one — the file ships inside the
    /// app bundle, so if it's gone the install is broken in a way the
    /// user can't recover from. Fail loud rather than silently surfacing
    /// an empty grid.
    private static func loadCatalogue() -> [PopularChannelInfo] {
        guard let url = Bundle.main.url(forResource: "popular-channels", withExtension: "json") else {
            fatalError("popular-channels.json missing from app bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let usernames = try JSONDecoder().decode([String].self, from: data)
            return usernames.map { PopularChannelInfo(username: $0) }
        } catch {
            fatalError("popular-channels.json failed to decode: \(error)")
        }
    }

    func markInflight(_ username: String) {
        inflight.insert(username)
    }

    func clearInflight(_ username: String) {
        inflight.remove(username)
    }

    func isInflight(_ username: String) -> Bool {
        inflight.contains(username)
    }
}
