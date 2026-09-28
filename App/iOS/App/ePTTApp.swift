import SwiftUI
import UIKit
import UserNotifications

@main
struct ePTTApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .onOpenURL { url in AppModel.shared.open(link: url.absoluteString) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { AppModel.shared.engine.resume() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Start before anything else: a PushToTalk wake may be what launched us.
        AppModel.shared.start()
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.engine.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("ePTT: remote notification registration failed: \(error.localizedDescription)")
    }

    /// Wake acknowledgements arrive as silent pushes carrying a HELLO (PROTOCOL.md §8.2).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        AppModel.shared.engine.handlePushPacket(userInfo)
        // Leave a few seconds for hole punching before iOS may suspend us again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { completionHandler(.newData) }
    }
}
