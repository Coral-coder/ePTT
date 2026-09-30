import Foundation
import EPTTCore

/// Keys and framing shared by the iPhone app and the watch app over WatchConnectivity.
enum WatchProtocol {
    // Watch → phone messages (dictionary).
    static let command = "cmd"
    static let channelID = "ch"
    enum Command: String {
        case press, release, select, sync
        case listenOnWatch = "listen"
        /// The watch app was opened: the watch takes over (with `claimedAt`).
        case claim
    }
    static let enabled = "on"
    /// Seconds since 1970 of a claim (watch → phone: `claim`; phone → watch: `phoneClaim`).
    static let claimedAt = "at"
    /// Phone → watch (application context and messages): when the phone last took over.
    static let phoneClaim = "phoneClaim"

    // Phone → watch application context / messages.
    static let channels = "channels"      // [[String: String]] with keys "id" (hex) and "name"
    static let selected = "selected"      // hex channel ID
    static let state = "state"            // TalkState raw value
    static let talker = "talker"          // display name of the current talker
    static let listening = "listening"    // Bool: forward received audio to the watch

    enum TalkState: String {
        case idle, transmitting, receiving, busy, offline
    }

    // Audio travels as message data: one type byte, then mono Int16 little-endian PCM at 16 kHz.
    static let audioSampleRate: Double = 16_000
    static let audioFromWatch: UInt8 = 0x01
    static let audioToWatch: UInt8 = 0x02
}


extension WatchProtocol {
    /// userInfo key carrying an encoded `WatchSync` (phone → watch, via `transferUserInfo`).
    static let sync = "sync"
    /// userInfo key carrying the watch app's push token (watch → phone, via `transferUserInfo`).
    static let watchToken = "watchToken"
}

/// Everything the watch needs to act as this user when the iPhone is out of range.
///
/// It includes private keys, so it only ever travels over WatchConnectivity between a user's
/// own paired devices (encrypted by the OS), and the watch keeps it in its Keychain.
struct WatchSync: Codable, Equatable {
    var signingSeed: Data
    var keyAgreementSeed: Data
    var prekeys: PrekeyStore
    var displayName: String
    var contacts: [Contact]
    var channels: [Channel]
    var selectedChannel: ChannelID?
    var relayMailbox: Data?
    var pushKey: PushKey?
}
