import NEBULACore
import NEBULADesignSystem
import SwiftUI

// MARK: - Avatar

/// The agent's avatar. Emoji and initials are drawn by NAvatar; icons use the host's full icon set (NAvatar's own
/// symbol table only knows part of it) on the same tinted circle.
struct AgentAvatarView: View {
    let name: String
    let avatar: AgentAvatar?
    let seed: String
    var size: CGFloat = 44

    init(agent: Agent, size: CGFloat = 44) {
        self.name = agent.name; self.avatar = agent.config?.avatar; self.seed = agent.id; self.size = size
    }

    init(name: String, avatar: AgentAvatar?, seed: String, size: CGFloat = 44) {
        self.name = name; self.avatar = avatar; self.seed = seed; self.size = size
    }

    var body: some View {
        if let avatar, avatar.kind == "icon" {
            NAvatar(name: name, spec: AvatarSpec(kind: .initials, value: " "), seed: seed, size: size)
                .overlay {
                    Image(systemName: AText.iconSymbol(avatar.value))
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
        } else {
            NAvatar(name: name, spec: AgentsStore.avatarSpec(avatar), seed: seed, size: size)
        }
    }
}

// MARK: - Status

/// Status dot + state, and the live stage ("Thinking · 12 s") while the agent works.
struct AgentStatusLine: View {
    let agent: Agent
    let stage: AgentStage?
    var font: Font = .subheadline

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: AText.activityColor(agent.activity), pulsing: agent.activity == .working)
            if agent.activity == .working, let stage {
                StageText(stage: stage).font(font).foregroundStyle(NColor.accent)
            } else {
                Text(AText.status(agent)).font(font).foregroundStyle(NColor.textSecondary)
            }
        }
        .lineLimit(1)
    }
}

/// The stage line; the elapsed seconds tick only while the text is on screen (TimelineView pauses off screen).
struct StageText: View {
    let stage: AgentStage

    var body: some View {
        if stage.elapsedMs != nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(stage.line(at: ctx.date)).monospacedDigit()
            }
        } else {
            Text(stage.label)
        }
    }
}

// MARK: - Transient banner

/// A short result / error banner at the top of a view; tap to dismiss, disappears after a few seconds.
struct BannerContent: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var style: NBanner.Style

    static func == (l: BannerContent, r: BannerContent) -> Bool { l.id == r.id }

    static func error(_ text: String) -> BannerContent { BannerContent(text: text, style: .danger) }
    static func success(_ text: String) -> BannerContent { BannerContent(text: text, style: .success) }
    static func info(_ text: String) -> BannerContent { BannerContent(text: text, style: .info) }

    /// The banner for an action result (nil when cancelled or when a success needs no words).
    static func from(_ r: AgentsStore.ActionResult, success: String? = nil) -> BannerContent? {
        switch r {
        case .done: return success.map { .success($0) }
        case .cancelled: return nil
        case .failed(let m): return .error(m)
        }
    }
}

private struct TransientBannerModifier: ViewModifier {
    @Binding var banner: BannerContent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let b = banner {
                    NBanner(b.text, style: b.style)
                        .background(NColor.surface, in: RoundedRectangle(cornerRadius: NRadius.m, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                        .padding(.horizontal, NSpace.l)
                        .padding(.vertical, NSpace.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .onTapGesture { banner = nil }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Tap to close"))
                }
            }
            .nAnimation(NMotion.smooth, value: banner)
            .task(id: banner) {
                guard let b = banner else { return }
                AccessibilityNotification.Announcement(b.text).post()
                try? await Task.sleep(for: .seconds(b.style == .danger ? 6 : 3.5))
                if !Task.isCancelled, banner == b { banner = nil }
            }
    }
}

extension View {
    func transientBanner(_ banner: Binding<BannerContent?>) -> some View {
        modifier(TransientBannerModifier(banner: banner))
    }

    /// Grouped form look on both platforms (insetGrouped on iOS, System Settings style on macOS).
    func agentsFormStyle() -> some View {
        formStyle(.grouped)
    }

    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Pointer hover feedback (iPad pointer / Mac mouse).
    func hoverHighlight(cornerRadius: CGFloat = NRadius.m) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content.hoverEffect(.highlight)
        #else
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)).allowsHitTesting(false))
            .onHover { hovering = $0 }
            .animation(NMotion.fade, value: hovering)
        #endif
    }
}

// MARK: - Quick action tile

/// Contacts-style action tile (icon above a short label).
struct QuickActionTile: View {
    let title: String
    let symbol: String
    var tint: Color = NColor.accent
    var busy = false
    var enabled = true
    var shortcut: KeyEquivalent?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).font(.title3.weight(.semibold)).symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(height: 24)
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(enabled ? tint : NColor.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NSpace.m)
            .padding(.horizontal, NSpace.xs)
            .background(RoundedRectangle(cornerRadius: NRadius.m, style: .continuous).fill(tileBackground))
            .contentShape(RoundedRectangle(cornerRadius: NRadius.m, style: .continuous))
            .hoverHighlight()
        }
        .buttonStyle(NPressableStyle())
        .disabled(!enabled || busy)
        .modifier(OptionalShortcut(key: shortcut))
        .accessibilityLabel(Text(title))
    }

    private var tileBackground: Color {
        #if os(macOS)
        NColor.surfaceSunken
        #else
        NColor.surface
        #endif
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}

// MARK: - Misc

/// A label + value row that wraps nicely at large Dynamic Type sizes.
struct InfoRow: View {
    let title: String
    let value: String
    var symbol: String?
    var mono = false

    var body: some View {
        LabeledContent {
            Text(value)
                .font(mono ? NFont.monoSmall : .body)
                .foregroundStyle(NColor.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
