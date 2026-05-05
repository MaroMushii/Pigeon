import SwiftUI

extension String {
    /// Returns `.rightToLeft` when at least 30% of the directional letters in
    /// the string fall in RTL Unicode blocks (Arabic, Hebrew, Syriac, Thaana,
    /// N'Ko, etc.). Bidi-neutral characters (digits, punctuation, emoji,
    /// whitespace) are excluded from the ratio so they don't dilute it on
    /// short Farsi posts that happen to contain a hashtag or a URL.
    var dominantWritingDirection: LayoutDirection {
        var rtl = 0
        var ltr = 0
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF,   // Hebrew
                 0x0600...0x06FF,   // Arabic
                 0x0700...0x074F,   // Syriac
                 0x0750...0x077F,   // Arabic Supplement
                 0x0780...0x07BF,   // Thaana
                 0x07C0...0x07FF,   // N'Ko
                 0x0800...0x08FF,   // Samaritan, Mandaic, Arabic Extended-A
                 0xFB1D...0xFB4F,   // Hebrew Presentation Forms
                 0xFB50...0xFDFF,   // Arabic Presentation Forms-A
                 0xFE70...0xFEFF:   // Arabic Presentation Forms-B
                rtl += 1
            case 0x0041...0x005A,   // A–Z
                 0x0061...0x007A,   // a–z
                 0x00C0...0x024F,   // Latin Supplement + Extended-A/B
                 0x0370...0x03FF,   // Greek
                 0x0400...0x052F,   // Cyrillic + Cyrillic Supplement
                 0x1E00...0x1EFF:   // Latin Extended Additional
                ltr += 1
            default:
                continue
            }
        }
        let total = rtl + ltr
        guard total > 0 else { return .leftToRight }
        return Double(rtl) / Double(total) >= 0.3 ? .rightToLeft : .leftToRight
    }
}
