/**
 * Pigeon's mirror scraper. Runs in Node from a GitHub Actions runner;
 * the workflow handles git ops (commit + push). This script only writes
 * files into a working tree — it never talks to the GitHub API.
 *
 * Usage:
 *   pnpm exec tsx mirror/scrape.ts <export-tree-path> [<manifest-path>]
 *
 * <export-tree-path>  filesystem path to a checkout of the `export` branch
 *                     (the workflow makes one via actions/checkout)
 * <manifest-path>     defaults to ./mirror/channels.json (read from main)
 *
 * For each channel in the manifest:
 *   - GET t.me/s/<channel>, parse to a Snapshot
 *   - write channels/<u>/snapshot.json into the export tree
 *   - download referenced images, write to channels/<u>/media/<hash>.<ext>
 *     (skipped if the file already exists — Telegram CDN URLs are
 *     immutable per upload, so existing-by-name = same content)
 *
 * After all channels, rewrite index.json at the export tree root.
 */

import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseChannelPage } from "./parser.js";
import type {
  HealthDoc,
  HealthFailure,
  IndexDoc,
  IndexEntry,
  PostDTO,
  Snapshot,
} from "./schema.js";
import { SCHEMA_VERSION } from "./schema.js";

interface ChannelsManifest {
  schema: number;
  channels: string[];
}

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

/** Max channels scraped in parallel. Polite to t.me; each worker still
 *  sleeps 750–1500ms after its channel fetch. */
const CHANNEL_CONCURRENCY = 3;

/** Max simultaneous image downloads per channel sweep. CDN hosts tolerate
 *  more parallelism than t.me itself, but keep it modest so we don't
 *  exhaust sockets on the runner. */
const IMAGE_CONCURRENCY = 8;

/** Write content atomically: write to a .tmp sibling then rename into place
 *  so a mid-write SIGTERM can't leave a truncated file. */
function atomicWriteFile(path: string, content: string | Buffer): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}

/**
 * Per-channel retention cap. t.me/s/<u> only ever returns the most recent
 * ~20 posts, so we merge each fresh fetch into the on-disk snapshot to
 * give Pigeon meaningful scroll-back. 100 is a few weeks of history on
 * busy channels and several months on quieter ones, while keeping JSON
 * payloads small enough that git deltas stay cheap and Pigeon's mount
 * pipeline (off-main body parse + brief spinner) doesn't need redesign.
 */
const RETAIN_LIMIT = 100;

async function main(): Promise<void> {
  const exportRoot = process.argv[2];
  const manifestPath = process.argv[3] ?? "mirror/channels.json";

  if (!exportRoot) {
    process.stderr.write(
      "usage: scrape.ts <export-tree-path> [<manifest-path>]\n"
    );
    process.exit(1);
  }

  const manifest = parseManifest(readFileSync(manifestPath, "utf8"), manifestPath);
  const channels = manifest.channels.map((c) => c.toLowerCase()).sort();

  process.stderr.write(
    `pigeon-mirror: ${channels.length} channels, writing to ${exportRoot}\n`
  );

  const fresh = new Map<string, Snapshot>();
  const failures: HealthFailure[] = [];
  const queue = [...channels];

  await Promise.all(
    Array.from({ length: Math.min(CHANNEL_CONCURRENCY, channels.length) }, async () => {
      let username: string | undefined;
      while ((username = queue.shift()) !== undefined) {
        try {
          const result = await scrapeChannel(username, exportRoot);
          fresh.set(username, result.snapshot);
          process.stderr.write(
            `  ${username.padEnd(20)} ${result.snapshot.posts.length} posts ` +
              `(+${result.freshPostCount} fresh), ` +
              `${result.imagesWritten} new images, ${result.imagesSkipped} cached\n`
          );
          if (looksLikeDeadHandle(result.snapshot.channel, result.freshPostCount, username)) {
            process.stderr.write(
              `  ${"".padEnd(20)} WARN ${username} appears unresolved on Telegram ` +
                `(no title, no subscribers, no posts) — handle may have been ` +
                `renamed, deleted, or banned. Verify and update channels.json.\n`
            );
          }
          // Be polite to t.me — each worker sleeps between its own fetches.
          await sleep(750 + Math.floor(Math.random() * 750));
        } catch (e) {
          const message = (e as Error).message;
          process.stderr.write(`  ${username}: failed — ${message}\n`);
          failures.push({ username, error: message });
        }
      }
    })
  );

  rebuildIndex(exportRoot, channels, fresh);
  writeHealth(exportRoot, fresh.size, failures);
}

async function scrapeChannel(
  username: string,
  exportRoot: string
): Promise<{
  snapshot: Snapshot;
  freshPostCount: number;
  imagesWritten: number;
  imagesSkipped: number;
}> {
  const url = `https://t.me/s/${encodeURIComponent(username)}`;
  const res = await fetch(url, {
    signal: AbortSignal.timeout(15_000),
    headers: {
      "User-Agent": USER_AGENT,
      Accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "en-US,en;q=0.9",
    },
  });
  if (!res.ok) throw new Error(`t.me ${username}: HTTP ${res.status}`);

  const html = await res.text();
  const fresh = parseChannelPage(html, username);

  const snapPath = join(
    exportRoot,
    `channels/${username}/snapshot.json`
  );

  // Merge fresh posts into whatever is already on disk so we retain
  // history beyond t.me's 20-post window. Channel info always comes
  // from the fresh fetch — only posts[] carries forward.
  const snapshot: Snapshot = {
    ...fresh,
    posts: mergePosts(loadExistingPosts(snapPath), fresh.posts),
  };

  // Write the snapshot first so a partial image-mirror failure doesn't
  // lose the textual update.
  mkdirSync(dirname(snapPath), { recursive: true });
  atomicWriteFile(snapPath, JSON.stringify(snapshot, null, 2) + "\n");

  // Mirror referenced media with bounded concurrency (different CDN hosts;
  // politeness matters less than to t.me itself, but keep sockets modest).
  const refs = collectMediaRefs(snapshot);
  let imagesWritten = 0;
  let imagesSkipped = 0;
  const imageQueue = [...refs.entries()];

  await Promise.all(
    Array.from({ length: Math.min(IMAGE_CONCURRENCY, imageQueue.length) }, async () => {
      let entry: [string, string] | undefined;
      while ((entry = imageQueue.shift()) !== undefined) {
        const [path, canonical] = entry;
        const abs = join(exportRoot, path);
        if (existsSync(abs)) {
          imagesSkipped++;
          continue;
        }
        try {
          await downloadTo(canonical, abs);
          imagesWritten++;
        } catch (e) {
          process.stderr.write(
            `    media ${path} failed — ${(e as Error).message}\n`
          );
        }
      }
    })
  );

  return {
    snapshot,
    freshPostCount: fresh.posts.length,
    imagesWritten,
    imagesSkipped,
  };
}

function collectMediaRefs(snapshot: Snapshot): Map<string, string> {
  const refs = new Map<string, string>();
  const consider = (url: string | null, path: string | null): void => {
    if (!url || !path) return;
    if (!refs.has(path)) refs.set(path, url);
  };
  consider(snapshot.channel.photo_url, snapshot.channel.photo_path);
  for (const p of snapshot.posts) {
    consider(p.author_photo_url, p.author_photo_path);
    for (const m of p.media) {
      consider(m.asset_url, m.asset_path);
      consider(m.thumbnail_url, m.thumbnail_path);
    }
    if (p.reply) {
      consider(p.reply.thumbnail_url, p.reply.thumbnail_path);
    }
  }
  return refs;
}

async function downloadTo(url: string, destination: string): Promise<void> {
  const res = await fetch(url, {
    signal: AbortSignal.timeout(15_000),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "image/webp,image/avif,image/png,image/jpeg,*/*;q=0.8",
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  mkdirSync(dirname(destination), { recursive: true });
  atomicWriteFile(destination, buf);
}

function rebuildIndex(
  exportRoot: string,
  channels: string[],
  freshlyScraped: Map<string, Snapshot>
): void {
  const entries: IndexEntry[] = [];

  for (const username of channels) {
    let snap: Snapshot | null = freshlyScraped.get(username) ?? null;

    // Fall back to whatever snapshot is already on disk so the index
    // includes channels we didn't re-scrape on this run.
    if (!snap) {
      const path = join(exportRoot, `channels/${username}/snapshot.json`);
      if (existsSync(path)) {
        try {
          snap = JSON.parse(readFileSync(path, "utf8")) as Snapshot;
        } catch (e) {
          process.stderr.write(
            `  index: skipping ${username} — corrupt snapshot.json (${(e as Error).message})\n`
          );
        }
      }
    }

    if (!snap) continue;

    entries.push({
      username,
      title: snap.channel.title,
      last_fetched_at: snap.fetched_at,
      post_count: snap.posts.length,
      media_count: countMedia(snap),
      snapshot_path: `channels/${username}/snapshot.json`,
    });
  }

  const doc: IndexDoc = {
    schema: SCHEMA_VERSION,
    generated_at: new Date().toISOString(),
    channels: entries,
  };

  const indexPath = join(exportRoot, "index.json");
  atomicWriteFile(indexPath, JSON.stringify(doc, null, 2) + "\n");
  process.stderr.write(
    `index: ${entries.length} channels @ ${doc.generated_at}\n`
  );
}

function countMedia(snap: Snapshot): number {
  let n = 0;
  for (const p of snap.posts) n += p.media.length;
  return n;
}

/**
 * Persist sweep outcomes to `health.json` at the export tree root. Always
 * written, even on a fully-failed sweep — a stale `health.json` would be
 * worse than an honest one announcing widespread failure.
 *
 * `succeeded` is the count of channels that wrote a fresh snapshot this
 * run; channels we didn't touch (e.g. removed from the manifest) are not
 * counted on either side. `failures` carries one entry per thrown error
 * inside the per-channel loop.
 */
function writeHealth(
  exportRoot: string,
  succeeded: number,
  failed: HealthFailure[]
): void {
  const doc: HealthDoc = {
    schema: SCHEMA_VERSION,
    generated_at: new Date().toISOString(),
    succeeded,
    failed,
  };
  const path = join(exportRoot, "health.json");
  atomicWriteFile(path, JSON.stringify(doc, null, 2) + "\n");
  process.stderr.write(
    `health: ${succeeded} ok, ${failed.length} failed @ ${doc.generated_at}\n`
  );
}

/**
 * t.me serves a 200 OK splash for any /<username> — including ones that don't
 * resolve to a real channel. The parser falls back to the raw username for
 * the title in that case, and finds no subscriber count or posts. This trio
 * together is a strong signal the handle is dead (renamed/deleted/banned),
 * not just a quiet channel: a real channel always has at least a title and
 * a member count, even with zero posts.
 *
 * Checks the *fresh* post count, not the merged snapshot — retained posts
 * from earlier scrapes would otherwise mask a handle that's just gone dead.
 */
function looksLikeDeadHandle(
  channel: { title: string; subscriber_count: string | null },
  freshPostCount: number,
  username: string
): boolean {
  return (
    channel.title.toLowerCase() === username.toLowerCase() &&
    channel.subscriber_count === null &&
    freshPostCount === 0
  );
}

/**
 * Read the on-disk snapshot for a channel and return its posts. A missing
 * file is fine (first sweep ever for this channel) and returns []. A
 * *corrupt* file throws — never silently — because the merge step that
 * follows treats [] as "nothing to retain" and would overwrite the bad
 * file with a fresh-only snapshot, destroying every retained post. The
 * caller surfaces the throw as a per-channel failure and skips the write.
 */
function loadExistingPosts(snapPath: string): PostDTO[] {
  if (!existsSync(snapPath)) return [];
  const raw = JSON.parse(readFileSync(snapPath, "utf8")) as Snapshot;
  if (!Array.isArray(raw.posts)) {
    throw new Error(
      `snapshot.json at ${snapPath} is missing posts[] — refusing to overwrite with fresh-only`
    );
  }
  return raw.posts;
}

/**
 * Validate the manifest's shape before treating it as a `ChannelsManifest`.
 * A malformed manifest would otherwise crash the whole sweep with a cryptic
 * TypeError deep inside the worker pool. Catching it here lets us exit with
 * a clear message and a non-zero status so the workflow turns red.
 */
function parseManifest(raw: string, path: string): ChannelsManifest {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new Error(`${path}: not valid JSON — ${(e as Error).message}`);
  }
  if (!parsed || typeof parsed !== "object") {
    throw new Error(`${path}: expected a JSON object`);
  }
  const obj = parsed as Record<string, unknown>;
  if (typeof obj.schema !== "number") {
    throw new Error(`${path}: missing or non-numeric "schema"`);
  }
  if (!Array.isArray(obj.channels) || !obj.channels.every((c) => typeof c === "string")) {
    throw new Error(`${path}: "channels" must be an array of strings`);
  }
  return { schema: obj.schema, channels: obj.channels };
}

/**
 * Merge `previous` and `fresh` keyed by post id (latest-wins on edits and
 * reaction-count updates), sort newest-first, cap at RETAIN_LIMIT. Posts
 * that exist on disk but not in `fresh` are retained — that's the whole
 * point. A side-effect is that posts deleted upstream live in the mirror
 * until they age past the cap, which is a deliberate editorial choice.
 */
function mergePosts(previous: PostDTO[], fresh: PostDTO[]): PostDTO[] {
  const byId = new Map<string, PostDTO>();
  for (const p of previous) byId.set(p.id, p);
  for (const p of fresh) byId.set(p.id, p);
  const all = [...byId.values()];
  all.sort(comparePostsDesc);
  return all.slice(0, RETAIN_LIMIT);
}

/**
 * Sort by `posted_at` desc; fall back to numeric msgId tail of post id
 * (`<channel>/<msgId>`) when posted_at is missing or unparseable. msgIds
 * are monotonic within a channel so they're a reliable secondary key.
 */
function comparePostsDesc(a: PostDTO, b: PostDTO): number {
  const aT = parseTimestamp(a.posted_at);
  const bT = parseTimestamp(b.posted_at);
  if (Number.isFinite(aT) && Number.isFinite(bT)) return bT - aT;
  return msgIdFromPostId(b.id) - msgIdFromPostId(a.id);
}

function parseTimestamp(value: string | null): number {
  if (!value) return NaN;
  const t = Date.parse(value);
  return Number.isFinite(t) ? t : NaN;
}

function msgIdFromPostId(id: string): number {
  const tail = id.split("/").pop();
  const n = tail ? parseInt(tail, 10) : NaN;
  return Number.isFinite(n) ? n : 0;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((e) => {
  process.stderr.write(`scrape failed: ${e?.stack ?? e}\n`);
  process.exit(1);
});
