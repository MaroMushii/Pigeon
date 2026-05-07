#!/usr/bin/env bash
# Builds Pigeon.app for release and packages it as .zip and .dmg.
#
# Ad-hoc signed (CODE_SIGN_IDENTITY="-"); the resulting bundles will not
# pass Gatekeeper without manual quarantine clearing — see release notes.
#
# Usage:
#   build.sh --version 0.2.0 [--build 42] [--output mac/dist]
#
# Defaults:
#   --version  resolved via scripts/version.sh (reads GITHUB_REF)
#   --build    GITHUB_RUN_NUMBER, else 1
#   --output   mac/dist (relative to repo root)
#
# Produces under <output>/:
#   Pigeon.app
#   Pigeon-<version>.zip
#   Pigeon-<version>.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
BUILD=""
OUTPUT="$MAC_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --build)   BUILD="${2:?}";   shift 2 ;;
    --output)  OUTPUT="${2:?}";  shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || VERSION="$("$SCRIPT_DIR/version.sh")"
[[ -n "$BUILD"   ]] || BUILD="${GITHUB_RUN_NUMBER:-1}"

echo "==> Pigeon $VERSION (build $BUILD) → $OUTPUT"

command -v xcodegen >/dev/null || {
  echo "build.sh: xcodegen not found (brew install xcodegen)" >&2
  exit 1
}

command -v create-dmg >/dev/null || {
  echo "build.sh: create-dmg not found (brew install create-dmg)" >&2
  exit 1
}

DMG_BG="$MAC_DIR/assets/dmg/background.png"
[[ -f "$DMG_BG" ]] || {
  echo "build.sh: DMG background missing at <$DMG_BG>" >&2
  echo "  expected: mac/assets/dmg/background.png (512x512) + background@2x.png (1024x1024)" >&2
  exit 1
}

cd "$MAC_DIR"

echo "==> regenerating Xcode project"
xcodegen generate --quiet

DERIVED="$MAC_DIR/build"
rm -rf "$DERIVED"

echo "==> xcodebuild Release"
XCBUILD_ARGS=(
  -project Pigeon.xcodeproj
  -scheme Pigeon
  -configuration Release
  -derivedDataPath "$DERIVED"
  -destination "generic/platform=macOS"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD"
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM=
  build
)

BUILD_LOG="$DERIVED/xcodebuild.log"
mkdir -p "$DERIVED"

if command -v xcbeautify >/dev/null; then
  RENDERER=terminal
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] && RENDERER=github-actions
  # Tee the raw xcodebuild output (stdout + stderr) to a log before
  # xcbeautify consumes it. xcbeautify happily filters out actool
  # errors, so when builds fail in CI the only place to find the real
  # cause is this file — the workflow uploads it as an artifact.
  xcodebuild "${XCBUILD_ARGS[@]}" 2>&1 \
    | tee "$BUILD_LOG" \
    | xcbeautify --renderer "$RENDERER"
else
  xcodebuild "${XCBUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
fi

APP_SRC="$DERIVED/Build/Products/Release/Pigeon.app"
[[ -d "$APP_SRC" ]] || { echo "build.sh: $APP_SRC not produced" >&2; exit 1; }

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/Pigeon.app" \
       "$OUTPUT/Pigeon-$VERSION.zip" \
       "$OUTPUT/Pigeon-$VERSION.dmg"
cp -R "$APP_SRC" "$OUTPUT/Pigeon.app"

PLIST="$OUTPUT/Pigeon.app/Contents/Info.plist"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "==> bundle reports version=$ACTUAL_VERSION build=$ACTUAL_BUILD"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || {
  echo "build.sh: version substitution failed — Info.plist has '$ACTUAL_VERSION', wanted '$VERSION'" >&2
  exit 1
}

echo "==> verifying ad-hoc signature"
codesign --verify --deep --strict --verbose=2 "$OUTPUT/Pigeon.app"

echo "==> packaging .zip"
ditto -c -k --keepParent "$OUTPUT/Pigeon.app" "$OUTPUT/Pigeon-$VERSION.zip"

echo "==> packaging .dmg"
# 512x512 painted-background install window. Icon coords are tuned to land
# inside the painted wells in mac/assets/dmg/background@2x.png — re-export
# the BG and they'll need re-tuning. The drop link is supplied by create-dmg
# itself, so the staging dir holds only the .app.
DMG_STAGE="$(mktemp -d -t pigeon-dmg)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$OUTPUT/Pigeon.app" "$DMG_STAGE/"

create-dmg \
  --volname "Pigeon $VERSION" \
  --background "$DMG_BG" \
  --window-pos 200 120 \
  --window-size 512 512 \
  --icon-size 96 \
  --text-size 12 \
  --icon "Pigeon.app" 256 144 \
  --hide-extension "Pigeon.app" \
  --app-drop-link 256 334 \
  --no-internet-enable \
  "$OUTPUT/Pigeon-$VERSION.dmg" \
  "$DMG_STAGE" >/dev/null

echo "==> done"
ls -lh "$OUTPUT"
