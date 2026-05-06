import SwiftUI
import Nuke
import NukeUI

/// One post in the feed: header, optional media, attributed body, reactions,
/// footer. The whole card is one selectable unit but selection isn't
/// persistent — selecting just highlights for copy/share.
struct PostCard: View {
    let post: Post

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !post.media.isEmpty {
                MediaGallery(media: post.media)
            }

            if !post.bodyHTML.isEmpty {
                Text(Self.attributedBuilder.build(from: post.bodyHTML))
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
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
            handleVisibilityChange(visible)
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
        HStack(spacing: 6) {
            ForEach(post.reactions, id: \.self) { reaction in
                HStack(spacing: 4) {
                    Text(reaction.emoji).font(.callout)
                    Text(reaction.count)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: .capsule)
            }
        }
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

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        // Single-image posts (the common case) skip the gallery container
        // entirely — no layout math, just the tile in its natural aspect.
        if media.count == 1 {
            MediaTile(media: media[0])
        } else {
            // Telegram-style proportional album. Width is read once via a
            // background GeometryReader → preference, then every child is
            // placed with an explicit `.frame(width:height:)`. No lazy
            // containers, no aspect-ratio modifiers fighting each other,
            // no fixed columns that ignore portrait/landscape mix.
            AlbumLayout(
                media: media,
                width: availableWidth,
                gap: Self.tileGap,
                maxHeight: Self.maxAlbumHeight
            )
            .frame(height: AlbumLayout.height(
                for: media,
                width: availableWidth,
                gap: Self.tileGap,
                maxHeight: Self.maxAlbumHeight
            ))
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                availableWidth = newWidth
            }
        }
    }
}

/// Per-count layout templates. Each template returns explicit
/// `(rect, media)` placements for a given container width; `MediaGallery`
/// renders them as plain positioned tiles. Buckets aspect ratios into
/// portrait / square / landscape rather than optimising continuously —
/// good enough to pick a sensible template, dramatically simpler than
/// Telegram's actual layout solver.
private struct AlbumLayout: View {
    let media: [Media]
    let width: CGFloat
    let gap: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        let placements = Self.placements(
            for: media,
            width: width,
            gap: gap,
            maxHeight: maxHeight
        )
        ZStack(alignment: .topLeading) {
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                MediaTile(media: placement.media, fixedSize: placement.size)
                    .offset(x: placement.origin.x, y: placement.origin.y)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    struct Placement {
        let media: Media
        let origin: CGPoint
        let size: CGSize
    }

    /// Convenience: total album height for the placements that would be
    /// produced at this width. `MediaGallery` uses it to size its
    /// own `.frame(height:)` once the parent's width is known.
    static func height(
        for media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        guard width > 0 else { return 1 }
        let placements = placements(for: media, width: width, gap: gap, maxHeight: maxHeight)
        let bottom = placements.map { $0.origin.y + $0.size.height }.max() ?? 0
        return max(1, bottom)
    }

    // MARK: - Template dispatch

    static func placements(
        for media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        switch media.count {
        case 0, 1: return []
        case 2: return two(media, width: width, gap: gap, maxHeight: maxHeight)
        case 3: return three(media, width: width, gap: gap, maxHeight: maxHeight)
        case 4: return four(media, width: width, gap: gap, maxHeight: maxHeight)
        case 5: return five(media, width: width, gap: gap, maxHeight: maxHeight)
        case 6: return six(media, width: width, gap: gap, maxHeight: maxHeight)
        default: return grid(media, columns: 2, width: width, gap: gap, maxHeight: maxHeight)
        }
    }

    // MARK: - Templates

    private static func two(
        _ media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        let r0 = ratio(media[0])
        let r1 = ratio(media[1])
        // Two landscape images stack vertically — side-by-side would crush
        // each into a thin sliver. Otherwise default to side-by-side.
        if bucket(r0) == .landscape && bucket(r1) == .landscape {
            let totalH0 = width / r0
            let totalH1 = width / r1
            let scale = min(1, maxHeight / (totalH0 + totalH1 + gap))
            let h0 = totalH0 * scale
            let h1 = totalH1 * scale
            return [
                Placement(media: media[0], origin: .zero,
                          size: CGSize(width: width, height: h0)),
                Placement(media: media[1], origin: CGPoint(x: 0, y: h0 + gap),
                          size: CGSize(width: width, height: h1))
            ]
        }
        let tileWidth = (width - gap) / 2
        // Pick height from the *taller* required height so neither tile
        // letterboxes — `scaledToFill` then crops the wider one.
        let h = min(maxHeight, max(tileWidth / r0, tileWidth / r1))
        return [
            Placement(media: media[0], origin: .zero,
                      size: CGSize(width: tileWidth, height: h)),
            Placement(media: media[1], origin: CGPoint(x: tileWidth + gap, y: 0),
                      size: CGSize(width: tileWidth, height: h))
        ]
    }

    private static func three(
        _ media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        let r0 = ratio(media[0])
        // Wide hero on top + two smaller below, when the lead image is
        // landscape; otherwise lead-on-the-left with two stacked on the
        // right (Telegram's most common 3-up).
        if bucket(r0) == .landscape {
            let topH = min(maxHeight * 0.62, width / r0)
            let bottomW = (width - gap) / 2
            let bottomH = min(maxHeight - topH - gap, bottomW * 0.75)
            return [
                Placement(media: media[0], origin: .zero,
                          size: CGSize(width: width, height: topH)),
                Placement(media: media[1], origin: CGPoint(x: 0, y: topH + gap),
                          size: CGSize(width: bottomW, height: bottomH)),
                Placement(media: media[2], origin: CGPoint(x: bottomW + gap, y: topH + gap),
                          size: CGSize(width: bottomW, height: bottomH))
            ]
        }
        let leftW = width * 0.62 - gap / 2
        let rightW = width - leftW - gap
        let h = min(maxHeight, leftW / max(r0, 0.65))
        let smallH = (h - gap) / 2
        return [
            Placement(media: media[0], origin: .zero,
                      size: CGSize(width: leftW, height: h)),
            Placement(media: media[1], origin: CGPoint(x: leftW + gap, y: 0),
                      size: CGSize(width: rightW, height: smallH)),
            Placement(media: media[2], origin: CGPoint(x: leftW + gap, y: smallH + gap),
                      size: CGSize(width: rightW, height: smallH))
        ]
    }

    private static func four(
        _ media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // Tall hero on the left + three stacked on the right when the lead
        // is portrait; this matches Telegram's "phone-shaped first photo"
        // case. Otherwise plain 2×2.
        if bucket(ratio(media[0])) == .portrait {
            let leftW = width * 0.6 - gap / 2
            let rightW = width - leftW - gap
            let h = min(maxHeight, leftW / 0.7)
            let smallH = (h - gap * 2) / 3
            return [
                Placement(media: media[0], origin: .zero,
                          size: CGSize(width: leftW, height: h)),
                Placement(media: media[1], origin: CGPoint(x: leftW + gap, y: 0),
                          size: CGSize(width: rightW, height: smallH)),
                Placement(media: media[2], origin: CGPoint(x: leftW + gap, y: smallH + gap),
                          size: CGSize(width: rightW, height: smallH)),
                Placement(media: media[3], origin: CGPoint(x: leftW + gap, y: (smallH + gap) * 2),
                          size: CGSize(width: rightW, height: smallH))
            ]
        }
        return grid(media, columns: 2, width: width, gap: gap, maxHeight: maxHeight)
    }

    private static func five(
        _ media: [Media],
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
        out.append(Placement(media: media[0], origin: .zero,
                             size: CGSize(width: topW, height: topH)))
        out.append(Placement(media: media[1], origin: CGPoint(x: topW + gap, y: 0),
                             size: CGSize(width: topW, height: topH)))
        for i in 0..<3 {
            let x = (botW + gap) * CGFloat(i)
            out.append(Placement(media: media[2 + i],
                                 origin: CGPoint(x: x, y: topH + gap),
                                 size: CGSize(width: botW, height: bottomH)))
        }
        return out
    }

    private static func six(
        _ media: [Media],
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        // 3×2 grid. A 2/4 split looks great for some inputs but produces
        // weirdly tiny bottom tiles when the album isn't wide; uniform 3×2
        // is the safer default at feed-card width.
        return grid(media, columns: 3, width: width, gap: gap, maxHeight: maxHeight)
    }

    // MARK: - Generic grid

    /// Plain N-column grid. Used as the fallback for 7+ images and as the
    /// base case for 4 and 6 when no asymmetric template applies. Tile
    /// height is the column width × 0.85 — slightly wider than tall, which
    /// keeps the grid from looking like a wall of squares.
    private static func grid(
        _ media: [Media],
        columns: Int,
        width: CGFloat,
        gap: CGFloat,
        maxHeight: CGFloat
    ) -> [Placement] {
        let cols = max(1, columns)
        let rows = Int(ceil(Double(media.count) / Double(cols)))
        let tileW = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let idealH = tileW * 0.85
        let totalIdeal = idealH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let scale = min(1, maxHeight / totalIdeal)
        let tileH = idealH * scale
        var out: [Placement] = []
        for (i, item) in media.enumerated() {
            let row = i / cols
            let col = i % cols
            let x = (tileW + gap) * CGFloat(col)
            let y = (tileH + gap) * CGFloat(row)
            out.append(Placement(
                media: item,
                origin: CGPoint(x: x, y: y),
                size: CGSize(width: tileW, height: tileH)
            ))
        }
        return out
    }

    // MARK: - Aspect-ratio bucketing

    private enum Bucket { case portrait, square, landscape }

    private static func ratio(_ media: Media) -> Double {
        media.aspectRatio ?? (4.0 / 3.0)
    }

    private static func bucket(_ ratio: Double) -> Bucket {
        if ratio < 0.9 { return .portrait }
        if ratio > 1.1 { return .landscape }
        return .square
    }
}

private struct MediaTile: View {
    let media: Media

    /// When non-nil, the tile fills this exact size and clips. Used by
    /// `AlbumLayout` to lay out album children with explicit per-tile
    /// dimensions. Single-image posts pass nil and fall back to the
    /// natural-aspect path below.
    var fixedSize: CGSize? = nil

    /// Cap how tall a single piece of media can get. A 9:16 phone-shaped
    /// post would otherwise consume an entire feed page on its own.
    /// Album tiles override this via `fixedSize`.
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
        if let fixedSize {
            loader
                .frame(width: fixedSize.width, height: fixedSize.height)
                .clipped()
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        } else {
            let aspect = media.aspectRatio ?? (4.0 / 3.0)
            loader
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
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
