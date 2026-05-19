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

import { mkdirSync, readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { atomicWriteFile } from "./fs-utils.js";
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
import { sha256Hex, signAndWrite } from "./signing.js";

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

/** Write a signed JSON document: `payload` lands at `path` and its detached
 *  Ed25519 signature lands at `path + ".sig"`. When `signed` is false we
 *  skip the signature, producing output Pigeon will refuse to load (by
 *  design — only the live workflow output is meant to be consumed). */
function writeSignedJSON(path: string, payload: Buffer, signed: boolean): void {
  if (signed) {
    signAndWrite(path, payload);
  } else {
    atomicWriteFile(path, payload);
  }
}

/**
 * Bounded-concurrency worker pool. Spawns up to `concurrency` workers, each
 * draining the same FIFO queue until it's empty. Order-agnostic — callers
 * that need stable order must sort the input first.
 */
async function parallelWorkerPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>
): Promise<void> {
  const queue = [...items];
  const workerCount = Math.min(concurrency, queue.length);
  if (workerCount === 0) return;
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      let item: T | undefined;
      while ((item = queue.shift()) !== undefined) {
        await worker(item);
      }
    })
  );
}

/**
 * Read the SHA-256 of a file at `abs`, returning a 64-char lowercase hex
 * string. Returns `null` if the file is missing — the caller treats that as
 * "no integrity claim possible" and nulls out the corresponding `_path`
 * field so Pigeon doesn't try to fetch an unverifiable asset. Small media
 * files (avg ~50–200 KB) make `readFileSync` cheaper than streaming.
 */
function hashFileIfExists(abs: string): string | null {
  if (!existsSync(abs)) return null;
  return sha256Hex(readFileSync(abs));
}

/**
 * After media downloads complete, walk the snapshot and populate every
 * `_sha256` field next to a non-null `_path`. If a path's file isn't on
 * disk (download failed mid-sweep, or a retained post points at media we
 * never mirrored), null *both* the path and the hash for that reference —
 * Pigeon will then either fall back to the canonical `_url` (unverified)
 * or skip the asset entirely.
 */
function applyMediaHashes(snapshot: Snapshot, exportRoot: string): void {
  const cache = new Map<string, string | null>();
  const hashFor = (relPath: string): string | null => {
    const cached = cache.get(relPath);
    if (cached !== undefined) return cached;
    const h = hashFileIfExists(join(exportRoot, relPath));
    cache.set(relPath, h);
    return h;
  };

  // Per-field explicit assignment instead of a generic helper — TS index
  // signatures on the DTO types would force `Record<string, unknown>` casts
  // here, which loses the per-DTO field shape that catches typos at compile
  // time. The repetition is mechanical and grep-able.
  if (snapshot.channel.photo_path) {
    const h = hashFor(snapshot.channel.photo_path);
    if (h) snapshot.channel.photo_sha256 = h;
    else { snapshot.channel.photo_path = null; snapshot.channel.photo_sha256 = null; }
  }

  for (const post of snapshot.posts) {
    if (post.author_photo_path) {
      const h = hashFor(post.author_photo_path);
      if (h) post.author_photo_sha256 = h;
      else { post.author_photo_path = null; post.author_photo_sha256 = null; }
    }
    for (const m of post.media) {
      if (m.asset_path) {
        const h = hashFor(m.asset_path);
        if (h) m.asset_sha256 = h;
        else { m.asset_path = null; m.asset_sha256 = null; }
      }
      if (m.thumbnail_path) {
        const h = hashFor(m.thumbnail_path);
        if (h) m.thumbnail_sha256 = h;
        else { m.thumbnail_path = null; m.thumbnail_sha256 = null; }
      }
    }
    if (post.reply?.thumbnail_path) {
      const h = hashFor(post.reply.thumbnail_path);
      if (h) post.reply.thumbnail_sha256 = h;
      else { post.reply.thumbnail_path = null; post.reply.thumbnail_sha256 = null; }
    }
  }
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
  // Parse flags out of argv. The only supported flag right now is
  // `--unsigned`, which suppresses .sig generation for local dev runs that
  // don't have MIRROR_SIGNING_KEY in their env. CI must never pass it.
  let signed = true;
  const argv = process.argv.slice(2).filter((arg) => {
    if (arg === "--unsigned") {
      signed = false;
      return false;
    }
    return true;
  });

  const exportRoot = argv[0];
  const manifestPath = argv[1] ?? "mirror/channels.json";

  if (!exportRoot) {
    process.stderr.write(
      "usage: scrape.ts [--unsigned] <export-tree-path> [<manifest-path>]\n"
    );
    process.exit(1);
  }

  if (!signed) {
    process.stderr.write(
      "WARNING: --unsigned passed; outputs will NOT be signed. " +
        "Pigeon will refuse to load this data. Use only for local dev.\n"
    );
  }

  const manifest = parseManifest(readFileSync(manifestPath, "utf8"), manifestPath);
  const channels = manifest.channels.map((c) => c.toLowerCase()).sort();

  process.stderr.write(
    `pigeon-mirror: ${channels.length} channels, writing to ${exportRoot}\n`
  );

  const fresh = new Map<string, Snapshot>();
  const failures: HealthFailure[] = [];

  await parallelWorkerPool(channels, CHANNEL_CONCURRENCY, async (username) => {
    try {
      const result = await scrapeChannel(username, exportRoot, signed);
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
  });

  rebuildIndex(exportRoot, channels, fresh, signed);
  writeHealth(exportRoot, fresh.size, failures);
}

async function scrapeChannel(
  username: string,
  exportRoot: string,
  signed: boolean
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

  mkdirSync(dirname(snapPath), { recursive: true });

  // Mirror referenced media with bounded concurrency (different CDN hosts;
  // politeness matters less than to t.me itself, but keep sockets modest).
  // Order matters: images must be on disk before we serialize the snapshot
  // so `applyMediaHashes` can stamp each `_sha256` field from the actual
  // bytes. The signed snapshot then transitively covers every image it
  // references — Pigeon refuses to load any image whose hash doesn't match.
  const refs = collectMediaRefs(snapshot);
  let imagesWritten = 0;
  let imagesSkipped = 0;

  await parallelWorkerPool([...refs.entries()], IMAGE_CONCURRENCY, async ([path, canonical]) => {
    const abs = join(exportRoot, path);
    if (existsSync(abs)) {
      imagesSkipped++;
      return;
    }
    try {
      await downloadTo(canonical, abs);
      imagesWritten++;
    } catch (e) {
      process.stderr.write(
        `    media ${path} failed — ${(e as Error).message}\n`
      );
    }
  });

  applyMediaHashes(snapshot, exportRoot);

  const payload = Buffer.from(JSON.stringify(snapshot, null, 2) + "\n");
  writeSignedJSON(snapPath, payload, signed);

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
  freshlyScraped: Map<string, Snapshot>,
  signed: boolean
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
  writeSignedJSON(indexPath, Buffer.from(JSON.stringify(doc, null, 2) + "\n"), signed);
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
