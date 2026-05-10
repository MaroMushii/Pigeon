import Sparkle
import Foundation

/// Bridges Sparkle's ObjC delegate into reactive @Observable state.
/// Owns the updater controller so both live and die together.
@Observable
@MainActor
final class UpdateMonitor: NSObject {
    var updateAvailable = false

    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

extension UpdateMonitor: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.updateAvailable = true }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in self?.updateAvailable = false }
    }
}
