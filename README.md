# Pigeon

A native macOS reader for Telegram channels, designed for heavily filtered
networks. Two pieces:

- **`mac/`** — Pigeon, a SwiftUI app for macOS 26+. Sandboxed, ~30 MB,
  Swift 6 strict-concurrency clean.
- **`worker/`** — `pigeon-mirror`, a Cloudflare Worker that scrapes
  `t.me/s/<channel>` from outside Iran every 2 minutes and commits JSON
  snapshots to this repo's `export` branch.

## Why

Direct access to Telegram is blocked or DNS-poisoned in Iran. Pigeon
bypasses this in three layered ways:

1. **GitHub-hosted mirror (primary).** Pigeon reads channel snapshots
   from `raw.githubusercontent.com/MaroMushii/teleMirror/refs/heads/export/<channel>.json`.
   GitHub raw is rarely censored — collateral damage on developers is
   politically expensive.
2. **Pinned-IP HTTPS via Google Translate (fallback).** When a channel
   isn't mirrored yet, Pigeon connects to a hardcoded Google anycast IP,
   wraps the socket in TLS with `t-me.translate.goog` as the SNI, and
   asks Google to fetch `t.me/s/<channel>` on its behalf. Bypasses local
   DNS poisoning entirely. Same trick covers media (`*.telesco.pe`,
   `telegram.org` emoji) — host names are rewritten to their
   `<dashed-host>.translate.goog` form and routed through the same
   pinned transport.
3. **Direct `t.me` is never attempted.** Per the project brief.

## Quick start (macOS app)

```
brew install xcodegen
cd mac
xcodegen generate
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app
```

Or just open `mac/Pigeon.xcodeproj` in Xcode 26 and hit Run.

Requires macOS 26 (Tahoma) and Xcode 26.

## Adding a channel

Either:

- **In-app**: ⌘N → paste `@username`, `t.me/x`, or any t.me URL.
- **To the mirror**: open a PR adding the username to
  `worker/channels.json`. The Worker picks it up on the next 2-minute
  cron tick.

## License

MIT. Inspired by the original [ircfspace/teleMirror](https://github.com/ircfspace/teleMirror)
Electron client.
