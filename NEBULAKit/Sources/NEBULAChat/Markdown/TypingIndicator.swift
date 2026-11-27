import SwiftUI
import NEBULADesignSystem

/// Three dots rising and fading in a gentle wave while the agent composes its answer.
/// Under Reduce Motion it is a static "…". VoiceOver: "Agent is typing".
public struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 7

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                Text(verbatim: "…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NColor.textSecondary)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: dotSize * 0.6) {
                        ForEach(0..<3, id: \.self) { index in
                            let lift = Self.wave(time: time, index: index)
                            Circle()
                                .fill(NColor.textSecondary)
                                .frame(width: dotSize, height: dotSize)
                                .scaleEffect(0.8 + 0.2 * lift)
                                .opacity(0.35 + 0.65 * lift)
                                .offset(y: -dotSize * 0.45 * lift)
                        }
                    }
                    .frame(height: dotSize * 2, alignment: .bottom)
                }
            }
        }
        .padding(.vertical, NSpace.xs)
        .accessibilityElement()
        .accessibilityLabel(Text("Agent is typing"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// 0…1 lift of dot `index` at `time`: a smooth bump during the first half of a 1.2 s cycle, staggered per dot.
    static func wave(time: TimeInterval, index: Int) -> Double {
        let period = 1.2
        var phase = (time / period - Double(index) * 0.15).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        guard phase < 0.5 else { return 0 }
        let s = sin(phase * 2 * .pi)
        return s * s
    }
}
