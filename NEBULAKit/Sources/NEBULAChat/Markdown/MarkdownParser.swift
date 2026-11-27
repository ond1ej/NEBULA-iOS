import Foundation

/// A fast, line-based CommonMark / GFM block parser (no regular expressions, no HTML).
///
/// Supported: ATX and setext headings, paragraphs with soft / hard line breaks, bullet / ordered / task lists with
/// nesting and lazy continuation lines, nested block quotes, fenced (```` ``` ```` / `~~~`) and indented code blocks,
/// GFM tables with column alignment, thematic breaks. HTML blocks are deliberately *not* recognised: raw HTML stays
/// paragraph text and is rendered literally (security requirement). Link reference definitions are not supported.
///
/// Lookahead invariant (relied upon by incremental parsing in ``MarkdownDocument``): whether a block ends before
/// line `k` is decided from lines `<= k + 1` only.
enum MarkdownBlockParser {
    struct Output {
        var blocks: [MarkdownBlock]
        /// The first line of every top-level block (indices into `lineStarts`).
        var blockStartLines: [Int]
        /// UTF-8 offset of every line start, relative to the parsed text.
        var lineStarts: [Int]
        /// Whether the parsed text ends with `"\n"` (its last line is complete).
        var endsWithNewline: Bool
    }

    struct ParsedBlock {
        var block: MarkdownBlock
        /// First line of the block (index into the parsed line array).
        var startLine: Int
        /// One past the last line that belongs to the block (trailing blank lines are not included).
        var endLine: Int
    }

    /// Parses `text`, which must use `"\n"` line endings.
    ///
    /// With `streaming == true` the last, still unterminated line is interpreted with the message's likely
    /// continuation in mind (so streamed text does not flicker): a lone list marker starts an (empty) item, a lone
    /// `-` / `=` is not yet a setext underline, a started delimiter row (`|--`) already makes a table, and a trailing
    /// fragment that is only digits or one / two backticks is held back until the line continues.
    static func parse(_ text: Substring, streaming: Bool) -> Output {
        var lines: [Substring] = []
        var lineStarts: [Int] = []
        lines.reserveCapacity(64)
        lineStarts.reserveCapacity(64)

        let utf8 = text.utf8
        var start = utf8.startIndex
        var startOffset = 0
        var offset = 0
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == Byte.newline {
                lines.append(text[start..<index])
                lineStarts.append(startOffset)
                index = utf8.index(after: index)
                offset += 1
                start = index
                startOffset = offset
            } else {
                index = utf8.index(after: index)
                offset += 1
            }
        }
        let endsWithNewline = start == utf8.endIndex
        if !endsWithNewline {
            lines.append(text[start...])
            lineStarts.append(startOffset)
        }

        var parseLines = lines
        let openEnd = streaming && !endsWithNewline && !lines.isEmpty
        if openEnd, let last = parseLines.last, isPendingFragment(last) {
            parseLines.removeLast()
        }
        let lastIsOpen = openEnd && parseLines.count == lines.count
        let parsed = parseBlocks(parseLines, lastLineIsOpen: lastIsOpen)
        return Output(blocks: parsed.map(\.block), blockStartLines: parsed.map(\.startLine), lineStarts: lineStarts,
                      endsWithNewline: endsWithNewline)
    }

    // MARK: - Blocks

    /// Parses one container's lines (already stripped of the container's markers / indentation).
    /// `lastLineIsOpen`: the last line is the unterminated final line of a streaming message.
    static func parseBlocks(_ lines: [Substring], lastLineIsOpen: Bool) -> [ParsedBlock] {
        var out: [ParsedBlock] = []
        let n = lines.count
        let openLine = lastLineIsOpen ? n - 1 : -1
        var i = 0
        while i < n {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            let indent = leadingIndent(line)

            // Indented code (cannot interrupt a paragraph, so it is only ever checked at a block start).
            if indent.columns >= 4 {
                var j = i
                var code: [Substring] = []
                var lastContent = i
                while j < n {
                    let l = lines[j]
                    if isBlank(l) {
                        code.append(dropIndent(l, columns: 4))
                    } else if leadingIndent(l).columns >= 4 {
                        code.append(dropIndent(l, columns: 4))
                        lastContent = j
                    } else {
                        break
                    }
                    j += 1
                }
                let body = code.prefix(lastContent - i + 1).joined(separator: "\n")
                out.append(ParsedBlock(block: .codeBlock(MarkdownCodeBlock(language: nil, code: body, isFenced: false,
                                                                           isClosed: true)),
                                       startLine: i, endLine: lastContent + 1))
                i = lastContent + 1
                continue
            }

            if let fence = fenceOpen(line, indent: indent) {
                var j = i + 1
                var body: [Substring] = []
                var closed = false
                while j < n {
                    if isFenceClose(lines[j], fence) {
                        closed = true
                        j += 1
                        break
                    }
                    body.append(dropIndent(lines[j], columns: fence.indent))
                    j += 1
                }
                let block = MarkdownCodeBlock(language: fence.language, code: body.joined(separator: "\n"),
                                              isFenced: true, isClosed: closed)
                out.append(ParsedBlock(block: .codeBlock(block), startLine: i, endLine: j))
                i = j
                continue
            }

            if let heading = atxHeading(line, indent: indent) {
                out.append(ParsedBlock(block: .heading(level: heading.level, text: heading.text), startLine: i,
                                       endLine: i + 1))
                i += 1
                continue
            }

            if isThematicBreak(line, indent: indent) {
                out.append(ParsedBlock(block: .thematicBreak, startLine: i, endLine: i + 1))
                i += 1
                continue
            }

            if blockQuoteContent(line) != nil {
                var j = i
                var inner: [Substring] = []
                var tracker = FenceTracker()
                while j < n {
                    let l = lines[j]
                    if let content = blockQuoteContent(l) {
                        inner.append(content)
                        tracker.feed(content)
                        j += 1
                        continue
                    }
                    if !isBlank(l), let last = inner.last, tracker.allowsLazyContinuation(after: last),
                       !interruptsParagraph(l, next: j + 1 < n ? lines[j + 1] : nil, lineIsOpen: j == openLine,
                                            nextIsOpen: j + 1 == openLine) {
                        inner.append(l)
                        j += 1
                        continue
                    }
                    break
                }
                let children = parseBlocks(inner, lastLineIsOpen: lastLineIsOpen && j == n)
                out.append(ParsedBlock(block: .blockQuote(children.map(\.block)), startLine: i, endLine: j))
                i = j
                continue
            }

            if let marker = listMarker(line) {
                let (list, end) = parseList(lines, from: i, first: marker, lastLineIsOpen: lastLineIsOpen)
                out.append(ParsedBlock(block: .list(list), startLine: i, endLine: end))
                i = end
                continue
            }

            if i + 1 < n, let alignments = tableDelimiter(for: line, delimiter: lines[i + 1],
                                                          delimiterIsOpen: i + 1 == openLine) {
                let header = normalized(tableCells(line), count: alignments.count)
                var rows: [[String]] = []
                var j = i + 2
                if i + 1 != openLine {
                    while j < n {
                        let l = lines[j]
                        if isBlank(l) || interruptsParagraph(l, next: j + 1 < n ? lines[j + 1] : nil,
                                                             lineIsOpen: j == openLine, nextIsOpen: j + 1 == openLine) {
                            break
                        }
                        rows.append(normalized(tableCells(l), count: alignments.count))
                        j += 1
                    }
                }
                let table = MarkdownTable(alignments: alignments, header: header, rows: rows)
                out.append(ParsedBlock(block: .table(table), startLine: i, endLine: j))
                i = j
                continue
            }

            // Paragraph (possibly turned into a setext heading).
            var paragraph: [Substring] = [line]
            var j = i + 1
            var setext: Int?
            while j < n {
                let l = lines[j]
                if isBlank(l) { break }
                let lineIsOpen = j == openLine
                if lineIsOpen, let m = listMarker(l), m.isEmpty, m.canInterruptParagraph(ignoringEmptiness: true) {
                    break
                }
                if let level = setextLevel(l, lineIsOpen: lineIsOpen) {
                    setext = level
                    j += 1
                    break
                }
                if interruptsParagraph(l, next: j + 1 < n ? lines[j + 1] : nil, lineIsOpen: lineIsOpen,
                                       nextIsOpen: j + 1 == openLine) {
                    break
                }
                paragraph.append(l)
                j += 1
            }
            let text = paragraphText(paragraph)
            let block: MarkdownBlock = setext.map { .heading(level: $0, text: text) } ?? .paragraph(text: text)
            out.append(ParsedBlock(block: block, startLine: i, endLine: j))
            i = j
        }
        return out
    }

    private static func parseList(_ lines: [Substring], from start: Int, first: ListMarker,
                                  lastLineIsOpen: Bool) -> (MarkdownList, Int) {
        let n = lines.count
        let openLine = lastLineIsOpen ? n - 1 : -1
        var items: [MarkdownListItem] = []
        var tight = true
        var i = start
        var end = start + 1
        var blankBeforeItem = false

        while i < n, !isThematicBreak(lines[i], indent: leadingIndent(lines[i])), let marker = listMarker(lines[i]),
              marker.kind == first.kind {
            if !items.isEmpty && blankBeforeItem { tight = false }
            var itemLines: [Substring] = [marker.content]
            var tracker = FenceTracker()
            tracker.feed(marker.content)
            var lastContent = i
            var j = i + 1
            while j < n {
                let l = lines[j]
                if isBlank(l) {
                    // An item can begin with at most one blank line.
                    if marker.isEmpty && lastContent == i { break }
                    itemLines.append(dropIndent(l, columns: marker.contentColumn))
                    j += 1
                    continue
                }
                if leadingIndent(l).columns >= marker.contentColumn {
                    let content = dropIndent(l, columns: marker.contentColumn)
                    itemLines.append(content)
                    tracker.feed(content)
                    lastContent = j
                    j += 1
                    continue
                }
                // Lazy continuation of the item's paragraph (only directly after a non-blank line).
                if lastContent == j - 1, !(marker.isEmpty && lastContent == i),
                   tracker.allowsLazyContinuation(after: itemLines[itemLines.count - 1]), listMarker(l) == nil,
                   !interruptsParagraph(l, next: j + 1 < n ? lines[j + 1] : nil, lineIsOpen: j == openLine,
                                        nextIsOpen: j + 1 == openLine) {
                    itemLines.append(l)
                    lastContent = j
                    j += 1
                    continue
                }
                break
            }

            let content = Array(itemLines.prefix(lastContent - i + 1))
            let parsed = parseBlocks(content, lastLineIsOpen: lastLineIsOpen && lastContent == n - 1)
            if parsed.count > 1 {
                for k in 1..<parsed.count where parsed[k].startLine > parsed[k - 1].endLine {
                    tight = false
                }
            }
            items.append(makeItem(parsed.map(\.block)))
            end = lastContent + 1

            var next = lastContent + 1
            while next < n && isBlank(lines[next]) { next += 1 }
            blankBeforeItem = next > lastContent + 1
            i = next
        }

        let kind: MarkdownList.Kind
        switch first.kind {
        case .bullet: kind = .bullet
        case .ordered: kind = .ordered(start: first.number)
        }
        return (MarkdownList(kind: kind, isTight: tight, items: items), end)
    }

    /// Extracts a GFM task marker (`[ ]`, `[x]`, `[X]`) from the item's first paragraph.
    private static func makeItem(_ blocks: [MarkdownBlock]) -> MarkdownListItem {
        guard case .paragraph(let text)? = blocks.first else { return MarkdownListItem(blocks: blocks) }
        let utf8 = text.utf8
        guard utf8.count >= 3 else { return MarkdownListItem(blocks: blocks) }
        let b0 = utf8[utf8.startIndex]
        let b1 = utf8[utf8.index(utf8.startIndex, offsetBy: 1)]
        let b2 = utf8[utf8.index(utf8.startIndex, offsetBy: 2)]
        guard b0 == Byte.lbracket, b2 == Byte.rbracket else { return MarkdownListItem(blocks: blocks) }
        let state: MarkdownTaskState
        switch b1 {
        case Byte.space: state = .unchecked
        case Byte.lowerX, Byte.upperX: state = .checked
        default: return MarkdownListItem(blocks: blocks)
        }
        let afterIndex = utf8.index(utf8.startIndex, offsetBy: 3)
        if afterIndex < utf8.endIndex {
            let after = utf8[afterIndex]
            guard after == Byte.space || after == Byte.tab || after == Byte.newline else {
                return MarkdownListItem(blocks: blocks)
            }
        }
        var rest = blocks
        let remainder = trimLeading(text[afterIndex...])
        if remainder.isEmpty {
            rest.removeFirst()
        } else {
            rest[0] = .paragraph(text: String(remainder))
        }
        return MarkdownListItem(task: state, blocks: rest)
    }

    // MARK: - Paragraph interruption

    /// Whether `line` starts a block that ends a running paragraph (CommonMark rules, plus GFM tables).
    static func interruptsParagraph(_ line: Substring, next: Substring?, lineIsOpen: Bool, nextIsOpen: Bool) -> Bool {
        let indent = leadingIndent(line)
        if indent.columns >= 4 { return false }
        if atxHeading(line, indent: indent) != nil || fenceOpen(line, indent: indent) != nil
            || isThematicBreak(line, indent: indent) || blockQuoteContent(line) != nil {
            return true
        }
        if let marker = listMarker(line), marker.canInterruptParagraph(ignoringEmptiness: lineIsOpen) {
            return true
        }
        if let next, tableDelimiter(for: line, delimiter: next, delimiterIsOpen: nextIsOpen) != nil {
            return true
        }
        return false
    }

    /// Tracks fenced code inside a container so lazy continuation lines are only accepted after paragraph text.
    private struct FenceTracker {
        private var open: Fence?

        mutating func feed(_ line: Substring) {
            if let fence = open {
                if isFenceClose(line, fence) { open = nil }
            } else if let fence = fenceOpen(line, indent: leadingIndent(line)) {
                open = fence
            }
        }

        func allowsLazyContinuation(after last: Substring) -> Bool {
            guard open == nil, !isBlank(last) else { return false }
            let indent = leadingIndent(last)
            if indent.columns >= 4 { return false }
            return atxHeading(last, indent: indent) == nil && !isThematicBreak(last, indent: indent)
                && fenceOpen(last, indent: indent) == nil
        }
    }

    // MARK: - Line classification

    struct Indent {
        var columns: Int
        var bytes: Int
    }

    /// Leading whitespace measured in columns (tab stops every 4 columns) and in UTF-8 bytes.
    @inline(__always)
    static func leadingIndent(_ line: Substring) -> Indent {
        var columns = 0
        var bytes = 0
        for byte in line.utf8 {
            if byte == Byte.space {
                columns += 1
            } else if byte == Byte.tab {
                columns += 4 - columns % 4
            } else {
                break
            }
            bytes += 1
        }
        return Indent(columns: columns, bytes: bytes)
    }

    @inline(__always)
    static func isBlank(_ line: Substring) -> Bool {
        for byte in line.utf8 where byte != Byte.space && byte != Byte.tab { return false }
        return true
    }

    /// Removes up to `columns` columns of leading whitespace (a partially consumed tab becomes spaces).
    static func dropIndent(_ line: Substring, columns limit: Int) -> Substring {
        guard limit > 0 else { return line }
        let utf8 = line.utf8
        var columns = 0
        var index = utf8.startIndex
        while index < utf8.endIndex && columns < limit {
            let byte = utf8[index]
            if byte == Byte.space {
                columns += 1
            } else if byte == Byte.tab {
                let width = 4 - columns % 4
                if columns + width > limit {
                    let rest = line[utf8.index(after: index)...]
                    return Substring(String(repeating: " ", count: columns + width - limit) + rest)
                }
                columns += width
            } else {
                break
            }
            index = utf8.index(after: index)
        }
        return line[index...]
    }

    static func trimLeading(_ s: Substring) -> Substring {
        let utf8 = s.utf8
        var index = utf8.startIndex
        while index < utf8.endIndex, utf8[index] == Byte.space || utf8[index] == Byte.tab {
            index = utf8.index(after: index)
        }
        return s[index...]
    }

    static func trimTrailing(_ s: Substring) -> Substring {
        let utf8 = s.utf8
        var end = utf8.endIndex
        while end > utf8.startIndex {
            let before = utf8.index(before: end)
            let byte = utf8[before]
            guard byte == Byte.space || byte == Byte.tab else { break }
            end = before
        }
        return s[..<end]
    }

    static func trim(_ s: Substring) -> Substring { trimTrailing(trimLeading(s)) }

    /// `true` for a streaming tail that is only digits (`12`) or one / two backticks / tildes: it is most likely
    /// the start of a list marker or a code fence, so it is held back instead of flashing as paragraph text.
    private static func isPendingFragment(_ line: Substring) -> Bool {
        let body = trimLeading(line)
        guard let first = body.utf8.first else { return false }
        var count = 0
        if first >= Byte.zero && first <= Byte.nine {
            for byte in body.utf8 {
                guard byte >= Byte.zero && byte <= Byte.nine else { return false }
                count += 1
            }
            return count <= 9
        }
        if first == Byte.backtick || first == Byte.tilde {
            for byte in body.utf8 {
                guard byte == first else { return false }
                count += 1
            }
            return count <= 2
        }
        return false
    }

    // MARK: Headings

    static func atxHeading(_ line: Substring, indent: Indent) -> (level: Int, text: String)? {
        guard indent.columns < 4 else { return nil }
        let utf8 = line.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: indent.bytes)
        var level = 0
        while index < utf8.endIndex && utf8[index] == Byte.hash {
            level += 1
            index = utf8.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        if index < utf8.endIndex && utf8[index] != Byte.space && utf8[index] != Byte.tab { return nil }
        var content = trim(line[index...])
        // Optional closing sequence: `## Title ##`.
        let cu = content.utf8
        var end = cu.endIndex
        while end > cu.startIndex && cu[cu.index(before: end)] == Byte.hash { end = cu.index(before: end) }
        if end != cu.endIndex {
            if end == cu.startIndex {
                content = content[cu.startIndex..<cu.startIndex]
            } else {
                let before = cu[cu.index(before: end)]
                if before == Byte.space || before == Byte.tab { content = trimTrailing(content[..<end]) }
            }
        }
        return (level, String(content))
    }

    /// `===` → 1, `---` → 2. A still-open streaming line needs at least three characters.
    static func setextLevel(_ line: Substring, lineIsOpen: Bool) -> Int? {
        let indent = leadingIndent(line)
        guard indent.columns < 4 else { return nil }
        let body = trimTrailing(line[line.utf8.index(line.utf8.startIndex, offsetBy: indent.bytes)...])
        guard let first = body.utf8.first, first == Byte.equals || first == Byte.dash else { return nil }
        var count = 0
        for byte in body.utf8 {
            guard byte == first else { return nil }
            count += 1
        }
        if lineIsOpen && count < 3 { return nil }
        return first == Byte.equals ? 1 : 2
    }

    static func isThematicBreak(_ line: Substring, indent: Indent) -> Bool {
        guard indent.columns < 4 else { return false }
        var marker: UInt8 = 0
        var count = 0
        for byte in line.utf8.dropFirst(indent.bytes) {
            if byte == Byte.space || byte == Byte.tab { continue }
            if marker == 0 {
                guard byte == Byte.dash || byte == Byte.star || byte == Byte.underscore else { return false }
                marker = byte
            } else if byte != marker {
                return false
            }
            count += 1
        }
        return count >= 3
    }

    // MARK: Code fences

    struct Fence: Equatable {
        var marker: UInt8
        var count: Int
        var indent: Int
        var language: String?
    }

    static func fenceOpen(_ line: Substring, indent: Indent) -> Fence? {
        guard indent.columns < 4 else { return nil }
        let utf8 = line.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: indent.bytes)
        guard index < utf8.endIndex else { return nil }
        let marker = utf8[index]
        guard marker == Byte.backtick || marker == Byte.tilde else { return nil }
        var count = 0
        while index < utf8.endIndex && utf8[index] == marker {
            count += 1
            index = utf8.index(after: index)
        }
        guard count >= 3 else { return nil }
        let info = trim(line[index...])
        if marker == Byte.backtick && info.utf8.contains(Byte.backtick) { return nil }
        var language: String?
        if !info.isEmpty {
            let word = info.utf8.firstIndex(where: { $0 == Byte.space || $0 == Byte.tab }).map { info[..<$0] } ?? info
            var cleaned = word
            if cleaned.hasPrefix("{") { cleaned = cleaned.dropFirst() }
            if cleaned.hasSuffix("}") { cleaned = cleaned.dropLast() }
            if cleaned.hasPrefix(".") { cleaned = cleaned.dropFirst() }
            language = cleaned.isEmpty ? nil : String(cleaned)
        }
        return Fence(marker: marker, count: count, indent: indent.columns, language: language)
    }

    static func isFenceClose(_ line: Substring, _ fence: Fence) -> Bool {
        let indent = leadingIndent(line)
        guard indent.columns < 4 else { return false }
        var count = 0
        var trailing = false
        for byte in line.utf8.dropFirst(indent.bytes) {
            if !trailing && byte == fence.marker {
                count += 1
            } else if byte == Byte.space || byte == Byte.tab {
                trailing = true
            } else {
                return false
            }
        }
        return count >= fence.count
    }

    // MARK: Block quotes

    /// The line's content after the `>` marker, or `nil` when the line is not a quote line.
    static func blockQuoteContent(_ line: Substring) -> Substring? {
        let indent = leadingIndent(line)
        guard indent.columns < 4 else { return nil }
        let utf8 = line.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: indent.bytes)
        guard index < utf8.endIndex, utf8[index] == Byte.greater else { return nil }
        index = utf8.index(after: index)
        if index < utf8.endIndex {
            if utf8[index] == Byte.space {
                index = utf8.index(after: index)
            } else if utf8[index] == Byte.tab {
                // The tab after `>` expands to 3 columns; one is the optional space.
                return Substring("  " + line[utf8.index(after: index)...])
            }
        }
        return line[index...]
    }

    // MARK: Lists

    struct ListMarker {
        enum Kind: Equatable {
            case bullet(UInt8)
            case ordered(delimiter: UInt8)
        }

        var kind: Kind
        var number: Int
        /// Column (relative to the line start) where the item's content begins.
        var contentColumn: Int
        /// The item's first line, without the marker.
        var content: Substring
        /// The marker is followed by nothing but whitespace.
        var isEmpty: Bool

        /// CommonMark: an empty item cannot interrupt a paragraph, an ordered one only when it starts at 1.
        func canInterruptParagraph(ignoringEmptiness: Bool) -> Bool {
            if isEmpty && !ignoringEmptiness { return false }
            if case .ordered = kind { return number == 1 }
            return true
        }
    }

    static func listMarker(_ line: Substring) -> ListMarker? {
        let indent = leadingIndent(line)
        guard indent.columns < 4 else { return nil }
        let utf8 = line.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: indent.bytes)
        guard index < utf8.endIndex else { return nil }
        let first = utf8[index]
        var kind: ListMarker.Kind
        var number = 0
        var width: Int
        if first == Byte.dash || first == Byte.star || first == Byte.plus {
            kind = .bullet(first)
            width = 1
            index = utf8.index(after: index)
        } else if first >= Byte.zero && first <= Byte.nine {
            var digits = 0
            while index < utf8.endIndex, utf8[index] >= Byte.zero, utf8[index] <= Byte.nine, digits < 10 {
                number = number * 10 + Int(utf8[index] - Byte.zero)
                digits += 1
                index = utf8.index(after: index)
            }
            guard digits <= 9, index < utf8.endIndex,
                  utf8[index] == Byte.dot || utf8[index] == Byte.rparen else { return nil }
            kind = .ordered(delimiter: utf8[index])
            width = digits + 1
            index = utf8.index(after: index)
        } else {
            return nil
        }
        let markerEnd = indent.columns + width
        if index == utf8.endIndex {
            return ListMarker(kind: kind, number: number, contentColumn: markerEnd + 1,
                              content: line[line.endIndex...], isEmpty: true)
        }
        guard utf8[index] == Byte.space || utf8[index] == Byte.tab else { return nil }
        let afterMarker = line[index...]
        var column = markerEnd
        var contentIndex = index
        while contentIndex < utf8.endIndex, utf8[contentIndex] == Byte.space || utf8[contentIndex] == Byte.tab {
            column += utf8[contentIndex] == Byte.tab ? 4 - column % 4 : 1
            contentIndex = utf8.index(after: contentIndex)
        }
        if contentIndex == utf8.endIndex {
            return ListMarker(kind: kind, number: number, contentColumn: markerEnd + 1,
                              content: line[line.endIndex...], isEmpty: true)
        }
        let spaces = column - markerEnd
        if spaces > 4 {
            // The content is indented code: the content column is one space after the marker.
            return ListMarker(kind: kind, number: number, contentColumn: markerEnd + 1,
                              content: dropIndent(afterMarker, columns: 1), isEmpty: false)
        }
        return ListMarker(kind: kind, number: number, contentColumn: column, content: line[contentIndex...],
                          isEmpty: false)
    }

    // MARK: Tables

    /// The column alignments when `line` is a table header followed by the delimiter row `delimiter`.
    /// While streaming, a started delimiter row (`|-`, `| :--`) already counts.
    static func tableDelimiter(for line: Substring, delimiter: Substring,
                               delimiterIsOpen: Bool) -> [MarkdownTableAlignment]? {
        let indent = leadingIndent(delimiter)
        guard indent.columns < 4, leadingIndent(line).columns < 4 else { return nil }
        let delimiterUTF8 = delimiter.utf8
        guard delimiterUTF8.contains(Byte.pipe), hasUnescapedPipe(line) else { return nil }
        // Quick reject: a delimiter row only contains `|`, `:`, `-` and whitespace.
        for byte in delimiterUTF8 where byte != Byte.pipe && byte != Byte.colon && byte != Byte.dash
            && byte != Byte.space && byte != Byte.tab {
            return nil
        }
        let headerCount = tableCells(line).count
        let cells = tableCells(delimiter)
        var alignments: [MarkdownTableAlignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let utf8 = cell.utf8
            let dashes = utf8.reduce(0) { $0 + ($1 == Byte.dash ? 1 : 0) }
            let left = utf8.first == Byte.colon
            let right = utf8.count > 1 && utf8.last == Byte.colon
            let colons = (left ? 1 : 0) + (right ? 1 : 0)
            guard dashes + colons == utf8.count else { return nil }
            if dashes == 0 {
                guard delimiterIsOpen else { return nil }
            }
            switch (left, right) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        if delimiterIsOpen {
            let started = delimiter.utf8.first(where: { $0 != Byte.space && $0 != Byte.tab }) == Byte.pipe
            guard started, headerCount > 0, alignments.count <= headerCount else { return nil }
            return alignments + Array(repeating: .none, count: headerCount - alignments.count)
        }
        guard !alignments.isEmpty, alignments.count == headerCount else { return nil }
        return alignments
    }

    private static func hasUnescapedPipe(_ line: Substring) -> Bool {
        var escaped = false
        for byte in line.utf8 {
            if escaped {
                escaped = false
            } else if byte == Byte.backslash {
                escaped = true
            } else if byte == Byte.pipe {
                return true
            }
        }
        return false
    }

    /// Splits a table row into trimmed cells on unescaped pipes; `\|` becomes a literal `|`.
    static func tableCells(_ line: Substring) -> [String] {
        let row = trim(line)
        var cells: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(32)
        var escaped = false
        var sawContent = false
        for byte in row.utf8 {
            if escaped {
                if byte != Byte.pipe { current.append(Byte.backslash) }
                current.append(byte)
                escaped = false
            } else if byte == Byte.backslash {
                escaped = true
            } else if byte == Byte.pipe {
                if sawContent || !cells.isEmpty || !current.isEmpty {
                    cells.append(String(trim(Substring(String(decoding: current, as: UTF8.self)))))
                }
                current.removeAll(keepingCapacity: true)
                sawContent = true
            } else {
                current.append(byte)
            }
        }
        if escaped { current.append(Byte.backslash) }
        let last = String(trim(Substring(String(decoding: current, as: UTF8.self))))
        // A trailing pipe ends the row; text after the last pipe is a cell.
        if !last.isEmpty || row.utf8.last != Byte.pipe { cells.append(last) }
        return cells
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    // MARK: Paragraph text

    /// Joins paragraph lines: leading whitespace removed, soft breaks → `"\n"`, hard breaks → U+2028.
    static func paragraphText(_ lines: [Substring]) -> String {
        if lines.count == 1 { return String(trim(lines[0])) }
        var out = ""
        out.reserveCapacity(lines.reduce(0) { $0 + $1.utf8.count + 1 })
        for (index, raw) in lines.enumerated() {
            let line = trimLeading(raw)
            if index == lines.count - 1 {
                out += trimTrailing(line)
                break
            }
            var spaces = 0
            for byte in line.utf8.reversed() {
                guard byte == Byte.space else { break }
                spaces += 1
            }
            var content = trimTrailing(line)
            var hard = spaces >= 2
            if !hard {
                var backslashes = 0
                for byte in content.utf8.reversed() {
                    guard byte == Byte.backslash else { break }
                    backslashes += 1
                }
                if backslashes % 2 == 1 {
                    hard = true
                    content = content.dropLast()
                }
            }
            out += content
            out.append(hard ? MarkdownBlock.hardLineBreak : "\n")
        }
        return out
    }
}

/// ASCII byte constants used by the parsers.
enum Byte {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang = UInt8(ascii: "!")
    static let quote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let dollar = UInt8(ascii: "$")
    static let percent = UInt8(ascii: "%")
    static let ampersand = UInt8(ascii: "&")
    static let apostrophe = UInt8(ascii: "'")
    static let lparen = UInt8(ascii: "(")
    static let rparen = UInt8(ascii: ")")
    static let star = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let dash = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let colon = UInt8(ascii: ":")
    static let semicolon = UInt8(ascii: ";")
    static let less = UInt8(ascii: "<")
    static let equals = UInt8(ascii: "=")
    static let greater = UInt8(ascii: ">")
    static let question = UInt8(ascii: "?")
    static let at = UInt8(ascii: "@")
    static let upperA = UInt8(ascii: "A")
    static let upperZ = UInt8(ascii: "Z")
    static let upperX = UInt8(ascii: "X")
    static let lbracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let rbracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
    static let backtick = UInt8(ascii: "`")
    static let lowerA = UInt8(ascii: "a")
    static let lowerX = UInt8(ascii: "x")
    static let lowerZ = UInt8(ascii: "z")
    static let lbrace = UInt8(ascii: "{")
    static let pipe = UInt8(ascii: "|")
    static let rbrace = UInt8(ascii: "}")
    static let tilde = UInt8(ascii: "~")
}
