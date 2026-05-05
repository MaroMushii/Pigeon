import Foundation
import SwiftSoup
import SwiftUI

/// Walks a post's HTML body and produces a SwiftUI `AttributedString` with
/// proper inline styles (bold, italic, links, code, line breaks). We avoid
/// `NSAttributedString(data:options:)` because it spins up a full HTML
/// document parser per call and is very slow.
struct AttributedHTMLBuilder {
    /// Memoizes parse results keyed on the raw HTML string. SwiftUI calls
    /// `build(from:)` on every `PostCard.body` re-evaluation, and any
    /// observable mutation on any visible post triggers all visible cards to
    /// re-render. Without a cache that means re-parsing ~20 HTML blobs through
    /// SwiftSoup on the main thread per tick. NSCache is thread-safe and
    /// auto-evicts under memory pressure, which is exactly what we want.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedAttributed> = {
        let cache = NSCache<NSString, CachedAttributed>()
        cache.countLimit = 500
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    func build(from html: String) -> AttributedString {
        let key = html as NSString
        if let hit = Self.cache.object(forKey: key) {
            return hit.value
        }
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else {
            return AttributedString(html)
        }
        var out = AttributedString()
        append(node: body, into: &out, inheriting: .init())
        Self.cache.setObject(CachedAttributed(out), forKey: key, cost: html.utf8.count)
        return out
    }

    private struct InheritedStyle {
        var bold = false
        var italic = false
        var monospaced = false
        var link: URL?
    }

    private func append(node: Node, into out: inout AttributedString, inheriting style: InheritedStyle) {
        for child in node.getChildNodes() {
            if let tn = child as? TextNode {
                let text = tn.text()
                guard !text.isEmpty else { continue }
                var run = AttributedString(text)
                apply(style, to: &run)
                out.append(run)
            } else if let el = child as? Element {
                let tag = el.tagName().lowercased()
                switch tag {
                case "br":
                    out.append(AttributedString("\n"))
                case "a":
                    var nested = style
                    nested.link = (try? el.attr("href")).flatMap(URL.init(string:))
                    append(node: el, into: &out, inheriting: nested)
                case "b", "strong":
                    var nested = style; nested.bold = true
                    append(node: el, into: &out, inheriting: nested)
                case "i", "em":
                    var nested = style; nested.italic = true
                    append(node: el, into: &out, inheriting: nested)
                case "code", "pre", "tt":
                    var nested = style; nested.monospaced = true
                    append(node: el, into: &out, inheriting: nested)
                case "p", "div":
                    if !out.characters.isEmpty {
                        out.append(AttributedString("\n\n"))
                    }
                    append(node: el, into: &out, inheriting: style)
                case "blockquote":
                    if !out.characters.isEmpty {
                        out.append(AttributedString("\n\n"))
                    }
                    var nested = style; nested.italic = true
                    append(node: el, into: &out, inheriting: nested)
                default:
                    append(node: el, into: &out, inheriting: style)
                }
            }
        }
    }

    private func apply(_ style: InheritedStyle, to run: inout AttributedString) {
        var intents: InlinePresentationIntent = []
        if style.bold { intents.insert(.stronglyEmphasized) }
        if style.italic { intents.insert(.emphasized) }
        if style.monospaced { intents.insert(.code) }
        if !intents.isEmpty {
            run.inlinePresentationIntent = intents
        }
        if let link = style.link {
            run.link = link
            run.foregroundColor = .accentColor
            run.underlineStyle = .single
        }
    }
}

/// NSCache requires NSObject values, so wrap the Swift `AttributedString` in
/// a reference-typed box.
private final class CachedAttributed: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}

