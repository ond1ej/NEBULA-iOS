import Foundation
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import Observation

/// State of the agent form: client-side validation (the host validates everything again), level ↔ capability
/// coupling, the POST body, the PATCH diff (only what changed) and host errors mapped to the field they are about.
@MainActor
@Observable
final class AgentEditorModel {
    enum Phase: Equatable { case loading, ready, failed(String) }
    enum ModelsPhase: Equatable { case idle, loading, loaded, failed(String) }
    enum AvatarMode: String, CaseIterable, Identifiable {
        case auto, emoji, initials, icon
        var id: String { rawValue }
    }

    enum Field: String, Hashable, CaseIterable {
        case name, description, avatar, provider, model, instructions, capabilities, vault, level, idle
    }

    struct Form: Equatable {
        var name = ""
        var description = ""
        var avatarMode: AvatarMode = .auto
        var emoji = "🤖"
        var initials = ""
        var icon = "robot"
        var providerID = ""
        var modelID = ""
        var instructions = ""
        var capabilities: [String: Bool] = [:]
        var extraSkills: Set<String> = []
        var vaultAccess = "none"
        var level = "STANDARD"
        var startActive = true
        var idleSleep: Int?
        var allowDuplicateName = false

        var normalizedName: String {
            name.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        var avatar: AgentAvatar? {
            switch avatarMode {
            case .auto: return nil
            case .emoji: return AgentAvatar(kind: "emoji", value: emoji.trimmingCharacters(in: .whitespaces))
            case .initials:
                return AgentAvatar(kind: "initials", value: initials.trimmingCharacters(in: .whitespaces).uppercased())
            case .icon: return AgentAvatar(kind: "icon", value: icon)
            }
        }

        /// The part of the form a host error is about: the error shows until that part changes.
        func slice(_ f: Field) -> String {
            switch f {
            case .name: return name
            case .description: return description
            case .avatar: return "\(avatarMode.rawValue)|\(emoji)|\(initials)|\(icon)"
            case .provider, .model: return "\(providerID)|\(modelID)"
            case .instructions: return instructions
            case .capabilities, .level: return "\(capabilities.sorted { $0.key < $1.key })|\(level)|\(extraSkills.sorted())"
            case .vault: return vaultAccess
            case .idle: return String(describing: idleSleep)
            }
        }
    }

    struct Problem: Equatable {
        var field: Field
        var message: String
        var at: String
    }

    let agentID: String?
    private(set) var phase: Phase = .loading
    private(set) var options: ComposerOptions?
    private(set) var original: AgentSettings?
    private var originalForm: Form?
    var form = Form()
    private(set) var models: [ModelChoice] = []
    private(set) var modelsPhase: ModelsPhase = .idle
    private(set) var attempted = false
    private(set) var serverProblem: Problem?
    var generalError: String?
    private(set) var saving = false
    var levelNote: String?
    private(set) var duplicateName = false
    private var idempotencyKey = UUID().uuidString
    private var modelsLoad: Task<Void, Never>?

    init(agentID: String?) { self.agentID = agentID }

    var isCreate: Bool { agentID == nil }

    // MARK: catalogue

    var capabilityChoices: [ComposerOptions.Capability] { options?.capabilities ?? [] }
    var levelChoices: [ComposerOptions.Level] {
        var l = options?.levels ?? AText.levelOrder.map { ComposerOptions.Level(id: $0, description: nil) }
        if !l.contains(where: { $0.id == form.level }) { l.append(.init(id: form.level, description: nil)) }
        return l
    }
    var vaultChoices: [String] {
        let ids = options?.vault?.options?.map(\.id) ?? ["none", "ask"]
        return ids.isEmpty ? ["none", "ask"] : ids
    }
    var extraSkills: [ComposerOptions.ExtraSkill] { options?.extraSkills ?? [] }
    var icons: [String] {
        let i = options?.avatar?.icons ?? []
        return i.isEmpty ? AText.defaultIcons : i
    }
    var connectedProviders: [ComposerOptions.Provider] { (options?.providers ?? []).filter(\.isConnected) }
    var disconnectedProviders: [ComposerOptions.Provider] { (options?.providers ?? []).filter { !$0.isConnected } }
    var usableModels: [ModelChoice] { models.filter(\.usableByAgents) }
    var unusableModelCount: Int { models.count - usableModels.count }
    var nameMax: Int { options?.nameRules?.max ?? 64 }
    var descriptionMax: Int { options?.limits?.descriptionMax ?? 1000 }
    var instructionsMax: Int { options?.limits?.instructionsMax ?? 4000 }
    var defaultInstructions: String? { options?.defaultInstructions }

    var isDirty: Bool {
        if isCreate { return form != (originalForm ?? Form()) }
        guard let original else { return false }
        return !patch(against: original).isEmpty
    }

    // MARK: loading

    func load(store: AgentsStore) async {
        phase = .loading
        do {
            let o = try await store.composerOptions()
            options = o
            if let agentID {
                let s = try await store.composerSettings(agentID)
                original = s.settings
                form = Self.form(from: s.settings)
            } else {
                form = Self.initialForm(o)
            }
            originalForm = form
            phase = .ready
            if !form.providerID.isEmpty { loadModels(store: store, keepSelection: true) }
        } catch {
            if let msg = AText.message(error) { phase = .failed(msg) } else { phase = .failed(String(localized: "Cancelled")) }
        }
    }

    static func initialForm(_ o: ComposerOptions) -> Form {
        var f = Form()
        for c in o.capabilities ?? [] { f.capabilities[c.id] = c.default ?? false }
        f.capabilities["memory"] = o.memory?.default ?? true
        f.level = AText.levelOrder.contains(o.defaultLevel ?? "") ? (o.defaultLevel ?? "STANDARD") : "STANDARD"
        for c in o.capabilities ?? [] where f.capabilities[c.id] == true && !AText.allows(f.level, c.requiresLevel) {
            f.capabilities[c.id] = false
        }
        f.vaultAccess = o.vault?.options?.first(where: { $0.default == true })?.id ?? "none"
        let connected = (o.providers ?? []).filter(\.isConnected)
        if connected.count == 1, let p = connected.first { f.providerID = p.id }
        return f
    }

    static func form(from s: AgentSettings) -> Form {
        var f = Form()
        f.name = s.name
        f.description = s.description
        if let a = s.avatar {
            switch a.kind {
            case "emoji": f.avatarMode = .emoji; f.emoji = a.value
            case "initials": f.avatarMode = .initials; f.initials = a.value
            case "icon": f.avatarMode = .icon; f.icon = a.value
            default: f.avatarMode = .auto
            }
        }
        f.providerID = s.providerId ?? ""
        f.modelID = s.modelId ?? ""
        f.instructions = s.instructions
        f.capabilities = s.capabilities
        if f.capabilities["memory"] == nil { f.capabilities["memory"] = true }
        f.extraSkills = Set(s.extraSkills ?? [])
        f.vaultAccess = s.vaultAccess == "ask" ? "ask" : "none"
        f.level = s.permissionLevel
        f.idleSleep = s.idleSleepMinutes
        return f
    }

    // MARK: provider / model

    func selectProvider(_ id: String, store: AgentsStore) {
        guard id != form.providerID else { return }
        form.providerID = id
        if let original, original.providerId == id, let m = original.modelId { form.modelID = m } else { form.modelID = "" }
        models = []
        loadModels(store: store, keepSelection: false)
    }

    func loadModels(store: AgentsStore, keepSelection: Bool, force: Bool = false) {
        let pid = form.providerID
        guard !pid.isEmpty else { return }
        modelsLoad?.cancel()
        modelsPhase = .loading
        modelsLoad = Task { [weak self] in
            do {
                let list = try await store.models(for: pid, force: force)
                guard let self, !Task.isCancelled, self.form.providerID == pid else { return }
                self.models = list
                self.modelsPhase = .loaded
                let usable = list.filter(\.usableByAgents)
                if self.form.modelID.isEmpty, usable.count == 1, let only = usable.first {
                    self.form.modelID = only.id
                }
                if !keepSelection, !self.form.modelID.isEmpty, !list.contains(where: { $0.id == self.form.modelID }) {
                    self.form.modelID = ""
                }
            } catch {
                guard let self, !Task.isCancelled, self.form.providerID == pid else { return }
                self.modelsPhase = .failed(Self.modelsError(error))
            }
        }
    }

    private static func modelsError(_ error: any Error) -> String {
        if let e = error as? APIError {
            switch e.code {
            case "provider_disconnected":
                return String(localized: "The provider is not connected. Connect it on your Mac (NEBULA Dashboard → AI Providers).")
            case "provider_unsupported": return String(localized: "This provider cannot run agents.")
            case "models_unavailable": return String(localized: "Could not load the model list.")
            default: break
            }
        }
        return AText.message(error) ?? String(localized: "Could not load the model list.")
    }

    // MARK: level ↔ capabilities

    func setCapability(_ id: String, _ on: Bool) {
        form.capabilities[id] = on
        guard on, let need = capabilityChoices.first(where: { $0.id == id })?.requiresLevel,
              !AText.allows(form.level, need), AText.levelOrder.contains(need) else { return }
        form.level = need
        let cap = AText.capability(id, fallback: capabilityChoices.first { $0.id == id }?.label)
        levelNote = String(localized: "Permission level raised to \(AText.level(need)) because \(cap) requires it.")
    }

    func setExtraSkill(_ id: String, _ on: Bool) {
        if on { form.extraSkills.insert(id) } else { form.extraSkills.remove(id) }
        guard on, let need = extraSkills.first(where: { $0.id == id })?.requiresLevel,
              !AText.allows(form.level, need), AText.levelOrder.contains(need) else { return }
        form.level = need
        levelNote = String(localized: "Permission level raised to \(AText.level(need)).")
    }

    func setLevel(_ level: String) {
        form.level = level
        var dropped: [String] = []
        for c in capabilityChoices where form.capabilities[c.id] == true && !AText.allows(level, c.requiresLevel) {
            form.capabilities[c.id] = false
            dropped.append(AText.capability(c.id, fallback: c.label))
        }
        for s in extraSkills where form.extraSkills.contains(s.id) && !AText.allows(level, s.requiresLevel) {
            form.extraSkills.remove(s.id)
            dropped.append(s.name ?? s.id)
        }
        levelNote = dropped.isEmpty ? nil
            : String(localized: "Off because the \(AText.level(level)) level does not allow it: \(dropped.joined(separator: ", ")).")
    }

    // MARK: validation

    func validate() -> [Field: String] {
        var e: [Field: String] = [:]
        let name = form.normalizedName
        if name.isEmpty {
            e[.name] = String(localized: "Enter a name.")
        } else if name.count > nameMax {
            e[.name] = String(localized: "At most \(nameMax) characters.")
        } else if !Self.validName(name) {
            e[.name] = String(localized: "Use only letters, digits, spaces and . - _ ( )")
        } else if !form.allowDuplicateName, isDuplicate(name) {
            e[.name] = String(localized: "An agent with this name already exists.")
        }
        if form.description.trimmingCharacters(in: .whitespacesAndNewlines).count > descriptionMax {
            e[.description] = String(localized: "The description can be at most \(descriptionMax) characters.")
        }
        if let a = avatarError() { e[.avatar] = a }
        if form.providerID.isEmpty { e[.provider] = String(localized: "Choose an AI provider.") }
        if form.modelID.isEmpty {
            e[.model] = String(localized: "Choose a model.")
        } else if let m = models.first(where: { $0.id == form.modelID }), !m.usableByAgents {
            e[.model] = String(localized: "This model cannot use tools.")
        }
        if form.instructions.trimmingCharacters(in: .whitespacesAndNewlines).count > instructionsMax {
            e[.instructions] = String(localized: "Instructions can be at most \(instructionsMax) characters.")
        }
        if let c = capabilityChoices.first(where: { form.capabilities[$0.id] == true && !AText.allows(form.level, $0.requiresLevel) }) {
            e[.capabilities] = String(localized: "\(AText.capability(c.id, fallback: c.label)) requires the \(AText.level(c.requiresLevel)) level.")
        }
        return e
    }

    /// Client errors (after the first save attempt) plus a host error that still applies to the current input.
    var visibleErrors: [Field: String] {
        var e = attempted ? validate() : [:]
        if let p = serverProblem, form.slice(p.field) == p.at { e[p.field] = p.message }
        return e
    }

    var showsDuplicateOverride: Bool {
        !form.allowDuplicateName && (duplicateName || isDuplicate(form.normalizedName)) &&
            visibleErrors[.name] != nil
    }

    private func isDuplicate(_ name: String) -> Bool {
        let n = name.lowercased()
        guard !n.isEmpty else { return false }
        if let original, original.name.lowercased() == n { return false }
        return (options?.existingNames ?? []).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == n }
    }

    /// The host's rule: letters, digits, spaces and . - _ ( ).
    static func validName(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            if " _.-()".unicodeScalars.contains(u) { return true }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }

    func avatarError() -> String? {
        switch form.avatarMode {
        case .auto: return nil
        case .icon: return icons.contains(form.icon) ? nil : String(localized: "Choose one of the icons.")
        case .initials:
            let v = form.initials.trimmingCharacters(in: .whitespaces)
            let ok = (1...2).contains(v.count) && v.unicodeScalars.allSatisfy {
                switch $0.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber: return true
                default: return false
                }
            }
            return ok ? nil : String(localized: "Initials: one or two letters or digits.")
        case .emoji:
            let v = form.emoji.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return String(localized: "Type or choose an emoji.") }
            let scalars = Array(v.unicodeScalars)
            let ok = scalars.count <= 8 && scalars.allSatisfy { u in
                if u.value == 0x200D || u.value == 0xFE0F { return true }
                switch u.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber, .control, .format, .surrogate, .privateUse,
                     .unassigned, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
            return ok ? nil : String(localized: "Use a single emoji (no letters or digits).")
        }
    }

    // MARK: request bodies

    func createBody() -> NewAgentBody {
        let desc = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let instr = form.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var caps = form.capabilities
        for c in capabilityChoices where caps[c.id] == nil { caps[c.id] = false }
        return NewAgentBody(name: form.normalizedName, description: desc.isEmpty ? nil : desc, avatar: form.avatar,
                            providerId: form.providerID, modelId: form.modelID,
                            instructions: instr.isEmpty ? nil : instr, capabilities: caps,
                            extraSkills: form.extraSkills.sorted(), vaultAccess: form.vaultAccess,
                            permissionLevel: form.level, resourceMode: form.startActive ? "ACTIVE" : "SLEEP",
                            idleSleepMinutes: form.idleSleep, desktopResolution: options?.advanced?.defaultResolution,
                            allowDuplicateName: form.allowDuplicateName ? true : nil)
    }

    func patch(against s: AgentSettings) -> AgentComposerPatch {
        var p = AgentComposerPatch()
        let name = form.normalizedName
        if name != s.name { p.name = name }
        let desc = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc != s.description.trimmingCharacters(in: .whitespacesAndNewlines) { p.description = desc }
        let av = form.avatar
        if av?.kind != s.avatar?.kind || av?.value != s.avatar?.value { p.avatar = av.map { .set($0) } ?? .clear }
        if form.providerID != (s.providerId ?? "") || form.modelID != (s.modelId ?? "") {
            p.providerId = form.providerID
            p.modelId = form.modelID
        }
        let instr = form.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if instr != s.instructions.trimmingCharacters(in: .whitespacesAndNewlines) { p.instructions = instr }
        var caps: [String: Bool] = [:]
        let keys = Set(capabilityChoices.map(\.id)).union(s.capabilities.keys).union(["memory"])
        for k in keys {
            let was = k == "memory" ? (s.capabilities["memory"] ?? true) : (s.capabilities[k] ?? false)
            let now = form.capabilities[k] ?? (k == "memory")
            if now != was { caps[k] = now }
        }
        if !caps.isEmpty { p.capabilities = caps }
        if form.extraSkills.sorted() != (s.extraSkills ?? []).sorted() { p.extraSkills = form.extraSkills.sorted() }
        if form.vaultAccess != s.vaultAccess { p.vaultAccess = form.vaultAccess }
        if form.level != s.permissionLevel { p.permissionLevel = form.level }
        if form.idleSleep != s.idleSleepMinutes { p.idleSleepMinutes = form.idleSleep.map { .set($0) } ?? .clear }
        if p.name != nil, form.allowDuplicateName { p.allowDuplicateName = true }
        return p
    }

    // MARK: save

    /// Validates and saves. Returns the agent id on success.
    func save(store: AgentsStore) async -> String? {
        attempted = true
        generalError = nil
        guard validate().isEmpty else {
            Haptics.error()
            return nil
        }
        saving = true
        defer { saving = false }
        serverProblem = nil
        do {
            if let agentID, let original {
                let p = patch(against: original)
                if p.isEmpty { return agentID }
                let s = try await store.updateSettings(agentID, p)
                self.original = s.settings
                form = Self.form(from: s.settings)
                originalForm = form
                Haptics.success()
                return agentID
            } else {
                let r = try await store.createAgent(createBody(), idempotencyKey: idempotencyKey)
                Haptics.success()
                return r.agent?.id ?? ""
            }
        } catch {
            handle(error)
            return nil
        }
    }

    private func handle(_ error: any Error) {
        guard let msg = AText.message(error) else { return }  // owner cancelled the confirmation
        Haptics.error()
        guard let e = error as? APIError else { generalError = msg; return }
        // a definitive rejection (4xx): nothing was created, so the next, changed attempt gets a new key
        if e.status >= 400 && e.status < 500 && e.status != 408 { idempotencyKey = UUID().uuidString }
        if e.isOffline || e.status >= 500 {
            generalError = isCreate
                ? String(localized: "NEBULA did not confirm that the agent was created (\(msg)). Check the agent list; retrying is safe, at most one agent is created.")
                : String(localized: "Could not save the settings (\(msg)). Try again.")
            return
        }
        let field: Field?
        var text = AText.sanitize(e.message)
        switch e.code {
        case "invalid_name":
            field = .name; text = String(localized: "Name: 1–64 letters, digits, spaces and . - _ ( )")
        case "duplicate_name":
            field = .name; duplicateName = true; text = String(localized: "An agent with this name already exists.")
        case "description_too_long":
            field = .description; text = String(localized: "The description can be at most \(descriptionMax) characters.")
        case "invalid_avatar":
            field = .avatar; text = String(localized: "Invalid avatar: use one emoji, 1–2 characters or one of the icons.")
        case "provider_disconnected":
            field = .provider
            text = String(localized: "The provider is not connected. Connect it on your Mac (NEBULA Dashboard → AI Providers).")
        case "provider_unsupported": field = .provider; text = String(localized: "This provider cannot run agents.")
        case "invalid_provider": field = .provider; text = String(localized: "Unknown AI provider.")
        case "model_required": field = .model; text = String(localized: "Choose a provider and a model.")
        case "model_unavailable": field = .model; text = String(localized: "The provider does not offer this model. Choose another one.")
        case "model_without_tools":
            field = .model; text = String(localized: "This model cannot use tools, so it cannot work as an agent.")
        case "models_unavailable": field = .model; text = String(localized: "Could not load the model list.")
        case "instructions_too_long":
            field = .instructions; text = String(localized: "Instructions can be at most \(instructionsMax) characters.")
        case "invalid_instructions": field = .instructions; text = String(localized: "The instructions contain characters that are not allowed.")
        case "capability_requires_level", "invalid_capability":
            field = .capabilities
            if let cap = e.details?["capability"]?.string, let lv = e.details?["requires_level"]?.string {
                text = String(localized: "\(AText.capability(cap, fallback: nil)) requires the \(AText.level(lv)) level.")
            }
        case "invalid_vault_access": field = .vault
        case "invalid_permission_level": field = .level
        case "invalid_idle_sleep": field = .idle; text = String(localized: "Sleep delay: 0–1440 minutes.")
        case "rate_limited":
            field = nil; text = String(localized: "Too many agents have been created. \(AText.rateLimited(e))")
        case "agents_permission":
            field = nil; text = String(localized: "Only the NEBULA owner can create and change agents.")
        case "unsupported_capability", "unsupported_skill", "unsupported_fields":
            field = nil; text = String(localized: "NEBULA did not accept these settings: \(AText.sanitize(e.message))")
        case "provisioning_failed":
            field = nil; text = String(localized: "Could not set up the agent in the Ubuntu VM: \(AText.sanitize(e.message))")
        default:
            field = nil; text = msg
        }
        if let field {
            serverProblem = Problem(field: field, message: text, at: form.slice(field))
        } else {
            generalError = text
        }
    }

    func allowDuplicate() {
        form.allowDuplicateName = true
        duplicateName = false
        if serverProblem?.field == .name { serverProblem = nil }
    }
}
