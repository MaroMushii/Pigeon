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

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseChannelPage } from "./parser.js";
import type { IndexDoc, IndexEntry, Snapshot } from "./schema.js";
import { SCHEMA_VERSION } from "./schema.js";

interface ChannelsManifest {
  schema: number;
  channels: string[];
}

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

async function main(): Promise<void> {
  const exportRoot = process.argv[2];
  const manifestPath = process.argv[3] ?? "mirror/channels.json";

  if (!exportRoot) {
    process.stderr.write(
      "usage: scrape.ts <export-tree-path> [<manifest-path>]\n"
    );
    process.exit(1);
  }

  const manifest = JSON.parse(
    readFileSync(manifestPath, "utf8")
  ) as ChannelsManifest;
  const channels = manifest.channels.map((c) => c.toLowerCase()).sort();

  process.stderr.write(
    `pigeon-mirror: ${channels.length} channels, writing to ${exportRoot}\n`
  );

  const fresh = new Map<string, Snapshot>();

  for (const username of channels) {
    try {
      const result = await scrapeChannel(username, exportRoot);
      fresh.set(username, result.snapshot);
      process.stderr.write(
        `  ${username.padEnd(20)} ${result.snapshot.posts.length} posts, ` +
          `${result.imagesWritten} new images, ${result.imagesSkipped} cached\n`
      );
      if (looksLikeDeadHandle(result.snapshot, username)) {
        process.stderr.write(
          `  ${"".padEnd(20)} WARN ${username} appears unresolved on Telegram ` +
            `(no title, no subscribers, no posts) — handle may have been ` +
            `renamed, deleted, or banned. Verify and update channels.json.\n`
        );
      }
      // Be polite to t.me — we share an IP with whoever else is on this
      // GH runner, and Telegram throttles aggressive scrapers.
      await sleep(750 + Math.floor(Math.random() * 750));
    } catch (e) {
      process.stderr.write(`  ${username}: failed — ${(e as Error).message}\n`);
    }
  }

  rebuildIndex(exportRoot, channels, fresh);
}

async function scrapeChannel(
  username: string,
  exportRoot: string
): Promise<{ snapshot: Snapshot; imagesWritten: number; imagesSkipped: number }> {
  const url = `https://t.me/s/${encodeURIComponent(username)}`;
  const res = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "en-US,en;q=0.9",
    },
  });
  if (!res.ok) throw new Error(`t.me ${username}: HTTP ${res.status}`);

  const html = await res.text();
  const snapshot = parseChannelPage(html, username);

  // Write the snapshot first so a partial image-mirror failure doesn't
  // lose the textual update.
  const snapPath = join(
    exportRoot,
    `channels/${username}/snapshot.json`
  );
  mkdirSync(dirname(snapPath), { recursive: true });
  writeFileSync(snapPath, JSON.stringify(snapshot, null, 2) + "\n");

  // Mirror referenced media in parallel (different CDN hosts; politeness
  // matters less than to t.me itself).
  const refs = collectMediaRefs(snapshot);
  let imagesWritten = 0;
  let imagesSkipped = 0;
  await Promise.all(
    [...refs.entries()].map(async ([path, canonical]) => {
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
    })
  );

  return { snapshot, imagesWritten, imagesSkipped };
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
  }
  return refs;
}

async function downloadTo(url: string, destination: string): Promise<void> {
  const res = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "image/webp,image/avif,image/png,image/jpeg,*/*;q=0.8",
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, buf);
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
        } catch {
          // skip — leave it out of the index
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
  writeFileSync(indexPath, JSON.stringify(doc, null, 2) + "\n");
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
 * t.me serves a 200 OK splash for any /<username> — including ones that don't
 * resolve to a real channel. The parser falls back to the raw username for
 * the title in that case, and finds no subscriber count or posts. This trio
 * together is a strong signal the handle is dead (renamed/deleted/banned),
 * not just a quiet channel: a real channel always has at least a title and
 * a member count, even with zero posts.
 */
function looksLikeDeadHandle(snap: Snapshot, username: string): boolean {
  return (
    snap.channel.title.toLowerCase() === username.toLowerCase() &&
    snap.channel.subscriber_count === null &&
    snap.posts.length === 0
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((e) => {
  process.stderr.write(`scrape failed: ${e?.stack ?? e}\n`);
  process.exit(1);
});
