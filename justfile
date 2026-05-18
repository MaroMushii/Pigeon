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

# Regenerate Pigeon.xcodeproj from mac/project.yml — run after editing project.yml or adding/removing sources
gen:
    cd mac && xcodegen generate

# Build Debug
build:
    cd mac && NSUnbufferedIO=YES xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build 2>&1 | {{xcb}}

# Build Debug and launch a fresh copy (kills any running instance after a successful build)
run: build kill
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
    git fetch --tags --quiet origin
    version="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged origin/main --sort=-v:refname | head -1 | sed 's/^v//')"
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
    # `--merged origin/main` filters out tags whose commits aren't on our
    # main branch — e.g. tags that leaked in from a fork ancestor's remote.
    # Without this, a stale upstream tag like v3.2.0 can pose as the latest.
    git fetch --tags --quiet origin
    last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged origin/main --sort=-v:refname | head -1)"
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
    # --confirm validates preconditions, prints the plan, prompts on /dev/tty,
    # and only then tags + pushes. One invocation closes the previous
    # double-validation window where the tree could have shifted between
    # the dry-run and the actual push.
    mac/scripts/release.sh --version "$next" --confirm

# Subsystem used by AppLog. Single source of truth for the log predicates below.
log_subsystem := "dev.MaroMushii.Pigeon"

# Tail Pigeon logs live. Examples:
#   just logs                 # everything Pigeon emits, live
#   just logs scroll          # only Scroll, live
#   just logs measure         # only row-height measurement, live
# Categories: scroll, mount, measure, visible, feed, net, mirror, all (default). Ctrl-C to stop.
logs category="all":
    #!/usr/bin/env bash
    set -euo pipefail
    cat=$(echo "{{category}}" | tr '[:upper:]' '[:lower:]')
    if [[ "$cat" == "all" ]]; then
      pred='subsystem == "{{log_subsystem}}"'
    else
      # First letter uppercase to match AppLog category strings ("Scroll", "Measure", ...).
      capped="$(tr '[:lower:]' '[:upper:]' <<< ${cat:0:1})${cat:1}"
      pred='subsystem == "{{log_subsystem}}" AND category == "'"$capped"'"'
    fi
    echo "==> tailing $cat — Ctrl-C to stop"
    exec log stream --style compact --level info --predicate "$pred"

# Dump last <duration> of Pigeon logs and exit. Examples:
#   just logs-since                       # all categories, last 5m
#   just logs-since scroll                # Scroll only, last 5m
#   just logs-since measure 30s           # Measure only, last 30s
# Duration syntax: 30s, 5m, 1h. Categories: same vocab as `just logs`.
logs-since category="all" duration="5m":
    #!/usr/bin/env bash
    set -euo pipefail
    cat=$(echo "{{category}}" | tr '[:upper:]' '[:lower:]')
    if [[ "$cat" == "all" ]]; then
      pred='subsystem == "{{log_subsystem}}"'
    else
      capped="$(tr '[:lower:]' '[:upper:]' <<< ${cat:0:1})${cat:1}"
      pred='subsystem == "{{log_subsystem}}" AND category == "'"$capped"'"'
    fi
    echo "==> dumping $cat (last {{duration}})"
    log show --style compact --info --debug --last {{duration}} --predicate "$pred"

# Record an Instruments SwiftUI trace of the running app → ~/Desktop/pigeon-<ts>.trace
# Example: just trace 20    # 20-second trace; default 15s. App must already be running.
trace seconds="15":
    #!/usr/bin/env bash
    set -euo pipefail
    ts=$(date +%Y%m%d-%H%M%S)
    out="$HOME/Desktop/pigeon-$ts.trace"
    echo "==> recording SwiftUI trace for {{seconds}}s → $out"
    xcrun xctrace record \
      --template "SwiftUI" \
      --attach Pigeon \
      --time-limit {{seconds}}s \
      --output "$out"
    echo "==> done. Open in Instruments:  open '$out'"

# Mirror typecheck (offline; useful before pushing schema changes)
mirror-check:
    cd mirror && pnpm typecheck

# Manually trigger the mirror workflow on GitHub (useful when the
# scheduled cron is throttled and you want fresh data right now).
update-mirror:
    gh workflow run mirror.yml --repo MaroMushii/Pigeon
