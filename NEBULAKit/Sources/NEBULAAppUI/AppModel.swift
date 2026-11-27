import Foundation
import NEBULAAgents
import NEBULAAuth
import NEBULAChat
import NEBULACore
import NEBULADesktop
import NEBULANetwork
import NEBULASystem
import NEBULAVault
import Observation
import SwiftUI

/// The app's root state: pairing → waiting for the owner's approval → connected (stores, live events).
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case launching
        case unpaired
        case pendingApproval(code: String?)
        case ready
        case revoked
        case serverMismatch
    }

    public enum Connection: Equatable {
        case connecting, live, offline(String), reconnecting
    }

    public private(set) var phase: Phase = .launching
    public private(set) var connection: Connection = .connecting
    public private(set) var profile: ServerProfile?
    public private(set) var services: Services?
    public var pairingError: String?
    public var pairingBusy = false
    public var deepLinkSignIn: String?
    public var appVersion: String

    let keys = DeviceKeys()
    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var netTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var online = true

    /// Everything that needs a paired server. Created once per pairing.
    @MainActor
    public final class Services {
        public let api: APIClient
        public let session: SessionManager
        public let events: EventStream
        public let hub = EventHub()
        public let gate = OwnerGate()
        public let confirm: OwnerConfirmController
        public let chats: ChatListStore
        public let agents: AgentsStore
        public let vault: VaultStore
        public let signIns: SignInStore
        public let system: SystemStore
        public let notifications: NotificationCenterStore
        public let deviceID: String
        private var conversationStores: [String: ConversationStore] = [:]

        init(profile: ServerProfile, keys: DeviceKeys, appVersion: String) {
            session = SessionManager(profile: profile, keys: keys, appVersion: appVersion)
            api = APIClient(baseURL: profile.gatewayURL, tokens: session)
            events = EventStream(client: api)
            deviceID = profile.deviceID
            confirm = OwnerConfirmController(
                confirmation: OwnerConfirmation(api: api, session: session, keys: keys, deviceID: profile.deviceID),
                api: api)
            chats = ChatListStore(api: api, hub: hub)
            agents = AgentsStore(api: api, hub: hub, gate: gate)
            vault = VaultStore(api: api, hub: hub, gate: gate)
            signIns = SignInStore(api: api, hub: hub, gate: gate)
            system = SystemStore(api: api, hub: hub, gate: gate)
            notifications = NotificationCenterStore(api: api, hub: hub)
            let confirm = confirm
            gate.confirm = { need, reason in await confirm.confirm(need, reason: reason) }
        }

        /// One store per open conversation (kept while it is open; discarded when the list forgets it).
        public func conversation(_ id: String) -> ConversationStore {
            if let s = conversationStores[id] { return s }
            let s = ConversationStore(conversationID: id, api: api, hub: hub)
            conversationStores[id] = s
            return s
        }

        public func closeConversation(_ id: String) {
            conversationStores.removeValue(forKey: id)?.close()
        }

        public func liveBackend() -> any LiveDesktopBackend { APILiveBackend(api: api, session: session) }
    }

    public init(appVersion: String) {
        self.appVersion = appVersion
    }

    // MARK: lifecycle

    public func start() {
        guard phase == .launching else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NEBULAUITestReset") {  // UI tests start unpaired
            keys.destroy()
            ServerProfile.clear()
            Keychain.delete("session.token")
        }
        #endif
        guard let p = ServerProfile.load(), keys.exists else {
            phase = .unpaired
            #if DEBUG
            // automated smoke tests on a Mac without UI automation: pair from a launch argument (DEBUG builds only)
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-NEBULAPairLink"), i + 1 < args.count {
                let link = args[i + 1]
                Task { await pair(link: link, deviceName: "Mac – automated test") }
            }
            #endif
            return
        }
        profile = p
        connect(p)
    }

    private func connect(_ p: ServerProfile) {
        let s = Services(profile: p, keys: keys, appVersion: appVersion)
        services = s
        Task { await establish(s, profile: p) }
    }

    private func establish(_ s: Services, profile p: ServerProfile) async {
        connection = .connecting
        do {
            _ = try await s.session.sessionToken(forceRefresh: false)
            if !p.approved {
                var q = p
                q.approved = true
                try? q.save()
                profile = q
            }
            phase = .ready
            startStreaming(s)
            Task { await s.confirm.refreshAssurance() }
        } catch let e as SessionManager.SessionError {
            switch e.state {
            case .pendingApproval(let code):
                phase = .pendingApproval(code: code)
                waitForApproval(s, profile: p)
            case .revoked: phase = .revoked
            case .serverMismatch: phase = .serverMismatch
            default: phase = .ready
            }
        } catch let e as APIError {
            // offline at launch: show the app with cached state (nothing sensitive is cached) and retry
            phase = p.approved ? .ready : .pendingApproval(code: nil)
            connection = .offline(e.message)
            if p.approved { startStreaming(s) } else { waitForApproval(s, profile: p) }
        } catch {
            phase = .ready
            connection = .offline(error.localizedDescription)
        }
    }

    private func waitForApproval(_ s: Services, profile p: ServerProfile) {
        approvalTask?.cancel()
        approvalTask = Task { [weak self] in
            let end = Date().addingTimeInterval(15 * 60)
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                do {
                    _ = try await s.session.sessionToken(forceRefresh: true)
                    var q = p
                    q.approved = true
                    try? q.save()
                    self.profile = q
                    self.phase = .ready
                    self.startStreaming(s)
                    return
                } catch let e as SessionManager.SessionError {
                    switch e.state {
                    case .pendingApproval(let code): self.phase = .pendingApproval(code: code)
                    case .revoked: self.phase = .revoked; return
                    case .serverMismatch: self.phase = .serverMismatch; return
                    default: break
                    }
                } catch {}
            }
        }
    }

    private func startStreaming(_ s: Services) {
        eventTask?.cancel()
        statusTask?.cancel()
        let events = s.events
        eventTask = Task { [weak self] in
            let stream = await events.events()
            await events.start()
            for await ev in stream {
                guard let self else { return }
                if ev.type == "app.device.changed", ev.payload?["device_id"]?.string == s.deviceID,
                   ["revoked", "rejected"].contains(ev.payload?["status"]?.string ?? "") {
                    self.phase = .revoked
                }
                s.hub.dispatch(ev)
            }
        }
        statusTask = Task { [weak self] in
            for await st in await events.statusUpdates() {
                guard let self else { return }
                switch st {
                case .live: self.connection = .live
                case .connecting: if self.connection != .live { self.connection = .connecting }
                case .waiting: self.connection = self.online ? .reconnecting
                    : .offline(String(localized: "No internet connection"))
                case .idle, .stopped: break
                }
            }
        }
        netTask?.cancel()
        netTask = Task { [weak self] in
            for await up in Connectivity().updates() {
                guard let self else { return }
                let was = self.online
                self.online = up
                if !up { self.connection = .offline(String(localized: "No internet connection")) }
                if up && !was { await events.reconnectNow() }
            }
        }
    }

    /// iOS cannot keep the event stream open in the background: stop it there, resume (with replay from the last
    /// sequence, so nothing is missed or duplicated) when the app is active again.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        guard let s = services, self.phase == .ready else { return }
        switch phase {
        case .active:
            Task {
                await s.events.start()
                await s.chats.load(force: true)
                await s.signIns.load()
            }
        case .background:
            #if os(iOS)
            Task { await s.events.stop() }
            #endif
        default: break
        }
    }

    // MARK: pairing

    public func pair(link: String, deviceName: String) async {
        guard let offer = PairingOffer(link: link) else {
            pairingError = PairingError.invalidLink.errorDescription
            return
        }
        pairingBusy = true
        pairingError = nil
        defer { pairingBusy = false }
        do {
            #if os(iOS)
            let platform = "ios"
            #else
            let platform = "macos"
            #endif
            let claimed = try await PairingService(keys: keys).claim(offer, deviceName: deviceName, platform: platform,
                                                                     model: Self.modelIdentifier(), appVersion: appVersion)
            profile = claimed.profile
            phase = .pendingApproval(code: claimed.verificationCode)
            let s = Services(profile: claimed.profile, keys: keys, appVersion: appVersion)
            services = s
            waitForApproval(s, profile: claimed.profile)
        } catch DeviceKeys.KeyError.cancelled {
            pairingError = String(localized: "Pairing was cancelled.")
        } catch {
            pairingError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Forget the server on this device (keys destroyed, session ended). The owner can also revoke it on the Mac.
    public func unpair() async {
        approvalTask?.cancel()
        eventTask?.cancel()
        statusTask?.cancel()
        netTask?.cancel()
        if let s = services {
            await s.events.stop()
            await s.session.logout()
        }
        keys.destroy()
        ServerProfile.clear()
        services = nil
        profile = nil
        phase = .unpaired
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let raw = withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        }
        return String(raw.prefix(60))
    }
}

/// Live Desktop through NEBULA's API (single-use viewer token, gateway WebSocket).
struct APILiveBackend: LiveDesktopBackend {
    let api: APIClient
    let session: SessionManager

    func connect(agentID: String) async throws -> LiveConnectInfo {
        let c: LiveConnect
        do { c = try await api.liveConnect(agentID: agentID) } catch let e as APIError { throw Self.mapped(e) }
        let token = try await session.sessionToken(forceRefresh: false)
        var comps = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = c.wsPath
        comps.queryItems = [URLQueryItem(name: "session_token", value: token), URLQueryItem(name: "token", value: c.token)]
        guard let url = comps.url else { throw APIError(status: 0, code: "bad_url", message: "") }
        return LiveConnectInfo(sessionID: c.sessionId, webSocketURL: url, expiresAt: Date(timeIntervalSince1970: c.expiresAt))
    }

    func control(sessionID: String, action: LiveControlAction) async throws -> Bool {
        do { return try await api.liveControl(sessionID: sessionID, action: action.rawValue).control } catch let e as APIError {
            throw Self.mapped(e)
        }
    }

    static func mapped(_ e: APIError) -> LiveBackendError {
        if e.isOffline { return LiveBackendError(kind: .network, message: e.message) }
        if e.status == 401 { return LiveBackendError(kind: .unauthorized, message: e.message) }
        return LiveBackendError(code: e.code, message: e.message)
    }

    func disconnect(sessionID: String) async {
        _ = try? await api.liveDisconnect(sessionID: sessionID)
    }
}
