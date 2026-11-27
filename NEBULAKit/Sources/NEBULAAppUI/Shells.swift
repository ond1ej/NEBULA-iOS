import NEBULAAgents
import NEBULAAuth
import NEBULAChat
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import NEBULASystem
import NEBULAVault
import SwiftUI

#if os(iOS)
/// iPhone: Chats · Agents · Activity · Vault · Settings.
struct PhoneShell: View {
    @Bindable var model: AppModel
    let services: AppModel.Services
    let newChat: () -> Void
    let openSignIn: (String) -> Void
    let openDesktop: (String) -> Void

    enum TabID: Hashable { case chats, agents, activity, vault, settings }
    @State private var tab: TabID = .chats
    @State private var chatPath: [String] = []
    @State private var agentSelection: String?
    @State private var chatSelection: String?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                NavigationStack(path: $chatPath) {
                    ConversationListView(store: services.chats, selection: $chatSelection,
                                         avatarFor: { services.agents.avatar(for: $0) }, onNewChat: newChat)
                        .navigationTitle("Chats")
                        .navigationDestination(for: String.self) { id in conversation(id) }
                        .onChange(of: chatSelection) { _, id in
                            if let id { chatPath = [id]; chatSelection = nil }
                        }
                }
            }
            .badge(services.chats.unreadTotal)

            Tab("Agents", systemImage: "person.2.fill", value: .agents) {
                NavigationStack {
                    AgentsListView(store: services.agents, selection: $agentSelection)
                        .navigationTitle("Agents")
                        .navigationDestination(item: $agentSelection) { id in
                            AgentDetailView(store: services.agents, agentID: id,
                                            onOpenChat: { aid in openChat(agentID: aid) },
                                            onOpenDesktop: openDesktop)
                        }
                }
            }

            Tab("Activity", systemImage: "bell.badge.fill", value: .activity) {
                NavigationStack {
                    ActivityView(center: services.notifications, signIns: services.signIns, onOpenSignIn: openSignIn)
                        .navigationTitle("Activity")
                }
            }
            .badge(services.notifications.badgeCount + services.signIns.waiting.count)

            Tab("Vault", systemImage: "lock.shield.fill", value: .vault) {
                NavigationStack {
                    VaultView(store: services.vault).navigationTitle("Vault")
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView(model: model, services: services).navigationTitle("Settings")
                }
            }
        }
        .tabBarMinimizeBehaviorIfAvailable()
        .onReceive(NotificationCenter.default.publisher(for: .nebulaOpenConversation)) { n in
            if let id = n.object as? String { tab = .chats; chatPath = [id] }
        }
    }

    @ViewBuilder private func conversation(_ id: String) -> some View {
        let store = services.conversation(id)
        ConversationView(store: store, agentAvatar: store.agentID.flatMap { services.agents.avatar(for: $0) },
                         onOpenDesktop: openDesktop, onOpenSignIn: openSignIn)
            .navigationTitle(services.chats.conversations.first { $0.id == id }?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .onAppear { services.notifications.visibleAgentID = store.agentID; services.chats.markReadLocally(id) }
            .onDisappear {
                services.notifications.visibleAgentID = nil
                services.closeConversation(id)
            }
    }

    private func openChat(agentID: String) {
        Task {
            if let c = services.chats.conversations.first(where: { $0.agentId == agentID && $0.isDefault == true })
                ?? services.chats.conversations.first(where: { $0.agentId == agentID }) {
                tab = .chats
                chatPath = [c.id]
            } else if let c = try? await services.chats.newConversation(agentID: agentID) {
                tab = .chats
                chatPath = [c.id]
            }
        }
    }
}

extension View {
    @ViewBuilder func tabBarMinimizeBehaviorIfAvailable() -> some View {
        if #available(iOS 26.0, *) { self.tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
}
#endif

#if os(macOS)
/// Mac: a real desktop layout — sidebar (sections + conversations), the chat, an agent inspector.
struct MacShell: View {
    @Bindable var model: AppModel
    let services: AppModel.Services
    let newChat: () -> Void
    let openSignIn: (String) -> Void
    let openDesktop: (String) -> Void

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case chats, agents, activity, vault, system, settings
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .chats: "Chats"
            case .agents: "Agents"
            case .activity: "Activity"
            case .vault: "Vault"
            case .system: "System"
            case .settings: "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .chats: "bubble.left.and.bubble.right"
            case .agents: "person.2"
            case .activity: "bell.badge"
            case .vault: "lock.shield"
            case .system: "cpu"
            case .settings: "gearshape"
            }
        }
    }

    @State private var section: Section? = .chats
    @State private var conversation: String?
    @State private var agent: String?
    @State private var inspector = false
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                        .badge(badge(s))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { ServerFooter(model: model) }
        } content: {
            switch section ?? .chats {
            case .chats:
                ConversationListView(store: services.chats, selection: $conversation,
                                     avatarFor: { services.agents.avatar(for: $0) }, onNewChat: newChat)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            case .agents:
                AgentsListView(store: services.agents, selection: $agent)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            case .activity:
                ActivityView(center: services.notifications, signIns: services.signIns, onOpenSignIn: openSignIn)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            case .vault:
                VaultView(store: services.vault).navigationSplitViewColumnWidth(min: 320, ideal: 420)
            case .system:
                SystemStatusView(store: services.system).navigationSplitViewColumnWidth(min: 320, ideal: 420)
            case .settings:
                SettingsView(model: model, services: services).navigationSplitViewColumnWidth(min: 320, ideal: 420)
            }
        } detail: {
            detail
        }
        .inspector(isPresented: $inspector) {
            if let aid = currentAgentID {
                AgentDetailView(store: services.agents, agentID: aid, onOpenChat: { openChat($0) },
                                onOpenDesktop: { openWindow(id: "desktop", value: $0) })
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            } else {
                Text("Select a conversation or an agent").foregroundStyle(NColor.textSecondary)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let aid = currentAgentID {
                    Button { openWindow(id: "desktop", value: aid) } label: { Label("Live Desktop", systemImage: "display") }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .help("Open the agent's Live Desktop in a new window")
                }
                Button { inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nebulaOpenConversation)) { n in
            if let id = n.object as? String { section = .chats; conversation = id }
        }
    }

    private var currentAgentID: String? {
        if section == .agents { return agent }
        if let c = conversation { return services.chats.conversations.first { $0.id == c }?.agentId }
        return nil
    }

    @ViewBuilder private var detail: some View {
        if section == .agents, let a = agent {
            AgentDetailView(store: services.agents, agentID: a, onOpenChat: { openChat($0) },
                            onOpenDesktop: { openWindow(id: "desktop", value: $0) })
        } else if let id = conversation {
            let store = services.conversation(id)
            ConversationView(store: store, agentAvatar: store.agentID.flatMap { services.agents.avatar(for: $0) },
                             onOpenDesktop: { openWindow(id: "desktop", value: $0) }, onOpenSignIn: openSignIn)
                .id(id)
                .navigationTitle(services.chats.conversations.first { $0.id == id }?.title ?? "NEBULA")
                .navigationSubtitle(services.chats.conversations.first { $0.id == id }?.agentName ?? "")
                .onAppear { services.notifications.visibleAgentID = store.agentID }
        } else {
            EmptyStateView(symbol: "sparkles", title: "Select a conversation",
                           message: "Or start a new one with ⌘N.")
        }
    }

    private func badge(_ s: Section) -> Int {
        switch s {
        case .chats: services.chats.unreadTotal
        case .activity: services.notifications.badgeCount + services.signIns.waiting.count
        default: 0
        }
    }

    private func openChat(_ agentID: String) {
        Task {
            if let c = services.chats.conversations.first(where: { $0.agentId == agentID }) {
                section = .chats
                conversation = c.id
            } else if let c = try? await services.chats.newConversation(agentID: agentID) {
                section = .chats
                conversation = c.id
            }
        }
    }
}

struct ServerFooter: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: NSpace.s) {
            StatusDot(color: model.connection == .live ? NColor.success : NColor.warning, pulsing: model.connection != .live)
            Text(model.connection == .live ? "Mac mini connected" : "Connecting…").font(.caption)
                .foregroundStyle(NColor.textSecondary)
            Spacer()
        }
        .padding(NSpace.m)
    }
}
#endif

/// Settings: this device, Face ID for the vault, remote access, devices, system, about.
struct SettingsView: View {
    @Bindable var model: AppModel
    let services: AppModel.Services
    @AppStorage("nebula.appLock") private var appLock = false
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section("This device") {
                LabeledContent("Name", value: model.profile?.deviceName ?? "")
                LabeledContent("Server", value: model.profile?.gatewayURL.host() ?? "")
                LabeledContent("Key protection", value: DeviceKeys().protection == .secureEnclave ? "Secure Enclave" : String(localized: "Keychain"))
                LabeledContent("Vault unlock", value: services.confirm.deviceHasVaultKey == true
                               ? String(localized: "only \(OwnerPresence.label)") : String(localized: "only \(OwnerPresence.label) after the first activation"))
                Toggle("Require \(OwnerPresence.label) when opening", isOn: $appLock)
            }
            #if os(iOS)
            Section("System") {
                NavigationLink("Mac mini and VM status") { SystemStatusView(store: services.system).navigationTitle("System") }
                NavigationLink("Paired devices") {
                    DevicesView(store: services.system, currentDeviceID: services.deviceID,
                                onUnpairThisDevice: { confirmUnpair = true })
                        .navigationTitle("Devices")
                }
            }
            #else
            Section("Devices") {
                DevicesView(store: services.system, currentDeviceID: services.deviceID,
                            onUnpairThisDevice: { confirmUnpair = true })
                    .frame(minHeight: 200)
            }
            #endif
            Section {
                Button("Disconnect this device", role: .destructive) { confirmUnpair = true }
            } footer: {
                Text("This deletes the device keys. You can then pair it again on your Mac.")
            }
            Section("About") {
                LabeledContent("App", value: model.appVersion)
                LabeledContent("NEBULA server", value: services.system.serverVersion ?? "–")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Disconnect this device from NEBULA?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.unpair() } }
        }
    }
}
