import SwiftUI
import SwiftData
import Nuke
import NukeUI

struct ChannelSidebar: View {
    let channels: [Channel]
    @Binding var searchText: String

    @Environment(AppState.self) private var appState
    @Environment(\.channelService) private var service

    @State private var freshestMirrorFetch: Date?

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
                            isLoading: service?.inflight.contains(channel.username) ?? false,
                            unreadCount: channel.unreadCount,
                            isMuted: channel.isMuted
                        )
                        .tag(channel.persistentModelID)
                        .overlay {
                            if appState.selectedChannelID == channel.persistentModelID {
                                Button {
                                    appState.scrollToLatestToken = UUID()
                                } label: {
                                    Color.clear.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHidden(true)
                            }
                        }
                        .contextMenu {
                            Button("Refresh") {
                                if let service {
                                    Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
                                }
                            }
                            Button("Open on telegram.org") {
                                NSWorkspace.shared.open(channel.publicURL)
                            }
                            Button(channel.isMuted ? "Unmute" : "Mute") {
                                service?.setMuted(channel, !channel.isMuted)
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                service?.remove(channel)
                                if appState.selectedChannelID == channel.persistentModelID {
                                    appState.selectedChannelID = nil
                                }
                            }
                            Divider()
                            Section("@\(channel.username)") {
                                if let subs = channel.subscriberCount, !subs.isEmpty {
                                    Text("\(subs) subscribers")
                                }
                                Text("Updated \(Self.updatedLabel(channel.lastFetchedAt))")
                                Text("\(channel.posts.count) posts cached")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SidebarFooter(
                        schemaOutdated: service?.schemaOutdated ?? false,
                        mirrorHealth: service?.mirrorHealth,
                        freshestMirrorFetch: freshestMirrorFetch
                    )
                }
            }
        }
        .navigationTitle("Pigeon")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter channels")
        .onChange(of: appState.selectedChannelID) {
            guard let service else { return }
            if let channel = channels.first(where: { $0.persistentModelID == appState.selectedChannelID }),
               !service.isFresh(channel) {
                Task { _ = try? await service.postsForDisplay(channel, forceRefresh: true) }
            }
        }
        .onChange(of: channels, initial: true) { _, newValue in
            freshestMirrorFetch = newValue
                .filter { $0.fetchSource == .mirror }
                .compactMap(\.lastFetchedAt)
                .max()
        }
    }

    /// Snapshot relative-time label for the context menu. Static so the
    /// formatter is allocated once. Context menus are short-lived, so we
    /// don't tick the value live like the sidebar footer does.
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

private struct ChannelRow: View {
    let channel: Channel
    let isLoading: Bool
    let unreadCount: Int
    let isMuted: Bool

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
                HStack(spacing: 3) {
                    Text("@\(channel.username)")
                        .lineLimit(1)
                    if isMuted {
                        Image(systemName: "bell.slash")
                            .imageScale(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        isMuted
                            ? AnyShapeStyle(Color.secondary.opacity(0.18))
                            : AnyShapeStyle(Color.accentColor),
                        in: .capsule
                    )
                    .accessibilityLabel(isMuted ? "\(unreadCount) unread, muted" : "\(unreadCount) unread")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = channel.photoURL, let url = URL(string: urlString) {
            LazyImage(request: Self.thumbnailRequest(for: url)) { state in
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

    private static func thumbnailRequest(for url: URL) -> ImageRequest {
        ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: 32, height: 32),
                    contentMode: .aspectFill,
                    crop: false
                )
            ]
        )
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

/// Footer rendered below the channel list. Surfaces two degradation
/// signals:
///
/// 1. **Schema skew banner.** When the mirror started serving a snapshot
///    version this build doesn't understand, `ChannelService` flips
///    `schemaOutdated = true` and falls through to the GT path. Showing
///    a banner nudges the user to update; the app keeps working.
///
/// 2. **Mirror-staleness footer.** Shows "mirror updated N min ago" using
///    the sweep finish time from `health.json` when available — that's
///    the *actual* GitHub Actions sweep timestamp, regardless of whether
///    this app has been open. Falls back to the freshest local
///    `lastFetchedAt` across mirror-sourced channels for the brief window
///    after install before health has been fetched. When the latest sweep
///    reported any per-channel failures, appends a small "(N failed)"
///    suffix so silent partial degradations are visible.
///
/// Refresh ticks once a minute via a `TimelineView` so the relative-time
/// label stays current without a manual re-render.
private struct SidebarFooter: View {
    let schemaOutdated: Bool
    let mirrorHealth: MirrorHealth?
    let freshestMirrorFetch: Date?

    /// Prefer the sweep timestamp from `health.json` when we have one;
    /// fall back to the local last-fetch heuristic otherwise.
    private var stalenessTimestamp: Date? {
        mirrorHealth?.generatedAt ?? freshestMirrorFetch
    }

    var body: some View {
        VStack(spacing: 6) {
            if schemaOutdated {
                schemaSkewBanner
            }
            if stalenessTimestamp != nil {
                stalenessFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var schemaSkewBanner: some View {
        Label {
            Text("Pigeon needs an update — using fallback path.")
                .font(.footnote)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var stalenessFooter: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let last = stalenessTimestamp {
                let age = context.date.timeIntervalSince(last)
                let failureCount = mirrorHealth?.failures.count ?? 0
                Text(footerLabel(last: last, now: context.date, failureCount: failureCount))
                    .font(.footnote)
                    .foregroundStyle(age > 30 * 60 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func footerLabel(last: Date, now: Date, failureCount: Int) -> String {
        let base = "mirror updated \(relativeLabel(for: last, now: now))"
        guard failureCount > 0 else { return base }
        let noun = failureCount == 1 ? "channel" : "channels"
        return "\(base) · \(failureCount) \(noun) failed"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func relativeLabel(for date: Date, now: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: now)
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
