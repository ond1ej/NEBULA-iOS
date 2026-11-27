import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Motion tokens. Springs are critically tuned (no wobble) so 120 Hz ProMotion stays smooth and calm.
/// Every animation goes through `NMotion.animation(_:reduceMotion:)` so Reduce Motion is always respected.
public enum NMotion {
    public static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
    public static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.88)
    public static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.9)
    public static let fade = Animation.easeOut(duration: 0.18)

    public static func animation(_ a: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : a
    }
}

public extension View {
    /// Animate `value` changes with a NEBULA spring, or a short fade under Reduce Motion.
    func nAnimation<V: Equatable>(_ animation: Animation = NMotion.smooth, value: V) -> some View {
        modifier(NAnimationModifier(animation: animation, value: value))
    }

    /// Message / card entrance: fades and rises a few points (no movement under Reduce Motion).
    func nAppear(delay: Double = 0) -> some View { modifier(AppearModifier(delay: delay)) }
}

private struct NAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(NMotion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct AppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(NMotion.animation(NMotion.smooth.delay(delay), reduceMotion: reduceMotion)) { shown = true }
            }
    }
}

/// Haptic feedback (iPhone Taptic Engine; Force Touch trackpad on the Mac). Generators are prepared once and reused.
@MainActor
public enum Haptics {
    #if os(iOS)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let notify = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()
    #endif

    public static func tap() {
        #if os(iOS)
        light.impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    public static func soft() {
        #if os(iOS)
        softImpact.impactOccurred(intensity: 0.7)
        #endif
    }

    public static func selection() {
        #if os(iOS)
        select.selectionChanged()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    public static func success() {
        #if os(iOS)
        notify.notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    public static func warning() {
        #if os(iOS)
        notify.notificationOccurred(.warning)
        #endif
    }

    public static func error() {
        #if os(iOS)
        notify.notificationOccurred(.error)
        #endif
    }
}
