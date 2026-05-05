import SwiftUI
import SwiftData
import NukeUI

/// Right-hand pane: scrolls a stream of fully-rendered posts for the
/// currently selected channel. No separate detail view — Telegram channels
/// are broadcast streams, every post is self-contained, so we present them
/// inline like a chat/reader timeline.
struct ChannelFeed: View {
    let channel: Channel?

    @Environment(AppState.self) private var appState
    @Environment(\.channelService) private var service

    var body: some View {
        Group {
            if let channel {
                content(for: channel)
            } else {
                ContentUnavailableView {
                    Label("Pigeon", systemImage: "paperplane")
                        .symbolRenderingMode(.hierarchical)
                } description: {
                    Text("Pick a channel from the sidebar, or add a new one.")
                } actions: {
                    Button {
                        appState.presentedSheet = .addChannel
                    } label: {
                        Text("Add Channel")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .navigationTitle(channel?.displayName ?? "Pigeon")
        .navigationSubtitle(channel.map { "@\($0.username)" } ?? "")
        .toolbar {
            if let channel {
                if let lastFetched = channel.lastFetchedAt {
                    ToolbarItem(placement: .status) {
                        Text("Updated \(lastFetched, format: .relative(presentation: .named))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help("Last refreshed \(lastFetched.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh(channel) }
                    } label: {
                        if appState.loadingChannels.contains(channel.username) {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh this channel (⌘R)")
                    .disabled(appState.loadingChannels.contains(channel.username))
                }
            }
        }
    }

    @ViewBuilder
    private func content(for channel: Channel) -> some View {
        let posts = channel.posts.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
        let isLoading = appState.loadingChannels.contains(channel.username)

        if posts.isEmpty {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                    Text("Loading posts…").foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(
                        "No Posts",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("This channel has no public posts yet.")
                    )
                    Button("Refresh") { Task { await refresh(channel) } }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ChannelHeader(channel: channel)
                        .padding(.bottom, 4)

                    ForEach(posts) { post in
                        PostCard(post: post)
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func refresh(_ channel: Channel) async {
        guard let service else { return }
        appState.loadingChannels.insert(channel.username)
        defer { appState.loadingChannels.remove(channel.username) }
        do {
            _ = try await service.postsForDisplay(channel, forceRefresh: true)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}

private struct ChannelHeader: View {
    let channel: Channel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar
                .frame(width: 44, height: 44)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Text("@\(channel.username)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let subs = channel.subscriberCount, !subs.isEmpty {
                Text(subs)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = channel.photoURL, let url = URL(string: urlString) {
            LazyImage(url: url) { state in
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
}
