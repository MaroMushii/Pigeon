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

if command -v xcbeautify >/dev/null; then
  RENDERER=terminal
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] && RENDERER=github-actions
  xcodebuild "${XCBUILD_ARGS[@]}" | xcbeautify --renderer "$RENDERER"
else
  xcodebuild "${XCBUILD_ARGS[@]}"
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
DMG_STAGE="$(mktemp -d -t pigeon-dmg)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$OUTPUT/Pigeon.app" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "Pigeon $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$OUTPUT/Pigeon-$VERSION.dmg" >/dev/null

echo "==> done"
ls -lh "$OUTPUT"
