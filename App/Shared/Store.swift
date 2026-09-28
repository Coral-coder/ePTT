import Foundation
import EPTTCore

/// User preferences.
struct Settings: Codable, Equatable {
    var displayName: String = ""
    /// Keep the app running in the background with an open audio session, instead of relying
    /// on PushToTalk wakes. Uses more battery; fine for ad-hoc builds (see docs/ARCHITECTURE.md).
    var alwaysListening = false
    var stunEnabled = true
    /// Extra candidates to advertise, e.g. an overlay-VPN host name ("me.tailnet.ts.net:47474").
    var staticCandidates: [String] = []
    var forwardAudioToWatch = false
    /// Leave messages in the iCloud relay for people who couldn't be reached directly.
    var relayEnabled = true
    /// Give the paired Apple Watch this identity so it can talk without the iPhone nearby.
    var standaloneWatch = true
    /// Use the 911 Hz chirp instead of the classic 1800 Hz one.
    var deepChirp = false
    /// Beep when the other side releases. Nextel didn't, so it's off by default.
    var rogerBeep = false
    var selectedChannel: ChannelID?

    var parsedStaticCandidates: [Candidate] {
        staticCandidates.compactMap(Settings.parseCandidate)
    }

    /// Parses "host:port", "1.2.3.4:port" or "[v6]:port".
    static func parseCandidate(_ text: String) -> Candidate? {
        let s = text.trimmingCharacters(in: .whitespaces)
        var host: Substring, portText: Substring
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            host = s[s.index(after: s.startIndex)..<close]
            portText = s[s.index(after: close)...].drop { $0 == ":" }
        } else if let colon = s.lastIndex(of: ":") {
            host = s[..<colon]
            portText = s[s.index(after: colon)...]
        } else {
            return nil
        }
        guard let port = UInt16(portText), port != 0, !host.isEmpty else { return nil }
        return Candidate(address: String(host), port: port) ?? .host(String(host), port: port)
    }
}

/// How a transmission reached (or failed to reach) someone.
enum Route: String, Codable {
    case nearby          // peer-to-peer Wi-Fi (AWDL) or Bluetooth
    case localNetwork    // same Wi-Fi / LAN
    case overlay         // an overlay VPN address (Tailscale and similar)
    case internet        // direct over the public internet
    case relay           // iCloud store-and-forward
    case failed

    var label: String {
        switch self {
        case .nearby: return "Nearby (peer-to-peer)"
        case .localNetwork: return "Local network"
        case .overlay: return "Overlay VPN"
        case .internet: return "Internet (direct)"
        case .relay: return "iCloud relay"
        case .failed: return "Not delivered"
        }
    }

    var symbol: String {
        switch self {
        case .nearby: return "antenna.radiowaves.left.and.right"
        case .localNetwork: return "wifi"
        case .overlay: return "network.badge.shield.half.filled"
        case .internet: return "globe"
        case .relay: return "icloud"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// One entry of the "Recent transfers" list.
struct TransferRecord: Codable, Identifiable {
    struct Leg: Codable, Hashable {
        var peer: String
        var route: Route
    }

    var id = UUID()
    var date: Date
    var outgoing: Bool
    var channel: String
    var seconds: Double
    var legs: [Leg]
}

/// Everything the app persists besides private keys, as one JSON file in Application Support.
struct PersistedState: Codable {
    var settings = Settings()
    var contacts: [Contact] = []
    var channels: [Channel] = []
    /// Push tokens, kept so reachability is known on a cold launch before iOS re-delivers them.
    var pttToken: Data?
    var deviceToken: Data?
    /// Secret relay mailbox shared with contacts (PROTOCOL.md §11).
    var relayMailbox: Data?
    /// Relay records we uploaded, with their expiry, so we can delete them.
    var relayUploads: [String: Date] = [:]
    /// Newest first, capped.
    var transfers: [TransferRecord] = []
}

enum Store {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("eptt-state.json")
    }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Readable after first unlock so a push can wake a locked phone and still load contacts.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// Tolerant decoding: fields added in later versions fall back to their defaults instead of
// making the whole saved state unreadable.
extension Settings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? d.displayName
        alwaysListening = try c.decodeIfPresent(Bool.self, forKey: .alwaysListening) ?? d.alwaysListening
        stunEnabled = try c.decodeIfPresent(Bool.self, forKey: .stunEnabled) ?? d.stunEnabled
        staticCandidates = try c.decodeIfPresent([String].self, forKey: .staticCandidates) ?? d.staticCandidates
        forwardAudioToWatch = try c.decodeIfPresent(Bool.self, forKey: .forwardAudioToWatch) ?? d.forwardAudioToWatch
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? d.relayEnabled
        standaloneWatch = try c.decodeIfPresent(Bool.self, forKey: .standaloneWatch) ?? d.standaloneWatch
        deepChirp = try c.decodeIfPresent(Bool.self, forKey: .deepChirp) ?? d.deepChirp
        rogerBeep = try c.decodeIfPresent(Bool.self, forKey: .rogerBeep) ?? d.rogerBeep
        selectedChannel = try c.decodeIfPresent(ChannelID.self, forKey: .selectedChannel)
    }
}

extension PersistedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        channels = try c.decodeIfPresent([Channel].self, forKey: .channels) ?? []
        pttToken = try c.decodeIfPresent(Data.self, forKey: .pttToken)
        deviceToken = try c.decodeIfPresent(Data.self, forKey: .deviceToken)
        relayMailbox = try c.decodeIfPresent(Data.self, forKey: .relayMailbox)
        relayUploads = try c.decodeIfPresent([String: Date].self, forKey: .relayUploads) ?? [:]
        transfers = try c.decodeIfPresent([TransferRecord].self, forKey: .transfers) ?? []
    }
}
