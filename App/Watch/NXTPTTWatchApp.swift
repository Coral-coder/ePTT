import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

@main
struct NXTPTTWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTalkView().environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            // Open: the watch takes over. Left (background): the iPhone takes back over. A lowered
            // wrist (inactive) changes nothing.
            if phase == .active {
                model.fetchRelay()
                model.setActive(true)
            } else if phase == .background {
                model.setActive(false)
            }
        }
    }
}

/// Registers for pushes so a standalone watch hears about relayed messages: contacts send this
/// watch a silent push (its token travels in our contact details) when they relay a message.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static let tokenKey = "watchPushToken"

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        UserDefaults.standard.set(deviceToken, forKey: Self.tokenKey)
        Self.sendTokenToPhone()
    }

    /// Hands the phone our push token (queued; delivered whenever the phone is around).
    static func sendTokenToPhone() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let token = UserDefaults.standard.data(forKey: tokenKey) else { return }
        WCSession.default.transferUserInfo([WatchProtocol.watchToken: token])
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        // A relayed message is waiting. If the iPhone is in charge and around, it plays there;
        // otherwise say so here.
        let watchInCharge = UserDefaults.standard.bool(forKey: WatchModel.primaryKey)
        let phoneAround = !watchInCharge && WCSession.isSupported() && WCSession.default.isReachable
        WatchEngine.shared.announceWaitingMessages(unlessPhoneAround: phoneAround) {
            completionHandler(.newData)
        }
    }
}
