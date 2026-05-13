import Foundation
import SwiftData

/// In-memory record of where the user left each channel's scroll view, so
/// switching away from a channel and back lands at the same place. Lives for
/// the lifetime of the process — by design, **not** persisted. A cold launch
/// should always open a channel at its unread divider, so a never-seen
/// channel in this session returns `nil` and the feed falls back to
/// divider-or-bottom.
///
/// The store is intentionally tiny: `ChannelFeedContent` writes its current
/// position on `.onDisappear` (channel switch tears the view down via the
/// `.id(...)` reset) and reads it on mount. No observation needed — callers
/// only ever poll on mount/unmount, never during scroll.
@MainActor
@Observable
final class ChannelScrollMemory {
    enum Position: Equatable {
        /// User was at the newest post when they left.
        case bottom
        /// User was at (or above) the frozen unread divider when they left.
        /// `anchorPostID` is the id of the first-unread post at save time —
        /// captured so that if the divider has disappeared by the time we
        /// remount (e.g. the channel auto-marked everything as read while
        /// the user was away on another channel), we still have a concrete
        /// post id to scroll back to instead of falling through to "feed
        /// bottom" and silently throwing the user's position away.
        case unreadDivider(anchorPostID: String)
        /// User was mid-stream; restore by anchoring this post near the top
        /// of the viewport with a small breathing inset.
        case offset(postID: String)
    }

    @ObservationIgnored
    private var byChannel: [PersistentIdentifier: Position] = [:]

    func saved(for id: PersistentIdentifier) -> Position? {
        byChannel[id]
    }

    func save(_ position: Position, for id: PersistentIdentifier) {
        byChannel[id] = position
    }

    func clear(_ id: PersistentIdentifier) {
        byChannel.removeValue(forKey: id)
    }
}

