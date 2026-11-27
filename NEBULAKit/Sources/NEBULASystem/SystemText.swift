import Foundation
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// Localized labels for system states and user-facing error messages.
enum SText {
    static func vmState(_ s: String?) -> String {
        switch s {
        case "running": return String(localized: "Running")
        case "stopped", "not_running", "shutoff": return String(localized: "Stopped")
        case "starting": return String(localized: "Starting")
        case "stopping": return String(localized: "Stopping")
        case "restarting": return String(localized: "Restarting")
        case "failed": return String(localized: "Failed")
        case "unresponsive": return String(localized: "Not responding")
        case "paused": return String(localized: "Paused")
        case "not_created", "missing": return String(localized: "Not created")
        case "error": return String(localized: "Error")
        case nil: return String(localized: "Unknown state")
        case let s?: return s.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func vmColor(_ s: String?) -> Color {
        switch s {
        case "running": return NColor.success
        case "starting", "stopping", "restarting": return NColor.info
        case "failed", "unresponsive", "error": return NColor.danger
        default: return NColor.textTertiary
        }
    }

    static func guest(_ s: String?) -> String {
        switch s {
        case "ok": return String(localized: "Responding")
        case "vm_not_running": return String(localized: "VM is not running")
        case "unavailable": return String(localized: "Unavailable")
        case "filesystem_read_only": return String(localized: "Read-only disk")
        case nil: return "–"
        case let s?: return s.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func pressure(_ s: String?) -> String {
        switch s {
        case "normal": return String(localized: "Normal")
        case "warning": return String(localized: "Elevated")
        case "critical": return String(localized: "Critical")
        case nil: return "–"
        case let s?: return s
        }
    }

    static func pressureColor(_ s: String?) -> Color {
        switch s {
        case "warning": return NColor.warning
        case "critical": return NColor.danger
        default: return NColor.success
        }
    }

    static func health(_ s: String?) -> String {
        switch s {
        case "ok": return String(localized: "All good")
        case "degraded": return String(localized: "Limited operation")
        case "error": return String(localized: "Error")
        case nil: return "–"
        case let s?: return s
        }
    }

    static func taskState(_ s: String) -> String { NText.taskState(s) }

    static func ms(_ v: Double) -> String {
        v < 10 ? v.formatted(.number.precision(.fractionLength(1))) + " ms" : "\(Int(v.rounded())) ms"
    }

    static func percent(_ f: Double) -> String { f.formatted(.percent.precision(.fractionLength(0))) }

    static func sanitize(_ s: String, max: Int = 240) -> String {
        let one = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    /// A user-facing message, or nil when the owner cancelled (Face ID sheet closed, request cancelled).
    static func message(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let d = error as? DiagnosticsError { return d.errorDescription }
        guard let e = error as? APIError else { return String(localized: "Something went wrong. Try again.") }
        if e.code == "cancelled" { return nil }
        if e.isOffline { return e.message }
        switch e.code {
        case "owner_only", "agents_permission": return String(localized: "Only the NEBULA owner can do this.")
        case "stepup_required": return String(localized: "This action must be confirmed with Face ID or Touch ID.")
        case "not_found": return String(localized: "Not found. It may have been deleted in the meantime.")
        case "bad_response": return e.message
        default: break
        }
        if e.status == 403 { return String(localized: "You do not have permission for this action.") }
        if e.status >= 500 { return String(localized: "NEBULA did not complete the action: \(sanitize(e.message))") }
        if e.status == 409 { return String(localized: "This action is not possible right now: \(sanitize(e.message))") }
        return sanitize(e.message)
    }
}

// MARK: - Shared view helpers

struct SBanner: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var style: NBanner.Style
    static func == (l: SBanner, r: SBanner) -> Bool { l.id == r.id }

    static func from(_ r: SystemStore.ActionResult) -> SBanner? {
        switch r {
        case .done(let m?): return SBanner(text: m, style: .success)
        case .done(nil), .cancelled: return nil
        case .failed(let m): return SBanner(text: m, style: .danger)
        }
    }
}

private struct SBannerModifier: ViewModifier {
    @Binding var banner: SBanner?
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
                try? await Task.sleep(for: .seconds(b.style == .danger ? 6 : 4))
                if !Task.isCancelled, banner == b { banner = nil }
            }
    }
}

extension View {
    func systemBanner(_ banner: Binding<SBanner?>) -> some View { modifier(SBannerModifier(banner: banner)) }

    func systemFormStyle() -> some View { formStyle(.grouped) }

    @ViewBuilder
    func systemInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Label + value row (selectable value, wraps at large text sizes).
struct ValueRow: View {
    let title: String
    let value: String
    var symbol: String?
    var mono = false
    var tint: Color?

    var body: some View {
        LabeledContent {
            Text(value)
                .font(mono ? NFont.monoSmall : .body)
                .monospacedDigit()
                .foregroundStyle(tint ?? NColor.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
    }
}

/// A thin capacity bar with a title, a value and a tint.
struct CapacityBar: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.s) {
            HStack {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                Spacer()
                Text(value).font(.callout).monospacedDigit().foregroundStyle(NColor.textSecondary)
            }
            Gauge(value: min(1, max(0, fraction))) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(tint)
                .nAnimation(NMotion.smooth, value: fraction)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NSpace.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(SText.percent(fraction)))
    }
}

/// Header rows float on the grouped background on iOS; on the Mac they stay in their group box.
struct SClearRow: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(Color.clear)
        #else
        content
        #endif
    }
}
