import SwiftUI
import SwiftData
import Nuke

@main
struct PigeonApp: App {
    @State private var appState = AppState()

    /// App-scoped data + networking layer. Lives for the lifetime of the
    /// process — *not* for the lifetime of the WindowGroup's window.
    /// Closing the last window keeps the auto-refresh loop and dock badge
    /// alive, which is what users expect from a Mac reader app and is
    /// load-bearing for the notification feature.
    @State private var environment: AppEnvironment = AppEnvironment()

    init() {
        configureNukeWithPinnedTransport()
    }

    /// Replace Nuke's default image pipeline with one whose URLSession
    /// routes any `*.translate.goog` request through `PinnedURLProtocol`.
    /// This means image fetches use the same DNS-bypass as the channel
    /// HTML proxy — the only requirement is that media URLs are rewritten
    /// to GT form before they reach Nuke (handled by `TelegramURLRewriter`).
    private func configureNukeWithPinnedTransport() {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [PinnedURLProtocol.self] + (config.protocolClasses ?? [])
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        ImageCache.shared.costLimit = 256 * 1024 * 1024
        ImageCache.shared.countLimit = 500

        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: config)
            $0.dataCache = try? DataCache(name: "dev.MaroMushii.Pigeon.images")
            $0.imageCache = ImageCache.shared
        }
        ImagePipeline.shared = pipeline
    }

    var body: some Scene {
        WindowGroup("Pigeon") {
            RootView()
                .environment(appState)
                .environment(\.channelService, environment.service)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // Sync the dock badge to whatever's already persisted
                    // — covers the case where unread posts existed across
                    // launch. Subsequent updates fire from refresh/markRead.
                    environment.service.updateDockBadge()
                }
        }
        .modelContainer(environment.container)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Channel…") {
                    appState.presentedSheet = .addChannel
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            SidebarCommands()
            InspectorCommands()
        }
    }
}

/// Bundles the SwiftData container, network client, and channel service so
/// they share a single lifecycle owned by the App. Constructing this once,
/// in the App's `@State`, guarantees the auto-refresh loop and dock badge
/// keep running across window-close events — `RootView`'s @State would be
/// torn down with the window.
@MainActor
struct AppEnvironment {
    let container: ModelContainer
    let client: TelegramClient
    let service: ChannelService

    init() {
        let schema = Schema([Channel.self, Post.self, Media.self, Reaction.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // SwiftData container construction is documented as throwing only
        // for malformed schemas or unwritable storage — both are
        // fatal-at-launch failures we cannot meaningfully recover from.
        let container = try! ModelContainer(for: schema, configurations: configuration)
        let client = TelegramClient()
        let service = ChannelService(client: client, context: container.mainContext)
        self.container = container
        self.client = client
        self.service = service
        // We deliberately do NOT call `service.updateDockBadge()` here —
        // `NSApp` isn't ready during `App.init`. The WindowGroup's `.task`
        // performs the initial badge sync once the runloop is alive.
    }
}
