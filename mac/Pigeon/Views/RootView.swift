import SwiftUI
import SwiftData

struct RootView: View {
    let client: TelegramClient

    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: [SortDescriptor(\Channel.addedAt, order: .forward)]) private var channels: [Channel]

    @State private var service: ChannelService?
    @State private var sidebarSearch: String = ""

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            ChannelSidebar(
                channels: filteredChannels,
                searchText: $sidebarSearch
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            ChannelFeed(channel: selectedChannel)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $appState.presentedSheet) { sheet in
            switch sheet {
            case .addChannel:
                if let service {
                    AddChannelSheet(service: service)
                        .frame(minWidth: 420, minHeight: 220)
                }
            }
        }
        .task {
            if service == nil {
                service = ChannelService(client: client, context: context)
            }
        }
        .environment(\.channelService, service)
    }

    // MARK: - Derived

    private var filteredChannels: [Channel] {
        guard !sidebarSearch.isEmpty else { return channels }
        let q = sidebarSearch.lowercased()
        return channels.filter {
            $0.displayName.lowercased().contains(q) || $0.username.contains(q)
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
