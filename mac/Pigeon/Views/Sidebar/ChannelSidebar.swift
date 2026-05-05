import SwiftUI
import SwiftData
import NukeUI

struct ChannelSidebar: View {
    let channels: [Channel]
    @Binding var searchText: String

    @Environment(AppState.self) private var appState
    @Environment(\.channelService) private var service

    var body: some View {
        @Bindable var appState = appState

        Group {
            if channels.isEmpty {
                SidebarEmptyState {
                    appState.presentedSheet = .addChannel
                }
            } else {
                List(selection: $appState.selectedChannelID) {
                    ForEach(channels) { channel in
                        ChannelRow(
                            channel: channel,
                            isLoading: service?.inflight.contains(channel.username) ?? false
                        )
                        .tag(channel.persistentModelID)
                        .contextMenu {
                            Button("Refresh") {
                                if let service {
                                    Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
                                }
                            }
                            Button("Open on telegram.org") {
                                NSWorkspace.shared.open(channel.publicURL)
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                service?.remove(channel)
                                if appState.selectedChannelID == channel.persistentModelID {
                                    appState.selectedChannelID = nil
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
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
            guard let service else { return }
            if let channel = channels.first(where: { $0.persistentModelID == appState.selectedChannelID }),
               !service.isFresh(channel) {
                Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            avatar
                .frame(width: 32, height: 32)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("@\(channel.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
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
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private var initials: String {
        let parts = channel.displayName.split(separator: " ", omittingEmptySubsequences: true)
        let chars = parts.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? String(channel.username.prefix(1)).uppercased() : String(chars).uppercased()
    }
}

private struct SidebarEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No Channels")
                    .font(.headline)
                Text("Add a Telegram channel\nto start reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Add Channel…", action: onAdd)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
