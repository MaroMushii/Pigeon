#!/usr/bin/env bash
# Orchestrates a Pigeon tagged release.
#
# What it does:
#   1. Validates preconditions (on main, clean tree, in sync with origin/main).
#   2. Validates the requested X.Y.Z version (semver-shaped, not already taken,
#      strictly newer than the latest existing tag).
#   3. Shows the commits that will ship (everything since the latest tag).
#   4. With --push, creates an annotated tag and pushes it.
#      Pushing the tag triggers .github/workflows/release.yml, which builds
#      Pigeon.app, packages .zip/.dmg, computes SHA256SUMS, and uploads
#      everything to a GitHub Release.
#
# By design, running without --push is a dry-run: it prints the plan and
# exits without mutating anything. Tag pushes are public, irreversible
# actions — the opt-in flag is the safety rail.
#
# Usage:
#   mac/scripts/release.sh --version 2.0.0
#   mac/scripts/release.sh --version 2.0.0 --push
#   mac/scripts/release.sh --version 2.0.0 --confirm
#   mac/scripts/release.sh --version 2.0.0 --push --watch
#
# Flags:
#   --version X.Y.Z   required, semver-shaped (no leading "v")
#   --push            actually create + push the tag (default: dry-run)
#   --confirm         like --push, but prompt interactively before tagging
#   --watch           after pushing, run `gh run watch` on the release workflow
#   --remote NAME     git remote to push to (default: origin)

set -euo pipefail

VERSION=""
DO_PUSH=0
DO_CONFIRM=0
DO_WATCH=0
REMOTE="origin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version requires X.Y.Z}"; shift 2 ;;
    --push)    DO_PUSH=1; shift ;;
    --confirm) DO_CONFIRM=1; shift ;;
    --watch)   DO_WATCH=1; shift ;;
    --remote)  REMOTE="${2:?--remote requires a name}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$DO_PUSH" -eq 1 && "$DO_CONFIRM" -eq 1 ]]; then
  echo "release.sh: pass --push or --confirm, not both" >&2
  exit 2
fi
WILL_PUSH=$(( DO_PUSH | DO_CONFIRM ))

if [[ -z "$VERSION" ]]; then
  echo "release.sh: --version X.Y.Z is required" >&2
  exit 2
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release.sh: '$VERSION' is not X.Y.Z-shaped (prerelease tags aren't supported)" >&2
  exit 2
fi

TAG="v$VERSION"

# --- Preconditions --------------------------------------------------------

HEAD_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

if [[ "$HEAD_BRANCH" != "main" ]]; then
  echo "release.sh: must be on 'main' (currently on '$HEAD_BRANCH')" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release.sh: working tree is dirty — commit or stash first" >&2
  git status --short >&2
  exit 1
fi

git fetch --tags --quiet "$REMOTE"

REMOTE_HEAD="$(git rev-parse "$REMOTE/main" 2>/dev/null || echo "")"
if [[ -z "$REMOTE_HEAD" ]]; then
  echo "release.sh: '$REMOTE/main' not found — is the remote configured?" >&2
  exit 1
fi

LOCAL_HEAD="$(git rev-parse HEAD)"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
  AHEAD="$(git rev-list --count "$REMOTE/main"..HEAD)"
  BEHIND="$(git rev-list --count HEAD.."$REMOTE/main")"
  if [[ "$BEHIND" -gt 0 ]]; then
    echo "release.sh: local main is behind $REMOTE/main by $BEHIND commit(s) — pull first" >&2
    exit 1
  fi
  if [[ "$WILL_PUSH" -ne 1 ]]; then
    echo "release.sh: local main is $AHEAD commit(s) ahead of $REMOTE/main" >&2
    echo "  Pass --push or --confirm to auto-push commits, or push manually first." >&2
    exit 1
  fi
  echo "Pushing $AHEAD unpublished commit(s) to $REMOTE/main..."
  git push "$REMOTE" main
fi
TAG_TARGET="$LOCAL_HEAD"
TAG_TARGET_LABEL="HEAD"

if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "release.sh: tag '$TAG' already exists locally" >&2
  exit 1
fi
if git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "release.sh: tag '$TAG' already exists on $REMOTE" >&2
  exit 1
fi

# Strict monotonic check against the highest existing v*.*.* tag.
# `--merged $REMOTE/main` rejects tags whose commits aren't on our main
# branch (e.g. inherited from a fork ancestor's remote). Without it, a
# stale upstream tag can be misread as the latest Pigeon release.
LAST_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged "$REMOTE/main" --sort=-v:refname | head -1 || true)"
if [[ -n "$LAST_TAG" ]]; then
  PREV="${LAST_TAG#v}"
  HIGHER="$(printf '%s\n%s\n' "$PREV" "$VERSION" | sort -V | tail -1)"
  if [[ "$HIGHER" != "$VERSION" || "$PREV" == "$VERSION" ]]; then
    echo "release.sh: '$VERSION' is not strictly newer than last tag '$LAST_TAG'" >&2
    exit 1
  fi
fi

# --- Plan -----------------------------------------------------------------

# Build the annotated tag message: subject + commit list since LAST_TAG.
# We capture this before the prompt so the printed plan and the eventual
# tag annotation are guaranteed to match what the user approved.
TAG_MSG_FILE="$(mktemp)"
trap 'rm -f "$TAG_MSG_FILE"' EXIT
{
  echo "Pigeon $VERSION"
  echo
  if [[ -n "$LAST_TAG" ]]; then
    echo "Changes since $LAST_TAG:"
    git --no-pager log --pretty='- %s' "$LAST_TAG".."$TAG_TARGET"
  else
    echo "Initial release."
  fi
} > "$TAG_MSG_FILE"

echo "Release plan"
echo "  version : $VERSION"
echo "  tag     : $TAG"
echo "  remote  : $REMOTE"
echo "  target  : $TAG_TARGET ($TAG_TARGET_LABEL)"
echo "  prev tag: ${LAST_TAG:-<none>}"
echo
echo "Tag annotation:"
sed 's/^/  /' "$TAG_MSG_FILE"
echo

if [[ "$WILL_PUSH" -ne 1 ]]; then
  echo "Dry-run only. Pass --push to create and push the tag, or --confirm to prompt."
  exit 0
fi

if [[ "$DO_CONFIRM" -eq 1 ]]; then
  read -r -p "Proceed with tagging and pushing $TAG? [y/N] " reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "release.sh: aborted" >&2; exit 1 ;;
  esac
fi

# --- Execute --------------------------------------------------------------

echo "Creating annotated tag $TAG at $TAG_TARGET_LABEL..."
git tag -a "$TAG" -F "$TAG_MSG_FILE" "$TAG_TARGET"

echo "Pushing $TAG to $REMOTE..."
git push "$REMOTE" "$TAG"

echo
echo "Tag pushed. The release workflow should now be running:"
echo "  https://github.com/MaroMushii/Pigeon/actions/workflows/release.yml"
echo

if [[ "$DO_WATCH" -eq 1 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "release.sh: --watch requires the 'gh' CLI" >&2
    exit 0
  fi
  # Poll for the workflow run that was triggered by *this* tag push.
  # `--branch "$TAG"` filters to runs whose ref is the tag (gh treats the
  # tag name as the head branch for tag-triggered runs). Cheaper than
  # sleep+limit-1, which could grab an unrelated prior run.
  RUN_ID=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    RUN_ID="$(gh run list --workflow release.yml --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    [[ -n "$RUN_ID" ]] && break
    sleep 2
  done
  if [[ -n "$RUN_ID" ]]; then
    gh run watch "$RUN_ID" --exit-status
  else
    echo "release.sh: couldn't locate the workflow run for $TAG after 20s; check the Actions tab manually." >&2
  fi
fi
