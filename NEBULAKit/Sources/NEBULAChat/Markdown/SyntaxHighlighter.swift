import Foundation
import SwiftUI
import Synchronization

/// A language the syntax highlighter understands.
public enum SyntaxLanguage: String, CaseIterable, Hashable, Sendable {
    case swift, python, javascript, typescript, tsx, jsx, json, bash, html, xml, css, sql, go, rust, java, kotlin, c,
         cpp, yaml, diff

    /// Maps a code fence info string (`swift`, `py`, `ts`, `sh`, `zsh`, `yml`, `c++`, `patch`, …) to a language.
    /// Unknown identifiers return `nil` (the code is then shown without highlighting).
    public init?(identifier: String) {
        switch identifier.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift": self = .swift
        case "python", "py", "python3", "py3", "pyw", "ipython": self = .python
        case "javascript", "js", "mjs", "cjs", "node", "nodejs": self = .javascript
        case "typescript", "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "jsx": self = .jsx
        case "json", "jsonc", "json5", "geojson", "jsonl", "webmanifest": self = .json
        case "bash", "sh", "zsh", "shell", "console", "shellsession", "ksh", "terminal", "command": self = .bash
        case "html", "htm", "xhtml", "vue", "svelte": self = .html
        case "xml", "svg", "plist", "xsd", "xsl", "xslt", "rss", "atom", "xaml", "csproj", "storyboard": self = .xml
        case "css", "scss", "less", "postcss": self = .css
        case "sql", "postgres", "postgresql", "psql", "pgsql", "mysql", "sqlite", "plsql", "tsql", "mssql": self = .sql
        case "go", "golang": self = .go
        case "rust", "rs": self = .rust
        case "java": self = .java
        case "kotlin", "kt", "kts": self = .kotlin
        case "c", "h", "objc", "objective-c", "objectivec": self = .c
        case "cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx", "h++", "ino", "objective-c++", "objc++", "mm":
            self = .cpp
        case "yaml", "yml": self = .yaml
        case "diff", "patch", "udiff", "git-diff": self = .diff
        default: return nil
        }
    }

    /// Human-readable name for the code block header.
    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .jsx: "JSX"
        case .json: "JSON"
        case .bash: "Shell"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .sql: "SQL"
        case .go: "Go"
        case .rust: "Rust"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .c: "C"
        case .cpp: "C++"
        case .yaml: "YAML"
        case .diff: "Diff"
        }
    }
}

/// The category of a highlighted range.
public enum SyntaxTokenKind: String, CaseIterable, Hashable, Sendable {
    case keyword, string, number, comment, type, function, property, tag, attribute, variable, meta
    /// `+` line of a diff.
    case inserted
    /// `-` line of a diff.
    case deleted
}

/// A highlighted range of code. Ranges are UTF-8 byte offsets, sorted and non-overlapping; text between tokens is
/// plain.
public struct SyntaxToken: Hashable, Sendable {
    public var kind: SyntaxTokenKind
    public var range: Range<Int>

    public init(kind: SyntaxTokenKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// A lightweight, single-pass syntax highlighter (no regular expressions): keywords, strings, numbers, comments,
/// types, functions and language-specific extras (attributes, tags, properties, variables, diff lines).
///
/// Tokenizing 200 lines takes well under 2 ms in release builds. Building the colored `AttributedString` costs more
/// (Foundation attribute updates), so ``highlight(_:language:)`` caches results and ``CodeBlockView`` highlights
/// everything but small blocks off the main thread.
public enum SyntaxHighlighter {
    private struct Key: Hashable {
        var language: SyntaxLanguage
        var code: String
    }

    private static let cache = Mutex(MarkdownLRU<Key, AttributedString>(capacity: 256, costLimit: 8_000_000))

    /// Tokens for `code` in `language`.
    public static func tokens(in code: String, language: SyntaxLanguage) -> [SyntaxToken] {
        var lexer = SyntaxLexer(bytes: Array(code.utf8))
        lexer.lex(language)
        return lexer.tokens
    }

    /// The highlighted code (cached). An unknown or missing language returns the code without colors.
    public static func highlight(_ code: String, language: String?) -> AttributedString {
        guard let language = language.flatMap(SyntaxLanguage.init(identifier:)) else { return AttributedString(code) }
        return highlight(code, language: language)
    }

    /// The highlighted code (cached).
    public static func highlight(_ code: String, language: SyntaxLanguage) -> AttributedString {
        let key = Key(language: language, code: code)
        if let hit = cache.withLock({ $0.value(for: key) }) { return hit }
        let result = attributedString(code, tokens: tokens(in: code, language: language))
        cache.withLock { $0.insert(result, for: key, cost: code.utf8.count * 4 + 64) }
        return result
    }

    /// A cached result, without computing one.
    public static func cachedHighlight(_ code: String, language: String?) -> AttributedString? {
        guard let language = language.flatMap(SyntaxLanguage.init(identifier:)) else { return AttributedString(code) }
        return cache.withLock { $0.value(for: Key(language: language, code: code)) }
    }

    static func purgeCache() {
        cache.withLock { $0.removeAll() }
    }

    /// Applies token colors to `code`. Ranges are converted from the code's (O(1)) UTF-8 string indices into the
    /// attributed string afresh for every token, so no index is reused across mutations.
    static func attributedString(_ code: String, tokens: [SyntaxToken]) -> AttributedString {
        var result = AttributedString(code)
        guard !tokens.isEmpty else { return result }
        let utf8 = code.utf8
        let count = utf8.count
        var offset = 0
        for token in tokens where token.range.lowerBound >= offset && token.range.upperBound <= count {
            let lower = utf8.index(utf8.startIndex, offsetBy: token.range.lowerBound)
            let upper = utf8.index(lower, offsetBy: token.range.count)
            guard let range = Range(lower..<upper, in: result) else { continue }
            result[range].foregroundColor = MarkdownPalette.color(for: token.kind)
            if let background = MarkdownPalette.background(for: token.kind) {
                result[range].backgroundColor = background
            }
            offset = token.range.upperBound
        }
        return result
    }
}

// MARK: - Lexer

/// The tokenizer. Works on UTF-8 bytes; all delimiters are ASCII, so token boundaries always fall on scalar
/// boundaries (bytes >= 0x80 are treated as identifier characters and never split).
struct SyntaxLexer {
    let b: [UInt8]
    let start: Int
    let end: Int
    private(set) var tokens: [SyntaxToken] = []

    init(bytes: [UInt8], range: Range<Int>? = nil) {
        b = bytes
        start = range?.lowerBound ?? 0
        end = range?.upperBound ?? bytes.count
        tokens.reserveCapacity(max(16, (end - start) / 10))
    }

    mutating func lex(_ language: SyntaxLanguage) {
        switch language {
        case .json: lexJSON()
        case .bash: lexBash()
        case .yaml: lexYAML()
        case .html: lexMarkup(html: true)
        case .xml: lexMarkup(html: false)
        case .css: lexCSS()
        case .diff: lexDiff()
        default: lexCode(CodeSpec.spec(for: language))
        }
    }

    // MARK: Helpers

    @inline(__always) func at(_ i: Int) -> UInt8 { i < end && i >= start ? b[i] : 0 }

    @inline(__always) static func isDigit(_ c: UInt8) -> Bool { c >= Byte.zero && c <= Byte.nine }
    @inline(__always) static func isUpper(_ c: UInt8) -> Bool { c >= Byte.upperA && c <= Byte.upperZ }
    @inline(__always) static func isLetter(_ c: UInt8) -> Bool {
        (c >= Byte.lowerA && c <= Byte.lowerZ) || (c >= Byte.upperA && c <= Byte.upperZ)
    }
    @inline(__always) static func isIdentStart(_ c: UInt8) -> Bool { isLetter(c) || c == Byte.underscore || c >= 0x80 }
    @inline(__always) static func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }
    @inline(__always) static func isSpace(_ c: UInt8) -> Bool {
        c == Byte.space || c == Byte.tab || c == Byte.carriageReturn
    }
    @inline(__always) static func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= Byte.lowerA && c <= UInt8(ascii: "f")) || (c >= Byte.upperA && c <= UInt8(ascii: "F"))
    }

    mutating func emit(_ kind: SyntaxTokenKind, _ lower: Int, _ upper: Int) {
        let upper = min(upper, end)
        guard upper > lower else { return }
        if let last = tokens.last, last.kind == kind, last.range.upperBound <= lower,
           kind != .inserted, kind != .deleted {
            // Merge with the previous token of the same kind when only spaces separate them (fewer runs).
            var gapIsSpace = true
            for i in last.range.upperBound..<lower where b[i] != Byte.space && b[i] != Byte.tab {
                gapIsSpace = false
                break
            }
            if gapIsSpace {
                tokens[tokens.count - 1].range = last.range.lowerBound..<upper
                return
            }
        }
        tokens.append(SyntaxToken(kind: kind, range: lower..<upper))
    }

    func endOfLine(_ i: Int) -> Int {
        var j = i
        while j < end && b[j] != Byte.newline { j += 1 }
        return j
    }

    func starts(_ i: Int, with literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard i + count <= end else { return false }
        return literal.withUTF8Buffer { pattern in
            for k in 0..<count where b[i + k] != pattern[k] { return false }
            return true
        }
    }

    func startsCaseInsensitive(_ i: Int, with lowercased: [UInt8]) -> Bool {
        guard i + lowercased.count <= end else { return false }
        for k in 0..<lowercased.count {
            var c = b[i + k]
            if Self.isUpper(c) { c += 32 }
            if c != lowercased[k] { return false }
        }
        return true
    }

    func find(_ literal: StaticString, from i: Int) -> Int? {
        var j = i
        while j < end {
            if starts(j, with: literal) { return j }
            j += 1
        }
        return nil
    }

    func scanIdentifier(_ i: Int, extra: UInt8 = 0, extra2: UInt8 = 0) -> Int {
        var j = i
        while j < end, Self.isIdentPart(b[j]) || (extra != 0 && b[j] == extra) || (extra2 != 0 && b[j] == extra2) {
            j += 1
        }
        return j
    }

    func word(_ lower: Int, _ upper: Int) -> String {
        String(decoding: b[lower..<upper], as: UTF8.self)
    }

    /// A quoted string starting after the opening quote; returns the index after the closing quote.
    func scanString(from i: Int, quote: UInt8, multiline: Bool, escapes: Bool = true) -> Int {
        var j = i
        while j < end {
            let c = b[j]
            if escapes && c == Byte.backslash {
                j += 2
                continue
            }
            if c == quote { return j + 1 }
            if c == Byte.newline && !multiline { return j }
            j += 1
        }
        return end
    }

    func scanTripleString(from i: Int, quote: UInt8) -> Int {
        var j = i
        while j < end {
            if b[j] == Byte.backslash {
                j += 2
                continue
            }
            if b[j] == quote && at(j + 1) == quote && at(j + 2) == quote { return j + 3 }
            j += 1
        }
        return end
    }

    func scanBlockComment(from i: Int, nested: Bool) -> Int {
        var depth = 1
        var j = i
        while j + 1 < end {
            if b[j] == Byte.star && b[j + 1] == Byte.slash {
                depth -= 1
                j += 2
                if depth == 0 { return j }
                continue
            }
            if nested && b[j] == Byte.slash && b[j + 1] == Byte.star {
                depth += 1
                j += 2
                continue
            }
            j += 1
        }
        return end
    }

    func scanNumber(_ i: Int) -> Int {
        var j = i
        let next = at(j + 1)
        if b[j] == Byte.zero,
           next == UInt8(ascii: "x") || next == UInt8(ascii: "X") || next == UInt8(ascii: "b")
            || next == UInt8(ascii: "B") || next == UInt8(ascii: "o") || next == UInt8(ascii: "O") {
            j += 2
            while j < end, Self.isIdentPart(b[j]) { j += 1 }
            return j
        }
        while j < end {
            let c = b[j]
            if Self.isIdentPart(c) {
                j += 1
            } else if c == Byte.dot && Self.isDigit(at(j + 1)) {
                j += 1
            } else if (c == Byte.plus || c == Byte.dash), j > i, b[j - 1] == UInt8(ascii: "e")
                        || b[j - 1] == UInt8(ascii: "E"), Self.isDigit(at(j + 1)), Self.isDigit(b[i]) {
                j += 1
            } else {
                break
            }
        }
        return j
    }

    func nextNonSpace(_ i: Int) -> UInt8 {
        var j = i
        while j < end, Self.isSpace(b[j]) { j += 1 }
        return at(j)
    }

    // MARK: Generic code (C family, Swift, Python, JS/TS, Go, Rust, Java, Kotlin, SQL)

    mutating func lexCode(_ spec: CodeSpec) {
        var i = start
        var lineStart = true
        var previous: UInt8 = 0            // last significant byte
        var previousWasKeyword = false
        var expect: SyntaxTokenKind?       // a declaration keyword names the next identifier
        while i < end {
            let c = b[i]
            if c == Byte.newline {
                lineStart = true
                i += 1
                continue
            }
            if Self.isSpace(c) {
                i += 1
                continue
            }
            let atLineStart = lineStart
            lineStart = false

            // Comments.
            if spec.hashComments && c == Byte.hash {
                let e = endOfLine(i)
                emit(.comment, i, e)
                i = e
                continue
            }
            if spec.dashComments && c == Byte.dash && at(i + 1) == Byte.dash {
                let e = endOfLine(i)
                emit(.comment, i, e)
                i = e
                continue
            }
            if spec.slashComments && c == Byte.slash {
                if at(i + 1) == Byte.slash {
                    let e = endOfLine(i)
                    emit(.comment, i, e)
                    i = e
                    continue
                }
                if at(i + 1) == Byte.star {
                    let e = scanBlockComment(from: i + 2, nested: spec.nestedComments)
                    emit(.comment, i, e)
                    i = e
                    continue
                }
            }

            // Directives and attributes.
            if spec.preprocessor && c == Byte.hash && atLineStart {
                var j = i + 1
                while j < end, Self.isSpace(b[j]) { j += 1 }
                j = scanIdentifier(j)
                emit(.meta, i, j)
                // `#include <stdio.h>`
                var k = j
                while k < end, Self.isSpace(b[k]) { k += 1 }
                if at(k) == Byte.less {
                    var e = k + 1
                    while e < end, b[e] != Byte.greater, b[e] != Byte.newline { e += 1 }
                    if at(e) == Byte.greater {
                        emit(.string, k, e + 1)
                        j = e + 1
                    }
                }
                i = j
                previous = Byte.hash
                continue
            }
            if spec.hashDirectives && c == Byte.hash && Self.isIdentStart(at(i + 1)) {
                let e = scanIdentifier(i + 1)
                emit(.meta, i, e)
                i = e
                previous = Byte.hash
                continue
            }
            if spec.rust && c == Byte.hash
                && (at(i + 1) == Byte.lbracket || (at(i + 1) == Byte.bang && at(i + 2) == Byte.lbracket)) {
                var j = i + 1
                var depth = 0
                while j < end {
                    if b[j] == Byte.lbracket { depth += 1 }
                    if b[j] == Byte.rbracket {
                        depth -= 1
                        if depth == 0 {
                            j += 1
                            break
                        }
                    }
                    if b[j] == Byte.newline { break }
                    j += 1
                }
                emit(.meta, i, j)
                i = j
                continue
            }
            if spec.annotations && c == Byte.at && Self.isIdentStart(at(i + 1)) {
                var e = scanIdentifier(i + 1)
                while at(e) == Byte.dot && Self.isIdentStart(at(e + 1)) { e = scanIdentifier(e + 1) }
                emit(.meta, i, e)
                i = e
                previous = Byte.at
                continue
            }

            // Strings.
            if spec.tripleQuotes && (c == Byte.quote || (c == Byte.apostrophe && spec.singleQuoteStrings))
                && at(i + 1) == c && at(i + 2) == c {
                let e = scanTripleString(from: i + 3, quote: c)
                emit(.string, i, e)
                i = e
                previous = c
                continue
            }
            if spec.backtickStrings && c == Byte.backtick {
                let e = scanString(from: i + 1, quote: Byte.backtick, multiline: true, escapes: spec.backtickEscapes)
                emit(.string, i, e)
                i = e
                previous = c
                continue
            }
            if c == Byte.apostrophe && spec.rust {
                // Char literal ('a', '\n', 'é') or lifetime ('a, 'static).
                if at(i + 1) == Byte.backslash {
                    let e = scanString(from: i + 1, quote: Byte.apostrophe, multiline: false)
                    emit(.string, i, e)
                    i = e
                } else if at(i + 2) == Byte.apostrophe || (at(i + 1) >= 0x80 && charLiteralEnd(i) != nil) {
                    let e = at(i + 2) == Byte.apostrophe ? i + 3 : charLiteralEnd(i)!
                    emit(.string, i, e)
                    i = e
                } else if Self.isIdentStart(at(i + 1)) {
                    let e = scanIdentifier(i + 1)
                    emit(.meta, i, e)
                    i = e
                } else {
                    i += 1
                }
                previous = Byte.apostrophe
                continue
            }
            if c == Byte.quote || (c == Byte.apostrophe && spec.singleQuoteStrings) {
                let e = scanString(from: i + 1, quote: c, multiline: spec.multilineStrings,
                                   escapes: !spec.doubledQuoteEscapes)
                var e2 = e
                if spec.doubledQuoteEscapes {
                    // SQL: '' inside a string is an escaped quote.
                    while at(e2) == c {
                        e2 = scanString(from: e2 + 1, quote: c, multiline: true, escapes: false)
                    }
                }
                emit(.string, i, e2)
                i = e2
                previous = c
                continue
            }

            // JSX / TSX tags.
            if spec.jsx && c == Byte.less && (Self.isLetter(at(i + 1)) || at(i + 1) == Byte.slash
                                             || at(i + 1) == Byte.greater)
                && (previousWasKeyword || previous == 0 || "(,=:?&|{}[;!>".utf8.contains(previous)) {
                i = lexJSXTag(i)
                previous = Byte.greater
                previousWasKeyword = false
                continue
            }

            // Numbers.
            if Self.isDigit(c) || (c == Byte.dot && Self.isDigit(at(i + 1)) && !Self.isIdentPart(previous)) {
                let e = scanNumber(i)
                emit(.number, i, e)
                i = e
                previous = Byte.zero
                previousWasKeyword = false
                continue
            }

            // Identifiers.
            if Self.isIdentStart(c) || (spec.dollarIdentifiers && c == Byte.dollar) {
                var e = scanIdentifier(i, extra: spec.dollarIdentifiers ? Byte.dollar : 0)
                // String prefixes: Python f"…" r'…' b"…", Rust r"…" r#"…"# b"…".
                if spec.stringPrefixes, e - i <= 2, let quoteEnd = prefixedStringEnd(i, e, spec: spec) {
                    emit(.string, i, quoteEnd)
                    i = quoteEnd
                    previous = Byte.quote
                    previousWasKeyword = false
                    continue
                }
                let text = word(i, e)
                let lookup = spec.caseInsensitive ? text.lowercased() : text
                var kind: SyntaxTokenKind?
                if spec.rust && at(e) == Byte.bang && at(e + 1) != Byte.equals {
                    e += 1
                    kind = .function
                } else if spec.keywords.contains(lookup) {
                    kind = .keyword
                } else if let expected = expect {
                    kind = expected
                } else if spec.types.contains(lookup) {
                    kind = .type
                } else if at(e) == Byte.lparen {
                    kind = .function
                } else if spec.capitalizedTypes && Self.isUpper(c) {
                    kind = .type
                }
                if let kind { emit(kind, i, e) }
                expect = nil
                if kind == .keyword {
                    if spec.functionKeywords.contains(lookup) {
                        expect = .function
                    } else if spec.typeKeywords.contains(lookup) {
                        expect = .type
                    }
                }
                previousWasKeyword = kind == .keyword
                previous = b[e - 1]
                i = e
                continue
            }

            // Punctuation.
            if c != Byte.dot && c != Byte.star && c != Byte.less && c != Byte.ampersand { expect = nil }
            previous = c
            previousWasKeyword = false
            i += 1
        }
    }

    /// End of a Rust char literal whose first character is non-ASCII ('é'), or `nil`.
    private func charLiteralEnd(_ i: Int) -> Int? {
        var j = i + 1
        while j < end && j <= i + 5 {
            if b[j] == Byte.apostrophe { return j + 1 }
            if b[j] < 0x80 && j > i + 1 { return nil }
            j += 1
        }
        return nil
    }

    private func prefixedStringEnd(_ i: Int, _ e: Int, spec: CodeSpec) -> Int? {
        guard e < end else { return nil }
        for k in i..<e {
            switch b[k] {
            case UInt8(ascii: "r"), UInt8(ascii: "R"), UInt8(ascii: "b"), UInt8(ascii: "B"): continue
            case UInt8(ascii: "f"), UInt8(ascii: "F"), UInt8(ascii: "u"), UInt8(ascii: "U"):
                if spec.rust { return nil }
            default: return nil
            }
        }
        let q = b[e]
        let raw = b[i..<e].contains(UInt8(ascii: "r")) || b[i..<e].contains(UInt8(ascii: "R"))
        if spec.rust && raw && q == Byte.hash {
            // r#"…"#
            var hashes = 0
            var j = e
            while at(j) == Byte.hash {
                hashes += 1
                j += 1
            }
            guard at(j) == Byte.quote else { return nil }
            j += 1
            while j < end {
                if b[j] == Byte.quote {
                    var k = j + 1
                    var count = 0
                    while count < hashes && at(k) == Byte.hash {
                        count += 1
                        k += 1
                    }
                    if count == hashes { return k }
                }
                j += 1
            }
            return end
        }
        guard q == Byte.quote || (q == Byte.apostrophe && spec.singleQuoteStrings) else { return nil }
        if spec.tripleQuotes && at(e + 1) == q && at(e + 2) == q {
            return scanTripleString(from: e + 3, quote: q)
        }
        return scanString(from: e + 1, quote: q, multiline: spec.rust, escapes: !raw)
    }

    /// `<Tag attr="x" {...}>` / `</Tag>` inside JSX; returns the index after the tag.
    private mutating func lexJSXTag(_ i: Int) -> Int {
        var j = i + 1
        if at(j) == Byte.slash { j += 1 }
        let nameStart = j
        j = scanIdentifier(j, extra: Byte.dot, extra2: Byte.dash)
        emit(.tag, nameStart, j)
        while j < end {
            let c = b[j]
            if c == Byte.greater { return j + 1 }
            if c == Byte.slash && at(j + 1) == Byte.greater { return j + 2 }
            if c == Byte.quote || c == Byte.apostrophe {
                let e = scanString(from: j + 1, quote: c, multiline: true, escapes: false)
                emit(.string, j, e)
                j = e
                continue
            }
            if c == Byte.lbrace {
                var depth = 0
                while j < end {
                    if b[j] == Byte.lbrace { depth += 1 }
                    if b[j] == Byte.rbrace {
                        depth -= 1
                        if depth == 0 {
                            j += 1
                            break
                        }
                    }
                    j += 1
                }
                continue
            }
            if Self.isIdentStart(c) {
                let e = scanIdentifier(j, extra: Byte.dash, extra2: Byte.colon)
                emit(.attribute, j, e)
                j = e
                continue
            }
            j += 1
        }
        return j
    }

    // MARK: JSON

    mutating func lexJSON() {
        var i = start
        while i < end {
            let c = b[i]
            if c == Byte.quote || c == Byte.apostrophe {
                let e = scanString(from: i + 1, quote: c, multiline: false)
                emit(nextNonSpace(e) == Byte.colon ? .property : .string, i, e)
                i = e
            } else if Self.isDigit(c) || (c == Byte.dash && (Self.isDigit(at(i + 1)) || at(i + 1) == Byte.dot)) {
                let e = scanNumber(c == Byte.dash ? i + 1 : i)
                emit(.number, i, e)
                i = e
            } else if c == Byte.slash && at(i + 1) == Byte.slash {
                let e = endOfLine(i)
                emit(.comment, i, e)
                i = e
            } else if c == Byte.slash && at(i + 1) == Byte.star {
                let e = scanBlockComment(from: i + 2, nested: false)
                emit(.comment, i, e)
                i = e
            } else if Self.isIdentStart(c) {
                let e = scanIdentifier(i)
                switch word(i, e) {
                case "true", "false", "null", "NaN", "Infinity": emit(.keyword, i, e)
                default: if nextNonSpace(e) == Byte.colon { emit(.property, i, e) }
                }
                i = e
            } else {
                i += 1
            }
        }
    }

    // MARK: Shell

    private static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
        "return", "local", "export", "readonly", "declare", "typeset", "unset", "shift", "exit", "break", "continue",
        "select", "time", "source", "alias", "set", "trap", "eval", "exec", "let",
    ]
    private static let bashCommandKeywords: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "time", "exec", "eval", "!",
    ]

    mutating func lexBash() {
        var i = start
        var command = true                // the next word is a command name
        var expectName: SyntaxTokenKind?  // after `function` (a function name) / `for` (a variable)
        var declaring = false             // after `export` / `local` / `readonly` / `declare`: NAME=value
        while i < end {
            let c = b[i]
            if c == Byte.newline {
                command = true
                declaring = false
                i += 1
                continue
            }
            if Self.isSpace(c) {
                i += 1
                continue
            }
            let previous = i > start ? b[i - 1] : Byte.newline
            let wordBoundary = Self.isSpace(previous) || previous == Byte.newline || previous == Byte.semicolon
                || previous == Byte.pipe || previous == Byte.ampersand || previous == Byte.lparen
            if c == Byte.hash && wordBoundary {
                let e = endOfLine(i)
                emit(i == start && at(i + 1) == Byte.bang ? .meta : .comment, i, e)
                i = e
                continue
            }
            if c == Byte.apostrophe {
                let e = scanString(from: i + 1, quote: Byte.apostrophe, multiline: true, escapes: false)
                emit(.string, i, e)
                i = e
                command = false
                continue
            }
            if c == Byte.quote {
                i = lexBashDoubleQuoted(i)
                command = false
                continue
            }
            if c == Byte.dollar {
                i = lexBashVariable(i)
                if b[i - 1] == Byte.lparen { command = true }
                continue
            }
            if c == Byte.semicolon || c == Byte.pipe || c == Byte.ampersand || c == Byte.lparen || c == Byte.backtick {
                command = true
                declaring = false
                i += 1
                continue
            }
            if c == Byte.dash && wordBoundary && !command {
                var e = i
                while e < end, !Self.isSpace(b[e]), b[e] != Byte.newline, b[e] != Byte.equals, b[e] != Byte.semicolon {
                    e += 1
                }
                emit(.attribute, i, e)
                i = e
                continue
            }
            if Self.isDigit(c) && wordBoundary {
                var e = i
                while e < end, Self.isDigit(b[e]) || b[e] == Byte.dot { e += 1 }
                if e == end || Self.isSpace(b[e]) || b[e] == Byte.newline || b[e] == Byte.semicolon
                    || b[e] == Byte.rparen || b[e] == Byte.greater {
                    emit(.number, i, e)
                    i = e
                    command = false
                    continue
                }
            }
            if Self.isIdentStart(c) || c == Byte.dot || c == Byte.slash || c == Byte.tilde {
                var e = i
                while e < end {
                    let d = b[e]
                    if Self.isIdentPart(d) || d == Byte.dash || d == Byte.dot || d == Byte.slash || d == Byte.tilde
                        || d == Byte.plus || d == Byte.colon || d == Byte.at || d == Byte.percent || d == Byte.comma {
                        e += 1
                    } else {
                        break
                    }
                }
                let text = word(i, e)
                if at(e) == Byte.equals && (command || declaring) && Self.isIdentStart(c) && !text.contains("/") {
                    emit(.variable, i, e)   // NAME=value
                } else if Self.bashKeywords.contains(text) {
                    emit(.keyword, i, e)
                    command = Self.bashCommandKeywords.contains(text)
                    declaring = ["export", "local", "readonly", "declare", "typeset"].contains(text)
                    expectName = text == "function" ? .function : (text == "for" ? .variable : nil)
                } else if let name = expectName {
                    emit(name, i, e)
                    expectName = nil
                    command = false
                } else if command {
                    emit(.function, i, e)
                    command = false
                } else {
                    command = false
                }
                i = e
                continue
            }
            command = false
            i += 1
        }
    }

    private mutating func lexBashDoubleQuoted(_ i: Int) -> Int {
        var j = i + 1
        var segmentStart = i
        while j < end {
            let c = b[j]
            if c == Byte.backslash {
                j += 2
                continue
            }
            if c == Byte.quote {
                emit(.string, segmentStart, j + 1)
                return j + 1
            }
            if c == Byte.dollar && (Self.isIdentStart(at(j + 1)) || at(j + 1) == Byte.lbrace) {
                emit(.string, segmentStart, j)
                let e = lexBashVariable(j)
                segmentStart = e
                j = e
                continue
            }
            j += 1
        }
        emit(.string, segmentStart, end)
        return end
    }

    private mutating func lexBashVariable(_ i: Int) -> Int {
        let next = at(i + 1)
        var e = i + 1
        if next == Byte.lbrace {
            while e < end, b[e] != Byte.rbrace, b[e] != Byte.newline { e += 1 }
            e = min(end, e + 1)
        } else if next == Byte.lparen {
            e = i + 2
        } else if Self.isIdentStart(next) {
            e = scanIdentifier(i + 1)
        } else if Self.isDigit(next) || "@*#?$!-".utf8.contains(next) {
            e = i + 2
        }
        emit(.variable, i, e)
        return e
    }

    // MARK: YAML

    mutating func lexYAML() {
        var i = start
        var blockScalarIndent: Int?
        while i < end {
            let lineEnd = endOfLine(i)
            var j = i
            while j < lineEnd && b[j] == Byte.space { j += 1 }
            let indent = j - i
            if let scalarIndent = blockScalarIndent {
                if j == lineEnd || indent > scalarIndent {
                    emit(.string, j, lineEnd)
                    i = lineEnd + 1
                    continue
                }
                blockScalarIndent = nil
            }
            if j == lineEnd {
                i = lineEnd + 1
                continue
            }
            if b[j] == Byte.hash {
                emit(.comment, j, lineEnd)
                i = lineEnd + 1
                continue
            }
            if (starts(j, with: "---") || starts(j, with: "...")) && (j + 3 == lineEnd || Self.isSpace(at(j + 3))) {
                emit(.meta, j, j + 3)
                j += 3
            }
            // Sequence markers.
            while j < lineEnd, b[j] == Byte.dash, j + 1 == lineEnd || Self.isSpace(b[j + 1]) {
                j += 1
                while j < lineEnd && Self.isSpace(b[j]) { j += 1 }
            }
            if let keyEnd = yamlKeyEnd(j, lineEnd) {
                emit(.property, j, keyEnd)
                j = keyEnd
                while j < lineEnd && b[j] != Byte.colon { j += 1 }
                j += 1
            }
            if lexYAMLValue(j, lineEnd) { blockScalarIndent = indent }
            i = lineEnd + 1
        }
    }

    /// End of a `key:` at `j`, or `nil`.
    private func yamlKeyEnd(_ j: Int, _ lineEnd: Int) -> Int? {
        guard j < lineEnd else { return nil }
        let c = b[j]
        if c == Byte.quote || c == Byte.apostrophe {
            let e = scanString(from: j + 1, quote: c, multiline: false, escapes: c == Byte.quote)
            var k = e
            while k < lineEnd && Self.isSpace(b[k]) { k += 1 }
            return at(k) == Byte.colon && (k + 1 >= lineEnd || Self.isSpace(at(k + 1))) ? e : nil
        }
        if c == Byte.lbrace || c == Byte.lbracket || c == Byte.hash || c == Byte.ampersand || c == Byte.star
            || c == Byte.bang || c == Byte.pipe || c == Byte.greater {
            return nil
        }
        var k = j
        while k < lineEnd {
            if b[k] == Byte.colon && (k + 1 == lineEnd || Self.isSpace(b[k + 1])) {
                var e = k
                while e > j && Self.isSpace(b[e - 1]) { e -= 1 }
                return e
            }
            if b[k] == Byte.hash && k > j && Self.isSpace(b[k - 1]) { return nil }
            k += 1
        }
        return nil
    }

    /// Lexes a YAML value; returns `true` when it opens a block scalar (`|`, `>`).
    private mutating func lexYAMLValue(_ from: Int, _ lineEnd: Int) -> Bool {
        var j = from
        while j < lineEnd && Self.isSpace(b[j]) { j += 1 }
        guard j < lineEnd else { return false }
        let c = b[j]
        if c == Byte.hash {
            emit(.comment, j, lineEnd)
            return false
        }
        if c == Byte.pipe || c == Byte.greater {
            var e = j + 1
            while e < lineEnd, b[e] == Byte.plus || b[e] == Byte.dash || Self.isDigit(b[e]) { e += 1 }
            emit(.meta, j, e)
            lexYAMLTrailingComment(e, lineEnd)
            return true
        }
        if c == Byte.ampersand || c == Byte.star {
            let e = scanIdentifier(j + 1, extra: Byte.dash, extra2: Byte.dot)
            emit(.variable, j, e)
            return lexYAMLValue(e, lineEnd)
        }
        if c == Byte.bang {
            var e = j
            while e < lineEnd && !Self.isSpace(b[e]) { e += 1 }
            emit(.meta, j, e)
            return lexYAMLValue(e, lineEnd)
        }
        if c == Byte.quote || c == Byte.apostrophe {
            var e = scanString(from: j + 1, quote: c, multiline: false, escapes: c == Byte.quote)
            while c == Byte.apostrophe && at(e) == Byte.apostrophe {
                e = scanString(from: e + 1, quote: c, multiline: false, escapes: false)
            }
            emit(.string, j, e)
            lexYAMLTrailingComment(e, lineEnd)
            return false
        }
        if c == Byte.lbrace || c == Byte.lbracket {
            lexYAMLFlow(j, lineEnd)
            return false
        }
        // Plain scalar up to a comment.
        var e = j
        while e < lineEnd {
            if b[e] == Byte.hash && Self.isSpace(b[e - 1]) { break }
            e += 1
        }
        var valueEnd = e
        while valueEnd > j && Self.isSpace(b[valueEnd - 1]) { valueEnd -= 1 }
        emit(yamlScalarKind(j, valueEnd), j, valueEnd)
        if e < lineEnd { emit(.comment, e, lineEnd) }
        return false
    }

    private mutating func lexYAMLTrailingComment(_ from: Int, _ lineEnd: Int) {
        var k = from
        while k < lineEnd {
            if b[k] == Byte.hash && (k == from || Self.isSpace(b[k - 1])) {
                emit(.comment, k, lineEnd)
                return
            }
            k += 1
        }
    }

    private mutating func lexYAMLFlow(_ from: Int, _ lineEnd: Int) {
        var k = from
        while k < lineEnd {
            let c = b[k]
            if c == Byte.quote || c == Byte.apostrophe {
                let e = scanString(from: k + 1, quote: c, multiline: false, escapes: c == Byte.quote)
                emit(.string, k, e)
                k = e
            } else if c == Byte.hash && Self.isSpace(at(k - 1)) {
                emit(.comment, k, lineEnd)
                return
            } else if c == Byte.lbrace || c == Byte.rbrace || c == Byte.lbracket || c == Byte.rbracket
                        || c == Byte.comma || Self.isSpace(c) {
                k += 1
            } else {
                var e = k
                while e < lineEnd, !"{}[],".utf8.contains(b[e]), !(b[e] == Byte.colon && Self.isSpace(at(e + 1))) {
                    e += 1
                }
                var valueEnd = e
                while valueEnd > k && Self.isSpace(b[valueEnd - 1]) { valueEnd -= 1 }
                if at(e) == Byte.colon {
                    emit(.property, k, valueEnd)
                    e += 1
                } else {
                    emit(yamlScalarKind(k, valueEnd), k, valueEnd)
                }
                k = max(e, k + 1)
            }
        }
    }

    private static let yamlConstants: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "null", "~", "True", "False", "TRUE", "FALSE", "Yes", "No", "YES",
        "NO", "On", "Off", "ON", "OFF", "Null", "NULL",
    ]

    private func yamlScalarKind(_ lower: Int, _ upper: Int) -> SyntaxTokenKind {
        guard upper > lower else { return .string }
        let text = word(lower, upper)
        if Self.yamlConstants.contains(text) { return .keyword }
        var sawDigit = false
        for (k, c) in b[lower..<upper].enumerated() {
            if Self.isDigit(c) {
                sawDigit = true
            } else if !(c == Byte.dot || c == Byte.underscore || ((c == Byte.dash || c == Byte.plus) && k == 0)
                        || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")) {
                return .string
            }
        }
        return sawDigit ? .number : .string
    }

    // MARK: HTML / XML

    private static let scriptTag: [UInt8] = Array("</script".utf8)
    private static let styleTag: [UInt8] = Array("</style".utf8)

    mutating func lexMarkup(html: Bool) {
        var i = start
        while i < end {
            let c = b[i]
            if c == Byte.less {
                if starts(i, with: "<!--") {
                    let e = find("-->", from: i + 4).map { $0 + 3 } ?? end
                    emit(.comment, i, e)
                    i = e
                    continue
                }
                if starts(i, with: "<![CDATA[") {
                    let e = find("]]>", from: i + 9).map { $0 + 3 } ?? end
                    emit(.string, i, e)
                    i = e
                    continue
                }
                if at(i + 1) == Byte.bang || at(i + 1) == Byte.question {
                    var e = i + 1
                    while e < end && b[e] != Byte.greater { e += 1 }
                    e = min(end, e + 1)
                    emit(.meta, i, e)
                    i = e
                    continue
                }
                let closing = at(i + 1) == Byte.slash
                let nameStart = closing ? i + 2 : i + 1
                if Self.isIdentStart(at(nameStart)) {
                    var j = scanIdentifier(nameStart, extra: Byte.dash, extra2: Byte.colon)
                    while at(j) == Byte.dot { j = scanIdentifier(j + 1, extra: Byte.dash, extra2: Byte.colon) }
                    emit(.tag, nameStart, j)
                    let name = word(nameStart, j).lowercased()
                    j = lexMarkupAttributes(j)
                    i = j
                    let opened = j >= 2 && b[j - 1] == Byte.greater && b[j - 2] != Byte.slash
                    if html && !closing && opened && (name == "script" || name == "style") {
                        let closeTag = name == "script" ? Self.scriptTag : Self.styleTag
                        var close = i
                        while close < end && !startsCaseInsensitive(close, with: closeTag) { close += 1 }
                        var embedded = SyntaxLexer(bytes: b, range: i..<close)
                        if name == "script" {
                            embedded.lexCode(CodeSpec.spec(for: .javascript))
                        } else {
                            embedded.lexCSS()
                        }
                        tokens.append(contentsOf: embedded.tokens)
                        i = close
                    }
                    continue
                }
            }
            if c == Byte.ampersand {
                var e = i + 1
                while e < end, e - i <= 10, Self.isIdentPart(b[e]) || b[e] == Byte.hash { e += 1 }
                if at(e) == Byte.semicolon && e > i + 1 {
                    emit(.meta, i, e + 1)
                    i = e + 1
                    continue
                }
            }
            i += 1
        }
    }

    /// Attributes up to and including the tag's `>`.
    private mutating func lexMarkupAttributes(_ from: Int) -> Int {
        var j = from
        while j < end {
            let c = b[j]
            if c == Byte.greater { return j + 1 }
            if c == Byte.slash && at(j + 1) == Byte.greater { return j + 2 }
            if c == Byte.quote || c == Byte.apostrophe {
                let e = scanString(from: j + 1, quote: c, multiline: true, escapes: false)
                emit(.string, j, e)
                j = e
                continue
            }
            if c == Byte.equals {
                j += 1
                while j < end && Self.isSpace(b[j]) { j += 1 }
                if j < end && b[j] != Byte.quote && b[j] != Byte.apostrophe && b[j] != Byte.greater {
                    var e = j
                    while e < end, !Self.isSpace(b[e]), b[e] != Byte.newline, b[e] != Byte.greater { e += 1 }
                    emit(.string, j, e)
                    j = e
                }
                continue
            }
            if Self.isIdentStart(c) || c == Byte.at || c == Byte.colon {
                var e = j + 1
                while e < end, Self.isIdentPart(b[e]) || b[e] == Byte.dash || b[e] == Byte.colon || b[e] == Byte.dot
                        || b[e] == Byte.at {
                    e += 1
                }
                emit(.attribute, j, e)
                j = e
                continue
            }
            if c == Byte.less { return j }   // malformed tag: let the caller restart here
            j += 1
        }
        return end
    }

    // MARK: CSS

    mutating func lexCSS() {
        var i = start
        var depth = 0
        var inValue = false
        var propertyPending = false
        while i < end {
            let c = b[i]
            if Self.isSpace(c) || c == Byte.newline {
                i += 1
                continue
            }
            if c == Byte.slash && at(i + 1) == Byte.star {
                let e = scanBlockComment(from: i + 2, nested: false)
                emit(.comment, i, e)
                i = e
                continue
            }
            if c == Byte.slash && at(i + 1) == Byte.slash {   // SCSS / Less line comment
                let e = endOfLine(i)
                emit(.comment, i, e)
                i = e
                continue
            }
            if c == Byte.quote || c == Byte.apostrophe {
                let e = scanString(from: i + 1, quote: c, multiline: false)
                emit(.string, i, e)
                i = e
                continue
            }
            switch c {
            case Byte.lbrace:
                depth += 1
                inValue = false
                propertyPending = false
                i += 1
                continue
            case Byte.rbrace:
                depth = max(0, depth - 1)
                inValue = false
                propertyPending = false
                i += 1
                continue
            case Byte.semicolon:
                inValue = false
                propertyPending = false
                i += 1
                continue
            default:
                break
            }
            if c == Byte.at && Self.isIdentStart(at(i + 1)) {
                let e = scanIdentifier(i + 1, extra: Byte.dash)
                emit(.keyword, i, e)
                i = e
                continue
            }
            if inValue {
                if c == Byte.hash && Self.isHex(at(i + 1)) {
                    var e = i + 1
                    while e < end && Self.isIdentPart(b[e]) { e += 1 }
                    emit(.number, i, e)
                    i = e
                } else if Self.isDigit(c) || (c == Byte.dot && Self.isDigit(at(i + 1)))
                            || ((c == Byte.dash || c == Byte.plus) && (Self.isDigit(at(i + 1)) || at(i + 1) == Byte.dot)) {
                    var e = i + 1
                    while e < end, Self.isIdentPart(b[e]) || b[e] == Byte.dot || b[e] == Byte.percent { e += 1 }
                    emit(.number, i, e)
                    i = e
                } else if c == Byte.bang {
                    let e = scanIdentifier(i + 1)
                    emit(.keyword, i, e)
                    i = e
                } else if Self.isIdentStart(c) || c == Byte.dash {
                    let e = scanIdentifier(i, extra: Byte.dash)
                    if at(e) == Byte.lparen { emit(.function, i, e) }
                    i = e
                } else {
                    i += 1
                }
                continue
            }
            // Selector or property context.
            if c == Byte.colon {
                if propertyPending {
                    inValue = true
                    propertyPending = false
                    i += 1
                } else {
                    var e = i + 1
                    if at(e) == Byte.colon { e += 1 }
                    e = scanIdentifier(e, extra: Byte.dash)
                    emit(.attribute, i, e)
                    i = e
                }
                continue
            }
            if (c == Byte.dot || c == Byte.hash) && (Self.isIdentStart(at(i + 1)) || at(i + 1) == Byte.dash) {
                let e = scanIdentifier(i + 1, extra: Byte.dash)
                emit(.type, i, e)
                i = e
                continue
            }
            if c == Byte.lbracket {
                var e = i + 1
                while e < end && b[e] != Byte.rbracket && b[e] != Byte.newline { e += 1 }
                emit(.attribute, i, min(end, e + 1))
                i = min(end, e + 1)
                continue
            }
            if Self.isIdentStart(c) || (c == Byte.dash && (Self.isIdentStart(at(i + 1)) || at(i + 1) == Byte.dash)) {
                let e = scanIdentifier(i, extra: Byte.dash)
                if depth > 0 && cssLooksLikeDeclaration(e) {
                    emit(.property, i, e)
                    propertyPending = true
                } else {
                    emit(.tag, i, e)
                }
                i = e
                continue
            }
            i += 1
        }
    }

    /// `name: value;` (and not a nested selector such as `a:hover {`).
    private func cssLooksLikeDeclaration(_ from: Int) -> Bool {
        var j = from
        while j < end && Self.isSpace(b[j]) { j += 1 }
        guard at(j) == Byte.colon else { return false }
        j += 1
        while j < end {
            switch b[j] {
            case Byte.lbrace: return false
            case Byte.semicolon, Byte.rbrace, Byte.newline: return true
            default: j += 1
            }
        }
        return true
    }

    // MARK: Diff

    mutating func lexDiff() {
        var i = start
        while i < end {
            let e = endOfLine(i)
            if starts(i, with: "+++") || starts(i, with: "---") || starts(i, with: "@@") {
                emit(.meta, i, e)
            } else if starts(i, with: "diff ") || starts(i, with: "index ") || starts(i, with: "new file")
                        || starts(i, with: "deleted file") || starts(i, with: "similarity") || starts(i, with: "rename ")
                        || starts(i, with: "old mode") || starts(i, with: "new mode") || starts(i, with: "\\ No newline") {
                emit(.comment, i, e)
            } else if at(i) == Byte.plus {
                emit(.inserted, i, e)
            } else if at(i) == Byte.dash {
                emit(.deleted, i, e)
            }
            i = e + 1
        }
    }
}

// MARK: - Language specifications

/// Lexer configuration for C-family-like languages.
struct CodeSpec: Sendable {
    var keywords: Set<String>
    var types: Set<String> = []
    /// Keywords after which the next identifier names a function (`func`, `def`, `fn`, …).
    var functionKeywords: Set<String> = []
    /// Keywords after which the next identifier names a type (`class`, `struct`, …).
    var typeKeywords: Set<String> = []
    var slashComments = true
    var hashComments = false
    var dashComments = false
    var nestedComments = false
    var singleQuoteStrings = true
    var tripleQuotes = false
    var multilineStrings = false
    var backtickStrings = false
    var backtickEscapes = true
    var doubledQuoteEscapes = false
    var stringPrefixes = false
    var capitalizedTypes = true
    var caseInsensitive = false
    var annotations = false
    var preprocessor = false
    var hashDirectives = false
    var dollarIdentifiers = false
    var jsx = false
    var rust = false

    static func spec(for language: SyntaxLanguage) -> CodeSpec {
        switch language {
        case .swift: swift
        case .python: python
        case .javascript, .jsx: javascriptJSX
        case .typescript: typescript
        case .tsx: typescriptJSX
        case .go: go
        case .rust: rust
        case .java: java
        case .kotlin: kotlin
        case .c: c
        case .cpp: cpp
        case .sql: sql
        case .json, .bash, .yaml, .html, .xml, .css, .diff: javascriptJSX   // not used (dedicated lexers)
        }
    }

    static let swift = CodeSpec(
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
            "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
            "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
            "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
            "where", "while", "as", "Any", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
            "async", "await", "actor", "some", "any", "mutating", "nonmutating", "lazy", "weak", "unowned", "override",
            "final", "required", "convenience", "dynamic", "indirect", "optional", "get", "set", "willSet", "didSet",
            "isolated", "nonisolated", "consume", "consuming", "borrowing", "sending", "package", "macro", "each",
            "copy", "discard", "then",
        ],
        types: ["Int", "Double", "String", "Bool", "Float", "Character", "Void", "Never", "Optional", "Array",
                "Dictionary", "Set", "UInt", "Int64", "Int32", "UInt8", "Data", "Date", "URL", "Error"],
        functionKeywords: ["func"],
        typeKeywords: ["class", "struct", "enum", "protocol", "extension", "actor", "typealias", "associatedtype"],
        nestedComments: true, singleQuoteStrings: false, tripleQuotes: true, annotations: true, hashDirectives: true)

    static let python = CodeSpec(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case",
            "self", "cls", "type",
        ],
        types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object", "complex",
                "frozenset", "bytearray"],
        functionKeywords: ["def"], typeKeywords: ["class"],
        slashComments: false, hashComments: true, tripleQuotes: true, stringPrefixes: true, annotations: true)

    private static let javascriptKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
        "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
        "async", "await", "of", "static", "get", "set", "null", "undefined", "true", "false", "from", "as",
    ]
    private static let typescriptKeywords: Set<String> = javascriptKeywords.union([
        "interface", "type", "enum", "implements", "namespace", "declare", "abstract", "readonly", "private",
        "public", "protected", "keyof", "infer", "is", "satisfies", "override", "module", "asserts", "unique",
    ])
    private static let typescriptTypes: Set<String> = [
        "any", "unknown", "never", "string", "number", "boolean", "symbol", "bigint", "object",
    ]

    static let javascriptJSX = CodeSpec(
        keywords: javascriptKeywords, functionKeywords: ["function"], typeKeywords: ["class", "extends"],
        multilineStrings: false, backtickStrings: true, dollarIdentifiers: true, jsx: true)
    static let typescript = CodeSpec(
        keywords: typescriptKeywords, types: typescriptTypes, functionKeywords: ["function"],
        typeKeywords: ["class", "interface", "type", "enum", "extends", "implements"],
        backtickStrings: true, annotations: true, dollarIdentifiers: true)
    static let typescriptJSX: CodeSpec = {
        var spec = typescript
        spec.jsx = true
        return spec
    }()

    static let go = CodeSpec(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "nil", "true", "false", "iota",
        ],
        types: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
                "float32", "float64", "complex64", "complex128", "string", "bool", "byte", "rune", "error", "any"],
        functionKeywords: ["func"], typeKeywords: ["type"],
        backtickStrings: true, backtickEscapes: false)

    static let rust = CodeSpec(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
            "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
            "union", "macro_rules",
        ],
        types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
                "bool", "char", "str"],
        functionKeywords: ["fn"], typeKeywords: ["struct", "enum", "trait", "type", "impl"],
        nestedComments: true, singleQuoteStrings: false, multilineStrings: true, stringPrefixes: true, rust: true)

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record", "sealed", "permits",
        "yield", "null", "true", "false", "non-sealed",
    ]
    static let java = CodeSpec(
        keywords: javaKeywords, typeKeywords: ["class", "interface", "enum", "record", "extends", "implements"],
        tripleQuotes: true, annotations: true)
    static let kotlin = CodeSpec(
        keywords: [
            "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is",
            "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof",
            "val", "var", "when", "while", "by", "catch", "constructor", "delegate", "dynamic", "field", "file",
            "finally", "get", "import", "init", "param", "property", "receiver", "set", "setparam", "where",
            "abstract", "actual", "annotation", "companion", "const", "crossinline", "data", "enum", "expect",
            "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator",
            "out", "override", "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg",
            "value", "it",
        ],
        functionKeywords: ["fun"], typeKeywords: ["class", "interface", "object", "typealias"],
        tripleQuotes: true, annotations: true)

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL", "_Bool", "_Atomic", "_Noreturn", "_Static_assert", "_Thread_local",
    ]
    private static let cTypes: Set<String> = [
        "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "intptr_t", "uintptr_t", "ptrdiff_t", "FILE", "wchar_t",
    ]
    static let c = CodeSpec(keywords: cKeywords, types: cTypes, typeKeywords: ["struct", "enum", "union"],
                            capitalizedTypes: false, annotations: true, preprocessor: true)
    static let cpp = CodeSpec(
        keywords: cKeywords.union([
            "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override",
            "final", "new", "delete", "this", "operator", "using", "friend", "explicit", "constexpr", "consteval",
            "constinit", "noexcept", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "try", "catch",
            "throw", "mutable", "decltype", "concept", "requires", "co_await", "co_return", "co_yield", "nullptr",
            "export", "import", "module", "alignas", "alignof", "thread_local", "static_assert",
        ]),
        types: cTypes.union(["string", "vector", "map", "unordered_map", "set", "unique_ptr", "shared_ptr", "optional",
                             "array", "std"]),
        typeKeywords: ["class", "struct", "enum", "union", "namespace", "typename"],
        capitalizedTypes: true, annotations: true, preprocessor: true)

    static let sql = CodeSpec(
        keywords: [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop",
            "alter", "add", "column", "index", "view", "join", "left", "right", "inner", "outer", "full", "cross",
            "on", "using", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null",
            "is", "in", "exists", "between", "like", "ilike", "distinct", "union", "all", "case", "when", "then",
            "else", "end", "primary", "key", "foreign", "references", "default", "unique", "check", "constraint",
            "trigger", "begin", "commit", "rollback", "transaction", "returning", "with", "recursive", "asc", "desc",
            "if", "replace", "cascade", "true", "false", "grant", "revoke", "schema", "database", "explain",
            "analyze", "vacuum", "pragma", "over", "partition", "window", "lateral", "conflict", "do", "nothing",
            "upsert", "intersect", "except", "fetch", "first", "next", "rows", "only", "autoincrement", "collate",
        ],
        types: ["int", "integer", "bigint", "smallint", "tinyint", "text", "varchar", "char", "boolean", "bool", "date",
                "time", "timestamp", "timestamptz", "interval", "numeric", "decimal", "real", "float", "double",
                "serial", "bigserial", "uuid", "json", "jsonb", "blob", "bytea", "money"],
        slashComments: true, dashComments: true, multilineStrings: true, backtickStrings: true,
        backtickEscapes: false, doubledQuoteEscapes: true, capitalizedTypes: false, caseInsensitive: true)
}
