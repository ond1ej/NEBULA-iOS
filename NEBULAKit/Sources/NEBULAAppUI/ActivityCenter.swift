import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import NEBULAVault
import Observation
import SwiftUI
import UserNotifications

/// Approvals waiting for the owner, recent notifications, and LOCAL notifications for important events while the
/// app runs (remote push needs APNs — see docs/building.md#push-notifications; nothing here pretends to be a remote
/// push).
@MainActor
@Observable
public final class NotificationCenterStore {
    public private(set) var approvals: [CenterApproval] = []
    public private(set) var recent: [NebulaNotification] = []
    public private(set) var loading = false
    public var error: String?
    /// The conversation on screen: no banner for events the owner is looking at.
    public var visibleAgentID: String?
    public var appActive = true

    let api: APIClient
    private var refreshTask: Task<Void, Never>?

    public init(api: APIClient, hub: EventHub) {
        self.api = api
        hub.on("task.approval") { [weak self] ev in self?.scheduleRefresh(); self?.notify(ev) }
        hub.on("owner.approval") { [weak self] ev in self?.scheduleRefresh(); self?.notify(ev) }
        hub.on("task.completed") { [weak self] ev in self?.notify(ev) }
        hub.on("task.failed") { [weak self] ev in self?.notify(ev) }
        hub.on("auth.request") { [weak self] ev in self?.notify(ev) }
    }

    public var badgeCount: Int { approvals.count }

    public func load() async {
        loading = true
        defer { loading = false }
        do {
            let c = try await api.approvalCenter()
            approvals = c.pending
            recent = (try? await api.notifications()) ?? recent
            error = nil
        } catch { self.error = (error as? APIError)?.message }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    public func decide(_ a: CenterApproval, approve: Bool) async {
        do {
            _ = try await api.decide(approval: a.id, approve: approve)
            approvals.removeAll { $0.id == a.id }
            approve ? Haptics.success() : Haptics.tap()
        } catch { self.error = (error as? APIError)?.message }
    }

    // MARK: local notifications (metadata only: never message text, passwords or codes)

    public static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func notify(_ ev: ServerEvent) {
        if appActive && ev.agentId != nil && ev.agentId == visibleAgentID { return }
        guard appActive == false || ev.type == "auth.request" || ev.type.hasPrefix("task.approval") ||
              ev.type == "owner.approval.requested" else { return }
        let agent = ev.payload?["agent_name"]?.string ?? String(localized: "Agent")
        let content = UNMutableNotificationContent()
        switch ev.type {
        case "task.completed":
            content.title = String(localized: "Task completed")
            content.body = String(localized: "\(agent) finished the task.")
        case "task.failed":
            content.title = String(localized: "Task failed")
            content.body = String(localized: "\(agent) ran into an error.")
        case "task.approval.requested", "owner.approval.requested":
            content.title = String(localized: "Waiting for approval")
            content.body = String(localized: "\(agent) needs your approval.")
            content.interruptionLevel = .timeSensitive
        case "auth.request":
            content.title = String(localized: "Agent sign-in")
            let site = ev.payload?["site"]?.string.map { " (\($0))" } ?? ""
            content.body = String(localized: "\(agent) needs to sign in\(site).")
            content.interruptionLevel = .timeSensitive
            if let sid = ev.payload?["session_id"]?.string { content.userInfo = ["sign_in": sid] }
        default: return
        }
        content.sound = .default
        content.threadIdentifier = ev.agentId ?? "nebula"
        if let a = ev.agentId { content.userInfo["agent_id"] = a }
        let id = "nebula-\(ev.sequence.map(String.init) ?? UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// "Aktivita": approvals, sign-in requests and recent events in one calm list.
public struct ActivityView: View {
    @Bindable var center: NotificationCenterStore
    @Bindable var signIns: SignInStore
    let onOpenSignIn: (String) -> Void

    public init(center: NotificationCenterStore, signIns: SignInStore, onOpenSignIn: @escaping (String) -> Void) {
        self.center = center
        self.signIns = signIns
        self.onOpenSignIn = onOpenSignIn
    }

    public var body: some View {
        List {
            if !signIns.waiting.isEmpty {
                Section("Sign-in") {
                    ForEach(signIns.waiting) { s in
                        Button { onOpenSignIn(s.id) } label: { SignInCard(session: s) }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }
            Section("Awaiting approval") {
                if center.approvals.isEmpty {
                    Label("Nothing is waiting for approval", systemImage: "checkmark.circle").foregroundStyle(NColor.textSecondary)
                }
                ForEach(center.approvals) { a in ApprovalRow(approval: a, center: center) }
            }
            Section("Recent") {
                if center.loading && center.recent.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                }
                ForEach(center.recent.prefix(40)) { n in NotificationRow(n: n) }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .refreshable {
            await center.load()
            await signIns.load()
        }
        .task {
            await center.load()
            await signIns.load()
        }
        .overlay(alignment: .bottom) {
            if let e = center.error ?? signIns.error { NBanner(e, style: .warning).padding() }
        }
    }
}

struct ApprovalRow: View {
    let approval: CenterApproval
    let center: NotificationCenterStore
    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.s) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(NColor.warning)
                Text(approval.agentName ?? String(localized: "Agent")).font(.callout.weight(.semibold))
                Spacer()
                Text(NFormat.relativeTime(approval.createdAt)).font(.caption).foregroundStyle(NColor.textTertiary)
            }
            Text(approval.title).font(.callout)
            if let r = approval.reason, !r.isEmpty { Text(r).font(.footnote).foregroundStyle(NColor.textSecondary) }
            HStack {
                Button("Decline", role: .destructive) { Task { await center.decide(approval, approve: false) } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Approve") { Task { await center.decide(approval, approve: true) } }
                    .buttonStyle(.borderedProminent).tint(NColor.accent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NotificationRow: View {
    let n: NebulaNotification
    var body: some View {
        HStack(alignment: .top, spacing: NSpace.m) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let s = n.payload?["summary"]?.string ?? n.payload?["reason"]?.string, !s.isEmpty {
                    Text(s).font(.footnote).foregroundStyle(NColor.textSecondary).lineLimit(2)
                }
            }
            Spacer()
            Text(NFormat.relativeTime(n.timestamp)).font(.caption2).foregroundStyle(NColor.textTertiary)
        }
    }

    private var title: String {
        let a = n.agentName ?? String(localized: "Agent")
        switch n.type {
        case "task.completed": return String(localized: "\(a) finished a task")
        case "task.failed": return String(localized: "\(a): task failed")
        case "task.approval.requested": return String(localized: "\(a) is asking for approval")
        case "auth.request": return String(localized: "\(a) needs to sign in")
        default: return n.type
        }
    }

    private var icon: String {
        switch n.type {
        case "task.completed": return "checkmark.circle.fill"
        case "task.failed": return "exclamationmark.triangle.fill"
        case "auth.request": return "person.badge.key.fill"
        default: return "bell.fill"
        }
    }

    private var tint: Color {
        switch n.type {
        case "task.completed": return NColor.success
        case "task.failed": return NColor.danger
        default: return NColor.accent
        }
    }
}
