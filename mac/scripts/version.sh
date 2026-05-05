#!/usr/bin/env bash
# Resolves the marketing version for a Pigeon release build.
#
# Sources, in priority order:
#   1. --version <X.Y.Z>
#   2. GITHUB_REF env (when it points at a tag matching v*.*.*)
#
# Output: bare semver (no leading "v") on stdout. Exits non-zero on failure.
#
# Pigeon doesn't use prerelease versions — only plain X.Y.Z is accepted.

set -euo pipefail

VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:?--version requires a value}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "version.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" && "${GITHUB_REF:-}" =~ ^refs/tags/v(.+)$ ]]; then
  VERSION="${BASH_REMATCH[1]}"
fi

if [[ -z "$VERSION" ]]; then
  echo "version.sh: no version (pass --version X.Y.Z or set GITHUB_REF=refs/tags/vX.Y.Z)" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version.sh: '$VERSION' is not X.Y.Z-shaped (prerelease versions are not supported)" >&2
  exit 1
fi

printf '%s\n' "$VERSION"
