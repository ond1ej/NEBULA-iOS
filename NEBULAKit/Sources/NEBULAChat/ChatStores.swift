import Foundation
import NEBULACore
import NEBULANetwork
import Observation

/// The conversation list (all agents), kept current by `conversation.message` / task events — no polling.
@MainActor
@Observable
public final class ChatListStore {
    public private(set) var conversations: [Conversation] = []
    public private(set) var archived: [Conversation] = []
    public private(set) var loaded = false
    public private(set) var loading = false
    public var error: String?
    public private(set) var searchResult: SearchResult?
    public private(set) var searching = false

    let api: APIClient
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    public init(api: APIClient, hub: EventHub) {
        self.api = api
        hub.on("conversation.message") { [weak self] _ in self?.scheduleRefresh() }
        hub.on("task.") { [weak self] ev in
            guard let self, let t = ev.type.split(separator: ".").last,
                  ["started", "completed", "failed", "cancelled", "paused", "resumed"].contains(String(t)) else { return }
            self.scheduleRefresh()
        }
    }

    public var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    public func load(force: Bool = false) async {
        if loaded && !force { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await api.conversations()
            withAnimationIfNeeded { conversations = list.sorted { $0.sortDate > $1.sortDate } }
            loaded = true
            error = nil
        } catch let e as APIError where e.code == "cancelled" {
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func loadArchived() async {
        archived = (try? await api.conversations(archived: true)) ?? archived
    }

    /// Coalesces bursts of events (several messages / task updates in a row) into one request.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load(force: true)
        }
    }

    public func upsert(_ c: Conversation) {
        var list = conversations.filter { $0.id != c.id }
        if !c.archived { list.append(c) }
        conversations = list.sorted { $0.sortDate > $1.sortDate }
    }

    public func newConversation(agentID: String) async throws -> Conversation {
        let c = try await api.createConversation(agentID: agentID)
        upsert(c)
        return c
    }

    public func rename(_ id: String, title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        do { upsert(try await api.updateConversation(id, title: t)) } catch { self.error = error.localizedDescription }
    }

    public func setArchived(_ id: String, _ archived: Bool) async {
        do {
            let c = try await api.updateConversation(id, archived: archived)
            upsert(c)
            if archived { self.archived.insert(c, at: 0) } else { self.archived.removeAll { $0.id == id } }
        } catch { self.error = error.localizedDescription }
    }

    public func markReadLocally(_ id: String) {
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unreadCount = 0 }
    }

    public func search(_ q: String) {
        searchTask?.cancel()
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { searchResult = nil; searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))  // debounce typing
            guard !Task.isCancelled, let self else { return }
            let r = try? await self.api.search(q)
            guard !Task.isCancelled else { return }
            self.searchResult = r
            self.searching = false
        }
    }

    private func withAnimationIfNeeded(_ f: () -> Void) { f() }
}

/// What the agent is doing right now in a conversation (task state + live stage + streamed text).
public struct LiveActivity: Equatable, Sendable {
    public var taskID: String
    public var state: String
    public var stage: String?
    public var stageDetail: String?
    public var elapsedMs: Double?
    public var stageAt: Date = Date()
    public var streamedText: String = ""
    /// Length in Unicode scalars (the server counts code points).
    public var streamedLength: Int = 0
    public var streamTurn: Int = -1

    public var isPaused: Bool { TaskStates.paused.contains(state) }
    public var isWaiting: Bool { TaskStates.waiting.contains(state) }
}

/// A message being sent (shown immediately, replaced by the server copy with the same client id — never twice).
public struct PendingMessage: Identifiable, Equatable, Sendable {
    public var id: String { clientID }
    public var clientID: String
    public var content: String
    public var attachmentNames: [String]
    public var createdAt: Date
    public var failed: String?
}

/// One open conversation: paginated history, optimistic sending, live task activity.
@MainActor
@Observable
public final class ConversationStore {
    public let conversationID: String
    public private(set) var conversation: Conversation?
    public private(set) var messages: [Message] = []
    public private(set) var pending: [PendingMessage] = []
    public private(set) var hasMore = true
    public private(set) var loadingInitial = true
    public private(set) var loadingOlder = false
    public private(set) var activity: LiveActivity?
    public var error: String?
    /// Bumped when new messages arrive at the bottom (the view scrolls if the user is near the end).
    public private(set) var bottomRevision = 0

    let api: APIClient
    private let hub: EventHub
    private var subscriptions: [UUID] = []
    private var fetchTask: Task<Void, Never>?
    private var ids = Set<String>()

    public init(conversationID: String, api: APIClient, hub: EventHub) {
        self.conversationID = conversationID
        self.api = api
        self.hub = hub
        subscriptions.append(hub.on("conversation.message") { [weak self] ev in
            guard let self, ev.payload?["conversation_id"]?.string == self.conversationID else { return }
            self.scheduleFetchLatest()
        })
        subscriptions.append(hub.on("task.") { [weak self] ev in self?.handleTaskEvent(ev) })
    }

    /// Stop listening (call when the conversation closes; the store is then discarded).
    public func close() {
        for s in subscriptions { hub.off(s) }
        subscriptions.removeAll()
        fetchTask?.cancel()
    }

    public var agentID: String? { conversation?.agentId ?? messages.last?.agentId }

    public func start() async {
        async let conv = try? api.conversation(conversationID)
        do {
            let page = try await api.messages(conversationID, limit: 40)
            merge(page.items)
            hasMore = page.hasMore
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        conversation = await conv
        loadingInitial = false
        if let t = conversation?.runningTask { setActivity(taskID: t.id, state: t.state) }
        else if let m = messages.last(where: { $0.task != nil && !TaskStates.terminal.contains($0.task!.state) }),
                let t = m.task { setActivity(taskID: t.id, state: t.state) }
        _ = try? await api.markRead(conversationID)
    }

    public func loadOlder() async {
        guard hasMore, !loadingOlder, let oldest = messages.first?.createdAt else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await api.messages(conversationID, before: oldest, limit: 50)
            merge(page.items, atBottom: false)
            hasMore = page.hasMore
        } catch { self.error = error.localizedDescription }
    }

    private func scheduleFetchLatest() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.fetchLatest()
        }
    }

    /// Newest page merged by message id (safe after a reconnect: nothing is ever shown twice).
    public func fetchLatest() async {
        guard let page = try? await api.messages(conversationID, limit: 30) else { return }
        merge(page.items)
        _ = try? await api.markRead(conversationID)
    }

    func merge(_ incoming: [Message], atBottom: Bool = true) {
        var changed = false
        var list = messages
        for m in incoming {
            if ids.contains(m.id) {
                if let i = list.firstIndex(where: { $0.id == m.id }), list[i] != m { list[i] = m; changed = true }
                continue
            }
            ids.insert(m.id)
            list.append(m)
            changed = true
            if let cid = m.clientId { pending.removeAll { $0.clientID == cid } }
            if m.role == "assistant", let a = activity, m.taskId == a.taskID {
                activity?.streamedText = ""  // the final message replaces the live text
                activity?.streamedLength = 0
            }
            if let t = m.task, !TaskStates.terminal.contains(t.state) { setActivity(taskID: t.id, state: t.state) }
        }
        guard changed else { return }
        list.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        messages = list
        if atBottom { bottomRevision &+= 1 }
    }

    // MARK: sending

    public func send(_ text: String, attachments: [Attachment] = []) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return }
        let p = PendingMessage(clientID: Self.newClientID(), content: content,
                               attachmentNames: attachments.compactMap(\.name), createdAt: Date())
        pending.append(p)
        bottomRevision &+= 1
        Task { await deliver(p, attachmentIDs: attachments.map(\.id)) }
    }

    public func retry(_ clientID: String) {
        guard let i = pending.firstIndex(where: { $0.clientID == clientID }) else { return }
        pending[i].failed = nil
        let p = pending[i]
        Task { await deliver(p, attachmentIDs: []) }
    }

    public func discard(_ clientID: String) { pending.removeAll { $0.clientID == clientID } }

    private func deliver(_ p: PendingMessage, attachmentIDs: [String]) async {
        do {
            // the same client id on every retry: the server returns the original message instead of a duplicate
            let r = try await api.send(conversationID, content: p.content.isEmpty ? "📎" : p.content,
                                       clientID: p.clientID, attachmentIDs: attachmentIDs)
            merge([r.message])
            if let t = r.task { setActivity(taskID: t.id, state: t.state) }
        } catch {
            if let i = pending.firstIndex(where: { $0.clientID == p.clientID }) {
                pending[i].failed = (error as? APIError)?.message ?? error.localizedDescription
            }
        }
    }

    static func newClientID() -> String {
        "app-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func upload(fileName: String, mime: String, data: Data) async throws -> Attachment {
        guard let agentID else { throw APIError(status: 0, code: "no_agent", message: "") }
        return try await api.uploadAttachment(agentID: agentID, fileName: fileName, mime: mime, data: data)
    }

    // MARK: task control

    public func stop() async { await taskAction { try await self.api.stopTask($0) } }
    public func pause() async { await taskAction { try await self.api.pauseTask($0) } }
    public func resume() async { await taskAction { try await self.api.resumeTask($0) } }

    private func taskAction(_ f: (String) async throws -> AgentTask) async {
        guard let id = activity?.taskID else { return }
        do {
            let t = try await f(id)
            if t.isTerminal { activity = nil } else { activity?.state = t.state }
        } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
    }

    // MARK: live activity

    private func setActivity(taskID: String, state: String) {
        if TaskStates.terminal.contains(state) {
            if activity?.taskID == taskID { activity = nil }
            return
        }
        if activity?.taskID == taskID { activity?.state = state } else { activity = LiveActivity(taskID: taskID, state: state) }
    }

    private func handleTaskEvent(_ ev: ServerEvent) {
        guard let tid = ev.taskId else { return }
        let mine = activity?.taskID == tid || messages.contains { $0.taskId == tid }
        guard mine else { return }
        switch ev.type {
        case "task.output.delta":
            guard let turn = ev.payload?["turn"]?.int, let offset = ev.payload?["offset"]?.int,
                  let delta = ev.payload?["delta"]?.string else { return }
            if activity == nil { activity = LiveActivity(taskID: tid, state: "EXECUTING") }
            guard var a = activity, a.taskID == tid else { return }
            if turn != a.streamTurn { a.streamTurn = turn; a.streamedText = ""; a.streamedLength = 0 }
            if offset == a.streamedLength {  // a gap (missed update): wait for the final message instead
                a.streamedText += delta
                a.streamedLength += delta.unicodeScalars.count
            }
            activity = a
        case "task.stage":
            if activity == nil { activity = LiveActivity(taskID: tid, state: "EXECUTING") }
            activity?.stage = ev.payload?["stage"]?.string
            activity?.stageDetail = ev.payload?["detail"]?.string
            activity?.elapsedMs = ev.payload?["elapsed_ms"]?.double
            activity?.stageAt = Date()
        case "task.completed", "task.failed", "task.cancelled":
            if activity?.taskID == tid { activity = nil }
            scheduleFetchLatest()
        case "task.paused": activity?.state = "PAUSED"
        case "task.resumed", "task.started": setActivity(taskID: tid, state: "EXECUTING")
        case "task.approval.requested": activity?.state = "WAITING_APPROVAL"
        case "task.approval.resolved": activity?.state = "EXECUTING"
        default: break
        }
    }
}
