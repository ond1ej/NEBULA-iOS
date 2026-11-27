import Foundation

/// A live desktop connection handed out by the server (`POST /agents/{id}/live/connect`). The token inside the
/// WebSocket URL is single-use: every (re)connect needs a fresh `LiveConnectInfo`.
public struct LiveConnectInfo: Sendable, Equatable {
    public let sessionID: String
    /// Ready-to-use `wss://…/api/v1/live/ws/{session_id}?session_token=…&token=…` (built by the app layer).
    public let webSocketURL: URL
    /// The WebSocket must be opened before this.
    public let expiresAt: Date

    public init(sessionID: String, webSocketURL: URL, expiresAt: Date) {
        self.sessionID = sessionID
        self.webSocketURL = webSocketURL
        self.expiresAt = expiresAt
    }
}

/// `POST /live/sessions/{id}/control` actions.
public enum LiveControlAction: String, Sendable, CaseIterable {
    case acquire, renew, release
}

/// The server side of a live desktop, implemented by the app layer on top of NEBULA's API.
public protocol LiveDesktopBackend: Sendable {
    /// Creates a live session for the agent's desktop (view-only).
    func connect(agentID: String) async throws -> LiveConnectInfo
    /// Acquires, renews or releases the exclusive control lease. Returns whether control is held afterwards.
    /// Throw `LiveBackendError` for API errors (e.g. 409 `lease_conflict`, `agent_busy`).
    func control(sessionID: String, action: LiveControlAction) async throws -> Bool
    /// Ends the live session (best effort; never throws).
    func disconnect(sessionID: String) async
}

/// API errors the backend can report; the session maps them to user-facing notices and retry decisions.
public struct LiveBackendError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// Another viewer holds the control lease (409 lease_conflict).
        case leaseConflict = "lease_conflict"
        /// The agent did not reach a safe GUI boundary in time (409 agent_busy).
        case agentBusy = "agent_busy"
        /// The live session is no longer active (409 not_viewing).
        case notViewing = "not_viewing"
        /// The agent's desktop is asleep / stopped (409 desktop_not_running).
        case desktopNotRunning = "desktop_not_running"
        /// The agent runs on the host without a desktop (409 host_environment).
        case hostEnvironment = "host_environment"
        /// 404 live_session_not_found.
        case sessionNotFound = "live_session_not_found"
        /// 401/403: the app session lacks the permission.
        case unauthorized
        /// Transport failure talking to the API.
        case network
        case other
    }

    public var kind: Kind
    /// Server-provided detail (shown to the owner when there is no better text).
    public var message: String?

    public init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    /// Maps a NEBULA API error code (`error.code`).
    public init(code: String, message: String? = nil) {
        self.init(kind: Kind(rawValue: code) ?? .other, message: message)
    }

    /// Whether reconnecting can help.
    public var isRetryable: Bool {
        switch kind {
        case .desktopNotRunning, .hostEnvironment, .unauthorized: false
        default: true
        }
    }

    public var description: String { kind.rawValue + (message.map { ": \($0)" } ?? "") }
}
