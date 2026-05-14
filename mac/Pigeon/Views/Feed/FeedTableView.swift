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

    /// Called when a `.post` row crosses the 30% visibility threshold.
    /// `(postID, visible)` — matches `onScrollVisibilityChange(threshold: 0.3)`.
    var onPostVisibilityChange: ((String, Bool) -> Void)?
    /// Called when the `.unreadDivider` row crosses the 30% threshold.
    var onDividerVisibilityChange: ((Bool) -> Void)?
    /// Called when the last row's visibility changes (isAtBottom tracking).
    var onBottomVisibilityChange: ((Bool) -> Void)?

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
        // Layer-back the entire scroll hierarchy so the GPU compositor can
        // copy cached row layers during scroll instead of redrawing via
        // Core Graphics on the main thread. Without this, a SwiftUI trace
        // showed 400ms+ hitches with "expensive render" narrative and an
        // idle CPU — the smoking gun for non-layer-backed NSHostingView
        // content under NSTableView scroll.
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true

        let tableView = NSTableView()
        tableView.wantsLayer = true
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

        // Observe clip-view bounds to track which rows are on-screen.
        // `postsBoundsChangedNotifications` must be set on the clip view itself.
        scrollView.contentView.postsBoundsChangedNotifications = true
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                coordinator?.handleBoundsChange()
            }
        }

        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.boundsObserver = nil
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
        coordinator.onPostVisibilityChange = onPostVisibilityChange
        coordinator.onDividerVisibilityChange = onDividerVisibilityChange
        coordinator.onBottomVisibilityChange = onBottomVisibilityChange
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

    /// Frame-change observer token. See `FeedTableView.makeNSView` for the
    /// width-invalidation rationale.
    var frameObserver: NSObjectProtocol?
    /// Clip-view bounds-change observer token for visibility tracking.
    var boundsObserver: NSObjectProtocol?

    // MARK: Visibility tracking

    var onPostVisibilityChange: ((String, Bool) -> Void)?
    var onDividerVisibilityChange: ((Bool) -> Void)?
    var onBottomVisibilityChange: ((Bool) -> Void)?

    /// Row indices currently qualifying as visible (≥30% of row height in viewport).
    /// Recomputed on every clip-view bounds change; diff drives callbacks + dwell timers.
    private var qualifiedRowIndices: Set<Int> = []
    /// Last reported isAtBottom value — guards against redundant callback fires.
    private var bottomVisible: Bool = false
    /// Pending dwell work items keyed by postID. Cancelled when the row scrolls off-screen.
    private var dwellItems: [String: DispatchWorkItem] = [:]
    /// Dwell delay before a visible unread post is marked read. Matches PostCard.readDwell.
    private static let dwellDelay: TimeInterval = 0.6

    /// Mount-time scroll placement happens exactly once, after the table
    /// has resolved a real width and measured its rows. Posts are sorted
    /// ascending by `postedAt` — the newest post lives at the last index —
    /// so a fresh channel mount should land the user at the bottom of the
    /// list, matching the Telegram/Messages chat convention.
    private var didPlaceInitialScroll = false

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
        // Signpost bulk re-measure: `noteHeightOfRows` causes NSTableView to
        // synchronously re-ask `heightOfRow` for every row in `indexes`. With
        // ~200 rows × a fresh `NSHostingController` measurement each, this is
        // the prime suspect for the 1267ms hang observed at 14043ms in
        // pigeon-scroll-perf.trace. The signpost spans the entire blocking
        // call so we can attribute the wall-clock time in Instruments.
        let rowCount = rows.count
        let state = AppLog.signpost.beginInterval("BulkMeasure", id: AppLog.signpost.makeSignpostID(), "rows=\(rowCount) width=\(Int(effectiveWidth))")
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        AppLog.signpost.endInterval("BulkMeasure", state)
        placeInitialScrollIfNeeded()
    }

    /// Scroll to the last row on first valid layout. Idempotent — guarded
    /// by `didPlaceInitialScroll` so subsequent width changes (window
    /// resize, sidebar toggle) don't yank the user back to the bottom.
    private func placeInitialScrollIfNeeded() {
        guard !didPlaceInitialScroll,
              let tableView,
              !rows.isEmpty,
              lastMeasuredWidth > 0
        else { return }
        didPlaceInitialScroll = true
        let lastRow = rows.count - 1
        tableView.scrollRowToVisible(lastRow)
        AppLog.scroll.pub("initial scroll → row=<\(lastRow)> of <\(rows.count)>")
    }

    // MARK: Bounds / visibility

    /// Recomputes which rows meet the 30% visibility threshold and diffs
    /// against the previous qualified set. Fires row-level callbacks and
    /// manages dwell timers for unread posts. Called on every clip-view
    /// bounds change (120 fps during scroll) — kept O(k) where k ≈ visible
    /// row count (~5-10) via `tableView.rows(in:)` + `rect(ofRow:)`.
    func handleBoundsChange() {
        guard let tableView else { return }
        let visibleRect = tableView.visibleRect
        let nsRange = tableView.rows(in: visibleRect)

        var newQualified: Set<Int> = []
        if nsRange.location != NSNotFound && nsRange.length > 0 {
            for idx in nsRange.location ..< (nsRange.location + nsRange.length) where idx < rows.count {
                let rowRect = tableView.rect(ofRow: idx)
                guard rowRect.height > 0 else { continue }
                let overlap = rowRect.intersection(visibleRect).height
                if overlap / rowRect.height >= 0.3 {
                    newQualified.insert(idx)
                }
            }
        }

        // isAtBottom: last row qualifies at ≥30% — consistent threshold.
        let lastIdx = rows.count - 1
        let nowBottom = lastIdx >= 0 && newQualified.contains(lastIdx)
        if nowBottom != bottomVisible {
            bottomVisible = nowBottom
            onBottomVisibilityChange?(nowBottom)
        }

        guard newQualified != qualifiedRowIndices else { return }

        let appeared = newQualified.subtracting(qualifiedRowIndices)
        let disappeared = qualifiedRowIndices.subtracting(newQualified)
        qualifiedRowIndices = newQualified

        for idx in disappeared where idx < rows.count {
            switch rows[idx] {
            case .post(let snap):
                onPostVisibilityChange?(snap.id, false)
                cancelDwell(for: snap.id)
            case .unreadDivider:
                onDividerVisibilityChange?(false)
            }
        }

        for idx in appeared where idx < rows.count {
            switch rows[idx] {
            case .post(let snap):
                onPostVisibilityChange?(snap.id, true)
                if !snap.isRead { startDwell(for: snap.id) }
            case .unreadDivider:
                onDividerVisibilityChange?(true)
            }
        }

        AppLog.visible.pub("bounds visible=<\(newQualified.sorted())>")
    }

    private func startDwell(for postID: String) {
        dwellItems[postID]?.cancel()
        let service = channelService
        let item = DispatchWorkItem { service?.markRead(postID: postID) }
        dwellItems[postID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDelay, execute: item)
    }

    private func cancelDwell(for postID: String) {
        dwellItems[postID]?.cancel()
        dwellItems.removeValue(forKey: postID)
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
        // Defer visibility re-report by one runloop tick so AppKit has
        // completed its post-reload layout pass — rect(ofRow:) returns
        // stale geometry if called synchronously here.
        Task { @MainActor [weak self] in self?.handleBoundsChange() }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let feedRow = rows[row]
        // Cell reuse: ask NSTableView for a recycled HostingTableCellView
        // before allocating a fresh one. The cell shell (NSTableCellView +
        // autolayout constraints) is reused; configure() always installs a
        // fresh NSHostingView inside it to avoid stale SwiftUI layout state.
        let identifier = NSUserInterfaceItemIdentifier("FeedHostingCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HostingTableCellView
            ?? {
                let fresh = HostingTableCellView()
                fresh.identifier = identifier
                return fresh
            }()
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
        let state = AppLog.signpost.beginInterval("MeasureRow", id: AppLog.signpost.makeSignpostID())
        let height = measureHeight(for: feedRow, width: effectiveWidth)
        AppLog.signpost.endInterval("MeasureRow", state)
        heightCache[feedRow.id] = height
        AppLog.measure.pub("row=<\(feedRow.id)> width=<\(Int(effectiveWidth))> → <\(Int(height))> shape=<\(shapeDescription(for: feedRow))>")
        return height
    }

    /// Compact one-line summary of a row's content shape for measure logs.
    private func shapeDescription(for row: FeedRow) -> String {
        switch row {
        case .unreadDivider:
            return "divider"
        case .post(let snap):
            let mediaCount = snap.media.count
            let ars = snap.media.map { $0.aspectRatio.map { String(format: "%.2f", $0) } ?? "nil" }.joined(separator: ",")
            let bodyLen = snap.plainText.count
            return "media=<\(mediaCount)> ar=<\(ars)> bodyLen=<\(bodyLen)>"
        }
    }

    /// Canonical SwiftUI-in-NSTableView height measurement.
    ///
    /// Fresh `NSHostingController` per call, `preferredContentSize` after
    /// a layout pass. This is the only API combination verified to honor
    /// both `.aspectRatio(_, .fit)` media AND multi-line wrapped text.
    ///
    /// The render path (HostingTableCellView.configure) always creates a
    /// fresh NSHostingView — stale rootView swaps caused height mismatches
    /// (diagnostic 2026-05-13). Height cache ensures each row allocates
    /// only once per width.
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
        let controller = NSHostingController(rootView: constrained)
        controller.sizingOptions = .preferredContentSize
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        controller.view.layoutSubtreeIfNeeded()
        return controller.preferredContentSize.height
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Posts are read-only stream items, not selectable list rows.
        false
    }
}

