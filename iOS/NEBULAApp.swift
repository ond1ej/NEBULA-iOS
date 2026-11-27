import NEBULAAppUI
import SwiftUI
import UIKit
import UserNotifications

@main
struct NEBULAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(appVersion: Bundle.main.nebulaVersion)

    var body: some Scene {
        WindowGroup {
            NebulaRootView(model: model)
                .nebulaAppLock()
                .onAppear { delegate.model = model }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()  // needs the Push capability; fails quietly without it
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in if let m = model { PushRegistration.didRegister(token: deviceToken, model: m) } }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}

    // banners for approvals / sign-ins also while the app is open
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let sid = response.notification.request.content.userInfo["sign_in"] as? String
        if let sid { await openSignIn(sid) }
    }

    @MainActor
    private func openSignIn(_ sid: String) {
        model?.deepLinkSignIn = sid
    }
}

extension Bundle {
    var nebulaVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
