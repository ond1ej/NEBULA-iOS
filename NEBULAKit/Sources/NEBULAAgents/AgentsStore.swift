import Foundation
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import Observation

/// The live stage of an agent's running task (`task.stage` events: queued, thinking, using a tool, …).
public struct AgentStage: Sendable, Hashable {
    public var taskID: String
    public var stage: String
    public var detail: String?
    /// Time since the task was created, as the server measured it when the event was sent.
    public var elapsedMs: Double?
    /// When this device received the event (elapsed time keeps counting locally from here, no clock skew).
    public var receivedAt: Date

    public init(taskID: String, stage: String, detail: String? = nil, elapsedMs: Double? = nil,
                receivedAt: Date = Date()) {
        self.taskID = taskID; self.stage = stage; self.detail = detail; self.elapsedMs = elapsedMs
        self.receivedAt = receivedAt
    }

    public var label: String { NText.stage(stage) }

    public func elapsed(at now: Date) -> TimeInterval? {
        elapsedMs.map { max(0, $0 / 1000 + now.timeIntervalSince(receivedAt)) }
    }

    /// "Thinking · 12 s".
    public func line(at now: Date) -> String {
        guard let e = elapsed(at: now) else { return label }
        return "\(label) · \(NFormat.duration(ms: e * 1000))"
    }
}

/// Agents and their tasks, kept current by server events (`agent.*`, `task.*`) — no polling. Every owner action goes
/// through the OwnerGate, so a `stepup_required` answer asks for ONE Face ID / Touch ID confirmation and retries.
@MainActor
@Observable
public final class AgentsStore {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    /// Outcome of an owner action, for the view that started it (a cancelled confirmation is silent).
    public enum ActionResult: Equatable, Sendable {
        case done(String?)
        case cancelled
        case failed(String)

        public var succeeded: Bool { if case .done = self { return true }; return false }
    }

    public enum AgentCommand: String, Sendable, CaseIterable { case pause, resume, sleep, wake }
    public enum TaskCommand: String, Sendable, CaseIterable { case pause, resume, stop, retry }

    /// All agents: working first, then by most recent activity.
    public private(set) var agents: [Agent] = []
    public private(set) var phase: Phase = .idle
    /// The last refresh failed while older data is still shown (offline, server restarting).
    public private(set) var refreshError: String?
    /// agentID → live stage of its running task.
    public private(set) var stages: [String: AgentStage] = [:]
    /// agentID → latest tasks (newest first).
    public private(set) var recentTasks: [String: [AgentTask]] = [:]
    public private(set) var tasksPhase: [String: Phase] = [:]
    /// taskID → task with its steps (GET /tasks/{id}).
    public private(set) var taskDetails: [String: AgentTask] = [:]
    public private(set) var taskPhase: [String: Phase] = [:]
    /// agentIDs / "task:<id>" with an action in flight.
    public private(set) var busy: Set<String> = []
    /// The composer catalogue, once loaded (provider names, levels, icons).
    public private(set) var options: ComposerOptions?

    let api: APIClient
    let gate: OwnerGate
    private let coalescer = Coalescer()
    private var loadTask: Task<Void, Never>?
    private var watched: [String: Int] = [:]
    private var models: [String: [ModelChoice]] = [:]
    /// Set by previews: no network.
    var offline = false

    public init(api: APIClient, hub: EventHub, gate: OwnerGate) {
        self.api = api
        self.gate = gate
        hub.on("agent.") { [weak self] ev in self?.handle(ev) }
        hub.on("task.") { [weak self] ev in self?.handle(ev) }
    }

    // MARK: lookups

    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }

    public func stage(for agentID: String) -> AgentStage? { stages[agentID] }

    public func isBusy(_ agentID: String) -> Bool { busy.contains(agentID) }

    public func isTaskBusy(_ taskID: String) -> Bool { busy.contains("task:" + taskID) }

    /// The agent's avatar as the design system draws it (nil: initials from the name).
    public func avatar(for agentID: String) -> AvatarSpec? { Self.avatarSpec(agent(agentID)?.config?.avatar) }

    public static func avatarSpec(_ a: AgentAvatar?) -> AvatarSpec? {
        guard let a, !a.value.isEmpty, let kind = AvatarSpec.Kind(rawValue: a.kind) else { return nil }
        guard kind == .icon else { return AvatarSpec(kind: kind, value: a.value) }
        // host icon ids → the ids NAvatar knows (others fall back to its generic symbol)
        let known: [String: String] = ["globe": "browser", "spark": "star", "chart": "data", "search": "research"]
        return AvatarSpec(kind: .icon, value: known[a.value] ?? a.value)
    }

    public var showsSkeleton: Bool { agents.isEmpty && (phase == .idle || phase == .loading) }

    public func filtered(_ query: String) -> [Agent] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedStandardContains(q) || ($0.description ?? "").localizedStandardContains(q) ||
                ($0.modelId ?? "").localizedStandardContains(q)
        }
    }

    /// The task shown in the agent's "current task" card (detail if loaded, else the list row).
    public func currentTask(of agentID: String) -> AgentTask? {
        guard let ref = agent(agentID)?.currentTask else { return nil }
        return taskDetails[ref.id] ?? recentTasks[agentID]?.first { $0.id == ref.id }
    }

    // MARK: loading

    /// Loads (or refreshes) the agent list. Concurrent callers share one request.
    public func load() async {
        guard !offline else { return }
        if let loadTask { await loadTask.value; return }
        let t = Task { [weak self] () -> Void in await self?.fetchAgents() }
        loadTask = t
        await t.value
        loadTask = nil
    }

    public func refresh() async { await load() }

    private func fetchAgents() async {
        if agents.isEmpty { phase = .loading }
        do {
            let list = try await api.agents()
            agents = Self.sorted(list)
            let ids = Set(list.map(\.id))
            stages = stages.filter { ids.contains($0.key) }
            phase = .loaded
            refreshError = nil
        } catch {
            guard let msg = AText.message(error) else {
                if phase == .loading { phase = agents.isEmpty ? .idle : .loaded }
                return
            }
            if agents.isEmpty { phase = .failed(msg) } else { phase = .loaded; refreshError = msg }
        }
    }

    /// Everything the agent detail needs: a fresh record, its latest tasks and the current task's steps.
    public func loadDetail(_ agentID: String) async {
        guard !offline else { return }
        if agents.isEmpty { await load() } else { await refreshAgent(agentID) }
        await loadTasks(for: agentID)
        if let cur = agent(agentID)?.currentTask { await loadTask(cur.id) }
    }

    public func loadTasks(for agentID: String) async {
        guard !offline else { return }
        if recentTasks[agentID] == nil { tasksPhase[agentID] = .loading }
        do {
            recentTasks[agentID] = try await api.agentTasks(agentID, limit: 20)
            tasksPhase[agentID] = .loaded
        } catch {
            if let msg = AText.message(error) {
                tasksPhase[agentID] = recentTasks[agentID] == nil ? .failed(msg) : .loaded
            }
        }
    }

    public func loadTask(_ taskID: String) async {
        guard !offline else { return }
        if taskDetails[taskID] == nil { taskPhase[taskID] = .loading }
        do {
            apply(try await api.task(taskID))
            taskPhase[taskID] = .loaded
        } catch {
            if let msg = AText.message(error) {
                taskPhase[taskID] = taskDetails[taskID] == nil ? .failed(msg) : .loaded
            }
        }
    }

    /// While a task detail is on screen its steps follow `task.step` events.
    public func watchTask(_ taskID: String) { watched[taskID, default: 0] += 1 }

    public func unwatchTask(_ taskID: String) {
        let n = (watched[taskID] ?? 1) - 1
        watched[taskID] = n > 0 ? n : nil
    }

    // MARK: agent actions

    @discardableResult
    public func perform(_ command: AgentCommand, agentID: String) async -> ActionResult {
        guard !busy.contains(agentID) else { return .cancelled }
        busy.insert(agentID)
        defer { busy.remove(agentID) }
        let name = agent(agentID)?.name ?? ""
        let reason: String
        switch command {
        case .pause: reason = String(localized: "Pause agent \(name)")
        case .resume: reason = String(localized: "Resume agent \(name)")
        case .sleep: reason = String(localized: "Put agent \(name) to sleep")
        case .wake: reason = String(localized: "Wake agent \(name)")
        }
        do {
            let json = try await gate.run(reason) { try await self.api.agentAction(agentID, command.rawValue) }
            if let a = Remodel.decode(json, as: Agent.self) { upsert(a) } else { scheduleAgentRefresh(agentID) }
            if command == .pause || command == .sleep { stages[agentID] = nil }
            Haptics.success()
            return .done(nil)
        } catch {
            return failure(error, unknownOutcome: command == .sleep || command == .wake, agentID: agentID)
        }
    }

    // MARK: task actions

    @discardableResult
    public func perform(_ command: TaskCommand, taskID: String) async -> ActionResult {
        let key = "task:" + taskID
        guard !busy.contains(key) else { return .cancelled }
        busy.insert(key)
        defer { busy.remove(key) }
        let reason: String
        switch command {
        case .pause: reason = String(localized: "Pause task")
        case .resume: reason = String(localized: "Resume task")
        case .stop: reason = String(localized: "Stop task")
        case .retry: reason = String(localized: "Run task again")
        }
        do {
            let t: AgentTask = try await gate.run(reason) {
                switch command {
                case .pause: return try await self.api.pauseTask(taskID)
                case .resume: return try await self.api.resumeTask(taskID)
                case .stop: return try await self.api.stopTask(taskID)
                case .retry: return try await self.api.retryTask(taskID)
                }
            }
            apply(t)
            if command == .retry {
                if let i = agents.firstIndex(where: { $0.id == t.agentId }), agents[i].currentTask == nil {
                    agents[i].currentTask = Remodel.taskRef(id: t.id, state: t.state)
                    agents = Self.sorted(agents)
                }
                scheduleTasksRefresh(t.agentId)
            }
            Haptics.success()
            return .done(command == .retry ? t.id : nil)
        } catch {
            return failure(error, unknownOutcome: false, agentID: nil)
        }
    }

    // MARK: composer (create / settings / delete)

    public func composerOptions(force: Bool = false) async throws -> ComposerOptions {
        if let options, !force { return options }
        let o = try await gate.run(String(localized: "Load agent settings")) { try await self.api.agentComposerOptions() }
        options = o
        return o
    }

    public func models(for providerID: String, force: Bool = false) async throws -> [ModelChoice] {
        if let m = models[providerID], !force { return m }
        let m = try await api.agentComposerModels(providerID: providerID)
        models[providerID] = m
        return m
    }

    public func composerSettings(_ agentID: String) async throws -> ComposerSettings {
        let s = try await gate.run(String(localized: "Edit agent")) { try await self.api.agentComposerSettings(agentID) }
        if let a = s.agent { upsert(a) }
        return s
    }

    /// Creates the agent (provisioning its Linux user, desktop and browser takes up to a minute). A request that times
    /// out is repeated with the SAME Idempotency-Key: NEBULA waits for the first one and answers with that agent.
    public func createAgent(_ body: NewAgentBody, idempotencyKey: String) async throws -> ComposerSettings {
        let deadline = Date().addingTimeInterval(150)
        while true {
            let started = Date()
            do {
                let r = try await gate.run(String(localized: "Create agent \(body.name)")) {
                    try await self.api.createAgent(body, idempotencyKey: idempotencyKey)
                }
                if let a = r.agent { upsert(a) }
                options = nil  // existing names changed
                return r
            } catch let e as APIError where e.isOffline && e.code != "cancelled" &&
                Date().timeIntervalSince(started) > 20 && Date() < deadline {
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func updateSettings(_ agentID: String, _ patch: AgentComposerPatch) async throws -> ComposerSettings {
        let name = agent(agentID)?.name ?? ""
        let s = try await gate.run(String(localized: "Save settings of agent \(name)")) {
            try await self.api.updateAgentComposer(agentID, patch)
        }
        if let a = s.agent { upsert(a) } else { scheduleAgentRefresh(agentID) }
        if patch.name != nil { options = nil }
        return s
    }

    /// Deletes the agent (admin! — the gate asks for the owner's Face ID / Touch ID first).
    public func deleteAgent(_ agentID: String) async -> ActionResult {
        guard !busy.contains(agentID) else { return .cancelled }
        busy.insert(agentID)
        defer { busy.remove(agentID) }
        let name = agent(agentID)?.name ?? ""
        do {
            _ = try await gate.run(String(localized: "Delete agent \(name)")) { try await self.api.deleteAgent(agentID) }
            remove(agentID)
            options = nil
            Haptics.success()
            return .done(nil)
        } catch {
            return failure(error, unknownOutcome: true, agentID: agentID)
        }
    }

    // MARK: events

    private func handle(_ ev: ServerEvent) {
        let p = ev.payload
        switch ev.type {
        case "agent.state.changed":
            guard let id = ev.agentId else { return }
            if let to = p?["to"]?.string, let i = agents.firstIndex(where: { $0.id == id }) {
                agents[i].state = to
                agents = Self.sorted(agents)
            }
            scheduleAgentRefresh(id)
        case "agent.created":
            if let id = ev.agentId { scheduleAgentRefresh(id) }
            options = nil
        case "agent.deleted":
            if let id = ev.agentId { remove(id) }
            options = nil
        case "task.stage":
            guard let aid = ev.agentId, let tid = ev.taskId, let stage = p?["stage"]?.string else { return }
            stages[aid] = AgentStage(taskID: tid, stage: stage, detail: p?["detail"]?.string,
                                     elapsedMs: p?["elapsed_ms"]?.double)
            if let i = agents.firstIndex(where: { $0.id == aid }), agents[i].currentTask == nil {
                agents[i].currentTask = Remodel.taskRef(id: tid, state: stage.hasPrefix("queued") ||
                                                        stage == "waiting_for_resources" ? "QUEUED" : "EXECUTING")
                agents = Self.sorted(agents)
            }
        case "task.queued", "task.started", "task.resumed", "task.paused":
            guard let aid = ev.agentId, let tid = ev.taskId else { return }
            let state: String
            switch ev.type {
            case "task.queued": state = "QUEUED"
            case "task.started": state = "PLANNING"
            case "task.paused": state = "PAUSED"
            default: state = "EXECUTING"
            }
            setTaskState(tid, agentID: aid, state: state)
            if state == "PAUSED" { stages[aid] = nil }
            if let i = agents.firstIndex(where: { $0.id == aid }) {
                if agents[i].currentTask == nil || agents[i].currentTask?.id == tid {
                    agents[i].currentTask = Remodel.taskRef(id: tid, state: state)
                }
                agents = Self.sorted(agents)
            }
            if recentTasks[aid]?.contains(where: { $0.id == tid }) == false { scheduleTasksRefresh(aid) }
            if watched[tid] != nil { scheduleTaskRefresh(tid) }
            scheduleAgentRefresh(aid)
        case "task.completed", "task.failed", "task.cancelled":
            guard let aid = ev.agentId, let tid = ev.taskId else { return }
            let state = ["task.completed": "COMPLETED", "task.failed": "FAILED"][ev.type] ?? "CANCELLED"
            setTaskState(tid, agentID: aid, state: state)
            if stages[aid]?.taskID == tid { stages[aid] = nil }
            if let i = agents.firstIndex(where: { $0.id == aid }), agents[i].currentTask?.id == tid {
                agents[i].currentTask = nil
                agents[i].lastActiveAt = Date().timeIntervalSince1970
                agents = Self.sorted(agents)
            }
            if taskDetails[tid] != nil { scheduleTaskRefresh(tid) }
            if recentTasks[aid] != nil { scheduleTasksRefresh(aid) }
            scheduleAgentRefresh(aid)
        case "task.step":
            guard let tid = ev.taskId else { return }
            if let seq = p?["seq"]?.int, var t = taskDetails[tid] {
                t.currentStep = max(t.currentStep ?? 0, seq)
                taskDetails[tid] = t
            }
            if watched[tid] != nil { scheduleTaskRefresh(tid) }
        default:
            break
        }
    }

    private func setTaskState(_ taskID: String, agentID: String, state: String) {
        if var t = taskDetails[taskID] { t.state = state; taskDetails[taskID] = t }
        if var list = recentTasks[agentID], let i = list.firstIndex(where: { $0.id == taskID }) {
            list[i].state = state
            recentTasks[agentID] = list
        }
    }

    // MARK: coalesced refreshes (one request in flight per key; a burst of events costs at most one more)

    private func scheduleAgentRefresh(_ id: String) {
        guard !offline else { return }
        coalescer.run("agent:" + id) { [weak self] in await self?.refreshAgent(id) }
    }

    private func scheduleTasksRefresh(_ agentID: String) {
        guard !offline else { return }
        coalescer.run("tasks:" + agentID) { [weak self] in await self?.loadTasks(for: agentID) }
    }

    private func scheduleTaskRefresh(_ taskID: String) {
        guard !offline else { return }
        coalescer.run("task:" + taskID) { [weak self] in await self?.loadTask(taskID) }
    }

    private func refreshAgent(_ id: String) async {
        do {
            upsert(try await api.agent(id))
        } catch let e as APIError where e.status == 404 {
            remove(id)
        } catch {}
    }

    // MARK: helpers

    private func apply(_ t: AgentTask) {
        if let old = taskDetails[t.id], t.steps == nil {
            var merged = t
            merged.steps = old.steps
            taskDetails[t.id] = merged
        } else {
            taskDetails[t.id] = t
        }
        var list = recentTasks[t.agentId] ?? []
        if let i = list.firstIndex(where: { $0.id == t.id }) {
            var row = t
            row.steps = nil
            list[i] = row
        } else if recentTasks[t.agentId] != nil {
            var row = t
            row.steps = nil
            list.insert(row, at: 0)
        }
        if recentTasks[t.agentId] != nil { recentTasks[t.agentId] = list }
        if let i = agents.firstIndex(where: { $0.id == t.agentId }), agents[i].currentTask?.id == t.id {
            agents[i].currentTask = t.isTerminal ? nil : Remodel.taskRef(id: t.id, state: t.state)
            agents = Self.sorted(agents)
        }
    }

    private func upsert(_ a: Agent) {
        var list = agents
        if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a } else { list.append(a) }
        agents = Self.sorted(list)
        if a.currentTask == nil { stages[a.id] = nil }
        if phase != .loaded && !agents.isEmpty { phase = .loaded }
    }

    private func remove(_ id: String) {
        agents.removeAll { $0.id == id }
        stages[id] = nil
        recentTasks[id] = nil
        tasksPhase[id] = nil
    }

    private func failure(_ error: any Error, unknownOutcome: Bool, agentID: String?) -> ActionResult {
        guard let msg = AText.message(error) else { return .cancelled }
        Haptics.error()
        if unknownOutcome, let e = error as? APIError, e.isOffline {
            if let agentID { scheduleAgentRefresh(agentID) }
            return .failed(String(localized: "NEBULA has not confirmed the result yet. The action may still be running. The status updates by itself."))
        }
        return .failed(msg)
    }

    static func recency(_ a: Agent) -> Double { a.lastActiveAt ?? a.updatedAt ?? a.createdAt ?? 0 }

    static func sorted(_ list: [Agent]) -> [Agent] {
        list.sorted { l, r in
            let lw = l.activity == .working, rw = r.activity == .working
            if lw != rw { return lw }
            let lr = recency(l), rr = recency(r)
            if lr != rr { return lr > rr }
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
    }

    // MARK: previews

    /// Fills the store with sample data and turns networking off (SwiftUI previews only).
    func seedPreview(agents: [Agent], stages: [String: AgentStage] = [:], tasks: [String: [AgentTask]] = [:],
                     details: [AgentTask] = []) {
        offline = true
        self.agents = Self.sorted(agents)
        self.stages = stages
        recentTasks = tasks
        for t in details { taskDetails[t.id] = t }
        phase = .loaded
    }

    func seedPreviewComposer(options: ComposerOptions?, models: [String: [ModelChoice]]) {
        offline = true
        self.options = options
        self.models = models
    }
}

/// Runs one async refresh per key at a time; requests arriving meanwhile collapse into a single re-run.
@MainActor
final class Coalescer {
    private var running: Set<String> = []
    private var dirty: Set<String> = []

    func run(_ key: String, _ op: @escaping @MainActor () async -> Void) {
        if running.contains(key) {
            dirty.insert(key)
            return
        }
        running.insert(key)
        Task { @MainActor [weak self] in
            repeat {
                self?.dirty.remove(key)
                await op()
            } while self?.dirty.contains(key) == true
            self?.running.remove(key)
        }
    }
}
