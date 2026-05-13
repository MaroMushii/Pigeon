import os

/// Topic-keyed `Logger` instances for the app. All entries share the
/// `dev.MaroMushii.Pigeon` subsystem so `log show --predicate
/// 'subsystem == "dev.MaroMushii.Pigeon"'` picks them up regardless of
/// category. Tail any one category via `just logs <category>`.
///
/// Conventions:
///   • Use `.pub(...)` for free-form debug strings — it forces the whole
///     interpolation to `privacy: .public` so usernames / post ids land
///     in `log show` instead of `<private>`. This is intentional: Pigeon
///     reads public channels only, there is no PII to redact in our
///     own log lines.
///   • Reserve `.error(...)` for actual failures; everything else goes
///     through `.notice` (the default for `.pub`). `.debug` is filtered
///     out of `log show` by default, which is why we don't use it.
enum AppLog {
    private static let subsystem = "dev.MaroMushii.Pigeon"

    /// Scroll-memory save/restore, re-click cycle, anchor decisions.
    static let scroll  = Logger(subsystem: subsystem, category: "Scroll")
    /// View lifecycle: channel switch, mount/dismount, app launch.
    static let mount   = Logger(subsystem: subsystem, category: "Mount")
    /// NSTableView row-height measurement, cache invalidation, width changes.
    static let measure = Logger(subsystem: subsystem, category: "Measure")
    /// Viewport visibility tracking (which rows are on-screen, dwell timers).
    static let visible = Logger(subsystem: subsystem, category: "Visible")
    /// Feed content lifecycle (init, reveal, refresh diffs).
    static let feed    = Logger(subsystem: subsystem, category: "Feed")
    /// Networking: PinnedHTTPSClient, URLSession bridges, retry logic.
    static let net     = Logger(subsystem: subsystem, category: "Net")
    /// Mirror fetch, manifest, health.json, schema-version checks.
    static let mirror  = Logger(subsystem: subsystem, category: "Mirror")
}

extension Logger {
    /// Log a `.notice`-level message with the entire interpolation marked
    /// `privacy: .public`. Avoids per-call-site `, privacy: .public`
    /// boilerplate for dev logs. Use the regular `Logger.error/.fault`
    /// APIs (with explicit privacy) for production-sensitive logs.
    func pub(_ message: String) {
        self.notice("\(message, privacy: .public)")
    }
}

