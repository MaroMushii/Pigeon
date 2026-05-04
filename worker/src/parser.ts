/**
 * Parses the t.me/s/<channel> HTML payload into a `Snapshot`.
 * Selectors mirror Telegram's public widget DOM and match the Swift
 * `HTMLPostParser` so both producers and consumers stay in lock-step.
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

export function parseChannelPage(html: string, fallbackUsername: string): Snapshot {
  const $ = cheerio.load(html);

  const channel: ChannelInfo = {
    username:
      strip($(".tgme_channel_info_header_username a").first().text())
        .replace(/^@/, "")
        .toLowerCase() || fallbackUsername.toLowerCase(),
    title:
      strip($(".tgme_channel_info_header_title span").first().text()) ||
      fallbackUsername,
    description_html: nullIfEmpty(
      $(".tgme_channel_info_description").first().html() ?? ""
    ),
    photo_url: nullIfEmpty(
      $(".tgme_channel_info_header img").first().attr("src") ??
        $(".tgme_page_photo_image img").first().attr("src") ??
        ""
    ),
    subscriber_count: nullIfEmpty(
      strip($(".tgme_channel_info_counter .counter_value").first().text())
    ),
  };

  const posts: PostDTO[] = [];
  $(".tgme_widget_message_wrap").each((_, el) => {
    const post = parsePost($, $(el));
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
  wrap: cheerio.Cheerio<any>
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

  const textEl = wrap.find(".tgme_widget_message_text").first();
  const bodyHTML = textEl.html() ?? "";
  // Extract plain text but preserve <br> as newlines so post excerpts read
  // the way humans wrote them, not as one giant paragraph blob.
  const plainEl = cheerio.load(bodyHTML.replaceAll(/<br\s*\/?>/gi, "\n"));
  const plain = strip(plainEl.text()).replace(/[ \t]*\n[ \t]*/g, "\n");

  const media = parseMedia($, wrap);
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
  wrap: cheerio.Cheerio<any>
): MediaDTO[] {
  const out: MediaDTO[] = [];

  wrap.find(".tgme_widget_message_photo_wrap").each((_, el) => {
    const $el = $(el);
    const href = $el.attr("href") ?? null;
    const style = $el.attr("style") ?? "";
    const thumb = backgroundImageURL(style);
    out.push({
      kind: "photo" as MediaKind,
      asset_url: href ?? thumb,
      thumbnail_url: thumb,
      duration_label: null,
      aspect_ratio: aspectRatio(style),
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
    out.push({
      kind: "video" as MediaKind,
      asset_url: href ?? thumb,
      thumbnail_url: thumb,
      duration_label: duration,
      // Telegram puts padding-top on the outer wrap, not the thumb.
      aspect_ratio: aspectRatio(wrapStyle) ?? aspectRatio(thumbStyle),
    });
  });

  return out;
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

    // Strip any non-count text and grab the trailing count token
    // ("24K", "1.59M", "421", etc.).
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
  // Telegram serves protocol-relative URLs in inline styles for emoji.
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
