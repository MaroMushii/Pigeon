import Foundation

struct Media: Hashable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
        case unknown
    }

    let kind: Kind
    let assetURL: URL?
    let thumbnailURL: URL?
    let durationLabel: String?
    let aspectRatio: Double?
}
