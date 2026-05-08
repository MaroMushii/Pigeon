import SwiftUI
import Nuke
import NukeUI

/// One post in the feed: header, optional media, attributed body, reactions,
/// footer. The whole card is one selectable unit but selection isn't
/// persistent — selecting just highlights for copy/share.
struct PostCard: View {
    let post: Post
    /// Called by the parent before the internal dwell-read logic when
    /// scroll visibility changes. Used by `ChannelFeedContent` to handle
    /// prefetch and bottom-tracking without a second `onScrollVisibilityChange`
    /// observer per row.
    var onVisibilityChange: ((Bool) -> Void)? = nil

    @Environment(\.channelService) private var service

    private static let attributedBuilder = AttributedHTMLBuilder()

    /// Dwell time before a visible post is counted as read. Brief glances
    /// during a scroll-fling shouldn't burn through the unread queue, and
    /// — load-bearing for scroll smoothness — flings no longer fire a
    /// `markRead` (and its SwiftData mutation + dock-badge update) for
    /// every card that crosses the threshold for one frame.
    private static let readDwell: Duration = .milliseconds(600)

    /// Pending dwell-completion task. Recreated on each visibility flip;
    /// `onDisappear` cancels it so a card scrolled fully off-screen
    /// doesn't fire `markRead` after the fact.
    @State private var dwellTask: Task<Void, Never>?

    /// Attributed rendering of `post.bodyHTML`. Synchronously seeded from
    /// the `AttributedHTMLBuilder` cache in `init` so warm-cache rows
    /// paint formatted text on the first frame; cold-cache rows leave
    /// this `nil`, render `post.plainText` as a fallback, and upgrade
    /// once `.task` parses the HTML off the main thread. Without the
    /// off-main parse, switching to a freshly-loaded channel kicked off
    /// 20 synchronous SwiftSoup parses on the main thread and froze the
    /// UI for ~1–2 s — the cost of `LazyVStack`-to-`VStack` regressed
    /// because every row's `body` ran on first mount instead of just
    /// the visible 5.
    @State private var attributedBody: AttributedString?

    init(post: Post, onVisibilityChange: ((Bool) -> Void)? = nil) {
        self.post = post
        self.onVisibilityChange = onVisibilityChange
        _attributedBody = State(initialValue: AttributedHTMLBuilder.cached(for: post.bodyHTML))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !post.media.isEmpty {
                MediaGallery(media: post.media)
            }

            if !post.bodyHTML.isEmpty {
                // `attributedBody` is `nil` until either the cache had a hit
                // at `init` time or the off-main parse below completes. In
                // the brief cold-cache window we render `plainText` — same
                // characters, no formatting — which keeps the row's
                // height stable so the upgrade to formatted text doesn't
                // shift surrounding layout.
                Text(attributedBody ?? AttributedString(post.plainText))
                    .font(.body)
                    .lineSpacing(5)
                    // `.textSelection(.enabled)` is deliberately omitted.
                    // On macOS 26, applying it to `Text(AttributedString)`
                    // wires up an NSTextView-backed selection layer per
                    // card that knows about every glyph-run boundary, and
                    // the per-card setup cost compounded into ~200ms
                    // scroll-fling hitches when many cards materialised at
                    // once. Confirmed by binary-search ablation in the
                    // hot scroll path. The Copy Text context-menu item
                    // covers the "I want this text" need; partial-text
                    // drag-selection is the only feature lost.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, post.plainText.dominantWritingDirection)
            }

            if !post.reactions.isEmpty {
                reactionStrip
                    .padding(.top, 4)
            }

            footer
                .padding(.top, 4)
        }
        .padding(16)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topLeading) {
            // A small leading rail signals "unread" without taking layout
            // space. Disappears the moment markRead lands.
            if !post.isRead {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 24)
                    .offset(x: -10, y: 16)
                    .accessibilityLabel("Unread")
            }
        }
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            onVisibilityChange?(visible)
            handleVisibilityChange(visible)
        }
        .task(id: post.id) {
            // Cold-cache fallback: parse off the main thread and upgrade
            // `attributedBody` once available. `init` already took the
            // synchronous fast-path for warm-cache rows, so we skip the
            // detached-task overhead in that case. The `id: post.id`
            // parameter ensures this restarts if the same `PostCard`
            // struct is reused for a different post (e.g. new auto-
            // refreshed post arriving at the tail).
            guard attributedBody == nil, !post.bodyHTML.isEmpty else { return }
            let html = post.bodyHTML
            let parsed = await Task.detached(priority: .userInitiated) {
                AttributedHTMLBuilder().build(from: html)
            }.value
            attributedBody = parsed
        }
        .onDisappear {
            dwellTask?.cancel()
            dwellTask = nil
        }
        .contextMenu {
            if let permalink = post.permalink {
                Button("Open on telegram.org") {
                    NSWorkspace.shared.open(permalink)
                }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(permalink.absoluteString, forType: .string)
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(post.plainText, forType: .string)
            }
            .disabled(post.plainText.isEmpty)
        }
    }

    private func handleVisibilityChange(_ visible: Bool) {
        dwellTask?.cancel()
        dwellTask = nil
        guard visible, !post.isRead, let service else { return }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: Self.readDwell)
            guard !Task.isCancelled else { return }
            service.markRead(post)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let postedAt = post.postedAt {
                Text(postedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            if post.edited {
                Text("· edited")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let views = post.viewsLabel {
                Label(views, systemImage: "eye")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reactionStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(post.reactions, id: \.self) { reaction in
                    HStack(spacing: 4) {
                        Text(reaction.emoji).font(.callout)
                        Text(reaction.count)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: .capsule)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .horizontal)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let permalink = post.permalink {
                Link(destination: permalink) {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct MediaGallery: View {
    let media: [Media]

    /// Spacing between album tiles. 4pt reads more like Telegram than the
    /// 8pt default — the gallery should look like one composite image with
    /// hairline gaps, not a grid of cards.
    private static let tileGap: CGFloat = 4

    /// Cap on total album height. Mirrors `MediaTile.maxHeight` so a tall
    /// 9:16 album can't consume an entire feed page on its own.
    private static let maxAlbumHeight: CGFloat = 480

    var body: some View {
        // Single-image posts (the common case) skip the album container
        // entirely — no layout math, just the tile in its natural aspect.
        if media.count == 1 {
            MediaTile(media: media[0])
        } else {
            // Telegram-style proportional album. `AlbumLayout` is a
            // `Layout`-protocol container, so it gets the parent's proposed
            // width *synchronously* during the layout pass and reports the
            // album's true height on the first render. The previous
            // implementation read width via `onGeometryChange` after the
            // first render, which meant every freshly-mounted multi-image
            // post grew from 1pt to ~488pt on its second render — visible
            // as a scroll-position jump whenever an album scrolled into
            // view inside `LazyVStack`'s recycle window.
            // Pass aspect ratios as a `Sendable` `[Double]` rather than
            // the live `[Media]` (SwiftData `@Model` instances aren't
            // thread-safe, and `Layout` types are `Sendable` because the
            // layout engine may run off the main actor). The subviews
            // still receive the full `Media` — they render on the main
            // actor where SwiftData reads are safe.
            AlbumLayout(
                aspectRatios: media.map { $0.aspectRatio ?? (4.0 / 3.0) },
                gap: Self.tileGap,
                maxHeight: Self.maxAlbumHeight
            ) {
                ForEach(Array(media.enumerated()), id: \.offset) { _, item in
                    MediaTile(media: item, inAlbum: true)
                }
            }
        }
    }
}

/// Per-count Telegram-style album templates. Conforms to `Layout`, so
/// the parent's proposed width is read *synchronously* during the layout
/// pass — `sizeThatFits` returns the album's true height on the first
/// render, eliminating the geometry-read race that previously made
/// multi-image posts grow from ~1pt to ~488pt on second render and
/// jumped scroll position whenever an album crossed the recycle window.
/// Buckets aspect ratios into portrait / square / landscape rather than
/// optimising continuously — good enough to pick a sensible template,
/// dramatically simpler than Telegram's actual layout solver.
private struct AlbumLayout: Layout {
    /// One aspect ratio per media item (in `media` order). Used to pick a
    /// template and size individual tiles; the actual `Media` objects
    /// stay out of this `Sendable` type and are rendered by the subviews
    /// passed via the trailing closure.
    let aspectRatios: [Double]
    let gap: CGFloat
    let maxHeight: CGFloat

    /// Memoised placements for the most recently seen proposed width.
    /// SwiftUI calls `sizeThatFits` and `placeSubviews` once each per
    /// layout pass with the same proposal, so caching here cuts the
    /// template math in half. The cache is per-Layout-instance and
    /// SwiftUI handles invalidation when `aspectRatios`/`gap`/`maxHeight`
    /// change (the struct's stored properties define identity).
    struct Cache {
        var width: CGFloat?
        var placements: [Placement] = []
    }

    struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0, width.isFinite else {
            return CGSize(width: max(0, width), height: 0)
        }
        let placements = cachedPlacements(width: width, cache: &cache)
        let height = placements.map { $0.origin.y + $0.size.height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let placements = cachedPlacements(width: bounds.width, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            guard index < placements.count else { break }
            let placement = placements[index]
            subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    private func cachedPlacements(width: CGFloat, cache: inout Cache) -> [Placement] {
        if cache.width == width { return cache.placements }
        let placements = Self.placements(
            for: aspectRatios,
            width: width,
            gap: gap,
            maxHeight: maxHeight
        )
        cache.width = width
        cache.placements = placements
        return placements
    }

    // MARK: - Template dispatch

    static func placements(
        for ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        switch ratios.count {
        case 0, 1: return []
        case 2: return two(ratios, width: width, gap: gap, maxHeight: maxHeight)
        case 3: return three(ratios, width: width, gap: gap, maxHeight: maxHeight)
        case 4: return four(ratios, width: width, gap: gap, maxHeight: maxHeight)
        case 5: return five(ratios, width: width, gap: gap, maxHeight: maxHeight)
        case 6: return six(ratios, width: width, gap: gap, maxHeight: maxHeight)
        default: return grid(count: ratios.count, columns: 2, width: width, gap: gap, maxHeight: maxHeight)
        }
    }

    // MARK: - Templates

    private static func two(
        _ ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // Always side-by-side, matching native Telegram. The previous
        // "stack two landscape images vertically" branch fired for any
        // ratio > 1.1, which produced two ~480pt-tall full-width tiles
        // for ordinary 4:3 photos — visually reading as two separate
        // posts rather than one grouped pair. Side-by-side at half-width
        // keeps even modest panoramas comfortably tall (~130pt at 21:9),
        // and the wider tile gets cropped via the album tile's
        // `scaledToFill` to match the taller one's height.
        let tileWidth = (width - gap) / 2
        let h = min(maxHeight, max(tileWidth / ratios[0], tileWidth / ratios[1]))
        return [
            Placement(origin: .zero,
                      size: CGSize(width: tileWidth, height: h)),
            Placement(origin: CGPoint(x: tileWidth + gap, y: 0),
                      size: CGSize(width: tileWidth, height: h))
        ]
    }

    private static func three(
        _ ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        let r0 = ratios[0]
        // Wide hero on top + two smaller below, when the lead image is
        // landscape; otherwise lead-on-the-left with two stacked on the
        // right (Telegram's most common 3-up).
        if bucket(r0) == .landscape {
            let topH = min(maxHeight * 0.62, width / r0)
            let bottomW = (width - gap) / 2
            let bottomH = min(maxHeight - topH - gap, bottomW * 0.75)
            return [
                Placement(origin: .zero,
                          size: CGSize(width: width, height: topH)),
                Placement(origin: CGPoint(x: 0, y: topH + gap),
                          size: CGSize(width: bottomW, height: bottomH)),
                Placement(origin: CGPoint(x: bottomW + gap, y: topH + gap),
                          size: CGSize(width: bottomW, height: bottomH))
            ]
        }
        let leftW = width * 0.62 - gap / 2
        let rightW = width - leftW - gap
        let h = min(maxHeight, leftW / max(r0, 0.65))
        let smallH = (h - gap) / 2
        return [
            Placement(origin: .zero,
                      size: CGSize(width: leftW, height: h)),
            Placement(origin: CGPoint(x: leftW + gap, y: 0),
                      size: CGSize(width: rightW, height: smallH)),
            Placement(origin: CGPoint(x: leftW + gap, y: smallH + gap),
                      size: CGSize(width: rightW, height: smallH))
        ]
    }

    private static func four(
        _ ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // Tall hero on the left + three stacked on the right when the lead
        // is portrait; this matches Telegram's "phone-shaped first photo"
        // case. Otherwise plain 2×2.
        if bucket(ratios[0]) == .portrait {
            let leftW = width * 0.6 - gap / 2
            let rightW = width - leftW - gap
            let h = min(maxHeight, leftW / 0.7)
            let smallH = (h - gap * 2) / 3
            return [
                Placement(origin: .zero,
                          size: CGSize(width: leftW, height: h)),
                Placement(origin: CGPoint(x: leftW + gap, y: 0),
                          size: CGSize(width: rightW, height: smallH)),
                Placement(origin: CGPoint(x: leftW + gap, y: smallH + gap),
                          size: CGSize(width: rightW, height: smallH)),
                Placement(origin: CGPoint(x: leftW + gap, y: (smallH + gap) * 2),
                          size: CGSize(width: rightW, height: smallH))
            ]
        }
        return grid(count: ratios.count, columns: 2, width: width, gap: gap, maxHeight: maxHeight)
    }

    private static func five(
        _ ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // Telegram's classic 5-up: two hero tiles on top, three smaller on
        // the bottom. Sized so top:bottom is roughly 4:3.
        let topH = min(maxHeight * 0.58, width * 0.34)
        let bottomH = min(maxHeight - topH - gap, width * 0.25)
        let topW = (width - gap) / 2
        let botW = (width - gap * 2) / 3
        var out: [Placement] = []
        out.append(Placement(origin: .zero,
                             size: CGSize(width: topW, height: topH)))
        out.append(Placement(origin: CGPoint(x: topW + gap, y: 0),
                             size: CGSize(width: topW, height: topH)))
        for i in 0..<3 {
            let x = (botW + gap) * CGFloat(i)
            out.append(Placement(
                origin: CGPoint(x: x, y: topH + gap),
                size: CGSize(width: botW, height: bottomH)
            ))
        }
        return out
    }

    private static func six(
        _ ratios: [Double],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // 3×2 grid. A 2/4 split looks great for some inputs but produces
        // weirdly tiny bottom tiles when the album isn't wide; uniform 3×2
        // is the safer default at feed-card width.
        return grid(count: ratios.count, columns: 3, width: width, gap: gap, maxHeight: maxHeight)
    }

    // MARK: - Generic grid

    /// Plain N-column grid. Used as the fallback for 7+ images and as the
    /// base case for 4 and 6 when no asymmetric template applies. Tile
    /// height is the column width × 0.85 — slightly wider than tall, which
    /// keeps the grid from looking like a wall of squares. Aspect ratios
    /// don't matter for a uniform grid, so we take just the count.
    private static func grid(
        count: Int,
        columns: Int,
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        let cols = max(1, columns)
        let rows = Int(ceil(Double(count) / Double(cols)))
        let tileW = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let idealH = tileW * 0.85
        let totalIdeal = idealH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let scale = min(1, maxHeight / totalIdeal)
        let tileH = idealH * scale
        var out: [Placement] = []
        for i in 0..<count {
            let row = i / cols
            let col = i % cols
            let x = (tileW + gap) * CGFloat(col)
            let y = (tileH + gap) * CGFloat(row)
            out.append(Placement(
                origin: CGPoint(x: x, y: y),
                size: CGSize(width: tileW, height: tileH)
            ))
        }
        return out
    }

    // MARK: - Aspect-ratio bucketing

    private enum Bucket { case portrait, square, landscape }

    private static func bucket(_ ratio: Double) -> Bucket {
        if ratio < 0.9 { return .portrait }
        if ratio > 1.1 { return .landscape }
        return .square
    }
}

private struct MediaTile: View {
    let media: Media

    /// When `true`, the tile accepts whatever size its parent proposes
    /// (used by `AlbumLayout`, which calls `place(at:proposal:)` with
    /// per-tile dimensions). When `false`, the tile sizes itself from
    /// `media.aspectRatio` — the single-image-post path.
    var inAlbum: Bool = false

    /// Cap how tall a single piece of media can get in the natural-aspect
    /// path. A 9:16 phone-shaped post would otherwise consume an entire
    /// feed page on its own. Album tiles bypass this — `AlbumLayout`
    /// already enforces its own per-album cap.
    private let maxHeight: CGFloat = 480

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            image
            if media.kind == .video {
                Label(media.durationLabel ?? "Video", systemImage: "play.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(8)
            }
        }
        .onTapGesture {
            if media.kind == .video {
                if let url = media.assetURL { NSWorkspace.shared.open(url) }
            } else {
                Task { await openInQuickLook() }
            }
        }
    }

    @ViewBuilder
    private var image: some View {
        let loader = LazyImage(request: MediaImageRequest.tile(for: media)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        if inAlbum {
            // `Color.clear` is the canonical "stable sizer" in SwiftUI:
            // it accepts any proposal and reports back exactly the
            // proposed size — no growing, no shrinking. The image renders
            // inside the `.overlay` with `scaledToFill` semantics, and
            // `.clipped()` trims any pixel overflow at the bounds. We
            // tried `.frame(maxWidth: .infinity, maxHeight: .infinity)`
            // here first and it leaked: the range-frame returned the
            // loaded image's intrinsic size when `scaledToFill` advertised
            // it, causing tiles to paint taller than `AlbumLayout`
            // proposed and bleed over the body text below.
            Color.clear
                .overlay { loader }
                .clipped()
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        } else {
            // Same `Color.clear` stable-sizer trick as the in-album
            // branch. The previous chain was
            //   loader.aspectRatio(_, .fit).frame(maxWidth: .infinity, ...)
            // which let `scaledToFill` inside `LazyImage` paint pixels
            // past the aspectRatio'd box and out to the full-width frame
            // — visible as the image bleeding wider than the surrounding
            // post body whenever `media.aspectRatio` was `nil` (Telegram
            // omits `padding-top` on some photos), stale, or mismatched
            // against the loaded asset. Sizing `Color.clear` to the aspect
            // and overlaying the loader makes the rendered box and the
            // clip box the same rectangle.
            let aspect = media.aspectRatio ?? (4.0 / 3.0)
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
                .overlay { loader }
                .clipped()
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        }
    }

    @MainActor
    private func openInQuickLook() async {
        // Prefer `thumbnailURL` — that's the actual image (matches what
        // `MediaImageRequest.tile` already loaded into Nuke's data cache,
        // so this fetch is usually a disk hit). `assetURL` for HTML-parsed
        // posts can be the t.me post permalink (Telegram wraps photos in
        // click-through anchors), which we must never hit unproxied.
        guard let url = media.thumbnailURL ?? media.assetURL else { return }
        do {
            let (data, _) = try await ImagePipeline.shared.data(for: ImageRequest(url: url))
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try data.write(to: tempURL)
            QuickLookManager.shared.show(tempURL)
        } catch {
            // Fail closed. A fallback `NSWorkspace.shared.open(url)` would
            // leak a t.me permalink (or proxied CDN URL) to the system
            // browser, which violates the no-direct-t.me rule.
            NSLog("[QuickLook] fetch failed for <\(url.absoluteString)>: \(error)")
        }
    }
}
