import Foundation
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// Localized labels for the composer's fixed ids, tool types, statuses, and user-facing error messages. Server labels
/// (English) are only a fallback for ids this build does not know yet.
enum AText {
    // MARK: permission levels

    static let levelOrder = ["READ_ONLY", "STANDARD", "ADVANCED"]

    /// Rank of a level; anything unknown (e.g. HOST_CONTROL) ranks above every level the apps can choose.
    static func rank(_ level: String?) -> Int {
        levelOrder.firstIndex(of: level ?? "STANDARD") ?? 99
    }

    static func allows(_ level: String, _ required: String?) -> Bool { rank(required ?? "STANDARD") <= rank(level) }

    static func level(_ id: String?) -> String {
        switch id {
        case "READ_ONLY": return String(localized: "Read only")
        case "STANDARD": return String(localized: "Standard")
        case "ADVANCED": return String(localized: "Advanced")
        case "HOST_CONTROL": return String(localized: "Mac control")
        default: return (id ?? "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func levelDescription(_ id: String, fallback: String?) -> String {
        switch id {
        case "READ_ONLY": return String(localized: "Can read pages and files, changes nothing.")
        case "STANDARD": return String(localized: "Browser, desktop and its own files. No terminal.")
        case "ADVANCED": return String(localized: "Everything in Standard, plus a terminal, Python, Node.js and git in the VM.")
        default: return fallback ?? ""
        }
    }

    // MARK: capabilities

    static func capability(_ id: String, fallback: String?) -> String {
        switch id {
        case "browser": return String(localized: "Browser")
        case "web_research": return String(localized: "Web search")
        case "files": return String(localized: "Files")
        case "terminal": return String(localized: "Terminal")
        case "desktop": return String(localized: "Desktop control")
        case "memory": return String(localized: "Memory")
        default: return fallback ?? id
        }
    }

    static func capabilityDescription(_ id: String, fallback: String?) -> String {
        switch id {
        case "browser": return String(localized: "A visible Chromium on its own desktop: opens pages, reads, clicks and types.")
        case "web_research": return String(localized: "Searches the web and reads pages.")
        case "files": return String(localized: "Reads and writes files in its own workspace (never files on your Mac).")
        case "terminal": return String(localized: "Shell commands as an unprivileged user in the VM.")
        case "desktop": return String(localized: "Mouse and keyboard on its own VM desktop (you can always watch in Live Desktop).")
        case "memory": return String(localized: "Remembers useful facts between tasks (you can view and delete them).")
        default: return fallback ?? ""
        }
    }

    static func capabilitySymbol(_ id: String) -> String {
        switch id {
        case "browser": return "safari"
        case "web_research": return "magnifyingglass"
        case "files": return "folder"
        case "terminal": return "terminal"
        case "desktop": return "cursorarrow.motionlines"
        case "memory": return "brain"
        default: return "puzzlepiece.extension"
        }
    }

    // MARK: Smart sign-in (vault access)

    static func vault(_ id: String) -> String {
        switch id {
        case "none": return String(localized: "No access")
        case "ask": return String(localized: "Ask when a sign-in is needed")
        default: return id
        }
    }

    static func vaultDescription(_ id: String) -> String {
        switch id {
        case "none": return String(localized: "The agent cannot sign in anywhere on your behalf and has no saved credentials.")
        case "ask":
            return String(localized: "Smart sign-in: the agent asks, you answer in a secure form, and it never sees your passwords.")
        default: return ""
        }
    }

    // MARK: providers

    static func provider(_ id: String?, options: ComposerOptions?) -> String {
        guard let id, !id.isEmpty else { return String(localized: "Not selected") }
        if let p = options?.providers?.first(where: { $0.id == id }), let n = p.name, !n.isEmpty { return n }
        switch id.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google", "gemini": return "Google Gemini"
        case "ollama": return "Ollama"
        case "openrouter": return "OpenRouter"
        case "mistral": return "Mistral"
        case "lmstudio", "lm_studio": return "LM Studio"
        default: return id
        }
    }

    // MARK: avatar icons

    /// The host's fixed avatar icon ids (agent_composer.AVATAR_ICONS) — used when the catalogue does not list them.
    static let defaultIcons = ["robot", "spark", "brain", "code", "search", "chart", "briefcase", "globe", "shield",
                               "book", "bolt", "star", "mail", "calendar", "music", "camera"]

    static func iconSymbol(_ id: String) -> String {
        switch id {
        case "robot", "bot": return "cpu"
        case "spark", "star": return "sparkles"
        case "brain": return "brain"
        case "code", "developer": return "chevron.left.forwardslash.chevron.right"
        case "search", "research": return "magnifyingglass"
        case "chart", "data": return "chart.bar.xaxis"
        case "briefcase": return "briefcase.fill"
        case "globe", "browser", "web": return "globe"
        case "shield", "security": return "lock.shield"
        case "book": return "book.fill"
        case "bolt": return "bolt.fill"
        case "mail": return "envelope.fill"
        case "calendar": return "calendar"
        case "music": return "music.note"
        case "camera": return "camera.fill"
        case "writer", "pen": return "pencil.line"
        default: return "sparkles"
        }
    }

    static let emojiChoices = ["🤖", "🧠", "💼", "📊", "🔍", "✍️", "🌐", "🛡️", "📬", "⚡️", "🎯", "🧪", "🚀", "🦊",
                               "🐙", "🦉", "📚", "🗂️", "🧾", "🛒", "🎨", "🎧", "🏠", "⭐️"]

    // MARK: tasks & steps

    static func taskSymbol(_ state: String) -> String {
        switch state {
        case "COMPLETED": return "checkmark.circle.fill"
        case "FAILED": return "xmark.octagon.fill"
        case "CANCELLED": return "minus.circle.fill"
        case "PAUSED", "PAUSING": return "pause.circle.fill"
        case "WAITING_APPROVAL", "WAITING_PROVIDER", "WAITING_CONTROL": return "hourglass.circle.fill"
        case "RECEIVED", "QUEUED": return "clock.fill"
        default: return "circle.dotted.circle"
        }
    }

    static func taskColor(_ state: String) -> Color {
        switch state {
        case "COMPLETED": return NColor.success
        case "FAILED": return NColor.danger
        case "CANCELLED": return NColor.textTertiary
        case "PAUSED", "PAUSING": return NColor.warning
        case "WAITING_APPROVAL", "WAITING_PROVIDER", "WAITING_CONTROL": return NColor.warning
        case "RECEIVED", "QUEUED": return NColor.textSecondary
        default: return NColor.accent
        }
    }

    /// Tool category of a step (`browser_click` → "Browser").
    static func tool(_ type: String) -> (label: String, symbol: String) {
        let prefix = type.split(separator: "_").first.map(String.init) ?? type
        switch prefix {
        case "desktop", "computer": return (String(localized: "Desktop"), "display")
        case "browser": return (String(localized: "Browser"), "safari")
        case "web": return (String(localized: "Web"), "magnifyingglass")
        case "files", "pdf", "doc": return (String(localized: "Files"), "doc.text")
        case "shell", "process", "packages": return (String(localized: "Terminal"), "terminal")
        case "git", "github": return ("Git", "arrow.triangle.branch")
        case "python", "node": return (String(localized: "Code"), "chevron.left.forwardslash.chevron.right")
        case "data": return (String(localized: "Data"), "tablecells")
        case "memory": return (String(localized: "Memory"), "brain")
        case "team", "company": return (String(localized: "Team"), "person.3")
        case "ask": return (String(localized: "Approval"), "hand.raised")
        case "task": return (String(localized: "Completion"), "flag.checkered")
        case "sign", "credential", "vault", "smart": return (String(localized: "Sign-in"), "key")
        default: return (String(localized: "Tool"), "wrench.and.screwdriver")
        }
    }

    static func stepStatus(_ s: String) -> (label: String, color: Color) {
        switch s {
        case "ok": return (String(localized: "Done"), NColor.success)
        case "error": return (String(localized: "Error"), NColor.danger)
        case "denied": return (String(localized: "Declined"), NColor.warning)
        case "approved": return (String(localized: "Approved"), NColor.info)
        case "in_flight": return (String(localized: "In progress"), NColor.accent)
        default: return (s, NColor.textSecondary)
        }
    }

    static func elapsed(ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        if ms < 60_000 { return (ms / 1000).formatted(.number.precision(.fractionLength(1))) + " s" }
        return NFormat.duration(ms: ms)
    }

    // MARK: agent status

    static func activityColor(_ a: AgentActivity) -> Color {
        switch a {
        case .ready: return NColor.success
        case .working: return NColor.accent
        case .sleeping: return NColor.textTertiary
        case .paused: return NColor.warning
        case .error: return NColor.danger
        case .busy: return NColor.info
        }
    }

    /// "Working", "Asleep", "Ready" — the working state shows the task's own state.
    static func status(_ agent: Agent) -> String {
        if agent.activity == .working, let t = agent.currentTask { return NText.taskState(t.state) }
        return NText.agentState(agent.state)
    }

    // MARK: errors

    /// Control characters out, one line, bounded: host messages are shown verbatim as a last resort.
    static func sanitize(_ s: String, max: Int = 240) -> String {
        let one = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    /// A user-facing message, or nil when the owner simply cancelled (Face ID sheet closed, request cancelled).
    static func message(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        guard let e = error as? APIError else { return String(localized: "Something went wrong. Try again.") }
        if e.code == "cancelled" { return nil }
        if e.isOffline { return e.message }
        switch e.code {
        case "agent_busy": return String(localized: "Pause or stop the running task first.")
        case "agent_not_ready": return String(localized: "The agent is not ready to accept a task right now.")
        case "not_retryable": return String(localized: "Only a failed or cancelled task can be run again.")
        case "vm_unavailable", "vm_not_running":
            return String(localized: "The Ubuntu VM is not available. Start it in the System section and try again.")
        case "agents_permission", "owner_only":
            return String(localized: "Only the NEBULA owner can do this.")
        case "agent_not_found": return String(localized: "Agent not found. It may have been deleted in the meantime.")
        case "task_not_found": return String(localized: "Task not found.")
        case "agent_not_editable": return String(localized: "The agent is being created or deleted right now. Try again in a moment.")
        case "stepup_required": return String(localized: "This action must be confirmed with Face ID or Touch ID.")
        case "rate_limited", "http_429": return rateLimited(e)
        case "guest_delete_failed": return String(localized: "The Ubuntu VM did not remove the agent: \(sanitize(e.message))")
        case "bad_response": return e.message
        default: break
        }
        if e.status == 403 { return String(localized: "You do not have permission for this action.") }
        if e.status >= 500 { return String(localized: "NEBULA did not complete the action: \(sanitize(e.message))") }
        return sanitize(e.message)
    }

    static func rateLimited(_ e: APIError) -> String {
        guard let s = e.retryAfter else { return String(localized: "Too many requests. Try again in a few minutes.") }
        if s < 90 { return String(localized: "Too many requests. Try again in about \(max(1, Int(s.rounded()))) s.") }
        return String(localized: "Too many requests. Try again in about \(Int((s / 60).rounded(.up))) min.")
    }
}
