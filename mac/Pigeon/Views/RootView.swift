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
        // Toolbar items live on the root, NOT on the sidebar column. Declaring
        // them inside `ChannelSidebar` bound them to the sidebar's title-bar
        // segment; toggling the sidebar made SwiftUI try to reparent them into
        // the detail toolbar, and the reparenting diff misplaced them after a
        // few toggles (ghost copy on the right, original gone). Anchoring at
        // root keeps them in the unified toolbar regardless of column state.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let isRefreshing = !(service?.inflight.isEmpty ?? true)
                Button {
                    guard let service else { return }
                    Task { await service.refreshAll() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh all channels (⌘R)")
                .disabled(channels.isEmpty || isRefreshing)
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
        // Sort by latest post (descending) so channels with new activity
        // bubble to the top — Telegram-style recency. Channels with no
        // posts yet (just-added, mid-first-fetch) fall back to `addedAt`
        // so they don't sink past channels with stale content.
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
