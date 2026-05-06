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

    /// Owns the image prefetcher and the rolling prefetch-window state. Held
    /// as a class instance (not raw `@State` value types) so visibility-driven
    /// mutations don't invalidate `ChannelFeed`'s body. With dictionary-typed
    /// `@State`, every scroll delta re-evaluated `content(for:)`, re-installed
    /// `onScrollVisibilityChange` modifiers on every visible row, and pumped
    /// LazyVStack/LazyVGrid into a constant placement-recomputation loop —
    /// which Instruments lit up as 27 microhangs and dropped frames during
    /// scroll. Class-reference identity is what `@State` tracks; mutations
    /// on the controller's internals are invisible to SwiftUI.
    @State private var prefetch = FeedPrefetchController()

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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentedSheet = .healthCheck
                } label: {
                    Label("Network Health", systemImage: "stethoscope")
                }
                .help("Check network health")
            }
            if let channel {
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
                    .help(refreshHelpText(for: channel))
                    .disabled(service?.inflight.contains(channel.username) ?? false)
                }
            }
        }
        .task(id: channel?.persistentModelID) {
            recomputeSortedPosts()
            // Switching channels invalidates the prefetch window — the post
            // indices we were tracking belong to the previous channel's
            // ordering. Drain everything; the next visible row will refill.
            prefetch.cancelAll()
        }
        .onChange(of: channel?.posts.count ?? 0) {
            recomputeSortedPosts()
        }
        .onDisappear {
            prefetch.cancelAll()
        }
    }

    private func recomputeSortedPosts() {
        guard let channel else {
            sortedPosts = []
            prefetch.setPosts([])
            return
        }
        let sorted = channel.posts.sorted {
            ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast)
        }
        sortedPosts = sorted
        prefetch.setPosts(sorted)
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

                    // Row identity is `post.id` (a unique String) so new
                    // posts arriving at index 0 from auto-refresh don't
                    // force every row to re-render. The visibility callback
                    // forwards just the id; the controller owns the
                    // post→index lookup so the closure doesn't capture the
                    // posts array (which would re-allocate per body call).
                    ForEach(posts, id: \.id) { post in
                        PostCard(post: post)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                if visible {
                                    prefetch.handleVisible(postID: post.id)
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

    private func refreshHelpText(for channel: Channel) -> String {
        var lines = ["Refresh this channel (⌘R)"]
        if let lastFetched = channel.lastFetchedAt {
            let relative = lastFetched.formatted(.relative(presentation: .named))
            let absolute = lastFetched.formatted(date: .abbreviated, time: .shortened)
            lines.append("Updated \(relative) — \(absolute)")
        }
        return lines.joined(separator: "\n")
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

/// Owns image-prefetch state for `ChannelFeed`. Lives as a class so that
/// scroll-visibility callbacks can mutate its internals without invalidating
/// the enclosing view's body — `@State` tracks reference identity for
/// classes, not internal mutations. See the comment on
/// `ChannelFeed.prefetch` for the structural reasoning behind this split.
@MainActor
private final class FeedPrefetchController {
    /// How many posts ahead we keep prefetched at any given time. Five is
    /// roughly one screenful past the bottom of the viewport at typical
    /// reading window sizes — enough that scroll-flings don't reveal
    /// placeholder rectangles, small enough that mid-feed jumps don't
    /// queue tens of doomed requests.
    static let prefetchWindow = 5

    /// Uses `.shared` so fetches go through Nuke's `URLSession` that has
    /// `PinnedURLProtocol` installed — same GT-host-rewrite path as visible
    /// images. `maxConcurrentRequestCount: 2` is conservative on purpose:
    /// Iranian links saturate quickly, and we'd rather have the *next*
    /// image ready than burn bandwidth racing five concurrent downloads
    /// against the pinned client's foreground requests.
    let prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache,
        maxConcurrentRequestCount: 2
    )

    private var orderedPosts: [Post] = []
    private var indexByPostID: [String: Int] = [:]

    /// Currently-prefetching `ImageRequest`s, keyed by Post `id`. We keep
    /// the *requests* (not just URLs) so `stopPrefetching(with:)` matches
    /// Nuke's cache key exactly — same processor, same URL.
    private var prefetchedByPost: [String: ImageRequest] = [:]

    func setPosts(_ posts: [Post]) {
        orderedPosts = posts
        var map: [String: Int] = [:]
        map.reserveCapacity(posts.count)
        for (i, post) in posts.enumerated() {
            map[post.id] = i
        }
        indexByPostID = map
    }

    /// Slide the prefetch window forward to cover the N posts after the
    /// one identified by `postID`. Cheap enough to call on every scroll
    /// visibility flip — no allocations beyond the desired-set itself.
    func handleVisible(postID: String) {
        guard let index = indexByPostID[postID] else { return }
        let lower = index + 1
        let upper = min(index + 1 + Self.prefetchWindow, orderedPosts.count)
        guard lower < upper else {
            cancelAll()
            return
        }

        var desired: [String: ImageRequest] = [:]
        for i in lower..<upper {
            let post = orderedPosts[i]
            guard let request = Self.firstPhotoRequest(for: post) else { continue }
            desired[post.id] = request
        }

        // Stop in-flight prefetches that fell out of the window before
        // starting new ones — keeps the concurrent-slot count honest when
        // scroll moves fast.
        let dropped = prefetchedByPost
            .filter { desired[$0.key] == nil }
            .map(\.value)
        if !dropped.isEmpty {
            prefetcher.stopPrefetching(with: dropped)
        }

        let added = desired
            .filter { prefetchedByPost[$0.key] == nil }
            .map(\.value)
        if !added.isEmpty {
            prefetcher.startPrefetching(with: added)
        }

        prefetchedByPost = desired
    }

    func cancelAll() {
        guard !prefetchedByPost.isEmpty else { return }
        prefetcher.stopPrefetching()
        prefetchedByPost.removeAll(keepingCapacity: false)
    }

    /// First photo on a post, or nil if the post is text-only / video-only.
    /// Videos are deliberately skipped: a video's `assetURL` is the MP4
    /// itself (not a poster), and Telegram videos can be tens of megabytes.
    private static func firstPhotoRequest(for post: Post) -> ImageRequest? {
        guard let media = post.media.first(where: { $0.kind == .photo }) else {
            return nil
        }
        return MediaImageRequest.tile(for: media)
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
