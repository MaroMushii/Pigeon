import SwiftUI

/// Curated-channel chip grid shown in `AddChannelSheet`. Owns the chip
/// view itself and the flow layout; the parent owns the data + add
/// callback.
struct PopularChannelChips: View {
    let channels: [PopularChannelInfo]
    let addedUsernames: Set<String>
    let inflightUsernames: Set<String>
    let onTap: (PopularChannelInfo) -> Void

    var body: some View {
        ScrollView(.vertical) {
            HFlow(spacing: 8, lineSpacing: 8) {
                ForEach(channels, id: \.username) { channel in
                    PopularChannelChip(
                        username: channel.username,
                        displayName: channel.displayName,
                        state: state(for: channel.username),
                        onTap: { onTap(channel) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
        .contentMargins(.vertical, 16, for: .scrollContent)
        .overlay(alignment: .top) { edgeFade(edge: .top) }
        .overlay(alignment: .bottom) { edgeFade(edge: .bottom) }
    }

    private func state(for username: String) -> PopularChannelChip.State {
        if addedUsernames.contains(username) { return .added }
        if inflightUsernames.contains(username) { return .loading }
        return .idle
    }

    private func edgeFade(edge: VerticalEdge) -> some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor).opacity(0)
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: 28)
        .allowsHitTesting(false)
    }
}

private struct PopularChannelChip: View {
    enum State { case idle, loading, added }

    let username: String
    let displayName: String
    let state: State
    let onTap: () -> Void
    private let avatarBackground: Color

    init(username: String, displayName: String, state: State, onTap: @escaping () -> Void) {
        self.username = username
        self.displayName = displayName
        self.state = state
        self.onTap = onTap
        var hash: UInt32 = 0
        for byte in username.utf8 {
            hash = hash &* 31 &+ UInt32(byte)
        }
        let hue = Double(hash % 360) / 360.0
        self.avatarBackground = Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                avatar
                Text(displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                trailingGlyph
                    .frame(width: 12, height: 12)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(background, in: .capsule)
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            .foregroundStyle(foreground)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(state != .idle)
        .animation(.snappy(duration: 0.18), value: state)
    }

    @ViewBuilder
    private var avatar: some View {
        if let nsImage = NSImage(named: "PopularChannels/\(username)") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(.circle)
        } else {
            Circle()
                .fill(avatarBackground)
                .frame(width: 22, height: 22)
                .overlay(
                    Text(initials)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }

    @ViewBuilder
    private var trailingGlyph: some View {
        switch state {
        case .idle:
            Image(systemName: "plus")
                .font(.caption2.weight(.bold))
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .added:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
        }
    }

    private var background: AnyShapeStyle {
        switch state {
        case .idle, .loading:
            AnyShapeStyle(Color.secondary.opacity(0.12))
        case .added:
            AnyShapeStyle(Color.accentColor.opacity(0.15))
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle, .loading: Color.secondary.opacity(0.25)
        case .added:          Color.accentColor.opacity(0.35)
        }
    }

    private var foreground: AnyShapeStyle {
        switch state {
        case .idle, .loading: AnyShapeStyle(.primary)
        case .added:          AnyShapeStyle(Color.accentColor)
        }
    }

    private var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

private struct HFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let advance = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if advance > maxWidth, rowWidth > 0 {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = advance
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
