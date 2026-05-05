# pigeon-mirror

Pigeon's Cloudflare Worker. Scrapes Telegram channels from outside Iran and
commits JSON snapshots to `MaroMushii/Pigeon#export` so the Pigeon app can
read them via `raw.githubusercontent.com` (which isn't DNS-poisoned in Iran
the way `t.me` and `*.translate.goog` are).

## Setup

1. **Install deps**
   ```
   pnpm install
   ```

2. **Authenticate wrangler**
   ```
   pnpm exec wrangler login
   ```

3. **Generate a fine-grained GitHub PAT**
   At <https://github.com/settings/personal-access-tokens/new>:
   - Resource owner: `MaroMushii`
   - Repository access: only `MaroMushii/Pigeon`
   - Permissions → Repository → **Contents: Read and write**
   - Expiry: 1 year (renew before it dies)

4. **Drop the PAT into the Worker as a secret**
   ```
   pnpm exec wrangler secret put GITHUB_TOKEN
   ```

5. **Create the `export` branch on GitHub**
   ```
   git switch --orphan export
   git commit --allow-empty -m "init export branch"
   git push origin export
   git switch -
   ```

6. **Deploy**
   ```
   pnpm deploy
   ```

7. **Tail logs**
   ```
   pnpm tail
   ```

## Adding channels

Edit `channels.json` on `main` and PR. The Worker re-reads the manifest on
every cron tick, so new channels appear in the next sweep.

## Cron schedule

`*/2 * * * *` — every two minutes. Each invocation processes a rotating
shard of up to `MAX_CHANNELS_PER_TICK` (default 16) channels. With the
default settings, a full pass over a list of 100 channels takes ~13 minutes.

## Endpoints

- `GET /healthz` — liveness check.
- `GET /scrape/<username>` — trigger a one-shot scrape and return the
  parsed JSON. Requires `X-Token: <GITHUB_TOKEN>`. Used for debugging.
