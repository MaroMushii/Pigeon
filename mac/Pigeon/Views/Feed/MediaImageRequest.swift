import Foundation
import Nuke

/// Shared `ImageRequest` builder for feed media tiles. The processor
/// configuration is part of Nuke's cache key, so prefetch and render must
/// use *byte-identical* requests — otherwise the prefetched bitmap sits
/// unused while the render path issues a second download. Centralising
/// the builder here is the cheapest way to keep them in sync.
enum MediaImageRequest {
    /// Width/height the feed downsamples media to. Matches the upper bound
    /// of `MediaGallery`'s adaptive grid (`maximum: 360`).
    static let renderSize = CGSize(width: 360, height: 360)

    /// Build the same request `MediaTile` uses for rendering. Returns nil
    /// when the media has no usable URL (e.g. an unknown asset that the
    /// parser couldn't extract).
    static func tile(for media: Media) -> ImageRequest? {
        guard let url = media.thumbnailURL ?? media.assetURL else { return nil }
        return ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: renderSize,
                    contentMode: .aspectFill,
                    crop: false
                )
            ]
        )
    }
}

