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
        let posts: [Post]
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

    private func parsePosts(_ doc: Document, channelUsername: String) throws -> [Post] {
        let wraps = try doc.select(".tgme_widget_message_wrap")
        return wraps.array().compactMap { wrap in
            try? parsePost(wrap, channelUsername: channelUsername)
        }
    }

    private func parsePost(_ wrap: Element, channelUsername: String) throws -> Post? {
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

        let textEl = try wrap.select(".tgme_widget_message_text").first()
        let bodyHTML = (try? textEl?.html()) ?? ""
        let plain = (try? textEl?.text()) ?? ""

        let media = parseMedia(in: wrap)
        let reactions = parseReactions(in: wrap)

        let viewsLabel = try? wrap.select(".tgme_widget_message_views").first()?.text()

        var postedAt: Date?
        if let timeEl = try? wrap.select(".tgme_widget_message_date time").first(),
           let datetime = try? timeEl.attr("datetime"), !datetime.isEmpty {
            postedAt = ISO8601DateFormatter().date(from: datetime)
        }

        let edited = (try? wrap.select(".tgme_widget_message_meta").first()?.text().contains("edited")) ?? false

        let permalink = URL(string: "https://t.me/\(dataPost)")

        return Post(
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
            permalink: permalink
        )
    }

    private func parseMedia(in wrap: Element) -> [Media] {
        var out: [Media] = []

        if let photos = try? wrap.select(".tgme_widget_message_photo_wrap").array() {
            for el in photos {
                let href = (try? el.attr("href")).flatMap(URL.init(string:))
                let style = (try? el.attr("style")) ?? ""
                let thumb = backgroundImageURL(from: style)
                out.append(Media(
                    kind: .photo,
                    assetURL: TelegramURLRewriter.rewrite(href ?? thumb),
                    thumbnailURL: TelegramURLRewriter.rewrite(thumb),
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
                out.append(Media(
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

    private func parseReactions(in wrap: Element) -> [Reaction] {
        guard let elements = try? wrap.select(".tgme_reaction").array() else { return [] }
        return elements.compactMap { el in
            let emoji = (try? el.select(".emoji b").first()?.text())
                ?? (try? el.select(".icon").first()?.text())
                ?? ""
            let count = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The text() includes the emoji + the count; strip the emoji.
            let stripped = count.replacingOccurrences(of: emoji, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Reaction(emoji: emoji, count: stripped.isEmpty ? "0" : stripped)
        }
    }

    private func backgroundImageURL(from style: String) -> URL? {
        guard let range = style.range(of: #"url\(['"]?([^'"\)]+)['"]?\)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(style[range])
        let trimmed = match
            .replacingOccurrences(of: "url(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return URL(string: trimmed)
    }

    private func aspectRatio(from style: String) -> Double? {
        // padding-top: 56.25% is a common width:height encoding.
        if let range = style.range(of: #"padding-top:\s*([0-9.]+)%"#, options: .regularExpression) {
            let match = String(style[range])
            let digits = match.filter { "0123456789.".contains($0) }
            if let pct = Double(digits), pct > 0 {
                return 100.0 / pct
            }
        }
        return nil
    }
}
