/**
 * Maps a canonical Telegram CDN URL to a deterministic, repo-relative
 * path under `channels/<username>/media/<hash>.<ext>`.
 *
 * The hash is derived from the full canonical URL (including any query
 * string), so the same image referenced from multiple posts resolves to
 * the same on-disk path — meaning we write it to the export branch
 * exactly once, regardless of how often the channel cites it.
 */

import { createHash } from "node:crypto";

const ALLOWED_EXTS = new Set(["jpg", "jpeg", "png", "webp", "gif"]);
const HASH_LEN = 24; // hex chars; 96 bits of entropy is plenty for our scale

export interface MediaPath {
  /** repo-relative path: `channels/<u>/media/<hash>.<ext>` */
  path: string;
  /** filename only: `<hash>.<ext>` */
  filename: string;
  /** lowercased extension w/o dot */
  ext: string;
}

export function pathForCanonicalURL(
  canonicalURL: string,
  channelUsername: string
): MediaPath {
  const ext = guessExtension(canonicalURL);
  const hash = sha256Hex(canonicalURL);
  const filename = `${hash.slice(0, HASH_LEN)}.${ext}`;
  return {
    path: `channels/${channelUsername.toLowerCase()}/media/${filename}`,
    filename,
    ext,
  };
}

function guessExtension(url: string): string {
  const u = url.toLowerCase();
  // Strip query string + fragment.
  const clean = u.split("?")[0]!.split("#")[0]!;
  const dotIdx = clean.lastIndexOf(".");
  if (dotIdx === -1) return "jpg";
  const tail = clean.slice(dotIdx + 1);
  if (ALLOWED_EXTS.has(tail)) return tail === "jpeg" ? "jpg" : tail;
  return "jpg";
}

function sha256Hex(input: string): string {
  return createHash("sha256").update(input, "utf8").digest("hex");
}
