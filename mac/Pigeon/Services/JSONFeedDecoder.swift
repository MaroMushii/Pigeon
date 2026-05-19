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

    static let supportedSchemaVersion = 2

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
        // Optional — pre-signing snapshots lack this. Used by VerifyingDataLoader
        // to integrity-check the channel avatar bytes against the (already
        // signature-verified) snapshot.
        let photo_sha256: String?
        let subscriber_count: String?
    }

    private struct PostDTO: Decodable {
        let id: String
        let author_name: String
        let author_photo_url: String?
        let author_photo_path: String?
        let author_photo_sha256: String?
        let body_html: String
        let plain_text: String
        let media: [MediaDTO]
        let reactions: [ReactionDTO]
        let views_label: String?
        let posted_at: String?
        let edited: Bool
        let permalink: String
        /// Optional — older snapshots written before the reply field
        /// landed will simply decode this as `nil`.
        let reply: ReplyDTO?
    }

    private struct ReplyDTO: Decodable {
        let channel_username: String
        let post_id: String
        let author_name: String
        let preview_text: String
        let thumbnail_url: String?
        let thumbnail_path: String?
        let thumbnail_sha256: String?
        let permalink: String
    }

    private struct MediaDTO: Decodable {
        let kind: String
        let asset_url: String?
        let asset_path: String?
        let asset_sha256: String?
        let thumbnail_url: String?
        let thumbnail_path: String?
        let thumbnail_sha256: String?
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
            env = try Self.decoder.decode(SnapshotDTO.self, from: data)
        } catch {
            throw DecodeError.invalidJSON(underlying: error)
        }

        guard env.schema == Self.supportedSchemaVersion else {
            throw DecodeError.unsupportedSchema(
                found: env.schema,
                supported: Self.supportedSchemaVersion
            )
        }

        let channelPhotoURL = resolveURL(
            path: env.channel.photo_path,
            fallback: env.channel.photo_url,
            base: mirrorBaseURL
        )
        registerHash(url: channelPhotoURL, path: env.channel.photo_path, hex: env.channel.photo_sha256)

        let channel = HTMLPostParser.ChannelInfo(
            title: env.channel.title,
            username: env.channel.username.lowercased(),
            descriptionHTML: emptyToNil(env.channel.description_html),
            photoURL: channelPhotoURL?.absoluteString,
            subscriberCount: emptyToNil(env.channel.subscriber_count)
        )

        let posts: [PostSnapshot] = env.posts.map { dto in
            let media: [MediaSnapshot] = dto.media.map { m in
                let kind: MediaSnapshot.Kind = switch m.kind.lowercased() {
                case "photo": .photo
                case "video": .video
                default: .unknown
                }
                let assetURL = resolveURL(path: m.asset_path, fallback: m.asset_url, base: mirrorBaseURL)
                let thumbURL = resolveURL(path: m.thumbnail_path, fallback: m.thumbnail_url, base: mirrorBaseURL)
                registerHash(url: assetURL, path: m.asset_path, hex: m.asset_sha256)
                registerHash(url: thumbURL, path: m.thumbnail_path, hex: m.thumbnail_sha256)
                return MediaSnapshot(
                    kind: kind,
                    assetURL: assetURL,
                    thumbnailURL: thumbURL,
                    durationLabel: emptyToNil(m.duration_label),
                    aspectRatio: m.aspect_ratio
                )
            }

            let reactions = dto.reactions.map { ReactionSnapshot(emoji: $0.emoji, count: $0.count) }
            let postedAt = dto.posted_at.flatMap { Self.fractionalISO.date(from: $0) ?? Self.plainISO.date(from: $0) }

            let authorPhotoURL = resolveURL(
                path: dto.author_photo_path,
                fallback: dto.author_photo_url,
                base: mirrorBaseURL
            )
            registerHash(url: authorPhotoURL, path: dto.author_photo_path, hex: dto.author_photo_sha256)

            let reply: ReplySnapshot? = dto.reply.map { r in
                let replyThumbURL = resolveURL(
                    path: r.thumbnail_path,
                    fallback: r.thumbnail_url,
                    base: mirrorBaseURL
                )
                registerHash(url: replyThumbURL, path: r.thumbnail_path, hex: r.thumbnail_sha256)
                return ReplySnapshot(
                    channelUsername: r.channel_username.lowercased(),
                    postIDNumeric: r.post_id,
                    authorName: r.author_name,
                    previewText: r.preview_text,
                    thumbnailURL: replyThumbURL?.absoluteString,
                    permalink: URL(string: r.permalink)
                )
            }

            return PostSnapshot(
                id: dto.id,
                channelUsername: env.channel.username.lowercased(),
                authorName: dto.author_name,
                authorPhotoURL: authorPhotoURL?.absoluteString,
                bodyHTML: dto.body_html,
                plainText: dto.plain_text,
                media: media,
                reactions: reactions,
                viewsLabel: emptyToNil(dto.views_label),
                postedAt: postedAt,
                edited: dto.edited,
                permalink: URL(string: dto.permalink),
                reply: reply
            )
        }

        return HTMLPostParser.ParseResult(channel: channel, posts: posts)
    }

    // See `LockedISO8601` — Apple's docs don't formally cover
    // `ISO8601DateFormatter` thread-safety, and a corrupt date silently
    // produced by a race would be near-impossible to debug downstream.
    private static let fractionalISO: LockedISO8601 = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return LockedISO8601(f)
    }()

    private static let plainISO: LockedISO8601 = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return LockedISO8601(f)
    }()

    private static let decoder = JSONDecoder()

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

    private func emptyToNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Register `hex` as the expected SHA-256 for `url`. Only registers when
    /// the URL resolved via a repo-relative `path` (i.e. we trust this hash
    /// because it came from a signature-verified snapshot AND the URL points
    /// at mirror-hosted bytes). If the URL came from a fallback `_url` field,
    /// the hash doesn't apply to those bytes — they live on Telegram's CDN,
    /// not in our mirror, and were never hashed by the scraper.
    private func registerHash(url: URL?, path: String?, hex: String?) {
        guard let url, let path, !path.isEmpty else { return }
        guard let hex, !hex.isEmpty else {
            // Repo-relative path present but no hash — the scraper wrote a
            // mirrored asset without stamping it. Signals a producer-pipeline
            // regression (e.g. `applyMediaHashes` skipped this file). Log so
            // it shows up in mirror logs; bytes will load unverified.
            AppLog.mirror.error("[verify] mirrored asset has no sha256 stamp path=<\(path, privacy: .public)>")
            return
        }
        ImageHashRegistry.shared.register(url: url, sha256Hex: hex)
    }
}
