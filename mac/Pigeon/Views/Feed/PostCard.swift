import SwiftUI
import NukeUI

/// One post in the feed: header, optional media, attributed body, reactions,
/// footer. The whole card is one selectable unit but selection isn't
/// persistent — selecting just highlights for copy/share.
struct PostCard: View {
    let post: Post

    private static let attributedBuilder = AttributedHTMLBuilder()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !post.media.isEmpty {
                MediaGallery(media: post.media)
            }

            if !post.bodyHTML.isEmpty {
                Text(Self.attributedBuilder.build(from: post.bodyHTML))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !post.reactions.isEmpty {
                reactionStrip
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 0.5)
        )
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

    private var header: some View {
        HStack(spacing: 8) {
            if let postedAt = post.postedAt {
                Text(postedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if post.edited {
                Text("· edited")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let views = post.viewsLabel {
                Label(views, systemImage: "eye")
                    .font(.system(size: 11))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reactionStrip: some View {
        HStack(spacing: 6) {
            ForEach(post.reactions, id: \.self) { reaction in
                HStack(spacing: 4) {
                    Text(reaction.emoji).font(.system(size: 12))
                    Text(reaction.count)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let permalink = post.permalink {
                Link(destination: permalink) {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .labelStyle(.titleAndIcon)
                }
                .foregroundStyle(.tertiary)
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
            LazyImage(url: media.thumbnailURL ?? media.assetURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.secondary.opacity(0.08))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .clipped()
            .clipShape(.rect(cornerRadius: 10, style: .continuous))

            if media.kind == .video {
                Label(media.durationLabel ?? "Video", systemImage: "play.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(8)
            }
        }
        .onTapGesture {
            if let url = media.assetURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
