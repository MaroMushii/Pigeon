<p align="center">
  <img src="docs/logo.png" alt="Pigeon" width="160" />
</p>

<h1 align="center">Pigeon</h1>

<p align="center">
  Read Telegram public channels on your Mac, even when Telegram itself
  is blocked. No Telegram account, no VPN, no setup beyond installing
  the app.
</p>

Built for heavily filtered networks. Most readers break the moment
Telegram is blocked at the network level. Pigeon doesn't, because it
never talks to Telegram directly.

<p align="center">
  <img src="docs/screenshot.png" alt="Pigeon main window — sidebar of channels on the left, an open Persian-language channel on the right" width="820" />
</p>

## Install

Grab the latest `Pigeon-X.Y.Z.dmg` from the
[**Releases**](https://github.com/MaroMushii/Pigeon/releases) page, drag
the app to `/Applications`, and you're done. Requires macOS 26 (Tahoma).

The DMG is ad-hoc signed, so on first launch macOS will refuse with
*"can't be opened, developer cannot be verified"*. Clear the quarantine
attribute once and it's done:

```sh
xattr -cr /Applications/Pigeon.app
```

(Or right-click the app in Finder → **Open** → **Open anyway**.)

### Or build from source

```sh
brew install xcodegen
git clone https://github.com/MaroMushii/Pigeon.git
cd Pigeon/mac
xcodegen generate
open Pigeon.xcodeproj
```

Then in Xcode hit ⌘R. Requires Xcode 26.

## Using it

- **Add a channel:** ⌘N, then paste a username (`durov`), an `@handle`,
  or any t.me URL. The sheet also lists a few popular channels you can
  add with one click.
- **Read posts:** click a channel in the sidebar. Posts load in the
  main pane with text, images, video posters, view counts, reactions.
  Each post is marked read once it scrolls into view.
- **Auto-refresh:** Pigeon polls in the background. Mirror-backed
  channels refresh every 5 minutes (matching the mirror's cron),
  on-demand channels every 2 minutes. ⌘R forces an immediate refresh.
- **Unread badge:** the app's dock icon shows the total number of
  unread posts across all channels. Channel rows in the sidebar carry
  their own per-channel count.
- **Open a post:** right-click → *Open on telegram.org* to view it in
  your browser. (Telegram's own preview pages are public — no login.)

That's it. There is no settings screen, no account, no sync.

## Privacy

- No Telegram account. Pigeon only reads the same public preview pages
  Telegram itself shows at `t.me/s/<channel>`.
- No analytics, no telemetry, no remote logging.
- Channel list is stored locally in `~/Library/Containers/dev.MaroMushii.Pigeon`.
- Network traffic is HTTPS-only, to GitHub and Google. Telegram's
  servers don't see your IP.

## Credits

Inspired by the original
[ircfspace/teleMirror](https://github.com/ircfspace/teleMirror) Electron
client — Pigeon borrowed the Google-Translate proxy idea and the
Telegram widget DOM selectors as starting points, and rebuilt
everything else as a native macOS app.

Licensed under the [WTFPL](LICENSE) — do what the fuck you want.
