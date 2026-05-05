import XCTest
@testable import Pigeon

/// Pins `HTMLPostParser` against real Telegram HTML so future markup
/// changes break tests rather than users.
///
/// Fixtures are HTML snapshots of `https://t.me/s/<channel>` captured
/// off-Iran with a normal Mozilla UA. Refresh them with:
///
///   curl -sL 'https://t.me/s/durov' -A 'Mozilla/5.0' \
///     -o mac/PigeonTests/Fixtures/durov.html
///
/// They live in the test bundle (built as resources), not the app bundle.
final class HTMLPostParserTests: XCTestCase {
    private let bundle = Bundle(for: HTMLPostParserTests.self)

    // MARK: - Golden fixture (durov)
    //
    // Drift detector. Telegram founder, large Latin posts, predictable.
    // If Telegram changes the page structure these three asserts catch
    // it before the user sees a broken feed.

    func testGoldenDurov() throws {
        let result = try parseFixture(named: "durov")

        XCTAssertEqual(
            result.channel.username,
            "durov",
            "Channel username should round-trip through parser"
        )

        let first = try XCTUnwrap(result.posts.first, "Expected at least one post")
        let actualPrefix = String(first.plainText.prefix(60))

        // Surface actual values so a re-capture failure shows you the
        // constants to paste into ExpectedDurov below.
        if ExpectedDurov.firstPostID.contains("__REPLACE") ||
           ExpectedDurov.firstPostPlainPrefix.contains("__REPLACE") {
            XCTFail(
                """
                Golden constants are placeholders. Update ExpectedDurov in this file:

                  static let postCount: Int = \(result.posts.count)
                  static let firstPostID: String = "\(first.id)"
                  static let firstPostPlainPrefix: String = \(asSwiftLiteral(actualPrefix))
                """
            )
            return
        }

        // Post count: should be 20. t.me/s/<channel> returns 20 posts
        // per page; a different number means either selector drift or
        // a smaller fixture. Update only after re-capturing.
        XCTAssertEqual(
            result.posts.count,
            ExpectedDurov.postCount,
            "durov fixture post count drifted — re-capture or fix parser"
        )

        XCTAssertEqual(
            first.id,
            ExpectedDurov.firstPostID,
            "First post id changed; refresh fixture or check parser"
        )

        XCTAssertTrue(
            first.plainText.hasPrefix(ExpectedDurov.firstPostPlainPrefix),
            """
            First post plain-text prefix drifted.
              expected prefix: \(ExpectedDurov.firstPostPlainPrefix)
              actual prefix:   \(actualPrefix)
            """
        )
    }

    /// Encodes a string as a valid Swift double-quoted literal so the
    /// failure message in `testGoldenDurov` produces a paste-ready
    /// constant for the maintainer.
    private func asSwiftLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        out += "\""
        return out
    }

    // MARK: - Breadth fixtures
    //
    // These re-capture occasionally (channels post new content), so we
    // only assert structural invariants — not exact ids or counts.

    func testTelegramFixtureHasParseableStructure() throws {
        try assertWellFormed(named: "telegram")
    }

    func testBBCPersianFixtureHasParseableStructure() throws {
        try assertWellFormed(named: "bbcpersian")
    }

    func testTGInfoEnFixtureHasParseableStructure() throws {
        try assertWellFormed(named: "tginfoen")
    }

    // MARK: - Cross-cutting invariants

    /// Every fixture must produce media URLs already routed through the
    /// `.translate.goog` proxy. A raw `cdn4.telesco.pe` (or any other
    /// Telegram CDN host) leaking through means `TelegramURLRewriter`
    /// is no longer being invoked — DPI-blocked URLs would reach the
    /// image pipeline on Iran-side users.
    func testNoRawTelegramCDNHostsLeakAcrossAllFixtures() throws {
        for name in Self.allFixtureNames {
            let result = try parseFixture(named: name)
            assertNoRawCDNHosts(in: result, fixture: name)
        }
    }

    func testEveryPostHasIDAndPermalinkAcrossAllFixtures() throws {
        for name in Self.allFixtureNames {
            let result = try parseFixture(named: name)
            XCTAssertGreaterThan(
                result.posts.count, 0,
                "fixture \(name) parsed zero posts"
            )
            for post in result.posts {
                XCTAssertFalse(
                    post.id.isEmpty,
                    "post in \(name) has empty id"
                )
                XCTAssertNotNil(
                    post.permalink,
                    "post \(post.id) in \(name) has nil permalink"
                )
                if let permalink = post.permalink {
                    XCTAssertTrue(
                        permalink.absoluteString.hasPrefix("https://t.me/"),
                        "post \(post.id) permalink not under t.me: <\(permalink.absoluteString)>"
                    )
                }
            }
        }
    }

    func testAtLeastOnePostHasNonEmptyPlainTextAcrossAllFixtures() throws {
        for name in Self.allFixtureNames {
            let result = try parseFixture(named: name)
            let nonEmpty = result.posts.contains { !$0.plainText.isEmpty }
            XCTAssertTrue(
                nonEmpty,
                "fixture \(name) had no posts with non-empty plainText — parser likely lost the .tgme_widget_message_text selector"
            )
        }
    }

    /// Locks in the `<br>` → `\n` fix. SwiftSoup's `.text()` collapses every
    /// line break into a single space; multi-paragraph posts then read as
    /// one giant blob. At least one post somewhere across the four fixtures
    /// should contain a real newline if the fix is in place.
    func testMultiLinePostsPreserveLineBreaksAcrossAllFixtures() throws {
        var anyMultiLine = false
        for name in Self.allFixtureNames {
            let result = try parseFixture(named: name)
            if result.posts.contains(where: { $0.plainText.contains("\n") }) {
                anyMultiLine = true
                break
            }
        }
        XCTAssertTrue(
            anyMultiLine,
            "no post in any fixture has a newline in plainText — `<br>` handling likely regressed"
        )
    }

    /// Locks in the reaction-emoji fix. If a fixture has reactions at all,
    /// every reaction must have a non-empty emoji glyph (standard, paid, or
    /// custom-with-fallback). An empty emoji means we hit a Telegram shape
    /// the parser doesn't recognise.
    func testReactionsAlwaysCarryAnEmojiGlyphAcrossAllFixtures() throws {
        for name in Self.allFixtureNames {
            let result = try parseFixture(named: name)
            for post in result.posts {
                for reaction in post.reactions {
                    XCTAssertFalse(
                        reaction.emoji.isEmpty,
                        "fixture \(name), post \(post.id): reaction has empty emoji (count=\(reaction.count))"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private static let allFixtureNames = ["durov", "telegram", "bbcpersian", "tginfoen"]

    private func parseFixture(named name: String) throws -> HTMLPostParser.ParseResult {
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "html"),
            "Missing fixture \(name).html in test bundle. Drop the captured HTML into mac/PigeonTests/Fixtures/."
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        return try HTMLPostParser().parse(html, fallbackUsername: name)
    }

    private func assertWellFormed(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try parseFixture(named: name)
        XCTAssertGreaterThan(
            result.posts.count, 0,
            "fixture \(name) produced zero posts",
            file: file, line: line
        )
        let nonEmpty = result.posts.contains { !$0.plainText.isEmpty }
        XCTAssertTrue(
            nonEmpty,
            "fixture \(name) had no posts with non-empty plainText",
            file: file, line: line
        )
        for post in result.posts {
            XCTAssertFalse(
                post.id.isEmpty,
                "post in \(name) has empty id",
                file: file, line: line
            )
            XCTAssertNotNil(
                post.permalink,
                "post \(post.id) in \(name) has nil permalink",
                file: file, line: line
            )
        }
        assertNoRawCDNHosts(in: result, fixture: name, file: file, line: line)
    }

    /// Confirms no raw Telegram CDN hostnames slipped past
    /// `TelegramURLRewriter` for any media URL produced by the parser.
    /// Asserts on the asset and thumbnail URLs of every post's media.
    private func assertNoRawCDNHosts(
        in result: HTMLPostParser.ParseResult,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bannedHostSuffixes = [
            ".telesco.pe",
            ".cdn-telegram.org"
        ]

        func check(_ url: URL?, label: String, postID: String) {
            guard let url, let host = url.host?.lowercased() else { return }
            for banned in bannedHostSuffixes {
                if host.hasSuffix(banned) {
                    XCTFail(
                        "raw Telegram CDN host leaked through parser: \(label) for post \(postID) in \(fixture) is <\(url.absoluteString)> (host \(host))",
                        file: file, line: line
                    )
                }
            }
        }

        // Channel photo (string form).
        if let photoString = result.channel.photoURL,
           let url = URL(string: photoString),
           let host = url.host?.lowercased() {
            for banned in bannedHostSuffixes where host.hasSuffix(banned) {
                XCTFail(
                    "raw CDN host in channel photoURL for \(fixture): <\(photoString)>",
                    file: file, line: line
                )
            }
        }

        for post in result.posts {
            if let photo = post.authorPhotoURL,
               let url = URL(string: photo),
               let host = url.host?.lowercased() {
                for banned in bannedHostSuffixes where host.hasSuffix(banned) {
                    XCTFail(
                        "raw CDN host in authorPhotoURL for post \(post.id) in \(fixture): <\(photo)>",
                        file: file, line: line
                    )
                }
            }
            for media in post.media {
                check(media.assetURL, label: "media.assetURL", postID: post.id)
                check(media.thumbnailURL, label: "media.thumbnailURL", postID: post.id)
            }
        }
    }
}

// MARK: - Golden values
//
// Captured from `mac/PigeonTests/Fixtures/durov.html`. When the fixture
// is re-captured (Telegram channels post new content), update these
// three constants to match the new top post. Keep `firstPostPlainPrefix`
// short enough to be stable but long enough to detect parser drift in
// .tgme_widget_message_text extraction (~60 chars per the brief).
//
// The first run after re-capture will fail loudly on whichever value
// drifted — the failure message includes the actual prefix so you can
// paste it back here verbatim.
private enum ExpectedDurov {
    static let postCount: Int = 20
    static let firstPostID: String = "durov/481"
    static let firstPostPlainPrefix: String = "🇪🇺 The EU is trying to justify its push for more surveillance"
}

