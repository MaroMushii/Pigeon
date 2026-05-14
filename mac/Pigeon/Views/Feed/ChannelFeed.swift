import SwiftUI
import SwiftData
import Nuke
import NukeUI
// Logging lives in Support/AppLog.swift. Topic-keyed Loggers per
// category; tail with `just logs <category>`. The categories used in
// this file are AppLog.feed (lifecycle) and AppLog.scroll (save/restore
// + re-click cycle).

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
    @Environment(ChannelScrollMemory.self) private var scrollMemory

    /// Sorted display snapshots of `channel.posts` (ascending by postedAt).
    /// Using value-type snapshots instead of live `@Model` references means
    /// SwiftUI cannot observe individual post mutations (reaction counts,
    /// viewsLabel) during a refresh and issue re-renders mid-scroll. Cards
    /// only re-render when `recomputeSortedPosts` explicitly rebuilds this
    /// array — triggered by `channel.lastFetchedAt` changes rather than
    /// fine-grained property mutations. Seeded synchronously in `init` so
    /// the very first body evaluation already sees a populated array.
    @State private var sortedPosts: [PostDisplaySnapshot]

    /// `sortedPosts` lifted into a unified row enum so the `ForEach` in
    /// `feed(posts:)` produces *exactly one view per element*. The naive
    /// shape — `if post.id == firstUnreadID { UnreadDivider() } PostCard()`
    /// — gives the ForEach a variable child count, which breaks SwiftUI's
    /// stable-identity contract and forces `LazyVStack` to re-realize rows
    /// on every scroll past the initial window. That re-realization is
    /// the source of the visible scroll-up jumping (estimated heights are
    /// re-applied per re-realization, layout shifts).
    @State private var rows: [FeedRow]

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

    /// Count of posts that have arrived since the user last sat at the
    /// bottom. Drives the badge on the floating jump-to-latest button.
    /// Session-only; not written to `Post.isRead`.
    @State private var unseenCount: Int = 0

    /// Three-step mount state machine — one source of truth for "what
    /// should the view show right now."
    ///
    ///   `.preparing`   HTML prewarm + initial PostCard realization happen
    ///                  off the visible path. Spinner only; feed not yet in
    ///                  the hierarchy.
    ///   `.layingOut`   Feed is in the hierarchy with `opacity(0)` so the
    ///                  ScrollView measures itself and `onScrollGeometryChange`
    ///                  can fire — but still under the spinner because the
    ///                  scroll position hasn't been placed yet.
    ///   `.ready`       Initial scroll has been applied; feed is revealed.
    ///
    /// Channel switches reset this via the `.id(channel.persistentModelID)`
    /// on the parent.
    enum MountPhase {
        case preparing
        case layingOut
        case ready
    }
    @State private var phase: MountPhase = .preparing

    /// Debounce handle for the `.layingOut → .ready` reveal. Every layout
    /// change during `.layingOut` cancels and reschedules this; the reveal
    /// fires once the geometry has been quiet for a single debounce window.
    /// That gives us "wait for the lazy stack to settle" without guessing
    /// how long realization will take.
    @State private var revealTask: Task<Void, Never>?

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
    @State private var unreadDividerVisible = false

    init(channel: Channel, scrollToLatestToken: UUID?) {
        self.channel = channel
        self.scrollToLatestToken = scrollToLatestToken
        let sorted = channel.posts
            .sorted { ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast) }
            .map { $0.displaySnapshot() }
        _sortedPosts = State(initialValue: sorted)
        let firstUnread = sorted.first { !$0.isRead }?.id
        let hasReadPost = sorted.contains { $0.isRead }
        let resolvedFirstUnreadID = hasReadPost ? firstUnread : nil
        _firstUnreadID = State(initialValue: resolvedFirstUnreadID)
        _rows = State(initialValue: Self.buildRows(posts: sorted, firstUnreadID: resolvedFirstUnreadID))
        AppLog.scroll.pub("init @\(channel.username) postCount=<\(sorted.count)>")
    }

    /// Build the unified row stream — divider injected in place ahead of
    /// `firstUnreadID`, never at the top (the divider's whole purpose is
    /// "where you were when you opened this channel," so it lives between
    /// rows, not above the first row).
    private static func buildRows(posts: [PostDisplaySnapshot], firstUnreadID: String?) -> [FeedRow] {
        var rows: [FeedRow] = []
        rows.reserveCapacity(posts.count + 1)
        for post in posts {
            if post.id == firstUnreadID {
                rows.append(.unreadDivider)
            }
            rows.append(.post(post))
        }
        return rows
    }

    var body: some View {
        let posts = sortedPosts

        Group {
            if posts.isEmpty {
                EmptyFeedState(channel: channel, onRefresh: refresh)
            } else {
                ZStack {
                    if phase != .preparing {
                        // Feed enters the hierarchy at `.layingOut` so the
                        // ScrollView measures itself and `onScrollGeometryChange`
                        // can place the scroll target — held invisible until
                        // `.ready`, otherwise the user sees a flash of
                        // top-of-feed before the proxy jumps to position.
                        feed(posts: posts)
                            .opacity(phase == .ready ? 1 : 0)
                    }
                    if phase != .ready {
                        // Single spinner across `.preparing` and `.layingOut`
                        // — the user shouldn't be able to tell which phase
                        // we're in, only that the channel is loading.
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background {
            // `FeedDataWatcher` owns the `channel.lastFetchedAt`
            // observation so this view's body is never re-run on
            // refresh. Its body is trivially cheap (Color.clear).
            FeedDataWatcher(channel: channel, onUpdate: scheduleRecompute)
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
            prefetch.setPosts(sortedPosts)
            // With the AppKit bridge replacing LazyVStack, `NSTableView`
            // measures all rows synchronously via its delegate and lays out
            // deterministically — no convergence/reveal dance needed.
            // Go straight `.preparing → .ready`.
            phase = .ready
        }
        .onChange(of: scrollToLatestToken) { _, _ in
            guard phase == .ready else { return }
            advanceReclickCycle()
        }
        .onDisappear {
            saveCurrentPosition()
            prefetch.cancelAll()
            revealTask?.cancel()
        }
    }

    /// Called by `FeedDataWatcher` when `channel.lastFetchedAt` changes.
    /// Rebuilds the snapshot array and handles new-post scroll/badge logic,
    /// deferred so the sort never blocks the current scroll frame.
    private func scheduleRecompute() {
        Task { @MainActor in
            let oldCount = sortedPosts.count
            recomputeSortedPosts()
            let delta = sortedPosts.count - oldCount
            guard delta > 0 else { return }
            if prefetch.isAtBottom {
                scrollToLatest(animated: false)
            } else {
                unseenCount += delta
            }
        }
    }

    @ViewBuilder
    private func feed(posts: [PostDisplaySnapshot]) -> some View {
        // Capture Binding before the closure — `$` requires self to be a
        // concrete struct value; capturing the Binding (not the @State directly)
        // gives the closure reference semantics into the State storage box.
        let dividerBinding = $unreadDividerVisible
        ZStack(alignment: .bottomTrailing) {
            FeedTableView(
                rows: rows,
                onPostVisibilityChange: { [prefetch] id, visible in
                    prefetch.setVisible(visible, postID: id)
                    if visible { prefetch.handleVisible(postID: id) }
                },
                onDividerVisibilityChange: { visible in
                    dividerBinding.wrappedValue = visible
                },
                onBottomVisibilityChange: { [prefetch] visible in
                    prefetch.setBottomVisible(visible)
                }
            )
                .safeAreaInset(edge: .top, spacing: 0) {
                    ChannelHeader(channel: channel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffectIfAvailable(in: .rect(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
            FeedOverlay(unseenCount: $unseenCount) {
                // Step 6 will wire scrollToLatest to the bridge. Stub for now.
            }
        }
    }

    /// Debounce-schedule the reveal: each call cancels the prior pending
    /// reveal and reschedules. When the geometry stops changing — i.e. no
    /// more `applyInitialScroll → contentSize → onScrollGeometryChange`
    /// cycles — the last-scheduled task survives the debounce window and
    /// flips us to `.ready`. Pure event-driven convergence; the only timing
    /// primitive is the debounce window itself.
    private func scheduleReveal() {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            AppLog.scroll.pub("reveal @\(channel.username) — phase=.ready")
            withAnimation(.easeOut(duration: 0.12)) {
                phase = .ready
            }
        }
    }

    /// Scroll to the newest post via `ScrollViewProxy`. `scrollTo(edge:)`
    /// races with `LazyVStack` row realization (the lazy stack reports an
    /// estimated content size before tail rows materialize, so the "edge"
    /// resolves to the wrong offset); id-based targeting instructs the
    /// lazy stack to realize the rows around that id, then pins to the
    /// bottom anchor — converging layout on a single pass.
    private func scrollToLatest(animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                prefetch.scrollProxy?.scrollTo("feed-bottom", anchor: .bottom)
            }
        } else {
            prefetch.scrollProxy?.scrollTo("feed-bottom", anchor: .bottom)
        }
    }

    /// Anchor for the unread divider — keeps it in the upper fifth of the
    /// viewport so the first unread post sits clearly *below* it instead of
    /// being scrolled offscreen above.
    private var dividerAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.2) }

    /// Anchor for restoring a saved mid-stream offset — pins the target post
    /// near the top with a small inset for breathing room beneath the
    /// floating header.
    private var offsetAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.08) }

    /// Resolve and apply the mount-time scroll target. Called twice — once
    /// at the first non-zero content-size measurement, and once one frame
    /// later — to absorb LazyVStack's estimated-vs-measured offset drift
    /// for targets outside the initial realization window.
    private func applyInitialScroll(saved: ChannelScrollMemory.Position?, proxy: ScrollViewProxy) {
        AppLog.scroll.pub("applyInitialScroll @\(channel.username): saved=<\(String(describing: saved))> firstUnreadID=<\(firstUnreadID ?? "nil")> rowCount=<\(rows.count)>")
        switch saved {
        case .bottom:
            AppLog.scroll.pub("  → scrollTo(feed-bottom)")
            scrollToBottom(proxy: proxy)
        case .unreadDivider(let anchor):
            if firstUnreadID == anchor {
                AppLog.scroll.pub("  → scrollTo(unread-divider) — anchor still firstUnread")
                proxy.scrollTo("unread-divider", anchor: dividerAnchor)
            } else {
                // Divider concept lost (everything got marked read, or the
                // anchor post itself got marked read individually). Scroll
                // to the anchor post directly so the user lands on the
                // same content they were reading.
                AppLog.scroll.pub("  → fallback scrollTo(anchor=<\(anchor)>) — firstUnreadID now <\(firstUnreadID ?? "nil")>")
                proxy.scrollTo(anchor, anchor: offsetAnchor)
            }
        case .offset(let postID):
            AppLog.scroll.pub("  → scrollTo(post=<\(postID)>) — exists in rows: <\(rows.contains { if case .post(let s) = $0 { return s.id == postID } else { return false } })>")
            proxy.scrollTo(postID, anchor: offsetAnchor)
        case .none:
            if firstUnreadID != nil {
                AppLog.scroll.pub("  → cold-launch scrollTo(unread-divider)")
                proxy.scrollTo("unread-divider", anchor: dividerAnchor)
            } else {
                AppLog.scroll.pub("  → cold-launch scrollTo(feed-bottom)")
                scrollToBottom(proxy: proxy)
            }
        }
    }

    /// Scroll-to-bottom helper that also records our intent: after this
    /// returns we *know* we're at the bottom, so we tell the controller
    /// directly instead of waiting on the bottom row's visibility
    /// callback. A refresh racing the callback would otherwise bump the
    /// unseen badge instead of auto-scrolling for new posts.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        proxy.scrollTo("feed-bottom", anchor: .bottom)
        prefetch.markAtBottom()
    }

    private func scrollToUnread(animated: Bool) {
        guard firstUnreadID != nil else {
            scrollToLatest(animated: animated)
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                prefetch.scrollProxy?.scrollTo("unread-divider", anchor: dividerAnchor)
            }
        } else {
            prefetch.scrollProxy?.scrollTo("unread-divider", anchor: dividerAnchor)
        }
    }

    /// Re-click on the already-selected channel cycles the scroll position:
    ///
    ///   somewhere mid-stream  →  unread divider  →  bottom  →  (no-op)
    ///
    /// When the channel has no unread posts the divider step is skipped
    /// entirely — re-click just moves you to the bottom (or no-ops if you're
    /// already there). `unseenCount` is cleared whenever we land at bottom
    /// because the floating jump-to-latest button no longer makes sense.
    private func advanceReclickCycle() {
        let hasUnread = firstUnreadID != nil
        AppLog.scroll.pub("reclick @\(channel.username): isAtBottom=<\(prefetch.isAtBottom)> hasUnread=<\(hasUnread)> dividerVis=<\(unreadDividerVisible)>")

        if prefetch.isAtBottom {
            AppLog.scroll.pub("  → no-op (at bottom)")
            return
        }

        if hasUnread && !unreadDividerVisible {
            AppLog.scroll.pub("  → scrollToUnread")
            scrollToUnread(animated: true)
            return
        }

        AppLog.scroll.pub("  → scrollToLatest")
        scrollToLatest(animated: true)
        unseenCount = 0
    }

    /// Capture the current scroll position so a switch-back to this channel
    /// can resume here. Called from `.onDisappear`, which fires when the
    /// `.id(channel.persistentModelID)` on the parent destroys this subtree
    /// on channel switch — so the controller's `isAtBottom` /
    /// `topmostVisiblePostID` are still authoritative at this point.
    private func saveCurrentPosition() {
        let position: ChannelScrollMemory.Position
        if prefetch.isAtBottom {
            position = .bottom
        } else if unreadDividerVisible, let anchor = firstUnreadID {
            // Capture the divider's anchor post so the restore site has a
            // concrete fallback even if `firstUnreadID` later becomes nil
            // (the channel was auto-marked-as-read while away). Without
            // this, the restore would silently fall through to feed-bottom
            // and discard the user's reading position.
            position = .unreadDivider(anchorPostID: anchor)
        } else if let topID = prefetch.topmostVisiblePostID {
            position = .offset(postID: topID)
        } else {
            AppLog.scroll.pub("save @\(channel.username): SKIP — isAtBottom=<false> dividerVis=<false> topmost=<nil>")
            return
        }
        AppLog.scroll.pub("save @\(channel.username): <\(String(describing: position))> isAtBottom=<\(prefetch.isAtBottom)> dividerVis=<\(unreadDividerVisible)> topmost=<\(prefetch.topmostVisiblePostID ?? "nil")>")
        scrollMemory.save(position, for: channel.persistentModelID)
    }

    private func recomputeSortedPosts() {
        let sorted = channel.posts
            .sorted { ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast) }
            .map { $0.displaySnapshot() }
        sortedPosts = sorted
        rows = Self.buildRows(posts: sorted, firstUnreadID: firstUnreadID)
        prefetch.setPosts(sorted)
    }

    private func refresh() {
        guard let service else { return }
        Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
    }
}

/// Shown when `sortedPosts` is empty. Owns the `inflight` observation so
/// that `ChannelFeedContent.body` is never re-run just because a refresh
/// starts or ends — the only time `inflight` matters for the empty state.
private struct EmptyFeedState: View {
    let channel: Channel
    let onRefresh: () -> Void

    @Environment(\.channelService) private var service

    var body: some View {
        VStack(spacing: 12) {
            if service?.inflight.contains(channel.username) ?? false {
                ProgressView()
                Text("Loading posts…").foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No Posts",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This channel has no public posts yet.")
                )
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Stored here (not as `@State`) so mutations are invisible to SwiftUI —
    /// writing via `.scrollTo` must not trigger a body re-run, which was the
    /// source of the 16 k re-renders/sec feedback loop when `scrollPosition`
    /// lived in `@State`.
    var scrollProxy: ScrollViewProxy?

    /// Whether the last post in the feed is currently in the viewport.
    /// Stored on the controller (not as `@State`) for the same reason as
    /// `scrollProxy`: the bottom row's visibility callback writes this on
    /// every scroll frame and we cannot afford a body re-run per write.
    ///
    /// Defaults to `false`: a fresh mount that lands on the unread divider
    /// (the cold-launch path) never has the bottom row in the viewport, so
    /// the visibility callback won't fire `true` until the user actually
    /// scrolls there. Defaulting to `true` would make the re-click cycle
    /// short-circuit as "already at bottom" and silently no-op.
    ///
    /// External mutation goes through `markAtBottom()` / `setBottomVisible(_:)`
    /// — the named methods document intent and keep the assignment site
    /// greppable.
    private(set) var isAtBottom: Bool = false

    /// Called by the bottom row's `onVisibilityChange` callback. The flag
    /// is *eventually consistent* with viewport state; `markAtBottom()`
    /// exists for callers that have just programmatically scrolled there
    /// and know the answer without waiting for the callback.
    func setBottomVisible(_ visible: Bool) {
        isAtBottom = visible
    }

    /// Record that we just programmatically scrolled to the bottom, so
    /// downstream checks (refresh auto-scroll, re-click cycle) treat us
    /// as at-bottom without waiting for the visibility callback to fire.
    func markAtBottom() {
        isAtBottom = true
    }

    /// Set of post ids currently inside the viewport. Updated from
    /// `PostCard.onVisibilityChange` — same callback that already drives
    /// prefetch — so no extra observation cost.
    private var visiblePostIDs: Set<String> = []

    /// Cached "oldest post currently on screen" — i.e. the *top* row in
    /// our chronological feed (ascending by `postedAt`). Updated eagerly on
    /// every visibility flip, *but only when the visible set is non-empty*,
    /// so a teardown (channel switch) — which fires `false` callbacks for
    /// every visible card before `.onDisappear` runs on the parent — never
    /// clobbers the last good value. Read at save-time to record the user's
    /// "continue from here" position.
    private(set) var topmostVisiblePostID: String?

    private var orderedPosts: [PostDisplaySnapshot] = []
    private var indexByPostID: [String: Int] = [:]

    /// Currently-prefetching `ImageRequest`s, keyed by Post `id`. We keep
    /// the *requests* (not just URLs) so `stopPrefetching(with:)` matches
    /// Nuke's cache key exactly — same processor, same URL.
    private var prefetchedByPost: [String: ImageRequest] = [:]

    func setPosts(_ posts: [PostDisplaySnapshot]) {
        orderedPosts = posts
        var map: [String: Int] = [:]
        map.reserveCapacity(posts.count)
        for (i, post) in posts.enumerated() {
            map[post.id] = i
        }
        indexByPostID = map
        // Drop the cached topmost if it no longer references a known post
        // (paranoia — `setPosts` is mostly called for incremental refreshes
        // that preserve ids, but defensive against the case where a
        // schema-version reset replaces the entire post set).
        if let cached = topmostVisiblePostID, map[cached] == nil {
            topmostVisiblePostID = nil
        }
    }

    /// Slide the prefetch window to cover the N posts the user is about
    /// to scroll *into*. The feed is inverted: index 0 is the oldest post
    /// (top of ScrollView), and the user scrolls *upward* to read older
    /// content — so the upcoming window is at *lower* indices than the
    /// currently visible row, not higher. Cheap enough to call on every
    /// scroll visibility flip — no allocations beyond the desired-set.
    func setVisible(_ visible: Bool, postID: String) {
        if visible {
            visiblePostIDs.insert(postID)
        } else {
            visiblePostIDs.remove(postID)
        }
        // Refresh the cached topmost ONLY when something is still visible.
        // During teardown SwiftUI fires `false` for every card before the
        // parent's `.onDisappear` runs; clearing the cache here would erase
        // the value we need a moment later in `saveCurrentPosition`.
        guard !visiblePostIDs.isEmpty else { return }
        topmostVisiblePostID = visiblePostIDs
            .compactMap { id in indexByPostID[id].map { (id, $0) } }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

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
    private static func firstPhotoRequest(for post: PostDisplaySnapshot) -> ImageRequest? {
        guard let media = post.media.first(where: { $0.kind == .photo }) else {
            return nil
        }
        return MediaImageRequest.tile(for: media)
    }
}

/// Transparent sentinel that owns the `channel.lastFetchedAt` observation.
/// Lives in a `.background` so its body (just `Color.clear`) re-runs on
/// refresh instead of the full `ChannelFeedContent` body.
private struct FeedDataWatcher: View {
    let channel: Channel
    let onUpdate: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: channel.lastFetchedAt) { _, _ in
                onUpdate()
            }
    }
}

/// Overlay that owns the `unseenCount` observation so that
/// `ChannelFeedContent.body` is never re-run when new posts arrive while
/// the user is scrolled up, or when the bottom row clears the badge.
private struct FeedOverlay: View {
    @Binding var unseenCount: Int
    let onJump: () -> Void

    var body: some View {
        Group {
            if unseenCount > 0 {
                JumpToLatestButton(count: unseenCount) {
                    unseenCount = 0
                    onJump()
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: unseenCount > 0)
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
