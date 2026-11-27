import SwiftUI
import NEBULADesignSystem

/// Marks the caret glyph inside a `Text` so ``StreamingCaretRenderer`` can fade only that glyph.
struct StreamingCaretAttribute: TextAttribute {}

/// Draws the text normally and the caret run with an animatable opacity. Only redraws (no relayout) while the
/// caret pulses, so streaming text stays cheap.
struct StreamingCaretRenderer: TextRenderer {
    var caretOpacity: Double

    var animatableData: Double {
        get { caretOpacity }
        set { caretOpacity = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[StreamingCaretAttribute.self] != nil {
                    var caretContext = context
                    caretContext.opacity = caretOpacity
                    caretContext.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
    }
}

/// `text` followed by a softly pulsing accent caret (static under Reduce Motion). The caret is inline, so it sits
/// right after the last character however the text wraps; VoiceOver reads only `text`.
struct StreamingCaretText: View {
    let text: Text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        let caret = Text(verbatim: "\u{200A}\u{258E}")
            .foregroundStyle(NColor.accent)
            .customAttribute(StreamingCaretAttribute())
        Text("\(text)\(caret)")
            .textRenderer(StreamingCaretRenderer(caretOpacity: reduceMotion ? 0.8 : (dimmed ? 0.15 : 1)))
            .accessibilityLabel(text)
            .onAppear {
                guard !reduceMotion, !dimmed else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dimmed = true }
            }
    }
}

/// A caret on its own line (after a table, a rule, or before the first character arrives).
struct StreamingCaret: View {
    var body: some View {
        StreamingCaretText(text: Text(verbatim: ""))
            .accessibilityHidden(true)
    }
}
