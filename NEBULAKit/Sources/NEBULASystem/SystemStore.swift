import Foundation
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import Observation

/// The Mac mini, its Ubuntu VM and NEBULA's maintenance actions, plus the owner's paired apps. Server events
/// (`vm.state.changed`, `system.health`, `resource.pressure.changed`, task and device changes) keep it current;
/// network refreshes run only while a system view is on screen — no polling.
@MainActor
@Observable
public final class SystemStore {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    /// Outcome of an owner action for the view that started it (a cancelled Face ID prompt is silent).
    public enum ActionResult: Equatable, Sendable {
        case done(String?)
        case cancelled
        case failed(String)
    }

    public enum Action: String, Sendable { case vmStart, vmStop, restart, backup, diagnostics }
    public enum VMTransition: Sendable, Equatable { case starting, stopping }

    /// A task that stopping the VM would interrupt.
    public struct RunningTask: Sendable, Hashable, Identifiable {
        public var id: String
        public var agentID: String
        public var agentName: String
        public var state: String
    }

    public private(set) var health: Health?
    public private(set) var system: SystemInfo?
    public private(set) var phase: Phase = .idle
    public private(set) var refreshError: String?
    /// Round trip of GET /health from this device, in milliseconds.
    public private(set) var latencyMs: Double?
    public private(set) var agentCount: Int?
    public private(set) var workingAgents: Int?
    public private(set) var vmTransition: VMTransition?
    public private(set) var busyAction: Action?
    public private(set) var restarting = false
    public private(set) var lastBackup: BackupResult?
    public private(set) var diagnostics: DiagnosticsReport?
    public private(set) var diagnosticsPhase: Phase = .idle

    public private(set) var devices: [AppDevice] = []
    public private(set) var devicesPhase: Phase = .idle
    public private(set) var gatewayURL: String?
    public private(set) var serverFingerprint: String?
    public private(set) var revoking: Set<String> = []

    let api: APIClient
    let gate: OwnerGate
    private var loadTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var statusViewers = 0
    private var devicesViewers = 0
    /// Set by previews: no network.
    var offline = false

    public init(api: APIClient, hub: EventHub, gate: OwnerGate) {
        self.api = api
        self.gate = gate
        hub.on("vm.state.changed") { [weak self] ev in self?.vmChanged(ev) }
        hub.on("system.health") { [weak self] _ in self?.scheduleRefresh() }
        hub.on("resource.pressure.changed") { [weak self] ev in self?.pressureChanged(ev) }
        hub.on("task.") { [weak self] ev in
            guard ["task.started", "task.completed", "task.failed", "task.cancelled", "task.paused",
                   "task.resumed"].contains(ev.type) else { return }
            self?.scheduleRefresh()
        }
        hub.on("agent.created") { [weak self] _ in self?.scheduleRefresh() }
        hub.on("agent.deleted") { [weak self] _ in self?.scheduleRefresh() }
        hub.on("app.device.changed") { [weak self] _ in self?.scheduleDevicesRefresh() }
    }

    // MARK: derived

    /// NEBULA's version on the Mac mini.
    public var serverVersion: String? { health?.version ?? system?.host?.appVersion }

    public var vmState: String? {
        switch vmTransition {
        case .starting?: return "starting"
        case .stopping?: return "stopping"
        case nil: return system?.vm?.state ?? health?.vm?.state
        }
    }

    public var vmRunning: Bool { vmState == "running" }
    public var vmStopped: Bool { ["stopped", "not_running", "shutoff", "failed", "not_created"].contains(vmState ?? "") }

    public var memoryUsedFraction: Double? {
        guard let h = system?.host, let total = h.memoryTotalBytes, total > 0 else { return nil }
        if let avail = h.memoryAvailableBytes { return min(1, max(0, (total - avail) / total)) }
        if let free = h.memoryFreePercent { return min(1, max(0, 1 - free / 100)) }
        return nil
    }

    public var diskUsedFraction: Double? {
        guard let h = system?.host, let total = h.diskTotalBytes, total > 0, let free = h.diskFreeBytes else { return nil }
        return min(1, max(0, (total - free) / total))
    }

    /// 1-minute load average per core (1.0 = every core busy).
    public var cpuLoadFraction: Double? {
        guard let h = system?.host, let l = h.loadAvg?.first else { return nil }
        let cores = Double(max(1, h.cpuCount ?? 1))
        return l / cores
    }

    public var showsSkeleton: Bool { health == nil && system == nil && (phase == .idle || phase == .loading) }

    // MARK: visibility (refreshes run only while someone looks)

    public func viewAppeared() {
        statusViewers += 1
        if statusViewers == 1 { Task { await refresh() } }
    }

    public func viewDisappeared() { statusViewers = max(0, statusViewers - 1) }

    public func devicesAppeared() {
        devicesViewers += 1
        if devicesViewers == 1 { Task { await loadDevices() } }
    }

    public func devicesDisappeared() { devicesViewers = max(0, devicesViewers - 1) }

    // MARK: loading

    public func refresh() async {
        guard !offline else { return }
        if let loadTask { await loadTask.value; return }
        let t = Task { [weak self] () -> Void in await self?.fetch() }
        loadTask = t
        await t.value
        loadTask = nil
    }

    private func fetch() async {
        if showsSkeleton { phase = .loading }
        let api = self.api
        async let h = Self.result { () -> (Health, Double) in
            let clock = ContinuousClock()
            let start = clock.now
            let v = try await api.health()
            let d = start.duration(to: clock.now)
            return (v, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        async let s = Self.result { try await api.system() }
        async let a = Self.result { try await api.agents() }
        let (hr, sr, ar) = await (h, s, a)
        var firstError: (any Error)?
        switch hr {
        case .success(let (v, ms)): health = v; latencyMs = ms
        case .failure(let e): firstError = e; latencyMs = nil
        }
        switch sr {
        case .success(let v):
            system = v
            if let st = v.vm?.state, ["running", "stopped", "failed", "not_created"].contains(st) { settleTransition(st) }
        case .failure(let e): firstError = firstError ?? e
        }
        if case .success(let list) = ar {
            agentCount = list.count
            workingAgents = list.filter { $0.activity == .working }.count
        }
        if let e = firstError, let msg = SText.message(e) {
            if health == nil && system == nil { phase = .failed(msg) } else { phase = .loaded; refreshError = msg }
        } else {
            phase = .loaded
            refreshError = nil
            if restarting, health != nil { restarting = false }
        }
    }

    nonisolated private static func result<T: Sendable>(_ op: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    /// Tasks that stopping the VM would interrupt (agents' current tasks that are not paused).
    public func runningTasks() async -> [RunningTask] {
        guard !offline else { return [] }
        guard let list = try? await api.agents() else { return [] }
        return list.compactMap { a in
            guard let t = a.currentTask, !TaskStates.paused.contains(t.state), !TaskStates.terminal.contains(t.state)
            else { return nil }
            return RunningTask(id: t.id, agentID: a.id, agentName: a.name, state: t.state)
        }
    }

    // MARK: actions

    public func startVM() async -> ActionResult {
        await vmAction(.vmStart, reason: String(localized: "Start Ubuntu VM"), transition: .starting) {
            try await self.api.vmStart()
        }
    }

    /// Stops the VM (fresh owner confirmation). Running tasks are paused by NEBULA ("smart" pause) first.
    public func stopVM() async -> ActionResult {
        await vmAction(.vmStop, reason: String(localized: "Stop Ubuntu VM"), transition: .stopping) {
            try await self.api.vmStop()
        }
    }

    private func vmAction(_ action: Action, reason: String, transition: VMTransition,
                          _ op: @escaping @MainActor () async throws -> JSONValue) async -> ActionResult {
        guard busyAction == nil else { return .cancelled }
        busyAction = action
        defer { busyAction = nil }
        vmTransition = transition
        do {
            let r = try await gate.run(reason) { try await op() }
            if let st = r["state"]?.string { setVMState(st) } else { vmTransition = nil }
            Haptics.success()
            scheduleRefresh()
            return .done(nil)
        } catch {
            guard let msg = SText.message(error) else { vmTransition = nil; return .cancelled }
            Haptics.error()
            if let e = error as? APIError, e.isOffline {
                // the VM helper may still be working (start waits up to a minute): the event settles it
                scheduleFollowUp(after: .seconds(45))
                return .failed(String(localized: "NEBULA has not confirmed the result yet. The VM may still be changing state. The status updates by itself."))
            }
            vmTransition = nil
            return .failed(msg)
        }
    }

    public func restartServices() async -> ActionResult {
        guard busyAction == nil else { return .cancelled }
        busyAction = .restart
        defer { busyAction = nil }
        do {
            _ = try await gate.run(String(localized: "Restart NEBULA services")) { try await self.api.restartServices() }
            restarting = true
            Haptics.success()
            Task { [weak self] in await self?.waitForRestart() }
            return .done(String(localized: "NEBULA services are restarting. The connection comes back in a moment."))
        } catch {
            guard let msg = SText.message(error) else { return .cancelled }
            Haptics.error()
            if let e = error as? APIError, e.code == "not_managed" {
                return .failed(String(localized: "The server is not running under launchd (development mode). Restart it by hand on your Mac."))
            }
            return .failed(msg)
        }
    }

    /// A bounded wait for the restarted server (a few tries, only while the status view is open).
    private func waitForRestart() async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(4))
            guard restarting, statusViewers > 0 else { return }
            if (try? await api.health()) != nil {
                restarting = false
                await refresh()
                return
            }
        }
        restarting = false
    }

    public func backup() async -> ActionResult {
        guard busyAction == nil else { return .cancelled }
        busyAction = .backup
        defer { busyAction = nil }
        do {
            lastBackup = try await gate.run(String(localized: "Back up the NEBULA database")) { try await self.api.createBackup() }
            Haptics.success()
            return .done(String(localized: "The backup is done."))
        } catch {
            guard let msg = SText.message(error) else { return .cancelled }
            Haptics.error()
            return .failed(msg)
        }
    }

    public func loadDiagnostics() async {
        guard !offline, busyAction == nil else { return }
        busyAction = .diagnostics
        defer { busyAction = nil }
        diagnosticsPhase = .loading
        do {
            diagnostics = try await gate.run(String(localized: "Show NEBULA diagnostics")) {
                try await self.api.diagnosticsReport()
            }
            diagnosticsPhase = .loaded
        } catch {
            if let msg = SText.message(error) {
                diagnosticsPhase = .failed(msg)
            } else {
                diagnosticsPhase = diagnostics == nil ? .idle : .loaded
            }
        }
    }

    // MARK: devices

    public func loadDevices() async {
        guard !offline else { return }
        if let devicesTask { await devicesTask.value; return }
        let t = Task { [weak self] () -> Void in await self?.fetchDevices() }
        devicesTask = t
        await t.value
        devicesTask = nil
    }

    private func fetchDevices() async {
        if devices.isEmpty { devicesPhase = .loading }
        do {
            let r = try await gate.run(String(localized: "Show paired devices")) { try await self.api.pairedDevices() }
            devices = r.devices.sorted { l, r in
                if (l.status == "pending") != (r.status == "pending") { return l.status == "pending" }
                return (l.lastSeenAt ?? l.createdAt) > (r.lastSeenAt ?? r.createdAt)
            }
            gatewayURL = r.gatewayUrl
            serverFingerprint = r.serverFingerprint
            devicesPhase = .loaded
        } catch {
            guard let msg = SText.message(error) else {
                if devicesPhase == .loading { devicesPhase = .idle }
                return
            }
            devicesPhase = devices.isEmpty ? .failed(msg) : .loaded
        }
    }

    /// Revokes another paired app: its sessions end and its vault key is removed.
    public func revoke(_ device: AppDevice) async -> ActionResult {
        guard !revoking.contains(device.id) else { return .cancelled }
        revoking.insert(device.id)
        defer { revoking.remove(device.id) }
        do {
            _ = try await gate.run(String(localized: "Remove device \(device.name)")) {
                try await self.api.revokeDevice(device.id)
            }
            devices.removeAll { $0.id == device.id }
            Haptics.success()
            return .done(String(localized: "Device \(device.name) was removed."))
        } catch {
            guard let msg = SText.message(error) else { return .cancelled }
            Haptics.error()
            return .failed(msg)
        }
    }

    // MARK: events

    private func vmChanged(_ ev: ServerEvent) {
        if let st = ev.payload?["state"]?.string { setVMState(st) }
        followUp?.cancel()
        scheduleRefresh()
    }

    private func pressureChanged(_ ev: ServerEvent) {
        guard let to = ev.payload?["to"]?.string else { return }
        system?.host?.memoryPressure = to
        if let free = ev.payload?["free_percent"]?.double { system?.host?.memoryFreePercent = free }
    }

    private func setVMState(_ st: String) {
        if system?.vm != nil {
            system?.vm?.state = st
        } else if system != nil {
            system?.vm = SRemodel.decode(.object(["state": .string(st)]))
        }
        if health?.vm != nil { health?.vm?.state = st }
        settleTransition(st)
    }

    private func settleTransition(_ st: String) {
        switch vmTransition {
        case .starting?: if st == "running" || st == "failed" { vmTransition = nil }
        case .stopping?: if st != "running" && st != "stopping" { vmTransition = nil }
        case nil: break
        }
    }

    /// Bursts of events collapse into one refresh; while nobody looks, the next appearance refreshes instead.
    private func scheduleRefresh() {
        guard !offline else { return }
        guard statusViewers > 0 else { return }
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func scheduleDevicesRefresh() {
        guard !offline else { return }
        guard devicesViewers > 0 else { return }
        Task { [weak self] in await self?.loadDevices() }
    }

    /// One delayed check after an action whose outcome NEBULA did not confirm (not a loop).
    private func scheduleFollowUp(after delay: Duration) {
        followUp?.cancel()
        followUp = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if self.statusViewers > 0 { await self.refresh() }
            self.vmTransition = nil
        }
    }

    // MARK: previews

    func seedPreview(health: Health?, system: SystemInfo?, latencyMs: Double?, agents: Int, working: Int,
                     devices: [AppDevice] = [], fingerprint: String? = nil) {
        offline = true
        self.health = health
        self.system = system
        self.latencyMs = latencyMs
        agentCount = agents
        workingAgents = working
        self.devices = devices
        serverFingerprint = fingerprint
        phase = .loaded
        devicesPhase = .loaded
    }
}

enum SRemodel {
    static func decode<T: Decodable>(_ value: JSONValue, as: T.Type = T.self) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? NJSON.decoder().decode(T.self, from: data)
    }

    static func decode<T: Decodable>(json: String, as: T.Type = T.self) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? NJSON.decoder().decode(T.self, from: data)
    }
}
