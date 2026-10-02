import Foundation
import WatchConnectivity
import EPTTCore

/// Phone side of the watch link: the watch is a remote hold-to-talk button and microphone.
final class WatchBridge: NSObject {
    weak var engine: PTTEngine?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var lastContext: [String: Any] = [:]
    private var lastSnapshot: EngineSnapshot?

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func update(_ snapshot: EngineSnapshot) {
        lastSnapshot = snapshot
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        let names = Dictionary(snapshot.contacts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let channels: [[String: String]] = snapshot.channels.map { channel in
            let name = channel.kind == .direct ? (channel.members.first.flatMap { names[$0] } ?? channel.name) : channel.name
            return ["id": channel.id.bytes.hex, "name": name]
        }
        var state = WatchProtocol.TalkState.idle
        var talker = ""
        switch snapshot.talk {
        case .idle: break
        case .transmitting: state = .transmitting
        case .receiving(_, let name): state = .receiving; talker = name
        }
        let context: [String: Any] = [
            WatchProtocol.channels: channels,
            WatchProtocol.selected: snapshot.settings.selectedChannel?.bytes.hex ?? "",
            WatchProtocol.state: state.rawValue,
            WatchProtocol.talker: talker,
            WatchProtocol.listening: snapshot.settings.playOnWatch,
            WatchProtocol.phoneClaim: snapshot.lastPhoneClaim?.timeIntervalSince1970 ?? 0,
        ]
        guard !NSDictionary(dictionary: context).isEqual(to: lastContext) else { return }
        lastContext = context
        try? session.updateApplicationContext(context)
        // Application context can lag; push talk state immediately when the watch app is open.
        if session.isReachable { session.sendMessage(context, replyHandler: nil, errorHandler: nil) }
    }

    /// Hands the watch what it needs to work on its own. Only the newest sync matters, so
    /// older queued ones are cancelled.
    func sendSync(_ data: Data) {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[WatchProtocol.sync] != nil {
            transfer.cancel()
        }
        session.transferUserInfo([WatchProtocol.sync: data])
    }

    /// "Standalone watch" turned off: the watch deletes what it holds. Pending syncs are dropped.
    func sendWipe() {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[WatchProtocol.sync] != nil {
            transfer.cancel()
        }
        session.transferUserInfo([WatchProtocol.wipe: true])
    }

    /// This phone took over: tell the watch now if it's reachable, and queue it otherwise.
    func sendPhoneClaim(_ date: Date) {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        let message = [WatchProtocol.phoneClaim: date.timeIntervalSince1970]
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    func sendAudio(_ pcm: Data) {
        guard let session, session.isReachable else { return }
        session.sendMessageData(Data([WatchProtocol.audioToWatch]) + pcm, replyHandler: nil, errorHandler: nil)
    }
}

extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { engine?.resyncWatch() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let engine, let raw = message[WatchProtocol.command] as? String,
              let command = WatchProtocol.Command(rawValue: raw) else { return }
        switch command {
        case .press:
            engine.pressTalkFromWatch()
        case .release:
            engine.releaseTalkFromWatch()
        case .select:
            if let hex = message[WatchProtocol.channelID] as? String, let bytes = Data(hex: hex),
               let id = try? ChannelID(bytes: bytes) {
                engine.select(id)
            }
        case .listenOnWatch:
            let enabled = message[WatchProtocol.enabled] as? Bool ?? false
            engine.updateSettings { $0.playOnWatch = enabled }
        case .claim:
            let at = message[WatchProtocol.claimedAt] as? Double ?? Date().timeIntervalSince1970
            engine.watchClaimed(at: Date(timeIntervalSince1970: at))
        case .handBack:
            engine.watchHandedBack()
        case .sync:
            DispatchQueue.main.async {
                self.lastContext = [:]
                if let snapshot = self.lastSnapshot { self.update(snapshot) }
            }
            engine.resyncWatch()
        }
    }

    /// The watch app's push token (queued by the watch with transferUserInfo).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let token = userInfo[WatchProtocol.watchToken] as? Data { engine?.setWatchToken(token) }
        if let at = userInfo[WatchProtocol.claimedAt] as? Double {
            engine?.watchClaimed(at: Date(timeIntervalSince1970: at))
        }
        if userInfo[WatchProtocol.handBack] != nil { engine?.watchHandedBack() }
        if let used = userInfo[WatchProtocol.usedOneTimeKeys] as? [Int] {
            engine?.oneTimeKeysUsedOnWatch(used.compactMap { UInt32(exactly: $0) })
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData.first == WatchProtocol.audioFromWatch else { return }
        engine?.injectWatchAudio(Data(messageData.dropFirst()))
    }
}
