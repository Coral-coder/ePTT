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

/// Everything the app persists besides private keys, as one JSON file in Application Support.
struct PersistedState: Codable {
    var settings = Settings()
    var contacts: [Contact] = []
    var channels: [Channel] = []
    /// Push tokens, kept so reachability is known on a cold launch before iOS re-delivers them.
    var pttToken: Data?
    var deviceToken: Data?
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
