import AVFoundation
import Foundation
import Network
import Security
import UserNotifications
import os
import EPTTCore

/// Standalone mode: the watch acts as the user's identity (mirrored from the iPhone) and talks
/// through the iCloud relay when the iPhone is out of range (docs/ARCHITECTURE.md, "Apple Watch").
///
/// Sending: record → seal a burst exactly as the phone would → leave it in the relay for every
/// member → wake them with a push. Receiving: fetch relayed bursts → open → decode → play.
final class WatchEngine {
    enum Status: Equatable {
        case idle
        case recording
        case sending
        case sent(recipients: Int)
        case failed(String)
        case playing(String)
    }

    /// Called on the main queue.
    var onStatus: ((Status) -> Void)?
    /// Decoded audio to play, as mono Int16 16 kHz chunks. Called on the main queue.
    var onPlayback: ((Data) -> Void)?

    static let maxOpusSeconds = 60.0
    static let maxPCMSeconds = 25.0   // keeps a raw-PCM burst under the relay's size limit

    private let queue = DispatchQueue(label: "app.eptt.watch.engine")
    private let log = Logger(subsystem: "app.eptt", category: "watch")
    private let relay = CloudRelay()
    private var sync: WatchSync?
    private var identity: LocalIdentity?
    private var processor: PacketProcessor?
    private var apns: APNsClient?
    private var recording: Recording?
    private var seenRecords: Set<String> = []
    private var fetching = false

    private struct Recording {
        let channel: Channel
        let burst: OutgoingBurst
        let encoder: CaptureEncoder
        var packets: [Data]
        /// Members we stream to live (linked when the burst began).
        var live: Set<SenderID> = []
        var pending: [Data] = []
        var nextFrame: UInt32 = 0
        let started = Date()
    }

    static let shared = WatchEngine()

    private init() {
        if let stored = WatchSyncKeychain.load() { install(stored) }
    }

    // MARK: - State from the iPhone

    var isConfigured: Bool { queue.sync { identity != nil } }

    var channels: [Channel] { queue.sync { sync?.channels ?? [] } }

    func contactName(_ id: IdentityID) -> String? {
        queue.sync { sync?.contacts.first { $0.id == id }?.name }
    }

    func apply(_ newSync: WatchSync) {
        queue.async { [self] in
            guard newSync != sync else { return }
            WatchSyncKeychain.save(newSync)
            install(newSync)
        }
    }

    private func install(_ newSync: WatchSync) {
        guard let local = try? LocalIdentity(signingSeed: newSync.signingSeed,
                                             keyAgreementSeed: newSync.keyAgreementSeed) else { return }
        sync = newSync
        identity = local
        processor = PacketProcessor(local: local, agreement: newSync.keyAgreement(local))
        if let key = newSync.pushKey, let credentials = try? APNsCredentials(teamID: key.teamID, keyID: key.keyID,
                                                                            p8PEM: key.pem) {
            apns = APNsClient(credentials: credentials, bundleID: Self.phoneBundleID,
                              environment: APNsClient.environment(of: .main))
        } else {
            apns = nil
        }
    }

    /// Pushes are addressed to the iPhone app's topic, which is the watch app's without ".watchkitapp".
    private static var phoneBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".watchkitapp") ? String(id.dropLast(".watchkitapp".count)) : id
    }

    // MARK: - Sending

    /// Starts recording a burst on `channelID`. Returns false if the watch isn't set up.
    func beginBurst(on channelID: ChannelID) -> Bool {
        queue.sync {
            guard recording == nil, let identity, let sync,
                  var channel = sync.channels.first(where: { $0.id == channelID }) else { return false }
            let encoder = CaptureEncoder()
            // Only members whose link is post-quantum (the iPhone runs the rekeys). Never their
            // one-time keys: the iPhone hands those out and would use them again.
            let targets = channel.members.compactMap { id in sync.contacts.first { $0.id == id } }
                .compactMap { contact -> SealTarget? in
                    guard let session = sync.channels.first(where: { $0.kind == .direct && $0.members == [contact.id] })?.session,
                          session.isQuantumSafe, let epoch = session.keys(forEpoch: session.sendEpoch),
                          epoch.epoch >= 1 else { return nil }
                    return SealTarget(identity: contact.identity, oneTimeKey: nil, prekey: contact.reachability.prekey,
                                      epoch: epoch)
                }
            guard !targets.isEmpty else {
                status(.failed("Securing the link. Open NXTPTT on your iPhone."))
                return false
            }
            let secured = Set(targets.map(\.recipient))
            channel.members = channel.members.filter { secured.contains($0.senderID) }
            do {
                let burst = try OutgoingBurst(identity: identity, channelID: channel.id, timestamp: currentTimestamp(),
                                              targets: targets, codec: encoder.codecID,
                                              sampleRate: UInt32(encoder.sampleRate), frameMilliseconds: 20)
                let start = try PacketBuilder(local: identity).seal(.burstStart, plaintext: burst.start.encoded,
                                                                   keys: channel.keys, messageID: burst.burstID,
                                                                   group: channel.kind == .group)
                var r = Recording(channel: channel, burst: burst, encoder: encoder, packets: [start])
                r.live = Set(channel.members.map(\.senderID).filter { isLinked($0) })
                recording = r
                sendLive(start, to: r.live)
                status(.recording)
                return true
            } catch {
                log.error("Could not start burst: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Microphone audio as mono Int16 16 kHz.
    func append(pcm16k: Data) {
        queue.async { [self] in
            guard var r = recording else { return }
            let limit = r.encoder.codecID == .opus ? Self.maxOpusSeconds : Self.maxPCMSeconds
            guard Date().timeIntervalSince(r.started) < limit else { return }
            r.pending += r.encoder.append(pcm16k)
            while r.pending.count >= 3 { seal(Array(r.pending.prefix(3)), into: &r); r.pending.removeFirst(3) }
            recording = r
        }
    }

    private func seal(_ frames: [Data], into r: inout Recording) {
        guard let identity, let packet = try? PacketBuilder(local: identity).sealBurst(
            .voice, plaintext: VoiceBody.encode(frames), keys: r.channel.keys, burstID: r.burst.burstID,
            burstKey: r.burst.burstKey, seq: r.nextFrame, group: r.channel.kind == .group) else { return }
        r.nextFrame += UInt32(frames.count)
        r.packets.append(packet)
        sendLive(packet, to: r.live)
    }

    /// Finishes the burst. Members reached live who confirm it (a receipt) are done; everyone
    /// else gets it through the relay, with a wake or notification.
    func endBurst() {
        queue.async { [self] in
            guard var r = recording, let identity, let sync else { return }
            recording = nil
            if !r.pending.isEmpty { seal(r.pending, into: &r) }
            guard r.nextFrame > 0 else { status(.idle); return }
            let end = BurstEnd(timestamp: currentTimestamp(), frameCount: r.nextFrame)
            if let packet = try? PacketBuilder(local: identity).sealBurst(
                .burstEnd, plaintext: end.encoded, keys: r.channel.keys, burstID: r.burst.burstID,
                burstKey: r.burst.burstKey, seq: r.nextFrame, group: r.channel.kind == .group) {
                r.packets.append(packet)
                // Three copies 40 ms apart, like the phone.
                for i in 0..<3 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(40 * i)) { [weak self] in
                        self?.sendLive(packet, to: r.live)
                    }
                }
            }
            let endedAt = Date()
            status(.sending)
            // Give live members a moment to send their receipts.
            queue.asyncAfter(deadline: .now() + (r.live.isEmpty ? 0 : 1.5)) { [weak self] in
                self?.relay(r, sync: sync, identity: identity, endedAt: endedAt)
            }
        }
    }

    private func relay(_ r: Recording, sync: WatchSync, identity: LocalIdentity, endedAt: Date) {
        let confirmed = r.live.filter { (lastReceipt[$0] ?? .distantPast) >= endedAt.addingTimeInterval(-0.05) }
        let members = r.channel.members.compactMap { id in sync.contacts.first { $0.id == id } }
            .filter { !confirmed.contains($0.senderID) }
        guard !members.isEmpty else {
            status(.sent(recipients: confirmed.count))
            return
        }
        let shielded = r.packets.compactMap { try? PacketShield.shield($0, keys: r.channel.keys) }
        guard let relay, shielded.count == r.packets.count, let payload = Relay.encode(packets: shielded) else {
            status(confirmed.isEmpty ? .failed(relay == nil ? "iCloud unavailable" : "Too long")
                                     : .sent(recipients: confirmed.count))
            return
        }
        let wakePacket = try? PacketShield.shield(PacketBuilder(local: identity).seal(
            .wake, plaintext: Wake(name: sync.displayName, timestamp: currentTimestamp(), candidates: []).encoded,
            keys: r.channel.keys, messageID: r.burst.burstID, group: r.channel.kind == .group), keys: r.channel.keys)
        let apns = self.apns
        let direct = confirmed.count
        Task { [weak self] in
            var delivered = direct
            for contact in members {
                guard let mailbox = contact.reachability.relayMailbox else { continue }
                if (try? await relay.upload(payload: payload, tag: Relay.tag(mailbox: mailbox))) != nil {
                    delivered += 1
                    // The wake makes their phone chirp; it then finds the burst in the relay.
                    if let wakePacket { apns?.sendWake(wakePacket, to: contact) }
                }
            }
            self?.status(delivered > 0 ? .sent(recipients: delivered) : .failed("Nobody reachable"))
        }
    }

    // MARK: - Live (on its own, app open)

    /// While the watch app is open without its iPhone, it keeps its own direct links, like the
    /// phone does (PROTOCOL.md §2, §7). watchOS only allows this networking during an active audio
    /// session, which WatchModel holds for as long as live mode is on.
    private var transport: UDPTransport?
    private var links: [SenderID: (endpoint: NWEndpoint, lastHeard: Date)] = [:]
    private var lastReceipt: [SenderID: Date] = [:]
    private var keepalive: DispatchSourceTimer?
    private var liveRx: LiveReception?
    private static let linkFreshness: TimeInterval = 30

    private struct LiveReception {
        let burst: MessageID
        let decoder: VoiceDecoder
        let converter: PlaybackConverter
        var nextIndex: UInt32?
    }

    var isLive: Bool { queue.sync { transport != nil } }

    func startLive() {
        queue.async { [self] in
            guard transport == nil, identity != nil else { return }
            let t = UDPTransport(queue: queue)
            t.onPacket = { [weak self] data, endpoint in self?.handleLive(data, from: endpoint) }
            t.onPeerDiscovered = { [weak self] endpoint in self?.helloEveryone(at: endpoint) }
            t.onCandidatesChanged = { [weak self] _ in self?.helloAll() }
            t.start()
            transport = t
            helloAll()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in self?.helloLinked() }
            timer.resume()
            keepalive = timer
        }
    }

    /// Leaving live mode (the iPhone is back, or the app closed): tell linked contacts we're away.
    func stopLive() {
        queue.async { [self] in
            guard let transport else { return }
            for (sender, link) in links where isLinked(sender) {
                if let contact = contact(sender), let packet = hello(for: contact, away: true) {
                    transport.send(packet, to: link.endpoint)
                }
            }
            keepalive?.cancel()
            keepalive = nil
            let old = transport
            // Let the away HELLOs go out before closing the socket.
            queue.asyncAfter(deadline: .now() + 0.3) { old.stop() }
            self.transport = nil
            links = [:]
            liveRx = nil
        }
    }

    private func isLinked(_ sender: SenderID) -> Bool {
        guard let link = links[sender] else { return false }
        return Date().timeIntervalSince(link.lastHeard) < Self.linkFreshness
    }

    private func contact(_ sender: SenderID) -> Contact? { sync?.contacts.first { $0.senderID == sender } }

    /// Shields each copy separately (a fresh nonce and padding every time, PROTOCOL.md §6.6).
    private func sendLive(_ packet: Data, to senders: Set<SenderID>) {
        guard let transport, let header = try? PacketHeader(packet: packet),
              let keys = sync?.channels.first(where: { $0.id == header.channelID })?.keys(forEpoch: header.epoch) else { return }
        for sender in senders {
            if let link = links[sender], let wire = try? PacketShield.shield(packet, keys: keys) {
                transport.send(wire, to: link.endpoint)
            }
        }
    }

    private func hello(for contact: Contact, reply: Bool = false, receipt: Bool = false, away: Bool = false) -> Data? {
        guard let identity, let sync, let transport,
              let channel = sync.channels.first(where: { $0.kind == .direct && $0.members == [contact.id] }) else { return nil }
        var flags: UInt8 = Hello.sendsReceipts
        if reply { flags |= Hello.replyRequested }
        if receipt { flags |= Hello.receipt }
        if away { flags |= Hello.away }
        let prekey = try? sync.prekeys.current(signedBy: identity)
        // Our addresses only: no push tokens, so contacts keep the iPhone's.
        let reachability = Reachability(candidates: transport.localCandidates, prekey: prekey,
                                        relayMailbox: sync.relayMailbox)
        let body = Hello(name: sync.displayName, timestamp: currentTimestamp(), reachability: reachability, flags: flags)
        return try? PacketShield.shield(PacketBuilder(local: identity).seal(.hello, plaintext: body.encoded,
                                                                            keys: channel.keys), keys: channel.keys)
    }

    /// Everyone: linked contacts on their link, the rest at every address they last gave us.
    private func helloAll() {
        guard let sync, let transport else { return }
        for contact in sync.contacts {
            if let link = links[contact.senderID], isLinked(contact.senderID) {
                if let packet = hello(for: contact) { transport.send(packet, to: link.endpoint) }
            } else if let packet = hello(for: contact, reply: true) {
                for candidate in contact.reachability.candidates where candidate.isRoutable {
                    transport.send(packet, to: candidate)
                }
            }
        }
    }

    private func helloLinked() {
        guard let transport else { return }
        for (sender, link) in links where isLinked(sender) {
            if let contact = contact(sender), let packet = hello(for: contact) { transport.send(packet, to: link.endpoint) }
        }
        helloAll()
    }

    /// A Bonjour neighbour on the local network: greet each contact there.
    private func helloEveryone(at endpoint: NWEndpoint) {
        guard let sync, let transport else { return }
        for contact in sync.contacts.prefix(32) {
            if let packet = hello(for: contact, reply: true) { transport.send(packet, to: endpoint) }
        }
    }

    private func handleLive(_ wire: Data, from endpoint: NWEndpoint) {
        guard var processor, let sync, let data = sync.unshield(wire) else { return }
        let inbound: InboundPacket
        do {
            inbound = try processor.process(
                data,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets)
        } catch {
            self.processor = processor
            return
        }
        self.processor = processor
        let sender = inbound.header.senderID
        guard let contact = contact(sender), let transport else { return }
        let burst = inbound.header.messageID
        switch inbound.message {
        case .hello(let hello):
            if hello.isReceipt || hello.isAway { lastReceipt[sender] = Date() }
            if hello.isAway {
                links[sender] = nil
                return
            }
            links[sender] = (endpoint, Date())
            if hello.wantsReply, let packet = self.hello(for: contact) { transport.send(packet, to: endpoint) }
        case .burstStart(let start):
            links[sender] = (endpoint, Date())
            guard liveRx?.burst != burst else { return }
            if let packet = hello(for: contact, receipt: true) { transport.send(packet, to: endpoint) }
            guard let decoder = VoiceCodecFactory.makeDecoder(codec: start.codec, sampleRate: start.sampleRate,
                                                              frameMilliseconds: start.frameMilliseconds),
                  let converter = PlaybackConverter(from: decoder.pcmFormat) else { return }
            liveRx = LiveReception(burst: burst, decoder: decoder, converter: converter)
            let name = contact.name
            status(.playing(inbound.channel.kind == .group ? "\(name) · \(inbound.channel.name)" : name))
        case .voice(let index, let frames):
            links[sender] = (endpoint, Date())
            guard var r = liveRx, r.burst == burst else { return }
            var pcm = Data()
            for (offset, frame) in frames.enumerated() {
                let i = index + UInt32(offset)
                if let next = r.nextIndex {
                    guard i >= next else { continue }                     // late or duplicate
                    for _ in 0..<min(i - next, 25) { pcm += r.converter.convert(r.decoder.silence()) }  // lost
                }
                if let buffer = r.decoder.decode(frame) { pcm += r.converter.convert(buffer) }
                r.nextIndex = i + 1
            }
            liveRx = r
            let playback = onPlayback
            if !pcm.isEmpty { DispatchQueue.main.async { playback?(pcm) } }
        case .burstEnd:
            links[sender] = (endpoint, Date())
            if let packet = hello(for: contact, receipt: true) { transport.send(packet, to: endpoint) }
            if liveRx?.burst == burst {
                liveRx = nil
                processor.forgetBurst(sender: sender, burst: burst)
                self.processor = processor
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.status(.idle) }
            }
        default:
            links[sender] = (endpoint, Date())
        }
    }

    // MARK: - Receiving

    /// Fetches relayed bursts addressed to this user and plays them, oldest first.
    func fetchRelay() {
        queue.async { [self] in
            guard !fetching, let relay, let mailbox = sync?.relayMailbox else { return }
            fetching = true
            let tags = Relay.inboxTags(mailbox: mailbox)
            Task { [weak self] in
                let records = (try? await relay.fetch(tags: tags)) ?? []
                self?.queue.async {
                    guard let self else { return }
                    self.fetching = false
                    for record in records where !self.seenRecords.contains(record.name) {
                        self.seenRecords.insert(record.name)
                        self.play(record.payload)
                        Task { await relay.delete(recordName: record.name) }
                    }
                }
            }
        }
    }

    /// A silent push said a relayed message is waiting. Without the iPhone around, show a
    /// notification (the message plays when the app opens); records are left in place.
    func announceWaitingMessages(unlessPhoneAround phoneAround: Bool, done: @escaping () -> Void) {
        queue.async { [self] in
            guard !phoneAround, let relay, let mailbox = sync?.relayMailbox else { done(); return }
            let tags = Relay.inboxTags(mailbox: mailbox)
            Task { [weak self] in
                let records = (try? await relay.fetch(tags: tags)) ?? []
                self?.queue.async {
                    guard let self else { done(); return }
                    let fresh = records.filter { !self.seenRecords.contains($0.name) && !self.announced.contains($0.name) }
                    for record in fresh { self.announced.insert(record.name) }
                    guard !fresh.isEmpty else { done(); return }
                    let content = UNMutableNotificationContent()
                    content.title = "NXTPTT"
                    content.body = fresh.count == 1 ? "New voice message" : "\(fresh.count) new voice messages"
                    content.sound = .default
                    let request = UNNotificationRequest(identifier: "relay-\(fresh[0].name)", content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request) { _ in done() }
                }
            }
        }
    }

    private var announced: Set<String> = []

    private func play(_ payload: Data) {
        guard var processor, let sync, let packets = (try? Relay.decode(payload))?.compactMap(sync.unshield) else { return }
        var start: BurstStart?
        var talker = "NXTPTT"
        var frames: [UInt32: Data] = [:]
        var sender: SenderID?
        var burst: MessageID?
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets) else { continue }
            switch inbound.message {
            case .burstStart(let s):
                start = s
                sender = inbound.header.senderID
                burst = inbound.header.messageID
                let name = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? "NXTPTT"
                talker = inbound.channel.kind == .group ? "\(name) · \(inbound.channel.name)" : name
            case .voice(let index, let voiceFrames):
                for (offset, frame) in voiceFrames.enumerated() { frames[index + UInt32(offset)] = frame }
            default:
                break
            }
        }
        if let sender, let burst { processor.forgetBurst(sender: sender, burst: burst) }
        self.processor = processor
        guard let start, !frames.isEmpty,
              let decoder = VoiceCodecFactory.makeDecoder(codec: start.codec, sampleRate: start.sampleRate,
                                                          frameMilliseconds: start.frameMilliseconds),
              let output = PlaybackConverter(from: decoder.pcmFormat) else { return }
        status(.playing(talker))
        var pcm = Data()
        for index in (frames.keys.min() ?? 0)...(frames.keys.max() ?? 0) {
            let buffer = frames[index].flatMap { decoder.decode($0) } ?? decoder.silence()
            pcm += output.convert(buffer)
        }
        let playback = onPlayback
        DispatchQueue.main.async { playback?(pcm) }
        let seconds = Double(frames.count * Int(start.frameMilliseconds)) / 1000
        queue.asyncAfter(deadline: .now() + seconds + 0.3) { [weak self] in self?.status(.idle) }
    }

    private func status(_ status: Status) {
        let callback = onStatus
        DispatchQueue.main.async { callback?(status) }
    }
}

/// Watch microphone audio (Int16 16 kHz) → the voice codec's frames.
final class CaptureEncoder {
    private let encoder: VoiceEncoder
    private let inputFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private var fifo: [Float] = []

    init() {
        let encoder = VoiceCodecFactory.makeEncoder()
        let inputFormat = AudioFormats.int16Mono(sampleRate: 16_000)
        self.encoder = encoder
        self.inputFormat = inputFormat
        converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: encoder.pcmFormat) }
    }

    var codecID: VoiceCodecID { encoder.codecID }
    var sampleRate: Double { encoder.pcmFormat.sampleRate }

    /// Returns the frames completed by this chunk.
    func append(_ pcm: Data) -> [Data] {
        let count = pcm.count / 2
        guard count > 0, let inputFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let samples = input.int16ChannelData else { return [] }
        input.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                samples[0][i] = Int16(bitPattern: UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8)
            }
        }
        let ratio = encoder.pcmFormat.sampleRate / inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: encoder.pcmFormat,
                                            frameCapacity: AVAudioFrameCount(Double(count) * ratio) + 64) else { return [] }
        _ = converter.convertSupplyingOnce(input, into: output)
        if let channel = output.floatChannelData?[0] {
            fifo.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        var frames: [Data] = []
        let frameLength = Int(encoder.frameLength)
        while fifo.count >= frameLength {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: encoder.pcmFormat,
                                                frameCapacity: AVAudioFrameCount(frameLength)),
                  let channel = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(frameLength)
            for i in 0..<frameLength { channel[i] = fifo[i] }
            fifo.removeFirst(frameLength)
            if let encoded = encoder.encode(buffer) { frames.append(encoded) }
        }
        return frames
    }
}

/// Decoded audio (any format) → mono Int16 16 kHz for `WatchAudio.play`.
final class PlaybackConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from format: AVAudioFormat) {
        guard let out = AudioFormats.int16Mono(sampleRate: 16_000),
              let converter = AVAudioConverter(from: format, to: out) else { return nil }
        self.converter = converter
        outputFormat = out
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64)
        else { return Data() }
        _ = converter.convertSupplyingOnce(buffer, into: output)
        guard let samples = output.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }
}

/// The mirrored identity lives in the watch's Keychain, never in a plain file.
enum WatchSyncKeychain {
    private static let service = "app.eptt.watch"
    private static let account = "sync-v1"

    static func load() -> WatchSync? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(WatchSync.self, from: data)
    }

    static func save(_ sync: WatchSync) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = try? JSONEncoder().encode(sync) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
