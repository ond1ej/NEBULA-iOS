import Foundation
import Synchronization

/// A parsed Markdown message: a list of ``MarkdownBlock``s ready for ``MarkdownView``.
///
/// Use ``parse(_:id:isStreaming:)``: it is cheap to call on every render.
/// - Results are kept in a small LRU cache keyed by message id + content, so scrolling a long conversation never
///   parses a message twice.
/// - For a growing (streaming) message only the tail is re-parsed: blocks before the last *stable block boundary*
///   are reused from the previous version of the same message (or, without an id, from a recently parsed text that
///   shares the prefix). The result is identical to a full parse.
/// - An unterminated code fence renders as a code block running to the end of the text.
public struct MarkdownDocument: Hashable, Sendable {
    /// The parsed text (line endings normalized to `"\n"`).
    public let source: String
    /// The top-level blocks.
    public let blocks: [MarkdownBlock]
    /// Whether the text was parsed as a still-streaming message (see ``parse(_:id:isStreaming:)``).
    public let isStreaming: Bool

    // Incremental parsing metadata.
    let blockStartLines: [Int]
    let lineStarts: [Int]
    let endsWithNewline: Bool

    /// Parses `text` without using the cache.
    ///
    /// - Parameters:
    ///   - text: Markdown source.
    ///   - isStreaming: `true` while the message is still being generated: the last, unterminated line is then
    ///     interpreted with its likely continuation in mind (a lone `-` already starts a list item, a started
    ///     table delimiter row already makes a table, a trailing `12` or ` `` ` fragment is held back), so streamed
    ///     text does not flicker between interpretations. Complete text is always parsed strictly.
    public init(parsing text: String, isStreaming: Bool = false) {
        let normalized = Self.normalizeLineEndings(text)
        let output = MarkdownBlockParser.parse(normalized[...], streaming: isStreaming)
        self.init(source: normalized, blocks: output.blocks, isStreaming: isStreaming,
                  blockStartLines: output.blockStartLines, lineStarts: output.lineStarts,
                  endsWithNewline: output.endsWithNewline)
    }

    init(source: String, blocks: [MarkdownBlock], isStreaming: Bool, blockStartLines: [Int], lineStarts: [Int],
         endsWithNewline: Bool) {
        self.source = source
        self.blocks = blocks
        self.isStreaming = isStreaming
        self.blockStartLines = blockStartLines
        self.lineStarts = lineStarts
        self.endsWithNewline = endsWithNewline
    }

    /// Parses `text`, using the shared cache.
    ///
    /// - Parameters:
    ///   - text: Markdown source of one message.
    ///   - id: A stable message id. With an id, a cache hit needs the same id and content, and a streaming message
    ///     re-parses only its changed tail relative to the previous version with that id.
    ///   - isStreaming: See ``init(parsing:isStreaming:)``.
    public static func parse(_ text: String, id: String? = nil, isStreaming: Bool = false) -> MarkdownDocument {
        MarkdownDocumentCache.shared.document(for: normalizeLineEndings(text), id: id, streaming: isStreaming)
    }

    /// Drops every cached document, inline rendering and syntax highlighting result (e.g. on memory pressure).
    public static func purgeCaches() {
        MarkdownDocumentCache.shared.removeAll()
        MarkdownInlineRenderer.purgeCache()
        SyntaxHighlighter.purgeCache()
    }

    /// `true` when the message has no visible content.
    public var isEmpty: Bool { blocks.isEmpty }

    // MARK: - Incremental parsing

    /// Re-parses `text` reusing the leading blocks of `base`, or returns `nil` when nothing can be reused.
    ///
    /// Block `j` of `base` (starting at line `L`) is a safe restart point when lines `L` and `L + 1` are complete in
    /// `base` and `text` shares `base`'s bytes through the end of line `L + 1`: the parser decides where a block ends
    /// from at most one line of lookahead beyond the first line of the next block, so every block before `j` is then
    /// identical in a full parse of `text`, and blocks from `j` on equal a standalone parse of the tail.
    static func reparse(_ text: String, reusing base: MarkdownDocument, streaming: Bool) -> MarkdownDocument? {
        guard base.blocks.count >= 2 else { return nil }
        let shared = commonPrefixLength(base.source, text)
        let lineCount = base.lineStarts.count
        var j = base.blocks.count - 1
        while j >= 1 {
            let line = base.blockStartLines[j]
            let required: Int?
            if line + 2 < lineCount {
                required = base.lineStarts[line + 2]
            } else if line + 1 == lineCount - 1 && base.endsWithNewline {
                required = base.source.utf8.count
            } else {
                required = nil
            }
            if let required, required <= shared { break }
            j -= 1
        }
        guard j >= 1 else { return nil }

        let startLine = base.blockStartLines[j]
        let startOffset = base.lineStarts[startLine]
        let utf8 = text.utf8
        let tail = MarkdownBlockParser.parse(text[utf8.index(utf8.startIndex, offsetBy: startOffset)...],
                                             streaming: streaming)
        var blocks = Array(base.blocks[..<j])
        blocks.append(contentsOf: tail.blocks)
        var blockStartLines = Array(base.blockStartLines[..<j])
        blockStartLines.append(contentsOf: tail.blockStartLines.lazy.map { $0 + startLine })
        var lineStarts = Array(base.lineStarts[..<startLine])
        lineStarts.append(contentsOf: tail.lineStarts.lazy.map { $0 + startOffset })
        return MarkdownDocument(source: text, blocks: blocks, isStreaming: streaming, blockStartLines: blockStartLines,
                                lineStarts: lineStarts, endsWithNewline: tail.endsWithNewline)
    }

    /// Number of leading UTF-8 bytes `a` and `b` have in common.
    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let fast: Int?? = a.utf8.withContiguousStorageIfAvailable { pa in
            b.utf8.withContiguousStorageIfAvailable { pb -> Int in
                let count = min(pa.count, pb.count)
                guard count > 0, let ba = pa.baseAddress, let bb = pb.baseAddress else { return 0 }
                if memcmp(ba, bb, count) == 0 { return count }
                var i = 0
                while i < count && pa[i] == pb[i] { i += 1 }
                return i
            }
        }
        if let fast = fast ?? nil { return fast }
        var i = 0
        for (x, y) in zip(a.utf8, b.utf8) {
            guard x == y else { break }
            i += 1
        }
        return i
    }

    static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(Byte.carriageReturn) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Plain text

    /// The message as plain text (inline markup removed, list markers kept, code verbatim, table cells separated by
    /// tabs): for VoiceOver summaries, "Copy text" and notifications.
    public var plainText: String {
        Self.plainText(of: blocks, depth: 0)
    }

    /// The plain text of a Markdown string (see ``plainText``).
    public static func plainText(from markdown: String) -> String {
        parse(markdown).plainText
    }

    private static func plainText(of blocks: [MarkdownBlock], depth: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(blocks.count)
        for block in blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text):
                parts.append(MarkdownInlineRenderer.plainText(text))
            case .list(let list):
                let indent = String(repeating: "  ", count: depth)
                var lines: [String] = []
                for (index, item) in list.items.enumerated() {
                    let marker: String
                    switch (item.task, list.kind) {
                    case (.checked?, _): marker = "☑︎"
                    case (.unchecked?, _): marker = "☐"
                    case (nil, .bullet): marker = "•"
                    case (nil, .ordered(let start)): marker = "\(start + index)."
                    }
                    let body = plainText(of: item.blocks, depth: depth + 1)
                    lines.append(indent + marker + (body.isEmpty ? "" : " " + body))
                }
                parts.append(lines.joined(separator: "\n"))
            case .blockQuote(let children):
                parts.append(plainText(of: children, depth: depth))
            case .codeBlock(let code):
                parts.append(code.code)
            case .table(let table):
                var rows = [table.header.map(MarkdownInlineRenderer.plainText).joined(separator: "\t")]
                for row in table.rows {
                    rows.append(row.map(MarkdownInlineRenderer.plainText).joined(separator: "\t"))
                }
                parts.append(rows.joined(separator: "\n"))
            case .thematicBreak:
                continue
            }
        }
        return parts.joined(separator: depth == 0 ? "\n\n" : "\n")
    }
}

// MARK: - Cache

/// The process-wide document cache (thread-safe).
final class MarkdownDocumentCache: Sendable {
    static let shared = MarkdownDocumentCache()

    private struct Key: Hashable {
        var id: String?
        var streaming: Bool
        var text: String
    }

    private struct State {
        var documents = MarkdownLRU<Key, MarkdownDocument>(capacity: 192, costLimit: 8_000_000)
        /// The most recently parsed version of each message id (the base for incremental re-parsing).
        var latestByID: [String: MarkdownDocument] = [:]
        var latestOrder: [String] = []
        /// Recently parsed documents without an id.
        var recentAnonymous: [MarkdownDocument] = []
    }

    private let state = Mutex(State())
    private static let latestLimit = 48
    private static let anonymousLimit = 4

    func document(for text: String, id: String?, streaming: Bool) -> MarkdownDocument {
        let key = Key(id: id, streaming: streaming, text: text)
        let lookup: (hit: MarkdownDocument?, bases: [MarkdownDocument]) = state.withLock { state in
            if let hit = state.documents.value(for: key) { return (hit, []) }
            if let id { return (nil, state.latestByID[id].map { [$0] } ?? []) }
            return (nil, state.recentAnonymous)
        }
        if let hit = lookup.hit { return hit }

        var document: MarkdownDocument?
        for base in lookup.bases {
            if base.source == text && base.isStreaming == streaming {
                document = base
                break
            }
            if let reparsed = MarkdownDocument.reparse(text, reusing: base, streaming: streaming) {
                document = reparsed
                break
            }
        }
        let result = document ?? MarkdownDocument(parsing: text, isStreaming: streaming)

        state.withLock { state in
            state.documents.insert(result, for: key, cost: text.utf8.count * 3 + 256)
            if let id {
                if state.latestByID.updateValue(result, forKey: id) == nil {
                    state.latestOrder.append(id)
                    if state.latestOrder.count > Self.latestLimit {
                        state.latestByID.removeValue(forKey: state.latestOrder.removeFirst())
                    }
                }
            } else {
                state.recentAnonymous.insert(result, at: 0)
                if state.recentAnonymous.count > Self.anonymousLimit { state.recentAnonymous.removeLast() }
            }
        }
        return result
    }

    func removeAll() {
        state.withLock { $0 = State() }
    }
}

/// A small least-recently-used cache bounded by entry count and total cost. Not thread-safe (wrap it in a Mutex).
struct MarkdownLRU<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var stamp: UInt64
    }

    let capacity: Int
    let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var totalCost = 0

    init(capacity: Int, costLimit: Int) {
        self.capacity = max(1, capacity)
        self.costLimit = max(1, costLimit)
    }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let index = entries.index(forKey: key) else { return nil }
        clock &+= 1
        entries.values[index].stamp = clock
        return entries.values[index].value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        clock &+= 1
        if let old = entries.updateValue(Entry(value: value, cost: cost, stamp: clock), forKey: key) {
            totalCost -= old.cost
        }
        totalCost += cost
        if entries.count > capacity || totalCost > costLimit { evict() }
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    /// Evicts least recently used entries down to 75 % of both limits (amortises the sort).
    private mutating func evict() {
        let targetCount = capacity * 3 / 4
        let targetCost = costLimit * 3 / 4
        let oldestFirst = entries.sorted { $0.value.stamp < $1.value.stamp }
        for (key, entry) in oldestFirst {
            guard entries.count > targetCount || totalCost > targetCost else { break }
            entries.removeValue(forKey: key)
            totalCost -= entry.cost
        }
    }
}
