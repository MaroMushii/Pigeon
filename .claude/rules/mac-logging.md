---
paths: mac/**/*.swift
---
# Logging in the macOS App

All logging goes through `AppLog` (`mac/Pigeon/Support/AppLog.swift`). It wraps `os.Logger` under the `dev.MaroMushii.Pigeon` subsystem with seven topic-keyed categories.

## Categories and their scope

| Logger | Category | Use for |
|---|---|---|
| `AppLog.scroll` | `Scroll` | Scroll-memory save/restore, anchor decisions, re-click cycle |
| `AppLog.mount` | `Mount` | Channel switch, view lifecycle, app launch/quit |
| `AppLog.measure` | `Measure` | NSTableView row-height cache, width changes |
| `AppLog.visible` | `Visible` | On-screen row tracking, dwell timers |
| `AppLog.feed` | `Feed` | Feed init, refresh diffs, reveal timing |
| `AppLog.net` | `Net` | PinnedHTTPSClient, URLSession bridges, retry logic |
| `AppLog.mirror` | `Mirror` | Mirror fetch, manifest, health.json, schema checks |

## Writing log lines

**Always use `.pub()`** for dev-time strings — it marks the whole interpolation `.public` so variable values actually appear in the output instead of `<private>`.

```swift
// Good
AppLog.scroll.pub("restoring scroll for <\(channel.username)> offset=<\(offset)>")
AppLog.net.error("PinnedHTTPSClient failed: \(error.localizedDescription, privacy: .public)")

// Bad — values will be redacted
AppLog.scroll.notice("restoring scroll for \(channel.username)")
```

Use `.error()` (with explicit `privacy:`) only for actual failures. Everything else goes through `.pub()` at `.notice` level. Do not use `.debug()` — it is filtered out by `log show` by default and won't appear in the recipes below.

Format variable values in `<>`, consistent with the rest of the codebase:
```swift
AppLog.feed.pub("loaded <\(posts.count)> posts for <\(username)>")
```

Pick the category that matches the *subsystem doing the work*, not the triggering event. A networking timeout discovered during a feed refresh goes to `AppLog.net`, not `AppLog.feed`.

## Reading logs

Three `just` recipes cover the common cases:

```sh
# Live tail — Ctrl-C to stop
just logs              # all categories
just logs scroll       # Scroll only
just logs net          # Net only

# Historical dump — exits when done
just logs-since              # all, last 5 min
just logs-since scroll       # Scroll only, last 5 min
just logs-since measure 30s  # Measure only, last 30 s
# Duration syntax: 30s, 5m, 1h

# SwiftUI Instruments trace (app must be running)
just trace        # 15 s trace → ~/Desktop/pigeon-<ts>.trace
just trace 30     # 30 s trace
```

Valid category names for the recipes: `scroll`, `mount`, `measure`, `visible`, `feed`, `net`, `mirror`, `all`.

Raw `log` command if you need custom predicates:
```sh
log stream --style compact --level info \
  --predicate 'subsystem == "dev.MaroMushii.Pigeon" AND category == "Net"'
```
