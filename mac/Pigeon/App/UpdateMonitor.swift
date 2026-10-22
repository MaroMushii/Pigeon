import Foundation
import Sparkle

/// Bridges Sparkle's ObjC delegate into reactive @Observable state.
/// Owns the updater controller so both live and die together.
@Observable
@MainActor
final class UpdateMonitor: NSObject {
    var updateAvailable = false

    private(set) var controller: SPUStandardUpdaterController!

    /// Release-only launch check. Debug builds report MARKETING_VERSION
    /// 0.1.0 against the release appcast, so a started updater just
    /// prompts for an update it cannot install (ad-hoc signature — see
    /// PigeonApp.swift). The menu item keeps working for manual checks.
    private static var startsUpdaterOnLaunch: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.startsUpdaterOnLaunch,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
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
