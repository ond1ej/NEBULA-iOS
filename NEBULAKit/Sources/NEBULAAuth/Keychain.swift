import Foundation
import LocalAuthentication
import Security

/// Minimal, explicit Keychain access for NEBULA's few items. Everything is "ThisDeviceOnly": never synced to iCloud,
/// never restored to another device from a backup.
public enum Keychain {
    /// The Keychain service of every NEBULA item: the app's bundle identifier (`<prefix>.nebula`, the prefix comes from
    /// Config/Local.xcconfig), so forks and side-by-side builds never share items.
    public static let service = Bundle.main.bundleIdentifier ?? "nebula"

    public enum Protection: Sendable {
        /// Readable after the first unlock since boot (session token, device identity key blob, server profile).
        case afterFirstUnlock
        /// Readable only after Face ID / Touch ID / the device passcode (the confirm key, the vault secret).
        case userPresence
    }

    public struct KeychainError: Error, Sendable, Equatable {
        public let status: OSStatus
        public var isMissingEntitlement: Bool { status == errSecMissingEntitlement }
        public var isUserCancel: Bool { status == errSecUserCanceled }
        public var isAuthFailed: Bool { status == errSecAuthFailed || status == errSecInteractionNotAllowed }
    }

    /// macOS: the data-protection keychain needs a provisioned app (keychain-access-groups); a locally signed build
    /// falls back to the login keychain, where the app itself enforces Touch ID before using the protected items.
    public static let dataProtectionAvailable: Bool = {
        #if os(macOS)
        let probe = "nebula.probe.\(UUID().uuidString)"
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: probe, kSecValueData as String: Data([1]),
                                kSecUseDataProtectionKeychain as String: true]
        let st = SecItemAdd(q as CFDictionary, nil)
        q.removeValue(forKey: kSecValueData as String)
        SecItemDelete(q as CFDictionary)
        return st == errSecSuccess
        #else
        return true
        #endif
    }()

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if os(macOS)
        if dataProtectionAvailable { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    /// The access control for `.userPresence` items (nil when the platform cannot enforce it here).
    static func accessControl(_ p: Protection) -> SecAccessControl? {
        guard p == .userPresence, dataProtectionAvailable else { return nil }
        return SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
    }

    /// Stores (replaces) an item. Returns whether the OS enforces user presence for it.
    @discardableResult
    public static func set(_ data: Data, account: String, protection: Protection) throws -> Bool {
        delete(account)
        var q = base(account)
        q[kSecValueData as String] = data
        var enforced = false
        if protection == .userPresence, let ac = accessControl(.userPresence) {
            q[kSecAttrAccessControl as String] = ac
            enforced = true
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var st = SecItemAdd(q as CFDictionary, nil)
        if st != errSecSuccess && enforced {
            // e.g. no device passcode set: keep the item device-bound and let the app enforce LocalAuthentication
            q.removeValue(forKey: kSecAttrAccessControl as String)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            enforced = false
            st = SecItemAdd(q as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return enforced
    }

    /// Reads an item; `context` (already evaluated) lets a `.userPresence` item open without a second prompt.
    public static func get(_ account: String, context: LAContext? = nil, prompt: String? = nil) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        if context == nil, let prompt {
            let ctx = LAContext()
            ctx.localizedReason = prompt
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return out as? Data
    }

    public static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let st = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(st == errSecSuccess, "system random generator failed")
        return d
    }
}
