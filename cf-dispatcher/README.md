# pigeon-mirror-dispatcher

Cloudflare Worker that fires every 5 minutes and pings GitHub's
`workflow_dispatch` endpoint to kick the `mirror.yml` workflow. Exists
because GitHub Actions' free-tier scheduled-workflow priority is
unreliable — measured firings on this repo are ~6% of the configured
rate (median gap 42 min on a `*/5` schedule).

CF Workers' cron triggers fire to within seconds of the slot, so this
Worker becomes the **floor** for mirror freshness. Any GH-side scheduled
run that happens to slip through is bonus.

## What it is *not*

- Not a Telegram scraper. The Worker does **one HTTP POST per invocation**
  and exits. No image processing, no HTML parsing, no git operations.
  CPU per tick is well under the 1ms range — the free-plan 10ms cap that
  killed the earlier data-plane Worker is not in play here.
- Not a substitute for `mirror.yml`. The workflow still does all the
  work; this Worker only triggers it.

## One-time setup

```sh
cd cf-dispatcher
pnpm install
pnpm exec wrangler login   # opens browser, authorises wrangler
```

Mint a fine-grained GitHub PAT:

- <https://github.com/settings/personal-access-tokens/new>
- Repository access → "Only select repositories" → `MaroMushii/Pigeon`
- Permissions → **Actions: Read and write** (nothing else)
- Expiration: 1 year is fine; CF will surface the eventual 401 in logs

Hand the PAT to the Worker via wrangler's interactive prompt — it never
touches a file or a chat transcript:

```sh
pnpm exec wrangler secret put GITHUB_TOKEN
# paste the token at the prompt, hit enter
```

Deploy:

```sh
pnpm exec wrangler deploy
```

After deploy, CF runs `scheduled()` on the configured cron (`*/5`)
without further action. Verify:

```sh
pnpm exec wrangler tail
# or watch from the GitHub side:
gh run list --repo MaroMushii/Pigeon --workflow mirror.yml --limit 10
# look for `event: workflow_dispatch` lines firing every 5 min
```

## Routine ops

- **Rotating the PAT** — `pnpm exec wrangler secret put GITHUB_TOKEN`
  again and paste the new value. The Worker picks it up on the next
  scheduled tick; no redeploy needed.
- **Pausing dispatches** — `pnpm exec wrangler delete` removes the
  Worker entirely. The mirror falls back to GH's own cron schedule
  (lagged but functional). Re-deploy with `pnpm exec wrangler deploy`
  when ready.
- **Tailing logs** — `pnpm exec wrangler tail` streams `console.log` and
  uncaught errors. Look for the `dispatched mirror.yml on
  <MaroMushii/Pigeon@main>` line every 5 min.

## Failure modes worth knowing

- **401 on dispatch** → PAT expired or revoked. Mint a new one, re-run
  `wrangler secret put GITHUB_TOKEN`. The Worker will throw and surface
  in CF's error metrics + logs.
- **404 on dispatch** → workflow file renamed or moved. Update the
  `WORKFLOW` constant in `src/worker.ts` and redeploy.
- **422 on dispatch** → ref no longer exists. Update the `REF` constant
  if `main` was renamed.
- **CF outage** → mirror falls back to GH's lagged cron. Acceptable —
  the staleness footer in the macOS app surfaces the lag to users.
