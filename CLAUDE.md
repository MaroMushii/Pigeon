# CLAUDE.md

Project-level guidance for Claude when working in this repo. Read first.

## What this project is

**Pigeon** is a native macOS reader for Telegram public channels, built
to keep working on heavily filtered networks (Iran-grade DPI, DNS
poisoning). The repo is three cooperating pieces:

```
mac/             — Pigeon, SwiftUI macOS 26 client (Swift 6, strict
                   concurrency)
mirror/          — pigeon-mirror, a Node scraper run by GitHub Actions
                   (.github/workflows/mirror.yml) every ~5 min. Fetches
                   t.me from a GH-hosted runner (outside Iran), writes
                   per-channel snapshots + image binaries into a
                   checkout of the `export` branch, then `git push`es
                   the diff.
cf-dispatcher/   — tiny Cloudflare Worker that fires every 5 min on a
                   CF cron trigger and POSTs to GitHub's
                   workflow_dispatch endpoint to kick mirror.yml.
                   Exists because GitHub Actions' free-tier scheduled
                   workflows fire at ~6% of the configured rate; CF
                   crons hit their slot reliably. Worker does one HTTP
                   POST and exits — no scraping, no image bytes.
```

Pigeon reads channel data from
`raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/<u>/snapshot.json`
as its primary path, and falls back to a pinned-IP HTTPS request to
`t-me.translate.goog` (Google Translate's domain-translate proxy) when
a channel isn't in the mirror manifest yet.

We migrated **away from a Cloudflare Worker as the data plane** (the
original design) because the free plan's 10 ms CPU cap can't process
even one base64-encoded image upload per cron tick, and `git push`
from a CI runner is dramatically simpler than the GitHub Contents API.
Don't put scraping, image fetching, or any per-channel work back in
CF — that cap will still bite.

The exception is `cf-dispatcher/`, a scheduler-only Worker added after
measuring that GH-side scheduled workflows on the free tier fire at
~6% of the configured rate (median gap 42 min on a `*/5` schedule).
The dispatcher does **one outbound POST per tick** to GitHub's
workflow_dispatch endpoint and nothing else; CPU per invocation is
sub-millisecond, well under the cap. It owns one secret — a
fine-grained PAT (`Actions: read+write` on `MaroMushii/Pigeon` only),
stored as a `wrangler secret`, never in the repo.

`README.md` has the full architectural pitch — read it once for
context before suggesting structural changes.

## Hard rules — do not violate

These are load-bearing for Iran users. If a refactor seems to require
breaking one of these, **stop and ask.**

- **Never request `t.me` directly.** Even as a "last-resort" fallback.
  Iran's DPI fingerprints the SNI/TLS handshake to `t.me`. Always go
  through the mirror or the GT-host-rewrite proxy.
- **Never use `URLSession`'s system DNS for proxy requests.** All
  `*.translate.goog` traffic goes through `PinnedURLProtocol`, which
  delegates to `PinnedHTTPSClient` (`NWConnection` bound to a hardcoded
  Google IP, with TLS SNI override). System DNS is poisoned in Iran for
  these hostnames.
- **Pigeon is read-only against the mirror.** The mac app must never
  write to GitHub. Only the GH Actions workflow does, using the
  auto-provisioned `GITHUB_TOKEN` scoped to this repo.
- **Mirror snapshots store canonical (un-rewritten) URLs.** Pigeon
  applies its own `TelegramURLRewriter` after decode. Don't bake
  GT-rewriting into the scraper — it would break anyone else reading
  the mirror data.
- **The mirror URL is hardcoded in the app.** A wrong base URL is
  silently catastrophic for non-technical users, so we deliberately
  removed the user-configurable field (commit `2bdc4db`). Don't
  reintroduce it casually.

## Architecture cheat sheet

### Bypass chain (every channel fetch)

```
TelegramClient.swift
   │
   ├──▶  raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/
   │     channels/<u>/snapshot.json
   │     (primary; URLSession; 200 OK on success)
   │
   ├──▶  t-me.translate.goog (via PinnedHTTPSClient)
   │     pinned IP rotation: 216.239.38.120, 142.250.191.196,
   │                         142.250.184.196, 142.250.74.14
   │     query rotation: googleAuto / googleFa / googleRu / googleAr
   │     (fallback when mirror returns 404 or malformed JSON)
   │
   └──✗  direct t.me  (NEVER ATTEMPTED, by design)
```

### Image fetches

```
LazyImage(url) ──▶ Nuke pipeline ──▶ URLSession (custom config)
                                          │
                                          ├──▶ PinnedURLProtocol intercepts
                                          │      hosts ending in .translate.goog
                                          │      → routes via PinnedHTTPSClient
                                          │
                                          └──▶ everything else: normal URLSession
```

URLs reach this pipeline already-rewritten (`cdn4-telesco-pe.translate.goog`)
because `HTMLPostParser` and `JSONFeedDecoder` both pipe extracted URLs
through `TelegramURLRewriter.rewrite(...)`.

### Mirror scrape loop (GH Actions, every ~5 min)

```
CF cron (*/5) ──▶ cf-dispatcher Worker ──▶ POST workflow_dispatch ─┐
                                                                   ├─▶ mirror.yml runs
GH cron (lazy, ~6% throughput) ────────────────────────────────────┘
                                          │
                                          ▼
              runner checks out main into ./src and export into ./out
           ──▶ cd src/mirror && pnpm exec tsx scrape.ts ../../out channels.json
                 for each channel:
                   GET t.me/s/<u>
                   parseChannelPage() → fresh Snapshot (~20 newest posts)
                   load on-disk out/channels/<u>/snapshot.json (if any)
                   merge previous.posts + fresh.posts:
                     - keyed by post.id (latest-wins on edits + reactions)
                     - sort by posted_at desc, msgId tiebreaker
                     - cap at RETAIN_LIMIT (100)
                   channel info (title/photo/subscribers): fresh always wins
                   write out/channels/<u>/snapshot.json
                   for each referenced image:
                     skip if file exists locally (Telegram CDN URLs are
                     immutable per upload, so name-on-disk == content)
                     else fetch + write to out/channels/<u>/media/<hash>.<ext>
                 rebuild out/index.json
           ──▶ runner: git add -A; commit if diff; git push origin export
```

The scraper has **no secrets**. The workflow's `GITHUB_TOKEN` is the
only auth — no PAT, no CF API token in the workflow itself.

The `cf-dispatcher/` Worker does own one secret (a fine-grained PAT
that lets it call `workflow_dispatch`), held in CF's encrypted env via
`wrangler secret put GITHUB_TOKEN`. That secret never lands in the
repo or any config file. Rotation: re-run `wrangler secret put`; the
Worker picks up the new value on the next tick.

## Build & dev

The `justfile` at the repo root is the canonical dev surface. Recipes
are thin wrappers over scripts in `mac/scripts/` so anyone can also
invoke them directly.

```sh
just                 # list recipes
just build           # xcodegen + xcodebuild Debug, then reveal Pigeon.app
just app             # open the freshest Debug build
just test            # run the test bundle
just clean           # trash all DerivedData/Pigeon-*
just package <ver>   # build release artifacts → mac/dist
just ship <ver>      # tag + push (triggers .github/workflows/release.yml)
just mirror-check    # mirror typecheck (offline)
```

### macOS app — manual path

Requires Xcode 26 + macOS 26 (Tahoe) + xcodegen.

```sh
brew install xcodegen
cd mac
xcodegen generate                   # always run after editing project.yml
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build
```

`mac/Pigeon.xcodeproj/` and `mac/Pigeon/Resources/{Info.plist,Pigeon.entitlements}`
are generated by xcodegen and **gitignored** — `mac/project.yml` is the
source of truth.

If a build fails with "Entitlements file was modified during the build,"
do `xcodebuild ... clean` once and rebuild. xcodegen + xcodebuild can
race on a fresh generate.

### Mirror — manual path

```sh
cd mirror
pnpm install
pnpm typecheck

# Parser-only sanity test (offline; needs an HTML fixture):
pnpm dry-run /tmp/some-fixture.html durov

# Full end-to-end (needs t.me reachable — won't work from Iran-side
# machines; works on GH runners):
pnpm scrape /tmp/test-export-tree channels.json
```

## Conventions

### Swift (`mac/`)

- Swift 6, **strict concurrency complete.** Don't downgrade.
- macOS 15 deployment target. macOS 26-only APIs (Liquid Glass `.glassEffect`, `scrollEdgeEffectStyle(_:for:)`) require `#available(macOS 26, *)` guards — use the helpers in `Views/ViewExtensions.swift` (`glassEffectIfAvailable`, `softTopScrollEdgeEffect`, `softHorizontalScrollEdgeEffect`).
- `@Observable` + `@State` over `ObservableObject` + `@StateObject`.
- `@MainActor` on stores; mark `@ObservationIgnored` on any property
  wrapper inside an `@Observable` class.
- Networking actors return `Sendable` value types only. Don't pass
  `ModelContext` across actor boundaries.
- All `@State` properties are `private`.

### TypeScript (`mirror/`)

- `strict`, `noUncheckedIndexedAccess`, `verbatimModuleSyntax: false`.
- ES modules; `.js` extension on internal imports (TS resolves them).
- Snake_case for JSON wire fields. Schema lives in `mirror/schema.ts`.
  When you add a field there, mirror it in
  `mac/Pigeon/Services/JSONFeedDecoder.swift`.

### Git

- Branch naming: `type/description` (e.g. `feat/notifications`,
  `fix/rate-limit`).
- Conventional-commit messages, scoped: `feat(mac):`, `feat(mirror):`,
  `fix(mirror):`, `chore(ci):`, `chore:`.
- Commits include the `Co-Authored-By: Claude Opus 4.7 (1M context)`
  trailer.
- Never push to `main` without explicit user confirmation, even for
  trivial fixes.

### Tooling

- `pnpm`, never npm/yarn.
- Fish shell — use Fish-compatible syntax in shell snippets.
- `trash` for deletes, never `rm`.
- `gh` CLI for GitHub API operations, not WebFetch.

## Common tasks

### Adding a channel to the mirror

Edit `mirror/channels.json`, PR (or push directly). The scraper
re-reads the manifest on every cron tick, so the new channel appears
in the next sweep. Nothing to deploy.

### Regenerating the Xcode project

```sh
just build      # regenerates + builds
# or manually:
cd mac && xcodegen generate
```

Run after any change to `mac/project.yml`, after adding/removing source
files, or when Xcode complains about missing files.

### Updating the snapshot schema

1. Bump `SCHEMA_VERSION` in `mirror/schema.ts` (and the `schema` field
   everywhere it's referenced).
2. Update `JSONFeedDecoder.supportedSchemaVersion` and the DTOs in
   `mac/Pigeon/Services/JSONFeedDecoder.swift`.
3. Test parser with `pnpm exec tsx dry-run.ts <fixture> <username>`
   from `mirror/`.
4. **Order matters:** land the mirror change on `main` first, wait one
   cron tick so the new schema lands in `export`, then ship the Pigeon
   update. Pigeon rejects unsupported schema versions, so reverse order
   would brick deployed copies of the app.

### Adding a Telegram CDN host to the rewriter

If Telegram introduces `cdnN.something-new.org`, add the suffix to
`TelegramURLRewriter.proxiedHostSuffixes` in
`mac/Pigeon/Services/TelegramURLRewriter.swift`. That's it —
`PinnedURLProtocol`'s host predicate (`.translate.goog` suffix) handles
the rest automatically.

### Debugging a stuck channel

```sh
# 1. Hit the mirror URL directly:
curl -s 'https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/<u>/snapshot.json' \
  -w '\nHTTP %{http_code}, %{size_download} bytes\n'

# 2. If 404 or stale, check the latest workflow run:
gh run list --workflow mirror.yml -L 5
gh run view <run-id> --log

# 3. Re-trigger on demand (faster than waiting for cron):
gh workflow run mirror.yml

# 4. Run the scraper locally against a temp tree (only works on a
#    network that can reach t.me — won't work from Iran-side machines):
cd mirror && pnpm scrape /tmp/test-export channels.json
```

## Lessons learned (don't repeat)

- **NavigationSplitView column visibility** — `.doubleColumn` on a
  three-column split *hides the sidebar*, not the detail. There's no
  built-in way to hide just the detail column. We collapsed to a
  two-column layout. (The product reasoning is also better: Telegram
  channels are streams, not threaded mailboxes.)
- **`.aspectRatio(_, .fill)` overflows.** Use `.fit` for media tiles,
  combined with `.frame(maxWidth:..., maxHeight:...)` and `.clipped()`.
  Put `.clipShape(...)` on the outer card so contents respect the
  rounded rect.
- **`URLProtocol` is class-based, not Sendable-friendly.** Subclass
  with `@unchecked Sendable`, capture `self` into the Task as
  `let proto = self`, and explicitly mark the Task closure `@Sendable`.
- **CF Workers free tier is too tight for image mirroring.** 10 ms CPU
  per invocation can't fit even one base64-encoded image PUT. Migrating
  to GH Actions gave us (a) free unlimited compute on public repos,
  (b) `git push` of binary files instead of the Contents API,
  (c) zero secrets to manage. The Paid plan ($5/mo, 30 s CPU) would
  technically work, but there's no reason to come back.
- **Cheerio's `.text()` strips line breaks.** When extracting
  `plain_text`, replace `<br>` with `\n` first via a quick regex, then
  call `.text()`.
- **Release builds need the `macos-26` runner**, not `macos-15`. Only
  Xcode 26.x's `actool` fully supports Icon Composer `.icon` bundles
  (which is what `mac/Pigeon/Resources/Pigeon.icon/` is). The
  `macos-15` image carries an early Xcode 26 beta that fails at the
  asset-catalog stage. See the comment in
  `.github/workflows/release.yml`.
- **`xcodegen` regenerates `Info.plist` and entitlements** on every
  run. Both are gitignored — `project.yml` is canonical.
- **GitHub release assets are blocked in Iran.** `github.com/releases/download/...`
  URLs 302-redirect to `release-assets.githubusercontent.com`, which is not on
  Iran's whitelist. DMGs are therefore committed to the `release` branch under
  `dist/` and served via `raw.githubusercontent.com` (confirmed open). The
  appcast enclosure URLs and per-item `<link>` tags both point there. Don't
  change the `--download-url-prefix` in `update-appcast.sh` back to the GitHub
  releases CDN path.

## What's deferred / not yet built

In rough priority order if the user asks "what's next?":

1. **Un-mirrored channel suggestion flow.** Today, adding `@somechannel`
   that's not in `mirror/channels.json` falls through to the GT proxy
   (works, but slower and more fragile than the mirror). A "Suggest
   this channel for the mirror" action that opens a pre-filled GitHub
   PR would close the loop without giving Pigeon any write capability.
2. **Mirror retry/backoff** in `mirror/scrape.ts` so one flaky
   `t.me/s/<u>` doesn't repeatedly fail across consecutive sweeps. Low
   priority — the 5-min cron is already a coarse retry, and `health.json`
   now surfaces persistent failures so they're at least visible.

**Explicitly out of scope:** notifications on new posts (banners,
sounds, `UNUserNotificationCenter`). The dock-icon unread badge —
maintained by `ChannelService.updateDockBadge()` from a cached
`unreadCount` — is the deliberate substitute. Don't propose
notifications as a next feature; if a user request implicitly assumes
them, push back and reach for the badge or sidebar-row treatment first.

When in doubt about what to work on, **ask** — don't guess from this
list. Items shipped before this rewrite (search, settings, app icon,
prefetch, network health check, RTL post bodies, justfile) used to
live here too; they don't anymore.

