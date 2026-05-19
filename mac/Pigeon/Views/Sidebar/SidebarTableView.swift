import SwiftUI
import AppKit
import SwiftData

/// AppKit-backed sidebar channel list. Re-click detection works by subclassing
/// `NSTableView` and capturing `selectedRow == clickedRow` in `mouseDown`
/// BEFORE `super.mouseDown` processes the event — the only moment we can
/// reliably distinguish "row was already selected" from "row just got selected".
/// `shouldSelectRow` is NOT used for this: it only fires when selection is
/// changing, so it never sees clicks on already-selected rows.
struct SidebarTableView: NSViewRepresentable {
    let channels: [Channel]
    @Binding var selectedID: PersistentIdentifier?
    var onReClick: @MainActor (Channel) -> Void
    var channelService: ChannelService?
    var appState: AppState
    var colorScheme: ColorScheme

    func makeCoordinator() -> SidebarCoordinator { SidebarCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true

        let coordinator = context.coordinator

        let tableView = SidebarNSTableView()
        tableView.onRowReClick = { [weak coordinator] row in
            coordinator?.handleReClick(row: row)
        }
        tableView.wantsLayer = true
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnSelection = false
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        coordinator.tableView = tableView
        coordinator.channelService = channelService
        coordinator.appState = appState
        coordinator.colorScheme = colorScheme

        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.selectionHighlightStyle = .regular

        // Context menu: AppKit calls menuNeedsUpdate before showing it,
        // where we populate items for whichever row was right-clicked.
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let envChanged = coordinator.channelService !== channelService
            || coordinator.colorScheme != colorScheme
        coordinator.channelService = channelService
        coordinator.appState = appState
        coordinator.colorScheme = colorScheme
        coordinator.onReClick = onReClick
        let binding = _selectedID
        coordinator.onSelectionChange = { id in
            binding.wrappedValue = id
        }
        coordinator.update(channels: channels, selectedID: selectedID, envChanged: envChanged)
    }
}

// MARK: - Coordinator

@MainActor
final class SidebarCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
    var channels: [Channel] = []
    var channelService: ChannelService?
    var appState: AppState?
    var colorScheme: ColorScheme = .light
    var onReClick: (@MainActor (Channel) -> Void)?
    var onSelectionChange: (@MainActor (PersistentIdentifier?) -> Void)?
    weak var tableView: NSTableView?

    func update(channels newChannels: [Channel], selectedID newID: PersistentIdentifier?, envChanged: Bool) {
        let channelsChanged = newChannels.map(\.persistentModelID) != channels.map(\.persistentModelID)
        channels = newChannels
        if channelsChanged || envChanged {
            tableView?.reloadData()
        }
        applySelection(selectedID: newID)
    }

    /// Sync the table's selection to match the given ID.
    /// `SidebarNSTableView.mouseDown` won't fire during `selectRowIndexes`
    /// (it's programmatic, not user-initiated), so no re-click spuriously fires.
    private func applySelection(selectedID: PersistentIdentifier?) {
        guard let tableView else { return }
        if let id = selectedID,
           let row = channels.firstIndex(where: { $0.persistentModelID == id }) {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            if tableView.selectedRow != -1 { tableView.deselectAll(nil) }
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { channels.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < channels.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
            ?? {
                let c = SidebarCellView()
                c.identifier = identifier
                return c
            }()
        cell.configure(with: channels[row], channelService: channelService, colorScheme: colorScheme)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 52 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
        return tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView
            ?? {
                let r = SidebarRowView()
                r.identifier = identifier
                return r
            }()
    }

    func handleReClick(row: Int) {
        guard row < channels.count else { return }
        onReClick?(channels[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView?.selectedRow ?? -1
        let newID: PersistentIdentifier? = row >= 0 && row < channels.count
            ? channels[row].persistentModelID
            : nil
        onSelectionChange?(newID)
    }

    // MARK: NSMenuDelegate

    /// Called just before the context menu is shown. `tableView.clickedRow`
    /// is already set at this point — use it to build channel-specific items.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView,
              let service = channelService else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < channels.count else { return }
        let channel = channels[row]
        menuTargetChannel = channel

        menu.addItem(makeItem("Refresh", action: #selector(menuRefresh)))
        if channel.unreadCount > 0 {
            menu.addItem(makeItem("Mark as Read", action: #selector(menuMarkRead)))
        }
        menu.addItem(makeItem("Open on telegram.org", action: #selector(menuOpenURL)))
        menu.addItem(makeItem(channel.isMuted ? "Unmute" : "Mute", action: #selector(menuToggleMute)))
        menu.addItem(.separator())

        let removeItem = makeItem("Remove", action: #selector(menuRemove))
        removeItem.attributedTitle = NSAttributedString(
            string: "Remove",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(removeItem)
        menu.addItem(.separator())

        menu.addItem(infoItem("@\(channel.username)"))
        if let subs = channel.subscriberCount, !subs.isEmpty {
            menu.addItem(infoItem("\(subs) subscribers"))
        }
        menu.addItem(infoItem("Updated \(Self.updatedLabel(channel.lastFetchedAt))"))
        menu.addItem(infoItem("\(channel.posts.count) posts cached"))

        // Store for use in action selectors — valid until next menuNeedsUpdate.
        _ = service
    }

    // MARK: Context menu actions

    /// The channel targeted by the most recent right-click. Set in
    /// `menuNeedsUpdate` and valid for the lifetime of the open menu.
    private var menuTargetChannel: Channel?

    @objc private func menuRefresh() {
        guard let channel = menuTargetChannel,
              let service = channelService else { return }
        Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
    }

    @objc private func menuMarkRead() {
        guard let channel = menuTargetChannel else { return }
        channelService?.markAllRead(channel)
    }

    @objc private func menuOpenURL() {
        guard let channel = menuTargetChannel else { return }
        NSWorkspace.shared.open(channel.publicURL)
    }

    @objc private func menuToggleMute() {
        guard let channel = menuTargetChannel else { return }
        channelService?.setMuted(channel, !channel.isMuted)
    }

    @objc private func menuRemove() {
        guard let channel = menuTargetChannel else { return }
        channelService?.remove(channel)
        if appState?.selectedChannelID == channel.persistentModelID {
            appState?.selectedChannelID = nil
        }
    }

    // MARK: Helpers

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func updatedLabel(_ date: Date?) -> String {
        guard let date else { return "never" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - NSTableView subclass

/// `NSTableView` subclass that captures re-clicks on the already-selected row.
/// In `mouseDown`, we record whether the target row is already selected BEFORE
/// calling `super` (which processes selection). If it was, we fire `onRowReClick`
/// after `super` returns — at which point the event cycle is complete and the
/// selection state is stable.
final class SidebarNSTableView: NSTableView {
    var onRowReClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let wasAlreadySelected = row >= 0 && selectedRow == row
        super.mouseDown(with: event)
        if wasAlreadySelected { onRowReClick?(row) }
    }
}

// MARK: - Row view

/// `NSTableRowView` that draws the selection highlight with Apple's
/// continuous (squircle) corner geometry. AppKit's default
/// `drawSelection(in:)` uses `CGPath(roundedRect:cornerSize:)` which is
/// the legacy circular curve — visibly inconsistent with every SwiftUI
/// `.rect(cornerRadius:style: .continuous)` elsewhere in the app.
final class SidebarRowView: NSTableRowView {
    private static let cornerRadius: CGFloat = 6
    private static let horizontalInset: CGFloat = 8
    private static let verticalInset: CGFloat = 2

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let rect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        let path = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .path(in: rect)
            .cgPath

        let color = selectionColor()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func selectionColor() -> NSColor {
        let focused = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
            || window?.isKeyWindow == true
        return focused
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
    }
}

// MARK: - Cell

/// NSTableCellView that hosts `ChannelRow` in a SwiftUI `NSHostingView`.
/// The cell shell is reused via `makeView(withIdentifier:owner:)`; we swap
/// `rootView` on reuse (unlike `HostingTableCellView` in the feed, sidebar
/// rows have fixed height so stale layout state is not a concern).
final class SidebarCellView: NSTableCellView {
    private var hostedView: NSHostingView<AnyView>?

    func configure(with channel: Channel, channelService: ChannelService?, colorScheme: ColorScheme) {
        let view = AnyView(
            ChannelRow(channel: channel)
                .environment(\.channelService, channelService)
                .environment(\.colorScheme, colorScheme)
        )
        if let host = hostedView {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            addSubview(host)
            hostedView = host
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}
