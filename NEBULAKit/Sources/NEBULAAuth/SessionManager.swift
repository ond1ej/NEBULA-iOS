import Foundation
import NEBULACore
import NEBULANetwork

/// The app's session with NEBULA: signs single-use server challenges with the device identity key (no user
/// interaction), verifies every challenge with the pinned server key, and caches the bearer token in the Keychain.
public actor SessionManager: SessionTokenProvider {
    public enum State: Sendable, Equatable {
        case signedIn
        case pendingApproval(code: String?)
        case revoked
        case serverMismatch
        case offline(String)
    }

    struct Stored: Codable { var token: String; var sessionId: String; var expiresAt: Double; var maxExpiresAt: Double }

    private let profile: ServerProfile
    private let keys: DeviceKeys
    private let api: APIClient
    private var stored: Stored?
    private var inflight: Task<Stored, any Error>?
    private let appVersion: String
    private static let tokenAccount = "session.token"

    public init(profile: ServerProfile, keys: DeviceKeys, appVersion: String) {
        self.profile = profile
        self.keys = keys
        self.appVersion = appVersion
        self.api = APIClient(baseURL: profile.gatewayURL, tokens: nil)
        if let d = try? Keychain.get(Self.tokenAccount), let s = try? JSONDecoder().decode(Stored.self, from: d),
           s.maxExpiresAt > Date().timeIntervalSince1970 + 60 {
            stored = s
        }
    }

    public var sessionID: String? { stored?.sessionId }

    public func sessionToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let s = stored, s.maxExpiresAt > Date().timeIntervalSince1970 + 60 { return s.token }
        return try await refresh().token
    }

    /// The current session id (after making sure a session exists) — part of every signed owner confirmation.
    public func currentSessionID() async throws -> String {
        _ = try await sessionToken(forceRefresh: false)
        return stored?.sessionId ?? ""
    }

    public func invalidate() {
        stored = nil
        Keychain.delete(Self.tokenAccount)
    }

    private func refresh() async throws -> Stored {
        if let t = inflight { return try await t.value }
        let t = Task { try await signIn() }
        inflight = t
        defer { inflight = nil }
        let s = try await t.value
        stored = s
        if let d = try? JSONEncoder().encode(s) {
            try? Keychain.set(d, account: Self.tokenAccount, protection: .afterFirstUnlock)
        }
        return s
    }

    private struct ChallengeBody: Codable, Sendable { var deviceId: String }
    private struct Challenge: Codable, Sendable {
        var challengeId: String; var challenge: String; var expiresAt: Double; var serverSignature: String
    }
    private struct SignInBody: Codable, Sendable {
        var deviceId: String; var challengeId: String; var signature: String; var appVersion: String
    }
    private struct SignInResult: Codable, Sendable {
        var token: String; var sessionId: String; var expiresAt: Double; var maxExpiresAt: Double
    }

    public struct SessionError: Error, LocalizedError, Sendable {
        public let state: State
        public let message: String
        public var errorDescription: String? { message }
    }

    private func signIn() async throws -> Stored {
        let ch: Challenge
        do {
            ch = try await api.publicPost("/api/app/session/challenge", body: ChallengeBody(deviceId: profile.deviceID))
        } catch let e as APIError {
            switch e.code {
            case "pending_approval":
                throw SessionError(state: .pendingApproval(code: e.details?["verification_code"]?.string),
                                   message: e.message)
            case "device_revoked":
                throw SessionError(state: .revoked, message: String(localized: "This device is no longer paired with NEBULA."))
            default:
                throw e
            }
        }
        // the challenge must be signed by the server we paired with (protects against an impersonating server)
        let srv = Data(["nebula-app-challenge/v1", profile.deviceID, ch.challengeId, ch.challenge]
            .joined(separator: "\n").utf8)
        guard PairingService.verify(serverKey: profile.serverKey, payload: srv, signature: ch.serverSignature) else {
            NLog.auth.error("server challenge signature mismatch")
            throw SessionError(state: .serverMismatch,
                               message: String(localized: "The server did not prove its identity with the paired key. The connection was refused."))
        }
        let payload = Data(["nebula-app-session/v1", profile.deviceID, ch.challengeId, ch.challenge]
            .joined(separator: "\n").utf8)
        let sig = try keys.signWithIdentity(payload)
        let r: SignInResult = try await api.publicPost("/api/app/session", body: SignInBody(
            deviceId: profile.deviceID, challengeId: ch.challengeId, signature: sig, appVersion: appVersion))
        return Stored(token: r.token, sessionId: r.sessionId, expiresAt: r.expiresAt, maxExpiresAt: r.maxExpiresAt)
    }

    /// Ends this session on the server (Settings → Sign out of this device keeps the pairing).
    public func logout() async {
        guard let s = stored else { return }
        var req = URLRequest(url: profile.gatewayURL.appending(path: "api/app/logout"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        invalidate()
    }
}
