import Foundation

/// Keys and framing shared by the iPhone app and the watch app over WatchConnectivity.
enum WatchProtocol {
    // Watch → phone messages (dictionary).
    static let command = "cmd"
    static let channelID = "ch"
    enum Command: String {
        case press, release, select, sync
        case listenOnWatch = "listen"
    }
    static let enabled = "on"

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
