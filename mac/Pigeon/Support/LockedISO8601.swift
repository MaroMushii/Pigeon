import Foundation
import os

/// Thread-safe wrapper around `ISO8601DateFormatter`. The underlying class
/// is not formally documented thread-safe (unlike `DateFormatter`), so we
/// serialise reads through an unfair lock. Contention is negligible — only
/// the parse/decode paths reach these, and each call is a single
/// `date(from:)` against a small string.
///
/// `ISO8601DateFormatter` isn't `Sendable`, so we can't park it inside an
/// `OSAllocatedUnfairLock<State>`. Wrap manually: `@unchecked Sendable`
/// because every access to the stored formatter is gated by `lock`.
final class LockedISO8601: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let formatter: ISO8601DateFormatter

    init(_ formatter: ISO8601DateFormatter) {
        self.formatter = formatter
    }

    func date(from string: String) -> Date? {
        lock.withLock { formatter.date(from: string) }
    }
}

