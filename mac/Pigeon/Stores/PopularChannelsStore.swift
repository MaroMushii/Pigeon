import Foundation

/// Curated list of popular Persian-language channels surfaced as chips
/// inside `AddChannelSheet`. The mirror backfills these on its first
/// scrape, so they load instantly from `raw.githubusercontent.com` —
/// hence the "pre-cached" copy in the sheet.
struct PopularChannelInfo: Sendable, Hashable {
    let username: String
    let displayName: String
}

/// Owns the static catalogue of popular channels and the transient
/// "currently being added" set used by `PopularChannelChips`. Scoped to
/// the main actor — chip taps mutate inflight state synchronously while
/// the async add runs.
@MainActor
@Observable
final class PopularChannelsStore {
    /// Channels currently mid-add. Drives the chip's spinner state.
    var inflight: Set<String> = []

    @ObservationIgnored
    let channels: [PopularChannelInfo] = [
        .init(username: "vahidonline",   displayName: "Vahid Online"),
        .init(username: "bbcpersian",    displayName: "BBC Persian"),
        .init(username: "iranintltv",    displayName: "Iran International"),
        .init(username: "farsivoa",      displayName: "Farsi VOA"),
        .init(username: "radiofarda",    displayName: "Radio Farda"),
        .init(username: "dwpersian",     displayName: "DW Persian"),
        .init(username: "sahamnewsorg",  displayName: "Saham News"),
        .init(username: "farsi_iranwire", displayName: "IranWire"),
        .init(username: "followupiran",  displayName: "Followup Iran"),
        .init(username: "mamlekate",     displayName: "Mamlekate"),
        .init(username: "daadbaan2021",  displayName: "Daadbaan"),
        .init(username: "hranews",       displayName: "HRANA News"),
        .init(username: "ircfspace",     displayName: "IRCF"),
        .init(username: "persianvpnhub", displayName: "Persian VPN Hub"),
        .init(username: "iranlix",       displayName: "Iran Lix"),
        .init(username: "matinsenpaii",  displayName: "Matin Sen Paii"),
        .init(username: "no_itsmyturn",  displayName: "No It’s My Turn"),
        .init(username: "telegram",      displayName: "Telegram News"),
        .init(username: "durov",         displayName: "Pavel Durov"),
    ]

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
