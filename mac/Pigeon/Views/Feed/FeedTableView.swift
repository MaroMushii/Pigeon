import SwiftUI
import AppKit

/// Imperative scroll command routed from `ChannelFeedContent` into the
/// `Coordinator` via the `onScrollCommandReady` callback. Replaces the
/// old `ScrollViewProxy` pattern which required a live SwiftUI proxy.
enum ScrollCommand {
    /// Scroll to the last row. `animated` drives `NSAnimationContext`.
    case bottom(animated: Bool)
    /// Scroll so the row matching `id` (a `FeedRow.id` string) appears at
    /// `viewportFraction` from the top of the visible area (0 = top, 1 = bottom).
    case toRow(id: String, viewportFraction: CGFloat, animated: Bool)
}

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
    var onPostVisibilityChange: (@MainActor (String, Bool) -> Void)?
    /// Called when the `.unreadDivider` row crosses the 30% threshold.
    var onDividerVisibilityChange: (@MainActor (Bool) -> Void)?
    /// Called when the last row's visibility changes (isAtBottom tracking).
    var onBottomVisibilityChange: (@MainActor (Bool) -> Void)?

    /// Scroll target applied exactly once on the first valid layout pass.
    /// Defaults to `.bottom` so a fresh channel opens at the newest post.
    var initialScrollCommand: ScrollCommand = .bottom(animated: false)
    /// Delivers a scroll-action closure to the caller so they can command
    /// programmatic scrolls after mount. Mirrors `ScrollViewReader`'s pattern
    /// but routes into the `Coordinator` instead of a SwiftUI proxy.
    var onScrollCommandReady: (@MainActor (@escaping @MainActor (ScrollCommand) -> Void) -> Void)?
    /// Fired exactly once when the first bulk row-height measurement
    /// drains. `ChannelFeedContent` uses this to flip its `phase` from
    /// `.preparing` to `.ready`, revealing the feed against fully-measured
    /// rows. Width-change re-measurements (window resize) do not re-fire
    /// this — the closure is one-shot per coordinator lifetime.
    var onMeasurementComplete: (@MainActor () -> Void)?

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
        // One-shot install — `updateNSView` must NOT re-assign this slot.
        // The coordinator clears it after firing, and re-assigning on every
        // SwiftUI re-render would resurrect a stale closure and re-fire
        // `phase = .ready` on width-change re-measurements.
        coordinator.onMeasurementComplete = onMeasurementComplete

        tableView.delegate = coordinator
        tableView.dataSource = coordinator

        scrollView.documentView = tableView

        // Deliver the scroll-action closure to the caller. Strong capture is
        // correct: the Coordinator is owned by the NSViewRepresentable lifecycle
        // (SwiftUI holds it), not by this closure, so there is no retain cycle.
        let scrollAction: @MainActor (ScrollCommand) -> Void = { cmd in
            coordinator.perform(cmd)
        }
        onScrollCommandReady?(scrollAction)

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
        coordinator.cancelAllDwells()
        coordinator.cancelMeasurement()
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
        coordinator.setInitialScrollCommand(initialScrollCommand)
        // Re-deliver the scroll action on every update in case the struct was
        // recreated before makeNSView's delivery reached prefetch.performScroll.
        if let action = onScrollCommandReady {
            let c = coordinator
            action { cmd in c.perform(cmd) }
        }
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

    var onPostVisibilityChange: (@MainActor (String, Bool) -> Void)?
    var onDividerVisibilityChange: (@MainActor (Bool) -> Void)?
    var onBottomVisibilityChange: (@MainActor (Bool) -> Void)?

    /// Row indices currently qualifying as visible (≥30% of row height in viewport).
    /// Recomputed on every clip-view bounds change; diff drives callbacks + dwell timers.
    private var qualifiedRowIndices: Set<Int> = []
    /// Last reported isAtBottom value — guards against redundant callback fires.
    private var bottomVisible: Bool = false
    /// True between `reloadData()` and the deferred `handleBoundsChange()` call.
    /// Suppresses the intermediate bounds event that fires with stale row geometry.
    private var isReloading: Bool = false
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
    /// Scroll target to apply on first valid layout. Set by `ChannelFeedContent`
    /// via `setInitialScrollCommand`; consumed once by `placeInitialScrollIfNeeded`.
    private var pendingInitialScroll: ScrollCommand?

    /// In-flight chunked row-measurement task. Owned by the coordinator so
    /// it can be cancelled when the view is dismantled (channel switch),
    /// when a new frame-change kicks off a re-measurement, or when an
    /// update mutates `rows` mid-flight.
    private var measurementTask: Task<Void, Never>?
    /// One-shot signal fired exactly once when the first bulk measurement
    /// drains. `ChannelFeedContent` uses this to flip `phase` from
    /// `.preparing` to `.ready`, revealing the feed against fully-measured
    /// rows. Cleared after firing so width-change re-measurements don't
    /// re-fire it.
    var onMeasurementComplete: (@MainActor () -> Void)?
    /// Chunk size for the async measurement loop. ~16 rows × ~6ms per row
    /// ≈ 100ms per synchronous chunk; the `await Task.yield()` between
    /// chunks lets AppKit drain pending input (sidebar clicks) so the UI
    /// remains responsive during the initial measurement window.
    private static let measurementChunkSize = 16

    /// Called when the table view's frame changes (e.g. window resize, or
    /// the initial scroll-view layout pass that brings the table from its
    /// tiny default bounds to its real size). Drops the height cache and
    /// drives a chunked re-measurement of every row.
    ///
    /// Background: a single synchronous `noteHeightOfRows(IndexSet(0..<n))`
    /// for ~200 rows × a fresh `NSHostingController` per row produced a
    /// 1267ms main-thread hang at 14043ms in `pigeon-scroll-perf.trace`.
    /// During that window AppKit cannot deliver new mouse events, so the
    /// sidebar feels locked. We now measure in chunks of
    /// `measurementChunkSize` rows, yielding between chunks so input
    /// events get processed. `placeInitialScrollIfNeeded` runs once at the
    /// end, against fully-measured rows — preserving the exact scroll-
    /// restore behavior we had before (unread divider, "at bottom",
    /// re-click cycle).
    func handleTableFrameChange() {
        guard let tableView else { return }
        let width = max(0, tableView.bounds.width)
        let effectiveWidth = min(width, HostingTableCellView.columnMaxWidth)
        guard effectiveWidth != lastMeasuredWidth, effectiveWidth > 0 else { return }
        heightCache.removeAll(keepingCapacity: true)
        lastMeasuredWidth = effectiveWidth

        // If a previous measurement is still in flight (rapid width change,
        // window resize during initial load) cancel it so we don't double-
        // measure with stale width.
        measurementTask?.cancel()

        let rowCount = rows.count
        let chunkSize = Self.measurementChunkSize
        let state = AppLog.signpost.beginInterval(
            "BulkMeasure",
            id: AppLog.signpost.makeSignpostID(),
            "rows=\(rowCount) width=\(Int(effectiveWidth)) chunked"
        )
        measurementTask = Task { @MainActor [weak self] in
            defer { AppLog.signpost.endInterval("BulkMeasure", state) }
            var idx = 0
            while idx < rowCount {
                guard !Task.isCancelled, let self else { return }
                // Re-read `self.rows.count` so a mid-flight `update()` that
                // shrinks the row array can't push us past the end. The
                // bounds guard in `heightOfRow` further protects against
                // races between this loop and a concurrent reload.
                let end = min(idx + chunkSize, self.rows.count)
                guard end > idx else { break }
                self.tableView?.noteHeightOfRows(withIndexesChanged: IndexSet(idx..<end))
                idx = end
                await Task.yield()
            }
            guard !Task.isCancelled, let self else { return }
            self.placeInitialScrollIfNeeded()
            // One-shot: clear before firing so a width-change re-measure
            // can't re-trigger `phase = .ready` on an already-revealed feed.
            let completion = self.onMeasurementComplete
            self.onMeasurementComplete = nil
            self.measurementTask = nil
            completion?()
        }
    }

    /// Accept a scroll target for the first layout pass. No-ops once the
    /// initial placement has already fired — guards against `updateNSView`
    /// re-pushing on subsequent renders.
    func setInitialScrollCommand(_ cmd: ScrollCommand) {
        guard !didPlaceInitialScroll else { return }
        pendingInitialScroll = cmd
        AppLog.scroll.pub("pendingInitialScroll set: <\(cmd)>")
    }

    /// Execute a scroll command immediately. Safe to call at any time after
    /// the table has a real layout; silently no-ops if geometry is not ready.
    func perform(_ command: ScrollCommand) {
        switch command {
        case .bottom(let animated):
            guard let tableView, !rows.isEmpty else { return }
            let lastRow = rows.count - 1
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.allowsImplicitAnimation = true
                    tableView.scrollRowToVisible(lastRow)
                }
            } else {
                tableView.scrollRowToVisible(lastRow)
            }
            AppLog.scroll.pub("scroll → bottom row=<\(lastRow)> animated=<\(animated)>")

        case .toRow(let rowID, let fraction, let animated):
            guard let tableView, let scrollView else { return }
            guard let idx = rows.firstIndex(where: { $0.id == rowID }) else {
                AppLog.scroll.pub("scroll → toRow id=<\(rowID)> NOT FOUND in <\(rows.count)> rows")
                return
            }
            let rowRect = tableView.rect(ofRow: idx)
            guard rowRect.height > 0 else { return }
            let viewportH = scrollView.contentView.bounds.height
            guard viewportH > 0 else { return }
            let targetY = rowRect.minY - viewportH * fraction
            let maxY = max(0, tableView.frame.height - viewportH)
            let clampedY = max(0, min(targetY, maxY))
            let point = NSPoint(x: 0, y: clampedY)
            AppLog.scroll.pub("scroll → toRow id=<\(rowID)> idx=<\(idx)> fraction=<\(fraction)> targetY=<\(Int(clampedY))> animated=<\(animated)>")
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.allowsImplicitAnimation = true
                    scrollView.contentView.setBoundsOrigin(point)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            } else {
                scrollView.contentView.scroll(to: point)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Scroll to the last row on first valid layout. Uses `pendingInitialScroll`
    /// if set (from `ChannelFeedContent`), otherwise defaults to the bottom row.
    /// Idempotent — `didPlaceInitialScroll` prevents re-firing on window resize.
    private func placeInitialScrollIfNeeded() {
        guard !didPlaceInitialScroll,
              let tableView,
              !rows.isEmpty,
              lastMeasuredWidth > 0
        else { return }
        didPlaceInitialScroll = true
        if let cmd = pendingInitialScroll {
            pendingInitialScroll = nil
            perform(cmd)
        } else {
            let lastRow = rows.count - 1
            tableView.scrollRowToVisible(lastRow)
            AppLog.scroll.pub("initial scroll → bottom row=<\(lastRow)> of <\(rows.count)> (default)")
        }
    }

    // MARK: Bounds / visibility

    /// Recomputes which rows meet the 30% visibility threshold and diffs
    /// against the previous qualified set. Fires row-level callbacks and
    /// manages dwell timers for unread posts. Called on every clip-view
    /// bounds change (120 fps during scroll) — kept O(k) where k ≈ visible
    /// row count (~5-10) via `tableView.rows(in:)` + `rect(ofRow:)`.
    func handleBoundsChange() {
        guard let tableView, !isReloading else { return }
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
        isReloading = true
        tableView?.reloadData()
        // Defer visibility re-report one runloop tick: AppKit posts a bounds
        // change during reloadData with stale row geometry. `isReloading`
        // suppresses that event; the Task hop runs after layout settles.
        Task { @MainActor [weak self] in
            self?.isReloading = false
            self?.handleBoundsChange()
        }
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
        let cacheKey = heightCacheKey(for: feedRow)
        if let cached = heightCache[cacheKey] {
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
        heightCache[cacheKey] = height
        AppLog.measure.pub("row=<\(feedRow.id)> width=<\(Int(effectiveWidth))> → <\(Int(height))> shape=<\(shapeDescription(for: feedRow))>")
        return height
    }

    /// Cache key that changes when height-affecting content changes.
    /// Includes body length, media count, and reaction count so an edited
    /// post gets a fresh measurement rather than reusing a stale cached height.
    private func heightCacheKey(for row: FeedRow) -> String {
        switch row {
        case .unreadDivider:
            return "divider"
        case .post(let snap):
            return "\(snap.id)|\(snap.bodyHTML.count)|\(snap.media.count)|\(snap.reactions.count)"
        }
    }

    func cancelAllDwells() {
        dwellItems.values.forEach { $0.cancel() }
        dwellItems.removeAll()
    }

    /// Cancel an in-flight chunked measurement. Used by `dismantleNSView`
    /// (channel switch) and by `update()` when a refresh mutates `rows`
    /// mid-measurement. The next frame-change or layout pass will start a
    /// fresh measurement if one is still needed.
    func cancelMeasurement() {
        measurementTask?.cancel()
        measurementTask = nil
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

