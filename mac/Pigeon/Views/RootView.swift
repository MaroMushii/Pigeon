import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(SearchStore.self) private var searchStore
    @Environment(\.channelService) private var service
    // `@Query` can only sort by stored attributes, but we want recency by
    // newest post — a computed value derived from the `posts` relationship.
    // Pull in a stable order here, then re-sort in memory below.
    @Query(sort: [SortDescriptor(\Channel.addedAt, order: .forward)]) private var channels: [Channel]

    @State private var sidebarSearch: String = ""
    @State private var isHoveringRefresh = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var searchStore = searchStore

        NavigationSplitView {
            ChannelSidebar(
                channels: filteredChannels,
                searchText: $sidebarSearch
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if searchStore.hasActiveQuery {
                SearchResultsView(
                    results: searchStore.results,
                    query: searchStore.query,
                    isSearching: searchStore.isSearching
                )
            } else {
                ChannelFeed(channel: selectedChannel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Toolbar-mounted searchbar sits in the detail-pane chrome, which is
        // the conventional Mac placement for a global search affordance —
        // sidebar-level search would be confused with the existing sidebar
        // filter (`sidebarSearch`).
        .searchable(
            text: $searchStore.query,
            placement: .toolbar,
            prompt: "Search posts"
        )
        // Toolbar items live on the root, NOT on the sidebar column. When
        // declared inside `ChannelSidebar`, SwiftUI binds them to that
        // column's segment of the unified toolbar. On collapse, the system
        // injects a `>>` chevron next to the regular sidebar toggle as an
        // "expand the column to access these items" affordance — visually
        // a duplicate-toggle artifact that confused users and, after a few
        // collapses, sometimes left ghost copies (commit `6273f5c`).
        // Anchoring at root sidesteps the segment-reparenting entirely.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let isRefreshing = !(service?.inflight.isEmpty ?? true)
                if isRefreshing {
                    Button {
                        service?.cancelRefreshAll()
                    } label: {
                        ZStack {
                            if isHoveringRefresh {
                                Image(systemName: "xmark").foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(6)
                        .background(.fill.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringRefresh = $0 }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Cancel refresh")
                    .accessibilityLabel("Cancel refresh")
                } else {
                    Button {
                        service?.refreshAll()
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh all channels (⌘R)")
                    .disabled(channels.isEmpty)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentedSheet = .addChannel
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Add a Telegram channel (⌘N)")
            }
        }
        .sheet(item: $appState.presentedSheet) { sheet in
            switch sheet {
            case .addChannel:
                if let service {
                    AddChannelSheet(service: service)
                        .frame(minWidth: 420, minHeight: 220)
                }
            case .healthCheck:
                HealthCheckView()
                    .frame(minWidth: 380, minHeight: 240)
            }
        }
    }

    // MARK: - Derived

    // Computed (not cached in @State): `@Query` re-emits when the array's
    // membership/order changes, but our query is sorted by `addedAt` so
    // per-row `lastPostAt` mutations don't bump the array identity. A cached
    // version stayed stale on new posts; recomputing each render is cheap at
    // the channel-list size we ever have.
    private var filteredChannels: [Channel] {
        let base: [Channel]
        if sidebarSearch.isEmpty {
            base = channels
        } else {
            let q = sidebarSearch.lowercased()
            base = channels.filter {
                $0.displayName.lowercased().contains(q) || $0.username.contains(q)
            }
        }
        return base.sorted { lhs, rhs in
            let l = lhs.lastPostAt ?? lhs.addedAt
            let r = rhs.lastPostAt ?? rhs.addedAt
            return l > r
        }
    }

    private var selectedChannel: Channel? {
        guard let id = appState.selectedChannelID else { return nil }
        return channels.first(where: { $0.persistentModelID == id })
    }
}

extension EnvironmentValues {
    @Entry var channelService: ChannelService? = nil
}
