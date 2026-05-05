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

# Regenerate Xcode project + build Debug, then reveal the .app in Finder
build:
    cd mac && xcodegen generate
    cd mac && xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug build 2>&1 | {{xcb}}
    just reveal

# Run the test bundle
test:
    cd mac && xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -configuration Debug test 2>&1 | {{xcb}}

# Open the freshest Debug build
app:
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app | head -1)"

# Reveal the freshest Debug build in Finder
reveal:
    open -R "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pigeon-*/Build/Products/Debug/Pigeon.app | head -1)"

# Trash all DerivedData copies (per CLAUDE.md: trash, never rm)
clean:
    trash ~/Library/Developer/Xcode/DerivedData/Pigeon-* 2>/dev/null || true

# Build release artifacts into mac/dist and reveal the dir in Finder. Does NOT push a tag.
release version:
    mac/scripts/build.sh --version {{version}}
    open mac/dist

# Create + push a release tag (triggers .github/workflows/release.yml)
tag version:
    mac/scripts/release.sh --version {{version}} --push

# Mirror typecheck (offline; useful before pushing schema changes)
mirror-check:
    cd mirror && pnpm typecheck
