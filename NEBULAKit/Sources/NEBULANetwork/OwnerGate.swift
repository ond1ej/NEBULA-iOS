import Foundation

/// Runs an owner action and, when NEBULA answers `stepup_required` (or the vault is locked for it), asks the owner to
/// confirm ONCE (Face ID / Touch ID — wired by the app shell to the unified owner confirmation) and retries.
/// Feature modules use it without depending on the authentication module.
@MainActor
public final class OwnerGate {
    public enum Need: Sendable { case stepUp, vault, vaultReveal }

    /// Set by the app shell. Returns false when the owner cancelled.
    public var confirm: @MainActor (_ need: Need, _ reason: String) async -> Bool = { _, _ in false }

    public init() {}

    public func run<T: Sendable>(_ reason: String, _ op: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let e as APIError where e.needsStepUp || e.vaultLocked || e.code == "reauth_required" {
            let need: Need = e.needsStepUp ? .stepUp : (e.code == "reauth_required" ? .vaultReveal : .vault)
            guard await confirm(need, reason) else { throw CancellationError() }
            return try await op()
        }
    }
}
