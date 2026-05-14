import SwiftUI
import AppKit

/// `NSTableCellView` that hosts our SwiftUI feed rows (`PostCard` or
/// `UnreadDivider`) via `NSHostingView`. This is the "cell" half of the
/// AppKit bridge — the SwiftUI views themselves are unchanged from the
/// pure-SwiftUI implementation.
@MainActor
final class HostingTableCellView: NSTableCellView {
    /// 680-pt max column width, matching the original `LazyVStack`'s
    /// `.frame(maxWidth: 680)`. Beyond this the column would feel cavernous
    /// for reading-oriented content (long line lengths hurt scanability).
    static let columnMaxWidth: CGFloat = 680

    /// Install a fresh SwiftUI host for this cell. A new `NSHostingView` is
    /// created on every configure — we never swap `rootView` on a reused
    /// host. Swapping rootView preserves stale SwiftUI layout state from the
    /// previous post, causing height mismatches (diagnostic 2026-05-13:
    /// cell.h=1112 host.fitting=286). The cell VIEW itself is reused via
    /// `NSTableView.makeView(withIdentifier:owner:)`, which avoids the
    /// expensive autolayout constraint setup; the host inside it is cheap to
    /// recreate per configure.
    private var hostedView: NSHostingView<AnyView>?

    func configure(
        with row: FeedRow,
        channelService: ChannelService?,
        colorScheme: ColorScheme
    ) {
        // Remove only the view we installed — avoids nuking internal
        // NSTableCellView subviews AppKit may manage.
        hostedView?.removeFromSuperview()
        hostedView = nil

        wantsLayer = true
        let view = Self.makeRootView(for: row, channelService: channelService, colorScheme: colorScheme)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        addSubview(host)
        hostedView = host
        // Width: clamp to `columnMaxWidth`, allow shrinking under that.
        // Center horizontally in the cell. Top + bottom pinned so the
        // cell's frame (set by NSTableView from `heightOfRow`) drives
        // the hosting view's height exactly.
        let widthCap = host.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnMaxWidth)
        widthCap.priority = .required
        let fillWidth = host.widthAnchor.constraint(equalTo: widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthCap,
            fillWidth,
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Build the SwiftUI view tree to host for a given row.
    ///
    /// Does NOT include outer flexible frames (`.frame(maxWidth: .infinity)`
    /// or `.frame(maxWidth: 680)`). The 680 column-width clamp and
    /// horizontal centering are handled at the AppKit cell layer (see
    /// `configure`) via autolayout. This keeps the SwiftUI view tree
    /// simple and lets measurement (`Coordinator.measureHeight`) work
    /// against a stable, concrete-width layout.
    static func makeRootView(
        for row: FeedRow,
        channelService: ChannelService?,
        colorScheme: ColorScheme
    ) -> AnyView {
        switch row {
        case .unreadDivider:
            return AnyView(
                UnreadDivider()
                    .padding(.horizontal, 32)
                    .environment(\.colorScheme, colorScheme)
            )
        case .post(let snap):
            return AnyView(
                PostCard(post: snap)
                    .padding(.horizontal, 32)
                    .environment(\.channelService, channelService)
                    .environment(\.colorScheme, colorScheme)
            )
        }
    }
}

/// Inline "Unread messages" rule. Position is frozen for the session by
/// `ChannelFeedContent.firstUnreadID` — the divider stays put even after
/// the dwell-driven `markRead` cascade flips its anchor post to read.
struct UnreadDivider: View {
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
