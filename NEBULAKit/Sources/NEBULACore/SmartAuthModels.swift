import Foundation

// Smart Authentication 3.0 wire models (GET /smart-auth/sessions, /approval-center `sign_ins`). Nothing here is ever a
// secret: typed values, submission tokens and confirmations live only in memory for one POST.

public struct SignInField: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var role: String  // email | phone | username | username_or_email | password | otp | recovery_code
    public var input: String  // email | tel | text | password | code
    public var length: Int?
    public var charset: String?

    public var isSecret: Bool { role == "password" || role == "recovery_code" }
    public var isCode: Bool { role == "otp" || input == "code" }
}

public struct SignInAccount: Codable, Sendable, Hashable, Identifiable {
    public var entryId: String
    public var name: String
    public var username: String?
    public var hasGrant: Bool
    public var policy: String?
    public var id: String { entryId }
}

public struct SignInTrust: Codable, Sendable, Hashable {
    public struct Reason: Codable, Sendable, Hashable { public var code: String; public var text: String }
    public var level: String  // GREEN | YELLOW | RED
    public var reasons: [Reason]
    public var provider: String?
    public var hard: Bool?
}

public struct SignInVaultInfo: Codable, Sendable, Hashable {
    public var state: String  // not_created | locked | unlocked
    public var canSave: Bool
    public var canUnlock: Bool?
    public var reason: String?
}

public struct SignInOTP: Codable, Sendable, Hashable {
    public var channel: String
    public var length: Int?
    public var charset: String?
}

public struct SignInManual: Codable, Sendable, Hashable {
    public var kind: String
    public var liveDesktop: Bool?
    public var canCompleteHere: Bool?
    public var webauthnPending: Bool?
}

public struct SignInDestination: Codable, Sendable, Hashable {
    public var origin: String
    public var kind: String
    public var sameSite: Bool
    public var requestedOrigin: String
    public var secretsPending: Bool
}

public struct SignInRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String  // credentials | otp | recovery_code | confirm_destination | device_approval | manual | method_choice | loop
    public var seq: Int
    public var expiresAt: Epoch
    public var step: String?
    public var fields: [SignInField]
    public var otp: SignInOTP?
    public var reviewRequired: Bool
    public var error: String?
    public var requirement: String?
    public var notes: [String]?
    public var trust: SignInTrust?
    public var alternatives: [String]?
    public var pageOrigin: String?
    public var vault: SignInVaultInfo
    public var saveIntent: String?
    public var local: Bool
    public var fresh: Bool?
    public var remoteSubmission: Bool
    public var pinConfigured: Bool
    public var pinRequiredFor: [String]
    public var allowFutureAvailable: Bool?
    public var allowFutureNeedsStepup: Bool?
    public var accounts: [SignInAccount]?
    public var destination: SignInDestination?
    public var manual: SignInManual?
    public var approvalNumber: String?
    public var codeTtlS: Int?
}

public struct SignInSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var state: String
    public var agentId: String
    public var agentName: String
    public var taskId: String
    public var conversationId: String?
    public var requestedOrigin: String
    public var verifiedOrigin: String?
    public var site: String
    public var step: String?
    public var stepSeq: Int?
    public var errorCode: String?
    public var createdAt: Epoch
    public var updatedAt: Epoch
    public var expiresAt: Epoch
    public var completedAt: Epoch?
    public var savedToVault: Bool?
    public var trust: SignInTrust?
    public var request: SignInRequest?

    public static let finalStates: Set<String> = ["AUTHENTICATED", "FAILED", "CANCELLED", "EXPIRED"]
    public var isFinal: Bool { Self.finalStates.contains(state) }
    public var needsOwner: Bool { request != nil && !isFinal }
}

public struct SubmitToken: Codable, Sendable {
    public var requestId: String
    public var token: String
    public var expiresAt: Epoch
}

/// POST /smart-auth/sessions/{id}/submit. Encoded with snake_case keys. Values are cleared by the caller after use.
public struct SignInSubmit: Encodable, Sendable {
    public var requestId: String
    public var token: String
    public var action: String
    public var values: [String: String]?
    public var entryId: String?
    public var save: String?
    public var allowFuture: Bool?
    public var name: String?
    public var reviewConfirmed: Bool?
    public var alternative: String?

    public init(requestId: String, token: String, action: String) {
        self.requestId = requestId; self.token = token; self.action = action
    }
}
