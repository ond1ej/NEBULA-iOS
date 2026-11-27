import Foundation
import NEBULACore
import NEBULANetwork

// Agent composer endpoints (GET /miniapp/agent-options, …/models, POST /miniapp/agents, GET/PATCH
// /miniapp/agents/{id}/settings) and the per-agent task list, in the server's real shapes. Every catalogue field is
// optional so an older or newer NEBULA never breaks the form; the host validates everything again.

/// GET /miniapp/agent-options — the catalogue the agent form is built from.
public struct ComposerOptions: Decodable, Sendable, Hashable {
    public struct Provider: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String?
        public var state: String?
        public var connected: Bool?
        public var reason: String?
        public var displayName: String { name ?? id }
        public var isConnected: Bool { connected ?? false }
    }

    public struct Capability: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String?
        public var description: String?
        public var `default`: Bool?
        public var requiresLevel: String?
    }

    public struct Level: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var description: String?
    }

    public struct Choice: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String?
        public var description: String?
        public var `default`: Bool?
    }

    public struct Vault: Decodable, Sendable, Hashable {
        public var options: [Choice]?
        public var grantedNote: String?
    }

    public struct Memory: Decodable, Sendable, Hashable {
        public var `default`: Bool?
        public var description: String?
    }

    public struct ExtraSkill: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String?
        public var description: String?
        public var kind: String?
        public var requiresLevel: String?
    }

    public struct Avatar: Decodable, Sendable, Hashable {
        public var kinds: [String]?
        public var icons: [String]?
    }

    public struct NameRules: Decodable, Sendable, Hashable { public var max: Int? }
    public struct Limits: Decodable, Sendable, Hashable {
        public var instructionsMax: Int?
        public var descriptionMax: Int?
    }
    public struct IdleRange: Decodable, Sendable, Hashable { public var min: Int?; public var max: Int? }
    public struct Advanced: Decodable, Sendable, Hashable {
        public var resourceModes: [String]?
        public var resolutions: [String]?
        public var defaultResolution: String?
        public var idleSleepMinutes: IdleRange?
    }

    public var providers: [Provider]?
    public var capabilities: [Capability]?
    public var memory: Memory?
    public var extraSkills: [ExtraSkill]?
    public var levels: [Level]?
    public var defaultLevel: String?
    public var vault: Vault?
    public var advanced: Advanced?
    public var avatar: Avatar?
    public var nameRules: NameRules?
    public var existingNames: [String]?
    public var defaultInstructions: String?
    public var limits: Limits?
}

/// GET /miniapp/agent-options/models?provider_id= — the provider's live model list (never an invented id).
public struct ModelChoice: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var supportsTools: Bool?
    public var supportsImages: Bool?
    public var contextTokens: Int?
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? id }
    public var usableByAgents: Bool { supportsTools ?? true }
}

/// POST /miniapp/agents body (environment is always the Ubuntu VM from the apps; native Mac execution is Mac-only).
public struct NewAgentBody: Encodable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var avatar: AgentAvatar?
    public var providerId: String
    public var modelId: String
    public var instructions: String?
    public var environment: String = "vm"
    public var capabilities: [String: Bool]
    public var extraSkills: [String]
    public var vaultAccess: String
    public var permissionLevel: String
    public var resourceMode: String
    public var idleSleepMinutes: Int?
    public var desktopResolution: String?
    public var allowDuplicateName: Bool?

    public init(name: String, description: String? = nil, avatar: AgentAvatar? = nil, providerId: String,
                modelId: String, instructions: String? = nil, capabilities: [String: Bool], extraSkills: [String] = [],
                vaultAccess: String = "none", permissionLevel: String = "STANDARD", resourceMode: String = "ACTIVE",
                idleSleepMinutes: Int? = nil, desktopResolution: String? = nil, allowDuplicateName: Bool? = nil) {
        self.name = name; self.description = description; self.avatar = avatar; self.providerId = providerId
        self.modelId = modelId; self.instructions = instructions; self.capabilities = capabilities
        self.extraSkills = extraSkills; self.vaultAccess = vaultAccess; self.permissionLevel = permissionLevel
        self.resourceMode = resourceMode; self.idleSleepMinutes = idleSleepMinutes
        self.desktopResolution = desktopResolution; self.allowDuplicateName = allowDuplicateName
    }
}

/// A PATCH field that can also be cleared (sent as JSON `null`): the avatar and the idle-sleep timeout.
public enum PatchValue<T: Encodable & Sendable & Hashable>: Sendable, Hashable {
    case set(T)
    case clear
}

/// PATCH /miniapp/agents/{id}/settings — only the fields that changed (provider and model always together).
public struct AgentComposerPatch: Encodable, Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var avatar: PatchValue<AgentAvatar>?
    public var providerId: String?
    public var modelId: String?
    public var instructions: String?
    public var capabilities: [String: Bool]?
    public var extraSkills: [String]?
    public var vaultAccess: String?
    public var permissionLevel: String?
    public var idleSleepMinutes: PatchValue<Int>?
    public var allowDuplicateName: Bool?

    public init() {}

    public var isEmpty: Bool {
        name == nil && description == nil && avatar == nil && providerId == nil && modelId == nil &&
            instructions == nil && capabilities == nil && extraSkills == nil && vaultAccess == nil &&
            permissionLevel == nil && idleSleepMinutes == nil
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, avatar, providerId, modelId, instructions, capabilities, extraSkills, vaultAccess,
             permissionLevel, idleSleepMinutes, allowDuplicateName
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        switch avatar {
        case .set(let a)?: try c.encode(a, forKey: .avatar)
        case .clear?: try c.encodeNil(forKey: .avatar)
        case nil: break
        }
        try c.encodeIfPresent(providerId, forKey: .providerId)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encodeIfPresent(instructions, forKey: .instructions)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(extraSkills, forKey: .extraSkills)
        try c.encodeIfPresent(vaultAccess, forKey: .vaultAccess)
        try c.encodeIfPresent(permissionLevel, forKey: .permissionLevel)
        switch idleSleepMinutes {
        case .set(let m)?: try c.encode(m, forKey: .idleSleepMinutes)
        case .clear?: try c.encodeNil(forKey: .idleSleepMinutes)
        case nil: break
        }
        if allowDuplicateName == true { try c.encode(true, forKey: .allowDuplicateName) }
    }
}

/// The composer's settings answer: the editable settings plus the agent's public record.
public struct ComposerSettings: Decodable, Sendable {
    public var settings: AgentSettings
    public var agent: Agent?

    private enum CodingKeys: String, CodingKey { case agent }

    public init(from decoder: any Decoder) throws {
        settings = try AgentSettings(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try? c.decodeIfPresent(Agent.self, forKey: .agent)
    }
}

public extension APIClient {
    func agentComposerOptions() async throws -> ComposerOptions { try await get("/miniapp/agent-options") }

    func agentComposerModels(providerID: String) async throws -> [ModelChoice] {
        try await get("/miniapp/agent-options/models", query: ["provider_id": providerID])
    }

    func agentComposerSettings(_ agentID: String) async throws -> ComposerSettings {
        try await get("/miniapp/agents/\(agentID)/settings")
    }

    /// The Idempotency-Key makes a retry (double tap, lost connection) return the same agent, never a second one.
    func createAgent(_ body: NewAgentBody, idempotencyKey: String) async throws -> ComposerSettings {
        try await post("/miniapp/agents", body: body, idempotencyKey: idempotencyKey)
    }

    func updateAgentComposer(_ agentID: String, _ patch: AgentComposerPatch) async throws -> ComposerSettings {
        try await self.patch("/miniapp/agents/\(agentID)/settings", body: patch)
    }

    /// DELETE /agents/{id}?confirm=true — removes the agent's Linux account, desktop and files (fresh owner only).
    func deleteAgent(_ agentID: String) async throws -> JSONValue {
        try await delete("/agents/\(agentID)", query: ["confirm": "true"])
    }

    /// The agent's latest tasks, newest first.
    func agentTasks(_ agentID: String, limit: Int = 20) async throws -> [AgentTask] {
        try await get("/agents/\(agentID)/tasks", query: ["limit": String(limit)])
    }
}

/// Re-decodes a free-form server answer (e.g. the agent returned by pause / wake) into a typed model.
enum Remodel {
    static func decode<T: Decodable>(_ value: JSONValue, as: T.Type = T.self) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? NJSON.decoder().decode(T.self, from: data)
    }

    static func decode<T: Decodable>(json: String, as: T.Type = T.self) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        do { return try NJSON.decoder().decode(T.self, from: data) } catch {
            return nil
        }
    }

    static func taskRef(id: String, state: String) -> TaskRef? {
        decode(.object(["id": .string(id), "state": .string(state)]))
    }
}
