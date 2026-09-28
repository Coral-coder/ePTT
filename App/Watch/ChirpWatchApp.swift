import SwiftUI

@main
struct ChirpWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchTalkView().environmentObject(model)
        }
    }
}
