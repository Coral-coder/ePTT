import SwiftUI

@main
struct ePTTWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchTalkView().environmentObject(model)
        }
    }
}
