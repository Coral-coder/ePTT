import AVFoundation
import Foundation
import MultipeerConnectivity
import Network
import UIKit
import UserNotifications
import os
import EPTTCore

/// What the UI renders. Published to the main thread after every state change.
struct EngineSnapshot {
    enum Talk: Equatable {
        case idle
        case transmitting(ChannelID)
        case receiving(ChannelID, talker: String)
    }

    var contacts: [Contact] = []
    var channels: [Channel] = []
    var settings = Settings()
    var talk: Talk = .idle
    var onlinePeers: Set<IdentityID> = []
    var candidates: [Candidate] = []
    var pushToTalkAvailable = false
    var wakeAvailable = false
    var localIdentity: PublicIdentity?
    var transfers: [TransferRecord] = []
    var relayAvailable = false
    var relayAlerts = ""
    var lastWakeSent: String?
    /// Whether PushToTalk gave us a token that others can wake us with.
    var hasPushToken = false
    var lastWakeReceived: Date?
    var lastRelayAlert: Date?
    /// How the transmission being received reached us.
    var receivingRoute: Route?
    /// The path each connected contact is reachable on right now.
    var peerRoutes: [IdentityID: Route] = [:]
}

/// Where a peer was last heard: a UDP endpoint or a MultipeerConnectivity peer.
enum PeerPath: Hashable {
    case udp(NWEndpoint)
    case nearby(MCPeerID)
}

enum EngineEvent {
    case busy
    case preempted
    case callAlert(from: String, text: String?)
    case joinedGroup(String)
    case unreachable(String)
    case message(String)
    /// How the transmission we just finished was delivered, one leg per recipient.
    case delivery([TransferRecord.Leg])
}

/// The walkie-talkie itself: owns identity, contacts, channels, networking, audio and the
/// PushToTalk integration. All mutable state is confined to `queue`.
final class PTTEngine {
    static let maxBurstDuration: TimeInterval = 60   // like Nextel, a stuck key times out
    static let linkFreshness: TimeInterval = 30
    static let framesPerPacket = 3

    var onSnapshot: ((EngineSnapshot) -> Void)?
    var onEvent: ((EngineEvent) -> Void)?
    /// Decoded playback audio for the watch (mono Int16 16 kHz), when forwarding is enabled.
    var onWatchAudio: ((Data) -> Void)?
    /// Identity, contacts and keys for a standalone watch; called when they change.
    var onWatchSync: ((WatchSync) -> Void)?
    private var lastWatchSync: WatchSync?

    let queue = DispatchQueue(label: "app.eptt.engine", qos: .userInteractive)
    private let log = Logger(subsystem: "app.eptt", category: "engine")

    private let identity: LocalIdentity
    private var state: PersistedState
    /// Session prekeys for forward secrecy. A class so the packet processor can read the
    /// current store through a closure without capturing `self` during init.
    private final class PrekeyBox {
        var store = PrekeyKeychain.load()
        var signed: SignedPrekey?
    }
    private let prekeys = PrekeyBox()
    private var processor: PacketProcessor
    private let builder: PacketBuilder
    private var floor: FloorControl
    private let transport: UDPTransport
    /// Bluetooth + peer-to-peer Wi-Fi (MultipeerConnectivity) for phones with no network at all.
    private let nearby: NearbyTransport
    private let audio = AudioEngine()
    let ptt = PushToTalkManager()
    private var apns = APNsClient.fromBundle() ?? APNsClient.fromKeychain()
    private let relay = CloudRelay()
    /// Relayed bursts waiting to be played, oldest first (record name, sealed packets).
    private var relayQueue: [(record: String, packets: [Data])] = []
    private var relayRecordsSeen: Set<String> = []
    private var relayFetchInFlight = false
    private var relayRefetchPending = false
    /// Relay records this process queued for playback itself.
    private var relayPlayed: Set<String> = []
    private var isForeground = false
    private var lastInboxSnapshot: WatchSync?
    private var lastRelayFetch = Date.distantPast
    private var subscribedTags: [String] = []
    /// Whether iCloud will alert us to relayed messages (shown in Settings › Status).
    private var relayAlerts = "Not set up"
    private var lastRelayAlert: Date?
    private let bundlesPushKey = APNsClient.fromBundle() != nil

    // Derived lookups, rebuilt whenever contacts or channels change.
    private var contactsBySender: [SenderID: Int] = [:]
    private var channelIndex: [ChannelID: Int] = [:]

    private struct PeerLink {
        var endpoint: PeerPath
        var lastHeard: Date
    }
    private var links: [SenderID: PeerLink] = [:]

    private struct Transmission {
        let channel: Channel
        let burst: MessageID
        /// Random per-burst key; forgotten when the burst ends (forward secrecy).
        let burstKey: Data
        let startPacket: Data
        var backlog: BurstBacklog
        var pending: [Data] = []
        var nextFrameIndex: UInt32 = 0
        /// Members that have the backlog and now get live packets.
        var delivered: Set<SenderID> = []
        var woken: Set<SenderID> = []
        var lastStartResend = Date()
        let startedAt = Date()
    }
    private var tx: Transmission?
    /// Channel requested from our UI while we wait for PushToTalk to grant the transmission.
    private var pendingPress: ChannelID?

    private struct Reception {
        let channel: Channel
        let burst: MessageID
        let sender: SenderID
        let talker: String
        let route: Route
        var framesPlayed = 0
        var frameMilliseconds = 20
        var jitter = JitterBuffer()
        /// BURST_END arrived: play out what is buffered, then stop.
        var draining = false
    }
    private var rx: Reception?
    private var playoutTimer: DispatchSourceTimer?
    private var earlyVoice = ExpiringQueue<MessageID, (UInt32, [Data])>()
    /// Burst packets that arrived before their BURST_START could be opened.
    private var earlyPackets = ExpiringQueue<MessageID, (Data, PeerPath?)>()

    private var audioActive = false
    /// Set when a wake push was accepted; cleared when its burst arrives.
    private var pendingWake: (talker: String, deadline: Date)?
    private var housekeepingTimer: DispatchSourceTimer?
    private var lastKeepalive = Date.distantPast

    init() {
        identity = IdentityKeychain.loadOrCreate()
        state = Store.load()
        let box = prekeys
        processor = PacketProcessor(local: identity, agreement: identity.keyAgreement(prekeys: { box.store }))
        builder = PacketBuilder(local: identity)
        floor = FloorControl(localSender: identity.senderID)
        transport = UDPTransport(queue: queue)
        nearby = NearbyTransport(queue: queue)
        if state.settings.displayName.isEmpty {
            state.settings.displayName = UIDevice.current.name
        }
        if state.relayMailbox == nil {
            state.relayMailbox = .random(count: 16)
            Store.save(state)
        }
        rebuildIndexes()
        rotatePrekeysIfNeeded()
    }

    /// Creates, rotates and expires session prekeys (PROTOCOL.md §3.1). Returns true on change.
    @discardableResult
    private func rotatePrekeysIfNeeded() -> Bool {
        let changed = prekeys.store.rotateIfNeeded()
        if changed || prekeys.signed == nil {
            prekeys.signed = try? prekeys.store.current(signedBy: identity)
        }
        if changed {
            PrekeyKeychain.save(prekeys.store)
            if onWatchSync != nil { syncWatch() }
            syncInbox()
        }
        return changed
    }

    // MARK: - Lifecycle

    func start() {
        wirePushToTalk()
        queue.async { [self] in
            audio.onEncodedFrame = { [weak self] frame in
                self?.queue.async { self?.appendCapturedFrame(frame) }
            }
            audio.onPlaybackPCM16k = { [weak self] pcm in
                guard let self, self.state.settings.forwardAudioToWatch else { return }
                self.onWatchAudio?(pcm)
            }
            transport.onPacket = { [weak self] data, endpoint in self?.handleDatagram(data, from: .udp(endpoint)) }
            transport.onPeerDiscovered = { [weak self] endpoint in self?.helloEveryone(at: .udp(endpoint)) }
            nearby.onPacket = { [weak self] data, peer in self?.handleDatagram(data, from: .nearby(peer)) }
            nearby.onPeerConnected = { [weak self] peer in self?.helloEveryone(at: .nearby(peer)) }
            nearby.start()
            transport.onCandidatesChanged = { [weak self] _ in self?.announceReachability() }
            applyTransportSettings()
            transport.start()
            startHousekeeping()
            syncInbox()
            refreshRelaySubscription()
            fetchRelay()
            purgeExpiredRelayUploads()
            publish()
        }
        Task { await ptt.setUp(); queue.async { self.publish() } }
    }

    /// Called when the app returns to the foreground: sockets may have been torn down.
    func resume() {
        queue.async { [self] in
            transport.start()
            nearby.start()
            announceReachability()
            refreshRelaySubscription()   // mailbox tags rotate daily
            fetchRelay()
        }
    }

    private func startHousekeeping() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.housekeeping() }
        timer.resume()
        housekeepingTimer = timer
    }

    private func housekeeping() {
        let now = Date()
        apply(floor.tick(now: now))
        // Links go stale silently (nothing arrives), so re-check who is online on every tick;
        // otherwise the UI keeps showing a peer "on the grid" after the path has died.
        publishIfOnlineChanged()

        if var t = tx {
            if now.timeIntervalSince(t.lastStartResend) >= 0.5 {
                t.lastStartResend = now
                tx = t
                send(t.startPacket, to: t.delivered)
            }
            if now.timeIntervalSince(t.startedAt) > PTTEngine.maxBurstDuration { releaseTalk() }
        }

        if let wake = pendingWake {
            if now > wake.deadline {
                pendingWake = nil
                if rx == nil { ptt.setActiveRemoteParticipant(nil) }
                emit(.unreachable(wake.talker))
            } else if rx == nil, now.timeIntervalSince(lastRelayFetch) >= 2 {
                fetchRelay(force: true)   // woken but not connected: watch the relay
            }
        }

        if now.timeIntervalSince(lastKeepalive) >= 15 {
            lastKeepalive = now
            for (sender, link) in links where now.timeIntervalSince(link.lastHeard) < 120 {
                if let contact = self.contact(sender) { sendHello(to: contact, endpoints: [link.endpoint]) }
            }
            earlyVoice.expire(now: now)
            earlyPackets.expire(now: now)
            if rotatePrekeysIfNeeded() { announceReachability() }
            if now.timeIntervalSince(lastRelayFetch) >= 60 {
                fetchRelay()
                refreshRelaySubscription()
                purgeExpiredRelayUploads()
            }
            publishIfOnlineChanged()
        }
    }

    // MARK: - PushToTalk wiring

    private func wirePushToTalk() {
        ptt.onJoined = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.ptt.setDescriptorName(self.selectedChannel?.name ?? "NXTPTT")
                self.ptt.setServiceStatus(.ready)
                self.publish()
            }
        }
        ptt.onPushToken = { [weak self] token in
            self?.queue.async {
                guard let self, self.state.pttToken != token else { return }
                self.state.pttToken = token
                self.save()
                self.announceReachability()
            }
        }
        ptt.onBeginTransmitting = { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                let channel = self.pendingPress ?? self.state.settings.selectedChannel
                self.pendingPress = nil
                guard let channel, self.beginBurst(on: channel) else {
                    self.ptt.stopTransmitting()
                    return
                }
            }
        }
        ptt.onEndTransmitting = { [weak self] in self?.queue.async { self?.endBurst() } }
        ptt.onTransmitFailed = { [weak self] _ in self?.queue.async { self?.pendingPress = nil } }
        ptt.onAudioActivated = { [weak self] _ in self?.queue.async { self?.audioDidActivate() } }
        ptt.onAudioDeactivated = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.audioActive = false
                self.audio.stop()
            }
        }
        ptt.onIncomingPush = { [weak self] payload in
            guard let self else { return nil }
            return self.queue.sync { self.handleWakePush(payload) }
        }
    }

    private func audioDidActivate() {
        audioActive = true
        do {
            if !audio.isRunning { try audio.start() }
        } catch {
            log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Starting the engine enables voice processing, which can move output to the earpiece.
        AudioEngine.routeToSpeakerIfNeeded()
        if tx != nil {
            audio.play(.talkPermit)
            audio.startCapture()
        } else if rx != nil {
            playIncomingTone()
        }
    }

    /// Without PushToTalk (unavailable or not joined yet): run our own audio session for a burst.
    private func startManualAudio() {
        do {
            try AudioEngine.activateSessionManually()
            audioActive = true
            if !audio.isRunning { try audio.start() }
            AudioEngine.routeToSpeakerIfNeeded()
        } catch {
            log.error("Manual audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var usesPushToTalk: Bool { ptt.isAvailable && ptt.isJoined }

    // MARK: - Talking

    func pressTalk() {
        queue.async { [self] in
            guard let channel = state.settings.selectedChannel, channelIndex[channel] != nil else {
                emit(.message("Pick a channel first"))
                return
            }
            if usesPushToTalk {
                pendingPress = channel
                ptt.requestBeginTransmitting()   // continues in onBeginTransmitting
            } else if beginBurst(on: channel) {
                if !audioActive { startManualAudio() }
                audio.play(.talkPermit)
                audio.startCapture()
            }
        }
    }

    func releaseTalk() {
        queue.async { [self] in
            pendingPress = nil
            guard tx != nil else { return }
            if usesPushToTalk { ptt.stopTransmitting() } else { endBurst() }
        }
    }

    /// Returns false (after playing the busy tone) when the floor is not ours.
    private func beginBurst(on channelID: ChannelID) -> Bool {
        guard tx == nil else { return true }
        apply(floor.pressTalk(on: channelID))
        return tx != nil
    }

    private func startTransmission(channelID: ChannelID, burst: MessageID, timestamp: UInt64) {
        guard let channel = self.channel(channelID) else { return }
        do {
            // Seal a fresh burst key to each member's current prekey (or static key if unknown).
            let targets = channel.members.compactMap { self.contact(id: $0) }
                .map { SealTarget(identity: $0.identity, prekey: $0.reachability.prekey) }
            let outgoing = try OutgoingBurst(identity: identity, channelID: channel.id, burstID: burst,
                                             timestamp: timestamp, targets: targets,
                                             codec: audio.captureCodec.codec,
                                             sampleRate: audio.captureCodec.sampleRate,
                                             frameMilliseconds: audio.captureCodec.frameMilliseconds)
            let packet = try builder.seal(.burstStart, plaintext: outgoing.start.encoded, keys: channel.keys,
                                          messageID: burst)
            var t = Transmission(channel: channel, burst: burst, burstKey: outgoing.burstKey, startPacket: packet,
                                 backlog: BurstBacklog(burst: burst))
            t.backlog.append(packet)
            tx = t
            for member in channel.members {
                guard let contact = self.contact(id: member) else { continue }
                if isLinked(contact.senderID) {
                    deliverBacklog(to: contact.senderID)
                } else {
                    wake(contact, for: t)
                }
            }
            publish()
        } catch {
            log.error("Could not start burst: \(error.localizedDescription, privacy: .public)")
            _ = floor.releaseTalk()
        }
    }

    private func appendCapturedFrame(_ frame: Data) {
        guard var t = tx else { return }
        t.pending.append(frame)
        tx = t
        if t.pending.count >= PTTEngine.framesPerPacket { flushVoice() }
    }

    private func flushVoice() {
        guard var t = tx, !t.pending.isEmpty else { return }
        do {
            let packet = try builder.sealBurst(.voice, plaintext: VoiceBody.encode(t.pending), keys: t.channel.keys,
                                               burstID: t.burst, burstKey: t.burstKey, seq: t.nextFrameIndex)
            t.nextFrameIndex += UInt32(t.pending.count)
            t.pending.removeAll()
            t.backlog.append(packet)
            tx = t
            send(packet, to: t.delivered)
        } catch {
            log.error("Voice seal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endBurst() {
        guard tx != nil else { return }
        flushVoice()
        guard let t = tx else { return }
        audio.stopCapture()
        if floor.isTransmitting { _ = floor.releaseTalk() }
        tx = nil
        let end = BurstEnd(timestamp: currentTimestamp(), frameCount: t.nextFrameIndex)
        let endPacket = try? builder.sealBurst(.burstEnd, plaintext: end.encoded, keys: t.channel.keys,
                                               burstID: t.burst, burstKey: t.burstKey, seq: t.nextFrameIndex)
        if let endPacket {
            // Three copies 40 ms apart; receivers drop the duplicates.
            for i in 0..<3 {
                queue.asyncAfter(deadline: .now() + .milliseconds(40 * i)) { [weak self] in
                    self?.send(endPacket, to: t.delivered)
                }
            }
        }
        finishOutgoing(t, endPacket: endPacket)
        if !usesPushToTalk && rx == nil {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.tx == nil, self.rx == nil else { return }
                self.audio.stop()
                self.audioActive = false
            }
        }
        publish()
    }

    /// Sends the burst so far to a member who just became reachable, then keeps them live.
    private func deliverBacklog(to sender: SenderID) {
        guard var t = tx, !t.delivered.contains(sender),
              t.channel.members.contains(where: { $0.senderID == sender }) else { return }
        for packet in t.backlog.packets { send(packet, to: [sender]) }
        t.delivered.insert(sender)
        tx = t
    }

    private func wake(_ contact: Contact, for t: Transmission) {
        guard !t.woken.contains(contact.senderID) else { return }
        tx?.woken.insert(contact.senderID)
        // Their last known addresses may still work; a HELLO costs nothing.
        sendHello(to: contact, replyRequested: true, endpoints: [], candidates: contact.reachability.candidates)
        guard let apns else {
            noteWake(contact, "not sent: this build has no push key")
            return
        }
        guard contact.isWakeable else {
            noteWake(contact, "not sent: no push token from them yet (have them open NXTPTT once while you're connected)")
            return
        }
        let wake = Wake(name: state.settings.displayName, timestamp: currentTimestamp(),
                        candidates: transport.localCandidates)
        guard let packet = try? builder.seal(.wake, plaintext: wake.encoded, keys: t.channel.keys, messageID: t.burst) else { return }
        noteWake(contact, "sending…")
        apns.sendWake(packet, to: contact) { [weak self] failure in
            self?.queue.async {
                guard let self else { return }
                if let failure {
                    self.noteWake(contact, "failed: \(failure)")
                    self.emit(.message("Couldn't wake \(contact.name): \(failure)"))
                } else {
                    self.noteWake(contact, "accepted by Apple")
                }
            }
        }
    }

    /// What happened to the last wake we tried to send, per contact (Settings › Status, and the
    /// reason on a failed Activity entry).
    private var wakeOutcomes: [SenderID: String] = [:]
    private var lastWakeSent: String?
    private var lastWakeReceived: Date?

    private func noteWake(_ contact: Contact, _ outcome: String) {
        wakeOutcomes[contact.senderID] = outcome
        lastWakeSent = "\(contact.name): \(outcome)"
        publish()
    }

    // MARK: - Call alert

    func sendCallAlert(to contactID: IdentityID, text: String? = nil) {
        queue.async { [self] in
            guard let contact = self.contact(id: contactID), let channel = self.directChannel(for: contactID) else { return }
            let alert = CallAlert(name: state.settings.displayName, timestamp: currentTimestamp(), text: text)
            guard let packet = try? builder.seal(.callAlert, plaintext: alert.encoded, keys: channel.keys) else { return }
            if isLinked(contact.senderID) {
                send(packet, to: [contact.senderID])
            } else {
                sendToCandidates(packet, contact.reachability.candidates)
                emit(.message("\(contact.name) may be offline; the alert was sent to their last known address"))
            }
        }
    }

    // MARK: - Inbound

    /// Entry point for the silent background push that carries a wake acknowledgement.
    func handlePushPacket(_ payload: [AnyHashable: Any]) {
        guard let packet = APNsRequest.packet(fromPayload: payload) else { return }
        queue.async { self.handleDatagram(packet, from: nil) }
    }

    private func handleDatagram(_ data: Data, from endpoint: PeerPath?, relayed: Bool = false) {
        let inbound: InboundPacket
        do {
            inbound = try processor.process(
                data,
                maxAge: relayed ? Relay.lifetime : ReplayGuard.maxClockSkew,
                channelLookup: { [self] in channel($0) },
                memberLookup: { [self] in contact($0)?.identity }
            )
        } catch InboundError.unknownBurst {
            // VOICE overtook its BURST_START (or the start is still in flight): retry after it lands.
            if !relayed, let header = try? PacketHeader(packet: data) {
                earlyPackets.append((data, endpoint), for: header.messageID)
            }
            return
        } catch InboundError.replay {
            // Retransmitted BURST_START/END; still proof the peer is reachable here.
            if let endpoint, let header = try? PacketHeader(packet: data), contact(header.senderID) != nil {
                noteHeard(header.senderID, at: endpoint)
            }
            return
        } catch {
            log.debug("Dropped packet: \(String(describing: error), privacy: .public)")
            return
        }

        let sender = inbound.header.senderID
        if let endpoint { noteHeard(sender, at: endpoint) }

        switch inbound.message {
        case .hello(let hello):
            handleHello(hello, from: sender, endpoint: endpoint)
        case .burstStart(let start):
            defer {
                for (packet, from) in earlyPackets.take(inbound.header.messageID) { handleDatagram(packet, from: from) }
            }
            guard inbound.channel.isMonitored || inbound.channel.kind == .direct else { return }
            pendingBurstInfo[inbound.header.messageID] = start
            pendingRoutes[inbound.header.messageID] = relayed ? .relay : PTTEngine.route(for: endpoint)
            apply(floor.remoteBurstStarted(channel: inbound.channel.id, burst: inbound.header.messageID,
                                           sender: sender, timestamp: start.timestamp))
            floor.remoteActivity(channel: inbound.channel.id, burst: inbound.header.messageID)
        case .voice(let index, let frames):
            let burst = inbound.header.messageID
            if var r = rx, r.burst == burst, r.channel.id == inbound.channel.id {
                for (offset, frame) in frames.enumerated() { r.jitter.insert(index: index + UInt32(offset), frame: frame) }
                rx = r
                floor.remoteActivity(channel: r.channel.id, burst: burst)
            } else if !floor.isReceiving(burst: burst, on: inbound.channel.id) {
                earlyVoice.append((index, frames), for: burst)
            }
        case .burstEnd(let end):
            let burst = inbound.header.messageID
            guard var r = rx, r.burst == burst else { return }
            r.jitter.markEnded(frameCount: end.frameCount)
            r.draining = true
            rx = r
            apply(floor.remoteBurstEnded(channel: r.channel.id, burst: burst), draining: true)
        case .callAlert(let alert):
            audioOrNotify(.callAlert, title: "Call alert", body: "\(alert.name) is trying to reach you")
            emit(.callAlert(from: alert.name, text: alert.text))
        case .wake(let wake):
            if let contact = self.contact(sender) { respondToWake(wake, from: contact) }
        case .groupInvite(let invite):
            acceptInvite(invite, from: sender)
        case .groupLeave(let leave):
            if let i = channelIndex[leave.groupID], let contact = self.contact(sender) {
                state.channels[i].members.removeAll { $0 == contact.id }
                save()
            }
        }
    }

    /// BURST_START details by burst, needed when reception begins.
    private var pendingBurstInfo: [MessageID: BurstStart] = [:]
    private var pendingRoutes: [MessageID: Route] = [:]

    private func handleHello(_ hello: Hello, from sender: SenderID, endpoint: PeerPath?) {
        guard let i = contactsBySender[sender] else { return }
        if state.contacts[i].apply(hello: hello) { save() }
        let contact = state.contacts[i]
        if hello.wantsReply {
            // Over UDP we reply on the same path. A HELLO relayed by push has no path, so punch
            // towards every candidate it lists (PROTOCOL.md §8.2).
            sendHello(to: contact, replyRequested: endpoint == nil,
                      endpoints: endpoint.map { [$0] } ?? [],
                      candidates: endpoint == nil ? hello.reachability.candidates : [])
        }
    }

    private func noteHeard(_ sender: SenderID, at endpoint: PeerPath) {
        let wasLinked = isLinked(sender)
        links[sender] = PeerLink(endpoint: endpoint, lastHeard: Date())
        guard !wasLinked, let contact = self.contact(sender) else { return }
        deliverBacklog(to: sender)
        // Re-offer group invites: cheap, idempotent, and covers members who were offline.
        for channel in state.channels where channel.kind == .group && channel.members.contains(contact.id) {
            sendInvite(channel, to: contact)
        }
        publishIfOnlineChanged()
    }

    private func startReception(channelID: ChannelID, burst: MessageID, sender: SenderID) {
        stopReception(playEndTone: false)
        guard let channel = self.channel(channelID), let contact = self.contact(sender) else { return }
        let start = pendingBurstInfo.removeValue(forKey: burst)
        let route = pendingRoutes.removeValue(forKey: burst) ?? .internet
        pendingBurstInfo.removeAll()
        pendingRoutes.removeAll()
        let talker = channel.kind == .group ? "\(contact.name) · \(channel.name)" : contact.name
        var r = Reception(channel: channel, burst: burst, sender: sender, talker: talker, route: route)
        r.frameMilliseconds = Int(start?.frameMilliseconds ?? 20)
        for (index, frames) in earlyVoice.take(burst) {
            for (offset, frame) in frames.enumerated() { r.jitter.insert(index: index + UInt32(offset), frame: frame) }
        }
        rx = r
        pendingWake = nil
        audio.beginPlayback(codec: start?.codec ?? .opus, sampleRate: start?.sampleRate ?? 48_000,
                            frameMilliseconds: start?.frameMilliseconds ?? 20)
        if usesPushToTalk {
            ptt.setActiveRemoteParticipant(talker)   // iOS then activates audio → audioDidActivate
            // Already active (e.g. a wake is holding the session open): audioDidActivate won't
            // run again, so play the receive tone here.
            if audioActive { playIncomingTone() }
        } else {
            if !audioActive { startManualAudio() }
            playIncomingTone()
        }
        startPlayout()
        publish()
    }

    private func stopReception(playEndTone: Bool = true) {
        guard let finished = rx else { return }
        rx = nil
        processor.forgetBurst(sender: finished.sender, burst: finished.burst)
        if finished.framesPlayed > 0 {
            logTransfer(TransferRecord(date: Date(), outgoing: false, channel: displayName(of: finished.channel),
                                       seconds: Double(finished.framesPlayed * finished.frameMilliseconds) / 1000,
                                       legs: [.init(peer: self.contact(finished.sender)?.name ?? "?", route: finished.route)]))
        }
        // Relayed messages play one after another.
        if !relayQueue.isEmpty {
            queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.playNextRelayed() }
        }
        playoutTimer?.cancel()
        playoutTimer = nil
        audio.endPlayback()
        if playEndTone && audioActive && state.settings.rogerBeep { audio.play(.endOfTransmission) }
        if usesPushToTalk && tx == nil {
            // Give any end tone a moment before iOS tears the audio session down.
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.rx == nil, self.tx == nil else { return }
                self.ptt.setActiveRemoteParticipant(nil)
            }
        }
        publish()
    }

    /// Voice waits (buffering) until the receive tone has finished.
    private var playoutHold = Date.distantPast

    private func playIncomingTone() {
        audio.play(.incoming)
        playoutHold = Date().addingTimeInterval(ToneSynth.duration(of: .incoming))
    }

    private func startPlayout() {
        playoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.playoutTick() }
        timer.resume()
        playoutTimer = timer
    }

    private func playoutTick() {
        // Until iOS hands us the audio session, keep buffering: the listener hears the burst
        // time-shifted rather than clipped.
        guard audioActive, Date() >= playoutHold, var r = rx else { return }
        let pulled = r.jitter.pull()
        rx = r
        switch pulled {
        case .frame(let frame):
            audio.playFrame(frame)
            rx?.framesPlayed += 1
        case .missing:
            audio.playFrame(nil)
            rx?.framesPlayed += 1
        case .waiting: break
        case .finished: stopReception()
        }
    }

    // MARK: - Floor outputs

    private func apply(_ outputs: [FloorControl.Output], draining: Bool = false) {
        for output in outputs {
            switch output {
            case .transmitGranted(let channel, let burst, let timestamp):
                startTransmission(channelID: channel, burst: burst, timestamp: timestamp)
            case .busy:
                audio.play(.busy)
                emit(.busy)
            case .transmitEnded(_, _, let preempted):
                if preempted {
                    endBurst()
                    if usesPushToTalk { ptt.stopTransmitting() }
                    audio.play(.busy)
                    emit(.preempted)
                }
            case .receiveStarted(let channel, let burst, let sender):
                startReception(channelID: channel, burst: burst, sender: sender)
            case .receiveEnded:
                if !draining { stopReception() }
            }
        }
    }

    // MARK: - Wake (listener side)

    /// Runs synchronously inside PushToTalk's push callback. Returns the name to display.
    private func handleWakePush(_ payload: [String: Any]) -> String? {
        transport.start()
        guard let packet = APNsRequest.packet(fromPayload: payload),
              let inbound = try? processor.process(packet, channelLookup: { [self] in channel($0) },
                                                   memberLookup: { [self] in contact($0)?.identity }),
              case .wake(let wake) = inbound.message,
              let contact = self.contact(inbound.header.senderID) else {
            log.notice("Rejected an unauthenticated wake push")
            queue.async { [weak self] in self?.ptt.setActiveRemoteParticipant(nil) }
            return nil
        }
        let talker = inbound.channel.kind == .group ? "\(contact.name) · \(inbound.channel.name)" : contact.name
        lastWakeReceived = Date()
        respondToWake(wake, from: contact)
        // Stay awake (PushToTalk keeps our audio session and runtime while the talker is shown)
        // long enough for a whole burst: if no direct path appears, e.g. both phones on cellular,
        // the talker leaves it in the relay when they release, and we play it as soon as it lands.
        pendingWake = (talker, Date().addingTimeInterval(PTTEngine.maxBurstDuration + 20))
        return talker
    }

    /// Punch towards the talker and tell them where we are (PROTOCOL.md §8.2).
    private func respondToWake(_ wake: Wake, from contact: Contact) {
        if let apns, let channel = self.directChannel(for: contact.id),
           let packet = helloPacket(replyRequested: true, keys: channel.keys) {
            apns.sendBackground(packet, to: contact)
        }
        for attempt in 0..<20 {
            queue.asyncAfter(deadline: .now() + .milliseconds(250 * attempt)) { [weak self] in
                guard let self, !self.isLinked(contact.senderID) || attempt == 0 else { return }
                self.sendHello(to: contact, replyRequested: true, endpoints: [], candidates: wake.candidates)
            }
        }
    }

    // MARK: - Contacts and groups

    func addContact(uri: String) throws {
        let card = try ContactCard(uri: uri)
        queue.async { [self] in addContact(card) }
    }

    private func addContact(_ card: ContactCard, announce: Bool = true) {
        guard card.id != identity.id else { return }
        if let i = state.contacts.firstIndex(where: { $0.id == card.id }) {
            state.contacts[i].apply(card: card)
        } else {
            state.contacts.append(Contact(card: card))
            if let direct = try? Channel.direct(local: identity, peer: card) { state.channels.append(direct) }
            if state.settings.selectedChannel == nil { state.settings.selectedChannel = self.directChannel(for: card.id)?.id }
        }
        save()
        if announce, let contact = self.contact(id: card.id) {
            sendHello(to: contact, replyRequested: true, endpoints: [], candidates: contact.reachability.candidates)
        }
    }

    func removeContact(_ id: IdentityID) {
        queue.async { [self] in
            state.contacts.removeAll { $0.id == id }
            state.channels.removeAll { $0.kind == .direct && $0.members == [id] }
            for i in state.channels.indices { state.channels[i].members.removeAll { $0 == id } }
            save()
        }
    }

    func createGroup(name: String, members: [IdentityID]) {
        queue.async { [self] in
            let channel = Channel(kind: .group, name: name, keys: .newGroup(), members: members)
            state.channels.append(channel)
            state.settings.selectedChannel = channel.id
            save()
            for member in members { if let contact = self.contact(id: member) { sendInvite(channel, to: contact) } }
        }
    }

    func leaveGroup(_ id: ChannelID) {
        queue.async { [self] in
            guard let channel = self.channel(id), channel.kind == .group else { return }
            let leave = GroupLeave(timestamp: currentTimestamp(), groupID: id)
            for member in channel.members {
                guard let contact = self.contact(id: member), let direct = self.directChannel(for: member),
                      let packet = try? builder.seal(.groupLeave, plaintext: leave.encoded, keys: direct.keys) else { continue }
                sendAnyway(packet, to: contact)
            }
            state.channels.removeAll { $0.id == id }
            if state.settings.selectedChannel == id { state.settings.selectedChannel = state.channels.first?.id }
            save()
        }
    }

    private func sendInvite(_ channel: Channel, to contact: Contact) {
        guard let direct = self.directChannel(for: contact.id), let mine = try? myCard() else { return }
        var cards = [mine]
        for member in channel.members {
            if let c = self.contact(id: member), let card = try? ContactCard(encoded: c.cardData) { cards.append(card) }
        }
        let invite = GroupInvite(timestamp: currentTimestamp(), name: channel.name, keys: channel.keys, memberCards: cards)
        let messageID = MessageID.random()
        let target = SealTarget(identity: contact.identity, prekey: contact.reachability.prekey)
        guard let plaintext = try? invite.sealed(for: target, messageID: messageID),
              let packet = try? builder.seal(.groupInvite, plaintext: plaintext, keys: direct.keys,
                                             messageID: messageID) else { return }
        sendAnyway(packet, to: contact)
    }

    private func acceptInvite(_ invite: GroupInvite, from sender: SenderID) {
        let memberIDs = invite.memberCards.map(\.id)
        guard memberIDs.contains(identity.id), let inviter = self.contact(sender), memberIDs.contains(inviter.id) else {
            return
        }
        for card in invite.memberCards where card.id != identity.id { addContact(card, announce: false) }
        let others = memberIDs.filter { $0 != identity.id }
        if let i = channelIndex[invite.keys.channelID] {
            let existing = state.channels[i]
            guard invite.keys.epoch >= existing.keys.epoch else { return }
            if invite.keys.epoch > existing.keys.epoch { state.channels[i].previousKeys = existing.keys }
            state.channels[i].keys = invite.keys
            state.channels[i].members = Array(Set(existing.members).union(others))
            save()
        } else {
            state.channels.append(Channel(kind: .group, name: invite.name, keys: invite.keys, members: others))
            save()
            emit(.joinedGroup(invite.name))
        }
    }

    // MARK: - Settings and selection

    func select(_ channel: ChannelID) {
        queue.async { [self] in
            state.settings.selectedChannel = channel
            ptt.setDescriptorName(self.channel(channel)?.name ?? "NXTPTT")
            save()
        }
    }

    func setMonitored(_ channel: ChannelID, _ monitored: Bool) {
        queue.async { [self] in
            guard let i = channelIndex[channel] else { return }
            state.channels[i].isMonitored = monitored
            save()
        }
    }

    func updateSettings(_ change: @escaping (inout Settings) -> Void) {
        queue.async { [self] in
            let before = state.settings
            change(&state.settings)
            save()
            applyTransportSettings()
            if before.displayName != state.settings.displayName { announceReachability() }
        }
    }

    func setDeviceToken(_ token: Data) {
        queue.async { [self] in
            guard state.deviceToken != token else { return }
            state.deviceToken = token
            save()
            announceReachability()
        }
    }

    /// Installs a push key shared by a friend (an `eptt://pushkey/` link). Throws if invalid.
    func installPushKey(uri: String) throws {
        let key = try PushKey(uri: uri)
        queue.async { [self] in
            PushKeyKeychain.save(key)
            if !bundlesPushKey { apns = APNsClient.fromKeychain() }
            publish()
            syncWatch()
        }
    }

    /// A link that gives another device this device's push key. Share only with people you trust.
    func pushKeyURI() -> String? {
        queue.sync { PushKeyKeychain.load()?.uri }
    }

    func injectWatchAudio(_ pcm: Data) {
        queue.async { [self] in audio.injectCapturedPCM(pcm, sampleRate: 16_000) }
    }

    /// The signed card other people scan to add us.
    func myCardURI(completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            let uri = try? myCard().uri
            DispatchQueue.main.async { completion(uri) }
        }
    }

    func safetyNumber(with contactID: IdentityID) -> String? {
        queue.sync { contact(id: contactID).map { SafetyNumber.compute(identity.publicIdentity, $0.identity) } }
    }

    private func applyTransportSettings() {
        ToneSynth.chirpFrequency = state.settings.deepChirp ? ToneSynth.deepChirpHz : ToneSynth.classicChirpHz
        transport.stunEnabled = state.settings.stunEnabled
        transport.staticCandidates = state.settings.parsedStaticCandidates
    }

    // MARK: - Sending

    private var myReachability: Reachability {
        let env = APNsClient.environment(of: .main)
        return Reachability(apnsPTTToken: state.pttToken, apnsDeviceToken: state.deviceToken, apnsEnvironment: env,
                            apnsTopic: Bundle.main.bundleIdentifier, candidates: transport.localCandidates,
                            prekey: prekeys.signed,
                            relayMailbox: relay != nil && state.settings.relayEnabled ? state.relayMailbox : nil)
    }

    private func myCard() throws -> ContactCard {
        try ContactCard(signing: identity, name: state.settings.displayName, timestamp: currentTimestamp(),
                        reachability: myReachability)
    }

    private func helloPacket(replyRequested: Bool, keys: ChannelKeys) -> Data? {
        let hello = Hello(name: state.settings.displayName, timestamp: currentTimestamp(), reachability: myReachability,
                          flags: replyRequested ? Hello.replyRequested : 0)
        return try? builder.seal(.hello, plaintext: hello.encoded, keys: keys)
    }

    private func sendHello(to contact: Contact, replyRequested: Bool = false, endpoints: [PeerPath],
                           candidates: [Candidate] = []) {
        guard let channel = self.directChannel(for: contact.id),
              let packet = helloPacket(replyRequested: replyRequested, keys: channel.keys) else { return }
        for endpoint in endpoints { send(packet, via: endpoint) }
        sendToCandidates(packet, candidates)
    }

    private func sendToCandidates(_ packet: Data, _ candidates: [Candidate]) {
        for candidate in candidates where candidate.isRoutable { transport.send(packet, to: candidate) }
    }

    /// Sends over live links only.
    private func send(_ packet: Data, to senders: Set<SenderID>) {
        for sender in senders {
            if let link = links[sender] { send(packet, via: link.endpoint) }
        }
    }

    /// Control messages: use the live link if there is one, otherwise the last known candidates.
    private func sendAnyway(_ packet: Data, to contact: Contact) {
        if let link = links[contact.senderID] {
            send(packet, via: link.endpoint)
        } else {
            sendToCandidates(packet, contact.reachability.candidates)
        }
    }

    /// Our addresses or tokens changed: tell everyone we can reach.
    private func announceReachability() {
        for contact in state.contacts {
            let endpoints = links[contact.senderID].map { [$0.endpoint] } ?? []
            sendHello(to: contact, replyRequested: endpoints.isEmpty, endpoints: endpoints,
                      candidates: endpoints.isEmpty ? contact.reachability.candidates : [])
        }
        publish()
    }

    /// A new Bonjour peer appeared; we cannot tell who it is, so greet each contact there.
    private func helloEveryone(at endpoint: PeerPath) {
        for contact in state.contacts.prefix(32) {
            sendHello(to: contact, replyRequested: true, endpoints: [endpoint])
        }
    }

    // MARK: - Relay and transfer history

    /// Records how a finished transmission went and leaves it in the relay for anyone it missed.
    private func finishOutgoing(_ t: Transmission, endPacket: Data?) {
        var legs: [TransferRecord.Leg] = []
        var missed: [Contact] = []
        for member in t.channel.members {
            guard let contact = self.contact(id: member) else { continue }
            if t.delivered.contains(contact.senderID), let link = links[contact.senderID] {
                legs.append(.init(peer: contact.name, route: PTTEngine.route(for: link.endpoint)))
            } else {
                missed.append(contact)
            }
        }
        var packets = t.backlog.packets
        if let endPacket { packets.append(endPacket) }
        let seconds = Double(t.nextFrameIndex) * Double(audio.captureCodec.frameMilliseconds) / 1000
        let channelName = displayName(of: t.channel)

        // Anyone we couldn't reach directly goes to the relay, or gets a reason why not.
        var relayable: [(Contact, Data)] = []
        let payload = t.nextFrameIndex > 0 ? Relay.encode(packets: packets) : nil
        for contact in missed {
            let reason: String?
            if t.nextFrameIndex == 0 || payload == nil {
                reason = "nothing was recorded"
            } else if relay == nil {
                reason = "no direct connection, and the iCloud relay is unavailable (sign in to iCloud)"
            } else if !state.settings.relayEnabled {
                reason = "no direct connection, and the iCloud relay is off in Settings"
            } else if contact.reachability.relayMailbox == nil {
                reason = "no direct connection, and they haven't shared a relay mailbox yet (have them open the app)"
            } else {
                reason = nil
            }
            if var reason {
                if let wake = wakeOutcomes[contact.senderID] { reason += "; wake \(wake)" }
                legs.append(.init(peer: contact.name, route: .failed, reason: reason))
            } else if let mailbox = contact.reachability.relayMailbox {
                relayable.append((contact, mailbox))
            }
        }

        guard let relay, let payload, !relayable.isEmpty else {
            if !legs.isEmpty {
                logTransfer(TransferRecord(date: Date(), outgoing: true, channel: channelName, seconds: seconds, legs: legs))
            }
            return
        }
        let directLegs = legs
        Task { [weak self] in
            var relayedLegs: [TransferRecord.Leg] = []
            var uploads: [String: Date] = [:]
            for (contact, mailbox) in relayable {
                do {
                    let name = try await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox))
                    uploads[name] = Date().addingTimeInterval(Relay.lifetime)
                    relayedLegs.append(.init(peer: contact.name, route: .relay))
                } catch {
                    log.error("Relay upload failed: \(String(describing: error), privacy: .public)")
                    relayedLegs.append(.init(peer: contact.name, route: .failed,
                                             reason: "iCloud relay upload failed: \(error.localizedDescription)"))
                }
            }
            self?.queue.async {
                guard let self else { return }
                self.state.relayUploads.merge(uploads) { a, _ in a }
                self.logTransfer(TransferRecord(date: Date(), outgoing: true, channel: channelName, seconds: seconds,
                                                legs: directLegs + relayedLegs))
            }
        }
    }

    /// Looks for relayed messages addressed to us and queues them for playback.
    /// Whether the app is on screen. In the background the notification service extension plays
    /// relayed messages (as the notification sound); the app must not play them a second time.
    func setForeground(_ foreground: Bool) {
        queue.async { [self] in
            isForeground = foreground
            if foreground { fetchRelay() }
        }
    }

    /// A relay notification arrived while on screen: play the message live unless we already are.
    func claimRelayed(record: String) {
        queue.async { [self] in
            RelayInbox.forget(record: record)
            if !relayPlayed.contains(record) { relayRecordsSeen.remove(record) }
            fetchRelay(force: true)
        }
    }

    /// Plays a relayed message in full, e.g. when its notification is tapped.
    func replayRelayed(record: String) {
        queue.async { [self] in
            RelayInbox.forget(record: record)
            relayRecordsSeen.remove(record)
            fetchRelay(force: true)
        }
    }

    /// iCloud told us about a relayed message (proves the alert path works end to end).
    func noteRelayAlert() {
        queue.async { [self] in
            lastRelayAlert = Date()
            publish()
        }
    }

    func fetchRelay(force: Bool = false) {
        queue.async { [self] in
            // In the background the notification extension handles the relay, except while a wake
            // keeps us running: then we play relayed audio live through PushToTalk.
            guard isForeground || pendingWake != nil, let relay, state.settings.relayEnabled,
                  let mailbox = state.relayMailbox else { return }
            guard !relayFetchInFlight else {
                if force { relayRefetchPending = true }
                return
            }
            guard force || Date().timeIntervalSince(lastRelayFetch) > 5 else { return }
            relayFetchInFlight = true
            lastRelayFetch = Date()
            let tags = Relay.inboxTags(mailbox: mailbox)
            Task { [weak self] in
                let records = (try? await relay.fetch(tags: tags)) ?? []
                self?.queue.async {
                    guard let self else { return }
                    self.relayFetchInFlight = false
                    let heard = RelayInbox.heard()
                    for record in records where !self.relayRecordsSeen.contains(record.name) {
                        self.relayRecordsSeen.insert(record.name)
                        // Already played as a notification sound: just note it in Activity.
                        if let entry = heard.first(where: { $0.record == record.name }) {
                            if !entry.logged {
                                RelayInbox.markLogged(record: record.name)
                                self.logTransfer(TransferRecord(date: entry.date, outgoing: false, channel: entry.channel,
                                                                seconds: entry.seconds,
                                                                legs: [.init(peer: entry.talker, route: .relay)]))
                            }
                            // A wake was waiting for this one; it has been heard, so stop waiting.
                            if self.pendingWake != nil, self.rx == nil {
                                self.pendingWake = nil
                                self.ptt.setActiveRemoteParticipant(nil)
                            }
                            continue
                        }
                        guard let packets = try? Relay.decode(record.payload) else {
                            Task { await relay.delete(recordName: record.name) }
                            continue
                        }
                        self.relayPlayed.insert(record.name)
                        // Tell the notification extension not to play it a second time.
                        RelayInbox.markPlayedByApp(record: record.name)
                        self.relayQueue.append((record.name, packets))
                    }
                    if self.rx == nil && self.tx == nil { self.playNextRelayed() }
                    if self.relayRefetchPending {
                        self.relayRefetchPending = false
                        self.fetchRelay(force: true)
                    }
                }
            }
        }
    }

    private func playNextRelayed() {
        guard rx == nil, tx == nil, !relayQueue.isEmpty else { return }
        let next = relayQueue.removeFirst()
        for packet in next.packets { handleDatagram(packet, from: nil, relayed: true) }
        if let relay { Task { await relay.delete(recordName: next.record) } }
        // Not playable (e.g. not addressed to this device, or sealed to a deleted prekey): move on.
        if rx == nil, !relayQueue.isEmpty { playNextRelayed() }
    }

    private func refreshRelaySubscription() {
        guard let relay, state.settings.relayEnabled, let mailbox = state.relayMailbox else { return }
        let tags = Relay.inboxTags(mailbox: mailbox) + [Relay.tag(mailbox: mailbox, at: Date().addingTimeInterval(86400))]
        guard tags != subscribedTags else { return }
        subscribedTags = tags
        relayAlerts = "Setting up…"
        Task { [weak self] in
            do {
                try await relay.subscribe(tags: tags)
                self?.queue.async { self?.relayAlerts = "On"; self?.publish() }
            } catch {
                self?.queue.async {
                    guard let self else { return }
                    self.subscribedTags = []   // retry on the next housekeeping pass
                    self.relayAlerts = "Failed: \(error.localizedDescription)"
                    self.publish()
                }
            }
        }
    }

    private func purgeExpiredRelayUploads() {
        guard let relay else { return }
        let now = Date()
        let expired = state.relayUploads.filter { $0.value < now }.map(\.key)
        guard !expired.isEmpty else { return }
        for name in expired { state.relayUploads[name] = nil }
        save()
        Task { for name in expired { await relay.delete(recordName: name) } }
    }

    private func logTransfer(_ record: TransferRecord) {
        if record.outgoing { emit(.delivery(record.legs)) }
        state.transfers.insert(record, at: 0)
        if state.transfers.count > 100 { state.transfers.removeLast(state.transfers.count - 100) }
        save()
    }

    func clearTransfers() {
        queue.async { [self] in
            state.transfers.removeAll()
            save()
        }
    }

    /// Classifies the path a packet took from its remote endpoint.
    static func route(for path: PeerPath?) -> Route {
        guard let path else { return .internet }
        guard case .udp(let endpoint) = path else { return .nearby }
        switch endpoint {
        case .service:
            return .nearby
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                let b = [UInt8](address.rawValue)
                guard b.count == 4 else { return .internet }
                if b[0] == 100 && (b[1] & 0xC0) == 64 { return .overlay }            // 100.64.0.0/10
                if b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168)
                    || (b[0] == 169 && b[1] == 254) { return .localNetwork }
                return .internet
            case .ipv6(let address):
                let b = [UInt8](address.rawValue)
                guard b.count == 16 else { return .internet }
                if let name = address.interface?.name, name.hasPrefix("awdl") || name.hasPrefix("llw") { return .nearby }
                if b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C { return .overlay } // Tailscale ULA
                if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .localNetwork }     // link-local
                if (b[0] & 0xFE) == 0xFC { return .localNetwork }                      // ULA
                return .internet
            case .name:
                return .internet
            @unknown default:
                return .internet
            }
        default:
            return .internet
        }
    }

    private func displayName(of channel: Channel) -> String {
        guard channel.kind == .direct, let member = channel.members.first, let contact = self.contact(id: member) else {
            return channel.name
        }
        return contact.name
    }

    // MARK: - Helpers

    private func send(_ packet: Data, via path: PeerPath) {
        switch path {
        case .udp(let endpoint): transport.send(packet, to: endpoint)
        case .nearby(let peer): nearby.send(packet, to: peer)
        }
    }

    private func isLinked(_ sender: SenderID) -> Bool {
        guard let link = links[sender] else { return false }
        return Date().timeIntervalSince(link.lastHeard) < PTTEngine.linkFreshness
    }

    private func contact(_ sender: SenderID) -> Contact? { contactsBySender[sender].map { state.contacts[$0] } }
    private func contact(id: IdentityID) -> Contact? { contact(id.senderID) }
    private func channel(_ id: ChannelID) -> Channel? { channelIndex[id].map { state.channels[$0] } }
    private var selectedChannel: Channel? { state.settings.selectedChannel.flatMap(channel) }

    private func directChannel(for contact: IdentityID) -> Channel? {
        state.channels.first { $0.kind == .direct && $0.members == [contact] }
    }

    private func audioOrNotify(_ tone: Tone, title: String, body: String) {
        if audioActive { audio.play(tone) }
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func rebuildIndexes() {
        contactsBySender = Dictionary(state.contacts.enumerated().map { ($1.senderID, $0) }, uniquingKeysWith: { a, _ in a })
        channelIndex = Dictionary(state.channels.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        rebuildIndexes()
        Store.save(state)
        publish()
        syncWatch()
        syncInbox()
    }

    /// Shares what the notification service extension needs to open relayed messages (our keys,
    /// contacts and channels) through the Keychain access group, only when it changed.
    private func syncInbox() {
        let snapshot = WatchSync(signingSeed: identity.signingSeed, keyAgreementSeed: identity.keyAgreementSeed,
                                 prekeys: prekeys.store, displayName: state.settings.displayName,
                                 contacts: state.contacts, channels: state.channels,
                                 selectedChannel: state.settings.selectedChannel,
                                 relayMailbox: state.relayMailbox, pushKey: nil)
        guard snapshot != lastInboxSnapshot else { return }
        lastInboxSnapshot = snapshot
        RelayInbox.saveSnapshot(snapshot)
    }

    /// Mirrors what a standalone watch needs, only when it changed.
    private func syncWatch() {
        guard state.settings.standaloneWatch else { return }
        let sync = WatchSync(signingSeed: identity.signingSeed, keyAgreementSeed: identity.keyAgreementSeed,
                             prekeys: prekeys.store, displayName: state.settings.displayName,
                             contacts: state.contacts, channels: state.channels,
                             selectedChannel: state.settings.selectedChannel,
                             relayMailbox: relay != nil && state.settings.relayEnabled ? state.relayMailbox : nil,
                             pushKey: PushKeyKeychain.load())
        guard sync != lastWatchSync else { return }
        lastWatchSync = sync
        onWatchSync?(sync)
    }

    /// Re-sends the watch sync (e.g. after the watch app is reinstalled).
    func resyncWatch() {
        queue.async { [self] in
            lastWatchSync = nil
            syncWatch()
        }
    }

    private var lastOnline: Set<IdentityID> = []

    private func onlinePeers() -> Set<IdentityID> {
        Set(state.contacts.filter { isLinked($0.senderID) }.map(\.id))
    }

    private func publishIfOnlineChanged() {
        if onlinePeers() != lastOnline { publish() }
    }

    private func publish() {
        var snapshot = EngineSnapshot()
        snapshot.contacts = state.contacts
        snapshot.channels = state.channels
        snapshot.settings = state.settings
        if let t = tx {
            snapshot.talk = .transmitting(t.channel.id)
        } else if let r = rx {
            snapshot.talk = .receiving(r.channel.id, talker: r.talker)
            snapshot.receivingRoute = r.route
        }
        lastOnline = onlinePeers()
        snapshot.onlinePeers = lastOnline
        for contact in state.contacts where lastOnline.contains(contact.id) {
            snapshot.peerRoutes[contact.id] = PTTEngine.route(for: links[contact.senderID]?.endpoint)
        }
        snapshot.candidates = transport.localCandidates
        snapshot.pushToTalkAvailable = ptt.isAvailable
        snapshot.wakeAvailable = apns != nil
        snapshot.localIdentity = identity.publicIdentity
        snapshot.transfers = state.transfers
        snapshot.relayAvailable = relay != nil
        snapshot.relayAlerts = relay == nil ? "iCloud unavailable" : (state.settings.relayEnabled ? relayAlerts : "Relay off")
        snapshot.lastRelayAlert = lastRelayAlert
        snapshot.lastWakeSent = lastWakeSent
        snapshot.hasPushToken = state.pttToken != nil
        snapshot.lastWakeReceived = lastWakeReceived
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func emit(_ event: EngineEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
