import Foundation

/// User-tweakable preferences persisted in `UserDefaults`.
///
/// Read once at init, written through on every mutation. All access is
/// main-actor isolated; the store is observed by SwiftUI views via
/// `@Observable`.
@MainActor
@Observable
final class SettingsStore {
    enum LogLevel: String, CaseIterable, Identifiable, Sendable {
        case error
        case info
        case verbose

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .error: "Errors only"
            case .info: "Info"
            case .verbose: "Verbose"
            }
        }
    }

    /// Defaults stored under these keys. Names are stable — bumping them
    /// silently resets user prefs, so don't.
    private enum Key {
        static let cacheTTLMinutes = "settings.cacheTTLMinutes"
        static let logLevel = "settings.logLevel"
    }

    /// Cache TTL bounds. 5 min is the floor (mirror cron is ~5 min, going
    /// below pointlessly hammers the network); 60 min is a generous ceiling
    /// for users on metered connections.
    static let cacheTTLRange: ClosedRange<Int> = 5...60
    static let defaultCacheTTLMinutes = 15

    /// Single source of truth for the mirror prefix. Threaded through
    /// `TelegramClient.fetchMirrorSnapshot`, `JSONFeedDecoder.decode`, and
    /// `HealthChecker.checkMirror` as an explicit parameter — no globals
    /// scattered across the network layer.
    static let defaultMirrorBaseURL = URL(string: "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export")!

    /// How long a cached channel is considered fresh before it's auto
    /// re-fetched on selection. Clamped to `cacheTTLRange` on write.
    var cacheTTLMinutes: Int {
        didSet {
            let clamped = Self.cacheTTLRange.clamp(cacheTTLMinutes)
            if clamped != cacheTTLMinutes {
                cacheTTLMinutes = clamped
                return
            }
            guard cacheTTLMinutes != oldValue else { return }
            defaults.set(cacheTTLMinutes, forKey: Key.cacheTTLMinutes)
        }
    }

    var logLevel: LogLevel {
        didSet {
            guard logLevel != oldValue else { return }
            defaults.set(logLevel.rawValue, forKey: Key.logLevel)
        }
    }

    /// `TimeInterval` view of `cacheTTLMinutes` for callers that want
    /// seconds — primarily `ChannelService.freshnessTTL`.
    var cacheTTL: TimeInterval {
        TimeInterval(cacheTTLMinutes * 60)
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTTL = defaults.object(forKey: Key.cacheTTLMinutes) as? Int
        self.cacheTTLMinutes = Self.cacheTTLRange.clamp(
            storedTTL ?? Self.defaultCacheTTLMinutes
        )
        let storedLevel = defaults.string(forKey: Key.logLevel)
            .flatMap(LogLevel.init(rawValue:))
        self.logLevel = storedLevel ?? .info
    }
}

private extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

