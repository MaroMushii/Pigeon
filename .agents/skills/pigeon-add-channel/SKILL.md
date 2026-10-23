---
name: pigeon-add-channel
description: End-to-end procedure for adding a new Telegram channel to Pigeon — mirror manifest entry, in-app discovery entry, and locally-bundled avatar. Load when the user asks to add, register, or onboard a `@channelname` to Pigeon, or mentions `popular-channels.json` / `popular-channel-avatars/`.
license: MIT
user-invocable: false
---

# Adding a channel to Pigeon

Three artifacts. **Username is the join key everywhere** — same string in all three places. Skip any one and discovery is half-broken.

## The three artifacts

```
┌────────────────────────────────────────────────────────────────┐
│ 1. mirror/channels.json                                        │
│    → tells the scraper to fetch this channel every cron tick   │
│                                                                │
│ 2. mac/Pigeon/Resources/popular-channels.json                  │
│    → JSON array of usernames for the "Popular channels" chips  │
│      (no display name field — chip renders @<username>)        │
│                                                                │
│ 3. mac/Pigeon/Resources/popular-channel-avatars/<username>.jpg │
│    → avatar shown in the chip BEFORE the user subscribes       │
│      (post-subscription Pigeon uses the mirror's photo_path)   │
└────────────────────────────────────────────────────────────────┘
```

Why bundle the avatar instead of fetching it at runtime: the discovery chip grid renders before any network call. A cold launch on a fresh install in Iran shouldn't depend on the mirror being reachable to show "here's what you could subscribe to."

Why no separate display name: `ChannelService.swift` overwrites `channel.displayName` with the mirror's `title` after subscribe. The chip itself shows `@<username>` (matching Telegram's own UX for unsubscribed channels), so a hand-maintained display name would just be duplicated state that drifts.

## Procedure

### Step 1 — append username to both JSON files

- `mirror/channels.json` → append the username to the `"channels"` array (alphabetical, by convention).
- `mac/Pigeon/Resources/popular-channels.json` → append the username string. It's a flat `["a", "b", "c"]` array — no objects, no fields.

### Step 2 — commit + push to main (requires user confirmation)

```sh
git add mirror/channels.json mac/Pigeon/Resources/popular-channels.json
git commit -m "feat(mirror): add <username> channel"
git push origin main      # CLAUDE.md rule: explicit OK first
```

The scraper re-reads the manifest at the start of every run, so the change is live as soon as `main` is updated. No deploy.

### Step 3 — kick the workflow, don't wait for the cron

```sh
gh workflow run mirror.yml
gh run watch $(gh run list --workflow mirror.yml -L 1 --json databaseId -q '.[0].databaseId') --exit-status
```

Cron lag on the GH free tier can be 30+ minutes; manual dispatch finishes in ~1 min for a single new channel.

### Step 4 — pull avatar coords from the mirror

```sh
curl -s "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/<username>/snapshot.json" \
  | python3 -c "
import sys,json
c=json.load(sys.stdin).get('channel',{})
print('photo_path:', c.get('photo_path'))
print('photo_sha256:', c.get('photo_sha256'))
"
```

You don't need `title` anymore — it's not used in the catalogue.

### Step 5 — download the avatar from the mirror (NOT t.me)

```sh
curl -s -o "mac/Pigeon/Resources/popular-channel-avatars/<username>.jpg" \
  "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/<photo_path>"

# integrity check — must equal photo_sha256 from the snapshot
shasum -a 256 "mac/Pigeon/Resources/popular-channel-avatars/<username>.jpg"

# sanity check — should be JPEG ~160x160 like the others
file "mac/Pigeon/Resources/popular-channel-avatars/<username>.jpg"
```

**Why the mirror and not t.me directly:** dev machines may be in Iran. The "Never request t.me directly" rule from CLAUDE.md is about the app's runtime, but the spirit applies to tooling — and the mirror has a verified sha256 anyway, so it's strictly better. The mirror's content-addressed paths (`media/<hash>.<ext>`) don't expire and the bytes match exactly what users will fetch.

### Step 6 — no xcodegen needed for the avatar

`popular-channel-avatars/` is a **folder reference** in `mac/project.yml` (search for `type: folder`). Dropping a new `.jpg` in is picked up by the next build automatically — no `xcodegen generate` required.

### Step 7 — commit the avatar separately

```sh
git add mac/Pigeon/Resources/popular-channel-avatars/<username>.jpg
git commit -m "feat(mac): bundle <username> avatar for discovery"
git push origin main
```

Keeping the avatar commit separate from the manifest commit matches the actual workflow order: manifest first (so the mirror can scrape), avatar second (pulled from the now-populated mirror).

## How the chip resolves the avatar

`PopularChannelsStore.swift`:
```swift
struct PopularChannelInfo {
    let username: String
    var avatarFilename: String { "\(username).jpg" }
}
```

`PopularChannelChips.swift` then resolves `Bundle.main.url(forResource: avatarFilename, subdirectory: "popular-channel-avatars")`. Missing files degrade to a colored letter chip — keeps the grid looking complete during partial fills.

## Anti-patterns

- ✗ **Adding a `displayName` field.** Killed deliberately. The chip shows `@<username>`; the subscribed title comes from the mirror. There is no third place a display name belongs.
- ✗ **Downloading the avatar from `t.me/<username>` directly.** Skips the integrity check, uses an unstable URL, and risks DPI exposure on Iran-side dev machines. Use the mirror.
- ✗ **Committing the manifest change in the same commit as the avatar.** The mirror needs the manifest landed *first* before the avatar can be pulled — split commits to match the actual order.
- ✗ **Running `xcodegen generate` after dropping the avatar.** Does nothing useful, rewrites `Info.plist`/entitlements as a side effect, pollutes the diff.
- ✗ **Putting a placeholder grey avatar JPG.** The in-app initials fallback handles missing files — don't ship a placeholder.

## Verification checklist

After all commits land:

- [ ] `curl -sI https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/<username>/snapshot.json` → `HTTP 200`
- [ ] `popular-channels.json` contains the username string
- [ ] `popular-channel-avatars/<username>.jpg` exists, ~160×160 JPEG, sha256 matches the snapshot's `photo_sha256`
- [ ] `xcodebuild ... build` succeeds and the channel appears in the in-app discovery list with the bundled avatar (label is `@<username>`)

## When *not* to use this skill

- **User wants an un-mirrored channel to "just work".** That's the GT-proxy fallback path — `TelegramClient.swift` handles it. No file changes needed, but it's slower and more fragile. This skill is for *promoting* a channel to the mirrored + curated set.
- **Channel is private or requires login.** Pigeon only reads public `t.me/s/<username>` pages. Don't add it; tell the user it's out of scope.
