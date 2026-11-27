import SwiftUI
import NEBULADesignSystem

/// Renders a Markdown message with native SwiftUI views (`Text`, stacks, grids). No WebView and no HTML rendering:
/// raw HTML is shown as literal text, and only `http`, `https` and `mailto` links are tappable.
///
/// - Text is selectable, uses Dynamic Type text styles throughout and follows light / dark mode.
/// - Parsing is cached per message (``MarkdownDocument/parse(_:id:isStreaming:)``); while streaming only the tail
///   is re-parsed and every block keeps a stable identity (its index), so arriving text never rebuilds or jumps
///   the blocks above it.
/// - While `isStreaming` is `true` a subtle pulsing caret follows the last character (static under Reduce Motion).
public struct MarkdownView: View {
    private let text: String
    private let isStreaming: Bool
    private let id: String?

    /// - Parameters:
    ///   - text: The Markdown source.
    ///   - isStreaming: `true` while the message is still being generated.
    ///   - id: A stable message id (recommended): enables the per-message cache and incremental re-parsing.
    public init(text: String, isStreaming: Bool = false, id: String? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.id = id
    }

    public var body: some View {
        let document = MarkdownDocument.parse(text, id: id, isStreaming: isStreaming)
        MarkdownBlockList(blocks: document.blocks, depth: 0, spacing: MarkdownMetrics.blockSpacing,
                          showsCaret: isStreaming)
            .foregroundStyle(NColor.textPrimary)
            .tint(NColor.accent)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
    }
}

enum MarkdownMetrics {
    /// Space between top-level blocks (paragraph spacing).
    static let blockSpacing: CGFloat = NSpace.m
    /// Space above a heading that follows other content.
    static func headingTopPadding(level: Int) -> CGFloat { level <= 2 ? NSpace.s : NSpace.xs }

    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        case 4: .subheadline.weight(.semibold)
        case 5: .footnote.weight(.semibold)
        default: .footnote.weight(.medium)
        }
    }

    static func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

/// A vertical list of blocks; children are identified by index so streaming updates keep view identity.
struct MarkdownBlockList: View {
    let blocks: [MarkdownBlock]
    let depth: Int
    let spacing: CGFloat
    let showsCaret: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], depth: depth, isFirst: index == 0,
                                  showsCaret: showsCaret && index == blocks.count - 1)
                    .equatable()
            }
            if blocks.isEmpty && showsCaret {
                StreamingCaret()
            }
        }
    }
}

/// One block. Equatable, so SwiftUI skips unchanged blocks entirely while a message streams.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let depth: Int
    let isFirst: Bool
    let showsCaret: Bool

    nonisolated static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.depth == rhs.depth && lhs.isFirst == rhs.isFirst && lhs.showsCaret == rhs.showsCaret
            && lhs.block == rhs.block
    }

    var body: some View {
        switch block {
        case .paragraph(let text):
            MarkdownTextBlock(text: text, level: nil, showsCaret: showsCaret)
        case .heading(let level, let text):
            MarkdownTextBlock(text: text, level: level, showsCaret: showsCaret)
                .padding(.top, isFirst ? 0 : MarkdownMetrics.headingTopPadding(level: level))
        case .list(let list):
            MarkdownListView(list: list, depth: depth, showsCaret: showsCaret)
        case .blockQuote(let children):
            MarkdownQuoteView(blocks: children, depth: depth, showsCaret: showsCaret)
        case .codeBlock(let code):
            CodeBlockView(code: code.code, language: code.language, showsCaret: showsCaret)
        case .table(let table):
            VStack(alignment: .leading, spacing: NSpace.xs) {
                MarkdownTableView(table: table)
                if showsCaret { StreamingCaret() }
            }
        case .thematicBreak:
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Rectangle()
                    .fill(NColor.separator)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NSpace.xs)
                    .accessibilityHidden(true)
                if showsCaret { StreamingCaret() }
            }
        }
    }
}

// MARK: - Text

/// A paragraph or heading.
struct MarkdownTextBlock: View {
    let text: String
    /// Heading level, or `nil` for a paragraph.
    let level: Int?
    let showsCaret: Bool
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    var body: some View {
        let attributed = Text(MarkdownInlineRenderer.attributedString(text))
        Group {
            if showsCaret {
                StreamingCaretText(text: attributed)
            } else {
                attributed
            }
        }
        .font(level.map(MarkdownMetrics.headingFont(level:)) ?? .body)
        .lineSpacing(level == nil ? lineSpacing : 1)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(HeadingStyle(level: level))
    }
}

/// Heading semantics for VoiceOver; minor headings (h5, h6) in the secondary color. Paragraphs inherit the
/// foreground style (primary text, secondary inside quotes).
private struct HeadingStyle: ViewModifier {
    let level: Int?

    func body(content: Content) -> some View {
        if let level {
            if level >= 5 {
                content
                    .foregroundStyle(NColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(MarkdownMetrics.headingLevel(level))
            } else {
                content
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(MarkdownMetrics.headingLevel(level))
            }
        } else {
            content
        }
    }
}

// MARK: - Lists

struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int
    let showsCaret: Bool

    var body: some View {
        let spacing = list.isTight ? NSpace.xs : NSpace.s
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: NSpace.s) {
                    marker(for: item, index: index)
                    MarkdownBlockList(blocks: item.blocks, depth: depth + 1, spacing: spacing,
                                      showsCaret: showsCaret && index == list.items.count - 1)
                }
            }
        }
    }

    /// The marker in a column as wide as the list's widest marker, so item text lines up.
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        ZStack(alignment: .trailing) {
            // Width reference (invisible).
            Group {
                if list.items.contains(where: { $0.task != nil }) { taskSymbol(.unchecked) }
                if case .ordered(let start) = list.kind {
                    Text(verbatim: "\(start + list.items.count - 1).").monospacedDigit()
                } else if list.items.contains(where: { $0.task == nil }) {
                    Text(verbatim: bullet)
                }
            }
            .hidden()

            if let task = item.task {
                taskSymbol(task)
                    .accessibilityLabel(task == .checked ? Text("Met") : Text("Not met"))
            } else if case .ordered(let start) = list.kind {
                Text(verbatim: "\(start + index).")
                    .monospacedDigit()
                    .foregroundStyle(NColor.textSecondary)
            } else {
                Text(verbatim: bullet)
                    .foregroundStyle(NColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.body)
    }

    private var bullet: String {
        switch depth % 3 {
        case 0: "•"
        case 1: "◦"
        default: "▪︎"
        }
    }

    private func taskSymbol(_ state: MarkdownTaskState) -> some View {
        Image(systemName: state == .checked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(state == .checked ? NColor.accent : NColor.textTertiary)
            .imageScale(.medium)
    }
}

// MARK: - Block quotes

struct MarkdownQuoteView: View {
    let blocks: [MarkdownBlock]
    let depth: Int
    let showsCaret: Bool
    @ScaledMetric(relativeTo: .body) private var barWidth: CGFloat = 3

    var body: some View {
        MarkdownBlockList(blocks: blocks, depth: depth, spacing: NSpace.s, showsCaret: showsCaret)
            .foregroundStyle(NColor.textSecondary)
            .padding(.leading, barWidth + NSpace.m)
            .padding(.vertical, NSpace.xxs)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(NColor.accent.opacity(0.8))
                    .frame(width: barWidth)
                    .accessibilityHidden(true)
            }
    }
}

// MARK: - Tables

struct MarkdownTableView: View {
    let table: MarkdownTable
    @ScaledMetric(relativeTo: .subheadline) private var maxColumnWidth: CGFloat = 260

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[column], column: column, row: -1)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Rectangle()
                        .fill(NColor.separator)
                        .frame(height: 0.5)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(table.rows[row][column], column: column, row: row)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NRadius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NRadius.s, style: .continuous)
                .strokeBorder(NColor.separator, lineWidth: 1))
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Table"))
    }

    private func cell(_ text: String, column: Int, row: Int) -> some View {
        let alignment = table.alignments[column]
        let isHeader = row < 0
        return MarkdownCappedWidth(maxWidth: maxColumnWidth) {
            Text(MarkdownInlineRenderer.attributedString(text))
                .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                .multilineTextAlignment(alignment.textAlignment)
        }
        .padding(.horizontal, NSpace.m)
        .padding(.vertical, NSpace.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frameAlignment)
        .background(isHeader ? MarkdownPalette.headerBackground
                             : (row.isMultiple(of: 2) ? Color.clear : NColor.surfaceSunken.opacity(0.45)))
    }
}

private extension MarkdownTableAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .center: .center
        case .right: .trailing
        case .left, .none: .leading
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .center: .center
        case .right: .trailing
        case .left, .none: .leading
        }
    }
}

/// Lays its child out at `min(ideal width, maxWidth)`, so long table cells wrap while short ones stay compact
/// (a plain `.frame(maxWidth:)` cannot do this inside a horizontal scroll view, which proposes no width).
struct MarkdownCappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        let fitted = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let width = min(bounds.width, maxWidth)
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
}
