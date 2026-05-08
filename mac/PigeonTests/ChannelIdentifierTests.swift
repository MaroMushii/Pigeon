import XCTest
@testable import Pigeon

final class ChannelIdentifierTests: XCTestCase {

    // MARK: - Valid forms

    func testBareUsername() {
        XCTAssertEqual(ChannelIdentifier.normalise("ircfspace"), "ircfspace")
    }

    func testAtPrefixStripped() {
        XCTAssertEqual(ChannelIdentifier.normalise("@ircfspace"), "ircfspace")
    }

    func testTMeSlashPath() {
        XCTAssertEqual(ChannelIdentifier.normalise("t.me/ircfspace"), "ircfspace")
    }

    func testHTTPSTMeURL() {
        XCTAssertEqual(ChannelIdentifier.normalise("https://t.me/ircfspace"), "ircfspace")
    }

    func testHTTPTMeURL() {
        XCTAssertEqual(ChannelIdentifier.normalise("http://t.me/ircfspace"), "ircfspace")
    }

    func testHTTPSTMeSlashSPath() {
        XCTAssertEqual(ChannelIdentifier.normalise("https://t.me/s/ircfspace"), "ircfspace")
    }

    // MARK: - Normalisation

    func testUppercaseIsLowercased() {
        XCTAssertEqual(ChannelIdentifier.normalise("@IRCFSPACE"), "ircfspace")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertEqual(ChannelIdentifier.normalise("  ircfspace  "), "ircfspace")
    }

    func testTrailingPathSegmentIsStripped() {
        // A URL with a post ID after the username — only the username matters.
        XCTAssertEqual(ChannelIdentifier.normalise("https://t.me/ircfspace/123"), "ircfspace")
    }

    func testQueryStringIsStripped() {
        XCTAssertEqual(ChannelIdentifier.normalise("https://t.me/ircfspace?foo=bar"), "ircfspace")
    }

    // MARK: - Invalid inputs → nil

    func testEmptyStringReturnsNil() {
        XCTAssertNil(ChannelIdentifier.normalise(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(ChannelIdentifier.normalise("   "))
    }

    func testTooShortUsernameReturnsNil() {
        // Regex requires [a-z][a-z0-9_]{3,30}[a-z0-9] — minimum 5 chars.
        XCTAssertNil(ChannelIdentifier.normalise("abcd"))
    }

    func testStartsWithDigitReturnsNil() {
        XCTAssertNil(ChannelIdentifier.normalise("1channel"))
    }

    func testContainsSpaceReturnsNil() {
        XCTAssertNil(ChannelIdentifier.normalise("bad channel"))
    }

    func testContainsHyphenReturnsNil() {
        XCTAssertNil(ChannelIdentifier.normalise("bad-channel"))
    }
}
