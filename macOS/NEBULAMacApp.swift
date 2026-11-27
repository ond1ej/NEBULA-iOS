import AppKit
import NEBULAAppUI
import SwiftUI
import UserNotifications

@main
struct NEBULAMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model = AppModel(appVersion: Bundle.main.nebulaVersion)

    var body: some Scene {
        WindowGroup("NEBULA", id: "main") {
            NebulaRootView(model: model)
                .nebulaAppLock()
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            InspectorCommands()
            ToolbarCommands()
            TextEditingCommands()
        }

        // one resizable, full-screen capable Live Desktop window per agent
        WindowGroup("Live Desktop", id: "desktop", for: String.self) { $agentID in
            DesktopWindowView(model: model, agentID: agentID)
                .frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 860)
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel? { didSet { Self.current = self } }
    private static weak var current: MacAppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let sid = response.notification.request.content.userInfo["sign_in"] as? String
        if let sid { await MainActor.run { MacAppDelegate.current?.model?.deepLinkSignIn = sid } }
    }
}

extension Bundle {
    var nebulaVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
