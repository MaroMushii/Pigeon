import XCTest
@testable import Pigeon

final class JSONFeedDecoderTests: XCTestCase {
    private let decoder = JSONFeedDecoder()
    private let mirrorBase = URL(string: "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/")!

    // MARK: - Schema validation

    func testUnsupportedSchemaVersionThrows() throws {
        let json = makeSnapshot(schema: 99)
        XCTAssertThrowsError(try decoder.decode(json, mirrorBaseURL: mirrorBase)) { error in
            guard case JSONFeedDecoder.DecodeError.unsupportedSchema(let found, let supported) = error else {
                return XCTFail("Expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, JSONFeedDecoder.supportedSchemaVersion)
        }
    }

    func testInvalidJSONThrows() {
        let garbage = Data("not json at all".utf8)
        XCTAssertThrowsError(try decoder.decode(garbage, mirrorBaseURL: mirrorBase)) { error in
            if case JSONFeedDecoder.DecodeError.invalidJSON = error { } else {
                XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }

    // MARK: - Channel decoding

    func testChannelUsernameIsLowercased() throws {
        let json = makeSnapshot(channelUsername: "DuROV")
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertEqual(result.channel.username, "durov")
    }

    func testChannelPhotoPathResolvesAgainstMirrorBase() throws {
        let json = makeSnapshot(channelPhotoPath: "channels/durov/media/photo.jpg")
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertEqual(
            result.channel.photoURL,
            mirrorBase.appending(path: "channels/durov/media/photo.jpg").absoluteString
        )
    }

    func testChannelPhotoURLFallbackIsRewrittenThroughProxy() throws {
        // No asset_path — the fallback canonical CDN URL must go through
        // TelegramURLRewriter so it doesn't hit a DPI-blocked hostname.
        let json = makeSnapshot(channelPhotoPath: nil, channelPhotoURL: "https://cdn4.telesco.pe/file/photo.jpg")
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        let host = result.channel.photoURL.flatMap { URL(string: $0)?.host } ?? ""
        XCTAssertTrue(
            host.hasSuffix(".translate.goog"),
            "channel photoURL fallback must be proxied; got host <\(host)>"
        )
    }

    func testEmptySubscriberCountBecomesNil() throws {
        let json = makeSnapshot(subscriberCount: "")
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertNil(result.channel.subscriberCount)
    }

    // MARK: - Post decoding

    func testPostFieldsAreMappedCorrectly() throws {
        let json = makeSnapshot(posts: [
            makePost(
                id: "durov/42",
                authorName: "Pavel Durov",
                bodyHTML: "<p>Hello</p>",
                plainText: "Hello",
                edited: true,
                permalink: "https://t.me/durov/42"
            )
        ])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        let post = try XCTUnwrap(result.posts.first)
        XCTAssertEqual(post.id, "durov/42")
        XCTAssertEqual(post.authorName, "Pavel Durov")
        XCTAssertEqual(post.bodyHTML, "<p>Hello</p>")
        XCTAssertEqual(post.plainText, "Hello")
        XCTAssertTrue(post.edited)
        XCTAssertEqual(post.permalink?.absoluteString, "https://t.me/durov/42")
    }

    func testChannelUsernameIsPropagatedToEveryPost() throws {
        let json = makeSnapshot(channelUsername: "DUROV", posts: [makePost(), makePost(id: "durov/2")])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        for post in result.posts {
            XCTAssertEqual(post.channelUsername, "durov")
        }
    }

    // MARK: - Date parsing

    func testPostedAtWithFractionalSecondsIsParsed() throws {
        let json = makeSnapshot(posts: [makePost(postedAt: "2024-01-15T10:30:00.000Z")])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertNotNil(result.posts.first?.postedAt)
    }

    func testPostedAtWithoutFractionalSecondsIsParsed() throws {
        let json = makeSnapshot(posts: [makePost(postedAt: "2024-01-15T10:30:00Z")])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertNotNil(result.posts.first?.postedAt)
    }

    func testNullPostedAtProducesNilDate() throws {
        let json = makeSnapshot(posts: [makePost(postedAt: nil)])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertNil(result.posts.first?.postedAt)
    }

    // MARK: - Media decoding

    func testMediaAssetPathTakesPrecedenceOverAssetURL() throws {
        // When both are present, the repo-hosted path wins — it's unblocked.
        let json = makeSnapshot(posts: [makePost(media: [
            makeMedia(assetPath: "channels/durov/media/abc.jpg", assetURL: "https://cdn4.telesco.pe/file/abc.jpg")
        ])])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        let assetURL = try XCTUnwrap(result.posts.first?.media.first?.assetURL)
        XCTAssertEqual(assetURL, mirrorBase.appending(path: "channels/durov/media/abc.jpg"))
    }

    func testMediaAssetURLFallbackIsProxied() throws {
        // No asset_path — canonical CDN URL must be routed through the GT proxy.
        let json = makeSnapshot(posts: [makePost(media: [
            makeMedia(assetPath: nil, assetURL: "https://cdn4.telesco.pe/file/abc.jpg")
        ])])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        let host = result.posts.first?.media.first?.assetURL?.host ?? ""
        XCTAssertTrue(
            host.hasSuffix(".translate.goog"),
            "media asset fallback must be proxied; got host <\(host)>"
        )
    }

    func testMediaKindPhotoIsMapped() throws {
        let json = makeSnapshot(posts: [makePost(media: [makeMedia(kind: "photo")])])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertEqual(result.posts.first?.media.first?.kind, .photo)
    }

    func testMediaKindVideoIsMapped() throws {
        let json = makeSnapshot(posts: [makePost(media: [makeMedia(kind: "video")])])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertEqual(result.posts.first?.media.first?.kind, .video)
    }

    func testUnknownMediaKindIsMapped() throws {
        let json = makeSnapshot(posts: [makePost(media: [makeMedia(kind: "sticker")])])
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        XCTAssertEqual(result.posts.first?.media.first?.kind, .unknown)
    }

    // MARK: - No raw CDN hosts in output

    func testNoRawTelegramCDNHostsLeakIntoOutput() throws {
        let json = makeSnapshot(
            channelPhotoPath: nil,
            channelPhotoURL: "https://cdn4.telesco.pe/file/ch.jpg",
            posts: [makePost(media: [
                makeMedia(assetPath: nil, assetURL: "https://cdn-telegram.org/file/a.jpg"),
                makeMedia(assetPath: nil, thumbnailURL: "https://cdn1.telesco.pe/file/thumb.jpg")
            ])]
        )
        let result = try decoder.decode(json, mirrorBaseURL: mirrorBase)

        let bannedSuffixes = [".telesco.pe", ".cdn-telegram.org"]

        func assertNotRaw(_ urlString: String?, label: String) {
            guard let urlString, let host = URL(string: urlString)?.host else { return }
            for banned in bannedSuffixes {
                XCTAssertFalse(
                    host.hasSuffix(banned),
                    "\(label) contains raw CDN host <\(host)>"
                )
            }
        }

        assertNotRaw(result.channel.photoURL, label: "channel.photoURL")
        for post in result.posts {
            for media in post.media {
                assertNotRaw(media.assetURL?.absoluteString, label: "media.assetURL")
                assertNotRaw(media.thumbnailURL?.absoluteString, label: "media.thumbnailURL")
            }
        }
    }
}

// MARK: - JSON fixture builders

private func makeSnapshot(
    schema: Int = JSONFeedDecoder.supportedSchemaVersion,
    channelUsername: String = "durov",
    channelPhotoPath: String? = nil,
    channelPhotoURL: String? = nil,
    subscriberCount: String? = "1.2M",
    posts: [String] = []
) -> Data {
    let photoPath = channelPhotoPath.map { "\"\($0)\"" } ?? "null"
    let photoURL = channelPhotoURL.map { "\"\($0)\"" } ?? "null"
    let subCount = subscriberCount.map { "\"\($0)\"" } ?? "null"
    let postsJSON = posts.joined(separator: ",")

    let json = """
    {
      "schema": \(schema),
      "fetched_at": "2024-01-15T10:30:00Z",
      "channel": {
        "username": "\(channelUsername)",
        "title": "Test Channel",
        "description_html": null,
        "photo_url": \(photoURL),
        "photo_path": \(photoPath),
        "subscriber_count": \(subCount)
      },
      "posts": [\(postsJSON)]
    }
    """
    return Data(json.utf8)
}

private func makePost(
    id: String = "durov/1",
    authorName: String = "Test Author",
    bodyHTML: String = "<p>Test</p>",
    plainText: String = "Test",
    postedAt: String? = "2024-01-15T10:30:00Z",
    edited: Bool = false,
    permalink: String = "https://t.me/durov/1",
    media: [String] = [],
    reactions: [String] = []
) -> String {
    let postedAtJSON = postedAt.map { "\"\($0)\"" } ?? "null"
    let mediaJSON = media.joined(separator: ",")
    let reactionsJSON = reactions.joined(separator: ",")

    return """
    {
      "id": "\(id)",
      "author_name": "\(authorName)",
      "author_photo_url": null,
      "author_photo_path": null,
      "body_html": "\(bodyHTML)",
      "plain_text": "\(plainText)",
      "media": [\(mediaJSON)],
      "reactions": [\(reactionsJSON)],
      "views_label": null,
      "posted_at": \(postedAtJSON),
      "edited": \(edited),
      "permalink": "\(permalink)"
    }
    """
}

private func makeMedia(
    kind: String = "photo",
    assetPath: String? = "channels/durov/media/abc.jpg",
    assetURL: String? = nil,
    thumbnailPath: String? = nil,
    thumbnailURL: String? = nil
) -> String {
    let ap = assetPath.map { "\"\($0)\"" } ?? "null"
    let au = assetURL.map { "\"\($0)\"" } ?? "null"
    let tp = thumbnailPath.map { "\"\($0)\"" } ?? "null"
    let tu = thumbnailURL.map { "\"\($0)\"" } ?? "null"

    return """
    {
      "kind": "\(kind)",
      "asset_url": \(au),
      "asset_path": \(ap),
      "thumbnail_url": \(tu),
      "thumbnail_path": \(tp),
      "duration_label": null,
      "aspect_ratio": null
    }
    """
}
