# Pigeon task runner. All recipes run from the repo root regardless of
# where `just` is invoked. The shell scripts under mac/scripts/ remain
# the canonical implementations — these recipes are thin wrappers.

set shell := ["bash", "-uc", "-o", "pipefail"]

# Pretty-print xcodebuild output if xcbeautify is on PATH; otherwise pass
# through unchanged. Resolved once at parse time.
xcb := `command -v xcbeautify >/dev/null && echo xcbeautify || echo cat`

# Show the recipe list
default:
    @just --list

# Regenerate Xcode project + build Debug
build: xcbuild

# Build Debug and launch a fresh copy (kills any running instance after a successful build)
run: xcbuild kill
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app | head -1)"

# Kill the running Pigeon app, if any (waits for full termination)
[private]
kill:
    pkill -x Pigeon 2>/dev/null || true
    for i in {1..50}; do pgrep -x Pigeon >/dev/null 2>&1 || break; sleep 0.1; done

# Run the test bundle
test:
    cd mac && NSUnbufferedIO=YES xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug test 2>&1 | {{xcb}}

# Open the freshest Debug build (does not rebuild)
app:
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app | head -1)"

# Regenerate Xcode project + build Debug. No reveal, no launch.
[private]
xcbuild:
    cd mac && xcodegen generate
    cd mac && NSUnbufferedIO=YES xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build 2>&1 | {{xcb}}

# Reveal the freshest Debug build in Finder
reveal:
    open -R "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app | head -1)"

# Trash all DerivedData copies (per CLAUDE.md: trash, never rm)
clean: kill
    -trash ~/Library/Developer/Xcode/DerivedData/Pigeon-*

# Build release artifacts into mac/dist using the current version (latest v*.*.* tag) and reveal the .dmg in Finder. Does NOT push a tag.
package:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//')"
    [[ -n "$version" ]] || { echo "package: no v*.*.* tag found — run 'just ship patch|minor|major' first" >&2; exit 1; }
    echo "==> packaging current version: $version"
    mac/scripts/build.sh --version "$version"
    open -R "mac/dist/Pigeon-$version.dmg"

# Bump version (patch|minor|major) from the latest tag, then create + push the new tag (triggers .github/workflows/release.yml)
ship bump:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{bump}}" in
      patch|minor|major) ;;
      *) echo "ship: bump must be one of: patch, minor, major (got '{{bump}}')" >&2; exit 2 ;;
    esac
    last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
    [[ -n "$last" ]] || { echo "ship: no existing v*.*.* tag to bump from — push v0.1.0 manually first" >&2; exit 1; }
    IFS=. read -r major minor patch <<<"${last#v}"
    case "{{bump}}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
    esac
    next="$major.$minor.$patch"
    echo "==> bumping {{bump}}: $last → v$next"
    echo
    mac/scripts/release.sh --version "$next"
    read -r -p "Push v$next now? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "ship: aborted." >&2; exit 1 ;;
    esac
    mac/scripts/release.sh --version "$next" --push

# Mirror typecheck (offline; useful before pushing schema changes)
mirror-check:
    cd mirror && pnpm typecheck

# Manually trigger the mirror workflow on GitHub (useful when the
# scheduled cron is throttled and you want fresh data right now).
update-mirror:
    gh workflow run mirror.yml --repo MaroMushii/Pigeon
