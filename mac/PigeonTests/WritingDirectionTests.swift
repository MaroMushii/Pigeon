import XCTest
import SwiftUI
@testable import Pigeon

final class WritingDirectionTests: XCTestCase {

    // MARK: - Unambiguous scripts

    func testPureArabicIsRTL() {
        // مهدي — four Arabic letters, all in U+0600-U+06FF.
        XCTAssertEqual("مهدي".dominantWritingDirection, .rightToLeft)
    }

    func testPureHebrewIsRTL() {
        // שלום — four Hebrew letters, all in U+0590-U+05FF.
        XCTAssertEqual("שלום".dominantWritingDirection, .rightToLeft)
    }

    func testPureLatinIsLTR() {
        XCTAssertEqual("Hello world".dominantWritingDirection, .leftToRight)
    }

    func testPureCyrillicIsLTR() {
        // Привет — Cyrillic block U+0400–U+052F.
        XCTAssertEqual("Привет".dominantWritingDirection, .leftToRight)
    }

    // MARK: - Neutral characters are excluded from the ratio

    func testDigitsAndEmojiAloneAreLTR() {
        // Bidi-neutral chars (digits, emoji, punctuation) must not count toward
        // either side. With zero directional letters the guard returns .leftToRight.
        XCTAssertEqual("1234 🎉 !@#".dominantWritingDirection, .leftToRight)
    }

    func testArabicWithDigitsAndEmojiIsStillRTL() {
        // Neutral chars don't dilute the ratio — "مهدي 123 🎉" is still fully Arabic.
        XCTAssertEqual("مهدي 123 🎉".dominantWritingDirection, .rightToLeft)
    }

    // MARK: - 30% threshold

    func testExactlyThirtyPercentRTLIsRTL() {
        // "مممabcdefg" = 3 RTL + 7 LTR = 3/10 = 0.30 — boundary value, rounds to RTL.
        XCTAssertEqual("مممabcdefg".dominantWritingDirection, .rightToLeft)
    }

    func testBelowThirtyPercentRTLIsLTR() {
        // "ممabcdefg" = 2 RTL + 7 LTR = 2/9 ≈ 0.222 → LTR.
        XCTAssertEqual("ممabcdefg".dominantWritingDirection, .leftToRight)
    }

    // MARK: - Edge cases

    func testEmptyStringIsLTR() {
        XCTAssertEqual("".dominantWritingDirection, .leftToRight)
    }

    func testMixedFarsiAndLatinURL() {
        // A realistic Farsi post that contains an embedded Latin URL — should
        // still read RTL since the body is dominated by Arabic-script letters.
        let text = "این یک متن فارسی است https://example.com"
        XCTAssertEqual(text.dominantWritingDirection, .rightToLeft)
    }
}
