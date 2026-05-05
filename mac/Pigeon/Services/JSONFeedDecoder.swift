import Foundation

/// Decodes a snapshot JSON committed to `MaroMushii/Pigeon#export` by
/// Pigeon's mirror Worker. Schema lives at `worker/src/schema.ts`; fields
/// here mirror it 1:1 via explicit CodingKeys.
///
/// URLs in the snapshot are *original* Telegram CDN URLs (e.g.
/// `cdn4.telesco.pe`). We rewrite them to GT-proxied form here so they
/// flow through `PinnedURLProtocol` like everything else.
struct JSONFeedDecoder {
    enum DecodeError: Error, LocalizedError {
        case unsupportedSchema(Int)
        case invalidJSON(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let v): "Mirror snapshot uses unsupported schema v\(v)."
            case .invalidJSON(let e): "Could not decode mirror snapshot: \(e.localizedDescription)"
            }
        }
    }

    static let supportedSchemaVersion: Int = 1

    private struct SnapshotDTO: Decodable {
        let schema: Int
        let fetched_at: String?
        let channel: ChannelDTO
        let posts: [PostDTO]
    }

    private struct ChannelDTO: Decodable {
        let username: String
        let title: String
        let description_html: String?
        let photo_url: String?
        let subscriber_count: String?
    }

    private struct PostDTO: Decodable {
        let id: String
        let author_name: String
        let author_photo_url: String?
        let body_html: String
        let plain_text: String
        let media: [MediaDTO]
        let reactions: [ReactionDTO]
        let views_label: String?
        let posted_at: String?
        let edited: Bool
        let permalink: String
    }

    private struct MediaDTO: Decodable {
        let kind: String
        let asset_url: String?
        let thumbnail_url: String?
        let duration_label: String?
        let aspect_ratio: Double?
    }

    private struct ReactionDTO: Decodable {
        let emoji: String
        let count: String
    }

    func decode(_ data: Data) throws -> HTMLPostParser.ParseResult {
        let env: SnapshotDTO
        do {
            env = try JSONDecoder().decode(SnapshotDTO.self, from: data)
        } catch {
            throw DecodeError.invalidJSON(underlying: error)
        }

        guard env.schema == Self.supportedSchemaVersion else {
            throw DecodeError.unsupportedSchema(env.schema)
        }

        let channel = HTMLPostParser.ChannelInfo(
            title: env.channel.title,
            username: env.channel.username.lowercased(),
            descriptionHTML: emptyToNil(env.channel.description_html),
            photoURL: rewrittenString(env.channel.photo_url),
            subscriberCount: emptyToNil(env.channel.subscriber_count)
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]

        let posts: [Post] = env.posts.map { dto in
            let media: [Media] = dto.media.map { m in
                let kind: Media.Kind = switch m.kind.lowercased() {
                case "photo": .photo
                case "video": .video
                default: .unknown
                }
                return Media(
                    kind: kind,
                    assetURL: rewrittenURL(m.asset_url),
                    thumbnailURL: rewrittenURL(m.thumbnail_url),
                    durationLabel: emptyToNil(m.duration_label),
                    aspectRatio: m.aspect_ratio
                )
            }

            let reactions = dto.reactions.map { Reaction(emoji: $0.emoji, count: $0.count) }
            let postedAt = dto.posted_at.flatMap { formatter.date(from: $0) ?? altFormatter.date(from: $0) }

            return Post(
                id: dto.id,
                channelUsername: env.channel.username.lowercased(),
                authorName: dto.author_name,
                authorPhotoURL: rewrittenString(dto.author_photo_url),
                bodyHTML: dto.body_html,
                plainText: dto.plain_text,
                media: media,
                reactions: reactions,
                viewsLabel: emptyToNil(dto.views_label),
                postedAt: postedAt,
                edited: dto.edited,
                permalink: URL(string: dto.permalink)
            )
        }

        return HTMLPostParser.ParseResult(channel: channel, posts: posts)
    }

    // MARK: -

    private func emptyToNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func rewrittenURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return TelegramURLRewriter.rewrite(url)
    }

    private func rewrittenString(_ raw: String?) -> String? {
        rewrittenURL(raw)?.absoluteString
    }
}
