import Foundation

// Wire models of the NEBULA host API (the same endpoints the Telegram Mini App uses). Fields the apps do not need are
// simply not decoded; optional fields are optional because older servers or other roles may omit them.

// MARK: - Agents

public struct AgentAvatar: Codable, Sendable, Hashable {
    public var kind: String
    public var value: String
    public init(kind: String, value: String) { self.kind = kind; self.value = value }
}

public struct AgentConfig: Codable, Sendable, Hashable {
    public var memoryAutoSave: Bool?
    public var idleSleepMinutes: Int?
    public var avatar: AgentAvatar?
    public var instructions: String?
    public var signInAssistance: Bool?
}

public struct TaskRef: Codable, Sendable, Hashable {
    public var id: String
    public var state: String
}

public struct Agent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
    public var state: String
    public var providerId: String?
    public var modelId: String?
    public var permissionLevel: String?
    public var resourceMode: String?
    public var desktopResolution: String?
    public var lastError: String?
    public var lastActiveAt: Epoch?
    public var createdAt: Epoch?
    public var updatedAt: Epoch?
    public var currentTask: TaskRef?
    public var config: AgentConfig?

    public init(id: String, name: String, state: String) {
        self.id = id; self.name = name; self.state = state
    }

    /// Agent states as the UI groups them.
    public var activity: AgentActivity {
        switch state {
        case "ACTIVE": return currentTask != nil ? .working : .ready
        case "READY", "IDLE": return currentTask != nil ? .working : .ready
        case "SLEEP", "STOPPED": return .sleeping
        case "PAUSED": return .paused
        case "ERROR": return .error
        case "CREATING", "DELETING": return .busy
        default: return .ready
        }
    }
}

public enum AgentActivity: Sendable {
    case ready, working, sleeping, paused, error, busy
}

/// GET/PATCH /miniapp/agents/{id}/settings (the agent composer: the same model the Mini App and dashboard use).
public struct AgentSettings: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var avatar: AgentAvatar?
    public var providerId: String?
    public var modelId: String?
    public var instructions: String
    public var permissionLevel: String
    public var capabilities: [String: Bool]
    public var extraSkills: [String]?
    public var vaultAccess: String
    public var status: String?
    public var resourceMode: String?
    public var idleSleepMinutes: Int?
    public var desktopResolution: String?
    public var ready: Bool?
}

public struct AgentSettingsPatch: Codable, Sendable {
    public var name: String?
    public var description: String?
    public var avatar: AgentAvatar?
    public var providerId: String?
    public var modelId: String?
    public var instructions: String?
    public var capabilities: [String: Bool]?
    public var vaultAccess: String?
    public var permissionLevel: String?
    public var idleSleepMinutes: Int?
    public init() {}
}

// MARK: - Conversations & messages

public struct ConversationPreview: Codable, Sendable, Hashable {
    public var role: String
    public var content: String
    public var createdAt: Epoch
}

public struct Conversation: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var agentName: String
    public var agentStatus: String?
    public var title: String
    public var createdAt: Epoch
    public var updatedAt: Epoch
    public var lastMessageAt: Epoch?
    public var lastMessage: ConversationPreview?
    public var unreadCount: Int
    public var archived: Bool
    public var isDefault: Bool?
    public var runningTask: TaskRef?

    public var sortDate: Epoch { lastMessageAt ?? updatedAt }
}

public struct MessageTask: Codable, Sendable, Hashable {
    public var id: String
    public var state: String
    public var startedAt: Epoch?
    public var finishedAt: Epoch?
    public var failureReason: String?
}

/// An attachment reference inside a message: an uploaded attachment object, or an artifact ref string.
public enum MessageAttachment: Codable, Sendable, Hashable, Identifiable {
    case artifact(String)
    case file(Attachment)

    public var id: String {
        switch self {
        case .artifact(let s): return s
        case .file(let a): return a.id
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .artifact(s) }
        else { self = .file(try c.decode(Attachment.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .artifact(let s): try c.encode(s)
        case .file(let a): try c.encode(a)
        }
    }
}

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var kind: String?
    public var mime: String?
    public var size: Int?
    public var status: String?
    public var error: String?
    public var createdAt: Epoch?
    public var extracted: JSONValue?

    public var transcript: String? { extracted?["transcript"]?["text"]?.string }
    public var isImage: Bool { (mime ?? "").hasPrefix("image/") || kind == "image" }
    public var isAudio: Bool { (mime ?? "").hasPrefix("audio/") || kind == "audio" || kind == "voice" }
}

public struct Message: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var conversationId: String
    public var agentId: String
    public var taskId: String?
    public var role: String
    public var channel: String?
    public var content: String
    public var attachments: [MessageAttachment]
    public var createdAt: Epoch
    public var clientId: String?
    public var task: MessageTask?

    public init(id: String, conversationId: String, agentId: String, role: String, content: String,
                createdAt: Epoch, clientId: String? = nil, taskId: String? = nil) {
        self.id = id; self.conversationId = conversationId; self.agentId = agentId; self.role = role
        self.content = content; self.createdAt = createdAt; self.clientId = clientId; self.taskId = taskId
        self.attachments = []
    }

    public var isUser: Bool { role == "user" }
}

public struct MessagePage: Codable, Sendable {
    public var items: [Message]
    public var hasMore: Bool
}

public struct SendMessageResult: Codable, Sendable {
    public var message: Message
    public var task: MessageTask?
}

public struct SearchHit: Codable, Sendable, Hashable, Identifiable {
    public var messageId: String
    public var conversationId: String
    public var agentId: String
    public var agentName: String
    public var role: String
    public var snippet: String
    public var createdAt: Epoch
    public var id: String { messageId }
}

public struct SearchResult: Codable, Sendable {
    public var conversations: [Conversation]
    public var messages: [SearchHit]
}

// MARK: - Tasks

public enum TaskStates {
    public static let terminal: Set<String> = ["COMPLETED", "FAILED", "CANCELLED"]
    public static let paused: Set<String> = ["PAUSED", "PAUSING"]
    public static let waiting: Set<String> = ["WAITING_APPROVAL", "WAITING_PROVIDER", "WAITING_CONTROL"]
}

public struct AgentTask: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var agentName: String?
    public var prompt: String
    public var state: String
    public var currentStep: Int?
    public var toolCallsDone: Int?
    public var maxSteps: Int?
    public var failureReason: String?
    public var result: JSONValue?
    public var createdAt: Epoch
    public var updatedAt: Epoch?
    public var startedAt: Epoch?
    public var finishedAt: Epoch?
    public var steps: [TaskStep]?

    public var isTerminal: Bool { TaskStates.terminal.contains(state) }
    public var summary: String? { result?["summary"]?.string }
}

public struct TaskStep: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var seq: Int
    public var toolType: String
    public var resultStatus: String
    public var resultSummary: String?
    public var elapsedMs: Double?
    public var createdAt: Epoch
}

// MARK: - Approvals & notifications

public struct CenterApproval: Codable, Sendable, Identifiable, Hashable {
    public var kind: String
    public var id: String
    public var taskId: String?
    public var agentId: String?
    public var agentName: String?
    public var tool: String?
    public var actionSummary: String?
    public var summary: String?
    public var reason: String?
    public var prompt: String?
    public var createdAt: Epoch
    public var expiresAt: Epoch

    public var title: String { actionSummary ?? summary ?? kind }
    public var isTask: Bool { kind == "task" }
}

public struct ApprovalCenter: Codable, Sendable {
    public var pending: [CenterApproval]
    public var signIns: [SignInSession]?
}

public struct NebulaNotification: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var sequence: Int
    public var type: String
    public var agentId: String?
    public var taskId: String?
    public var agentName: String?
    public var timestamp: Epoch
    public var payload: JSONValue?
}

// MARK: - Live Desktop

public struct LiveConnect: Codable, Sendable {
    public var sessionId: String
    public var token: String
    public var state: String
    public var readOnly: Bool
    public var wsPath: String
    public var expiresAt: Epoch
    public var ttlSeconds: Int
}

public struct ControlResult: Codable, Sendable {
    public var sessionId: String
    public var control: Bool
    public var leaseExpiresAt: Epoch?
}

// MARK: - System

public struct Health: Codable, Sendable {
    public struct VM: Codable, Sendable { public var state: String? }
    public struct Guest: Codable, Sendable { public var status: String?; public var latencyMs: Double? }
    public var status: String
    public var api: String?
    public var db: String?
    public var vm: VM?
    public var guest: Guest?
    public var version: String?
}

public struct SystemInfo: Codable, Sendable {
    public struct Host: Codable, Sendable {
        public var memoryTotalBytes: Double?
        public var memoryAvailableBytes: Double?
        public var memoryFreePercent: Double?
        public var memoryPressure: String?
        public var loadAvg: [Double]?
        public var cpuCount: Int?
        public var diskTotalBytes: Double?
        public var diskFreeBytes: Double?
        public var vmFootprintBytes: Double?
        public var vmResidentBytes: Double?
        public var os: String?
        public var arch: String?
        public var appVersion: String?
    }
    public struct VMStatus: Codable, Sendable { public var state: String?; public var message: String? }
    public struct GuestStatus: Codable, Sendable { public var status: String?; public var latencyMs: Double? }
    public struct Limits: Codable, Sendable { public var activeGuiAgents: Int?; public var runningWorkers: Int? }
    public var host: Host?
    public var vm: VMStatus?
    public var guest: GuestStatus?
    public var limits: Limits?
}

// MARK: - Password Vault (metadata only)

public struct VaultStatus: Codable, Sendable, Hashable {
    public struct Broker: Codable, Sendable, Hashable {
        public var enabled: Bool?
        public var available: Bool?
        public var reason: String?
    }
    public var exists: Bool
    public var locked: Bool
    public var entryCount: Int
    public var autoLockMinutes: Int?
    public var unlockedAt: Epoch?
    public var lockAt: Epoch?
    public var lockoutUntil: Epoch?
    public var broker: Broker?
}

public struct VaultEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var appName: String?
    public var origin: String?
    public var credentialType: String
    public var tags: [String]
    public var createdAt: Epoch
    public var updatedAt: Epoch
    public var grantCount: Int?
}

/// GET /vault/entries/{id} — the username and whether a password exists; never the password itself.
public struct VaultEntryDetail: Codable, Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var appName: String?
    public var origin: String?
    public var credentialType: String
    public var tags: [String]?
    public var username: String?
    public var hasPassword: Bool?
    public var notes: String?
    public var loginUrl: String?
    public var createdAt: Epoch?
    public var updatedAt: Epoch?
}

public struct VaultEntryInput: Codable, Sendable {
    public var displayName: String?
    public var origin: String?
    public var credentialType: String?
    public var username: String?
    public var password: String?
    public var notes: String?
    public var loginUrl: String?
    public var tags: [String]?
    public init() {}
}

public struct VaultGrant: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var entryId: String
    public var entryName: String
    public var allowedOrigins: [String]
    public var approvalPolicy: String
    public var enabled: Bool
    public var expiresAt: Epoch?
    public var createdAt: Epoch
    public var lastUsedAt: Epoch?
}

public struct AgentVault: Codable, Sendable {
    public var agentId: String
    public var mode: String
    public var grants: [VaultGrant]
}

public struct VaultAuditRow: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var ts: Epoch
    public var actorType: String
    public var actorId: String?
    public var agentName: String?
    public var entryName: String?
    public var operation: String
    public var destinationOrigin: String?
    public var outcome: String
    public var reasonCode: String?
}

public struct RevealResult: Codable, Sendable {
    public var value: String
}

// MARK: - Owner assurance / unified confirmation

public struct Assurance: Codable, Sendable {
    public struct Methods: Codable, Sendable {
        public struct Device: Codable, Sendable { public var deviceId: String; public var vaultKey: Bool }
        public var password: Bool?
        public var vaultPassphrase: Bool?
        public var device: Device?
    }
    public struct Vault: Codable, Sendable {
        public var exists: Bool
        public var locked: Bool
        public var reauthUntil: Epoch?
    }
    public var interface: String
    public var role: String
    public var freshUntil: Epoch?
    public var fresh: Bool
    public var windowS: Int?
    public var methods: Methods?
    public var vault: Vault?
}

public struct ConfirmChallenge: Codable, Sendable {
    public var challengeId: String
    public var challenge: String
    public var expiresAt: Epoch
    public var purpose: String
    public var vaultKey: Bool
}

public struct ConfirmResult: Codable, Sendable {
    public struct Vault: Codable, Sendable {
        public var exists: Bool
        public var locked: Bool
        public var entryCount: Int?
        public var result: String?
        public var reauthUntil: Epoch?
        public var deviceKey: Bool
    }
    public var freshUntil: Epoch?
    public var vault: Vault?
    public var vaultUnlockNeeded: Bool?
}

public struct AppDevice: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var platform: String
    public var model: String?
    public var appVersion: String?
    public var keyProtection: String
    public var status: String
    public var createdAt: Epoch
    public var approvedAt: Epoch?
    public var lastSeenAt: Epoch?
    public var keyFingerprint: String?
    public var push: Bool?
    public var vaultKey: Bool?
    public var verificationCode: String?
}

public struct AppMe: Codable, Sendable {
    public var device: AppDevice?
    public var serverVersion: String
    public var serverFingerprint: String
    public var assurance: Assurance?
    public var gatewayUrl: String?
}

// MARK: - Events

/// One server event (GET /events, text/event-stream). Live-only events (streamed model text) carry no sequence.
public struct ServerEvent: Codable, Sendable, Hashable {
    public var id: String?
    public var sequence: Int?
    public var type: String
    public var agentId: String?
    public var taskId: String?
    public var timestamp: Epoch?
    public var payload: JSONValue?
}
