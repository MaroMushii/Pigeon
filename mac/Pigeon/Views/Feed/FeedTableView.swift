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
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

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

        // Observe frame changes on the table so we can invalidate height
        // cache and re-ask `heightOfRow` once the scroll view has actually
        // been laid out with a real width. Without this, initial
        // `reloadData` fires while the table is at its tiny default
        // bounds (~100pt) — every cell gets measured at that width,
        // text wraps to dozens of lines, heights end up in the
        // thousands of points, and `NSTableView` happily caches those
        // wrong values forever because we never tell it to re-ask.
        tableView.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: tableView,
            queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                coordinator?.handleTableFrameChange()
            }
        }

        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // Detect whether *anything* the cells care about actually changed.
        // SwiftUI calls `updateNSView` on every parent re-render — environment
        // pulses, binding writes, parent recomputes — and the previous
        // implementation called `reloadData()` unconditionally on each one.
        // `reloadData()` tears down every visible `NSHostingView`, which means
        // every PostCard's `@State`, `@StateObject` (incl. LazyImage's image
        // viewModel), and `.task(id:)` get rebuilt from scratch on every
        // spurious update. A SwiftUI Instruments trace showed this as
        // ~125k transaction edges into `LazyImage.viewModel` and ~100k into
        // `_TaskValueModifier.taskState` over 20s — pure waste from cells
        // that didn't need to change.
        let envChanged = coordinator.channelService !== channelService
            || coordinator.colorScheme != colorScheme
        coordinator.channelService = channelService
        coordinator.colorScheme = colorScheme
        coordinator.update(rows: rows, envChanged: envChanged)
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

    /// Frame-change observer token. See `FeedTableView.makeNSView` for the
    /// width-invalidation rationale.
    var frameObserver: NSObjectProtocol?

    /// Called when the table view's frame changes (e.g. window resize, or
    /// the initial scroll-view layout pass that brings the table from its
    /// tiny default bounds to its real size). Drops the height cache and
    /// tells `NSTableView` to re-ask `heightOfRow` for every row.
    func handleTableFrameChange() {
        guard let tableView else { return }
        let width = max(0, tableView.bounds.width)
        let effectiveWidth = min(width, HostingTableCellView.columnMaxWidth)
        guard effectiveWidth != lastMeasuredWidth, effectiveWidth > 0 else { return }
        heightCache.removeAll(keepingCapacity: true)
        lastMeasuredWidth = effectiveWidth
        let indexes = IndexSet(0..<rows.count)
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
    }

    func update(rows newRows: [FeedRow], envChanged: Bool) {
        // Skip the reload entirely when nothing the cells render has
        // actually changed. `FeedRow` is `Equatable`, so this is a cheap
        // O(n) compare on ~200 rows. See `updateNSView` for why this gate
        // exists (collapses 90%+ of spurious cell teardowns).
        let rowsChanged = newRows != rows
        rows = newRows
        guard rowsChanged || envChanged else {
            AppLog.feed.pub("update skipped — rows + env unchanged (n=\(newRows.count))")
            return
        }
        AppLog.feed.pub("update reload — rowsChanged=\(rowsChanged) envChanged=\(envChanged) n=\(newRows.count)")
        // For now we still do a full reload on legitimate change. Step 7
        // will replace this with a `[FeedRow]` diff + `insertRows` /
        // `removeRows` for animated updates and per-row preservation.
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
        // Below 200pt the table hasn't been laid out yet — measuring at
        // those widths produces absurd heights (text wraps to dozens of
        // lines). Return a placeholder; the frame-change observer will
        // invalidate + re-ask when the real width arrives.
        guard effectiveWidth >= 200 else {
            return 280
        }
        let height = measureHeight(for: feedRow, width: effectiveWidth)
        heightCache[feedRow.id] = height
        AppLog.measure.pub("row=<\(feedRow.id)> width=<\(Int(effectiveWidth))> → <\(Int(height))>")
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
        // With `sizingOptions = .intrinsicContentSize` set on the host,
        // SwiftUI's intrinsic size is exposed via the host's
        // `intrinsicContentSize` (NOT `fittingSize`, which queries the
        // AppKit autolayout pathway and falls back to screen bounds for
        // an unrooted host — observed empirically as ~2117pt clamps).
        // Explicit frame width grounds SwiftUI's layout at the target
        // size before we read intrinsic.
        measurementHost.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        measurementHost.rootView = constrained
        measurementHost.layoutSubtreeIfNeeded()
        return measurementHost.intrinsicContentSize.height
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Posts are read-only stream items, not selectable list rows.
        false
    }
}

