import SwiftUI
import AppKit

/// `NSTableCellView` that hosts our SwiftUI feed rows (`PostCard` or
/// `UnreadDivider`) via `NSHostingView`. This is the "cell" half of the
/// AppKit bridge — the SwiftUI views themselves are unchanged from the
/// pure-SwiftUI implementation.
@MainActor
final class HostingTableCellView: NSTableCellView {
    /// Single hosting view reused across reconfigurations — swapping
    /// `rootView` is cheaper than tearing down and re-installing the host.
    private var hostingView: NSHostingView<AnyView>?

    /// 680-pt max column width, matching the original `LazyVStack`'s
    /// `.frame(maxWidth: 680)`. Beyond this the column would feel cavernous
    /// for reading-oriented content (long line lengths hurt scanability).
    static let columnMaxWidth: CGFloat = 680

    /// Install or update the SwiftUI rootView for this cell. Width-clamp
    /// and centering happen here at the AppKit layer (via autolayout
    /// constraints on the hosting view) rather than as SwiftUI frame
    /// modifiers on the rootView, because flexible SwiftUI frames confused
    /// `NSHostingController.sizeThatFits(in:)` into 2-3× over-allocating
    /// the measured height. See `makeRootView` for the structural reason.
    func configure(
        with row: FeedRow,
        channelService: ChannelService?,
        colorScheme: ColorScheme
    ) {
        let view = Self.makeRootView(
            for: row,
            channelService: channelService,
            colorScheme: colorScheme
        )

        if let host = hostingView {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            // Width: clamp to `columnMaxWidth`, allow shrinking under that.
            // Center horizontally in the cell. Top + bottom pinned so the
            // cell's frame (set by NSTableView from `heightOfRow`) drives
            // the hosting view's height exactly.
            let widthCap = host.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.columnMaxWidth
            )
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
            hostingView = host
        }
    }

    /// Compute the natural height of a row at a given table width.
    ///
    /// Empirical findings (logged measurements across real channel data):
    ///   • `NSHostingController.sizeThatFits(in:)` → 2-3× too large
    ///     (chrome / presenting-context allowance gets included).
    ///   • `NSHostingView.intrinsicContentSize` → collapses aspect-ratio
    ///     views to zero so image rows clip badly.
    ///   • `NSHostingView.sizeThatFits(_:)` → respects aspect modifiers
    ///     (image rows reserve correct space) without the chrome
    ///     inflation. This is the one.
    ///
    /// The proposed size is `width` × unbounded; `NSHostingView` lays out
    /// at the width and returns the natural height including space for
    /// `aspectRatio(_:contentMode: .fit)` media tiles.
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

