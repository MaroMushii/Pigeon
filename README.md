<p align="center">
  <img src="docs/logo.png" alt="Pigeon" width="160" />
</p>

<h1 align="center">Pigeon</h1>

<p align="center">
  Read Telegram public channels on your Mac — even when Telegram is
  blocked. No Telegram account, no VPN, no setup beyond installing the app.
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Pigeon main window — sidebar of channels on the left, an open Persian-language channel on the right" width="820" />
</p>

---

## Why it works in Iran

**What the firewall sees:**
Normal HTTPS connections to GitHub and Google — nothing that looks like Telegram.

---

## Install

Grab the latest `Pigeon-X.Y.Z.dmg` from the
[**Releases**](https://github.com/MaroMushii/Pigeon/releases) page, drag
the app to `/Applications`, and you're done. Requires macOS 26 (Tahoe).

The DMG is ad-hoc signed, so on first launch macOS will refuse with
*"can't be opened, developer cannot be verified"*. Clear the quarantine
attribute once and it's done:

```sh
xattr -cr /Applications/Pigeon.app
```

Or right-click the app in Finder → **Open** → **Open anyway**.

### Build from source

```sh
brew install xcodegen
git clone https://github.com/MaroMushii/Pigeon.git
cd Pigeon/mac
xcodegen generate
open Pigeon.xcodeproj
```

Then hit ⌘R in Xcode. Requires Xcode 26.

---

## Updates

Pigeon checks for updates automatically in the background. When a new version is available you'll see a prompt.

The app cannot install updates silently because it is not signed with an Apple Developer certificate — signing would require handing Apple identifying information, which conflicts with the privacy goals of this project. One manual install step per update is the deliberate trade-off.

---

## Using it

- **Add a channel:** ⌘N, then paste a username (`durov`), an `@handle`,
  or any `t.me` URL. The sheet also lists a few popular channels you can
  add with one click.
- **Read posts:** click a channel in the sidebar. Posts load in the
  main pane with text, images, video posters, view counts, and reactions.
  Each post is marked read once it scrolls into view.
- **Auto-refresh:** Pigeon polls in the background. Mirror-backed
  channels refresh every 5 minutes, on-demand channels every 2 minutes.
  ⌘R forces an immediate refresh.
- **Unread badge:** the dock icon shows the total number of unread posts
  across all channels. Channel rows in the sidebar carry their own count.
- **Open a post:** right-click → *Open on telegram.org* to view it in
  your browser. Telegram's preview pages are public — no login required.

There is no settings screen, no account, no sync.

---

## Privacy

- **No Telegram account.** Pigeon reads the same public preview pages
  Telegram shows at `t.me/s/<channel>` — scraped externally so your
  device never has to.
- **No analytics, no telemetry, no remote logging.**
- **Your channel list stays on your Mac**, in
  `~/Library/Containers/dev.MaroMushii.Pigeon`.
- **Network traffic is HTTPS-only**, to GitHub and Google.
- **No Apple Developer certificate.** Signing the app would require
  submitting identifying information to Apple. Pigeon is ad-hoc signed
  specifically to avoid that.

---

## Credits

Inspired by [ircfspace/teleMirror](https://github.com/ircfspace/teleMirror) —
Pigeon borrowed the Google Translate proxy idea and the Telegram widget
DOM selectors as starting points, and rebuilt everything else as a
native macOS app.

Licensed under the [WTFPL](LICENSE) — do what the fuck you want.
