import SwiftUI
import AppKit
import SwiftData

/// AppKit-backed sidebar channel list. Replaces `List(selection:)` so we
/// own the `NSTableViewDelegate` and can detect re-clicks synchronously via
/// `tableView(_:shouldSelectRow:)` — the delegate method fires before
/// `tableViewSelectionDidChange`, giving us "already selected" information
/// without any NSEvent monitor or timing assumptions.
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

        let tableView = NSTableView()
        tableView.wantsLayer = true
        tableView.style = .sourceList
        tableView.selectionHighlightStyle = .sourceList
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

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        coordinator.channelService = channelService
        coordinator.appState = appState
        coordinator.colorScheme = colorScheme

        tableView.delegate = coordinator
        tableView.dataSource = coordinator

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

    /// Guards `shouldSelectRow` from firing re-click during programmatic
    /// selection changes (`applySelection`).
    private var isUpdatingSelection = false

    func update(channels newChannels: [Channel], selectedID newID: PersistentIdentifier?, envChanged: Bool) {
        let channelsChanged = newChannels.map(\.persistentModelID) != channels.map(\.persistentModelID)
        channels = newChannels
        if channelsChanged || envChanged {
            tableView?.reloadData()
        }
        applySelection(selectedID: newID)
    }

    /// Sync the table's selection to match the given ID without firing onReClick.
    private func applySelection(selectedID: PersistentIdentifier?) {
        guard let tableView else { return }
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
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

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Fires only for user-initiated selection. If the row is already selected,
        // this is a re-click — fire the callback synchronously before selection
        // state changes, so the caller gets a stable channel reference.
        if !isUpdatingSelection && tableView.selectedRow == row, row < channels.count {
            onReClick?(channels[row])
        }
        return true
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
