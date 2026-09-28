import AVFoundation
import Foundation
import Security
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
        let prekeys = newSync.prekeys
        processor = PacketProcessor(local: local, agreement: local.keyAgreement(prekeys: { prekeys }))
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
                  let channel = sync.channels.first(where: { $0.id == channelID }) else { return false }
            let encoder = CaptureEncoder()
            let targets = channel.members.compactMap { id in sync.contacts.first { $0.id == id } }
                .map { SealTarget(identity: $0.identity, prekey: $0.reachability.prekey) }
            do {
                let burst = try OutgoingBurst(identity: identity, channelID: channel.id, timestamp: currentTimestamp(),
                                              targets: targets, codec: encoder.codecID,
                                              sampleRate: UInt32(encoder.sampleRate), frameMilliseconds: 20)
                let start = try PacketBuilder(local: identity).seal(.burstStart, plaintext: burst.start.encoded,
                                                                   keys: channel.keys, messageID: burst.burstID)
                recording = Recording(channel: channel, burst: burst, encoder: encoder, packets: [start])
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
            burstKey: r.burst.burstKey, seq: r.nextFrame) else { return }
        r.nextFrame += UInt32(frames.count)
        r.packets.append(packet)
    }

    /// Finishes the burst and leaves it in the relay for every member.
    func endBurst() {
        queue.async { [self] in
            guard var r = recording, let identity, let sync else { return }
            recording = nil
            if !r.pending.isEmpty { seal(r.pending, into: &r) }
            guard r.nextFrame > 0 else { status(.idle); return }
            let end = BurstEnd(timestamp: currentTimestamp(), frameCount: r.nextFrame)
            if let packet = try? PacketBuilder(local: identity).sealBurst(
                .burstEnd, plaintext: end.encoded, keys: r.channel.keys, burstID: r.burst.burstID,
                burstKey: r.burst.burstKey, seq: r.nextFrame) {
                r.packets.append(packet)
            }
            guard let relay, let payload = Relay.encode(packets: r.packets) else {
                status(.failed(relay == nil ? "iCloud unavailable" : "Too long"))
                return
            }
            let members = r.channel.members.compactMap { id in sync.contacts.first { $0.id == id } }
            let wakePacket = try? PacketBuilder(local: identity).seal(
                .wake, plaintext: Wake(name: sync.displayName, timestamp: currentTimestamp(), candidates: []).encoded,
                keys: r.channel.keys, messageID: r.burst.burstID)
            let apns = self.apns
            status(.sending)
            Task { [weak self] in
                var delivered = 0
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

    private func play(_ payload: Data) {
        guard var processor, let sync, let packets = try? Relay.decode(payload) else { return }
        var start: BurstStart?
        var talker = "Chirp"
        var frames: [UInt32: Data] = [:]
        var sender: SenderID?
        var burst: MessageID?
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity }) else { continue }
            switch inbound.message {
            case .burstStart(let s):
                start = s
                sender = inbound.header.senderID
                burst = inbound.header.messageID
                let name = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? "Chirp"
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
