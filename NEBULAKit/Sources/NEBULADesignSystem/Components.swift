import SwiftUI

// MARK: - Skeleton loading

/// Shimmering placeholder. One shared TimelineView-free gradient sweep per view (GPU-only, no layout work);
/// static under Reduce Motion.
public struct Skeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = NRadius.s) { self.cornerRadius = cornerRadius }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(NColor.surfaceSunken)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, NColor.surface.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityHidden(true)
    }
}

/// A list row placeholder (avatar + two lines).
public struct SkeletonRow: View {
    public init() {}
    public var body: some View {
        HStack(spacing: NSpace.m) {
            Skeleton(cornerRadius: 22).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: NSpace.s) {
                Skeleton().frame(width: 150, height: 12)
                Skeleton().frame(maxWidth: .infinity).frame(height: 10)
            }
        }
        .padding(.vertical, NSpace.s)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

// MARK: - Avatar

public struct AvatarSpec: Hashable, Sendable {
    public enum Kind: String, Sendable { case emoji, initials, icon }
    public var kind: Kind
    public var value: String
    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }
}

/// Agent avatar: emoji, initials or an SF Symbol on a soft tinted circle derived from a stable seed.
public struct NAvatar: View {
    let name: String
    let spec: AvatarSpec?
    let size: CGFloat
    let seed: String

    public init(name: String, spec: AvatarSpec? = nil, seed: String? = nil, size: CGFloat = 44) {
        self.name = name
        self.spec = spec
        self.size = size
        self.seed = seed ?? name
    }

    private var hue: Double {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    public var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.95),
                                                  Color(hue: hue + 0.06, saturation: 0.6, brightness: 0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            switch spec?.kind {
            case .emoji?:
                Text(spec?.value ?? "").font(.system(size: size * 0.5))
            case .icon?:
                Image(systemName: Self.symbol(for: spec?.value ?? ""))
                    .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            default:
                Text(spec?.value.isEmpty == false ? spec!.value : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The server's fixed icon ids (agent_composer.ICONS) → SF Symbols.
    public static func symbol(for id: String) -> String {
        switch id {
        case "robot": return "cpu"
        case "spark": return "sparkle"
        case "brain": return "brain.head.profile"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "search": return "magnifyingglass"
        case "chart": return "chart.bar.xaxis"
        case "briefcase": return "briefcase.fill"
        case "globe": return "globe"
        case "shield": return "lock.shield"
        case "book": return "book.fill"
        case "bolt": return "bolt.fill"
        case "star": return "star.fill"
        case "mail": return "envelope.fill"
        case "calendar": return "calendar"
        case "music": return "music.note"
        case "camera": return "camera.fill"
        default: return "sparkles"
        }
    }
}

// MARK: - Status

public struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    public init(color: Color, pulsing: Bool = false) { self.color = color; self.pulsing = pulsing }

    public var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 1)
                }
            }
            .onAppear {
                guard pulsing && !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

public struct NBadge: View {
    let text: String
    let tint: Color
    public init(_ text: String, tint: Color = NColor.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

// MARK: - Buttons

public struct NPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14).padding(.horizontal, NSpace.xl)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: NRadius.m, style: .continuous)
                .fill(NColor.accentGradient).opacity(enabled ? 1 : 0.45))
            .foregroundStyle(NColor.onAccent)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(NMotion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

public struct NSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.vertical, 13).padding(.horizontal, NSpace.xl)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: NRadius.m, style: .continuous).fill(NColor.accentSoft))
            .foregroundStyle(NColor.accent)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(NMotion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Press feedback for custom tappable rows/cards.
public struct NPressableStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(NMotion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Surfaces

public struct NCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(NSpace.l)
            .background(RoundedRectangle(cornerRadius: NRadius.l, style: .continuous).fill(NColor.surface))
            .overlay(RoundedRectangle(cornerRadius: NRadius.l, style: .continuous)
                .strokeBorder(NColor.separator.opacity(0.6), lineWidth: 0.5))
    }
}

public extension View {
    /// Native "Liquid Glass" on iOS / macOS 26+, a thin material before.
    @ViewBuilder
    func nGlass(cornerRadius: CGFloat = NRadius.xl) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

public struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.symbol = symbol; self.title = title; self.message = message
    }
    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// Small inline banner for connection / vault / error notices.
public struct NBanner: View {
    public enum Style: Sendable { case info, warning, danger, success }
    let style: Style
    let text: String
    let symbol: String?
    public init(_ text: String, style: Style = .info, symbol: String? = nil) {
        self.text = text; self.style = style; self.symbol = symbol
    }
    private var tint: Color {
        switch style {
        case .info: NColor.info
        case .warning: NColor.warning
        case .danger: NColor.danger
        case .success: NColor.success
        }
    }
    private var icon: String {
        symbol ?? {
            switch style {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .danger: "xmark.octagon.fill"
            case .success: "checkmark.circle.fill"
            }
        }()
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NSpace.s) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(NColor.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(NSpace.m)
        .background(RoundedRectangle(cornerRadius: NRadius.m, style: .continuous).fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}
