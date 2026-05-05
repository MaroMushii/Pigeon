/**
 * Snapshot format committed to MaroMushii/Pigeon#export. Mirrors our
 * Swift domain types so the Pigeon JSON decoder is a near-identity:
 *  - keys use snake_case (Pigeon's decoder maps explicitly via CodingKeys)
 *  - dates are ISO 8601 strings
 *  - URLs come in two shapes:
 *      `asset_url`  — canonical Telegram CDN URL, kept for fallback
 *      `asset_path` — relative path under the export branch root
 *                     (e.g. `channels/durov/media/<hash>.jpg`).
 *                     Pigeon prefers this; image bytes live at
 *                     raw.githubusercontent.com/.../<asset_path>.
 *
 * v2 (current): introduces asset_path/thumbnail_path, scopes media under
 *               channels/<u>/media/, ships a top-level index.json.
 * v1 (legacy):  flat <username>.json at branch root, no media in repo.
 */

export const SCHEMA_VERSION = 2 as const;

export interface Snapshot {
  schema: typeof SCHEMA_VERSION;
  fetched_at: string;
  channel: ChannelInfo;
  posts: PostDTO[];
}

export interface ChannelInfo {
  username: string;
  title: string;
  description_html: string | null;
  photo_url: string | null;
  photo_path: string | null;
  subscriber_count: string | null;
}

export interface PostDTO {
  id: string;
  author_name: string;
  author_photo_url: string | null;
  author_photo_path: string | null;
  body_html: string;
  plain_text: string;
  media: MediaDTO[];
  reactions: ReactionDTO[];
  views_label: string | null;
  posted_at: string | null;
  edited: boolean;
  permalink: string;
}

export type MediaKind = "photo" | "video" | "unknown";

export interface MediaDTO {
  kind: MediaKind;
  asset_url: string | null;
  asset_path: string | null;
  thumbnail_url: string | null;
  thumbnail_path: string | null;
  duration_label: string | null;
  aspect_ratio: number | null;
}

export interface ReactionDTO {
  emoji: string;
  count: string;
}

/** Top-level discovery document at `index.json`. */
export interface IndexDoc {
  schema: typeof SCHEMA_VERSION;
  generated_at: string;
  channels: IndexEntry[];
}

export interface IndexEntry {
  username: string;
  title: string;
  last_fetched_at: string;
  post_count: number;
  media_count: number;
  snapshot_path: string; // "channels/<u>/snapshot.json"
}
