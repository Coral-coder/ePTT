import AVFoundation
import Foundation
import Security
import EPTTCore

/// What lets the notification service extension play a relayed message while NXTPTT itself is
/// suspended, without a push key: iCloud notifies us of a new relay record, the extension opens
/// it with a copy of our keys, decodes it and hands it to iOS as the notification's sound.
///
/// The app writes the keys into a Keychain access group the extension shares; files (sounds and
/// the list of messages already played) live in the app group container.
enum RelayInbox {
    /// A notification sound can be at most 30 seconds long.
    static let maxSoundSeconds = 30.0

    // MARK: - Shared locations

    /// `group.<bundle id>` from Info.plist (`EPTTAppGroup`).
    static var appGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "EPTTAppGroup") as? String).flatMap { $0.hasPrefix("group.") ? $0 : nil }
    }

    static var container: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// iOS looks for notification sounds in the app group's Library/Sounds.
    static var soundsDirectory: URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("Library/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Keys for the extension

    private static let service = "app.eptt.inbox"
    private static let account = "snapshot-v1"

    /// `<team prefix><bundle id>.shared` from Info.plist (`EPTTKeychainGroup`); nil in builds
    /// without one (then the snapshot is simply not shared).
    private static var keychainGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "EPTTKeychainGroup") as? String,
              !group.hasPrefix("."), group.contains(".") else { return nil }
        return group
    }

    static func saveSnapshot(_ snapshot: WatchSync) {
        guard let group = keychainGroup else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        var item = base
        item[kSecValueData as String] = data
        // The extension runs while the phone is locked, after the first unlock since boot.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func loadSnapshot() -> WatchSync? {
        guard let group = keychainGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(WatchSync.self, from: data)
    }

    // MARK: - Messages already played by a notification

    struct Heard: Codable, Equatable {
        var record: String
        var talker: String
        var channel: String
        var seconds: Double
        var sound: String
        var date: Date
        /// Whether the app has recorded it in Activity yet.
        var logged = false
    }

    private static var ledgerURL: URL? { container?.appendingPathComponent("heard.json") }

    static func heard() -> [Heard] {
        guard let url = ledgerURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Heard].self, from: data)) ?? []
    }

    static func markHeard(_ entry: Heard) {
        let cutoff = Date().addingTimeInterval(-Relay.lifetime)
        var entries = heard().filter { $0.record != entry.record && $0.date > cutoff }
        entries.append(entry)
        write(entries)
    }

    /// The app is playing `record` itself; the extension should leave its notification silent.
    static func markPlayedByApp(record: String) {
        guard !heard().contains(where: { $0.record == record }) else { return }
        markHeard(.init(record: record, talker: "", channel: "", seconds: 0, sound: "", date: Date(), logged: true))
    }

    static func wasPlayed(record: String) -> Bool {
        heard().contains { $0.record == record }
    }

    static func markLogged(record: String) {
        var entries = heard()
        guard let index = entries.firstIndex(where: { $0.record == record }) else { return }
        entries[index].logged = true
        write(entries)
    }

    /// Forgets that a notification played `record`, so the app plays it (again) in full.
    static func forget(record: String) {
        let entries = heard()
        let remaining = entries.filter { $0.record != record }
        if remaining.count != entries.count { write(remaining) }
    }

    private static func write(_ entries: [Heard]) {
        guard let url = ledgerURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes notification sounds older than the relay lifetime.
    static func purgeOldSounds() {
        guard let dir = soundsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-Relay.lifetime)
        for file in files where file.lastPathComponent.hasPrefix("rx-") {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: - Do Not Disturb (shared with the notification extension)

    /// Whether we're on Do Not Disturb, and whose messages break through (sender IDs).
    struct QuietState: Codable, Equatable {
        var until: Date?
        var priority: [Data] = []

        func holds(_ sender: SenderID?, now: Date = Date()) -> Bool {
            guard let until, until > now else { return false }
            return !(sender.map { priority.contains($0.bytes) } ?? false)
        }
    }

    // MARK: - Watch hand-off

    private static var handedOffURL: URL? { container?.appendingPathComponent("handed-off") }

    /// The Apple Watch has taken over: the notification service extension then leaves relayed
    /// messages for the watch instead of playing them on the phone.
    static func setHandedOff(_ on: Bool) {
        guard let url = handedOffURL else { return }
        if on { try? Data().write(to: url) } else { try? FileManager.default.removeItem(at: url) }
    }

    static var isHandedOff: Bool {
        handedOffURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private static var quietURL: URL? { container?.appendingPathComponent("quiet.json") }

    static func saveQuiet(_ state: QuietState) {
        guard let url = quietURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadQuiet() -> QuietState {
        guard let url = quietURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(QuietState.self, from: data) else { return QuietState() }
        return state
    }

    // MARK: - Held messages (Do Not Disturb)

    /// A message received on Do Not Disturb, kept on this phone (never back in the relay) until it
    /// is played, or for a day at most.
    struct Held: Codable, Identifiable, Equatable {
        var id: String
        var date: Date
        var talker: String
        var channel: String
        var seconds: Double
        var source: LastReceived.Source
        var codec: UInt8 = 0
        var sampleRate: UInt32 = 0
        var frameMilliseconds: UInt8 = 0
    }

    static let heldLifetime: TimeInterval = 24 * 3600

    private static var heldDirectory: URL? {
        guard let dir = container?.appendingPathComponent("held", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func hold(_ held: Held, audio: Data) {
        guard let dir = heldDirectory, let meta = try? JSONEncoder().encode(held) else { return }
        try? audio.write(to: dir.appendingPathComponent(held.id + ".bin"),
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? meta.write(to: dir.appendingPathComponent(held.id + ".json"), options: .atomic)
    }

    /// Held messages, oldest first. Drops any older than a day.
    static func heldMessages(now: Date = Date()) -> [Held] {
        guard let dir = heldDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var held: [Held] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(Held.self, from: data) else { continue }
            if now.timeIntervalSince(item.date) > heldLifetime { removeHeld(item.id) } else { held.append(item) }
        }
        return held.sorted { $0.date < $1.date }
    }

    static func heldAudio(_ held: Held) -> Data? {
        heldDirectory.flatMap { try? Data(contentsOf: $0.appendingPathComponent(held.id + ".bin")) }
    }

    static func removeHeld(_ id: String) {
        guard let dir = heldDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".bin"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
    }

    // MARK: - The last message received (for replay)

    /// The last voice message received, by the app or by a notification. Only the latest one is
    /// kept, and its audio only if the talker allowed replay.
    struct LastReceived: Codable, Equatable {
        enum Source: String, Codable {
            /// `last-message.bin` holds the encoded frames the app played (see `encodeFrames`).
            case frames
            /// `last-message.bin` holds the sealed relay payload a notification played.
            case relay
        }
        var date: Date
        var talker: String
        var channel: String
        var seconds: Double
        var replayable: Bool
        var source: Source
        var codec: UInt8 = 0
        var sampleRate: UInt32 = 0
        var frameMilliseconds: UInt8 = 0
    }

    /// How long a replayable message can be replayed.
    static let replayLifetime: TimeInterval = 3600

    private static var lastInfoURL: URL? { container?.appendingPathComponent("last-message.json") }
    private static var lastDataURL: URL? { container?.appendingPathComponent("last-message.bin") }

    /// Records the newest message, replacing the previous one. `audio` is kept only if replayable.
    static func saveLastReceived(_ info: LastReceived, audio: Data?) {
        guard let infoURL = lastInfoURL, let dataURL = lastDataURL else { return }
        try? FileManager.default.removeItem(at: dataURL)
        if info.replayable, let audio {
            try? audio.write(to: dataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: infoURL, options: .atomic) }
    }

    /// The last message's details if it can be replayed, without reading its audio (cheap).
    static func replayableInfo(now: Date = Date()) -> LastReceived? {
        guard let infoURL = lastInfoURL, let dataURL = lastDataURL,
              let raw = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(LastReceived.self, from: raw),
              info.replayable, now.timeIntervalSince(info.date) < replayLifetime,
              FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
        return info
    }

    /// The last message, if it is replayable, less than an hour old and its audio is still there.
    static func replayableLast(now: Date = Date()) -> (info: LastReceived, audio: Data)? {
        guard let infoURL = lastInfoURL, let dataURL = lastDataURL,
              let raw = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(LastReceived.self, from: raw) else { return nil }
        guard info.replayable, now.timeIntervalSince(info.date) < replayLifetime else {
            if now.timeIntervalSince(info.date) >= replayLifetime { try? FileManager.default.removeItem(at: dataURL) }
            return nil
        }
        guard let audio = try? Data(contentsOf: dataURL) else { return nil }
        return (info, audio)
    }

    /// Frames as `len: u16` + bytes each; 0xFFFF marks a lost frame.
    static func encodeFrames(_ frames: [Data?]) -> Data {
        var out = Data()
        for frame in frames {
            let length = frame.map { UInt16(clamping: $0.count) } ?? 0xFFFF
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
            if let frame { out.append(frame.prefix(0xFFFE)) }
        }
        return out
    }

    static func decodeFrames(_ data: Data) -> [Data?] {
        let bytes = [UInt8](data)
        var frames: [Data?] = []
        var i = 0
        while i + 2 <= bytes.count {
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
            if length == 0xFFFF { frames.append(nil); continue }
            guard i + length <= bytes.count else { break }
            frames.append(Data(bytes[i..<(i + length)]))
            i += length
        }
        return frames
    }

    // MARK: - Opening a relayed burst

    struct Message {
        var talker: String
        var channel: String
        var seconds: Double
        /// The talker allowed recipients to replay it.
        var allowsReplay = false
        var sender: SenderID?
        /// Decoded audio, in the decoder's PCM format.
        var buffers: [AVAudioPCMBuffer]
        var format: AVAudioFormat
    }

    /// Opens a relay payload with the mirrored keys. Nil if it isn't for us or can't be decoded.
    /// Decodes at most `maxSeconds` of audio (the extension has little memory); `seconds` is
    /// still the full length.
    static func open(_ payload: Data, with sync: WatchSync, maxSeconds: Double = maxSoundSeconds) -> Message? {
        guard let local = try? LocalIdentity(signingSeed: sync.signingSeed, keyAgreementSeed: sync.keyAgreementSeed),
              let packets = (try? Relay.decode(payload))?.compactMap(sync.unshield) else { return nil }
        var processor = PacketProcessor(local: local, agreement: sync.keyAgreement(local))
        var start: BurstStart?
        var talker = "NXTPTT"
        var sender: SenderID?
        var channelName = ""
        var frames: [UInt32: Data] = [:]
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets) else { continue }
            if let keyID = inbound.openedKeyID, OneTimeKeyStore.isOneTime(keyID) { noteOneTimeKeyUsed(keyID) }
            switch inbound.message {
            case .burstStart(let s):
                start = s
                talker = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? "NXTPTT"
                sender = inbound.header.senderID
                channelName = inbound.channel.kind == .group ? inbound.channel.name : talker
            case .voice(let index, let voiceFrames):
                for (offset, frame) in voiceFrames.enumerated() { frames[index + UInt32(offset)] = frame }
            default:
                break
            }
        }
        guard let start, let first = frames.keys.min(), let last = frames.keys.max(),
              let decoder = VoiceCodecFactory.makeDecoder(codec: start.codec, sampleRate: start.sampleRate,
                                                          frameMilliseconds: start.frameMilliseconds)
        else { return nil }
        var buffers: [AVAudioPCMBuffer] = []
        let frameSeconds = Double(start.frameMilliseconds == 0 ? 20 : start.frameMilliseconds) / 1000
        let wanted = maxSeconds / frameSeconds
        let decodeLast = wanted >= Double(last - first) + 1 ? last : first + UInt32(max(1, wanted)) - 1
        for index in first...decodeLast {
            buffers.append(frames[index].flatMap { decoder.decode($0) } ?? decoder.silence())
        }
        let seconds = Double(Int(last - first) + 1) * frameSeconds
        return Message(talker: talker, channel: channelName, seconds: seconds, allowsReplay: start.allowsReplay, sender: sender,
                       buffers: buffers, format: decoder.pcmFormat)
    }

    /// A relayed call alert (a page, not audio): who sent it and any text. Nil if the payload
    /// isn't a call alert for us.
    static func callAlert(in payload: Data, with sync: WatchSync) -> (name: String, text: String?, sender: SenderID)? {
        guard let packets = try? Relay.decode(payload) else { return nil }
        return callAlert(packets: packets, with: sync)   // shielded; unshielded below
    }

    /// The same, for shielded packets (e.g. a call alert that arrived as a push).
    static func callAlert(packets wire: [Data], with sync: WatchSync) -> (name: String, text: String?, sender: SenderID)? {
        guard let local = try? LocalIdentity(signingSeed: sync.signingSeed, keyAgreementSeed: sync.keyAgreementSeed)
        else { return nil }
        let packets = wire.compactMap(sync.unshield)
        var processor = PacketProcessor(local: local, agreement: sync.keyAgreement(local))
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets),
                  case .callAlert(let alert) = inbound.message else { continue }
            if let keyID = inbound.openedKeyID, OneTimeKeyStore.isOneTime(keyID) { noteOneTimeKeyUsed(keyID) }
            let name = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? alert.name
            return (name, alert.text, inbound.header.senderID)
        }
        return nil
    }

    /// The name on a relayed CARD message (contact details after face-to-face pairing), if that's
    /// what the payload is.
    // MARK: - Relayed bursts already played (replay protection)

    /// Someone could copy a relay record and post it again (under a new name) to replay an old
    /// message. Each burst or call alert played from the relay is remembered for a day, with the
    /// record that carried it; the same message in a different record is a replay. Shared by the
    /// app and the notification extension.
    private static var relayedURL: URL? { container?.appendingPathComponent("relayed-bursts.json") }

    private struct RelayedEntry: Codable {
        var record: String
        var date: Date
    }

    private static func relayedIDs(_ packets: [Data]) -> [String] {
        packets.compactMap { packet in
            guard let header = try? PacketHeader(packet: packet),
                  header.type == .burstStart || header.type == .callAlert else { return nil }
            return (header.senderID.bytes + header.messageID.bytes).base64EncodedString()
        }
    }

    private static func loadRelayed() -> [String: RelayedEntry] {
        guard let url = relayedURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: RelayedEntry].self, from: data)) ?? [:]
    }

    /// True when these packets were already played from a *different* relay record.
    static func isReplayedCopy(_ packets: [Data], record: String) -> Bool {
        let seen = loadRelayed()
        return relayedIDs(packets).contains { id in seen[id].map { $0.record != record } ?? false }
    }

    /// Call once the message authenticated and played (or was held).
    static func markRelayed(_ packets: [Data], record: String) {
        let ids = relayedIDs(packets)
        guard !ids.isEmpty, let url = relayedURL else { return }
        let cutoff = Date().addingTimeInterval(-(Relay.lifetime + 3600))
        var seen = loadRelayed().filter { $0.value.date > cutoff }
        for id in ids where seen[id] == nil { seen[id] = RelayedEntry(record: record, date: Date()) }
        if seen.count > 1000 {
            for (key, _) in seen.sorted(by: { $0.value.date < $1.value.date }).prefix(seen.count - 1000) { seen[key] = nil }
        }
        if let data = try? JSONEncoder().encode(seen) { try? data.write(to: url, options: .atomic) }
    }

    private static var pushedURL: URL? { container?.appendingPathComponent("pushed-packets.json") }

    /// Keeps a packet that arrived in a push (a request to join one of our talk groups) for the
    /// app, which handles it the next time it runs.
    static func keepPushed(_ packet: Data) {
        guard let url = pushedURL else { return }
        var packets = pushedPackets()
        guard !packets.contains(packet) else { return }
        packets = Array((packets + [packet]).suffix(20))
        if let data = try? JSONEncoder().encode(packets) { try? data.write(to: url, options: .atomic) }
    }

    /// The kept packets, removed from the store.
    static func takePushed() -> [Data] {
        let packets = pushedPackets()
        if !packets.isEmpty, let url = pushedURL { try? FileManager.default.removeItem(at: url) }
        return packets
    }

    private static func pushedPackets() -> [Data] {
        guard let url = pushedURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Data].self, from: data)) ?? []
    }

    /// A request to join one of our talk groups (someone scanned our group QR code). The app
    /// adds them when it next fetches the relay; the extension can only say so.
    static func containsJoinRequest(_ payload: Data, with sync: WatchSync?) -> Bool {
        guard let packets = try? Relay.decode(payload) else { return false }
        // Join requests are shielded with a join code's key, which the snapshot doesn't carry;
        // anything nothing of ours opens is reported as a possible request.
        guard let sync else { return true }
        return packets.contains { sync.unshield($0) == nil }
    }

    // MARK: - One-time keys used here (the app deletes them)

    private static var usedKeysURL: URL? { container?.appendingPathComponent("used-one-time-keys.json") }

    /// A one-time prekey opened a message here; the app deletes its private half on its next run.
    static func noteOneTimeKeyUsed(_ id: UInt32) {
        guard let url = usedKeysURL else { return }
        var ids = (try? JSONDecoder().decode([UInt32].self, from: Data(contentsOf: url))) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        if let data = try? JSONEncoder().encode(ids) { try? data.write(to: url, options: .atomic) }
    }

    /// The one-time keys used since last asked, cleared.
    static func takeUsedOneTimeKeys() -> [UInt32] {
        guard let url = usedKeysURL, let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return (try? JSONDecoder().decode([UInt32].self, from: data)) ?? []
    }

    /// The talk group a relayed GROUP_INVITE adds us to, and who sent it.
    static func groupInvite(in payload: Data, with sync: WatchSync) -> (group: String, from: String)? {
        guard let local = try? LocalIdentity(signingSeed: sync.signingSeed, keyAgreementSeed: sync.keyAgreementSeed),
              let packets = (try? Relay.decode(payload))?.compactMap(sync.unshield) else { return nil }
        var processor = PacketProcessor(local: local, agreement: sync.keyAgreement(local))
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets),
                  case .groupInvite(let invite) = inbound.message else { continue }
            let from = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? "Someone"
            return (invite.name, from)
        }
        return nil
    }

    static func cardSender(in payload: Data, with sync: WatchSync) -> String? {
        guard let local = try? LocalIdentity(signingSeed: sync.signingSeed, keyAgreementSeed: sync.keyAgreementSeed),
              let packets = (try? Relay.decode(payload))?.compactMap(sync.unshield) else { return nil }
        var processor = PacketProcessor(local: local, agreement: sync.keyAgreement(local))
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity },
                pairSecret: sync.pairSecrets),
                  case .card(let card) = inbound.message else { continue }
            return card.name
        }
        return nil
    }

    /// The four-beep call alert as a notification sound. Returns the file name.
    static func writeCallAlertSound() -> String? {
        guard let dir = soundsDirectory, let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        else { return nil }
        let file = "call-alert.caf"
        let url = dir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) { return file }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            try output.write(from: ToneSynth.buffer(for: .callAlert, format: format))
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return file
    }

    /// Writes up to `maxSoundSeconds` of the message as a 16-bit CAF in the shared Sounds
    /// folder, where iOS can play it as a notification sound. Returns the file name.
    static func writeSound(_ message: Message, name: String) -> String? {
        guard let dir = soundsDirectory else { return nil }
        let file = "rx-\(name).caf"
        let url = dir.appendingPathComponent(file)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: message.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: message.format.commonFormat,
                                         interleaved: message.format.isInterleaved)
            let limit = AVAudioFramePosition(maxSoundSeconds * message.format.sampleRate)
            // The Nextel receive tone first, then the voice.
            try output.write(from: ToneSynth.buffer(for: .incoming, format: message.format))
            for buffer in message.buffers where output.length < limit {
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return file
    }
}
