# Pigeon

A native macOS reader for Telegram public channels, built to keep working
on heavily filtered networks (Iran-grade DPI, DNS poisoning).

It's a two-part system:

- **`mac/`** — Pigeon, a SwiftUI macOS 26 client. ~30 MB, Swift 6 strict
  concurrency, sandboxed, hardened-runtime ad-hoc signed.
- **`worker/`** — `pigeon-mirror`, a Cloudflare Worker that scrapes
  `t.me/s/<channel>` from CF's edge every two minutes and commits JSON
  snapshots to this repo's `export` branch.

## Why

Telegram and its CDNs are blocked at multiple network layers in Iran:
direct TCP to `t.me` and `*.telesco.pe` is dropped, and the local
resolver poisons their A records. Pigeon never talks to Telegram
directly. Instead it stacks three independent bypasses, the first one
that succeeds wins.

### 1. GitHub-hosted mirror (primary path)

The Worker scrapes from outside Iran and commits per-channel snapshots
to:

```
https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/<username>.json
```

Iran rarely blocks `raw.githubusercontent.com` — the collateral damage
on developer tooling is politically expensive. This is fast, fresh
within ~2 minutes, and works reliably on filtered networks.

### 2. Pinned-IP HTTPS via Google Translate (fallback)

Used when a channel isn't mirrored yet, or when GitHub raw is
unreachable. Pigeon:

1. Opens a TCP socket to a **hardcoded Google anycast IP** (rotating
   `216.239.38.120`, `142.250.191.196`, `142.250.184.196`,
   `142.250.74.14`).
2. Wraps it in TLS with `t-me.translate.goog` set as the **SNI**, and
   sends `Host: t-me.translate.goog` in the HTTP request.
3. Sends `GET /s/<channel> HTTP/1.0` with `_x_tr_*` query params, four
   translation-language variants tried in sequence.

Google's edge fetches `t.me/s/<channel>` server-side and returns the
HTML to us. The system DNS resolver is never consulted, so DNS
poisoning of `*.translate.goog` doesn't matter. From the network's
view it's an ordinary HTTPS conversation with Google.

The same trick covers **images**. Telegram CDN URLs
(`cdn4.telesco.pe`, `cdn1.cdn-telegram.org`, `telegram.org` for emoji)
are rewritten at parse time to `<dashed-host>.translate.goog` form,
and a custom `URLProtocol` routes any `*.translate.goog` request from
URLSession through the same pinned transport. Nuke (the image cache)
inherits this with no special-casing.

### 3. Direct `t.me` is never attempted

By design. Even when both paths fail, we don't try it as a last
resort. Avoids accidentally leaking traffic that DPI can fingerprint.

## Repository layout

```
.
├── mac/                       # Pigeon SwiftUI app
│   ├── project.yml            # xcodegen source-of-truth
│   └── Pigeon/
│       ├── App/               # entry point, Nuke pipeline wiring
│       ├── Models/            # Channel (SwiftData @Model), Post, Media, Reaction
│       ├── Services/          # PinnedHTTPSClient, TelegramClient,
│       │                       # HTMLPostParser, JSONFeedDecoder,
│       │                       # PinnedURLProtocol, TelegramURLRewriter,
│       │                       # AttributedHTMLBuilder, …
│       ├── Stores/            # @Observable AppState, PostCache, ChannelService
│       ├── Views/             # Sidebar, Feed, AddChannelSheet
│       └── Resources/         # Assets, generated Info.plist + entitlements
│
└── worker/                    # Cloudflare Worker
    ├── wrangler.toml          # cron + bindings
    ├── channels.json          # the channel manifest (PR to add channels)
    ├── src/
    │   ├── index.ts           # cron + HTTP handler, sharding, GH commit
    │   ├── parser.ts          # cheerio-based parser, mirrors HTMLPostParser
    │   ├── github.ts          # Contents API wrapper + sha256 diff
    │   └── schema.ts          # snapshot schema (v1)
    └── scripts/dry-run.ts     # local parser test harness
```

## Quick start — macOS app

Requires macOS 26 (Tahoma) and Xcode 26.

```sh
brew install xcodegen
cd mac
xcodegen generate
open Pigeon.xcodeproj            # then ⌘R in Xcode
```

Or build from the CLI:

```sh
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app
```

The app is unsigned (ad-hoc); on first launch right-click → **Open**
once to dismiss Gatekeeper, or
`xattr -dr com.apple.quarantine /Applications/Pigeon.app`.

## Quick start — Worker

Already deployed at `pigeon-mirror.freddie-001.workers.dev`. To run
your own instance:

```sh
cd worker
pnpm install
pnpm exec wrangler login
pnpm exec wrangler secret put GITHUB_TOKEN   # paste a fine-grained PAT
pnpm deploy
pnpm tail
```

The PAT needs **Contents: Read and write** scoped to a single repo
(this one). The Worker uses it to commit snapshots to the `export`
branch.

## Adding a channel

Two ways:

- **In-app:** `⌘N` → paste `@username`, `t.me/x`, or `https://t.me/s/x`.
  The channel is added to your local SwiftData store and fetched
  immediately. If it isn't in the mirror manifest, the GT fallback
  serves it on demand.
- **To the mirror manifest:** open a PR editing
  [`worker/channels.json`](worker/channels.json). The Worker picks up
  manifest changes on its next cron tick (every 2 min) and starts
  publishing snapshots within minutes.

## How fresh is the mirror?

Cron runs every 2 minutes and processes a rotating shard of up to 16
channels per invocation (CF free plan caps at 50 subrequests). With a
list of N channels, full coverage takes `ceil(N / 16) × 2` minutes. A
content-hash diff before commit means unchanged channels don't churn
the export branch — most ticks are no-ops.

## Schema

Snapshot format ([`worker/src/schema.ts`](worker/src/schema.ts)):

```ts
{
  schema: 1,
  fetched_at: "2026-05-04T23:15:00Z",
  channel: { username, title, description_html, photo_url, subscriber_count },
  posts: [
    {
      id: "<channel>/<message-id>",
      author_name, author_photo_url,
      body_html, plain_text,
      media: [{ kind, asset_url, thumbnail_url, duration_label, aspect_ratio }],
      reactions: [{ emoji, count }],
      views_label, posted_at, edited, permalink
    }
  ]
}
```

URLs in the snapshot are **canonical** (`cdn4.telesco.pe/...`). Pigeon
applies its own GT-host-rewrite after decode, so the on-disk artifact
stays meaningful regardless of consumer.

## License

MIT. Inspired by the original
[ircfspace/teleMirror](https://github.com/ircfspace/teleMirror) Electron
client — Pigeon mines no code from it, but borrowed the GT-proxy
hostname-rewrite trick and Telegram widget DOM selectors as starting
points.
