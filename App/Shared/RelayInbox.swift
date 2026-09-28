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

    // MARK: - Opening a relayed burst

    struct Message {
        var talker: String
        var channel: String
        var seconds: Double
        /// Decoded audio, in the decoder's PCM format.
        var buffers: [AVAudioPCMBuffer]
        var format: AVAudioFormat
    }

    /// Opens a relay payload with the mirrored keys. Nil if it isn't for us or can't be decoded.
    /// Decodes at most `maxSeconds` of audio (the extension has little memory); `seconds` is
    /// still the full length.
    static func open(_ payload: Data, with sync: WatchSync, maxSeconds: Double = maxSoundSeconds) -> Message? {
        guard let local = try? LocalIdentity(signingSeed: sync.signingSeed, keyAgreementSeed: sync.keyAgreementSeed),
              let packets = try? Relay.decode(payload) else { return nil }
        let prekeys = sync.prekeys
        var processor = PacketProcessor(local: local, agreement: local.keyAgreement(prekeys: { prekeys }))
        var start: BurstStart?
        var talker = "NXTPTT"
        var channelName = ""
        var frames: [UInt32: Data] = [:]
        for packet in packets {
            guard let inbound = try? processor.process(
                packet, maxAge: Relay.lifetime,
                channelLookup: { id in sync.channels.first { $0.id == id } },
                memberLookup: { id in sync.contacts.first { $0.senderID == id }?.identity }) else { continue }
            switch inbound.message {
            case .burstStart(let s):
                start = s
                talker = sync.contacts.first { $0.senderID == inbound.header.senderID }?.name ?? "NXTPTT"
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
        let decodeLast = min(last, first + UInt32(max(1, maxSeconds / frameSeconds)) - 1)
        for index in first...decodeLast {
            buffers.append(frames[index].flatMap { decoder.decode($0) } ?? decoder.silence())
        }
        let seconds = Double(Int(last - first) + 1) * frameSeconds
        return Message(talker: talker, channel: channelName, seconds: seconds, buffers: buffers, format: decoder.pcmFormat)
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
