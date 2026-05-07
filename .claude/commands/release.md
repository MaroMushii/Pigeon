---
description: Draft a user-facing changelog and ship a new Pigeon release
allowed-tools: Bash, Read, Write, Edit
argument-hint: "[patch|minor|major]"
---

You are the release engineer for Pigeon. Your job is to draft a polished,
user-facing changelog and drive the release end-to-end via `just ship`.

# Steps

## 1. Gather commits since the last tag

```sh
last_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
git log "$last_tag"..HEAD --no-merges --format='%h%x09%s'
```

If a commit's subject doesn't tell the full story, read its body:

```sh
git log "$last_tag"..HEAD --no-merges --format='%h%n%s%n%n%b%n---'
```

## 2. Draft the changelog

Only include commits that an **end user** would care about. Filter rules:

- **Include:** `feat:`, `fix:`, `perf:` (and `revert:` of any of these)
- **Skip silently:** `chore:`, `docs:`, `style:`, `test:`, `ci:`, `refactor:`,
  `build:`. These don't move users — keep them out of release notes even if
  the diff is large.

For each included commit:

- Strip the conventional prefix (`feat(mac):` → `…`).
- Rewrite the subject as a short, user-facing one-liner. Imperative mood,
  sentence case, no trailing period.
- Append the scope as a parenthetical only if it's `(mac)` or `(mirror)` —
  drop `(ci)` since user-visible CI changes are rare and confusing in a
  changelog.

Group into sections — omit any section that's empty:

```markdown
### New features
- Surface mirror sweep health in sidebar footer _(mac)_

### Fixes
- Refresh mirror health on manual reload _(mac)_

### Performance
- Switch feed to LazyVStack to handle 100-post retention _(mac)_
```

## 3. Show the draft + ask for the bump

Print the draft to the user as plain markdown. Then ask two things:

1. "Any edits to the changelog?"
2. "Bump kind: patch / minor / major?"

If `$ARGUMENTS` already contains a bump kind (`patch`/`minor`/`major`), use
that and only ask about edits.

Iterate on the changelog until the user is happy. Don't proceed to step 4
until they explicitly approve.

## 4. Compute the next version

```sh
last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
IFS=. read -r major minor patch <<<"${last#v}"
# bump major/minor/patch per the user's choice (mirror what justfile does)
next="X.Y.Z"
```

This must match `justfile`'s ship recipe exactly — if they diverge, the file
you write and the tag `just ship` creates will refer to different versions.

## 5. Write the full release body to a temp file

The body is the polished changelog **plus** the installation/verification
block. Save it under `mac/dist/` (already gitignored):

```sh
notes_file="mac/dist/release-notes-v$next.md"
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

This build is **ad-hoc signed**, so on first launch macOS will refuse to
open it ("can't be opened, developer cannot be verified"). To clear the
quarantine flag:

```sh
xattr -cr /Applications/Pigeon.app
```

Or right-click the app in Finder → Open → Open anyway in the warning
dialog. You only need to do this once.

### Requirements

- macOS 26 (Tahoma) or later
- Apple Silicon or Intel

### Verifying the download

Compare against `SHA256SUMS.txt`:

```sh
shasum -a 256 -c SHA256SUMS.txt
```
```

Substitute `<version>` with the actual `$next` everywhere.

## 6. Run `just ship <bump>`

```sh
just ship <bump>
```

This recipe runs its own dry-run (showing the commits that will ship) and
prompts the user with `Push v$next now? [y/N]`. **Do not** try to bypass
that prompt — it's the safety rail for an irreversible action. The user
either confirms or aborts.

If the user aborts, stop. Don't clean up the notes file — they may want to
re-run.

## 7. Watch the release workflow

After the tag is pushed, the `release.yml` workflow runs on `macos-26`
(takes ~10–15 min). Locate it and watch:

```sh
sleep 5
run_id="$(gh run list --workflow release.yml --limit 1 \
  --json databaseId,headBranch,event \
  --jq '.[0].databaseId')"
gh run watch "$run_id" --exit-status
```

If the workflow fails, **do not** edit the release notes. Surface the
failure and stop. The user will fix the build, re-tag (likely after
deleting the failed tag), and re-run `/release`.

## 8. Replace the release notes

Once the workflow succeeds, GitHub already has a release at `v$next` with
the workflow's basic notes. Overwrite the body with the polished version:

```sh
gh release edit "v$next" --notes-file "$notes_file"
```

Print the release URL so the user can verify:

```sh
gh release view "v$next" --json url --jq .url
```

## 9. Cleanup

Delete the temp notes file:

```sh
trash "$notes_file"
```

(Per repo convention: `trash`, not `rm`.)

# Hard rules

- **Never** auto-confirm the `Push v$next now?` prompt. The user types `y`,
  not you.
- **Never** run `git push --force`, `git reset --hard`, or
  `gh release delete` to "fix" a stuck release. If something is wrong, ask
  the user.
- **Never** edit the release notes if the build workflow failed — failed
  releases should not look polished.
- If `just ship` fails its own preconditions (dirty tree, not on `main`,
  out of sync with origin, tag exists), surface the exact error message
  and stop. Don't try to "fix" the precondition silently.
- Skip commit categories that don't matter to users (`chore`, `docs`,
  `style`, `test`, `ci`, `refactor`, `build`) even when the user asks
  what's in the release. Show them only in the *internal* draft if asked,
  never in the published release notes.
