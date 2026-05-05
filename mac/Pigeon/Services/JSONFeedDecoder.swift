import Foundation

/// Decodes a snapshot JSON committed to `MaroMushii/Pigeon#export` by
/// Pigeon's mirror scraper. Schema lives at `mirror/schema.ts`; fields
/// here mirror it 1:1 via explicit CodingKeys.
///
/// **Path resolution (schema v2):** Each media item carries both
///   - `asset_url`  — canonical Telegram CDN URL (used as fallback)
///   - `asset_path` — repo-relative path under the export branch root
/// We prefer `asset_path` and resolve it against `mirrorRawPrefix` to a
/// `raw.githubusercontent.com` URL. If `asset_path` is missing (e.g. for
/// videos, where we don't mirror the .mp4), we fall back to the canonical
/// URL run through `TelegramURLRewriter` so it still flows through the
/// pinned GT image transport.
struct JSONFeedDecoder {
    enum DecodeError: Error, LocalizedError {
        case unsupportedSchema(found: Int, supported: Int)
        case invalidJSON(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let found, let supported):
                "Mirror snapshot uses unsupported schema v\(found) (this build supports v\(supported))."
            case .invalidJSON(let e):
                "Could not decode mirror snapshot: \(e.localizedDescription)"
            }
        }
    }

    static let supportedSchemaVersion: Int = 2

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
        let photo_path: String?
        let subscriber_count: String?
    }

    private struct PostDTO: Decodable {
        let id: String
        let author_name: String
        let author_photo_url: String?
        let author_photo_path: String?
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
        let asset_path: String?
        let thumbnail_url: String?
        let thumbnail_path: String?
        let duration_label: String?
        let aspect_ratio: Double?
    }

    private struct ReactionDTO: Decodable {
        let emoji: String
        let count: String
    }

    /// `mirrorBaseURL` is the same prefix used to fetch the snapshot —
    /// resolved by the caller from `SettingsStore`. Repo-relative
    /// `asset_path` values are appended to it to produce fetchable URLs.
    func decode(_ data: Data, mirrorBaseURL: URL) throws -> HTMLPostParser.ParseResult {
        let env: SnapshotDTO
        do {
            env = try JSONDecoder().decode(SnapshotDTO.self, from: data)
        } catch {
            throw DecodeError.invalidJSON(underlying: error)
        }

        guard env.schema == Self.supportedSchemaVersion else {
            throw DecodeError.unsupportedSchema(
                found: env.schema,
                supported: Self.supportedSchemaVersion
            )
        }

        let channel = HTMLPostParser.ChannelInfo(
            title: env.channel.title,
            username: env.channel.username.lowercased(),
            descriptionHTML: emptyToNil(env.channel.description_html),
            photoURL: resolveImageURL(path: env.channel.photo_path, fallback: env.channel.photo_url, base: mirrorBaseURL),
            subscriberCount: emptyToNil(env.channel.subscriber_count)
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]

        let posts: [PostSnapshot] = env.posts.map { dto in
            let media: [MediaSnapshot] = dto.media.map { m in
                let kind: MediaSnapshot.Kind = switch m.kind.lowercased() {
                case "photo": .photo
                case "video": .video
                default: .unknown
                }
                return MediaSnapshot(
                    kind: kind,
                    assetURL: resolveURL(path: m.asset_path, fallback: m.asset_url, base: mirrorBaseURL),
                    thumbnailURL: resolveURL(path: m.thumbnail_path, fallback: m.thumbnail_url, base: mirrorBaseURL),
                    durationLabel: emptyToNil(m.duration_label),
                    aspectRatio: m.aspect_ratio
                )
            }

            let reactions = dto.reactions.map { ReactionSnapshot(emoji: $0.emoji, count: $0.count) }
            let postedAt = dto.posted_at.flatMap { formatter.date(from: $0) ?? altFormatter.date(from: $0) }

            return PostSnapshot(
                id: dto.id,
                channelUsername: env.channel.username.lowercased(),
                authorName: dto.author_name,
                authorPhotoURL: resolveImageURL(
                    path: dto.author_photo_path,
                    fallback: dto.author_photo_url,
                    base: mirrorBaseURL
                ),
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

    // MARK: - URL resolution

    /// Resolve a media reference: prefer the repo-hosted path (cheap,
    /// CDN-cached, unblocked); fall back to the canonical URL routed
    /// through `TelegramURLRewriter` so the pinned-GT image transport
    /// still applies.
    private func resolveURL(path: String?, fallback: String?, base: URL) -> URL? {
        if let path, !path.isEmpty {
            return base.appending(path: path)
        }
        guard let fallback, !fallback.isEmpty, let url = URL(string: fallback) else {
            return nil
        }
        return TelegramURLRewriter.rewrite(url)
    }

    private func resolveImageURL(path: String?, fallback: String?, base: URL) -> String? {
        resolveURL(path: path, fallback: fallback, base: base)?.absoluteString
    }

    private func emptyToNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
