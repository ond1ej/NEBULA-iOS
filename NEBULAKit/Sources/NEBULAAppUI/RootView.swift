import NEBULAAgents
import NEBULAAuth
import NEBULAChat
import NEBULACore
import NEBULADesignSystem
import NEBULADesktop
import NEBULANetwork
import NEBULASystem
import NEBULAVault
import SwiftUI

/// The app: welcome / pairing / waiting for approval, or the connected NEBULA.
public struct NebulaRootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(NColor.background)
            case .unpaired:
                WelcomeView(model: model)
            case .pendingApproval(let code):
                PendingApprovalView(code: code) { Task { await model.unpair() } }
            case .revoked:
                BlockedView(title: "This device was removed",
                            message: "This device is no longer paired with NEBULA. No NEBULA data is stored on it.",
                            symbol: "iphone.slash") { Task { await model.unpair() } }
            case .serverMismatch:
                BlockedView(title: "Server could not prove its identity",
                            message: "NEBULA on this connection does not have the key this device was paired with. For your security, I will not connect.",
                            symbol: "exclamationmark.shield") { Task { await model.unpair() } }
            case .ready:
                if let s = model.services {
                    ConnectedView(model: model, services: s)
                }
            }
        }
        .tint(NColor.accent)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, p in
            model.scenePhaseChanged(p)
            model.services?.notifications.appActive = p == .active
        }
    }
}

/// Navigation targets shared by both platforms.
enum Route: Hashable {
    case conversation(String)
    case agent(String)
    case signIn(String)
}

struct ConnectedView: View {
    @Bindable var model: AppModel
    let services: AppModel.Services
    @State private var signInSheet: SignInRoute?
    @State private var desktopAgent: DesktopRoute?
    @State private var newChat = false

    struct SignInRoute: Identifiable { let id: String }
    struct DesktopRoute: Identifiable { let id: String }

    var body: some View {
        content
            .sheet(item: Binding(get: { services.confirm.passphraseRequest }, set: { if $0 == nil { services.confirm.answerPassphrase(nil) } })) { req in
                PassphraseSheet(request: req) { p, remember in services.confirm.answerPassphrase(p, remember: remember) }
            }
            .sheet(item: $signInSheet) { r in
                NavigationStack {
                    SignInRequestView(store: services.signIns, sessionID: r.id) { agentID in
                        signInSheet = nil
                        desktopAgent = DesktopRoute(id: agentID)
                    }
                }
            }
            .sheet(isPresented: $newChat) {
                NavigationStack {
                    NewChatSheet(agents: services.agents) { agentID in
                        newChat = false
                        Task { await openNewConversation(agentID) }
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $desktopAgent) { d in
                LiveDesktopScreen(agentID: d.id, backend: services.liveBackend()) { desktopAgent = nil }
            }
            #else
            .sheet(item: $desktopAgent) { d in
                LiveDesktopScreen(agentID: d.id, backend: services.liveBackend()) { desktopAgent = nil }
                    .frame(minWidth: 900, minHeight: 600)
            }
            #endif
            .overlay(alignment: .top) { ConnectionBanner(connection: model.connection) }
            .onChange(of: services.signIns.waiting.first?.id) { _, id in
                // a new sign-in request: offer it right away (one tap away from Face ID)
                if let id, signInSheet == nil { signInSheet = SignInRoute(id: id); Haptics.warning() }
            }
            .onChange(of: model.deepLinkSignIn) { _, id in
                if let id { signInSheet = SignInRoute(id: id); model.deepLinkSignIn = nil }
            }
            .task {
                await NotificationCenterStore.requestPermission()
                await services.signIns.load()
            }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        PhoneShell(model: model, services: services, newChat: { newChat = true },
                   openSignIn: { signInSheet = SignInRoute(id: $0) },
                   openDesktop: { desktopAgent = DesktopRoute(id: $0) })
        #else
        MacShell(model: model, services: services, newChat: { newChat = true },
                 openSignIn: { signInSheet = SignInRoute(id: $0) },
                 openDesktop: { desktopAgent = DesktopRoute(id: $0) })
        #endif
    }

    private func openNewConversation(_ agentID: String) async {
        if let c = try? await services.chats.newConversation(agentID: agentID) {
            NotificationCenter.default.post(name: .nebulaOpenConversation, object: c.id)
        }
    }
}

extension Notification.Name {
    static let nebulaOpenConversation = Notification.Name("nebula.openConversation")
}

/// Connection state, unobtrusive: only shown when not live.
struct ConnectionBanner: View {
    let connection: AppModel.Connection
    var body: some View {
        Group {
            switch connection {
            case .live, .connecting: EmptyView()
            case .reconnecting:
                pill(String(localized: "Reconnecting…"), symbol: "arrow.triangle.2.circlepath", tint: NColor.warning)
            case .offline(let why):
                pill(why, symbol: "wifi.slash", tint: NColor.danger)
            }
        }
        .animation(NMotion.smooth, value: connection)
    }

    private func pill(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, NSpace.m).padding(.vertical, 6)
            .nGlass(cornerRadius: 16)
            .foregroundStyle(tint)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Pick an agent for a new conversation.
struct NewChatSheet: View {
    let agents: AgentsStore
    let onPick: (String) -> Void
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AgentsListView(store: agents, selection: $selection)
            .navigationTitle("New conversation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: selection) { _, id in if let id { onPick(id) } }
            .frame(minWidth: 360, minHeight: 420)
    }
}

/// Live Desktop full screen (iPhone) / sheet (Mac): view, take / release control, keyboard.
struct LiveDesktopScreen: View {
    let agentID: String
    let backend: any LiveDesktopBackend
    let onClose: () -> Void
    @State private var session: LiveDesktopSession?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    LiveDesktopView(session: session)
                } else {
                    ProgressView()
                }
            }
            .background(Color.black)
            .environment(\.colorScheme, .dark)  // overlays and banners stay readable on the black desktop frame
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await session?.disconnect() }
                        onClose()
                    }
                }
            }
        }
        .onAppear {
            if session == nil { session = LiveDesktopSession(agentID: agentID, backend: backend) }  // the view starts it
        }
        .onChange(of: scenePhase) { _, p in session?.handleScenePhase(p) }
        .onDisappear { Task { await session?.leave() } }
    }
}
