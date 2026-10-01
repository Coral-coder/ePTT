import AVFoundation
import AudioToolbox
import Foundation
import MultipeerConnectivity
import Network
import UIKit
import UserNotifications
import os
import EPTTCore
import EPTTCompat

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
    /// The Apple Watch has taken over; this phone is standing by.
    var usingWatch = false
    var lastPhoneClaim: Date?
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
    /// The last message received, when its talker allowed replay and it is under an hour old.
    var replayable: ReplayableInfo?
    /// Messages held by Do Not Disturb, oldest first.
    var held: [RelayInbox.Held] = []
    /// Playing held messages one after another.
    var playingHeld = false
    /// Contacts on Do Not Disturb, and whether we break through for them.
    var peerQuiet: [IdentityID: Bool] = [:]
    /// Talk groups we asked to join, still waiting for the inviter to let us in.
    var pendingJoins: [PendingJoin] = []
    /// People who scanned our group codes, waiting for us to let them in or not.
    var joinRequests: [JoinRequest] = []
    /// Contacts on an older build: protocol 1, not post-quantum (PROTOCOL.md §10.1).
    var legacyContacts: Set<IdentityID> = []
}

struct JoinRequest: Identifiable, Equatable {
    /// Group ID + requester identity ID.
    var id: Data
    var group: String
    var name: String
    /// Contacts of ours already in the group.
    var members: [String]
}

struct PendingJoin: Identifiable, Equatable {
    var id: ChannelID
    var group: String
    var inviter: String
}

struct ReplayableInfo: Equatable {
    var talker: String
    var seconds: Double
    var date: Date
    var expires: Date { date.addingTimeInterval(RelayInbox.replayLifetime) }
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
    /// After pressing talk, how long a live member has to answer before we treat them as gone
    /// and wake them by push instead.
    static let liveCheckDelay: TimeInterval = 1.2
    /// After a message ends, how long we wait for receipts before relaying it to anyone silent.
    static let receiptWait: TimeInterval = 1.5
    /// A receipt later than this after the message ended doesn't beep.
    static let deliveredBeepWindow: TimeInterval = 5
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
    /// Protocol 1, for contacts still on a build from before protocol 2 (PROTOCOL.md §10.1).
    private var legacy: LegacyLink?
    /// Protocol-1 twins of protocol-2 packets, by the protocol-2 packet, for those contacts.
    private var twins: [Data: Data] = [:]
    private var twinOrder: [Data] = []

    private final class PrekeyBox {
        var store = PrekeyKeychain.load()
        var signed: SignedPrekey?
        /// One-time prekeys we've handed to contacts (protocol 2, §3.2).
        var oneTime = OneTimeKeyKeychain.load()
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
    /// Our last message: who we sent it to directly, and when it ended. The first receipt from
    /// one of them within `deliveredBeepWindow` gets a single beep.
    private var receiptWatch: (burst: MessageID, endedAt: Date, members: Set<SenderID>)?
    /// Peers whose HELLOs say they send receipts (older builds don't, so we don't wait for them).
    private var receiptSenders: Set<SenderID> = []
    /// When each peer last sent a receipt, or an away HELLO (it only sends that when idle, so
    /// after a message it counts as having heard it).
    private var lastReceipt: [SenderID: Date] = [:]
    /// The last path each peer was heard on; kept after a link is dropped, for the Activity log.
    private var lastPath: [SenderID: PeerPath] = [:]

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
        /// The burst's WAKE, sealed once: every copy (each member, each retry) must be these
        /// same bytes, because the nonce is fixed by the burst ID and seq 0.
        var wakePacket: Data?
        var lastStartResend = Date()
        let startedAt = Date()
        /// Members left out because our session with them isn't post-quantum yet (or we have no
        /// key of theirs to seal to). Nothing is sent to them, not even through the relay.
        var unsecured: [String] = []
        /// The protocol-1 burst key, when members on older builds get a protocol-1 copy.
        var legacyKey: Data?
    }
    private var tx: Transmission?
    /// Channel requested from our UI while we wait for PushToTalk to grant the transmission.
    private var pendingPress: ChannelID?
    /// The talk button is held but nobody on the channel has a secure link yet: a steady tone
    /// plays instead of the chirp, nothing is sent, and it ends when the button is released.
    private var heldWithoutLink = false

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
        var codec: VoiceCodecID = .opus
        var sampleRate: UInt32 = 48_000
        /// The talker allowed replay: keep the frames as played (nil = lost).
        var allowsReplay = false
        var recorded: [Data?] = []
        /// Playing back the last message rather than receiving one.
        var isReplay = false
        /// Replaying decoded audio (a message a notification played) instead of frames.
        var pcm: [AVAudioPCMBuffer]?
        var pcmEnds: Date?
        /// Do Not Disturb: record silently instead of playing, and keep it for later.
        var held = false
        /// Playing this held message; delete it once it has played to the end.
        var heldID: String?
        /// The receive tone is still to play: it goes right before the first audio, not when the
        /// start arrives (after a wake, the start can land seconds before the voice does).
        var toneDue = false
    }
    private var rx: Reception?
    /// Held messages still to play in this run ("play held").
    private var heldQueue: [RelayInbox.Held] = []
    /// Do Not Disturb ended: play what was held as soon as we're on screen.
    private var heldAutoplayPending = false
    private var wasQuiet = false
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
        processor = PacketProcessor(local: identity, agreement: identity.keyAgreement(prekeys: { box.store },
                                                                                      oneTimeKeys: { box.oneTime }))
        builder = PacketBuilder(local: identity)
        let me = identity
        legacy = try? LegacyLink(signingSeed: identity.signingSeed, keyAgreementSeed: identity.keyAgreementSeed) { id, publicKey in
            id == 0 ? try me.sharedSecret(withPublicKey: publicKey) : try box.store.agreement(id: id, with: publicKey)
        }
        floor = FloorControl(localSender: identity.senderID)
        transport = UDPTransport(queue: queue)
        nearby = NearbyTransport(queue: queue)
        // The name the user chose is also kept in the Keychain, so nothing can reset it.
        if let saved = NameKeychain.load() {
            if state.settings.displayName != saved || !state.settings.nameConfirmed {
                state.settings.displayName = saved
                state.settings.nameConfirmed = true
                Store.save(state)
            }
        } else if state.settings.nameConfirmed, !state.settings.displayName.isEmpty {
            NameKeychain.save(state.settings.displayName)
        }
        if state.relayMailbox == nil {
            state.relayMailbox = .random(count: 16)
            Store.save(state)
        }
        migrateToProtocol2()
        rebuildIndexes()
        rotatePrekeysIfNeeded()
    }

    /// Protocol 2: every direct channel runs a pairwise session ratchet. Channels saved by older
    /// builds get a fresh session at epoch 0; the first post-quantum exchange runs as soon as
    /// the contact is reachable, and nothing with content is sent before it completes.
    private func migrateToProtocol2() {
        var changed = false
        for i in state.channels.indices where state.channels[i].kind == .direct && state.channels[i].session == nil {
            guard let member = state.channels[i].members.first,
                  let contact = state.contacts.first(where: { $0.id == member }),
                  var fresh = try? Channel.direct(local: identity, peer: contact.identity,
                                                  name: state.channels[i].name) else { continue }
            fresh.isMonitored = state.channels[i].isMonitored
            state.channels[i] = fresh
            changed = true
        }
        if changed { Store.save(state) }
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
        // Launched before the phone's first unlock: our keys and saved state can't be read yet.
        // Stay dormant rather than run as a stranger (the next launch loads everything).
        guard !IdentityKeychain.unavailable, !Store.readFailed else {
            log.error("Protected data unavailable at launch; not starting")
            return
        }
        wirePushToTalk()
        queue.async { [self] in
            audio.onEncodedFrame = { [weak self] frame in
                self?.queue.async { self?.appendCapturedFrame(frame) }
            }
            audio.onPlaybackPCM16k = { [weak self] pcm in
                guard let self, self.state.settings.playOnWatch else { return }
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
            // Get the link up with whoever we're likely to talk to next.
            if let id = state.settings.selectedChannel, let selected = channel(id) { warmUp(selected) }
            // Requests that came in a push while the app wasn't running (someone joining a group).
            for packet in RelayInbox.takePushed() { handleDatagram(packet, from: nil, relayed: true) }
            takeOneTimeKeysUsedElsewhere()
            retryJoins(loud: false)
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
        if isQuiet != wasQuiet { quietChanged() }   // a timed Do Not Disturb ran out
        apply(floor.tick(now: now))
        // Links go stale silently (nothing arrives), so re-check who is online on every tick;
        // otherwise the UI keeps showing a peer "on the grid" after the path has died.
        publishIfOnlineChanged()
        if !state.pendingJoins.isEmpty, now.timeIntervalSince(lastJoinRetry) > joinRetryInterval { retryJoins(loud: false) }

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

        if isLingering, now > lingerUntil, tx == nil, rx == nil { endLinger(sayAway: true) }

        if now.timeIntervalSince(lastKeepalive) >= 15 {
            lastKeepalive = now
            // Not from the background: we told peers we're away, and a keep-alive would re-link us
            // just before iOS freezes our sockets.
            if (isForeground || isLingering || tx != nil || rx != nil) && !state.watchPrimary {
                for (sender, link) in links where now.timeIntervalSince(link.lastHeard) < 120 {
                    if let contact = self.contact(sender) { sendHello(to: contact, endpoints: [link.endpoint]) }
                }
            }
            earlyVoice.expire(now: now)
            earlyPackets.expire(now: now)
            if rotatePrekeysIfNeeded() { announceReachability() }
            takeOneTimeKeysUsedElsewhere()
            if prekeys.oneTime.purge(now: now) { saveOneTimeKeys() }
            var expired = false
            for i in state.channels.indices {
                guard var session = state.channels[i].session else { continue }
                let before = session
                session.expire(now: now)
                if session != before { state.channels[i].apply(session: session); expired = true }
            }
            if expired { save() }
            for contact in state.contacts { rekeyIfDue(contact, now: now) }
            if now.timeIntervalSince(lastRelayFetch) >= 60 {
                fetchRelay()
                refreshRelaySubscription()
                purgeExpiredRelayUploads()
                // Decoded audio and replay copies don't outlive their purpose.
                RelayInbox.purgeOldSounds()
                RelayInbox.purgeExpiredReplay()
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
        ptt.onBeginTransmitting = { [weak self] fromSystemUI in
            self?.queue.async {
                guard let self else { return }
                // Our own request, but the button was already let go (a quick tap): don't open
                // the microphone with nobody holding it.
                if !fromSystemUI && self.pendingPress == nil {
                    self.ptt.stopTransmitting()
                    return
                }
                let channel = self.pendingPress ?? self.state.settings.selectedChannel
                self.pendingPress = nil
                guard let channel, self.beginBurst(on: channel) || self.heldWithoutLink else {
                    self.ptt.stopTransmitting()
                    return
                }
            }
        }
        ptt.onEndTransmitting = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                if self.heldWithoutLink {   // released from the system UI
                    self.heldWithoutLink = false
                    self.audio.stopHoldTone()
                }
                self.endBurst()
            }
        }
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
            // iOS needs an answer right away. The engine queue may be busy (at launch it is
            // starting sockets, which can block for seconds), so wait for it only briefly; if it
            // doesn't answer in time, show a placeholder and fill in the name when it does.
            let done = DispatchSemaphore(value: 0)
            let answer = WakeAnswer()
            self.queue.async {
                let name = self.handleWakePush(payload)
                let late = answer.finish(name)
                done.signal()
                if late, let name { self.ptt.setActiveRemoteParticipant(name) }
            }
            if done.wait(timeout: .now() + 1.5) == .timedOut {
                let result = answer.timeOut()
                return result.finished ? result.name : nil
            }
            return answer.name
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
        if heldWithoutLink {
            audio.startHoldTone()
        } else if tx != nil {
            audio.play(.talkPermit)
            audio.startCapture()
        } else if rx != nil, rx?.pcm == nil, rx?.isReplay == false {
            rx?.toneDue = true   // played by playoutTick once there's voice to follow it
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

    /// Keys up on `target`, or on the selected channel. A target (a board tile, a reply) doesn't
    /// change the selection.
    func pressTalk(on target: ChannelID? = nil) {
        queue.async { [self] in
            if state.watchPrimary { takeOverNow() }
            guard let channel = target ?? state.settings.selectedChannel, channelIndex[channel] != nil else {
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
            } else if heldWithoutLink {
                if !audioActive { startManualAudio() }
                audio.startHoldTone()
            }
        }
    }

    func releaseTalk() {
        queue.async { [self] in
            let requested = pendingPress != nil
            pendingPress = nil
            if heldWithoutLink {
                heldWithoutLink = false
                audio.stopHoldTone()
                if usesPushToTalk {
                    ptt.stopTransmitting()
                } else if rx == nil {
                    queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, self.tx == nil, self.rx == nil, !self.heldWithoutLink else { return }
                        self.audio.stop()
                        self.audioActive = false
                    }
                }
                return
            }
            guard tx != nil else {
                // Released before iOS granted the transmission: withdraw the request.
                if requested, usesPushToTalk { ptt.stopTransmitting() }
                return
            }
            if usesPushToTalk { ptt.stopTransmitting() } else { endBurst() }
        }
    }

    /// Talk from the Apple Watch. The watch's microphone audio arrives over WatchConnectivity
    /// (injectWatchAudio), so the phone only seals and sends it; it doesn't need a PushToTalk
    /// transmission, which iOS won't start while NXTPTT is in the background.
    private var watchTalking = false

    func pressTalkFromWatch() {
        queue.async { [self] in
            guard tx == nil, let channel = state.settings.selectedChannel, channelIndex[channel] != nil else { return }
            if beginBurst(on: channel) {
                watchTalking = true
                audio.startCapture()
            }
        }
    }

    func releaseTalkFromWatch() {
        queue.async { [self] in
            guard watchTalking else { return }
            watchTalking = false
            endBurst()
        }
    }

    /// Returns false (after playing the busy tone) when the floor is not ours.
    private func beginBurst(on channelID: ChannelID) -> Bool {
        guard tx == nil else { return true }
        apply(floor.pressTalk(on: channelID))
        return tx != nil
    }

    private func startTransmission(channelID: ChannelID, burst: MessageID, timestamp: UInt64) {
        guard var channel = self.channel(channelID) else { return }
        do {
            // Seal a fresh burst key to each member: one of their one-time keys (else their signed
            // prekey), mixed with our post-quantum session secret with them. Members whose
            // session hasn't completed a post-quantum exchange get nothing at all.
            var targets: [SealTarget] = []
            var secured: [IdentityID] = []
            var unsecured: [String] = []
            // Members still on an older build get a protocol-1 copy (PROTOCOL.md §10.1).
            var legacyMembers: [Contact] = []
            for member in channel.members {
                guard let i = contactsBySender[member.senderID] else { continue }
                if peerProtocol(member.senderID) == .legacy {
                    legacyMembers.append(state.contacts[i])
                } else if let target = sealTarget(forContactAt: i) {
                    targets.append(target)
                    secured.append(member)
                } else {
                    unsecured.append(state.contacts[i].name)
                    rekeyIfDue(state.contacts[i])
                }
            }
            guard !targets.isEmpty || !legacyMembers.isEmpty else {
                emit(.message("Securing the link with \(unsecured.joined(separator: ", ")). Try again in a moment."))
                _ = floor.releaseTalk()
                // Hold the steady "no link" tone until the button is released (with PushToTalk the
                // audio session comes up shortly, see audioDidActivate).
                heldWithoutLink = true
                if audioActive { audio.startHoldTone() }
                return
            }
            if !unsecured.isEmpty {
                emit(.message("Not sent to \(unsecured.joined(separator: ", ")) yet: securing the link"))
            }
            save()   // one-time keys were used up
            let peer = legacyPeer(channel)
            channel.members = secured + legacyMembers.map(\.id)
            let outgoing = try OutgoingBurst(identity: identity, channelID: channel.id, burstID: burst,
                                             timestamp: timestamp, targets: targets,
                                             codec: audio.captureCodec.codec,
                                             sampleRate: audio.captureCodec.sampleRate,
                                             frameMilliseconds: audio.captureCodec.frameMilliseconds,
                                             allowsReplay: state.settings.allowReplay)
            let packet = try builder.seal(.burstStart, plaintext: outgoing.start.encoded, keys: channel.keys,
                                          messageID: burst)
            var t = Transmission(channel: channel, burst: burst, burstKey: outgoing.burstKey, startPacket: packet,
                                 backlog: BurstBacklog(burst: burst))
            t.unsecured = unsecured
            if !legacyMembers.isEmpty, var link = legacy {
                let codec = audio.captureCodec
                let start = try link.startBurst(channel: channel, peer: peer, burstID: burst, timestamp: timestamp,
                                                recipients: legacyMembers.map { ($0.identity, $0.reachability.prekey) },
                                                codec: codec.codec.rawValue, sampleRate: codec.sampleRate,
                                                frameMilliseconds: codec.frameMilliseconds,
                                                allowsReplay: state.settings.allowReplay)
                legacy = link
                registerTwin(packet, start.packet)
                t.legacyKey = start.burstKey
            }
            t.backlog.append(packet)
            tx = t
            for member in channel.members {
                guard let contact = self.contact(id: member) else { continue }
                if isLinked(contact.senderID), let link = links[contact.senderID] {
                    deliverBacklog(to: contact.senderID)
                    // Make sure they're really there: their app may have gone to the background
                    // since we last heard from them.
                    sendHello(to: contact, replyRequested: true, endpoints: [link.endpoint])
                } else {
                    wake(contact, for: t)
                }
            }
            queue.asyncAfter(deadline: .now() + PTTEngine.liveCheckDelay) { [weak self] in
                self?.dropSilentMembers(of: burst)
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
                                               burstID: t.burst, burstKey: t.burstKey, seq: t.nextFrameIndex,
                                               group: t.channel.kind == .group)
            if let key = t.legacyKey, var link = legacy {
                registerTwin(packet, try? link.sealBurst(.voice, plaintext: VoiceBody.encode(t.pending), channel: t.channel,
                                                         peer: legacyPeer(t.channel), burstID: t.burst, burstKey: key,
                                                         seq: t.nextFrameIndex))
                legacy = link
            }
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
                                               burstID: t.burst, burstKey: t.burstKey, seq: t.nextFrameIndex,
                                               group: t.channel.kind == .group)
        if let endPacket, let key = t.legacyKey, var link = legacy {
            registerTwin(endPacket, try? link.sealBurst(.burstEnd, plaintext: end.encoded, channel: t.channel,
                                                        peer: legacyPeer(t.channel), burstID: t.burst, burstKey: key,
                                                        seq: t.nextFrameIndex))
            legacy = link
        }
        if let endPacket {
            // Three copies 40 ms apart; receivers drop the duplicates.
            for i in 0..<3 {
                queue.asyncAfter(deadline: .now() + .milliseconds(40 * i)) { [weak self] in
                    self?.send(endPacket, to: t.delivered)
                }
            }
        }
        // Wait for their end-of-message receipts before deciding who got it directly; anyone
        // silent gets it through the relay.
        let endedAt = Date()
        receiptWatch = t.delivered.isEmpty ? nil : (t.burst, endedAt, t.delivered)
        // Talking from the lock screen, iOS suspends us soon after the transmission ends: ask
        // for time to wait for receipts and upload to the relay.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Deliver message")
        queue.asyncAfter(deadline: .now() + PTTEngine.receiptWait) { [weak self] in
            guard let self else {
                UIApplication.shared.endBackgroundTask(background)
                return
            }
            // Stay reachable for their reply before letting this task go.
            if !self.isForeground { self.startLinger() }
            self.finishOutgoing(t, endPacket: endPacket, endedAt: endedAt) {
                UIApplication.shared.endBackgroundTask(background)
            }
        }
        if !usesPushToTalk && rx == nil {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.tx == nil, self.rx == nil else { return }
                self.audio.stop()
                self.audioActive = false
            }
        }
        publish()
    }

    /// One beep: the other phone confirmed our message. With PushToTalk, iOS has usually
    /// deactivated our audio by now, so on screen we open a short session of our own; in the
    /// background iOS doesn't let us make a sound outside a PushToTalk transmission.
    private func playDeliveredBeep() {
        guard tx == nil, rx == nil else { return }
        if audioActive {
            audio.play(.delivered)
            return
        }
        // Our audio session is off (PushToTalk shuts it after a transmission). Play the beep as a
        // system sound instead: no session, no microphone, and other audio keeps playing.
        guard isForeground, let url = PTTEngine.deliveredSoundURL() else { return }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return }
        AudioServicesPlaySystemSoundWithCompletion(sound) { AudioServicesDisposeSystemSoundID(sound) }
    }

    /// The delivered beep as a file: the user's own sound if they chose one, else the built-in
    /// tone written once to Caches.
    private static func deliveredSoundURL() -> URL? {
        if let custom = SoundLibrary.customURL(for: .delivered) { return custom }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("delivered-\(Int(ToneSynth.chirpFrequency)).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ToneSynth.wav(for: .delivered).write(to: url)
        }
        return url
    }

    /// Members we started streaming to but who haven't answered since the burst began (receipt
    /// or probe reply): their app is probably in the background. Stop counting them as live, wake
    /// them by push, and send them the backlog when they come back.
    private func dropSilentMembers(of burst: MessageID) {
        guard let t = tx, t.burst == burst else { return }
        for sender in t.delivered {
            guard let link = links[sender], link.lastHeard < t.startedAt else { continue }
            links[sender] = nil
            tx?.delivered.remove(sender)
            if let contact = self.contact(sender), let current = tx { wake(contact, for: current) }
        }
        publishIfOnlineChanged()
    }

    /// The app is going to the background: tell live peers, so they reach us by push or relay
    /// instead of streaming into sockets iOS is about to freeze. Not while a message is playing
    /// or being sent (PushToTalk keeps us running then).
    func goingToBackground() {
        queue.async { [self] in
            guard tx == nil, rx == nil else { return }
            startLinger()
        }
    }

    // MARK: - Staying reachable for a while in the background

    /// After going to the background, or after a conversation in the background, the app keeps
    /// its live links up for as long as iOS lets it (it asks for this long; iOS usually allows
    /// about 30 s), so a quick reply goes straight through instead of by push and relay.
    static let lingerWanted: TimeInterval = 180
    private var lingerTask = UIBackgroundTaskIdentifier.invalid
    private var lingerUntil = Date.distantPast
    private var isLingering: Bool { lingerTask != .invalid }

    private func startLinger() {
        guard !isForeground, !state.watchPrimary else { return }
        lingerUntil = Date().addingTimeInterval(PTTEngine.lingerWanted)
        guard lingerTask == .invalid else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Stay reachable") { [weak self] in
            // iOS is about to suspend us: tell live peers now, so they wake us instead. (The
            // task must end right here, on the main thread, or iOS kills the app.)
            self?.queue.async {
                guard let self, self.lingerTask == task else { return }
                if self.tx == nil, self.rx == nil { self.sayAway() }
                self.lingerTask = .invalid
            }
            UIApplication.shared.endBackgroundTask(task)
        }
        lingerTask = task
        if task == .invalid { sayAway() }
    }

    private func endLinger(sayAway away: Bool) {
        guard lingerTask != .invalid else { return }
        if away, tx == nil, rx == nil { sayAway() }
        let task = lingerTask
        lingerTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    /// Tells live peers we're going quiet, so they reach us by push or relay instead of
    /// streaming into sockets iOS is about to freeze.
    private func sayAway() {
        for (sender, link) in links where isLinked(sender) {
            if let contact = self.contact(sender) { sendHello(to: contact, endpoints: [link.endpoint], away: true) }
        }
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
        if let quiet = state.peerQuiet.first(where: { $0.id == contact.id }), !quiet.breaksThrough {
            // They're on Do Not Disturb: don't light up their phone; it holds the message.
            noteWake(contact, "not sent: they're on Do Not Disturb")
            return
        }
        guard let apns else {
            noteWake(contact, "not sent: this build has no push key")
            return
        }
        guard contact.isWakeable else {
            noteWake(contact, "not sent: no push token from them yet (have them open NXTPTT once while you're connected)")
            return
        }
        let packet: Data
        if let sealed = tx?.wakePacket, tx?.burst == t.burst {
            packet = sealed
        } else {
            let wake = Wake(name: state.settings.displayName, timestamp: currentTimestamp(),
                            candidates: transport.localCandidates)
            guard let sealed = try? builder.seal(.wake, plaintext: wake.encoded, keys: t.channel.keys, messageID: t.burst,
                                                 group: t.channel.kind == .group)
            else { return }
            if t.legacyKey != nil {
                registerTwin(sealed, legacyTwin(.wake, plaintext: wake.encoded, channel: t.channel, messageID: t.burst))
            }
            packet = sealed
            if tx?.burst == t.burst { tx?.wakePacket = sealed }
        }
        noteWake(contact, "sending…")
        guard let wire = singleWire(packet, for: contact.senderID) else { return }
        apns.sendWake(wire, to: contact) { [weak self] failure in
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
            guard let contact = self.contact(id: contactID), let channel = self.directChannel(for: contactID),
                  let i = contactsBySender[contact.senderID] else { return }
            let alert = CallAlert(name: state.settings.displayName, timestamp: currentTimestamp(), text: text)
            let messageID = MessageID.random()
            let plaintext: Data
            if peerProtocol(contact.senderID) == .legacy {
                // An older build: protocol 1, text and all, under its classical channel key.
                guard var link = legacy,
                      let packet = legacyOnly(try? link.sealCallAlert(name: alert.name, timestamp: alert.timestamp, text: text,
                                                                     channel: channel, peer: contact.identity,
                                                                     messageID: messageID)) else { return }
                legacy = link
                deliverCallAlert(packet, to: contact)
                return
            } else if let text, !text.isEmpty {
                // Typed text is content: sealed like a burst, so only post-quantum and per message.
                guard let target = sealTarget(forContactAt: i),
                      let sealed = try? alert.encoded(sealingTextFor: target, channelID: channel.id, messageID: messageID)
                else {
                    rekeyIfDue(contact)
                    emit(.message("Securing the link with \(contact.name). Send the text again in a moment."))
                    return
                }
                save()
                plaintext = sealed
            } else {
                plaintext = alert.encoded
            }
            guard let packet = try? builder.seal(.callAlert, plaintext: plaintext, keys: channel.keys,
                                                 messageID: messageID) else { return }
            if text?.isEmpty ?? true {
                registerTwin(packet, legacyTwin(.callAlert, plaintext: alert.encoded, channel: channel, messageID: messageID))
            }
            deliverCallAlert(packet, to: contact)
        }
    }

    private func deliverCallAlert(_ packet: Data, to contact: Contact) {
            if isLinked(contact.senderID) {
                send(packet, to: [contact.senderID])
                emit(.message("Call alert sent to \(contact.name)"))
                return
            }
            // Not connected: try their last known address, then a push notification (shows at
            // once, with the alert sound), falling back to the relay.
            sendToCandidates(packet, for: contact.senderID, contact.reachability.candidates)
            guard let apns, contact.reachability.apnsDeviceToken != nil else {
                relayCallAlert(packet, to: contact)
                return
            }
            guard let wire = singleWire(packet, for: contact.senderID) else { return }
            apns.sendAlert(wire, to: contact) { [weak self] failure in
                self?.queue.async {
                    guard let self else { return }
                    if let failure {
                        self.relayCallAlert(packet, to: contact, pushFailure: failure)
                    } else {
                        self.emit(.message("Call alert sent to \(contact.name)"))
                    }
                }
            }
    }

    private func relayCallAlert(_ packet: Data, to contact: Contact, pushFailure: String? = nil) {
            guard let relay, state.settings.relayEnabled, let mailbox = contact.reachability.relayMailbox,
                  let payload = Relay.encode(packets: wireForms(packet, for: contact.senderID)) else {
                emit(.message("Call alert to \(contact.name) may not arrive: "
                              + (pushFailure.map { "push \($0), and " } ?? "")
                              + "the iCloud relay isn't available"))
                return
            }
            Task { [weak self] in
                do {
                    let name = try await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox))
                    self?.queue.async {
                        self?.state.relayUploads[name] = Date().addingTimeInterval(Relay.lifetime)
                        self?.save()
                        self?.emit(.message("Call alert sent to \(contact.name) via iCloud relay"))
                    }
                } catch {
                    self?.emit(.message("Call alert to \(contact.name) failed: \(error.localizedDescription)"))
                }
            }
    }

    // MARK: - Inbound

    /// Entry point for the silent background push that carries a wake acknowledgement.
    func handlePushPacket(_ payload: [AnyHashable: Any]) {
        guard let packet = APNsRequest.packet(fromPayload: payload) else { return }
        queue.async { self.handleDatagram(packet, from: nil) }
    }

    /// A packet as it arrived on the wire: shielded (PROTOCOL.md §6.6), or a bare protocol-1
    /// packet from a contact on an older build (§10.1).
    private func handleDatagram(_ wire: Data, from endpoint: PeerPath?, relayed: Bool = false) {
        guard let inner = innerPacket(wire) else { return }
        handleInner(inner, from: endpoint, relayed: relayed)
    }

    /// The protocol-2 inner packet, or the packet itself if it may be protocol 1 (which carries
    /// no shield; it still has to authenticate).
    private func innerPacket(_ wire: Data) -> Data? {
        unshield(wire) ?? (LegacyLink.looksLegacy(wire) ? wire : nil)
    }

    private func handleInner(_ data: Data, from endpoint: PeerPath?, relayed: Bool = false) {
        // Protocol 1 (version byte 1); protocol-2 inner packets carry version 2.
        if data.first == 1 {
            handleLegacy(data, from: endpoint, relayed: relayed)
            return
        }
        // Someone who scanned one of our group codes: not a contact yet, so not for the processor.
        if (try? PacketHeader(packet: data))?.type == .groupJoin {
            // A push can sit a while before it's seen: allow it the relay's age.
            handleGroupJoin(data, relayed: relayed || endpoint == nil)
            return
        }
        let inbound: InboundPacket
        do {
            inbound = try processor.process(
                data,
                maxAge: relayed ? Relay.lifetime : ReplayGuard.maxClockSkew,
                channelLookup: { [self] in channel($0) },
                memberLookup: { [self] in contact($0)?.identity },
                pairSecret: pairSecrets
            )
        } catch InboundError.incomplete {
            return   // a fragment of a rekey message; the rest is on its way
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

        noteProtocol(2, from: inbound.header.senderID)
        handleInbound(inbound, from: endpoint, relayed: relayed)
    }

    /// An authenticated message, whichever protocol it came in.
    private func handleInbound(_ inbound: InboundPacket, from endpoint: PeerPath?, relayed: Bool) {
        let sender = inbound.header.senderID
        // They sealed this under a newer epoch of our session: they hold it, so we switch to it.
        if inbound.channel.kind == .direct, let i = channelIndex[inbound.channel.id],
           var session = state.channels[i].session, inbound.header.epoch > session.sendEpoch {
            let wasSecure = session.sendEpoch >= 1
            session.peerUsed(epoch: inbound.header.epoch)
            state.channels[i].apply(session: session)
            save()
            if !wasSecure, session.sendEpoch >= 1, let contact = self.contact(sender) { sessionSecured(with: contact) }
        }
        // They're still sending under an older epoch than ours: our confirmation (or our accept)
        // hasn't reached them, and until it does they can't send to us. Confirm again, by every path.
        if inbound.channel.kind == .direct, let session = channel(inbound.channel.id)?.session,
           inbound.header.epoch < session.sendEpoch, let contact = self.contact(sender) {
            confirmEpoch(to: contact)
        }
        // A one-time key opened this: it's used. Deleted once the message completes.
        if let keyID = inbound.openedKeyID, OneTimeKeyStore.isOneTime(keyID) {
            prekeys.oneTime.markUsed(keyID)
            if case .burstStart = inbound.message {
                oneTimeKeyForBurst[inbound.header.messageID] = keyID
            } else {
                prekeys.oneTime.consume(keyID)
            }
            saveOneTimeKeys()
        }
        // The watch has taken over: no links, no playing, no answering. Other messages (cards,
        // group invites) are still applied.
        if state.watchPrimary {
            switch inbound.message {
            case .hello, .burstStart, .voice, .burstEnd, .wake, .callAlert: return
            default: break
            }
        }
        if let endpoint, !state.watchPrimary {
            // An away HELLO must not re-link the peer it's about to drop.
            if case .hello(let hello) = inbound.message, hello.isAway {
                lastPath[sender] = endpoint
            } else {
                noteHeard(sender, at: endpoint)
            }
        }

        switch inbound.message {
        case .hello(let hello):
            handleHello(hello, from: sender, endpoint: endpoint)
        case .burstStart(let start):
            defer {
                for (packet, from) in earlyPackets.take(inbound.header.messageID) { handleInner(packet, from: from) }
            }
            guard inbound.channel.isMonitored || inbound.channel.kind == .direct else { return }
            let burst = inbound.header.messageID
            let wasReceiving = rx?.burst == burst
            pendingBurstInfo[burst] = start
            pendingRoutes[burst] = relayed ? .relay : PTTEngine.route(for: endpoint)
            apply(floor.remoteBurstStarted(channel: inbound.channel.id, burst: burst,
                                           sender: sender, timestamp: start.timestamp))
            floor.remoteActivity(channel: inbound.channel.id, burst: burst)
            // Receipt: tells the talker we're really playing (or holding) it, so it doesn't fall
            // back to push/relay. Only once reception started: a burst we drop (we're busy on
            // another channel) must get no receipt, so the talker leaves it in the relay.
            // (Once: BURST_START repeats every 500 ms.)
            if !wasReceiving, rx?.burst == burst, let endpoint, let contact = self.contact(sender) {
                sendHello(to: contact, endpoints: [endpoint], receipt: true)
            }
            // startReception has taken what it needs; nothing to keep for a dropped or repeated start.
            pendingBurstInfo[burst] = nil
            pendingRoutes[burst] = nil
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
            // The whole message is here: its one-time key goes now. Nobody, us included, can
            // open a copy of it any more.
            if let keyID = oneTimeKeyForBurst.removeValue(forKey: burst) {
                prekeys.oneTime.consume(keyID)
                saveOneTimeKeys()
            }
            // Receipt for the whole message (the talker relays it if this never arrives): only
            // for a message we're playing or just played, never one we dropped.
            if rx?.burst == burst || recentlyPlayed.contains(burst), let endpoint, let contact = self.contact(sender) {
                sendHello(to: contact, endpoints: [endpoint], receipt: true)
            }
            guard var r = rx, r.burst == burst else { return }
            r.jitter.markEnded(frameCount: end.frameCount)
            r.draining = true
            rx = r
            apply(floor.remoteBurstEnded(channel: r.channel.id, burst: burst), draining: true)
        case .callAlert(let alert):
            if holds(sender) {
                emit(.message("Call alert from \(contact(sender)?.name ?? alert.name) · held by Do Not Disturb"))
            } else {
                audioOrNotify(.callAlert, title: "Call alert", body: "\(alert.name) is trying to reach you")
                emit(.callAlert(from: alert.name, text: alert.text))
            }
        case .wake(let wake):
            if let contact = self.contact(sender) { respondToWake(wake, from: contact) }
        case .groupInvite(let invite):
            acceptInvite(invite, from: sender)
        case .groupLeave(let leave):
            if let i = channelIndex[leave.groupID], state.channels[i].kind == .group, let contact = self.contact(sender),
               state.channels[i].members.contains(contact.id) {
                state.channels[i].members.removeAll { $0 == contact.id }
                save()
                // They keep the old group key: the remaining member who sorts first replaces it.
                let remaining = state.channels[i].members + [identity.id]
                if remaining.min() == identity.id { rekeyGroup(at: i) }
            }
        case .card(let card):
            // Their full signed card, e.g. after pairing face to face: tokens, prekey, addresses.
            guard let i = contactsBySender[sender], state.contacts[i].id == card.id else { return }
            if state.contacts[i].apply(card: card) { save() }
        case .pqOffer(let offer):
            handleRekeyOffer(offer, from: sender)
        case .pqAccept(let accept):
            handleRekeyAccept(accept, from: sender)
        case .oneTimeKeys(let batch):
            guard let i = contactsBySender[sender] else { return }
            state.contacts[i].add(oneTimeKeys: batch.keys)
            save()
        }
    }

    /// Where to seal a message for a contact (PROTOCOL.md §6.2): only once our session with them
    /// is post-quantum, and only to one of their one-time keys (used up here) or their signed
    /// prekey — never their static key.
    private func sealTarget(forContactAt i: Int) -> SealTarget? {
        let contact = state.contacts[i]
        guard let session = directChannel(for: contact.id)?.session, session.isQuantumSafe,
              let epoch = session.keys(forEpoch: session.sendEpoch), epoch.epoch >= 1 else { return nil }
        let oneTime = state.contacts[i].takeOneTimeKey()
        return SealTarget(identity: contact.identity, oneTimeKey: oneTime, prekey: contact.reachability.prekey,
                          epoch: epoch)
    }

    /// Which one-time key opened a burst still being received.
    private var oneTimeKeyForBurst: [MessageID: UInt32] = [:]

    /// One-time keys the notification extension opened messages with: mark them used, so they
    /// are deleted once the message's relay copy can no longer be fetched again.
    private func takeOneTimeKeysUsedElsewhere() {
        let used = RelayInbox.takeUsedOneTimeKeys()
        guard !used.isEmpty else { return }
        for id in used { prekeys.oneTime.markUsed(id) }
        saveOneTimeKeys()
    }

    private func saveOneTimeKeys() {
        OneTimeKeyKeychain.save(prekeys.oneTime)
        syncWatch()
        syncInbox()
    }

    // MARK: - Post-quantum session ratchet (PROTOCOL.md §5.3)

    /// A quantum-safe epoch is replaced this often while the contact is reachable.
    static let rekeyInterval: TimeInterval = 3600
    /// A pending offer is re-sent this often while the contact is linked.
    static let offerResend: TimeInterval = 8
    private var lastOfferSent: [ChannelID: Date] = [:]
    private var offersRelayed: Set<String> = []

    /// Sends PQ_OFFER / PQ_ACCEPT fragments: on the live link, else to their last addresses and
    /// (once per message) through the relay.
    private func deliverRekey(_ packets: [Data], relayKey: String, to contact: Contact) {
        if isLinked(contact.senderID), let link = links[contact.senderID] {
            for packet in packets { send(packet, to: contact.senderID, via: link.endpoint) }
            return
        }
        for packet in packets { sendToCandidates(packet, for: contact.senderID, contact.reachability.candidates) }
        // Each fragment also as a silent push (once per offer or accept): the other phone
        // handles it in the background, so the exchange completes without either app open.
        let first = offersRelayed.insert(relayKey).inserted
        if first, let apns {
            for packet in packets {
                if let wire = singleWire(packet, for: contact.senderID) { apns.sendBackground(wire, to: contact) }
            }
        }
        guard first, let relay, state.settings.relayEnabled,
              let mailbox = contact.reachability.relayMailbox,
              let payload = Relay.encode(packets: shieldAll(packets)) else { return }
        Task { [weak self] in
            if let name = try? await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox)) {
                self?.queue.async {
                    self?.state.relayUploads[name] = Date().addingTimeInterval(Relay.lifetime)
                    self?.save()
                }
            }
        }
    }

    /// Starts (or re-sends) a rekey with a contact when it's due: right away while the session is
    /// still at the classical epoch 0, then hourly while they're reachable.
    private func rekeyIfDue(_ contact: Contact, now: Date = Date()) {
        guard !state.watchPrimary, peerProtocol(contact.senderID) != .legacy, let i = channelIndex[directChannel(for: contact.id)?.id ?? .random()],
              var session = state.channels[i].session else { return }
        // We answered their offer but haven't heard from them under the new epoch yet, so we
        // can't use it. Ask them to confirm instead of waiting for them to talk first.
        if session.sendEpoch < session.epoch {
            askToConfirmEpoch(contact)
            return
        }
        let due = !session.isQuantumSafe || now.timeIntervalSince(session.epochStarted) > PTTEngine.rekeyInterval
        guard due || session.hasPendingOffer else { return }
        // Re-send briskly while they're live; otherwise once a minute to their last addresses
        // (the relay gets each offer once).
        let every = isLinked(contact.senderID) ? PTTEngine.offerResend : 60
        guard now.timeIntervalSince(lastOfferSent[state.channels[i].id] ?? .distantPast) >= every else { return }
        guard let offer = try? session.offer(now: now),
              let keys = session.channelKeys(channelID: state.channels[i].id, epoch: offer.baseEpoch),
              let packets = try? builder.sealFragmented(.pqOffer, plaintext: offer.encoded, keys: keys) else { return }
        state.channels[i].apply(session: session)
        lastOfferSent[state.channels[i].id] = now
        save()
        deliverRekey(packets, relayKey: "offer-\(offer.offerID)", to: contact)
    }

    private func handleRekeyOffer(_ offer: PQOffer, from sender: SenderID) {
        guard !state.watchPrimary, let contact = self.contact(sender),
              let i = channelIndex[directChannel(for: contact.id)?.id ?? .random()],
              var session = state.channels[i].session else { return }
        let channelID = state.channels[i].id
        guard let result = try? session.receive(offer: offer, channelID: channelID, localID: identity.id,
                                                peerID: contact.id),
              case .reply(let accept) = result,
              let keys = session.channelKeys(channelID: channelID, epoch: offer.baseEpoch),
              let packets = try? builder.sealFragmented(.pqAccept, plaintext: accept, keys: keys) else { return }
        state.channels[i].apply(session: session)
        save()
        deliverRekey(packets, relayKey: "accept-\(offer.offerID)", to: contact)
        log.info("Rekeyed a session (responder) to epoch \(session.epoch)")
    }

    private func handleRekeyAccept(_ accept: PQAccept, from sender: SenderID) {
        guard !state.watchPrimary, let contact = self.contact(sender),
              let i = channelIndex[directChannel(for: contact.id)?.id ?? .random()],
              var session = state.channels[i].session,
              (try? session.receive(accept: accept, channelID: state.channels[i].id, localID: identity.id,
                                    peerID: contact.id)) == true else { return }
        state.channels[i].apply(session: session)
        lastOfferSent[state.channels[i].id] = nil
        save()
        log.info("Rekeyed a session (initiator) to epoch \(session.epoch)")
        // Sealed under the new epoch: confirms it to them (by every path, relay included: until
        // it arrives they can't send to us), and carries fresh one-time keys.
        confirmEpoch(to: contact, force: true)
        topUpOneTimeKeys(for: contact, theyHold: nil)
        sessionSecured(with: contact)
        publish()
    }

    // MARK: - Epoch confirmation (PROTOCOL.md §5.3)

    private var lastEpochConfirm: [IdentityID: Date] = [:]
    private var lastConfirmAsk: [IdentityID: Date] = [:]
    /// The relay and silent pushes cost more: at most every 3 minutes per contact.
    private var lastConfirmFar: [IdentityID: Date] = [:]

    /// Sends a confirmation HELLO: on the live link if there is one; otherwise to their last
    /// addresses, plus (at most every 3 minutes) a silent push and the relay.
    private func deliverConfirmation(_ packet: Data, to contact: Contact, force: Bool) {
        if let link = links[contact.senderID], isLinked(contact.senderID) {
            send(packet, to: contact.senderID, via: link.endpoint)
            return
        }
        sendAnyway(packet, to: contact)
        guard force || Date().timeIntervalSince(lastConfirmFar[contact.id] ?? .distantPast) > 180 else { return }
        lastConfirmFar[contact.id] = Date()
        deliverAnyway(packet, to: contact)
        if let apns, let wire = singleWire(packet, for: contact.senderID) { apns.sendBackground(wire, to: contact) }
    }

    /// A HELLO under our current epoch, by every path including a silent push and the relay.
    /// The responder of a rekey can't send under the new epoch until something sealed under it
    /// arrives from us.
    private func confirmEpoch(to contact: Contact, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastEpochConfirm[contact.id] ?? .distantPast) > 30,
              let direct = directChannel(for: contact.id),
              let packet = helloPacket(replyRequested: false, keys: direct.keys, to: contact) else { return }
        lastEpochConfirm[contact.id] = Date()
        deliverConfirmation(packet, to: contact, force: force)
    }

    /// We're the responder and still unconfirmed: a HELLO asking for a reply. Their answer is
    /// sealed under the new epoch, which confirms it (and they confirm by every path when they
    /// see us behind, in `handleInbound`).
    private func askToConfirmEpoch(_ contact: Contact) {
        guard Date().timeIntervalSince(lastConfirmAsk[contact.id] ?? .distantPast) > 30 else { return }
        lastConfirmAsk[contact.id] = Date()
        guard let direct = directChannel(for: contact.id),
              let packet = helloPacket(replyRequested: true, keys: direct.keys, to: contact) else { return }
        deliverConfirmation(packet, to: contact, force: false)
    }

    // MARK: - One-time prekeys (PROTOCOL.md §3.2)

    private var lastOneTimeKeysSent: [IdentityID: Date] = [:]

    /// Hands a contact more of our one-time keys if they're running low. `theyHold`: what their
    /// latest HELLO says they have (nil: go by our own count).
    private func topUpOneTimeKeys(for contact: Contact, theyHold: Int?) {
        guard !state.watchPrimary,
              Date().timeIntervalSince(lastOneTimeKeysSent[contact.id] ?? .distantPast) > 30,
              let channel = directChannel(for: contact.id),
              channel.session?.isQuantumSafe == true, channel.keys.epoch >= 1 else { return }
        let held = theyHold ?? prekeys.oneTime.outstanding(for: contact.id)
        guard held < OneTimeKeyStore.lowWater else { return }
        let keys = prekeys.oneTime.issue(to: contact.id, count: OneTimeKeyStore.target - held)
        guard !keys.isEmpty,
              let packet = try? builder.seal(.oneTimeKeys,
                                             plaintext: OneTimeKeyBatch(timestamp: currentTimestamp(), keys: keys).encoded,
                                             keys: channel.keys) else { return }
        lastOneTimeKeysSent[contact.id] = Date()
        saveOneTimeKeys()
        deliverAnyway(packet, to: contact)
    }

    /// BURST_START details by burst, needed when reception begins.
    private var pendingBurstInfo: [MessageID: BurstStart] = [:]
    private var pendingRoutes: [MessageID: Route] = [:]

    private func handleHello(_ hello: Hello, from sender: SenderID, endpoint: PeerPath?) {
        guard let i = contactsBySender[sender] else { return }
        if state.contacts[i].apply(hello: hello) { save() }
        let contact = state.contacts[i]
        let quiet = hello.isDoNotDisturb ? PeerQuiet(id: contact.id, breaksThrough: hello.recipientBreaksThrough) : nil
        if state.peerQuiet.first(where: { $0.id == contact.id }) != quiet {
            state.peerQuiet.removeAll { $0.id == contact.id }
            if let quiet { state.peerQuiet.append(quiet) }
            save()
        }
        if hello.sendsReceipts { receiptSenders.insert(sender) } else { receiptSenders.remove(sender) }
        if !hello.isAway {
            rekeyIfDue(contact)
            topUpOneTimeKeys(for: contact, theyHold: hello.heldOneTimeKeys.map(Int.init))
        }
        if hello.isReceipt || hello.isAway { lastReceipt[sender] = Date() }
        if hello.isAway {
            // Their app went to the background: its sockets are about to go quiet. Reach it by
            // push or relay from now on, until it says hello again.
            links[sender] = nil
            if let t = tx, t.delivered.contains(sender) {
                tx?.delivered.remove(sender)
                if let current = tx { wake(contact, for: current) }
            }
            publishIfOnlineChanged()
            return
        }
        if endpoint != nil, hello.isReceipt, let watch = receiptWatch, watch.members.contains(sender) {
            receiptWatch = nil
            if Date().timeIntervalSince(watch.endedAt) <= PTTEngine.deliveredBeepWindow { playDeliveredBeep() }
        }
        if hello.wantsReply {
            // Reached by push in the background (someone opened our channel): stay reachable a
            // while, so their first press comes straight through.
            if endpoint == nil, !isForeground { startLinger() }
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
        lastPath[sender] = endpoint
        guard !wasLinked, let contact = self.contact(sender) else { return }
        deliverBacklog(to: sender)
        // Re-offer group invites: cheap, idempotent, and covers members who were offline.
        for channel in state.channels where channel.kind == .group && channel.members.contains(contact.id) {
            sendInvite(channel, to: contact)
        }
        publishIfOnlineChanged()
    }

    /// Bursts we recently started playing, so a late BURST_END still gets its receipt.
    private var recentlyPlayed: [MessageID] = []

    private func startReception(channelID: ChannelID, burst: MessageID, sender: SenderID) {
        recentlyPlayed = Array((recentlyPlayed + [burst]).suffix(16))
        stopReception(playEndTone: false)
        guard let channel = self.channel(channelID), let contact = self.contact(sender) else { return }
        let start = pendingBurstInfo.removeValue(forKey: burst)
        let route = pendingRoutes.removeValue(forKey: burst) ?? .internet
        pendingBurstInfo.removeAll()
        pendingRoutes.removeAll()
        let talker = channel.kind == .group ? "\(contact.name) · \(channel.name)" : contact.name
        var r = Reception(channel: channel, burst: burst, sender: sender, talker: talker, route: route)
        r.frameMilliseconds = Int(start?.frameMilliseconds ?? 20)
        r.codec = start?.codec ?? .opus
        r.sampleRate = start?.sampleRate ?? 48_000
        r.allowsReplay = start?.allowsReplay ?? false
        for (index, frames) in earlyVoice.take(burst) {
            for (offset, frame) in frames.enumerated() { r.jitter.insert(index: index + UInt32(offset), frame: frame) }
        }
        pendingWake = nil
        if holds(sender) {
            // Do Not Disturb: no tone, no audio session, no talker on screen; just record it.
            r.held = true
            rx = r
            startPlayout()
            publish()
            return
        }
        rx = r
        audio.beginPlayback(codec: start?.codec ?? .opus, sampleRate: start?.sampleRate ?? 48_000,
                            frameMilliseconds: start?.frameMilliseconds ?? 20)
        if usesPushToTalk {
            ptt.setActiveRemoteParticipant(talker)   // iOS then activates audio → audioDidActivate
        } else if !audioActive {
            startManualAudio()
        }
        // The receive tone plays when the voice is ready to follow it (playoutTick).
        rx?.toneDue = true
        startPlayout()
        publish()
    }

    private func stopReception(playEndTone: Bool = true) {
        guard let finished = rx else { return }
        rx = nil
        if finished.isReplay {
            if let id = finished.heldID, playEndTone {
                // Played to the end: it's been heard, so it goes.
                diskCache = nil
                RelayInbox.removeHeld(id)
                heldQueue.removeAll { $0.id == id }
            }
            finishStop(playEndTone: playEndTone && finished.heldID == nil)
            if finished.heldID != nil {
                queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.playNextHeld() }
            }
            return
        }
        processor.forgetBurst(sender: finished.sender, burst: finished.burst)
        legacy?.forgetBurst(sender: finished.sender, burst: finished.burst)
        if finished.held {
            playoutTimer?.cancel()
            playoutTimer = nil
            let seconds = Double(finished.recorded.count * finished.frameMilliseconds) / 1000
            if !finished.recorded.isEmpty {
                diskCache = nil
                RelayInbox.hold(.init(id: UUID().uuidString, date: Date(), talker: finished.talker,
                                      channel: displayName(of: finished.channel), seconds: seconds, source: .frames,
                                      codec: finished.codec.rawValue, sampleRate: finished.sampleRate,
                                      frameMilliseconds: UInt8(clamping: finished.frameMilliseconds)),
                                audio: RelayInbox.encodeFrames(finished.recorded))
                logTransfer(TransferRecord(date: Date(), outgoing: false, channel: displayName(of: finished.channel),
                                           seconds: seconds,
                                           legs: [.init(peer: self.contact(finished.sender)?.name ?? "?", route: finished.route,
                                                        reason: "held · Do Not Disturb")],
                                           channelID: finished.channel.id))
            }
            if !relayQueue.isEmpty {
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.playNextRelayed() }
            }
            publish()
            return
        }
        if finished.framesPlayed > 0 {
            // Only the latest message is kept; its audio only if the talker allowed replay.
            diskCache = nil
            RelayInbox.saveLastReceived(.init(date: Date(), talker: finished.talker,
                                              channel: displayName(of: finished.channel),
                                              seconds: Double(finished.framesPlayed * finished.frameMilliseconds) / 1000,
                                              replayable: finished.allowsReplay, source: .frames,
                                              codec: finished.codec.rawValue, sampleRate: finished.sampleRate,
                                              frameMilliseconds: UInt8(clamping: finished.frameMilliseconds)),
                                        audio: finished.allowsReplay ? RelayInbox.encodeFrames(finished.recorded) : nil)
            logTransfer(TransferRecord(date: Date(), outgoing: false, channel: displayName(of: finished.channel),
                                       seconds: Double(finished.framesPlayed * finished.frameMilliseconds) / 1000,
                                       legs: [.init(peer: self.contact(finished.sender)?.name ?? "?", route: finished.route)],
                                       channelID: finished.channel.id))
        }
        finishStop(playEndTone: playEndTone)
    }

    private func finishStop(playEndTone: Bool) {
        // Relayed messages play one after another.
        if !relayQueue.isEmpty {
            queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.playNextRelayed() }
        }
        playoutTimer?.cancel()
        playoutTimer = nil
        audio.endPlayback()
        if playEndTone && audioActive && state.settings.rogerBeep { audio.play(.endOfTransmission) }
        // In the background, a reply is likely: stay reachable for a while.
        if !isForeground && tx == nil { startLinger() }
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
        if var r = rx, r.held {
            // Held: drain the jitter buffer at the normal pace, recording instead of playing.
            let pulled = r.jitter.pull()
            switch pulled {
            case .frame(let frame): r.recorded.append(frame)
            case .missing: r.recorded.append(nil)
            case .waiting: break
            case .finished:
                rx = r
                stopReception(playEndTone: false)
                return
            }
            rx = r
            return
        }
        guard audioActive, Date() >= playoutHold, var r = rx else { return }
        if r.toneDue {
            // Tone, then voice, with no silence between: wait until enough audio is buffered
            // to play straight through (or the message has ended).
            guard r.jitter.bufferedCount >= r.jitter.targetFrames || r.draining else { return }
            rx?.toneDue = false
            playIncomingTone()
            return
        }
        if let pcm = r.pcm {
            if let ends = r.pcmEnds {
                if Date() >= ends { stopReception() }
            } else {
                rx?.pcmEnds = Date().addingTimeInterval(audio.playBuffers(pcm) + 0.2)
            }
            return
        }
        let pulled = r.jitter.pull()
        rx = r
        switch pulled {
        case .frame(let frame):
            audio.playFrame(frame)
            rx?.framesPlayed += 1
            if r.allowsReplay && !r.isReplay { rx?.recorded.append(frame) }
        case .missing:
            audio.playFrame(nil)
            rx?.framesPlayed += 1
            if r.allowsReplay && !r.isReplay { rx?.recorded.append(nil) }
        case .waiting: break
        case .finished: stopReception()
        }
    }

    // MARK: - Replay

    /// Plays the last message received again: only the latest, only if its talker allowed it,
    /// and only for an hour. Always the whole message.
    func replayLast() {
        queue.async { [self] in
            guard rx == nil, tx == nil, let last = RelayInbox.replayableLast() else { return }
            let info = last.info
            if !playStored(talker: "Replay · " + info.talker, channelName: info.channel, source: info.source,
                           audio: last.audio, codec: info.codec, sampleRate: info.sampleRate,
                           frameMilliseconds: info.frameMilliseconds, heldID: nil) {
                emit(.message("That message can't be replayed any more"))
            }
        }
    }

    /// Erases received audio still on this device now: decoded notification sounds and the
    /// replay copy.
    func burnReceivedAudio() {
        queue.async { [self] in
            RelayInbox.burnReceivedAudio()
            diskCache = nil
            publish()
            emit(.message("Received audio erased from this iPhone"))
        }
    }

    // MARK: - Do Not Disturb

    /// Whether a message from this sender is held rather than played right now.
    private func holds(_ sender: SenderID) -> Bool {
        guard let until = state.settings.quietUntil, until > Date() else { return false }
        guard let contact = contact(sender) else { return true }
        return !state.settings.priorityContacts.contains(contact.id)
    }

    private var isQuiet: Bool { state.settings.quietUntil.map { $0 > Date() } ?? false }

    /// Turns Do Not Disturb on until a moment (`distantFuture`: until turned off), or off (nil).
    func setDoNotDisturb(until: Date?) {
        queue.async { [self] in
            state.settings.quietUntil = until.flatMap { $0 > Date() ? $0 : nil }
            save()
            quietChanged()
            scheduleQuietEndNotice()
        }
    }

    func setPriority(_ id: IdentityID, _ priority: Bool) {
        queue.async { [self] in
            state.settings.priorityContacts.removeAll { $0 == id }
            if priority { state.settings.priorityContacts.append(id) }
            save()
            syncQuiet()
            if isQuiet, let contact = contact(id: id) {
                sendHello(to: contact, replyRequested: false, endpoints: links[contact.senderID].map { [$0.endpoint] } ?? [],
                          candidates: contact.reachability.candidates)
            }
        }
    }

    /// Plays every held message, oldest first, each deleted once it has played through.
    func playHeld() {
        queue.async { [self] in
            heldQueue = RelayInbox.heldMessages()
            heldAutoplayPending = false
            playNextHeld()
        }
    }

    func discardHeld() {
        queue.async { [self] in
            diskCache = nil
            for item in RelayInbox.heldMessages() { RelayInbox.removeHeld(item.id) }
            heldQueue = []
            publish()
        }
    }

    private func playNextHeld() {
        guard rx == nil, tx == nil else { return }
        while let next = heldQueue.first {
            guard let audioData = RelayInbox.heldAudio(next),
                  playStored(talker: "Held · " + next.talker, channelName: next.channel, source: next.source,
                             audio: audioData, codec: next.codec, sampleRate: next.sampleRate,
                             frameMilliseconds: next.frameMilliseconds, heldID: next.id) else {
                diskCache = nil
                RelayInbox.removeHeld(next.id)
                heldQueue.removeFirst()
                continue
            }
            return
        }
        publish()
    }

    /// Do Not Disturb turned on or off (or its time ran out): tell contacts, share with the
    /// notification extension, and play what was held once it's over.
    private func quietChanged() {
        // Ran out while the app wasn't running: clear it, and play what was held when we can.
        if let until = state.settings.quietUntil, until <= Date() {
            state.settings.quietUntil = nil
            save()
            if !RelayInbox.heldMessages().isEmpty { heldAutoplayPending = true }
        }
        let quiet = isQuiet
        syncQuiet()
        if wasQuiet != quiet {
            wasQuiet = quiet
            announceReachability()
            if !quiet, !RelayInbox.heldMessages().isEmpty {
                heldAutoplayPending = true
                if isForeground { playHeld() }
            }
        }
        publish()
    }

    private func syncQuiet() {
        let priority = state.settings.priorityContacts.compactMap { id in contact(id: id)?.senderID.bytes }
        RelayInbox.saveQuiet(.init(until: isQuiet ? state.settings.quietUntil : nil, priority: priority))
    }

    /// A reminder when a timed Do Not Disturb ends (the app can't start playing by itself in the
    /// background): tap it and the held messages play.
    private func scheduleQuietEndNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["dnd-end"])
        guard let until = state.settings.quietUntil, until != .distantFuture, until > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Do Not Disturb is over"
        content.body = "Tap to hear any messages that were held."
        content.threadIdentifier = "held"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: until.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: "dnd-end", content: content, trigger: trigger))
    }

    /// Plays a stored message (replay or held) through the normal playback path.
    private func playStored(talker: String, channelName: String, source: RelayInbox.LastReceived.Source, audio data: Data,
                            codec codecID: UInt8, sampleRate: UInt32, frameMilliseconds: UInt8, heldID: String?) -> Bool {
        let channel = state.channels.first { displayName(of: $0) == channelName }
            ?? state.settings.selectedChannel.flatMap { self.channel($0) } ?? state.channels.first
        guard let channel else { return false }
        let nobody = try! SenderID(bytes: Data(count: 8))
        var r = Reception(channel: channel, burst: .random(), sender: nobody, talker: talker, route: .internet)
        r.isReplay = true
        r.heldID = heldID
        switch source {
        case .frames:
            let frames = RelayInbox.decodeFrames(data)
            guard !frames.isEmpty, let codec = VoiceCodecID(rawValue: codecID) else { return false }
            r.frameMilliseconds = Int(frameMilliseconds == 0 ? 20 : frameMilliseconds)
            r.jitter = JitterBuffer(capacity: frames.count + 1)
            for (i, frame) in frames.enumerated() {
                if let frame { r.jitter.insert(index: UInt32(i), frame: frame) }
            }
            r.jitter.markEnded(frameCount: UInt32(frames.count))
            audio.beginPlayback(codec: codec, sampleRate: sampleRate, frameMilliseconds: UInt8(clamping: r.frameMilliseconds))
        case .relay:
            guard let sync = RelayInbox.loadSnapshot(),
                  let message = RelayInbox.open(data, with: sync, maxSeconds: .greatestFiniteMagnitude),
                  !message.buffers.isEmpty else { return false }
            r.pcm = message.buffers
        }
        rx = r
        if usesPushToTalk {
            ptt.setActiveRemoteParticipant(talker)
            if audioActive { playIncomingTone() }
        } else {
            if !audioActive { startManualAudio() }
            playIncomingTone()
        }
        startPlayout()
        publish()
        return true
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
        if state.watchPrimary {
            // The watch has taken over: don't play here.
            queue.async { [weak self] in self?.ptt.setActiveRemoteParticipant(nil) }
            return nil
        }
        transport.start()
        guard let wire = APNsRequest.packet(fromPayload: payload), let inbound = openWakePush(wire),
              case .wake(let wake) = inbound.message,
              let contact = self.contact(inbound.header.senderID) else {
            log.notice("Rejected an unauthenticated wake push")
            queue.async { [weak self] in self?.ptt.setActiveRemoteParticipant(nil) }
            return nil
        }
        let talker = inbound.channel.kind == .group ? "\(contact.name) · \(inbound.channel.name)" : contact.name
        lastWakeReceived = Date()
        if holds(inbound.header.senderID) {
            // Do Not Disturb (they didn't know yet): iOS needs a talker, but let it go at once;
            // the message is held when it arrives. Tell them, so they stop waking us.
            respondToWake(wake, from: contact)
            queue.async { [weak self] in self?.ptt.setActiveRemoteParticipant(nil) }
            return talker
        }
        respondToWake(wake, from: contact)
        // Stay awake (PushToTalk keeps our audio session and runtime while the talker is shown)
        // long enough for a whole burst: if no direct path appears, e.g. both phones on cellular,
        // the talker leaves it in the relay when they release, and we play it as soon as it lands.
        pendingWake = (talker, Date().addingTimeInterval(PTTEngine.maxBurstDuration + 20))
        return talker
    }

    /// A pushed WAKE: protocol 2, or protocol 1 from a contact on an older build.
    private func openWakePush(_ wire: Data) -> InboundPacket? {
        if let packet = unshield(wire) {
            return try? processor.process(packet, channelLookup: { [self] in channel($0) },
                                          memberLookup: { [self] in contact($0)?.identity },
                                          pairSecret: pairSecrets)
        }
        guard LegacyLink.looksLegacy(wire), var link = legacy else { return nil }
        defer { legacy = link }
        guard let inbound = try? link.open(wire, maxAge: ReplayGuard.maxClockSkew,
                                           channelLookup: { [self] in channel($0) },
                                           identityLookup: { [self] in contact(id: $0)?.identity }),
              peerProtocol(inbound.header.senderID) != .current else { return nil }
        noteProtocol(1, from: inbound.header.senderID)
        return inbound
    }

    /// Punch towards the talker and tell them where we are (PROTOCOL.md §8.2).
    private func respondToWake(_ wake: Wake, from contact: Contact) {
        if let apns, let channel = self.directChannel(for: contact.id),
           let packet = helloPacket(replyRequested: true, keys: channel.keys, to: contact),
           let wire = singleWire(packet, for: contact.senderID) {
            apns.sendBackground(wire, to: contact)
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
            if let direct = try? Channel.direct(local: identity, peer: card), channelIndex[direct.id] == nil {
                state.channels.append(direct)
            }
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
            prekeys.oneTime.revoke(id)   // the keys we issued them: nobody else may use them
            saveOneTimeKeys()
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

    /// Renames a talk group for everyone in it: the members get the new name with the same key
    /// (an invite at the same epoch, which only updates the group).
    func renameGroup(_ id: ChannelID, to newName: String) {
        queue.async { [self] in
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).utf8Prefix(maxBytes: 64)
            guard !name.isEmpty, let i = channelIndex[id], state.channels[i].kind == .group,
                  state.channels[i].name != name else { return }
            state.channels[i].name = name
            if state.settings.selectedChannel == id { ptt.setDescriptorName(name) }
            save()
            publish()
            let group = state.channels[i]
            for member in group.members {
                if let contact = self.contact(id: member) { sendInvite(group, to: contact) }
            }
        }
    }

    func leaveGroup(_ id: ChannelID) {
        queue.async { [self] in
            guard let channel = self.channel(id), channel.kind == .group else { return }
            let leave = GroupLeave(timestamp: currentTimestamp(), groupID: id)
            for member in channel.members {
                guard let contact = self.contact(id: member), let direct = self.directChannel(for: member),
                      let packet = try? builder.seal(.groupLeave, plaintext: leave.encoded, keys: direct.keys) else { continue }
                registerTwin(packet, legacyTwin(.groupLeave, plaintext: leave.encoded, channel: direct, messageID: .random()))
                sendAnyway(packet, to: contact)
            }
            state.channels.removeAll { $0.id == id }
            if state.settings.selectedChannel == id { state.settings.selectedChannel = state.channels.first?.id }
            save()
        }
    }

    /// Removes someone from a talk group and replaces the group key, sent only to who's left.
    /// They can't hear new messages anyway (each message key is sealed per member), but the new
    /// key also locks them out of the group's wake-ups and metadata.
    func removeMember(_ member: IdentityID, from groupID: ChannelID) {
        queue.async { [self] in
            guard let i = channelIndex[groupID], state.channels[i].kind == .group,
                  state.channels[i].members.contains(member) else { return }
            state.channels[i].members.removeAll { $0 == member }
            rekeyGroup(at: i)
            emit(.message("\(contact(id: member)?.name ?? "They") can no longer hear \(state.channels[i].name)"))
        }
    }

    /// A new group key at the next epoch, sealed to every remaining member.
    private func rekeyGroup(at i: Int) {
        let old = state.channels[i].keys
        state.channels[i].previousKeys = old
        state.channels[i].keys = old.rekeyed()
        save()
        let group = state.channels[i]
        for member in group.members {
            if let contact = self.contact(id: member) { sendInvite(group, to: contact) }
        }
    }

    /// Our session with a contact just became post-quantum (or moved on): re-offer the groups
    /// we share, whose invites waited for it.
    private func sessionSecured(with contact: Contact) {
        for channel in state.channels where channel.kind == .group && channel.members.contains(contact.id) {
            sendInvite(channel, to: contact)
        }
    }

    private func sendInvite(_ channel: Channel, to contact: Contact) {
        guard let direct = self.directChannel(for: contact.id), let mine = try? myCard(for: contact) else { return }
        var cards = [mine]
        for member in channel.members {
            if let c = self.contact(id: member), let card = try? ContactCard(encoded: c.cardData) { cards.append(card) }
        }
        let invite = GroupInvite(timestamp: currentTimestamp(), name: channel.name, keys: channel.keys, memberCards: cards)
        let messageID = MessageID.random()
        if peerProtocol(contact.senderID) == .legacy {
            // An older build: the group key goes to them in protocol 1 (classical), the only
            // way they can read it.
            guard var link = legacy,
                  let packet = legacyOnly(try? link.sealInvite(invite, direct: direct, peer: contact.identity,
                                                              prekey: contact.reachability.prekey, messageID: messageID))
            else { return }
            legacy = link
            if links[contact.senderID] != nil { sendAnyway(packet, to: contact) } else { deliverAnyway(packet, to: contact) }
            return
        }
        // The group key only ever travels under a post-quantum session; until ours with this
        // contact is ready, the invite waits (it's re-sent once the exchange completes).
        guard let session = direct.session, session.isQuantumSafe,
              let epoch = session.keys(forEpoch: session.sendEpoch), epoch.epoch >= 1,
              let target = SealTarget(identity: contact.identity, oneTimeKey: nil, prekey: contact.reachability.prekey,
                                      epoch: epoch, allowStatic: true) else {
            rekeyIfDue(contact)
            return
        }
        guard let plaintext = try? invite.sealed(for: target, messageID: messageID),
              let packet = try? builder.seal(.groupInvite, plaintext: plaintext, keys: direct.keys,
                                             messageID: messageID) else { return }
        if links[contact.senderID] != nil {
            sendAnyway(packet, to: contact)
        } else {
            deliverAnyway(packet, to: contact)
        }
    }

    // MARK: - Talk-group QR codes (PROTOCOL.md §6.5)

    private var liveJoinCodes: [GroupJoinCode] {
        state.joinCodes.compactMap { try? GroupJoinCode(encoded: $0) }.filter { !$0.isExpired }
    }

    /// A QR code that lets whoever scans it ask to join `groupID`, valid for a day. Reuses the
    /// current code unless `fresh`, which also retires every earlier code for the group.
    func groupJoinURI(for groupID: ChannelID, fresh: Bool = false,
                      completion: @escaping (_ uri: String?, _ expires: Date?) -> Void) {
        queue.async { [self] in
            var result: GroupJoinCode?
            defer {
                let uri = result?.uri
                let expires = result.map { Date(timeIntervalSince1970: Double($0.expires) / 1000) }
                DispatchQueue.main.async { completion(uri, expires) }
            }
            guard let channel = self.channel(groupID), channel.kind == .group, let mine = try? myCard() else { return }
            var codes = liveJoinCodes
            if fresh { codes.removeAll { $0.groupID == groupID } }
            let soon = Date().addingTimeInterval(3600)
            if let i = codes.lastIndex(where: { $0.groupID == groupID && !$0.isExpired(at: soon) }) {
                // Same code, but with our current addresses and push tokens in it.
                let existing = codes[i]
                codes[i] = GroupJoinCode(groupID: groupID, groupName: channel.name, inviter: mine,
                                         secret: existing.secret, expires: existing.expires)
                result = codes[i]
            } else {
                let expires = currentTimestamp(Date().addingTimeInterval(GroupJoinCode.lifetime))
                let code = GroupJoinCode(groupID: groupID, groupName: channel.name, inviter: mine, expires: expires)
                codes.append(code)
                result = code
            }
            state.joinCodes = codes.map(\.encoded)
            save()
        }
    }

    /// Adds a contact to a talk group and sends the group key to everyone, the newcomer included
    /// (e.g. after pairing face to face from the group's invite screen).
    func addMember(_ id: IdentityID, toGroup groupID: ChannelID) {
        queue.async { [self] in
            guard let i = channelIndex[groupID], state.channels[i].kind == .group, id != identity.id,
                  let newcomer = contact(id: id) else { return }
            if !state.channels[i].members.contains(id) {
                state.channels[i].members.append(id)
                save()
            }
            let group = state.channels[i]
            for member in group.members {
                if let contact = self.contact(id: member) { sendInvite(group, to: contact) }
            }
            emit(.message("\(newcomer.name) added to \(group.name)"))
        }
    }

    /// Stops every code for a group from working.
    func retireJoinCodes(for groupID: ChannelID) {
        queue.async { [self] in
            state.joinCodes = liveJoinCodes.filter { $0.groupID != groupID }.map(\.encoded)
            save()
        }
    }

    /// We scanned a group code: add the inviter and ask them to add us.
    func joinGroup(uri: String) throws {
        let code = try GroupJoinCode(uri: uri)
        queue.async { [self] in
            guard !code.isExpired else {
                emit(.message("That group code has expired. Ask for a new one."))
                return
            }
            if channel(code.groupID) != nil {
                emit(.message("You're already in \(code.groupName)"))
                return
            }
            // The inviter becomes a contact (their phone sends us the group key), but the group,
            // not their private channel, is what we're after: keep the selection as it was.
            let selected = state.settings.selectedChannel
            addContact(code.inviter)
            state.settings.selectedChannel = selected
            var pending = pendingJoinCodes.filter { $0.groupID != code.groupID }
            pending.append(code)
            state.pendingJoins = pending.map(\.encoded)
            save()
            sendJoin(code, loud: true)
            joinRetryInterval = 15
            publish()
            let name = code.inviter.name.isEmpty ? "the inviter" : code.inviter.name
            emit(.message("Asked \(name) to let you into \(code.groupName). It shows under Channels until you're in."))
        }
    }

    private var pendingJoinCodes: [GroupJoinCode] {
        state.pendingJoins.compactMap { try? GroupJoinCode(encoded: $0) }
    }

    private var lastJoinRetry = Date.distantPast
    /// 15 s, doubling to 10 min: the owner may be away, or may have said no (we aren't told).
    private var joinRetryInterval: TimeInterval = 15

    /// Sends (again) the request to join `code`'s group, freshly sealed. Loud also pushes it to
    /// the inviter's phone as a notification and leaves it in the relay; otherwise only their
    /// last known addresses (cheap, for retries).
    private func sendJoin(_ code: GroupJoinCode, loud: Bool) {
        guard let inviter = contact(id: code.inviter.id), let mine = try? myCard(for: inviter),
              let packet = try? GroupJoin.seal(card: mine, for: code, timestamp: currentTimestamp(),
                                               builder: builder) else { return }
        guard loud else {
            sendAnyway(packet, to: inviter)
            return
        }
        deliverAnyway(packet, to: inviter)
        guard let wire = shield(packet) else { return }
        apns?.sendJoinRequest(wire, to: inviter) { [weak self] failure in
            guard let failure else { return }
            self?.log.notice("Join request push failed: \(failure, privacy: .public)")
        }
    }

    /// Drops joins that finished or expired, and re-sends the rest.
    private func retryJoins(loud: Bool) {
        lastJoinRetry = Date()
        joinRetryInterval = min(joinRetryInterval * 2, 600)
        let pending = pendingJoinCodes.filter { !$0.isExpired && channel($0.groupID) == nil }
        if pending.count != state.pendingJoins.count {
            state.pendingJoins = pending.map(\.encoded)
            save()
            publish()
        }
        guard !pending.isEmpty else { return }
        for code in pending { sendJoin(code, loud: loud) }
        fetchRelay()   // the group key may be waiting there
    }

    /// "Ask again": pushes the request to the inviter's phone once more.
    func retryJoin(_ groupID: ChannelID) {
        queue.async { [self] in
            guard let code = pendingJoinCodes.first(where: { $0.groupID == groupID }) else { return }
            sendJoin(code, loud: true)
            emit(.message("Asked \(code.inviter.name.isEmpty ? "the inviter" : code.inviter.name) again"))
        }
    }

    func cancelJoin(_ groupID: ChannelID) {
        queue.async { [self] in
            state.pendingJoins = pendingJoinCodes.filter { $0.groupID != groupID }.map(\.encoded)
            save()
            publish()
        }
    }

    /// Someone scanned one of our codes: add them, then send the group key to them and the
    /// updated member list to everyone (GROUP_INVITE, sealed to each member).
    private func handleGroupJoin(_ packet: Data, relayed: Bool) {
        guard let opened = GroupJoin.open(packet, codes: liveJoinCodes, maxAge: relayed ? Relay.lifetime : 600),
              let group = channel(opened.code.groupID), group.kind == .group else { return }
        let card = opened.join.card
        guard card.id != identity.id else { return }
        let key = group.id.bytes + card.id.bytes
        if group.members.contains(card.id) {
            // Already let in; the key hasn't reached them yet: send it to them again, but at most
            // once a minute (their phone retries, and a copied request could be replayed).
            if let last = lastReinvite[key], Date().timeIntervalSince(last) < 60 { return }
            lastReinvite[key] = Date()
            addContact(card, announce: false)
            if let contact = self.contact(id: card.id) { sendInvite(group, to: contact) }
            return
        }
        guard !state.deniedJoins.contains(key) else { return }
        // Ask first. Their phone repeats the request until let in, so a newer card replaces this one.
        // Capped, and forgotten after a while: anyone with a photo of the code could send many.
        let now = Date()
        heldJoins.removeAll { $0.key == key || now.timeIntervalSince($0.received) > PTTEngine.heldJoinLifetime }
        guard heldJoins.count < PTTEngine.maxHeldJoins else { return }
        heldJoins.append((key, group.id, card, now))
        publish()
    }

    /// Join requests waiting for a yes or no.
    private var heldJoins: [(key: Data, groupID: ChannelID, card: ContactCard, received: Date)] = []
    private static let maxHeldJoins = 10
    private static let heldJoinLifetime: TimeInterval = 15 * 60
    private var lastReinvite: [Data: Date] = [:]

    /// Let them in, or not. No is remembered, so their retries don't ask again.
    func answerJoinRequest(_ id: Data, allow: Bool) {
        queue.async { [self] in
            guard let held = heldJoins.first(where: { $0.key == id }) else { return }
            heldJoins.removeAll { $0.key == id }
            if allow {
                admit(held.card, to: held.groupID)
            } else {
                state.deniedJoins = Array((state.deniedJoins + [id]).suffix(100))
                save()
            }
            publish()
        }
    }

    /// Adds them as a contact and group member, and sends the group key to everyone, them included.
    private func admit(_ card: ContactCard, to groupID: ChannelID) {
        addContact(card)
        guard let i = channelIndex[groupID] else { return }
        let isNew = !state.channels[i].members.contains(card.id)
        if isNew {
            state.channels[i].members.append(card.id)
            save()
        }
        let group = state.channels[i]
        for member in group.members {
            if let contact = self.contact(id: member) { sendInvite(group, to: contact) }
        }
        if isNew { emit(.message("\(card.name.isEmpty ? "Someone" : card.name) joined \(group.name)")) }
    }

    private func acceptInvite(_ invite: GroupInvite, from sender: SenderID) {
        let memberIDs = invite.memberCards.map(\.id)
        guard memberIDs.contains(identity.id), let inviter = self.contact(sender), memberIDs.contains(inviter.id) else {
            return
        }
        let id = invite.keys.channelID
        if let i = channelIndex[id] {
            // Only a member of an existing group may change it, and never a private channel:
            // otherwise a contact could swap in their own key for our channel with someone else.
            let existing = state.channels[i]
            guard existing.kind == .group, existing.members.contains(inviter.id) else {
                log.notice("Refused a group invite for a channel the sender can't change")
                return
            }
            guard invite.keys.epoch > existing.keys.epoch
                    || (invite.keys.epoch == existing.keys.epoch && invite.keys == existing.keys) else { return }
        } else {
            // A new group's ID must not be one a private channel with any of its members would use.
            for card in invite.memberCards where card.id != identity.id {
                if let direct = try? Channel.direct(local: identity, peer: card), direct.id == id { return }
            }
        }
        for card in invite.memberCards where card.id != identity.id { addContact(card, announce: false) }
        let others = memberIDs.filter { $0 != identity.id }
        if let i = channelIndex[id] {
            let existing = state.channels[i]
            if invite.keys.epoch > existing.keys.epoch {
                // A rekey: its member list is the whole truth (someone may have been removed).
                state.channels[i].previousKeys = existing.keys
                state.channels[i].members = others
            } else {
                state.channels[i].members = Array(Set(existing.members).union(others))
            }
            // A member renamed the group.
            if !invite.name.isEmpty, invite.name != existing.name {
                state.channels[i].name = invite.name
                if state.settings.selectedChannel == id { ptt.setDescriptorName(invite.name) }
                publish()
            }
            state.channels[i].keys = invite.keys
            save()
        } else {
            state.channels.append(Channel(kind: .group, name: invite.name, keys: invite.keys, members: others))
            if state.pendingJoins.contains(where: { (try? GroupJoinCode(encoded: $0))?.groupID == invite.keys.channelID }) {
                // The group we asked to join: select it.
                state.pendingJoins.removeAll { (try? GroupJoinCode(encoded: $0))?.groupID == invite.keys.channelID }
                state.settings.selectedChannel = invite.keys.channelID
            }
            save()
            publish()
            emit(.joinedGroup(invite.name))
        }
    }

    // MARK: - Settings and selection

    func select(_ channel: ChannelID) {
        queue.async { [self] in
            state.settings.selectedChannel = channel
            ptt.setDescriptorName(self.channel(channel)?.name ?? "NXTPTT")
            save()
            if let selected = self.channel(channel) { warmUp(selected) }
        }
    }

    /// Reaches out to everyone on a channel we may be about to talk on, so the first press goes
    /// straight to them instead of waiting on a wake or the relay: a HELLO to their last known
    /// addresses, and the same HELLO in a silent push, which wakes their app briefly in the
    /// background to punch back (PROTOCOL.md §8.2). At most every 45 s per contact.
    private var lastWarmUp: [SenderID: Date] = [:]

    private func warmUp(_ channel: Channel) {
        guard !state.watchPrimary else { return }
        for member in channel.members.prefix(16) {
            guard let contact = self.contact(id: member), !isLinked(contact.senderID),
                  Date().timeIntervalSince(lastWarmUp[contact.senderID] ?? .distantPast) > 45 else { continue }
            lastWarmUp[contact.senderID] = Date()
            sendHello(to: contact, replyRequested: true, endpoints: [], candidates: contact.reachability.candidates)
            // Not to someone on Do Not Disturb: their phone stays undisturbed until we talk.
            if let quiet = state.peerQuiet.first(where: { $0.id == contact.id }), !quiet.breaksThrough { continue }
            if let apns, let direct = directChannel(for: contact.id),
               let packet = helloPacket(replyRequested: true, keys: direct.keys, to: contact),
               let wire = singleWire(packet, for: contact.senderID) {
                apns.sendBackground(wire, to: contact)
            }
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
            if before.displayName != state.settings.displayName || before.nameConfirmed != state.settings.nameConfirmed {
                if state.settings.nameConfirmed, !state.settings.displayName.isEmpty {
                    NameKeychain.save(state.settings.displayName)
                }
                announceReachability()
            }
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

    /// Installs a push key shared by a friend (an `nxtptt://pushkey/` link). Throws if invalid.
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

    private var myReachability: Reachability { myReachability(for: nil) }

    /// What we tell `contact` about reaching us. Their relay inbox is theirs alone (§11.1);
    /// with no contact (links, QR codes, group codes) it's the public one.
    private func myReachability(for contact: Contact?) -> Reachability {
        let env = APNsClient.environment(of: .main)
        let mailbox = relay != nil && state.settings.relayEnabled ? state.relayMailbox : nil
        return Reachability(apnsPTTToken: state.pttToken, apnsDeviceToken: state.deviceToken, apnsEnvironment: env,
                            apnsTopic: Bundle.main.bundleIdentifier, candidates: transport.localCandidates,
                            prekey: prekeys.signed,
                            relayMailbox: mailbox.map { m in contact.map { Relay.pairMailbox(master: m, peer: $0.id) } ?? m },
                            apnsWatchToken: state.settings.standaloneWatch ? state.watchToken : nil)
    }

    /// Every relay tag we receive under: the public inbox and each contact's.
    private func inboxTags(at date: Date = Date()) -> [String] {
        guard let mailbox = state.relayMailbox else { return [] }
        return Relay.inboxTags(master: mailbox, peers: state.contacts.map(\.id), at: date)
    }

    // MARK: - Face-to-face pairing

    /// Our signed card for Orbit face-to-face pairing: keys, name, push tokens, addresses, relay
    /// mailbox and current signed prekey, so the other phone can reach us directly and
    /// forward-secret from the start.
    func faceCard(completion: @escaping (ContactCard?) -> Void) {
        queue.async { [self] in
            _ = rotatePrekeysIfNeeded()
            let card = try? myCard()
            DispatchQueue.main.async { completion(card) }
        }
    }

    /// Adds a contact whose signed card was read face to face, and says hello straight to the
    /// addresses it lists. They hold our card already, so nothing waits on the relay.
    func addFacePaired(_ card: ContactCard) {
        queue.async { [self] in
            addContact(card)
            markVerified(card.id)
        }
    }

    /// Confirmed in person (optical handshake) or by comparing safety numbers.
    func setVerified(_ id: IdentityID, _ verified: Bool) {
        queue.async { [self] in
            guard let i = state.contacts.firstIndex(where: { $0.id == id }) else { return }
            state.contacts[i].verifiedAt = verified ? Date() : nil
            save()
        }
    }

    private func markVerified(_ id: IdentityID) {
        guard let i = state.contacts.firstIndex(where: { $0.id == id }), !state.contacts[i].isVerified else { return }
        state.contacts[i].verifiedAt = Date()
        save()
    }

    /// What this phone shows over light: public keys, name and relay mailbox.
    func lightProfile(completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            let profile = state.relayMailbox.map {
                LightProfile(identity: identity.publicIdentity, name: state.settings.displayName, relayMailbox: $0).encoded
            }
            DispatchQueue.main.async { completion(profile) }
        }
    }

    /// Adds a contact read over light, then sends them our full signed card through every path we
    /// have (the relay mailbox they just showed us, above all). Their card comes back the same way.
    func addLightPaired(_ profile: LightProfile) {
        queue.async { [self] in
            guard profile.identity.id != identity.id else { return }
            if contact(id: profile.identity.id) == nil {
                // The light carries no name; their signed card fills it in when it arrives.
                let name = profile.name.isEmpty ? "New contact" : profile.name
                state.contacts.append(Contact(identity: profile.identity, name: name,
                                              relayMailbox: profile.relayMailbox))
                if let direct = try? Channel.direct(local: identity, peer: profile.identity, name: name) {
                    state.channels.append(direct)
                    if state.settings.selectedChannel == nil { state.settings.selectedChannel = direct.id }
                }
                save()
            }
            markVerified(profile.identity.id)   // their keys came over light, phone to phone
            guard let contact = self.contact(id: profile.identity.id) else { return }
            sendCard(to: contact)
        }
    }

    private func sendCard(to contact: Contact) {
        guard let direct = directChannel(for: contact.id), let card = try? myCard(for: contact),
              let packet = try? builder.seal(.card, plaintext: card.encoded, keys: direct.keys) else { return }
        registerTwin(packet, legacyTwin(.card, plaintext: card.encoded, channel: direct, messageID: .random()))
        deliverAnyway(packet, to: contact)
    }

    /// Control messages that must arrive even if they're offline: live link or last known
    /// addresses, and their relay mailbox.
    private func deliverAnyway(_ packet: Data, to contact: Contact) {
        sendAnyway(packet, to: contact)
        guard let relay, state.settings.relayEnabled, let mailbox = contact.reachability.relayMailbox,
              let payload = Relay.encode(packets: wireForms(packet, for: contact.senderID)) else { return }
        Task { [weak self] in
            if let name = try? await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox)) {
                self?.queue.async {
                    self?.state.relayUploads[name] = Date().addingTimeInterval(Relay.lifetime)
                    self?.save()
                }
            }
        }
    }

    private func myCard(for contact: Contact? = nil) throws -> ContactCard {
        try ContactCard(signing: identity, name: state.settings.displayName, timestamp: currentTimestamp(),
                        reachability: myReachability(for: contact))
    }

    private func helloPacket(replyRequested: Bool, keys: ChannelKeys, to contact: Contact, away: Bool = false,
                             receipt: Bool = false) -> Data? {
        var flags: UInt8 = (replyRequested ? Hello.replyRequested : 0) | Hello.sendsReceipts
        if away { flags |= Hello.away }
        if receipt { flags |= Hello.receipt }
        if isQuiet {
            flags |= Hello.doNotDisturb
            if state.settings.priorityContacts.contains(contact.id) { flags |= Hello.breaksThrough }
        }
        let hello = Hello(name: state.settings.displayName, timestamp: currentTimestamp(),
                          reachability: myReachability(for: contact),
                          flags: flags, heldOneTimeKeys: UInt16(clamping: contact.availableOneTimeKeys))
        guard let packet = try? builder.seal(.hello, plaintext: hello.encoded, keys: keys) else { return nil }
        if let direct = directChannel(for: contact.id) {
            registerTwin(packet, legacyTwin(.hello, plaintext: hello.encoded, channel: direct, messageID: .random()))
        }
        return packet
    }

    private func sendHello(to contact: Contact, replyRequested: Bool = false, endpoints: [PeerPath],
                           candidates: [Candidate] = [], away: Bool = false, receipt: Bool = false) {
        guard let channel = self.directChannel(for: contact.id),
              let packet = helloPacket(replyRequested: replyRequested, keys: channel.keys, to: contact, away: away,
                                       receipt: receipt)
        else { return }
        for endpoint in endpoints { send(packet, to: contact.senderID, via: endpoint) }
        sendToCandidates(packet, for: contact.senderID, candidates)
    }

    private func sendToCandidates(_ packet: Data, for sender: SenderID, _ candidates: [Candidate]) {
        let wires = wireForms(packet, for: sender)
        for candidate in candidates where candidate.isRoutable {
            for wire in wires { transport.send(wire, to: candidate) }
        }
    }

    /// Sends over live links only.
    private func send(_ packet: Data, to senders: Set<SenderID>) {
        for sender in senders {
            if let link = links[sender] { send(packet, to: sender, via: link.endpoint) }
        }
    }

    /// Control messages: use the live link if there is one, otherwise the last known candidates.
    private func sendAnyway(_ packet: Data, to contact: Contact) {
        if let link = links[contact.senderID] {
            send(packet, to: contact.senderID, via: link.endpoint)
        } else {
            sendToCandidates(packet, for: contact.senderID, contact.reachability.candidates)
        }
    }

    /// Our addresses or tokens changed: tell everyone we can reach.
    private func announceReachability() {
        guard !state.watchPrimary else { return }
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
    private func finishOutgoing(_ t: Transmission, endPacket: Data?, endedAt: Date, done: @escaping () -> Void = {}) {
        var legs: [TransferRecord.Leg] = []
        var missed: [Contact] = []
        for member in t.channel.members {
            guard let contact = self.contact(id: member) else { continue }
            // Direct if we sent it on a live link and they confirmed it (a receipt, or going
            // away, after it ended). Peers on older builds send no receipts: a live link will do.
            let s = contact.senderID
            let confirmed = receiptSenders.contains(s)
                ? (lastReceipt[s] ?? .distantPast) >= endedAt.addingTimeInterval(-0.05)
                : links[s] != nil
            if t.delivered.contains(s), confirmed, let path = links[s]?.endpoint ?? lastPath[s] {
                legs.append(.init(peer: contact.name, route: PTTEngine.route(for: path), reason: heldNote(contact)))
            } else {
                missed.append(contact)
            }
        }
        var packets = t.backlog.packets
        if let endPacket { packets.append(endPacket) }
        let seconds = Double(t.nextFrameIndex) * Double(audio.captureCodec.frameMilliseconds) / 1000
        let channelName = displayName(of: t.channel)
        let channelID = t.channel.id

        // Anyone we couldn't reach directly goes to the relay, or gets a reason why not.
        var relayable: [(contact: Contact, mailbox: Data, payload: Data)] = []
        // Each member's copy in the protocol they speak (an older build gets protocol 1).
        var shared: Data??
        func relayPayload(for contact: Contact) -> Data? {
            guard t.nextFrameIndex > 0 else { return nil }
            if peerProtocol(contact.senderID) == .current {
                if shared == nil { shared = .some(Relay.encode(packets: shieldAll(packets))) }
                return shared ?? nil
            }
            return Relay.encode(packets: packets.flatMap { wireForms($0, for: contact.senderID) })
        }
        for name in t.unsecured {
            legs.append(.init(peer: name, route: .failed,
                              reason: "not sent: the post-quantum link with them isn't set up yet (it sets itself up "
                                + "the next time you're both online)"))
        }
        for contact in missed {
            let reason: String?
            let payload = relayPayload(for: contact)
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
            } else if let mailbox = contact.reachability.relayMailbox, let payload {
                relayable.append((contact, mailbox, payload))
            }
        }

        guard let relay, !relayable.isEmpty else {
            if !legs.isEmpty {
                logTransfer(TransferRecord(date: Date(), outgoing: true, channel: channelName, seconds: seconds, legs: legs,
                                           channelID: t.channel.id))
            }
            done()
            return
        }
        let directLegs = legs
        var notes: [IdentityID: String] = [:]
        for (contact, _, _) in relayable { notes[contact.id] = heldNote(contact) }
        let pusher = apns   // read on our queue, used from the task
        Task { [weak self] in
            var relayedLegs: [TransferRecord.Leg] = []
            var uploads: [String: Date] = [:]
            for (contact, mailbox, payload) in relayable {
                do {
                    let name = try await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox))
                    uploads[name] = Date().addingTimeInterval(Relay.lifetime)
                    relayedLegs.append(.init(peer: contact.name, route: .relay, reason: notes[contact.id]))
                    // Announce it ourselves: iCloud's own alert (a subscription) isn't always allowed.
                    // Not for someone on Do Not Disturb: their phone collects it quietly instead.
                    // Tell their watch, for when their iPhone is away (not on Do Not Disturb).
                    if notes[contact.id] == nil { pusher?.sendRelayNoticeToWatch(to: contact) }
                } catch {
                    log.error("Relay upload failed: \(String(describing: error), privacy: .public)")
                    relayedLegs.append(.init(peer: contact.name, route: .failed,
                                             reason: "iCloud relay upload failed: \(CloudRelay.describe(error))"))
                }
            }
            self?.queue.async {
                guard let self else { return }
                self.state.relayUploads.merge(uploads) { a, _ in a }
                self.logTransfer(TransferRecord(date: Date(), outgoing: true, channel: channelName, seconds: seconds,
                                                legs: directLegs + relayedLegs, channelID: channelID))
                done()
            }
        }
    }

    /// "held · Do Not Disturb" for a recipient whose phone will hold our message.
    private func heldNote(_ contact: Contact) -> String? {
        guard let quiet = state.peerQuiet.first(where: { $0.id == contact.id }), !quiet.breaksThrough else { return nil }
        return "held · Do Not Disturb"
    }

    /// Looks for relayed messages addressed to us and queues them for playback.
    /// Whether the app is on screen. In the background the notification service extension plays
    /// relayed messages (as the notification sound); the app must not play them a second time.
    func setForeground(_ foreground: Bool) {
        queue.async { [self] in
            isForeground = foreground
            if foreground {
                endLinger(sayAway: false)
                takeOverNow()
                fetchRelay()
                quietChanged()
                if heldAutoplayPending, !isQuiet { playHeld() }
            }
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
            guard !state.watchPrimary else { return }   // the watch collects them
            // In the background the notification extension handles the relay, except while a wake
            // keeps us running: then we play relayed audio live through PushToTalk.
            guard isForeground || pendingWake != nil, let relay, state.settings.relayEnabled,
                  state.relayMailbox != nil else { return }
            guard !relayFetchInFlight else {
                if force { relayRefetchPending = true }
                return
            }
            guard force || Date().timeIntervalSince(lastRelayFetch) > 5 else { return }
            relayFetchInFlight = true
            lastRelayFetch = Date()
            let tags = inboxTags()
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
        let inner = next.packets.compactMap(innerPacket)
        if RelayInbox.isReplayedCopy(inner, record: next.record) {
            // An old message posted again under a new record: don't play it twice.
            log.notice("Skipped a replayed relay record")
            if !relayQueue.isEmpty { playNextRelayed() }
            return
        }
        for packet in inner { handleInner(packet, from: nil, relayed: true) }
        if rx != nil { RelayInbox.markRelayed(inner, record: next.record) }
        if let relay { Task { await relay.delete(recordName: next.record) } }
        // Not playable (e.g. not addressed to this device, or sealed to a deleted prekey): move on.
        if rx == nil, !relayQueue.isEmpty { playNextRelayed() }
    }

    private func refreshRelaySubscription() {
        guard let relay, state.settings.relayEnabled, state.relayMailbox != nil else { return }
        // Today's and yesterday's for every inbox, plus tomorrow's so midnight isn't missed.
        let tomorrow = Set(inboxTags(at: Date().addingTimeInterval(86400)))
        let tags = Array(Set(inboxTags()).union(tomorrow)).sorted()
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
                    self.relayAlerts = "Failed: \(CloudRelay.describe(error))"
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

    private func sendWire(_ wire: Data, via path: PeerPath) {
        switch path {
        case .udp(let endpoint): transport.send(wire, to: endpoint)
        case .nearby(let peer): nearby.send(wire, to: peer)
        }
    }

    /// Sends a packet to one contact on one path, in the protocol they speak.
    private func send(_ packet: Data, to sender: SenderID, via path: PeerPath) {
        for wire in wireForms(packet, for: sender) { sendWire(wire, via: path) }
    }

    // MARK: - Contacts on older builds (protocol 1, PROTOCOL.md §10.1)

    private enum PeerProtocol { case unknown, legacy, current }

    private func peerProtocol(_ sender: SenderID) -> PeerProtocol {
        guard let contact = self.contact(sender) else { return .unknown }
        switch state.contactProtocols[contact.id] {
        case 2: return .current
        case 1: return .legacy
        default: return .unknown
        }
    }

    /// Records the protocol a contact just spoke (authenticated). Protocol 2 is final.
    private func noteProtocol(_ version: UInt8, from sender: SenderID) {
        guard let contact = self.contact(sender) else { return }
        let was = state.contactProtocols[contact.id]
        guard was != 2, was != version else { return }
        state.contactProtocols[contact.id] = version
        save()
        publish()
        if version == 1 {
            emit(.message("\(contact.name) is on an older NXTPTT. You can talk, but not post-quantum until they update."))
        } else if was == 1 {
            emit(.message("\(contact.name) updated: your link is post-quantum from now on"))
        }
    }

    /// Keeps the protocol-1 copy of a protocol-2 packet, for contacts who haven't updated.
    private func registerTwin(_ packet: Data, _ twin: Data?) {
        guard let twin, twins[packet] == nil else { return }
        twins[packet] = twin
        twinOrder.append(packet)
        // A burst is at most ~1000 packets; keep a few bursts' worth.
        while twinOrder.count > 4096 { twins[twinOrder.removeFirst()] = nil }
    }

    /// Protocol-1 only: sent as is to contacts on older builds, never to anyone else.
    private func legacyOnly(_ packet: Data?) -> Data? {
        guard let packet else { return nil }
        registerTwin(packet, packet)
        return packet
    }

    /// A contact on protocol 2 gets the shielded packet. One on an older build gets its
    /// protocol-1 twin, if it has one. One we haven't heard from since updating gets both, so
    /// whichever build they run understands.
    private func wireForms(_ packet: Data, for sender: SenderID) -> [Data] {
        let isLegacyOnly = twins[packet] == packet
        switch peerProtocol(sender) {
        case .current: return isLegacyOnly ? [] : shield(packet).map { [$0] } ?? []
        case .legacy: return twins[packet].map { [$0] } ?? []
        case .unknown: return (isLegacyOnly ? [] : shield(packet).map { [$0] } ?? []) + (twins[packet].map { [$0] } ?? [])
        }
    }

    /// One wire packet (a push or a relay record carries one form): protocol 1 for a contact
    /// on an older build, protocol 2 otherwise.
    private func singleWire(_ packet: Data, for sender: SenderID) -> Data? {
        peerProtocol(sender) == .legacy ? twins[packet] : (twins[packet] == packet ? nil : shield(packet))
    }

    /// For a protocol-1 copy: the peer of a direct channel (talk groups don't need one).
    private func legacyPeer(_ channel: Channel) -> PublicIdentity? {
        channel.kind == .direct ? channel.members.first.flatMap { contact(id: $0)?.identity } : nil
    }

    /// Whether anyone in `channel` might need a protocol-1 copy.
    private func needsTwin(_ channel: Channel) -> Bool {
        channel.members.contains { peerProtocol($0.senderID) != .current }
    }

    /// The protocol-1 twin of a control message, if anyone in the channel may need it.
    private func legacyTwin(_ type: PacketType, plaintext: Data, channel: Channel, messageID: MessageID) -> Data? {
        guard needsTwin(channel), var link = legacy else { return nil }
        let twin = try? link.seal(type, plaintext: plaintext, channel: channel, peer: legacyPeer(channel), messageID: messageID)
        legacy = link
        return twin
    }

    private func handleLegacy(_ data: Data, from endpoint: PeerPath?, relayed: Bool) {
        guard var link = legacy else { return }
        let inbound: InboundPacket
        do {
            inbound = try link.open(data, maxAge: relayed ? Relay.lifetime : ReplayGuard.maxClockSkew,
                                    channelLookup: { [self] in channel($0) },
                                    identityLookup: { [self] in contact(id: $0)?.identity })
            legacy = link
        } catch InboundError.unknownBurst {
            legacy = link
            if !relayed, let burst = LegacyLink.messageID(of: data) { earlyPackets.append((data, endpoint), for: burst) }
            return
        } catch InboundError.replay {
            legacy = link
            if let endpoint, let sender = LegacyLink.senderID(of: data), peerProtocol(sender) == .legacy {
                noteHeard(sender, at: endpoint)
            }
            return
        } catch {
            legacy = link
            log.debug("Dropped protocol-1 packet: \(String(describing: error), privacy: .public)")
            return
        }
        let sender = inbound.header.senderID
        // Downgrade lock: a contact who has spoken protocol 2 is never believed in protocol 1.
        guard peerProtocol(sender) != .current else {
            log.notice("Dropped a protocol-1 packet from a contact on protocol 2")
            return
        }
        noteProtocol(1, from: sender)
        handleInbound(inbound, from: endpoint, relayed: relayed)
    }

    // MARK: - Packet shield (PROTOCOL.md §6.6)

    /// Wraps an inner packet for the wire with a fresh random nonce, so the same packet never
    /// looks the same twice. Nil if we don't hold the key its header names.
    private func shield(_ packet: Data) -> Data? {
        guard let header = try? PacketHeader(packet: packet) else { return nil }
        let keys = channel(header.channelID)?.keys(forEpoch: header.epoch)
            ?? pendingJoinCodes.first { $0.joinKeys.channelID == header.channelID }?.joinKeys
            ?? liveJoinCodes.first { $0.joinKeys.channelID == header.channelID }?.joinKeys
        guard let keys, keys.epoch == header.epoch else {
            log.error("No key to shield a packet with")
            return nil
        }
        return try? PacketShield.shield(packet, keys: keys)
    }

    private func shieldAll(_ packets: [Data]) -> [Data] { packets.compactMap(shield) }

    /// Keys an incoming packet may be shielded with: every channel at every epoch we hold,
    /// plus our live group-join codes. The last one that worked is tried first.
    private var lastShieldKey: ChannelKeys?

    private func unshield(_ wire: Data) -> Data? {
        var candidates = state.channels.flatMap(\.shieldCandidates) + liveJoinCodes.map(\.joinKeys)
        if let last = lastShieldKey, let i = candidates.firstIndex(of: last) {
            candidates.swapAt(0, i)
        }
        guard let opened = PacketShield.unshield(wire, candidates: candidates) else { return nil }
        lastShieldKey = opened.keys
        return opened.inner
    }

    /// The burst secret of our session with a sender at an epoch: mixed into every envelope.
    private var pairSecrets: PairSecretLookup {
        { [self] sender, epoch in
            contact(sender).flatMap { directChannel(for: $0.id)?.session?.keys(forEpoch: epoch)?.burstSecret }
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
                                 relayMailbox: state.relayMailbox, pushKey: nil, oneTimeKeys: prekeys.oneTime, contactProtocols: state.contactProtocols)
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
                             // A key shared by link, else the one bundled into this build: without it
                             // the watch can leave messages in the relay but wake nobody.
                             pushKey: PushKeyKeychain.load() ?? PushKey.fromBundle(),
                             oneTimeKeys: prekeys.oneTime, contactProtocols: state.contactProtocols)
        guard sync != lastWatchSync else { return }
        lastWatchSync = sync
        onWatchSync?(sync)
    }

    // MARK: - Watch hand-off

    /// Tells the watch this phone has taken over.
    var onPhoneClaim: ((Date) -> Void)?

    /// The watch app was opened: the watch takes over until this phone's app is opened. We tell
    /// linked contacts we're away and stop linking, playing, fetching the relay and taking wakes.
    func watchClaimed(at date: Date) {
        queue.async { [self] in
            guard !state.watchPrimary, date > (state.lastPhoneClaim ?? .distantPast) else { return }
            for (sender, link) in links where isLinked(sender) {
                if let contact = self.contact(sender) { sendHello(to: contact, endpoints: [link.endpoint], away: true) }
            }
            links = [:]
            state.watchPrimary = true
            RelayInbox.setHandedOff(true)
            save()
            emit(.message("Using your Apple Watch while its NXTPTT app is open."))
        }
    }

    /// The watch app closed: the phone takes back over at once.
    func watchHandedBack() {
        queue.async { [self] in
            guard state.watchPrimary else { return }
            takeOverNow()
        }
    }

    /// This phone takes over again (its app was opened, or talk pressed). Always tells the watch,
    /// with the time, so a claim that crossed ours in flight loses.
    func takeOverFromWatch() {
        queue.async { [self] in takeOverNow() }
    }

    /// On `queue`.
    private func takeOverNow() {
        let now = Date()
        state.lastPhoneClaim = now
        onPhoneClaim?(now)
        guard state.watchPrimary else {
            save()
            return
        }
        state.watchPrimary = false
        RelayInbox.setHandedOff(false)
        save()
        announceReachability()
        fetchRelay()
    }

    /// The paired watch app's push token (from the watch, over WatchConnectivity). Shared with
    /// contacts so they can tell the watch about relayed messages when this iPhone is away.
    func setWatchToken(_ token: Data) {
        queue.async { [self] in
            guard token != state.watchToken else { return }
            state.watchToken = token
            save()
            announceReachability()
        }
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

    /// Held messages and the replayable one live in files; publish() runs often, on the audio
    /// queue, so read them at most every couple of seconds.
    private var diskCache: (at: Date, held: [RelayInbox.Held], replay: RelayInbox.LastReceived?)?

    private func diskInfo() -> (held: [RelayInbox.Held], replay: RelayInbox.LastReceived?) {
        if let cache = diskCache, Date().timeIntervalSince(cache.at) < 2 { return (cache.held, cache.replay) }
        let held = RelayInbox.heldMessages()
        let replay = RelayInbox.replayableInfo()
        diskCache = (Date(), held, replay)
        return (held, replay)
    }

    private func publish() {
        var snapshot = EngineSnapshot()
        snapshot.contacts = state.contacts
        snapshot.legacyContacts = Set(state.contactProtocols.filter { $0.value == 1 }.keys)
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
        snapshot.usingWatch = state.watchPrimary
        snapshot.lastPhoneClaim = state.lastPhoneClaim
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
        let disk = diskInfo()
        snapshot.held = disk.held
        snapshot.playingHeld = rx?.heldID != nil || !heldQueue.isEmpty
        snapshot.pendingJoins = pendingJoinCodes.map {
            PendingJoin(id: $0.groupID, group: $0.groupName, inviter: $0.inviter.name.isEmpty ? "the inviter" : $0.inviter.name)
        }
        snapshot.joinRequests = heldJoins.map { held in
            let group = self.channel(held.groupID)
            return JoinRequest(id: held.key, group: group?.name ?? "Talk group",
                               name: held.card.name.isEmpty ? "Someone" : held.card.name,
                               members: (group?.members ?? []).compactMap { self.contact(id: $0)?.name })
        }
        snapshot.peerQuiet = Dictionary(state.peerQuiet.map { ($0.id, $0.breaksThrough) }, uniquingKeysWith: { a, _ in a })
        if let last = disk.replay {
            snapshot.replayable = ReplayableInfo(talker: last.talker, seconds: last.seconds, date: last.date)
        }
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func emit(_ event: EngineEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}

/// The result of handling a wake push, handed from the engine queue to PushToTalk's thread.
private final class WakeAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var _name: String?
    private var finished = false
    private var late = false

    var name: String? { lock.withLock { _name } }

    /// Engine side: records the answer; true if PushToTalk already gave up waiting for it.
    func finish(_ name: String?) -> Bool {
        lock.withLock {
            _name = name
            finished = true
            return late
        }
    }

    /// PushToTalk side, after waiting too long: the answer if it arrived just now, else marks it late.
    func timeOut() -> (finished: Bool, name: String?) {
        lock.withLock {
            if finished { return (true, _name) }
            late = true
            return (false, nil)
        }
    }
}
