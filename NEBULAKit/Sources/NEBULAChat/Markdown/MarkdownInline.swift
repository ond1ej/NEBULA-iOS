import Foundation
import SwiftUI
import Synchronization

/// Turns inline Markdown (paragraph / heading / table-cell text) into an `AttributedString` for SwiftUI `Text`.
///
/// - Bold, italic, strikethrough and `inline code` come from Foundation's CommonMark/GFM inline parser
///   (`.inlineOnlyPreservingWhitespace`); SwiftUI renders their presentation intents natively, inline code also gets
///   a subtle background.
/// - Links (including autolinked bare URLs such as `https://…`, `www.…` and e-mail addresses) stay tappable only for
///   `http`, `https` and `mailto`; every other scheme (`javascript:`, `data:`, `file:`, relative paths, …) becomes plain
///   text. Images are shown as their alt text.
/// - Raw HTML is never interpreted: tags and comments are kept as literal text.
///
/// Results are cached (LRU), so re-rendering unchanged blocks is a dictionary lookup.
public enum MarkdownInlineRenderer {
    private static let cache = Mutex(MarkdownLRU<String, AttributedString>(capacity: 2048, costLimit: 6_000_000))

    /// The styled text for an inline Markdown string (cached).
    public static func attributedString(_ markdown: String) -> AttributedString {
        if let hit = cache.withLock({ $0.value(for: markdown) }) { return hit }
        let rendered = render(markdown)
        cache.withLock { $0.insert(rendered, for: markdown, cost: markdown.utf8.count * 4 + 64) }
        return rendered
    }

    /// The visible characters of an inline Markdown string (markup removed).
    public static func plainText(_ markdown: String) -> String {
        String(attributedString(markdown).characters)
    }

    /// `true` for links that may be opened: `http` / `https` with a host, and `mailto`.
    public static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return !(url.host(percentEncoded: false) ?? "").isEmpty
        case "mailto":
            return url.absoluteString.utf8.count > "mailto:".utf8.count
        default:
            return false
        }
    }

    static func purgeCache() {
        cache.withLock { $0.removeAll() }
    }

    /// Uncached rendering.
    static func render(_ markdown: String) -> AttributedString {
        var source = markdown
        if source.unicodeScalars.contains("\u{2028}") {
            source = source.replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        guard needsParsing(source) else { return AttributedString(source) }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        var result = parsed
        for run in parsed.runs {
            let range = run.range
            if let url = run.link, !isAllowedLink(url) {
                result[range].link = nil
            }
            if run.imageURL != nil {
                result[range].imageURL = nil
            }
            if let intent = run.inlinePresentationIntent {
                var cleaned = intent
                // Raw HTML stays literal text: drop the HTML intent so nothing downstream ever treats it as markup.
                cleaned.remove(.inlineHTML)
                cleaned.remove(.blockHTML)
                if cleaned.contains(.code) {
                    result[range].backgroundColor = MarkdownPalette.inlineCodeBackground
                }
                if cleaned != intent {
                    result[range].inlinePresentationIntent = cleaned.isEmpty ? nil : cleaned
                }
            }
        }
        return result
    }

    /// Plain text without any character that could start inline markup, an entity, an escape or an autolink is
    /// returned as is (skips the parser for most short lines).
    private static func needsParsing(_ text: String) -> Bool {
        var previous: UInt8 = 0
        for byte in text.utf8 {
            switch byte {
            case Byte.star, Byte.underscore, Byte.tilde, Byte.backtick, Byte.lbracket, Byte.less, Byte.ampersand,
                 Byte.backslash, Byte.colon, Byte.at:
                return true
            case Byte.dot where previous == UInt8(ascii: "w"):
                return true
            default:
                previous = byte
            }
        }
        return false
    }
}
