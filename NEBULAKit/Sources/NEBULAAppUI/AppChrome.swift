import LocalAuthentication
import NEBULAAuth
import NEBULACore
import NEBULADesignSystem
import NEBULADesktop
import SwiftUI

/// Optional app lock (Settings → "Require Face ID when opening"): the content is covered until the owner
/// authenticates; it locks again when the app goes to the background.
public struct AppLockModifier: ViewModifier {
    @AppStorage("nebula.appLock") private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var evaluating = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && !unlocked {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                        VStack(spacing: NSpace.l) {
                            Image(systemName: OwnerPresence.symbol).font(.system(size: 48)).foregroundStyle(NColor.accent)
                            Text("NEBULA is locked").font(.headline)
                            Button("Unlock") { Task { await unlock() } }.buttonStyle(.borderedProminent)
                        }
                    }
                    .transition(.opacity)
                    .task { await unlock() }
                }
            }
            .onChange(of: scenePhase) { _, p in if p == .background { unlocked = false } }
    }

    private func unlock() async {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        if (try? await OwnerPresence.evaluate(reason: String(localized: "Unlock NEBULA"))) != nil {
            withAnimation(NMotion.smooth) { unlocked = true }
        }
    }
}

public extension View {
    func nebulaAppLock() -> some View { modifier(AppLockModifier()) }
}

/// The Mac's separate Live Desktop window (one per agent, resizable, full screen capable).
public struct DesktopWindowView: View {
    let model: AppModel
    let agentID: String?
    @Environment(\.dismissWindow) private var dismissWindow

    public init(model: AppModel, agentID: String?) { self.model = model; self.agentID = agentID }

    public var body: some View {
        if let services = model.services, let agentID {
            LiveDesktopScreen(agentID: agentID, backend: services.liveBackend()) { dismissWindow(id: "desktop", value: agentID) }
                .navigationTitle(services.agents.agents.first { $0.id == agentID }?.name ?? String(localized: "Live Desktop"))
        } else {
            ContentUnavailableView("NEBULA is not connected", systemImage: "display.trianglebadge.exclamationmark")
        }
    }
}

/// APNs registration hand-off: the app delegate passes the token here; it is stored on the server for this device only.
/// Remote pushes additionally need the owner's APNs key on the server (see docs/building.md#push-notifications).
public enum PushRegistration {
    @MainActor
    public static func didRegister(token: Data, model: AppModel) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let env = "development"
        #else
        let env = "production"
        #endif
        Task { _ = try? await model.services?.api.setPushToken(hex, env: env) }
    }
}
