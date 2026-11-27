import Foundation
import os

/// Formatting helpers (the UI language follows the system; English is the development language, Czech is translated).
public enum NFormat {

    /// "Yesterday", "Mon", "14:05" — chat-list style.
    public static func listTime(_ epoch: Epoch, now: Date = Date()) -> String {
        let d = epoch.date
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return String(localized: "yesterday") }
        if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    public static func relativeTime(_ epoch: Epoch, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(epoch.date)) < 45 { return String(localized: "just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: epoch.date, relativeTo: now)
    }

    public static func bytes(_ n: Double?) -> String {
        guard let n else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }

    public static func duration(ms: Double) -> String {
        let s = Int(ms / 1000)
        if s < 60 { return "\(s) s" }
        return "\(s / 60) min \(s % 60) s"
    }

    /// The host name of an origin for display ("https://login.microsoftonline.com" → "login.microsoftonline.com").
    public static func host(_ origin: String?) -> String {
        guard let origin, let u = URL(string: origin), let h = u.host() else { return origin ?? "" }
        return h
    }
}

/// Privacy-safe logging: never pass user content, secrets or tokens. Only fixed codes and structural numbers.
public enum NLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "nebula"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let net = Logger(subsystem: subsystem, category: "network")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let live = Logger(subsystem: subsystem, category: "live")
}

/// Task states shown to people.
public enum NText {
    public static func taskState(_ s: String) -> String {
        switch s {
        case "RECEIVED", "QUEUED": return String(localized: "Queued")
        case "PLANNING": return String(localized: "Planning")
        case "EXECUTING": return String(localized: "Working")
        case "VERIFYING": return String(localized: "Verifying")
        case "PAUSING": return String(localized: "Pausing")
        case "PAUSED": return String(localized: "Paused")
        case "WAITING_APPROVAL": return String(localized: "Waiting for approval")
        case "WAITING_PROVIDER": return String(localized: "Waiting for the model")
        case "WAITING_CONTROL": return String(localized: "Waiting for control")
        case "COMPLETED": return String(localized: "Done")
        case "FAILED": return String(localized: "Failed")
        case "CANCELLED": return String(localized: "Cancelled")
        default: return s.capitalized
        }
    }

    public static func agentState(_ s: String) -> String {
        switch s {
        case "READY", "IDLE": return String(localized: "Ready")
        case "ACTIVE": return String(localized: "Active")
        case "SLEEP": return String(localized: "Asleep")
        case "PAUSED": return String(localized: "Paused")
        case "STOPPED": return String(localized: "Stopped")
        case "ERROR": return String(localized: "Error")
        case "CREATING": return String(localized: "Being created")
        case "DELETING": return String(localized: "Being deleted")
        default: return s.capitalized
        }
    }

    /// Stage of a running task (task.stage events).
    public static func stage(_ s: String) -> String {
        switch s {
        case "queued", "waiting_for_resources": return String(localized: "Waiting for a free slot")
        case "worker_allocated", "starting": return String(localized: "Starting")
        case "model_request", "model", "thinking": return String(localized: "Thinking")
        case "waking_desktop": return String(localized: "Waking the desktop")
        case "tool": return String(localized: "Using a tool")
        case "approval", "waiting_for_approval": return String(localized: "Waiting for approval")
        case "sign_in", "waiting_for_sign_in": return String(localized: "Waiting for sign-in")
        case "verifying": return String(localized: "Verifying the result")
        case "replying", "finishing": return String(localized: "Writing the reply")
        default: return String(localized: "Working")
        }
    }
}
