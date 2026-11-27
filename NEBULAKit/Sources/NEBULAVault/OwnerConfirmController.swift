import Foundation
import NEBULAAuth
import NEBULACore
import NEBULANetwork
import Observation

/// Drives the unified owner confirmation for the whole app (wired into `OwnerGate.confirm`).
///
/// Daily use: ONE Face ID / Touch ID / passcode prompt. Only the very first vault unlock on a device asks for the
/// vault passphrase once (in the same step); afterwards the vault key is wrapped for this device.
@MainActor
@Observable
public final class OwnerConfirmController {
    /// Shown by the app shell as a sheet: the vault passphrase (first activation, or no biometrics on this device).
    public struct PassphraseRequest: Identifiable, Sendable {
        public let id = UUID()
        public let reason: String
        public let firstActivation: Bool
        public let biometricLabel: String
    }

    public var passphraseRequest: PassphraseRequest?
    public var lastError: String?
    public private(set) var working = false

    private let confirmation: OwnerConfirmation
    private let api: APIClient
    private var pending: CheckedContinuation<(String, Bool)?, Never>?
    /// Whether this device already holds a vault key (refreshed from /auth/assurance).
    public private(set) var deviceHasVaultKey: Bool?

    public init(confirmation: OwnerConfirmation, api: APIClient) {
        self.confirmation = confirmation
        self.api = api
    }

    public func refreshAssurance() async {
        if let a = try? await api.assurance() { deviceHasVaultKey = a.methods?.device?.vaultKey }
    }

    /// The sheet answers here: (passphrase, remember with Face ID) or nil = cancelled.
    public func answerPassphrase(_ passphrase: String?, remember: Bool = true) {
        passphraseRequest = nil
        let c = pending
        pending = nil
        c?.resume(returning: passphrase.map { ($0, remember) })
    }

    private func askPassphrase(_ reason: String, first: Bool) async -> (String, Bool)? {
        pending?.resume(returning: nil)
        return await withCheckedContinuation { c in
            pending = c
            passphraseRequest = PassphraseRequest(reason: reason, firstActivation: first,
                                                  biometricLabel: OwnerPresence.label)
        }
    }

    /// The implementation of `OwnerGate.confirm`.
    public func confirm(_ need: OwnerGate.Need, reason: String) async -> Bool {
        working = true
        defer { working = false }
        lastError = nil
        let vault = need != .stepUp
        let biometricsReady = OwnerPresence.available != .none
        do {
            if !biometricsReady {
                guard let (p, _) = await askPassphrase(reason, first: false) else { return false }
                _ = try await confirmation.confirmWithPassphrase(p, unlockVault: vault)
                return true
            }
            if deviceHasVaultKey == nil { await refreshAssurance() }
            var passphrase: String?
            var remember = true
            if vault, deviceHasVaultKey == false, await vaultIsLocked() {
                guard let (p, r) = await askPassphrase(reason, first: true) else { return false }
                passphrase = p
                remember = r
            }
            var out = try await confirmation.confirm(vault ? (need == .vaultReveal ? .vaultReveal : .vaultUnlock) : .admin,
                                                     unlockVault: vault, enroll: remember, passphrase: passphrase)
            deviceHasVaultKey = out.deviceKeyEnrolled
            if vault && out.vaultUnlockNeeded {
                // the device key was missing or no longer valid: the passphrase once, then Face ID only again
                guard let (p, r) = await askPassphrase(reason, first: true) else { return false }
                out = try await confirmation.confirm(.vaultUnlock, unlockVault: true, enroll: r, passphrase: p)
                deviceHasVaultKey = out.deviceKeyEnrolled
                if out.vaultUnlockNeeded { lastError = String(localized: "Could not unlock the vault."); return false }
            }
            return true
        } catch DeviceKeys.KeyError.cancelled {
            return false
        } catch let e as APIError {
            lastError = e.message
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func vaultIsLocked() async -> Bool {
        (try? await api.vaultStatus().locked) ?? true
    }
}
