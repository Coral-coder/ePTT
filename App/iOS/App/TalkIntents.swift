import AppIntents

// The Action Button (and Siri) can only send a single press, not a hold, so these intents
// latch: press once to key up, press again to unkey. A latched transmission unkeys itself
// after `AppModel.latchLimit` so a forgotten press can't hold the floor.
//
// They open the app because PushToTalk only lets an app begin transmitting from the
// foreground (or from a Bluetooth accessory).

struct ToggleTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Push to Talk"
    static var description = IntentDescription("Keys up on the selected NXTPTT channel, or unkeys if you're already talking.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.start()
        AppModel.shared.toggleLatchedTalk()
        return .result()
    }
}

struct StartTalkingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Talking"
    static var description = IntentDescription("Keys up on the selected NXTPTT channel.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.start()
        AppModel.shared.setLatchedTalk(true)
        return .result()
    }
}

struct StopTalkingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Talking"
    static var description = IntentDescription("Unkeys NXTPTT.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.setLatchedTalk(false)
        return .result()
    }
}

struct NXTPTTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTalkIntent(), phrases: [
            "Push to talk on \(.applicationName)",
            "Talk on \(.applicationName)",
            "Chirp with \(.applicationName)",
        ])
        AppShortcut(intent: StopTalkingIntent(), phrases: [
            "Stop talking on \(.applicationName)",
        ])
    }
}
