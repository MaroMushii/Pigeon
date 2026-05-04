/**
 * Pigeon's mirror Worker.
 *
 * Cron handler:
 *   1. Reads channels.json from main (source of truth for what to mirror).
 *   2. Picks a rotating shard of channels (so we stay within Workers'
 *      50-subrequest-per-invocation cap on the free plan).
 *   3. For each channel, fetches t.me/s/<channel>, parses the HTML into
 *      our `Snapshot` schema, hashes it, and skips the commit if the
 *      content hasn't changed since last run.
 *   4. Otherwise commits the new snapshot to `<branch>/export/<username>.json`
 *      via the GitHub Contents API.
 *
 * HTTP handler (mostly for sanity testing):
 *   GET /healthz       → "ok"
 *   GET /scrape/<u>    → run a single scrape inline, return the snapshot
 *                         (requires `X-Token` matching GITHUB_TOKEN)
 */

import { parseChannelPage } from "./parser.js";
import {
  fetchFile,
  fetchRawFile,
  putFile,
  sha256Hex,
  type RepoCoords,
} from "./github.js";

interface Env {
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  GITHUB_BRANCH: string;
  GITHUB_CHANNELS_PATH: string;
  MAX_CHANNELS_PER_TICK: string;
  SCHEMA_VERSION: string;
}

interface ChannelsManifest {
  schema: number;
  channels: string[];
}

export default {
  async scheduled(
    event: ScheduledController,
    env: Env,
    ctx: ExecutionContext
  ): Promise<void> {
    ctx.waitUntil(runScrape(event.scheduledTime, env));
  },

  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/healthz") {
      return new Response("ok\n", { headers: { "Content-Type": "text/plain" } });
    }
    if (url.pathname.startsWith("/scrape/")) {
      if (req.headers.get("X-Token") !== env.GITHUB_TOKEN) {
        return new Response("unauthorized\n", { status: 401 });
      }
      const username = url.pathname.slice("/scrape/".length);
      try {
        const snap = await scrapeOne(username);
        return new Response(JSON.stringify(snap, null, 2), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (e) {
        return new Response(`scrape failed: ${(e as Error).message}\n`, {
          status: 500,
        });
      }
    }
    return new Response("pigeon-mirror\n", {
      headers: { "Content-Type": "text/plain" },
    });
  },
};

async function runScrape(tickEpoch: number, env: Env): Promise<void> {
  const coords: RepoCoords = {
    owner: env.GITHUB_OWNER,
    repo: env.GITHUB_REPO,
    branch: env.GITHUB_BRANCH,
    token: env.GITHUB_TOKEN,
  };
  const mainCoords: RepoCoords = { ...coords, branch: "main" };

  const manifestText = await fetchRawFile(mainCoords, env.GITHUB_CHANNELS_PATH);
  if (!manifestText) {
    console.error(`channels manifest not found at ${env.GITHUB_CHANNELS_PATH}`);
    return;
  }
  const manifest = JSON.parse(manifestText) as ChannelsManifest;
  const all = manifest.channels.map((c) => c.toLowerCase()).sort();

  const tickSize = Math.max(1, parseInt(env.MAX_CHANNELS_PER_TICK, 10) || 16);
  const shard = pickShard(all, tickSize, tickEpoch);

  console.log(
    `pigeon-mirror tick ${new Date(tickEpoch).toISOString()}: ${shard.length}/${all.length} channels`
  );

  // Process channels sequentially with a small jitter sleep — t.me is rate-
  // limited and CF Workers share egress IPs so back-to-back hammering is
  // counterproductive even though we have many edge IPs in aggregate.
  for (const username of shard) {
    try {
      await scrapeAndCommit(username, coords, env);
      await sleep(750 + Math.floor(Math.random() * 750));
    } catch (e) {
      console.error(`failed for ${username}: ${(e as Error).message}`);
    }
  }
}

async function scrapeAndCommit(
  username: string,
  coords: RepoCoords,
  env: Env
): Promise<void> {
  const snapshot = await scrapeOne(username);
  // Strip the `fetched_at` field from the hash so a no-op scrape (same
  // posts, just a different timestamp) doesn't churn the export branch.
  const stable = JSON.stringify({ ...snapshot, fetched_at: "" });
  const newHash = await sha256Hex(stable);

  // Snapshots live at the root of the export branch — that branch is
  // dedicated to mirror data, no sub-directory needed.
  const path = `${username}.json`;
  const existing = await fetchFile(coords, path);

  if (existing) {
    // Compare hashes by reconstructing the same stable form from the
    // existing committed file.
    try {
      const existingJSON = JSON.parse(b64decode(existing.contentBase64));
      const existingStable = JSON.stringify({ ...existingJSON, fetched_at: "" });
      const existingHash = await sha256Hex(existingStable);
      if (existingHash === newHash) {
        console.log(`${username}: unchanged, skipping commit`);
        return;
      }
    } catch {
      // fall through and overwrite
    }
  }

  const body = JSON.stringify(snapshot, null, 2) + "\n";
  await putFile(
    coords,
    path,
    body,
    `mirror: update ${username}`,
    existing?.sha
  );
  console.log(`${username}: committed ${snapshot.posts.length} posts`);
}

async function scrapeOne(username: string) {
  const u = username.trim().toLowerCase();
  const url = `https://t.me/s/${encodeURIComponent(u)}`;
  const res = await fetch(url, {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
      Accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "en-US,en;q=0.9",
    },
  });
  if (!res.ok) {
    throw new Error(`t.me ${u}: HTTP ${res.status}`);
  }
  const html = await res.text();
  return parseChannelPage(html, u);
}

/**
 * Deterministic rotating window. We slice `all` starting at an offset
 * derived from the tick number so every full pass covers every channel.
 *   tick 0:  channels[0..tickSize]
 *   tick 1:  channels[tickSize..2*tickSize]
 *   tick N:  wraps modulo all.length
 */
function pickShard(all: string[], tickSize: number, tickEpoch: number): string[] {
  if (all.length <= tickSize) return all;
  const tick = Math.floor(tickEpoch / (2 * 60 * 1000));
  const start = (tick * tickSize) % all.length;
  if (start + tickSize <= all.length) {
    return all.slice(start, start + tickSize);
  }
  return [...all.slice(start), ...all.slice(0, (start + tickSize) % all.length)];
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function b64decode(b64: string): string {
  // atob returns binary string; convert via TextDecoder to get UTF-8.
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder("utf-8").decode(bytes);
}
