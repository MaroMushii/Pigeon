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

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 360), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(media.enumerated()), id: \.offset) { _, item in
                MediaTile(media: item)
            }
        }
    }
}

private struct MediaTile: View {
    let media: Media

    /// Cap how tall a single piece of media can get. A 9:16 phone-shaped
    /// post would otherwise consume an entire feed page on its own.
    private let maxHeight: CGFloat = 480

    var body: some View {
        let aspect = media.aspectRatio ?? (4.0 / 3.0)

        ZStack(alignment: .bottomTrailing) {
            LazyImage(request: MediaImageRequest.tile(for: media)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .clipped()
            .clipShape(.rect(cornerRadius: 10, style: .continuous))

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
