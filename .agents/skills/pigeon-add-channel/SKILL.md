---
name: pigeon-add-channel
description: >
  Use when adding, supporting, or onboarding a new Telegram channel into
  Pigeon — i.e. any time the user mentions "add channel", "support channel",
  "new channel", or names a Telegram username they want mirrored or visible
  in the app. Both the scraper manifest and the Swift chip catalogue must be
  updated together or the channel will be missing from one path.
---

# Pigeon: Adding a New Channel

Two files must be updated together. Skipping either causes a visible gap —
the channel either won't be scraped or won't appear in the pre-cached chip
list inside AddChannelSheet.

---

## Step 1 — mirror/channels.json (scraper manifest)

Add the Telegram username (lowercase, exact) in alphabetical order inside
the `"channels"` array.

```json
// mirror/channels.json
{
  "channels": [
    ...
    "new_channel_username",
    ...
  ]
}
```

The mirror scraper re-reads this file on every cron tick (~5 min). No
deploy needed — the next GH Actions run picks it up automatically.

---

## Step 2 — mac/Pigeon/Stores/PopularChannelsStore.swift (chip catalogue)

Add a `.init(username:displayName:)` entry to the `channels` array. Use the
channel's canonical English name (check its actual Telegram title if
unsure). Insert it at a logical position — roughly grouped by topic or
prominence, with `telegram` and `durov` last.

```swift
// mac/Pigeon/Stores/PopularChannelsStore.swift
.init(username: "new_channel_username", displayName: "Channel Display Name"),
```

To find the real display name when uncertain, fetch the live snapshot title:

```sh
curl -s "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/<username>/snapshot.json" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['channel']['title'])"
```

If the snapshot doesn't exist yet (channel not scraped yet), check
`t.me/<username>` or ask the user for the preferred display name.

---

## Checklist

- [ ] `mirror/channels.json` — username added, list stays alphabetical
- [ ] `PopularChannelsStore.swift` — `.init` entry added with English display name
- [ ] Build the mac target (`just build`) and verify the chip appears in AddChannelSheet
- [ ] Commit both changes together under `feat(mirror+mac): add <username> channel`
