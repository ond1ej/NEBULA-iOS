import SwiftUI
import NEBULADesignSystem

/// A code block: language label, Copy button and monospaced, syntax-highlighted code that scrolls horizontally
/// (lines never wrap).
///
/// Highlighting is cached; small blocks (up to ``synchronousLimit`` bytes, well under 1 ms) are highlighted
/// synchronously, larger ones off the main thread. While a large block streams, the last highlighted prefix is reused and only the new
/// tail is shown plain until its highlight arrives, so the colors never flash.
public struct CodeBlockView: View {
    private let code: String
    private let language: String?
    private let showsCaret: Bool

    @State private var copied = false
    @State private var background: HighlightResult?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Code up to this size (UTF-8 bytes) is highlighted synchronously during `body`.
    static let synchronousLimit = 2_048

    /// - Parameters:
    ///   - code: The code (shown verbatim).
    ///   - language: The fence's language (`swift`, `py`, `ts`, …); unknown or `nil` shows plain code.
    public init(code: String, language: String?) {
        self.init(code: code, language: language, showsCaret: false)
    }

    init(code: String, language: String?, showsCaret: Bool) {
        self.code = code
        self.language = language
        self.showsCaret = showsCaret
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NRadius.m, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(NColor.separator.opacity(0.8))
                .frame(height: 0.5)
                .accessibilityHidden(true)
            ScrollView(.horizontal) {
                codeText
                    .font(Self.codeFont)
                    .lineSpacing(2)
                    .foregroundStyle(NColor.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, NSpace.m)
                    .padding(.vertical, NSpace.s + NSpace.xxs)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(NColor.codeBackground, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(NColor.separator.opacity(0.8), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .task(id: HighlightRequest(code: code, language: language)) { await highlightInBackgroundIfNeeded() }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            withAnimation(NMotion.animation(NMotion.snappy, reduceMotion: reduceMotion)) { copied = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: NSpace.s) {
            Text(verbatim: languageLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NColor.textSecondary)
                .lineLimit(1)
                .accessibilityLabel(Text("Code \(languageLabel)"))
            Spacer(minLength: NSpace.s)
            Button(action: copy) {
                Label {
                    Text(copied ? "Copied" : "Copy")
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(copied ? NColor.success : NColor.textSecondary)
                .padding(.vertical, NSpace.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
        }
        .padding(.horizontal, NSpace.m)
        .padding(.vertical, NSpace.xxs)
        .background(MarkdownPalette.headerBackground)
    }

    private var languageLabel: String {
        guard let language, !language.isEmpty else { return String(localized: "Code") }
        return SyntaxLanguage(identifier: language)?.displayName ?? language
    }

    private func copy() {
        MarkdownPasteboard.copy(code)
        Haptics.success()
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        withAnimation(NMotion.animation(NMotion.snappy, reduceMotion: reduceMotion)) { copied = true }
    }

    // MARK: Code

    @ViewBuilder
    private var codeText: some View {
        let text = Text(highlighted)
        if showsCaret {
            StreamingCaretText(text: text)
        } else {
            text
        }
    }

    private var highlighted: AttributedString {
        if let cached = SyntaxHighlighter.cachedHighlight(code, language: language) { return cached }
        if code.utf8.count <= Self.synchronousLimit { return SyntaxHighlighter.highlight(code, language: language) }
        // Large block: reuse the previous (background) highlight for the unchanged prefix.
        if let previous = background, previous.language == language, code.utf8.starts(with: previous.code.utf8) {
            let utf8 = code.utf8
            var result = previous.attributed
            result.append(AttributedString(String(code[utf8.index(utf8.startIndex,
                                                                    offsetBy: previous.code.utf8.count)...])))
            return result
        }
        return AttributedString(code)
    }

    private func highlightInBackgroundIfNeeded() async {
        guard code.utf8.count > Self.synchronousLimit,
              SyntaxHighlighter.cachedHighlight(code, language: language) == nil else { return }
        let code = code
        let language = language
        let attributed = await Task.detached(priority: .userInitiated) {
            SyntaxHighlighter.highlight(code, language: language)
        }.value
        guard !Task.isCancelled else { return }
        background = HighlightResult(code: code, language: language, attributed: attributed)
    }

    static var codeFont: Font {
        #if os(macOS)
        NFont.mono
        #else
        NFont.monoSmall
        #endif
    }
}

private struct HighlightRequest: Hashable {
    var code: String
    var language: String?
}

private struct HighlightResult {
    var code: String
    var language: String?
    var attributed: AttributedString
}
