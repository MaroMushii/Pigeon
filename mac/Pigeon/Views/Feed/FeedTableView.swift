import SwiftUI
import AppKit

/// Unified row type for the channel feed. The point of modelling the
/// unread divider as a `case` rather than an inline `if` is that the
/// underlying table (`NSTableView` here, previously `LazyVStack`) needs
/// a 1:1 row-to-data mapping for stable identity and scroll math.
enum FeedRow: Identifiable, Equatable {
    case unreadDivider
    case post(PostDisplaySnapshot)

    var id: String {
        switch self {
        case .unreadDivider: "row-unread-divider"
        case .post(let snap): "row-post-\(snap.id)"
        }
    }
}

/// AppKit-backed bridge that hosts the channel feed in an `NSTableView`.
/// Replaces our former `ScrollView`+`LazyVStack`+`ScrollViewProxy` stack
/// because pure SwiftUI's lazy stack APIs do not provide deterministic
/// scroll-to-row or accurate row-height estimation for feed-scale lists
/// with variable cell sizes — the reason every production-quality feed
/// UI (Slack, Twitter/X, Telegram-macOS, Messages) bridges to AppKit or
/// UIKit collection views. `NSTableView` measures every row up-front via
/// the delegate, giving us deterministic scroll-to-row, reliable
/// save/restore, and stable visibility tracking.
struct FeedTableView: NSViewRepresentable {
    let rows: [FeedRow]

    @Environment(\.channelService) private var channelService
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 16)
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnSelection = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feed"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.rows = rows
        coordinator.channelService = channelService
        coordinator.colorScheme = colorScheme

        tableView.delegate = coordinator
        tableView.dataSource = coordinator

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.channelService = channelService
        coordinator.colorScheme = colorScheme
        coordinator.update(rows: rows)
    }
}

@MainActor
final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    var rows: [FeedRow] = []
    weak var tableView: NSTableView?
    weak var scrollView: NSScrollView?
    var channelService: ChannelService?
    var colorScheme: ColorScheme = .light

    /// Per-row height cache keyed by `FeedRow.id`. Invalidated whenever the
    /// table's width changes, because PostCard wraps text — height depends
    /// on width. `NSTableView` also caches our `heightOfRow` returns, but
    /// we cache locally so a `reloadData()` doesn't re-measure every cell.
    private var heightCache: [String: CGFloat] = [:]
    private var lastMeasuredWidth: CGFloat = 0

    /// Persistent measurement host. The canonical NSHostingView+sizingOptions
    /// pattern requires reusing a single host across measurements rather than
    /// allocating one per call — `.intrinsicContentSize` narrows the layout
    /// probe to just the intrinsic size (avoiding the `[.minSize, .intrinsicContentSize, .maxSize]`
    /// default, where `.minSize`'s zero-width probe collapses `.aspectRatio(_, .fit)`
    /// chains to height=0 and image cells get clipped). See `measureHeight(for:width:)`.
    private lazy var measurementHost: NSHostingView<AnyView> = {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = .intrinsicContentSize
        return host
    }()

    func update(rows newRows: [FeedRow]) {
        // For step 1 we just reload. Step 7 will replace this with a
        // proper diff + `insertRows`/`removeRows` for animated updates.
        rows = newRows
        tableView?.reloadData()
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let feedRow = rows[row]
        let cell = HostingTableCellView()
        cell.configure(
            with: feedRow,
            channelService: channelService,
            colorScheme: colorScheme
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 0 }
        let feedRow = rows[row]
        let tableWidth = max(0, tableView.bounds.width)
        let effectiveWidth = min(tableWidth, HostingTableCellView.columnMaxWidth)
        if effectiveWidth != lastMeasuredWidth, effectiveWidth > 0 {
            heightCache.removeAll(keepingCapacity: true)
            lastMeasuredWidth = effectiveWidth
        }
        if let cached = heightCache[feedRow.id] {
            return cached
        }
        guard effectiveWidth > 0 else {
            return 280
        }
        let height = measureHeight(for: feedRow, width: effectiveWidth)
        heightCache[feedRow.id] = height
        slog("measure row=<\(feedRow.id)> width=<\(Int(effectiveWidth))> → <\(Int(height))>")
        return height
    }

    /// Canonical SwiftUI-in-NSTableView height measurement, per Apple's
    /// `NSHostingView.sizingOptions` API and the layout-engine semantics
    /// of `.aspectRatio(_, .fit)`.
    ///
    /// Three things must be combined:
    ///   1. `NSHostingView` with `sizingOptions = .intrinsicContentSize`
    ///      (set once on `measurementHost`). Avoids `NSHostingController`'s
    ///      chrome-allowance inflation AND the default multi-probe
    ///      `[.minSize, .intrinsicContentSize, .maxSize]` that returns 0
    ///      for aspect-ratio views during the minSize probe.
    ///   2. `.frame(width: width)` on the rootView — concrete, not
    ///      `maxWidth`. `.aspectRatio(_, .fit)` propagates `nil` width
    ///      upward to discover a concrete proposal; without it the chain
    ///      resolves to width=0 → height=0.
    ///   3. `.fixedSize(horizontal: false, vertical: true)` — tells SwiftUI
    ///      to report its ideal vertical size rather than expanding to
    ///      fill the (effectively unbounded) host height.
    ///
    /// Reusing one `measurementHost` across cells is intentional: the
    /// SizingOptions path is keyed to a stable host's intrinsic-size
    /// reporting; swapping `rootView` and re-laying-out is cheaper than
    /// allocating a fresh hosting view per row.
    private func measureHeight(for row: FeedRow, width: CGFloat) -> CGFloat {
        let view = HostingTableCellView.makeRootView(
            for: row,
            channelService: channelService,
            colorScheme: colorScheme
        )
        let constrained = AnyView(
            view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
        )
        measurementHost.rootView = constrained
        measurementHost.layoutSubtreeIfNeeded()
        return measurementHost.fittingSize.height
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Posts are read-only stream items, not selectable list rows.
        false
    }
}

