import Foundation
import NEBULACore
import NEBULANetwork
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Password Vault: metadata lists, protective actions and — one at a time, after a fresh confirmation — a
/// revealed value. Revealed values live only in memory for the visible sheet and are cleared on dismiss / background.
@MainActor
@Observable
public final class VaultStore {
    public private(set) var status: VaultStatus?
    public private(set) var entries: [VaultEntry] = []
    public private(set) var grants: [VaultGrant] = []
    public private(set) var audit: [VaultAuditRow] = []
    public private(set) var loading = false
    public var error: String?
    public var query = "" { didSet { scheduleSearch() } }

    let api: APIClient
    let gate: OwnerGate
    private var searchTask: Task<Void, Never>?

    public init(api: APIClient, hub: EventHub, gate: OwnerGate) {
        self.api = api
        self.gate = gate
        hub.on("vault.status.changed") { [weak self] _ in Task { await self?.loadStatus() } }
        hub.on("vault.access") { [weak self] ev in
            if ev.payload?["operation"]?.string?.hasPrefix("entry") == true { Task { await self?.loadEntries() } }
        }
    }

    public var locked: Bool { status?.locked ?? true }

    public func load() async {
        loading = true
        defer { loading = false }
        await loadStatus()
        await loadEntries()
    }

    public func loadStatus() async {
        do { status = try await api.vaultStatus(); error = nil } catch { self.error = message(error) }
    }

    public func loadEntries() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let list = try? await api.vaultEntries(query: q.isEmpty ? nil : q) { entries = list }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.loadEntries()
        }
    }

    public func loadGrants() async { grants = (try? await api.vaultGrants()) ?? grants }
    public func loadAudit() async { audit = (try? await api.vaultAudit(limit: 80)) ?? audit }

    /// Unlock with ONE confirmation (Face ID; the passphrase only the first time on this device).
    public func unlock() async {
        do {
            _ = try await gate.run(String(localized: "Unlock the vault")) {
                if (try await self.api.vaultStatus()).locked {
                    throw APIError(status: 409, code: "vault_locked", message: "")
                }
                return true
            }
            await load()
        } catch is CancellationError {
        } catch { self.error = message(error) }
    }

    public func lock() async {
        _ = try? await api.lockVault()
        await loadStatus()
    }

    public func detail(_ id: String) async throws -> VaultEntryDetail {
        try await gate.run(String(localized: "Show an account from the vault")) { try await self.api.vaultEntry(id) }
    }

    /// The plaintext of one field. Needs the owner (fresh) and a vault confirmation on this session — the gate asks
    /// for ONE Face ID that covers both.
    public func reveal(_ id: String, field: String = "password") async throws -> String {
        try await gate.run(String(localized: "Show password")) { try await self.api.reveal(id, field: field).value }
    }

    public func save(_ input: VaultEntryInput, id: String?) async throws {
        _ = try await gate.run(String(localized: "Save to the vault")) {
            if let id { return try await self.api.updateVaultEntry(id, input) }
            return try await self.api.addVaultEntry(input)
        }
        await loadEntries()
    }

    public func delete(_ id: String) async throws {
        _ = try await gate.run(String(localized: "Delete account from the vault")) { try await self.api.deleteVaultEntry(id) }
        entries.removeAll { $0.id == id }
    }

    public func revoke(grant id: String) async {
        do {
            _ = try await api.revokeGrant(id)
            await loadGrants()
        } catch { self.error = message(error) }
    }

    func message(_ e: any Error) -> String { (e as? APIError)?.message ?? e.localizedDescription }
}

/// Copies a secret and removes it from the clipboard after 60 s. iOS keeps it on this device (no Universal Clipboard);
/// macOS has no such option for NSPasteboard, so there it is only marked concealed/transient for clipboard managers and
/// Handoff may still offer it to the owner's other devices during those 60 s.
public enum SecretClipboard {
    public static let lifetime: TimeInterval = 60

    @MainActor
    public static func copy(_ secret: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)])
        #elseif os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(secret, forType: .string)
        // mark it as transient/concealed so clipboard managers skip it
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime))
            if pb.changeCount == count { pb.clearContents() }
        }
        #endif
    }
}
