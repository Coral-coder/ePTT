import SwiftUI
import UIKit
import UserNotifications
import EPTTCore

@main
struct NXTPTTApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .onOpenURL { url in AppModel.shared.open(link: url.absoluteString) }
        }
        .onChange(of: scenePhase) { phase in
            AppModel.shared.engine.setForeground(phase == .active)
            if phase == .active { AppModel.shared.engine.resume() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NXAppearance.apply()
        // Start before anything else: a PushToTalk wake may be what launched us.
        AppModel.shared.start()
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.engine.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("NXTPTT: remote notification registration failed: \(error.localizedDescription)")
    }

    /// Wake acknowledgements arrive as silent pushes carrying a HELLO (PROTOCOL.md §8.2).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if CloudRelay.isRelayNotification(userInfo) {
            AppModel.shared.engine.noteRelayAlert()
            AppModel.shared.engine.fetchRelay(force: true)
        } else {
            AppModel.shared.engine.handlePushPacket(userInfo)
        }
        // Leave a few seconds for hole punching before iOS may suspend us again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { completionHandler(.newData) }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// In the foreground a relayed message just plays; no banner needed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if CloudRelay.isRelayNotification(userInfo) {
            AppModel.shared.engine.noteRelayAlert()
            // The extension may already have turned it into a sound; on screen, play it live instead.
            if let record = CloudRelay.recordName(inNotification: userInfo) {
                AppModel.shared.engine.claimRelayed(record: record)
            } else {
                AppModel.shared.engine.fetchRelay(force: true)
            }
            completionHandler([])
        } else if APNsRequest.packet(fromPayload: userInfo) != nil {
            // A call alert push while on screen: the app shows its own banner; keep the sound.
            AppModel.shared.engine.handlePushPacket(userInfo)
            completionHandler([.sound, .list])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Tapping a voice message plays it in full (a notification sound stops at 30 s).
        if let record = CloudRelay.recordName(inNotification: response.notification.request.content.userInfo) {
            AppModel.shared.engine.replayRelayed(record: record)
        } else {
            AppModel.shared.engine.fetchRelay(force: true)
        }
        completionHandler()
    }
}
