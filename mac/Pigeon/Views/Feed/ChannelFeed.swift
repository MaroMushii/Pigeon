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
    @State private var showingErrorPopover = false

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
                if let lastError = service?.lastError {
                    ToolbarItem(placement: .status) {
                        errorBadge(lastError)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh(channel)
                    } label: {
                        if service?.inflight.contains(channel.username) ?? false {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh this channel (⌘R)")
                    .disabled(service?.inflight.contains(channel.username) ?? false)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for channel: Channel) -> some View {
        let posts = channel.posts.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
        let isLoading = service?.inflight.contains(channel.username) ?? false

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
                    Button("Refresh") { refresh(channel) }
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

    private func refresh(_ channel: Channel) {
        guard let service else { return }
        Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
    }

    @ViewBuilder
    private func errorBadge(_ error: ChannelService.ChannelError) -> some View {
        Button {
            showingErrorPopover = true
        } label: {
            Label("Refresh failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .help("Last refresh failed — click for details")
        .popover(isPresented: $showingErrorPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Refresh failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(error.channel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(error.message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    Text(error.at, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Spacer()
                    Button("Dismiss") {
                        service?.clearLastError()
                        showingErrorPopover = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 320)
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
