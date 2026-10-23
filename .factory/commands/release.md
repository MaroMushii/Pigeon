---
description: Draft a user-facing changelog for the latest release and apply it once the workflow is green
allowed-tools: Bash, Read, Write, Edit
---

You are the release engineer for Pigeon. The user has already run
`just ship` (or is in the middle of doing so) — your job is to wait for
the resulting workflow to finish, **prepare the changelog while it
runs**, and replace the placeholder release notes with the polished
version once the build is green.

You do **not** run `just ship`. You do **not** push tags. You only read
git history, draft notes, watch the workflow, and edit the release.

# Steps

## 1. Find the latest tag

```sh
latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
prev_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | sed -n '2p')"
```

Refresh remote tags first so a freshly-pushed tag shows up locally:

```sh
git fetch --tags --quiet origin
```

If `latest_tag` is empty, stop — there are no releases to apply notes to.

If `latest_tag` is not present on `origin`, the user hasn't completed
`just ship` (the y/N push prompt is still pending or was aborted):

```sh
git ls-remote --tags origin "refs/tags/$latest_tag" >/dev/null 2>&1 \
  || { echo "Latest tag $latest_tag not on origin yet — has \`just ship\` finished?" >&2; exit 1; }
```

In that case, ask the user whether to wait for them to complete the
push, or to bail.

## 2. Locate the release workflow run

```sh
run_id="$(gh run list --repo MaroMushii/Pigeon --workflow release.yml \
  --limit 5 --json databaseId,headBranch \
  --jq ".[] | select(.headBranch == \"$latest_tag\") | .databaseId" \
  | head -1)"
```

If empty, the tag push hasn't propagated to GitHub yet. Sleep 10s and
retry up to 3 times before giving up. If still empty after retries,
surface and stop — the user can re-run `/release` in a moment.

## 3. Draft the changelog (do this while the workflow is running)

Get the commits in this release:

```sh
git log "$prev_tag".."$latest_tag" --no-merges --format='%h%x09%s'
```

If a commit's subject is too terse, peek at its body:

```sh
git log "$prev_tag".."$latest_tag" --no-merges --format='%h%n%s%n%n%b%n---'
```

Filter rules — only include what an **end user** can perceive:

- **Include:** `feat:`, `fix:`, `perf:` (and reverts of those).
- **Skip silently:** `chore:`, `docs:`, `style:`, `test:`, `ci:`,
  `refactor:`, `build:`. These don't move users — never surface them in
  release notes, even if the diff is large.

For each included commit:

- Strip the conventional prefix (`feat(mac):` → `…`).
- Rewrite the subject as a short, user-facing one-liner. Imperative
  mood, sentence case, no trailing period.
- Append the scope as a parenthetical only if it's `(mac)` or
  `(mirror)` — drop `(ci)` since CI changes shouldn't surface in a
  user-facing changelog at all (the filter above should already exclude
  them; this is a belt-and-suspenders rule).

Section order (omit any section that's empty):

```markdown
### New features
- Surface mirror sweep health in sidebar footer _(mac)_

### Fixes
- Refresh mirror health on manual reload _(mac)_

### Performance
- Switch feed to LazyVStack to handle 100-post retention _(mac)_
```

If the filter leaves zero entries, the release is internal-only — show
the user a single line saying "No user-facing changes in $latest_tag —
internal/tooling release. Apply empty notes anyway?" and let them
decide.

## 4. Show the draft + iterate

Print the draft. Ask: "Any edits?" If they ask for changes, apply them
and reprint. Don't proceed to step 5 until they explicitly approve.

This step is intentionally where time is spent — the workflow is
running concurrently, so review here is "free."

## 5. Wait for the workflow to finish

```sh
gh run watch "$run_id" --repo MaroMushii/Pigeon --exit-status --interval 30
```

If the run already finished while the user was reviewing, this returns
immediately with the final status.

If the run failed (`gh run watch --exit-status` exits non-zero), **stop
here.** Don't apply notes to a broken release. Surface the failure with:

```sh
gh run view "$run_id" --repo MaroMushii/Pigeon --log-failed
```

…and let the user decide whether to retag or investigate.

## 6. Apply the polished notes

Compose the full body — the changelog from step 3 plus the standard
installation/verification block. Write to a temp file under
`mac/dist/` (gitignored):

```sh
version="${latest_tag#v}"
notes_file="mac/dist/release-notes-$latest_tag.md"
```

Body shape:

```markdown
### New features
- ...

### Fixes
- ...

### Performance
- ...

---

### Installation

Download `Pigeon-<version>.dmg` (or the `.zip`) below.

This build is **ad-hoc signed**, so on first launch macOS will refuse
to open it ("can't be opened, developer cannot be verified"). To clear
the quarantine flag:

```sh
xattr -cr /Applications/Pigeon.app
```

Or right-click the app in Finder → Open → Open anyway in the warning
dialog. You only need to do this once.

### Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon or Intel

### Verifying the download

Compare against `SHA256SUMS.txt`:

```sh
shasum -a 256 -c SHA256SUMS.txt
```
```

Substitute `<version>` with `$version` (no leading `v`) everywhere.

Apply:

```sh
gh release edit "$latest_tag" --repo MaroMushii/Pigeon \
  --notes-file "$notes_file"
```

Print the release URL:

```sh
gh release view "$latest_tag" --repo MaroMushii/Pigeon \
  --json url --jq .url
```

## 7. Cleanup

```sh
trash "$notes_file"
```

(Per repo convention: `trash`, not `rm`.)

# Hard rules

- **Never** run `just ship` from this command. The user owns that.
- **Never** create or push git tags. The user owns that too.
- **Never** apply notes to a failed workflow run. Failed releases stay
  with their default notes so they look obviously broken.
- **Never** run `gh release delete`, `git push --force`, or
  `git reset --hard` to "fix" a stuck release. Ask the user.
- **Never** include `chore:`, `docs:`, `style:`, `test:`, `ci:`,
  `refactor:`, or `build:` commits in published release notes — even if
  the user asks "what changed?", show those only in an internal
  draft, never in the body that lands on GitHub.
- If `latest_tag` and the previous release notes look identical (i.e.
  someone already ran `/release` for this tag), it's safe to re-apply —
  the operation is idempotent — but mention it so the user isn't
  surprised by the no-op edit.
