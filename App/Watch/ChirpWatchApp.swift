import SwiftUI
import UserNotifications
import WatchKit

@main
struct ChirpWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTalkView().environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.fetchRelay() }
        }
    }
}

/// Registers for iCloud relay notifications so a standalone watch hears about new messages.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        if CloudRelay.isRelayNotification(userInfo) { WatchEngine.shared.fetchRelay() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { completionHandler(.newData) }
    }
}
