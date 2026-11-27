import Foundation
import NEBULACore

// Typed NEBULA endpoints used by the apps (the same API and policy as the Telegram Mini App).

public struct NewConversationBody: Codable, Sendable { public var agentId: String; public var title: String? }
public struct ConversationPatch: Codable, Sendable { public var title: String?; public var archived: Bool? }
public struct SendMessageBody: Codable, Sendable {
    public var content: String
    public var clientId: String
    public var attachmentIds: [String]
}
public struct TaskModeBody: Codable, Sendable { public var mode: String }
public struct ControlBody: Codable, Sendable { public var action: String }
public struct ApprovalDecision: Codable, Sendable { public var decision: String; public var reason: String? }
public struct RevealBody: Codable, Sendable { public var field: String }
public struct UnreadResult: Codable, Sendable { public var unreadCount: Int }
public struct NewTaskBody: Codable, Sendable { public var prompt: String }
public struct PushBody: Codable, Sendable { public var token: String?; public var env: String? }

public extension APIClient {
    // MARK: conversations
    func conversations(archived: Bool = false, agentID: String? = nil) async throws -> [Conversation] {
        try await get("/conversations", query: ["archived": archived ? "true" : "false", "limit": "100",
                                                "agent_id": agentID])
    }
    func conversation(_ id: String) async throws -> Conversation { try await get("/conversations/\(id)") }
    func createConversation(agentID: String, title: String? = nil) async throws -> Conversation {
        try await post("/conversations", body: NewConversationBody(agentId: agentID, title: title))
    }
    func updateConversation(_ id: String, title: String? = nil, archived: Bool? = nil) async throws -> Conversation {
        try await patch("/conversations/\(id)", body: ConversationPatch(title: title, archived: archived))
    }
    func markRead(_ id: String) async throws -> UnreadResult { try await post("/conversations/\(id)/read") }
    func messages(_ conversationID: String, before: Epoch? = nil, limit: Int = 50) async throws -> MessagePage {
        try await get("/conversations/\(conversationID)/messages",
                      query: ["before": before.map { String($0) }, "limit": String(limit)])
    }
    /// Idempotent by `clientID` (also sent as Idempotency-Key): a retried send never creates a second message/task.
    func send(_ conversationID: String, content: String, clientID: String, attachmentIDs: [String] = [])
        async throws -> SendMessageResult {
        try await post("/conversations/\(conversationID)/messages",
                       body: SendMessageBody(content: content, clientId: clientID, attachmentIds: attachmentIDs),
                       idempotencyKey: clientID)
    }
    func search(_ q: String) async throws -> SearchResult {
        try await get("/conversations/search", query: ["q": q, "limit": "30"])
    }
    func uploadAttachment(agentID: String, fileName: String, mime: String, data: Data) async throws -> Attachment {
        try await upload("/agents/\(agentID)/attachments", fileName: fileName, mime: mime, data: data)
    }

    // MARK: agents & tasks
    func agents() async throws -> [Agent] { try await get("/agents") }
    func agent(_ id: String) async throws -> Agent { try await get("/agents/\(id)") }
    func agentSettings(_ id: String) async throws -> AgentSettings { try await get("/miniapp/agents/\(id)/settings") }
    func updateAgentSettings(_ id: String, _ changes: AgentSettingsPatch) async throws -> AgentSettings {
        try await patch("/miniapp/agents/\(id)/settings", body: changes)
    }
    func agentAction(_ id: String, _ action: String) async throws -> JSONValue {
        try await post("/agents/\(id)/\(action)")  // pause | resume | sleep | wake
    }
    func tasks(state: String? = nil) async throws -> [AgentTask] {
        try await get("/tasks", query: ["state": state, "limit": "100"])
    }
    func task(_ id: String) async throws -> AgentTask { try await get("/tasks/\(id)") }
    func pauseTask(_ id: String) async throws -> AgentTask {
        try await post("/tasks/\(id)/pause", body: TaskModeBody(mode: "smart"))
    }
    func resumeTask(_ id: String) async throws -> AgentTask { try await post("/tasks/\(id)/resume") }
    func stopTask(_ id: String) async throws -> AgentTask {
        try await post("/tasks/\(id)/stop", body: TaskModeBody(mode: "cancel"))
    }
    func retryTask(_ id: String) async throws -> AgentTask { try await post("/tasks/\(id)/retry") }

    // MARK: approvals & notifications
    func approvalCenter() async throws -> ApprovalCenter { try await get("/approval-center") }
    func decide(approval id: String, approve: Bool) async throws -> JSONValue {
        try await post("/approvals/\(id)", body: ApprovalDecision(decision: approve ? "approved" : "denied", reason: nil))
    }
    func notifications() async throws -> [NebulaNotification] { try await get("/notifications") }

    // MARK: Smart sign-in
    func signInSession(_ id: String) async throws -> SignInSession { try await get("/smart-auth/sessions/\(id)") }
    func signInSessions(active: Bool = true) async throws -> [SignInSession] {
        try await get("/smart-auth/sessions", query: ["active": active ? "true" : "false", "limit": "30"])
    }
    func signInToken(_ id: String) async throws -> SubmitToken { try await post("/smart-auth/sessions/\(id)/token") }
    func submitSignIn(_ id: String, _ body: SignInSubmit) async throws -> SignInSession {
        try await post("/smart-auth/sessions/\(id)/submit", body: body)
    }
    func cancelSignIn(_ id: String) async throws -> SignInSession { try await post("/smart-auth/sessions/\(id)/cancel") }

    // MARK: vault (metadata, protective actions, one reveal at a time)
    func vaultStatus() async throws -> VaultStatus { try await get("/vault/status") }
    func vaultEntries(query: String? = nil) async throws -> [VaultEntry] {
        try await get("/vault/entries", query: ["q": query])
    }
    func vaultEntry(_ id: String) async throws -> VaultEntryDetail { try await get("/vault/entries/\(id)") }
    func addVaultEntry(_ input: VaultEntryInput) async throws -> VaultEntry { try await post("/vault/entries", body: input) }
    func updateVaultEntry(_ id: String, _ input: VaultEntryInput) async throws -> VaultEntry {
        try await patch("/vault/entries/\(id)", body: input)
    }
    func deleteVaultEntry(_ id: String) async throws -> JSONValue {
        try await delete("/vault/entries/\(id)", query: ["confirm": "true"])
    }
    func reveal(_ id: String, field: String = "password") async throws -> RevealResult {
        try await post("/vault/entries/\(id)/reveal", body: RevealBody(field: field))
    }
    func lockVault() async throws -> JSONValue { try await post("/vault/lock") }
    func vaultAudit(limit: Int = 50) async throws -> [VaultAuditRow] {
        try await get("/vault/audit", query: ["limit": String(limit)])
    }
    func vaultGrants() async throws -> [VaultGrant] { try await get("/vault/grants") }
    func revokeGrant(_ id: String) async throws -> JSONValue { try await post("/vault/grants/\(id)/revoke") }
    func agentVault(_ agentID: String) async throws -> AgentVault { try await get("/agents/\(agentID)/vault") }

    // MARK: live desktop
    func liveConnect(agentID: String) async throws -> LiveConnect { try await post("/agents/\(agentID)/live/connect") }
    func liveControl(sessionID: String, action: String) async throws -> ControlResult {
        try await post("/live/sessions/\(sessionID)/control", body: ControlBody(action: action))
    }
    func liveDisconnect(sessionID: String) async throws -> JSONValue { try await delete("/live/sessions/\(sessionID)") }
    func screenshot(agentID: String) async throws -> JSONValue { try await get("/agents/\(agentID)/screenshot") }

    // MARK: system
    func health() async throws -> Health { try await get("/health") }
    func system() async throws -> SystemInfo { try await get("/system") }
    func vmStart() async throws -> JSONValue { try await post("/system/vm/start") }
    func vmStop() async throws -> JSONValue { try await post("/system/vm/stop") }
    func restartServices() async throws -> JSONValue { try await post("/system/services/restart") }
    func backup() async throws -> JSONValue { try await post("/system/backup") }

    // MARK: this app / owner
    func appMe() async throws -> AppMe { try await get("/app/me") }
    func assurance() async throws -> Assurance { try await get("/auth/assurance") }
    func devices() async throws -> JSONValue { try await get("/devices") }
    func revokeDevice(_ id: String) async throws -> JSONValue { try await delete("/devices/\(id)") }
    func setPushToken(_ token: String?, env: String?) async throws -> JSONValue {
        try await put("/app/push", body: PushBody(token: token, env: env))
    }
}

/// Routes server events to the stores that care (main actor; cheap prefix match).
@MainActor
public final class EventHub {
    public typealias Handler = @MainActor (ServerEvent) -> Void
    private var handlers: [(prefix: String, id: UUID, fn: Handler)] = []

    public init() {}

    @discardableResult
    public func on(_ prefix: String, _ fn: @escaping Handler) -> UUID {
        let id = UUID()
        handlers.append((prefix, id, fn))
        return id
    }

    public func off(_ id: UUID) { handlers.removeAll { $0.id == id } }

    public func dispatch(_ ev: ServerEvent) {
        for h in handlers where ev.type.hasPrefix(h.prefix) { h.fn(ev) }
    }
}
