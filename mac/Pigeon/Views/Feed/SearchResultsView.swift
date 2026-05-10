import SwiftUI
import SwiftData
import Nuke
import NukeUI

/// Detail-pane replacement shown whenever `SearchStore.hasActiveQuery` is
/// true. Renders a flat list of matching posts across every channel,
/// each row revealing channel attribution, when it was posted, and a
/// snippet of `plainText` with the query highlighted.
///
/// Channel name + avatar resolution is batched: we fetch all channels
/// once and look them up by username. A naive per-row `FetchDescriptor`
/// would be N+1 over the result set — fine at 20 results, painful at 200.
struct SearchResultsView: View {
    let results: [Post]
    let query: String
    let isSearching: Bool

    @Environment(AppState.self) private var appState
    @Query(sort: [SortDescriptor(\Channel.username, order: .forward)])
    private var allChannels: [Channel]
    @State private var channelLookup: [String: Channel] = [:]

    var body: some View {
        Group {
            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(subtitle)
        .onChange(of: allChannels, initial: true) { _, newValue in
            channelLookup = Dictionary(uniqueKeysWithValues: newValue.map { ($0.username.lowercased(), $0) })
        }
    }

    private var subtitle: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if isSearching && results.isEmpty { return "Searching…" }
        let count = results.count
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { post in
                    Button {
                        select(post: post)
                    } label: {
                        SearchResultRow(
                            post: post,
                            channel: channelLookup[post.channelUsername.lowercased()],
                            query: query
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 60)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .softTopScrollEdgeEffect()
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView(
                "Search Posts",
                systemImage: "magnifyingglass",
                description: Text("Type to search across every channel you follow.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Matches",
                systemImage: "text.magnifyingglass",
                description: Text("No posts match “\(trimmed)”.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(post: Post) {
        guard let channel = channelLookup[post.channelUsername.lowercased()] else { return }
        appState.selectedChannelID = channel.persistentModelID
        // Scrolling to the specific post is deferred — the feed will land at
        // its top, which is acceptable for v1. The user can scroll from there.
    }
}

private struct SearchResultRow: View {
    let post: Post
    let channel: Channel?
    let query: String

    @State private var cachedSnippet: AttributedString = AttributedString()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
                .frame(width: 36, height: 36)
                .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(channelLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("@\(post.channelUsername)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let posted = post.postedAt {
                        Text(posted, format: .relative(presentation: .named))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Text(cachedSnippet)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onChange(of: query, initial: true) { _, newQuery in
            cachedSnippet = buildSnippet(for: newQuery)
        }
    }

    private var channelLabel: String {
        channel?.displayName ?? post.channelUsername
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = channel?.photoURL, let url = URL(string: urlString) {
            LazyImage(request: Self.avatarRequest(for: url)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.accentColor.opacity(0.18)
                }
            }
        } else {
            Circle().fill(Color.accentColor.opacity(0.18))
        }
    }

    private static func avatarRequest(for url: URL) -> ImageRequest {
        ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: 36, height: 36),
                    contentMode: .aspectFill,
                    crop: false
                )
            ]
        )
    }

    private func buildSnippet(for query: String) -> AttributedString {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = post.plainText.replacingOccurrences(of: "\n", with: " ")
        guard !trimmedQuery.isEmpty else {
            return AttributedString(String(body.prefix(280)))
        }

        // Centre the snippet on the first match for context.
        let window = 240
        let leadPad = 40
        let snippetText: String
        if let matchRange = body.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = body.index(matchRange.lowerBound, offsetBy: -leadPad, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(start, offsetBy: window, limitedBy: body.endIndex) ?? body.endIndex
            var slice = String(body[start..<end])
            if start > body.startIndex { slice = "…" + slice }
            if end < body.endIndex { slice += "…" }
            snippetText = slice
        } else {
            snippetText = String(body.prefix(280))
        }

        var attributed = AttributedString(snippetText)
        // Walk the snippet string and bold every occurrence of the query.
        var cursor = snippetText.startIndex
        while cursor < snippetText.endIndex,
              let range = snippetText.range(of: trimmedQuery,
                                            options: [.caseInsensitive, .diacriticInsensitive],
                                            range: cursor..<snippetText.endIndex) {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].font = .system(size: 13, weight: .semibold)
                attributed[attrRange].foregroundColor = .primary
            }
            cursor = range.upperBound
        }
        return attributed
    }
}

