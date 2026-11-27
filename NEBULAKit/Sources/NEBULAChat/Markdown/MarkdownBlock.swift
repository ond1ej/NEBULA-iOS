import Foundation

// The block model of a parsed Markdown message. Every type is a plain value (Hashable, Sendable), so documents can be
// parsed off the main actor, cached, compared cheaply and diffed by SwiftUI.

/// One block-level element of a Markdown message.
///
/// Inline content (`text`, table cells) is kept as *inline Markdown source*; it is turned into styled text by
/// ``MarkdownInlineRenderer`` (bold, italic, strikethrough, inline code, safe links). Raw HTML is never interpreted:
/// it stays literal text.
public enum MarkdownBlock: Hashable, Sendable {
    /// An ATX (`## Title`) or setext (`Title` underlined with `===` / `---`) heading. `level` is 1...6.
    case heading(level: Int, text: String)
    /// A paragraph of inline Markdown. Soft line breaks are `"\n"`; hard line breaks (two trailing spaces or a
    /// trailing backslash) are ``MarkdownBlock/hardLineBreak``. The renderer shows both as line breaks
    /// (chat convention, like GitHub comments).
    case paragraph(text: String)
    /// A bullet, numbered or task list (items may contain nested blocks, including further lists).
    case list(MarkdownList)
    /// A block quote with its nested blocks (quotes may nest).
    case blockQuote([MarkdownBlock])
    /// A fenced (```` ``` ```` / `~~~`) or indented code block.
    case codeBlock(MarkdownCodeBlock)
    /// A GitHub-flavoured table.
    case table(MarkdownTable)
    /// A thematic break (`---`, `***`, `___`).
    case thematicBreak

    /// The character that marks a hard line break inside paragraph text (U+2028 LINE SEPARATOR).
    public static let hardLineBreak: Character = "\u{2028}"
}

/// A fenced or indented code block.
public struct MarkdownCodeBlock: Hashable, Sendable {
    /// The first word of the fence's info string (` ```swift title="x" ` → `"swift"`), or `nil`.
    public var language: String?
    /// The code, lines joined with `"\n"` (no trailing newline).
    public var code: String
    /// `true` for fenced blocks, `false` for blocks indented by four spaces.
    public var isFenced: Bool
    /// `false` while a fenced block has no closing fence yet (typically while the message is still streaming).
    public var isClosed: Bool

    public init(language: String?, code: String, isFenced: Bool = true, isClosed: Bool = true) {
        self.language = language
        self.code = code
        self.isFenced = isFenced
        self.isClosed = isClosed
    }
}

/// A bullet, ordered or task list.
public struct MarkdownList: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `-`, `*` or `+` items.
        case bullet
        /// `1.` / `1)` items; `start` is the number of the first item.
        case ordered(start: Int)
    }

    public var kind: Kind
    /// A tight list has no blank lines between its items (rendered with compact spacing).
    public var isTight: Bool
    public var items: [MarkdownListItem]

    public init(kind: Kind, isTight: Bool, items: [MarkdownListItem]) {
        self.kind = kind
        self.isTight = isTight
        self.items = items
    }
}

/// One list item: an optional task checkbox and the item's blocks.
public struct MarkdownListItem: Hashable, Sendable {
    /// `[ ]` / `[x]` task state, or `nil` for a plain item.
    public var task: MarkdownTaskState?
    public var blocks: [MarkdownBlock]

    public init(task: MarkdownTaskState? = nil, blocks: [MarkdownBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

/// The state of a GitHub task-list item.
public enum MarkdownTaskState: Hashable, Sendable {
    case unchecked
    case checked
}

/// The horizontal alignment of a table column (`:---`, `:---:`, `---:`).
public enum MarkdownTableAlignment: Hashable, Sendable {
    case none
    case left
    case center
    case right
}

/// A GitHub-flavoured table. Every row has exactly `alignments.count` cells (missing cells are empty strings).
public struct MarkdownTable: Hashable, Sendable {
    public var alignments: [MarkdownTableAlignment]
    /// Header cells (inline Markdown).
    public var header: [String]
    /// Body rows (inline Markdown cells).
    public var rows: [[String]]

    public init(alignments: [MarkdownTableAlignment], header: [String], rows: [[String]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    /// The number of columns.
    public var columnCount: Int { alignments.count }
}
