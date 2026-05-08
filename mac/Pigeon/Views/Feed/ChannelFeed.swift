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

    var body: some View {
        Group {
            if let channel {
                ChannelFeedContent(channel: channel, scrollToLatestToken: appState.scrollToLatestToken)
                    .id(channel.persistentModelID)
            } else {
                FeedEmptyState {
                    appState.presentedSheet = .addChannel
                }
            }
        }
        .navigationTitle("Pigeon")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentedSheet = .healthCheck
                } label: {
                    Label("Network Health", systemImage: "stethoscope")
                }
                .help("Check network health")
            }
            if let lastError = service?.lastError {
                ToolbarItem(placement: .automatic) {
                    errorBadge(lastError)
                }
            }
        }
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

/// Owns the per-channel feed state. Lives as a separate view so the call
/// site can apply `.id(channel.persistentModelID)` and force SwiftUI to
/// destroy and recreate the entire subtree — including all `@State` —
/// on channel switch. Without this split, scroll position, prefetch
/// window, `isAtBottom`, and `unseenCount` are owned by the parent and
/// leak across channels.
private struct ChannelFeedContent: View {
    let channel: Channel
    let scrollToLatestToken: UUID?

    @Environment(\.channelService) private var service

    /// Memoized sort of `channel.posts` by `postedAt` (ascending: oldest
    /// first, newest last — the bottom-anchored ScrollView renders the last
    /// index nearest the visible bottom). Recomputing inside `body` ran on
    /// every observable mutation across any post (a measurable hitch on
    /// every reaction-count tick), so we refresh it only on init and when
    /// the post count changes. Seeded synchronously in `init` so the very
    /// first body evaluation already sees a populated array — otherwise
    /// the first frame paints the empty state.
    @State private var sortedPosts: [Post]

    /// Owns the image prefetcher and the rolling prefetch-window state. Held
    /// as a class instance (not raw `@State` value types) so visibility-driven
    /// mutations don't invalidate this view's body. With dictionary-typed
    /// `@State`, every scroll delta re-evaluated `body`, re-installed
    /// `onScrollVisibilityChange` modifiers on every visible row, and pumped
    /// the stack into a constant placement-recomputation loop — which
    /// Instruments lit up as 27 microhangs and dropped frames during scroll.
    /// Class-reference identity is what `@State` tracks; mutations on the
    /// controller's internals are invisible to SwiftUI.
    @State private var prefetch = FeedPrefetchController()

    @State private var scrollPosition = ScrollPosition()

    /// Whether the newest post (last index) is currently visible. Tracked
    /// via `onScrollVisibilityChange` on the last row — not via
    /// `scrollPosition.edge`, which only updates after explicit programmatic
    /// scrolls and ignores user-driven gestures.
    @State private var isAtBottom: Bool = true

    /// Count of posts that have arrived since the user last sat at the
    /// bottom. Drives the badge on the floating jump-to-latest button.
    /// Session-only; not written to `Post.isRead`.
    @State private var unseenCount: Int = 0

    /// `true` while the channel is preparing on mount. Covers both the
    /// cold-cache `AttributedHTMLBuilder` prewarm *and* the brief beat
    /// where SwiftUI realizes the eager `VStack` of 20 PostCards (text
    /// layout, media galleries, reactions, ScrollView measurement). Even
    /// when the cache is warm, that realization isn't free, so we always
    /// show a spinner on mount and clear the flag once `.task` completes
    /// — by which point SwiftUI's layout pass for the feed has run
    /// concurrently with the (possibly no-op) prewarm.
    @State private var isPreparing: Bool = true

    /// Id of the post above which the "Unread messages" divider is drawn.
    /// Captured once at mount from the *current* `isRead` state and never
    /// recomputed for the lifetime of this channel view — otherwise the
    /// divider would slide downward in real time as posts crossed the
    /// dwell threshold and `markRead` flipped them. The point of the
    /// divider is "where you were when you opened this channel," so it
    /// has to be a frozen session marker. Suppressed when every loaded
    /// post is unread (no anchor to draw above) so a brand-new channel
    /// or a long mute window doesn't paint a divider above the topmost
    /// row. The `.id(channel.persistentModelID)` on the parent guarantees
    /// this `@State` is fresh on every channel visit.
    @State private var firstUnreadID: String?

    init(channel: Channel, scrollToLatestToken: UUID?) {
        self.channel = channel
        self.scrollToLatestToken = scrollToLatestToken
        // Sort once, here, so the first body evaluation already has the
        // final array. Touching `channel.posts` faults the SwiftData
        // relationship — fast for in-memory cached channels, which is
        // every channel by the time it's clickable in the sidebar.
        let sorted = channel.posts.sorted {
            ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast)
        }
        _sortedPosts = State(initialValue: sorted)
        // Snapshot the unread boundary at mount. Only meaningful when
        // there is at least one read post above the first unread one —
        // otherwise the divider would render above the very first row
        // and read as decoration, not a "you read up to here" signal.
        let firstUnread = sorted.first { !$0.isRead }?.id
        let hasReadPost = sorted.contains { $0.isRead }
        _firstUnreadID = State(initialValue: hasReadPost ? firstUnread : nil)
    }

    var body: some View {
        let posts = sortedPosts
        let isLoading = service?.inflight.contains(channel.username) ?? false

        Group {
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
                        Button("Refresh") { refresh() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isPreparing {
                // Mount window. Covers cold-cache HTML parsing (moved
                // off-main in the `.task` below) *and* the brief beat
                // where SwiftUI realizes 20 PostCard subtrees eagerly.
                // The latter happens even on warm cache, so the spinner
                // is unconditional — the user otherwise sees a stretch
                // of "stale-feeling" emptiness while layout runs.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                feed(posts: posts)
            }
        }
        .task {
            // Pre-warm the AttributedHTMLBuilder cache off the main
            // thread before revealing the feed. With `LazyVStack` only
            // ~5–10 cards realize on first paint, so cold-cache parsing
            // cost is bounded — but we still pre-warm the visible
            // window so the first frame paints with formatted text
            // instead of plain-text fallback.
            let htmls = sortedPosts.suffix(10).map(\.bodyHTML).filter { !$0.isEmpty }
            if !htmls.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    let builder = AttributedHTMLBuilder()
                    for html in htmls {
                        _ = builder.build(from: html)
                    }
                }.value
            }
            isPreparing = false
            prefetch.setPosts(sortedPosts)
            // Initial scroll target is set in `feed(posts:)`'s `.task`,
            // not here: this `.task` runs while `isPreparing == true`
            // (the `ProgressView` branch), so the `ScrollView` doesn't
            // exist yet and `scrollPosition.scrollTo` has nothing to
            // bind to. Calling it from the feed view's own `.task`
            // guarantees the binding is live before we ask it to move.
        }
        .onChange(of: scrollToLatestToken) { _, _ in
            guard !isPreparing else { return }
            scrollToLatest(animated: true)
            unseenCount = 0
        }
        .onChange(of: channel.posts.count) { oldCount, newCount in
            recomputeSortedPosts()
            let delta = newCount - oldCount
            guard delta > 0 else { return }
            if isAtBottom {
                scrollToLatest(animated: true)
            } else {
                unseenCount += delta
            }
        }
        .onDisappear {
            prefetch.cancelAll()
        }
    }

    @ViewBuilder
    private func feed(posts: [Post]) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Row identity is `post.id` (a unique String) so new
                    // posts arriving at the last index from auto-refresh
                    // don't force every row to re-render. The visibility
                    // callback forwards the id to the prefetch controller;
                    // tracking the *last* post's visibility gives us a
                    // robust "user is pinned to bottom" signal —
                    // `ScrollPosition.edge` only updates after explicit
                    // programmatic scrolls.
                    ForEach(posts, id: \.id) { post in
                        if post.id == firstUnreadID {
                            UnreadDivider()
                        }
                        PostCard(post: post, onVisibilityChange: { visible in
                            if visible {
                                prefetch.handleVisible(postID: post.id)
                            }
                            if post.id == posts.last?.id {
                                // Only write on transitions to avoid
                                // invalidating body mid-scroll when
                                // the bottom row re-fires the same
                                // value.
                                if isAtBottom != visible {
                                    isAtBottom = visible
                                }
                                if visible && unseenCount != 0 {
                                    unseenCount = 0
                                }
                            }
                        })
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollPosition($scrollPosition)
            // Soft fade at the top edge: posts that scroll up *behind*
            // the Liquid Glass header dissolve into the glass surface
            // instead of butting up against a hard line — exactly the
            // "scroll-under glass" feel.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Liquid Glass header: floats over the scroll surface and
            // lets posts visibly pass behind it as the user scrolls.
            // `.safeAreaInset` reserves the layout space *and* renders
            // the inset above the scrolling content, so glass refraction
            // picks up the moving content.
            .safeAreaInset(edge: .top, spacing: 0) {
                ChannelHeader(channel: channel)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }

            if unseenCount > 0 {
                JumpToLatestButton(count: unseenCount) {
                    scrollToLatest(animated: true)
                    unseenCount = 0
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: unseenCount > 0)
        .task {
            // Mount-time scroll target. Runs once the `ScrollView` is in
            // the view tree (this `.task` is on the feed itself, not on
            // the outer `Group` whose `.task` fires while the spinner is
            // still showing). Prefer the unread boundary so the user
            // lands where they left off; fall back to the newest post
            // when there's nothing unread to anchor against. `.center`
            // over `.top` because the divider renders above the post in
            // the same `ForEach` row — a top anchor would push the
            // divider above the viewport and defeat the visual signal.
            if let unreadID = firstUnreadID {
                scrollPosition.scrollTo(id: unreadID, anchor: .center)
            } else if let lastID = sortedPosts.last?.id {
                scrollPosition.scrollTo(id: lastID, anchor: .bottom)
            }
        }
    }

    /// Scroll to the newest post via id-based targeting. `scrollTo(edge:)`
    /// races with `LazyVStack` row realization (the lazy stack reports an
    /// estimated content size before tail rows materialize, so the "edge"
    /// resolves to the wrong offset); `scrollTo(id:anchor:)` instead
    /// instructs the lazy stack to realize the rows around that id, then
    /// pins it to the bottom anchor — converging layout on a single pass.
    private func scrollToLatest(animated: Bool) {
        guard let lastID = sortedPosts.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPosition.scrollTo(id: lastID, anchor: .bottom)
            }
        } else {
            scrollPosition.scrollTo(id: lastID, anchor: .bottom)
        }
    }

    private func recomputeSortedPosts() {
        // Ascending: oldest at index 0, newest at the last index. The
        // ScrollView is bottom-anchored, so the last index renders
        // nearest the visible bottom — matching Telegram's chat
        // orientation.
        let sorted = channel.posts.sorted {
            ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast)
        }
        sortedPosts = sorted
        prefetch.setPosts(sorted)
    }

    private func refresh() {
        guard let service else { return }
        Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
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

/// Owns image-prefetch state for `ChannelFeedContent`. Lives as a class
/// so that scroll-visibility callbacks can mutate its internals without
/// invalidating the enclosing view's body — `@State` tracks reference
/// identity for classes, not internal mutations. See the comment on
/// `ChannelFeedContent.prefetch` for the structural reasoning behind
/// this split.
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

    /// Slide the prefetch window to cover the N posts the user is about
    /// to scroll *into*. The feed is inverted: index 0 is the oldest post
    /// (top of ScrollView), and the user scrolls *upward* to read older
    /// content — so the upcoming window is at *lower* indices than the
    /// currently visible row, not higher. Cheap enough to call on every
    /// scroll visibility flip — no allocations beyond the desired-set.
    func handleVisible(postID: String) {
        guard let index = indexByPostID[postID] else { return }
        let upper = index
        let lower = max(0, index - Self.prefetchWindow)
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

/// Inline "Unread messages" rule, drawn above the first post the user
/// hadn't read when this channel was opened. Position is frozen for the
/// session by `ChannelFeedContent.firstUnreadID` — the divider stays put
/// even after the dwell-driven `markRead` cascade flips its anchor post
/// to read, so scrolling up after a channel switch reliably surfaces
/// "this is where I was."
private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            rule
            Text("Unread messages")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            rule
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unread messages below")
    }

    private var rule: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
    }
}

/// Floating Telegram-style "jump to latest" button. Appears bottom-right
/// of the feed when the user has scrolled away from the newest post and
/// new posts have arrived in the meantime. The badge shows how many new
/// posts the user hasn't yet caught up to (capped at "99+").
private struct JumpToLatestButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: .circle)
                .overlay(
                    Circle()
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: .capsule)
                            .offset(x: 6, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Jump to latest")
        .accessibilityLabel(count > 0 ? "Jump to latest, \(count) new posts" : "Jump to latest")
    }
}
