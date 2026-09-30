import Foundation
import EPTTCore

/// User preferences.
struct Settings: Codable, Equatable {
    var displayName: String = ""
    /// Whether the user chose `displayName` (onboarding or Settings). Until then onboarding shows.
    var nameConfirmed = false
    var stunEnabled = true
    /// Extra candidates to advertise, e.g. an overlay-VPN host name ("me.tailnet.ts.net:47474").
    var staticCandidates: [String] = []
    /// Forward received audio to the watch app (when it is open). On by default; stored under a new
    /// key, so the old default-off setting ("forwardAudioToWatch") no longer applies.
    var playOnWatch = true
    /// Leave messages in the iCloud relay for people who couldn't be reached directly.
    var relayEnabled = true
    /// Give the paired Apple Watch this identity so it can talk without the iPhone nearby.
    var standaloneWatch = true
    /// Use the 911 Hz chirp instead of the classic 1800 Hz one.
    var deepChirp = false
    /// The talk screen's little wave follows the real audio (sent or heard). Off: the animation.
    var liveWaveform = false
    /// Beep when the other side releases. Nextel didn't, so it's off by default.
    var rogerBeep = false
    /// Mark what we send as replayable: recipients may play it again for an hour.
    var allowReplay = false
    /// Do Not Disturb until this moment (`distantFuture`: until turned off); nil when off.
    /// Messages are held on the phone instead of played, except from priority contacts.
    var quietUntil: Date?
    /// Contacts whose messages and call alerts break through Do Not Disturb.
    var priorityContacts: [IdentityID] = []
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

    /// Short form for status lines: "WI-FI", "BLUETOOTH / PEER-TO-PEER", …
    var shortLabel: String {
        switch self {
        case .nearby: return "Nearby"
        case .localNetwork: return "Wi-Fi"
        case .overlay: return "VPN"
        case .internet: return "Internet"
        case .relay: return "iCloud relay"
        case .failed: return "Failed"
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
        /// Why a failed leg failed, in plain words.
        var reason: String? = nil
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
    /// Talk-group QR codes we handed out (encoded `GroupJoinCode`s), until they expire.
    var joinCodes: [Data] = []
    /// Contacts who told us (HELLO) they're on Do Not Disturb, and whether we break through.
    var peerQuiet: [PeerQuiet] = []
    /// The paired Apple Watch app's push token, shared with contacts (PROTOCOL.md §11).
    var watchToken: Data?
    /// The watch took over (its app was opened): this phone stays quiet until its app is opened.
    var watchPrimary = false
    /// When this phone last took over; a watch claim older than this is stale.
    var lastPhoneClaim: Date?
}

struct PeerQuiet: Codable, Equatable {
    var id: IdentityID
    var breaksThrough: Bool
}

enum Store {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("eptt-state.json")
    }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting it with an empty state.
            let backup = url.deletingLastPathComponent().appendingPathComponent("eptt-state.unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return PersistedState()
        }
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
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? d.displayName
        nameConfirmed = (try? c.decodeIfPresent(Bool.self, forKey: .nameConfirmed)) ?? d.nameConfirmed
        stunEnabled = try c.decodeIfPresent(Bool.self, forKey: .stunEnabled) ?? d.stunEnabled
        staticCandidates = try c.decodeIfPresent([String].self, forKey: .staticCandidates) ?? d.staticCandidates
        playOnWatch = try c.decodeIfPresent(Bool.self, forKey: .playOnWatch) ?? d.playOnWatch
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? d.relayEnabled
        standaloneWatch = try c.decodeIfPresent(Bool.self, forKey: .standaloneWatch) ?? d.standaloneWatch
        deepChirp = try c.decodeIfPresent(Bool.self, forKey: .deepChirp) ?? d.deepChirp
        rogerBeep = try c.decodeIfPresent(Bool.self, forKey: .rogerBeep) ?? d.rogerBeep
        liveWaveform = (try? c.decodeIfPresent(Bool.self, forKey: .liveWaveform)) ?? d.liveWaveform
        allowReplay = (try? c.decodeIfPresent(Bool.self, forKey: .allowReplay)) ?? d.allowReplay
        quietUntil = try? c.decodeIfPresent(Date.self, forKey: .quietUntil)
        priorityContacts = (try? c.decodeIfPresent([IdentityID].self, forKey: .priorityContacts)) ?? []
        selectedChannel = try c.decodeIfPresent(ChannelID.self, forKey: .selectedChannel)
    }
}

extension PersistedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Field by field, and element by element for lists: one unreadable entry must never cost
        // the user their contacts or name.
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
        contacts = (try? c.decodeIfPresent(Lossy<Contact>.self, forKey: .contacts))?.items ?? []
        channels = (try? c.decodeIfPresent(Lossy<Channel>.self, forKey: .channels))?.items ?? []
        pttToken = try? c.decodeIfPresent(Data.self, forKey: .pttToken)
        deviceToken = try? c.decodeIfPresent(Data.self, forKey: .deviceToken)
        relayMailbox = try? c.decodeIfPresent(Data.self, forKey: .relayMailbox)
        watchToken = try? c.decodeIfPresent(Data.self, forKey: .watchToken)
        watchPrimary = (try? c.decodeIfPresent(Bool.self, forKey: .watchPrimary)) ?? false
        lastPhoneClaim = try? c.decodeIfPresent(Date.self, forKey: .lastPhoneClaim)
        relayUploads = (try? c.decodeIfPresent([String: Date].self, forKey: .relayUploads)) ?? [:]
        transfers = (try? c.decodeIfPresent(Lossy<TransferRecord>.self, forKey: .transfers))?.items ?? []
        joinCodes = (try? c.decodeIfPresent([Data].self, forKey: .joinCodes)) ?? []
        peerQuiet = (try? c.decodeIfPresent([PeerQuiet].self, forKey: .peerQuiet)) ?? []
    }
}

/// Decodes an array, skipping elements that don't decode instead of failing the whole array.
private struct Lossy<Element: Decodable>: Decodable {
    var items: [Element] = []

    /// Consumes one element of any shape, so the loop always moves on.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
    }
}
