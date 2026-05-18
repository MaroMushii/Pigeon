import Foundation
import SwiftSoup

/// Parses the t.me/s/<channel> HTML payload (as proxied through Google
/// Translate) into our domain types.
///
/// All selectors target Telegram's public widget DOM. The Google Translate
/// proxy preserves classes, IDs, and inline styles, so the same selectors
/// work whether or not the page was translated.
struct HTMLPostParser {
    struct ChannelInfo: Sendable {
        let title: String
        let username: String
        let descriptionHTML: String?
        let photoURL: String?
        let subscriberCount: String?
    }

    struct ParseResult: Sendable {
        let channel: ChannelInfo
        let posts: [PostSnapshot]
    }

    enum ParseError: Error, LocalizedError {
        case malformedDocument
        case channelNotFound

        var errorDescription: String? {
            switch self {
            case .malformedDocument: "Could not parse channel page."
            case .channelNotFound: "Channel was not found or is private."
            }
        }
    }

    func parse(_ html: String, fallbackUsername: String) throws -> ParseResult {
        let doc: Document
        do {
            doc = try SwiftSoup.parse(html)
        } catch {
            throw ParseError.malformedDocument
        }

        let channel = try parseChannel(doc, fallbackUsername: fallbackUsername)
        let posts = try parsePosts(doc, channelUsername: channel.username)
        return ParseResult(channel: channel, posts: posts)
    }

    // MARK: - Channel

    private func parseChannel(_ doc: Document, fallbackUsername: String) throws -> ChannelInfo {
        let title = (try? doc.select(".tgme_channel_info_header_title span").first()?.text())
            ?? (try? doc.select(".tgme_channel_info_header_title").first()?.text())
            ?? fallbackUsername

        var username = (try? doc.select(".tgme_channel_info_header_username a").first()?.text()) ?? ""
        if username.hasPrefix("@") { username.removeFirst() }
        if username.isEmpty { username = fallbackUsername }

        let descriptionHTML = try? doc.select(".tgme_channel_info_description").first()?.html()

        let rawPhoto = (try? doc.select(".tgme_channel_info_header img").first()?.attr("src"))
            ?? (try? doc.select(".tgme_page_photo_image img").first()?.attr("src"))
        let photoURL = rawPhoto.flatMap { URL(string: $0) }
            .flatMap(TelegramURLRewriter.rewrite)
            .map(\.absoluteString)

        let subscribers = try? doc.select(".tgme_channel_info_counter .counter_value").first()?.text()

        return ChannelInfo(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.lowercased(),
            descriptionHTML: descriptionHTML?.isEmpty == true ? nil : descriptionHTML,
            photoURL: photoURL,
            subscriberCount: subscribers
        )
    }

    // MARK: - Posts

    private func parsePosts(_ doc: Document, channelUsername: String) throws -> [PostSnapshot] {
        let wraps = try doc.select(".tgme_widget_message_wrap")
        return wraps.array().compactMap { wrap in
            do {
                return try parsePost(wrap, channelUsername: channelUsername)
            } catch {
                #if DEBUG
                print("[HTMLPostParser] dropped post: \(error)")
                #endif
                return nil
            }
        }
    }

    private func parsePost(_ wrap: Element, channelUsername: String) throws -> PostSnapshot? {
        let messageEl = try wrap.select(".tgme_widget_message").first() ?? wrap

        let dataPost = try messageEl.attr("data-post")
        guard !dataPost.isEmpty else { return nil }

        let author = (try? wrap.select(".tgme_widget_message_owner_name span").first()?.text())
            ?? (try? wrap.select(".tgme_widget_message_owner_name").first()?.text())
            ?? ""
        let rawAuthorPhoto = try? wrap.select(".tgme_widget_message_user_photo img").first()?.attr("src")
        let authorPhoto = rawAuthorPhoto.flatMap { URL(string: $0) }
            .flatMap(TelegramURLRewriter.rewrite)
            .map(\.absoluteString)

        // Reply quotes nest a `.tgme_widget_message_text` inside
        // `.tgme_widget_message_reply`; SwiftSoup's CSS engine doesn't
        // support `:not(.x .y)`, so we scan the matches and drop any
        // whose ancestor chain hits a reply block. Otherwise `first()`
        // would pick the truncated reply preview instead of the body.
        let textEl = (try? wrap.select(".tgme_widget_message_text").array())?.first { el in
            var cursor: Element? = el.parent()
            while let node = cursor {
                if node.hasClass("tgme_widget_message_reply") { return false }
                cursor = node.parent()
            }
            return true
        }
        let bodyHTML = (try? textEl?.html()) ?? ""
        let plain = textEl.map { plainText(from: $0) } ?? ""

        let media = parseMedia(in: wrap)
        let reactions = parseReactions(in: wrap)
        let reply = parseReply(in: wrap)

        let viewsLabel = try? wrap.select(".tgme_widget_message_views").first()?.text()

        var postedAt: Date?
        if let timeEl = try? wrap.select(".tgme_widget_message_date time").first(),
           let datetime = try? timeEl.attr("datetime"), !datetime.isEmpty {
            postedAt = Self.fractionalISO.date(from: datetime)
                ?? Self.plainISO.date(from: datetime)
        }

        let edited = (try? wrap.select(".tgme_widget_message_meta").first()?.text().contains("edited")) ?? false

        let permalink = URL(string: "https://t.me/\(dataPost)")

        return PostSnapshot(
            id: dataPost,
            channelUsername: channelUsername,
            authorName: author.trimmingCharacters(in: .whitespacesAndNewlines),
            authorPhotoURL: authorPhoto,
            bodyHTML: bodyHTML,
            plainText: plain.trimmingCharacters(in: .whitespacesAndNewlines),
            media: media,
            reactions: reactions,
            viewsLabel: viewsLabel,
            postedAt: postedAt,
            edited: edited,
            permalink: permalink,
            reply: reply
        )
    }

    nonisolated(unsafe) private static let replyHrefRegex = /t\.me\/(?:s\/)?(?<channel>[A-Za-z0-9_]+)\/(?<post>\d+)/

    private func parseReply(in wrap: Element) -> ReplySnapshot? {
        guard let replyEl = try? wrap.select(".tgme_widget_message_reply").first() else { return nil }
        let href = (try? replyEl.attr("href")) ?? ""
        guard let match = href.firstMatch(of: Self.replyHrefRegex) else { return nil }
        let channel = String(match.channel).lowercased()
        let postID = String(match.post)

        let author = ((try? replyEl.select(".tgme_widget_message_author_name").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previewText = ((try? replyEl.select(".tgme_widget_message_text").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let thumbStyle = (try? replyEl.select(".tgme_widget_message_reply_thumb").first()?.attr("style")) ?? ""
        let thumb = backgroundImageURL(from: thumbStyle)
            .flatMap(TelegramURLRewriter.rewrite)
            .map(\.absoluteString)

        return ReplySnapshot(
            channelUsername: channel,
            postIDNumeric: postID,
            authorName: author,
            previewText: previewText,
            thumbnailURL: thumb,
            permalink: URL(string: "https://t.me/\(channel)/\(postID)")
        )
    }

    private func parseMedia(in wrap: Element) -> [MediaSnapshot] {
        var out: [MediaSnapshot] = []

        if let photos = try? wrap.select(".tgme_widget_message_photo_wrap").array() {
            for el in photos {
                let style = (try? el.attr("style")) ?? ""
                let thumb = backgroundImageURL(from: style)
                // `href` on the wrap is the post permalink (a t.me link),
                // not the image — Telegram uses it for click-through. The
                // CSS background URL IS the image, so it's both `assetURL`
                // and `thumbnailURL`.
                let asset = TelegramURLRewriter.rewrite(thumb)
                out.append(MediaSnapshot(
                    kind: .photo,
                    assetURL: asset,
                    thumbnailURL: asset,
                    durationLabel: nil,
                    aspectRatio: aspectRatio(from: style)
                ))
            }
        }

        if let videos = try? wrap.select(".tgme_widget_message_video_player").array() {
            for el in videos {
                let href = (try? el.attr("href")).flatMap(URL.init(string:))
                let thumbStyle = (try? el.select(".tgme_widget_message_video_thumb").first()?.attr("style")) ?? ""
                let thumb = backgroundImageURL(from: thumbStyle)
                let duration = try? el.select(".message_video_duration").first()?.text()
                out.append(MediaSnapshot(
                    kind: .video,
                    assetURL: TelegramURLRewriter.rewrite(href ?? thumb),
                    thumbnailURL: TelegramURLRewriter.rewrite(thumb),
                    durationLabel: duration,
                    aspectRatio: aspectRatio(from: thumbStyle)
                ))
            }
        }

        return out
    }

    /// Resolve a printable emoji glyph and a count from a single
    /// `.tgme_reaction` node. Telegram serves three shapes:
    ///   1. Standard:  `<i class="emoji"><b>👍</b></i>`
    ///   2. Paid:      `<i class="icon icon-telegram-stars"></i>` → ⭐
    ///   3. Custom:    `<tg-emoji emoji-id="...">[optional fallback]</tg-emoji>`
    /// — when a `<tg-emoji>` has no fallback text we substitute 💎 so the
    /// reaction renders something rather than collapsing to a count next to
    /// nothing. Mirrors `mirror/parser.ts`'s handling.
    ///
    /// The count is parsed via regex (`123`, `1.2K`, `4M`) instead of the
    /// previous "substring-subtract emoji" approach, which broke when the
    /// emoji glyph appeared anywhere in the count text (e.g. zero-width
    /// joiners).
    private func parseReactions(in wrap: Element) -> [ReactionSnapshot] {
        guard let elements = try? wrap.select(".tgme_reaction").array() else { return [] }
        return elements.compactMap { el in
            var emoji = (try? el.select(".emoji b").first()?.text()) ?? ""
            if emoji.isEmpty {
                emoji = (try? el.select("tg-emoji").first()?.text()) ?? ""
            }
            if emoji.isEmpty {
                let iconClasses = (try? el.select("i.icon").first()?.attr("class")) ?? ""
                if iconClasses.contains("icon-telegram-stars") {
                    emoji = "⭐"
                } else if (try? el.select("tg-emoji").first()) != nil {
                    emoji = "💎"
                }
            }

            let fullText = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let count = Self.extractReactionCount(from: fullText)
            return ReactionSnapshot(emoji: emoji, count: count)
        }
    }

    nonisolated(unsafe) private static let reactionCountRegex = /(?:[\d.]+\s*[KM]?)\s*$/

    private static func extractReactionCount(from text: String) -> String {
        if let match = text.firstMatch(of: reactionCountRegex) {
            let result = String(match.output).trimmingCharacters(in: .whitespaces)
            if !result.isEmpty { return result }
        }
        return "0"
    }

    nonisolated(unsafe) private static let whitespaceAroundNewlineRegex = /[ \t]*\n[ \t]*/
    nonisolated(unsafe) private static let consecutiveNewlinesRegex = /\n{2,}/

    private func plainText(from element: Element) -> String {
        extractText(from: element)
            .replacing(Self.whitespaceAroundNewlineRegex, with: "\n")
            .replacing(Self.consecutiveNewlinesRegex, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractText(from element: Element) -> String {
        var result = ""
        for node in element.childNodesCopy() {
            if let text = node as? TextNode {
                result += text.getWholeText()
            } else if let el = node as? Element {
                if el.tagName() == "br" {
                    result += "\n"
                } else {
                    result += extractText(from: el)
                }
            }
        }
        return result
    }

    // ISO8601DateFormatter is documented thread-safe by Apple but not marked
    // Sendable; `nonisolated(unsafe)` reflects the runtime contract.
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let backgroundImageURLRegex = /url\(['"]?(?<url>[^'"\)]+)['"]?\)/
    nonisolated(unsafe) private static let aspectRatioRegex = /padding-top:\s*(?<pct>[0-9.]+)%/

    private func backgroundImageURL(from style: String) -> URL? {
        guard let match = style.firstMatch(of: Self.backgroundImageURLRegex) else { return nil }
        return URL(string: String(match.url))
    }

    private func aspectRatio(from style: String) -> Double? {
        guard let match = style.firstMatch(of: Self.aspectRatioRegex),
              let pct = Double(match.pct), pct > 0 else { return nil }
        return 100.0 / pct
    }
}
