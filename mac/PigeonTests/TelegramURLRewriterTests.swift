import XCTest
@testable import Pigeon

final class TelegramURLRewriterTests: XCTestCase {

    // MARK: - Host rewriting

    func testCDNHostIsRewritten() {
        let input = URL(string: "https://cdn4.telesco.pe/file/abc.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.host, "cdn4-telesco-pe.translate.goog")
    }

    func testCDNTelegramOrgIsRewritten() {
        let input = URL(string: "https://cdn-telegram.org/file/abc.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.host, "cdn-telegram-org.translate.goog")
    }

    func testTelegramOrgIsRewritten() {
        let input = URL(string: "https://telegram.org/img/emoji.png")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.host, "telegram-org.translate.goog")
    }

    func testSubdomainOfProxiedHostIsRewritten() {
        let input = URL(string: "https://cdn1.telesco.pe/file/image.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.host, "cdn1-telesco-pe.translate.goog")
    }

    // MARK: - Query parameters

    func testTranslateQueryParamsAreAppended() {
        let input = URL(string: "https://cdn4.telesco.pe/file/abc.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        let items = URLComponents(url: result!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "_x_tr_sl", value: "auto")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "_x_tr_tl", value: "fa")))
    }

    func testExistingQueryParamsArePreserved() {
        let input = URL(string: "https://cdn4.telesco.pe/file/abc.jpg?size=m")!
        let result = TelegramURLRewriter.rewrite(input)

        let items = URLComponents(url: result!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "size", value: "m")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "_x_tr_sl", value: "auto")))
    }

    // MARK: - Path and scheme preservation

    func testPathIsPreservedAfterRewrite() {
        let input = URL(string: "https://cdn4.telesco.pe/file/long/path/image.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.path(), "/file/long/path/image.jpg")
    }

    func testProtocolRelativeURLIsPromotedToHTTPS() {
        let input = URL(string: "//cdn4.telesco.pe/file/abc.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result?.scheme, "https")
        XCTAssertEqual(result?.host, "cdn4-telesco-pe.translate.goog")
    }

    // MARK: - Pass-through for non-proxied hosts

    func testRawGitHubURLPassesThroughUnchanged() {
        let input = URL(string: "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export/channels/durov/media/abc.jpg")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result, input)
    }

    func testDirectTmeLinkPassesThroughUnchanged() {
        // t.me is intentionally not proxied — the app never opens t.me directly;
        // only canonical CDN media URLs need the rewrite.
        let input = URL(string: "https://t.me/durov/123")!
        let result = TelegramURLRewriter.rewrite(input)

        XCTAssertEqual(result, input)
    }

    func testNilInputReturnsNil() {
        XCTAssertNil(TelegramURLRewriter.rewrite(nil))
    }

    // MARK: - isProxiedHost

    func testTranslateGoogHostIsRecognised() {
        XCTAssertTrue(TelegramURLRewriter.isProxiedHost("cdn4-telesco-pe.translate.goog"))
    }

    func testNonTranslateGoogHostIsNotRecognised() {
        XCTAssertFalse(TelegramURLRewriter.isProxiedHost("cdn4.telesco.pe"))
        XCTAssertFalse(TelegramURLRewriter.isProxiedHost("raw.githubusercontent.com"))
    }
}
