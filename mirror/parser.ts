/**
 * Parses the t.me/s/<channel> HTML payload into a `Snapshot`.
 * Selectors mirror Telegram's public widget DOM and match the Swift
 * `HTMLPostParser` so both producers and consumers stay in lock-step.
 *
 * Sync end-to-end: Node's `createHash` doesn't return a promise, unlike
 * the Web Crypto API the Worker version had to deal with.
 */

import * as cheerio from "cheerio";
import type {
  ChannelInfo,
  MediaDTO,
  MediaKind,
  PostDTO,
  ReactionDTO,
  Snapshot,
} from "./schema.js";
import { SCHEMA_VERSION } from "./schema.js";
import { pathForCanonicalURL } from "./media-paths.js";

export function parseChannelPage(
  html: string,
  fallbackUsername: string
): Snapshot {
  const $ = cheerio.load(html);

  const username =
    strip($(".tgme_channel_info_header_username a").first().text())
      .replace(/^@/, "")
      .toLowerCase() || fallbackUsername.toLowerCase();

  const photoUrl = nullIfEmpty(
    $(".tgme_channel_info_header img").first().attr("src") ??
      $(".tgme_page_photo_image img").first().attr("src") ??
      ""
  );

  const channel: ChannelInfo = {
    username,
    title:
      strip($(".tgme_channel_info_header_title span").first().text()) ||
      fallbackUsername,
    description_html: nullIfEmpty(
      $(".tgme_channel_info_description").first().html() ?? ""
    ),
    photo_url: photoUrl,
    photo_path: photoUrl ? pathForCanonicalURL(photoUrl, username).path : null,
    subscriber_count: nullIfEmpty(
      strip($(".tgme_channel_info_counter .counter_value").first().text())
    ),
  };

  const posts: PostDTO[] = [];
  $(".tgme_widget_message_wrap").each((_, el) => {
    const post = parsePost($, $(el), username);
    if (post) posts.push(post);
  });

  return {
    schema: SCHEMA_VERSION,
    fetched_at: new Date().toISOString(),
    channel,
    posts,
  };
}

function parsePost(
  $: cheerio.CheerioAPI,
  wrap: cheerio.Cheerio<any>,
  channelUsername: string
): PostDTO | null {
  const messageEl = wrap.find(".tgme_widget_message").first();
  const dataPost = messageEl.attr("data-post") ?? "";
  if (!dataPost) return null;

  const author =
    strip(wrap.find(".tgme_widget_message_owner_name span").first().text()) ||
    strip(wrap.find(".tgme_widget_message_owner_name").first().text());

  const authorPhoto = nullIfEmpty(
    wrap.find(".tgme_widget_message_user_photo img").first().attr("src") ?? ""
  );
  const authorPhotoPath = authorPhoto
    ? pathForCanonicalURL(authorPhoto, channelUsername).path
    : null;

  const textEl = wrap.find(".tgme_widget_message_text").first();
  const bodyHTML = textEl.html() ?? "";
  // Extract plain text but preserve <br> as newlines so post excerpts
  // read the way humans wrote them, not as one giant paragraph blob.
  const plainEl = cheerio.load(bodyHTML.replaceAll(/<br\s*\/?>/gi, "\n"));
  const plain = strip(plainEl.text()).replace(/[ \t]*\n[ \t]*/g, "\n");

  const media = parseMedia($, wrap, channelUsername);
  const reactions = parseReactions($, wrap);

  const viewsLabel = nullIfEmpty(
    strip(wrap.find(".tgme_widget_message_views").first().text())
  );

  const datetime = wrap
    .find(".tgme_widget_message_date time")
    .first()
    .attr("datetime");
  const postedAt = datetime ? datetime : null;

  const metaText = strip(wrap.find(".tgme_widget_message_meta").first().text());
  const edited = metaText.toLowerCase().includes("edited");

  return {
    id: dataPost,
    author_name: author,
    author_photo_url: authorPhoto,
    author_photo_path: authorPhotoPath,
    body_html: bodyHTML,
    plain_text: plain,
    media,
    reactions,
    views_label: viewsLabel,
    posted_at: postedAt,
    edited,
    permalink: `https://t.me/${dataPost}`,
  };
}

function parseMedia(
  $: cheerio.CheerioAPI,
  wrap: cheerio.Cheerio<any>,
  channelUsername: string
): MediaDTO[] {
  const out: MediaDTO[] = [];

  wrap.find(".tgme_widget_message_photo_wrap").each((_, el) => {
    const $el = $(el);
    const href = $el.attr("href") ?? null;
    // Telegram has two photo markup variants:
    //   1. Single: outer <a> has `background-image:`; nested
    //      `.tgme_widget_message_photo` carries `padding-top:X%` (the
    //      classic CSS aspect-ratio-reserving padding hack).
    //   2. Grouped/album: outer <a> has `data-ratio="W/H"` (the
    //      per-photo aspect, in the same width-to-height convention we
    //      use); the inner div only carries positioning, and the
    //      album's combined padding-top sits on a separate
    //      `.tgme_widget_message_grouped` wrapper.
    // Try data-ratio first (covers albums), then padding-top.
    const wrapStyle = $el.attr("style") ?? "";
    const innerStyle =
      $el.find(".tgme_widget_message_photo").first().attr("style") ?? "";
    const thumb = backgroundImageURL(wrapStyle);
    const asset = href ?? thumb;
    out.push({
      kind: "photo" as MediaKind,
      asset_url: asset,
      asset_path: pathFor(asset, channelUsername),
      thumbnail_url: thumb,
      thumbnail_path: pathFor(thumb, channelUsername),
      duration_label: null,
      aspect_ratio: dataRatio($el.attr("data-ratio")) ?? aspectRatio(innerStyle),
    });
  });

  wrap.find(".tgme_widget_message_video_player").each((_, el) => {
    const $el = $(el);
    const href = $el.attr("href") ?? null;
    const wrapStyle =
      $el.find(".tgme_widget_message_video_wrap").first().attr("style") ?? "";
    const thumbStyle =
      $el.find(".tgme_widget_message_video_thumb").first().attr("style") ?? "";
    const thumb = backgroundImageURL(thumbStyle);
    const duration = nullIfEmpty(
      strip($el.find(".message_video_duration").first().text())
    );
    // Videos: don't try to mirror the .mp4 itself (large; outside scope).
    // We only mirror the poster thumb, which behaves like a photo.
    out.push({
      kind: "video" as MediaKind,
      asset_url: href ?? thumb,
      asset_path: null,
      thumbnail_url: thumb,
      thumbnail_path: pathFor(thumb, channelUsername),
      duration_label: duration,
      // Telegram puts padding-top on the outer wrap, not the thumb.
      aspect_ratio: aspectRatio(wrapStyle) ?? aspectRatio(thumbStyle),
    });
  });

  return out;
}

function pathFor(url: string | null, channelUsername: string): string | null {
  if (!url || !isMirrorableImageURL(url)) return null;
  return pathForCanonicalURL(url, channelUsername).path;
}

/**
 * Decide whether a URL points to media we should download + mirror.
 * Skip telegram.org emoji sprites — they're tiny, ubiquitous, and shared
 * across thousands of posts; mirroring would balloon the repo.
 */
function isMirrorableImageURL(url: string): boolean {
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    if (host === "telegram.org" || host.endsWith(".telegram.org")) return false;
    return host.endsWith(".telesco.pe") || host.endsWith(".cdn-telegram.org");
  } catch {
    return false;
  }
}

function parseReactions(
  $: cheerio.CheerioAPI,
  wrap: cheerio.Cheerio<any>
): ReactionDTO[] {
  const out: ReactionDTO[] = [];
  wrap.find(".tgme_reaction").each((_, el) => {
    const $el = $(el);

    // Resolve a printable emoji glyph from one of three shapes:
    //   1. Standard:   <i class="emoji"><b>👍</b></i>
    //   2. Paid:       <i class="icon icon-telegram-stars"></i>
    //   3. Custom:     <tg-emoji emoji-id="...">[optional fallback text]</tg-emoji>
    let emoji = strip($el.find(".emoji b").first().text());
    if (!emoji) {
      emoji = strip($el.find("tg-emoji").first().text());
    }
    if (!emoji) {
      const iconClasses = $el.find("i.icon").first().attr("class") ?? "";
      if (iconClasses.includes("icon-telegram-stars")) {
        emoji = "⭐";
      } else if ($el.find("tg-emoji").length > 0) {
        emoji = "💎"; // custom Telegram emoji with no unicode fallback
      }
    }

    const fullText = strip($el.text());
    const countMatch = fullText.match(/([\d.]+\s*[KM]?)\s*$/);
    const count = countMatch?.[1] ? strip(countMatch[1]) : "0";

    out.push({ emoji, count });
  });
  return out;
}

// MARK: - tiny helpers

function strip(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function nullIfEmpty(s: string): string | null {
  return s.length > 0 ? s : null;
}

function backgroundImageURL(style: string): string | null {
  const match = style.match(/url\(['"]?([^'")]+)['"]?\)/);
  if (!match || !match[1]) return null;
  let url = match[1];
  if (url.startsWith("//")) url = "https:" + url;
  return url;
}

function aspectRatio(style: string): number | null {
  const match = style.match(/padding-top:\s*([\d.]+)%/);
  if (!match || !match[1]) return null;
  const pct = parseFloat(match[1]);
  if (!isFinite(pct) || pct <= 0) return null;
  return 100 / pct;
}

function dataRatio(value: string | undefined): number | null {
  if (!value) return null;
  const ratio = parseFloat(value);
  if (!isFinite(ratio) || ratio <= 0) return null;
  return ratio;
}
