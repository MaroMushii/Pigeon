import SwiftUI
import SwiftData
import Nuke

@main
struct PigeonApp: App {
    @State private var appState = AppState()
    private let client = TelegramClient()

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
            RootView(client: client)
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(for: [Channel.self, Post.self, Media.self, Reaction.self])
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
