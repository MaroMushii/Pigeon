#!/usr/bin/env bash
# Regenerate appcast.xml using Sparkle's generate_appcast tool.
#
# Usage: update-appcast.sh <sparkle-bin-dir> <version> <dmg-path>
#   sparkle-bin-dir  path to the Sparkle bin/ directory
#   version          e.g. 1.2.3 (used to build the raw.githubusercontent.com download URL)
#   dmg-path         path to the built DMG
#
# Reads SPARKLE_PRIVATE_KEY from the environment (base64 private EdDSA key).
# generate_appcast extracts version info and computes the EdDSA signature from
# the app bundle inside the DMG.
set -euo pipefail

cd "$(dirname "$0")/../.."

SPARKLE_BIN="$1"
VERSION="$2"
DMG_PATH="$3"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Seed the staging dir: existing appcast (so previous entries are preserved)
# + the new DMG to sign.
[[ -f appcast.xml ]] && cp appcast.xml "$STAGING/"
cp "$DMG_PATH" "$STAGING/"

# DMGs live in the release branch under dist/ and are served via raw.githubusercontent.com,
# which is reachable from Iran (unlike release-assets.githubusercontent.com).
# generate_appcast reads the private key from stdin when --ed-key-file is "-".
echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/release/dist/" \
  --link "https://github.com/MaroMushii/Pigeon" \
  --embed-release-notes \
  --maximum-versions 5 \
  "$STAGING"

# Pigeon is ad-hoc signed (no Apple Developer team ID), so Sparkle's XPC
# installer service can't be launched from the sandbox. For each item:
#   - Rewrite any legacy github.com/releases/download enclosure URLs to raw.githubusercontent.com
#   - Set a per-item <link> to the raw DMG URL so clicking "View Update" triggers a
#     direct browser download (works from Iran, unlike the GitHub releases CDN)
#   - Mark as informationOnlyUpdate so Sparkle opens the link instead of trying to install
APPCAST_FILE="$STAGING/appcast.xml" python3 << 'PY'
import re, os

BASE = "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/release/dist"
path = os.environ['APPCAST_FILE']
content = open(path).read()

def fix_item(m):
    item = m.group(0)

    # Rewrite legacy github.com/releases/download enclosure URLs
    item = re.sub(
        r'url="https://github\.com/MaroMushii/Pigeon/releases/download/[^/]+/(Pigeon-[^"]+\.dmg)"',
        lambda mm: f'url="{BASE}/{mm.group(1)}"',
        item
    )

    # Per-item <link> → direct DMG download (works from Iran)
    ver_match = re.search(r'Pigeon-([0-9]+\.[0-9]+\.[0-9]+)\.dmg', item)
    dmg_link = f'{BASE}/Pigeon-{ver_match.group(1)}.dmg' if ver_match else "https://github.com/MaroMushii/Pigeon"
    if '<link>' in item:
        item = re.sub(r'<link>[^<]*</link>', f'<link>{dmg_link}</link>', item)
    else:
        item = item.replace('        </item>', f'        <link>{dmg_link}</link>\n        </item>')

    if '<sparkle:informationOnlyUpdate>' not in item:
        item = item.replace(
            '        </item>',
            '            <sparkle:informationOnlyUpdate>true</sparkle:informationOnlyUpdate>\n        </item>'
        )
    return item

content = re.sub(r'<item>.*?</item>', fix_item, content, flags=re.DOTALL)
open(path, 'w').write(content)
PY

cp "$STAGING/appcast.xml" appcast.xml
echo "==> appcast.xml updated for v${VERSION}"
