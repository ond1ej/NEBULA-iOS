import Foundation
import NEBULACore
import NEBULANetwork

/// Unified owner confirmation (NEBULA 1.0): ONE Face ID / Touch ID / passcode prompt both re-verifies the owner on
/// this session and — when asked — unlocks the Password Vault (or re-confirms it for revealing a password). No remote
/// PIN, no login password, no second "vault passphrase" prompt in daily use.
///
/// First activation on a device needs the vault passphrase once (together with the biometric prompt); NEBULA then
/// wraps the vault key for this device with a key derived from the device's vault secret.
public struct OwnerConfirmation: Sendable {
    public enum Purpose: String, Sendable { case stepup, vaultUnlock = "vault_unlock", vaultReveal = "vault_reveal",
                                            signIn = "sign_in", approve, admin }

    public struct Outcome: Sendable {
        public var freshUntil: Date?
        public var vaultLocked: Bool?
        public var vaultUnlockNeeded: Bool
        public var deviceKeyEnrolled: Bool
        public var vaultResult: String?
    }

    let api: APIClient
    let session: SessionManager
    let keys: DeviceKeys
    let deviceID: String

    public init(api: APIClient, session: SessionManager, keys: DeviceKeys, deviceID: String) {
        self.api = api; self.session = session; self.keys = keys; self.deviceID = deviceID
    }

    private struct ChallengeBody: Codable, Sendable { var purpose: String }
    private struct ConfirmBody: Codable, Sendable {
        var method: String
        var challengeId: String?
        var signature: String?
        var vaultSecret: String?
        var passphrase: String?
        var unlockVault: Bool
        var enrollVaultKey: Bool
    }

    /// The prompt text the system shows under Face ID / Touch ID.
    public static func reason(_ p: Purpose) -> String {
        switch p {
        case .vaultUnlock: return String(localized: "Unlock the NEBULA vault")
        case .vaultReveal: return String(localized: "Show a password from the vault")
        case .signIn: return String(localized: "Sign the agent in")
        case .approve: return String(localized: "Approve the agent action")
        case .admin, .stepup: return String(localized: "Confirm it is you")
        }
    }

    /// One biometric confirmation. `passphrase` only for the first activation (the server answers
    /// `vaultUnlockNeeded` when the vault is locked and this device has no vault key yet).
    public func confirm(_ purpose: Purpose, unlockVault: Bool = false, enroll: Bool = true,
                        passphrase: String? = nil) async throws -> Outcome {
        for attempt in 0..<2 {
            let sid = try await session.currentSessionID()
            let ch: ConfirmChallenge = try await api.post("/auth/confirm/challenge",
                                                          body: ChallengeBody(purpose: purpose.rawValue))
            let ctx = try await OwnerPresence.evaluate(reason: Self.reason(purpose))
            defer { ctx.invalidate() }
            let wantSecret = unlockVault || enroll || purpose == .vaultReveal || ch.vaultKey
            let signed = try keys.confirm({ secret in
                let digest = secret.map(DeviceKeys.sha256Hex) ?? "-"
                return Data(["nebula-owner-confirm/v1", deviceID, sid, ch.challengeId, ch.challenge, purpose.rawValue,
                             digest].joined(separator: "\n").utf8)
            }, withSecret: wantSecret, context: ctx)
            let body = ConfirmBody(method: "app_key", challengeId: ch.challengeId, signature: signed.signature,
                                   vaultSecret: signed.secret?.base64EncodedString(), passphrase: passphrase,
                                   unlockVault: unlockVault, enrollVaultKey: enroll)
            do {
                let r: ConfirmResult = try await api.post("/auth/confirm", body: body)
                return Outcome(freshUntil: r.freshUntil.map { Date(timeIntervalSince1970: $0) },
                               vaultLocked: r.vault?.locked, vaultUnlockNeeded: r.vaultUnlockNeeded ?? false,
                               deviceKeyEnrolled: r.vault?.deviceKey ?? false, vaultResult: r.vault?.result)
            } catch let e as APIError where e.code == "challenge_expired" && attempt == 0 {
                continue  // the session was renewed between challenge and answer: once more
            }
        }
        throw APIError(status: 401, code: "challenge_expired", message: String(localized: "Verification timed out, try again."))
    }

    /// The single fallback without biometrics: the vault passphrase (verifies the owner AND unlocks the vault).
    public func confirmWithPassphrase(_ passphrase: String, unlockVault: Bool = true) async throws -> Outcome {
        let body = ConfirmBody(method: "vault_passphrase", challengeId: nil, signature: nil, vaultSecret: nil,
                               passphrase: passphrase, unlockVault: unlockVault, enrollVaultKey: false)
        let r: ConfirmResult = try await api.post("/auth/confirm", body: body)
        return Outcome(freshUntil: r.freshUntil.map { Date(timeIntervalSince1970: $0) }, vaultLocked: r.vault?.locked,
                       vaultUnlockNeeded: r.vaultUnlockNeeded ?? false, deviceKeyEnrolled: r.vault?.deviceKey ?? false,
                       vaultResult: r.vault?.result)
    }
}
