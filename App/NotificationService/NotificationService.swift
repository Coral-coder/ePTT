import UserNotifications
import EPTTCore

/// Plays relayed voice messages while NXTPTT is suspended, without a push key.
///
/// iCloud sends a notification when a message lands in our relay mailbox. iOS runs this
/// extension before showing it: we fetch the record, open it with the keys the app shares with
/// us (RelayInbox), and attach the decoded audio as the notification's sound, so it plays on
/// its own. The app later skips messages we played here instead of playing them twice.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        // A call alert pushed straight from the other phone: decrypt it and use the four beeps.
        if let packet = APNsRequest.packet(fromPayload: request.content.userInfo) {
            var quiet = false
            if let sync = RelayInbox.loadSnapshot(), let alert = RelayInbox.callAlert(packets: [packet], with: sync) {
                quiet = RelayInbox.loadQuiet().holds(alert.sender)
                content.title = quiet ? "Call alert · Do Not Disturb" : "Call alert"
                content.body = "\(alert.name) is trying to reach you" + (alert.text.map { ": \($0)" } ?? "")
                content.threadIdentifier = "call-alert"
            }
            if quiet {
                content.sound = nil
            } else if let sound = RelayInbox.writeCallAlertSound() {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            }
            deliver()
            return
        }
        // From iCloud (a subscription) or pushed by the talker's phone (a relay notice).
        guard let record = CloudRelay.recordName(inNotification: request.content.userInfo)
                ?? APNsRequest.relayRecord(fromPayload: request.content.userInfo),
              let sync = RelayInbox.loadSnapshot(), let relay = CloudRelay() else {
            deliver()
            return
        }
        // Both announced the same message: only the first one plays it.
        if RelayInbox.heard().contains(where: { $0.record == record }) {
            content.sound = nil
            deliver()
            return
        }
        // NXTPTT itself is already playing it (a wake kept it running): stay quiet.
        if RelayInbox.wasPlayed(record: record) {
            content.sound = nil
            content.body = "Played in NXTPTT"
            deliver()
            return
        }
        // Main actor: iOS calls serviceExtensionTimeWillExpire on the main thread too.
        work = Task { @MainActor [weak self] in
            defer { self?.deliver() }
            guard let payload = try? await relay.fetch(recordName: record) else { return }
            // A call alert: the Nextel page, four beeps.
            if let alert = RelayInbox.callAlert(in: payload, with: sync) {
                let quiet = RelayInbox.loadQuiet().holds(alert.sender)
                content.title = quiet ? "Call alert · Do Not Disturb" : "Call alert"
                content.body = "\(alert.name) is trying to reach you" + (alert.text.map { ": \($0)" } ?? "")
                if quiet {
                    content.sound = nil
                } else if let sound = RelayInbox.writeCallAlertSound() {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                }
                RelayInbox.markHeard(.init(record: record, talker: alert.name, channel: alert.name, seconds: 0,
                                           sound: "call-alert.caf", date: Date(), logged: true))
                return
            }
            // Group QR codes: someone asking to join, or the group key arriving for us.
            if RelayInbox.containsJoinRequest(payload) {
                content.title = "NXTPTT"
                content.body = "Someone scanned your talk group code. Open NXTPTT to let them in."
                return
            }
            if let invite = RelayInbox.groupInvite(in: payload, with: sync) {
                content.title = "NXTPTT"
                content.body = "\(invite.from) added you to \(invite.group). Open NXTPTT to join."
                return
            }
            // Contact details after face-to-face pairing: say so quietly (the app applies them).
            if let name = RelayInbox.cardSender(in: payload, with: sync) {
                content.title = "NXTPTT"
                content.body = "Paired with \(name). Their details arrived."
                content.sound = nil
                return
            }
            guard let message = RelayInbox.open(payload, with: sync) else { return }
            // Do Not Disturb: keep it on this phone, silently, and take it out of the relay now.
            if RelayInbox.loadQuiet().holds(message.sender) {
                RelayInbox.hold(.init(id: record, date: Date(), talker: message.talker, channel: message.channel,
                                      seconds: message.seconds, source: .relay), audio: payload)
                RelayInbox.markHeard(.init(record: record, talker: message.talker, channel: message.channel,
                                           seconds: message.seconds, sound: "", date: Date()))
                await relay.delete(recordName: record)
                content.title = message.talker
                let length = String(format: "%.0f s", message.seconds.rounded(.up))
                content.body = "Held · \(message.channel == message.talker ? "voice message" : message.channel) · \(length) · Do Not Disturb"
                content.sound = nil
                content.threadIdentifier = "held"
                return
            }
            RelayInbox.saveLastReceived(.init(date: Date(), talker: message.talker, channel: message.channel,
                                              seconds: message.seconds, replayable: message.allowsReplay,
                                              source: .relay), audio: payload)
            RelayInbox.purgeOldSounds()
            guard let sound = RelayInbox.writeSound(message, name: record) else { return }
            content.title = message.talker
            let length = String(format: "%.0f s", message.seconds.rounded(.up))
            let clipped = message.seconds > RelayInbox.maxSoundSeconds ? " · first 30 s, tap for the rest" : ""
            content.body = message.channel == message.talker
                ? "Voice message · \(length)\(clipped)"
                : "\(message.channel) · \(length)\(clipped)"
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            content.threadIdentifier = message.channel
            content.userInfo["eptt.record"] = record
            RelayInbox.markHeard(.init(record: record, talker: message.talker, channel: message.channel,
                                       seconds: message.seconds, sound: sound, date: Date()))
        }
    }

    /// iOS is about to give up on us: show whatever we have (the plain "New voice message").
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        deliver()
    }

    private func deliver() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }
}
