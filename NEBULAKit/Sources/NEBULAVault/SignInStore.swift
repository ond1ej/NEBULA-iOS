import Foundation
import NEBULACore
import NEBULANetwork
import Observation

/// Smart Authentication requests from agents ("Teams needs your password"). The owner answers in NEBULA's form;
/// values go to NEBULA's isolated sign-in broker in one POST and are cleared from memory right after.
@MainActor
@Observable
public final class SignInStore {
    public private(set) var sessions: [SignInSession] = []
    public var error: String?
    public private(set) var submitting = false

    let api: APIClient
    let gate: OwnerGate
    private var refreshTask: Task<Void, Never>?

    public init(api: APIClient, hub: EventHub, gate: OwnerGate) {
        self.api = api
        self.gate = gate
        hub.on("auth.") { [weak self] ev in
            guard let self else { return }
            if let sid = ev.payload?["session_id"]?.string { Task { await self.refresh(sid) } } else { self.scheduleLoad() }
        }
    }

    /// Requests waiting for the owner, newest first.
    public var waiting: [SignInSession] { sessions.filter(\.needsOwner) }

    public func load() async {
        do {
            sessions = try await api.signInSessions(active: true).sorted { $0.updatedAt > $1.updatedAt }
            error = nil
        } catch { self.error = (error as? APIError)?.message }
    }

    private func scheduleLoad() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    public func refresh(_ id: String) async {
        guard let s = try? await api.signInSession(id) else { return }
        replace(s)
    }

    public func session(_ id: String) -> SignInSession? { sessions.first { $0.id == id } }

    private func replace(_ s: SignInSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        if s.isFinal {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.sessions.removeAll { $0.id == s.id && $0.isFinal }
            }
        }
    }

    /// One answer. A fresh owner confirmation (one Face ID) replaces the remote PIN; a locked vault is unlocked by
    /// the same confirmation when saving / using a saved account.
    public func submit(_ session: SignInSession, build: (inout SignInSubmit) -> Void) async -> Bool {
        guard let req = session.request else { return false }
        submitting = true
        defer { submitting = false }
        for attempt in 0..<3 {
            do {
                let tok = try await api.signInToken(session.id)
                guard tok.requestId == req.id else {
                    error = String(localized: "The page has changed in the meantime. Check the new step.")
                    await refresh(session.id)
                    return false
                }
                var body = SignInSubmit(requestId: tok.requestId, token: tok.token, action: "")
                build(&body)
                let out = try await api.submitSignIn(session.id, body)
                body.values = nil
                replace(out)
                error = nil
                return true
            } catch let e as APIError where attempt < 2 &&
                        ["pin_required", "pin_not_configured", "stepup_required"].contains(e.code) {
                guard await gate.confirm(.stepUp, String(localized: "Sign the agent in")) else { return false }
            } catch let e as APIError where attempt < 2 && e.code == "vault_locked" {
                guard await gate.confirm(.vault, String(localized: "Unlock the vault")) else { return false }
            } catch let e as APIError {
                error = e.message
                if ["stale", "request_closed", "fields_mismatch"].contains(e.code) { await refresh(session.id) }
                return false
            } catch {
                self.error = error.localizedDescription
                return false
            }
        }
        return false
    }

    public func cancel(_ session: SignInSession) async {
        do { replace(try await api.cancelSignIn(session.id)) } catch { self.error = (error as? APIError)?.message }
    }
}
