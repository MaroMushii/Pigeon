import SwiftUI
import SwiftData
import NukeUI

struct ChannelSidebar: View {
    let channels: [Channel]
    @Binding var searchText: String

    @Environment(AppState.self) private var appState
    @Environment(PostCache.self) private var postCache
    @Environment(\.channelService) private var service
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedChannelID) {
            if channels.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "tray")
                } description: {
                    Text("Add a Telegram channel to start reading.")
                } actions: {
                    Button("Add Channel…") {
                        appState.presentedSheet = .addChannel
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(channels) { channel in
                    ChannelRow(
                        channel: channel,
                        isLoading: appState.loadingChannels.contains(channel.username)
                    )
                    .tag(channel.persistentModelID)
                    .contextMenu {
                        Button("Refresh") {
                            Task { await refresh(channel) }
                        }
                        Button("Open on telegram.org") {
                            NSWorkspace.shared.open(channel.publicURL)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            service?.remove(channel, in: context)
                            if appState.selectedChannelID == channel.persistentModelID {
                                appState.selectedChannelID = nil
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pigeon")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter channels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentedSheet = .addChannel
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Add a Telegram channel (⌘N)")
            }
        }
        .onChange(of: appState.selectedChannelID) {
            if let channel = channels.first(where: { $0.persistentModelID == appState.selectedChannelID }),
               !postCache.isFresh(channel.username) {
                Task { await refresh(channel) }
            }
        }
    }

    private func refresh(_ channel: Channel) async {
        guard let service else { return }
        appState.loadingChannels.insert(channel.username)
        defer { appState.loadingChannels.remove(channel.username) }
        do {
            _ = try await service.postsForDisplay(channel, forceRefresh: true)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: 30, height: 30)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("@\(channel.username)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = channel.photoURL, let url = URL(string: urlString) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Text(initials)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initials: String {
        let parts = channel.displayName.split(separator: " ", omittingEmptySubsequences: true)
        let chars = parts.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? String(channel.username.prefix(1)).uppercased() : String(chars).uppercased()
    }
}
