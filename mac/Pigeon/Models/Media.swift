import Foundation
import SwiftData

struct MediaSnapshot: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
        case unknown
    }

    var id: String { "\(kind.rawValue)|\(assetURL?.absoluteString ?? "")" }
    let kind: Kind
    let assetURL: URL?
    let thumbnailURL: URL?
    let durationLabel: String?
    let aspectRatio: Double?
}

@Model
final class Media: Identifiable {
    /// Stored as the snapshot's raw string; `kind` exposes the enum form.
    var kindRaw: String
    var assetURL: URL?
    var thumbnailURL: URL?
    var durationLabel: String?
    var aspectRatio: Double?
    var post: Post?

    var kind: MediaSnapshot.Kind {
        MediaSnapshot.Kind(rawValue: kindRaw) ?? .unknown
    }

    init(
        kindRaw: String,
        assetURL: URL? = nil,
        thumbnailURL: URL? = nil,
        durationLabel: String? = nil,
        aspectRatio: Double? = nil
    ) {
        self.kindRaw = kindRaw
        self.assetURL = assetURL
        self.thumbnailURL = thumbnailURL
        self.durationLabel = durationLabel
        self.aspectRatio = aspectRatio
    }

    convenience init(from snapshot: MediaSnapshot) {
        self.init(
            kindRaw: snapshot.kind.rawValue,
            assetURL: snapshot.assetURL,
            thumbnailURL: snapshot.thumbnailURL,
            durationLabel: snapshot.durationLabel,
            aspectRatio: snapshot.aspectRatio
        )
    }
}
