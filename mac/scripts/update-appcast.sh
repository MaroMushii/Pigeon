#!/usr/bin/env bash
# Regenerate appcast.xml using Sparkle's generate_appcast tool.
#
# Usage: update-appcast.sh <sparkle-bin-dir> <version> <dmg-path>
#   sparkle-bin-dir  path to the Sparkle bin/ directory
#   version          e.g. 1.2.3 (used to build the GitHub release download URL)
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

# generate_appcast reads the private key from stdin when --ed-key-file is "-".
echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/MaroMushii/Pigeon/releases/download/v${VERSION}/" \
  --link "https://github.com/MaroMushii/Pigeon" \
  --embed-release-notes \
  --maximum-versions 5 \
  "$STAGING"

# Pigeon is ad-hoc signed (no Apple Developer team ID), so Sparkle's XPC
# installer service can't be launched from the sandbox. Mark every item as
# informational-only: Sparkle will show the update notification but open the
# GitHub releases page in the browser instead of trying to run the installer.
APPCAST_FILE="$STAGING/appcast.xml" python3 << 'PY'
import re, os

path = os.environ['APPCAST_FILE']
content = open(path).read()

def add_flag(m):
    item = m.group(0)
    if '<sparkle:informationOnlyUpdate>' not in item:
        item = item.replace(
            '        </item>',
            '            <sparkle:informationOnlyUpdate>true</sparkle:informationOnlyUpdate>\n        </item>'
        )
    return item

content = re.sub(r'<item>.*?</item>', add_flag, content, flags=re.DOTALL)
open(path, 'w').write(content)
PY

cp "$STAGING/appcast.xml" appcast.xml
echo "==> appcast.xml updated for v${VERSION}"
