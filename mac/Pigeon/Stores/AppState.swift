import Foundation
import SwiftData

/// Top-level UI state: which channel is selected, which post, and which
/// sheet (if any) is presented. Selection IDs are SwiftData `PersistentIdentifier`s
/// so they remain stable across launches.
@MainActor
@Observable
final class AppState {
    var selectedChannelID: PersistentIdentifier?
    var presentedSheet: PresentedSheet?
    var scrollToLatestToken: UUID?

    enum PresentedSheet: Identifiable {
        case addChannel
        case healthCheck
        var id: String {
            switch self {
            case .addChannel: "addChannel"
            case .healthCheck: "healthCheck"
            }
        }
    }
}
