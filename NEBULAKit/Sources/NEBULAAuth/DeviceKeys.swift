import CryptoKit
import Foundation
import LocalAuthentication
import NEBULACore

/// The two device keys and the vault secret of a paired NEBULA app. Private keys never leave the device:
/// in the Secure Enclave where available (iPhone; Mac with a provisioned build), otherwise in this device's Keychain.
///
/// * identity key — signs session challenges; no user interaction (so the app can reconnect silently).
/// * confirm key  — signs owner confirmations; usable only after Face ID / Touch ID / the device passcode.
/// * vault secret — 32 random bytes released by the SAME biometric prompt; NEBULA derives the key that unwraps the
///   vault for this device from it (the server never stores it).
public final class DeviceKeys: @unchecked Sendable {
    public enum Protection: String, Sendable { case secureEnclave = "secure_enclave", keychain = "keychain" }

    public enum KeyError: Error, LocalizedError, Sendable {
        case missing
        case cancelled
        case biometryUnavailable(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .missing: return String(localized: "The device keys are missing. Pair this device again.")
            case .cancelled: return String(localized: "Verification was cancelled.")
            case .biometryUnavailable(let s): return s
            case .failed(let s): return s
            }
        }
    }

    static let identityAccount = "device.identity"
    static let confirmAccount = "device.confirm"
    static let secretAccount = "device.vault-secret"
    static let protectionAccount = "device.protection"

    private let lock = NSLock()

    public init() {}

    public var exists: Bool { (try? Keychain.get(Self.identityAccount)) != nil }

    /// Whether new device keys would be created in the Secure Enclave (needs the hardware and a provisioned keychain;
    /// simulators and locally signed Mac builds fall back to the keychain).
    public static var secureEnclaveInUse: Bool { SecureEnclave.isAvailable && Keychain.dataProtectionAvailable }

    public var protection: Protection {
        if let d = try? Keychain.get(Self.protectionAccount), let s = String(data: d, encoding: .utf8),
           let p = Protection(rawValue: s) { return p }
        return .keychain
    }

    /// Creates new keys (pairing). Old keys are destroyed first.
    public func create() throws -> (identity: String, confirm: String, protection: Protection) {
        lock.lock(); defer { lock.unlock() }
        destroy()
        let useSE = Self.secureEnclaveInUse
        if useSE {
            do {
                let idAC = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, nil)!
                let cfAC = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], nil)!
                let id = try SecureEnclave.P256.Signing.PrivateKey(accessControl: idAC)
                let cf = try SecureEnclave.P256.Signing.PrivateKey(accessControl: cfAC)
                try Keychain.set(id.dataRepresentation, account: Self.identityAccount, protection: .afterFirstUnlock)
                try Keychain.set(cf.dataRepresentation, account: Self.confirmAccount, protection: .afterFirstUnlock)
                try Keychain.set(Keychain.randomBytes(32), account: Self.secretAccount, protection: .userPresence)
                try Keychain.set(Data(Protection.secureEnclave.rawValue.utf8), account: Self.protectionAccount,
                                 protection: .afterFirstUnlock)
                return (id.publicKey.x963Representation.base64EncodedString(),
                        cf.publicKey.x963Representation.base64EncodedString(), .secureEnclave)
            } catch {
                NLog.auth.notice("secure enclave keys unavailable, using keychain keys")
                destroy()
            }
        }
        let id = P256.Signing.PrivateKey()
        let cf = P256.Signing.PrivateKey()
        try Keychain.set(id.rawRepresentation, account: Self.identityAccount, protection: .afterFirstUnlock)
        let enforced = try Keychain.set(cf.rawRepresentation, account: Self.confirmAccount, protection: .userPresence)
        try Keychain.set(Keychain.randomBytes(32), account: Self.secretAccount, protection: .userPresence)
        try Keychain.set(Data(Protection.keychain.rawValue.utf8), account: Self.protectionAccount,
                         protection: .afterFirstUnlock)
        if !enforced { NLog.auth.notice("confirm key protected by the app (LocalAuthentication), not the keychain ACL") }
        return (id.publicKey.x963Representation.base64EncodedString(),
                cf.publicKey.x963Representation.base64EncodedString(), .keychain)
    }

    public func destroy() {
        for a in [Self.identityAccount, Self.confirmAccount, Self.secretAccount, Self.protectionAccount] {
            Keychain.delete(a)
        }
    }

    /// Signs with the identity key (no prompt).
    public func signWithIdentity(_ payload: Data) throws -> String {
        guard let blob = try Keychain.get(Self.identityAccount) else { throw KeyError.missing }
        if protection == .secureEnclave {
            let k = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            return try k.signature(for: payload).derRepresentation.base64EncodedString()
        }
        let k = try P256.Signing.PrivateKey(rawRepresentation: blob)
        return try k.signature(for: payload).derRepresentation.base64EncodedString()
    }

    /// Signs with the confirm key and (optionally) reads the vault secret, both with ONE already evaluated context.
    public func confirm(_ payloadFor: (Data?) -> Data, withSecret: Bool, context: LAContext) throws
        -> (signature: String, secret: Data?) {
        var secret: Data?
        if withSecret {
            secret = try mapped { try Keychain.get(Self.secretAccount, context: context) }
            if secret == nil { throw KeyError.missing }
        }
        let payload = payloadFor(secret)
        guard let blob = try mapped({ try Keychain.get(Self.confirmAccount, context: context) }) else {
            throw KeyError.missing
        }
        let sig: String
        if protection == .secureEnclave {
            let k = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            sig = try k.signature(for: payload).derRepresentation.base64EncodedString()
        } else {
            let k = try P256.Signing.PrivateKey(rawRepresentation: blob)
            sig = try k.signature(for: payload).derRepresentation.base64EncodedString()
        }
        return (sig, secret)
    }

    private func mapped<T>(_ f: () throws -> T) throws -> T {
        do { return try f() } catch let e as Keychain.KeychainError {
            if e.isUserCancel { throw KeyError.cancelled }
            throw KeyError.failed(String(localized: "The Keychain denied access (\(e.status))."))
        }
    }

    public static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

/// One system authentication prompt (Face ID / Touch ID with the device passcode as the single fallback).
public enum OwnerPresence {
    public enum Kind: Sendable { case faceID, touchID, opticID, passcode, none }

    public static var available: Kind {
        let ctx = LAContext()
        var err: NSError?
        let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        if bio {
            switch ctx.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: break
            }
        }
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? .passcode : .none
    }

    public static var label: String {
        switch available {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .passcode: return String(localized: "device passcode")
        case .none: return String(localized: "verification")
        }
    }

    public static var symbol: String {
        switch available {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.shield"
        }
    }

    /// Evaluates once and returns the context to reuse for the protected keychain items.
    public static func evaluate(reason: String) async throws -> LAContext {
        #if DEBUG
        // UI tests on a Mac without Touch ID (no biometric hardware to simulate): DEBUG builds only. Release builds
        // always evaluate. The iPhone simulator tests use the simulator's real (simulated) Face ID instead.
        if ProcessInfo.processInfo.arguments.contains("-NEBULAUITestSkipPresence") { return LAContext() }
        #endif
        let ctx = LAContext()
        ctx.localizedCancelTitle = String(localized: "Cancel")
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw DeviceKeys.KeyError.biometryUnavailable(
                String(localized: "No Face ID, Touch ID or passcode is set up on this device. Set a device passcode."))
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: throw DeviceKeys.KeyError.cancelled
            default: throw DeviceKeys.KeyError.failed(String(localized: "Verification failed."))
            }
        }
        return ctx
    }
}
