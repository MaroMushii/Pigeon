/**
 * Snapshot format committed to MaroMushii/teleMirror#export. Mirrors our
 * Swift domain types so the Pigeon JSON decoder is a near-identity:
 *  - keys use snake_case (Pigeon's decoder configured with snake-case strategy)
 *  - dates are ISO 8601 strings
 *  - URLs are *original* (not GT-rewritten); Pigeon applies its own rewriter
 *    after decode so the on-disk artifact stays canonical
 */

export const SCHEMA_VERSION = 1 as const;

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
  subscriber_count: string | null;
}

export interface PostDTO {
  id: string;
  author_name: string;
  author_photo_url: string | null;
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
  thumbnail_url: string | null;
  duration_label: string | null;
  aspect_ratio: number | null;
}

export interface ReactionDTO {
  emoji: string;
  count: string;
}
