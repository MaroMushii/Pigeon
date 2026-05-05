import SwiftUI
import SwiftData
import Nuke
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

    /// Memoized sort of `channel.posts` by `postedAt` (descending). Recomputing
    /// inside `body` ran on every observable mutation across any post — for a
    /// channel with hundreds of posts that's a measurable hitch on every
    /// reaction-count tick. We refresh this only when the selected channel or
    /// its post count actually changes.
    @State private var sortedPosts: [Post] = []

    /// Prefetcher for the next-on-screen post images. Uses `.shared` so the
    /// fetches go through Nuke's `URLSession` that has `PinnedURLProtocol`
    /// installed — i.e. the same GT-host-rewrite path as visible images.
    /// `maxConcurrentRequestCount: 2` is deliberately conservative: Iranian
    /// links saturate quickly, and we'd rather have the *next* image ready
    /// than burn bandwidth racing five simultaneous downloads against the
    /// pinned client's foreground requests.
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache,
        maxConcurrentRequestCount: 2
    )

    /// How many posts ahead we keep prefetched at any given time. Five is
    /// roughly one screenful past the bottom of the viewport at typical
    /// reading window sizes — enough that scroll-flings don't reveal
    /// placeholder rectangles, small enough that mid-feed jumps don't
    /// queue tens of doomed requests.
    private static let prefetchWindow = 5

    /// Currently-prefetching `ImageRequest`s, keyed by Post `id`. We keep
    /// the *requests* (not just URLs) so `stopPrefetching(with:)` matches
    /// Nuke's cache key exactly — same processor, same URL.
    @State private var prefetchedByPost: [String: ImageRequest] = [:]

    var body: some View {
        Group {
            if let channel {
                content(for: channel)
            } else {
                FeedEmptyState {
                    appState.presentedSheet = .addChannel
                }
            }
        }
        .navigationTitle(channel?.displayName ?? "Pigeon")
        .navigationSubtitle(channel.map { "@\($0.username)" } ?? "")
        .toolbar {
            if let channel {
                if let lastFetched = channel.lastFetchedAt {
                    ToolbarItem(placement: .automatic) {
                        Text("Updated \(lastFetched, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("Last refreshed \(lastFetched.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if let lastError = service?.lastError {
                    ToolbarItem(placement: .automatic) {
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
        .task(id: channel?.persistentModelID) {
            recomputeSortedPosts()
            // Switching channels invalidates the prefetch window — the post
            // indices we were tracking belong to the previous channel's
            // ordering. Drain everything; the next visible row will refill.
            cancelAllPrefetches()
        }
        .onChange(of: channel?.posts.count ?? 0) {
            recomputeSortedPosts()
        }
        .onDisappear {
            cancelAllPrefetches()
        }
    }

    /// Enqueue the first image of posts in `(index, index + prefetchWindow]`
    /// and drop anything outside that window that's still in-flight. Called
    /// every time a card crosses the visibility threshold, so it must be
    /// cheap — no allocations beyond the request set itself.
    private func updatePrefetchWindow(startingAfter index: Int, in posts: [Post]) {
        let lower = index + 1
        let upper = min(index + 1 + Self.prefetchWindow, posts.count)
        guard lower < upper else { return }

        var desired: [String: ImageRequest] = [:]
        for i in lower..<upper {
            let post = posts[i]
            guard let request = firstPhotoRequest(for: post) else { continue }
            desired[post.id] = request
        }

        // Stop any in-flight prefetches that fell out of the window. Doing
        // this before starting the new ones keeps the concurrent slot count
        // honest when scroll moves fast.
        let droppedRequests = prefetchedByPost
            .filter { desired[$0.key] == nil }
            .map(\.value)
        if !droppedRequests.isEmpty {
            prefetcher.stopPrefetching(with: droppedRequests)
        }

        // Enqueue only what's *new* — restarting an already-prefetching
        // request is harmless but wastes a dictionary update.
        let newRequests = desired
            .filter { prefetchedByPost[$0.key] == nil }
            .map(\.value)
        if !newRequests.isEmpty {
            prefetcher.startPrefetching(with: newRequests)
        }

        prefetchedByPost = desired
    }

    private func cancelAllPrefetches() {
        guard !prefetchedByPost.isEmpty else { return }
        prefetcher.stopPrefetching()
        prefetchedByPost.removeAll(keepingCapacity: false)
    }

    /// First photo on a post, or nil if the post is text-only / video-only.
    /// We deliberately skip videos: the `assetURL` for a video is the MP4
    /// itself (not a poster), and Telegram videos can be tens of megabytes.
    /// `MediaTile` shows the poster from `thumbnailURL` which is already
    /// the photo cache key — so a future enhancement could prefetch video
    /// posters too. Out of scope here.
    private func firstPhotoRequest(for post: Post) -> ImageRequest? {
        guard let media = post.media.first(where: { $0.kind == .photo }) else {
            return nil
        }
        return MediaImageRequest.tile(for: media)
    }

    private func recomputeSortedPosts() {
        guard let channel else {
            sortedPosts = []
            return
        }
        sortedPosts = channel.posts.sorted {
            ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast)
        }
    }

    @ViewBuilder
    private func content(for channel: Channel) -> some View {
        let posts = sortedPosts
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

                    Divider()
                        .padding(.bottom, 4)

                    // `enumerated()` gives us the index for the prefetch
                    // window calculation while keeping row identity bound
                    // to `post.id` — important because new posts arrive at
                    // index 0 from auto-refresh, and shifting indices
                    // would otherwise force every row to re-render.
                    ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                        PostCard(post: post)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                if visible {
                                    updatePrefetchWindow(startingAfter: index, in: posts)
                                }
                            }
                    }

                    Color.clear.frame(height: 32)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Bind the ScrollView's identity to the channel so SwiftUI
            // rebuilds it on channel switch — otherwise the previous
            // channel's content offset (and its in-flight visibility
            // callbacks) bleed into the new feed.
            .id(channel.persistentModelID)
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
                .frame(width: 52, height: 52)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("@\(channel.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let subs = channel.subscriberCount, !subs.isEmpty {
                Text(subs)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = channel.photoURL, let url = URL(string: urlString) {
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
                    size: CGSize(width: 52, height: 52),
                    contentMode: .aspectFill,
                    crop: false
                )
            ]
        )
    }
}

private struct FeedEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 20) {
                Image("PigeonMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .opacity(0.85)
                Text("Pick a channel from the sidebar,\nor add a new one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button("Add Channel", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
