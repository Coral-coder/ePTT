import Foundation
import EPTTCore
import EPTTCompat

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
        /// The watch app was closed: the phone takes back over.
        case handBack
    }
    static let enabled = "on"
    /// Seconds since 1970 of a claim (watch → phone: `claim`; phone → watch: `phoneClaim`).
    static let claimedAt = "at"
    /// Phone → watch (application context and messages): when the phone last took over.
    static let phoneClaim = "phoneClaim"
    /// Watch → phone (queued user info): the watch app closed at this time; the phone takes over.
    static let handBack = "handBack"

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
    /// One-time prekeys (protocol 2). Optional so older snapshots still decode.
    var oneTimeKeys: OneTimeKeyStore?
    /// The protocol each contact was last heard on (1: an older build; 2 is final).
    var contactProtocols: [IdentityID: UInt8]?
}

extension WatchSync {
    /// The local identity these keys belong to.
    var localIdentity: LocalIdentity? {
        try? LocalIdentity(signingSeed: signingSeed, keyAgreementSeed: keyAgreementSeed)
    }

    func keyAgreement(_ local: LocalIdentity) -> LocalKeyAgreement {
        let prekeys = self.prekeys, oneTime = self.oneTimeKeys ?? OneTimeKeyStore()
        return local.keyAgreement(prekeys: { prekeys }, oneTimeKeys: { oneTime })
    }

    /// The burst secret of our pairwise session with a sender at an epoch (PROTOCOL.md §5.3).
    var pairSecrets: PairSecretLookup {
        let contacts = self.contacts, channels = self.channels
        return { sender, epoch in
            guard let contact = contacts.first(where: { $0.senderID == sender }) else { return nil }
            return channels.first { $0.kind == .direct && $0.members == [contact.id] }?
                .session?.keys(forEpoch: epoch)?.burstSecret
        }
    }

    /// Every key an incoming packet might be shielded with (PROTOCOL.md §6.6).
    var shieldCandidates: [ChannelKeys] { channels.flatMap(\.shieldCandidates) }

    /// The inner packet of a shielded one, if it is for one of our channels.
    func unshield(_ wire: Data) -> Data? {
        PacketShield.unshield(wire, candidates: shieldCandidates)?.inner
    }

    /// Protocol 1, for contacts on an older build (PROTOCOL.md §10.1).
    func legacyLink() -> LegacyLink? {
        guard let local = localIdentity else { return nil }
        let prekeys = self.prekeys
        return try? LegacyLink(signingSeed: signingSeed, keyAgreementSeed: keyAgreementSeed) { id, publicKey in
            id == 0 ? try local.sharedSecret(withPublicKey: publicKey) : try prekeys.agreement(id: id, with: publicKey)
        }
    }

    /// A bare protocol-1 packet from one of our contacts not known to be on protocol 2 (so worth
    /// trying with `legacyLink`, and never mistaken for a talk-group request).
    func isLegacyFromContact(_ wire: Data) -> Bool {
        guard LegacyLink.looksLegacy(wire), let sender = LegacyLink.senderID(of: wire),
              let contact = contacts.first(where: { $0.senderID == sender }) else { return false }
        return contactProtocols?[contact.id] != 3   // 3: heard under a post-quantum epoch
    }

    /// Opens a relayed or pushed packet in either protocol. Nil if it isn't for us.
    func open(_ wire: Data, processor: inout PacketProcessor, legacy: inout LegacyLink?,
              maxAge: TimeInterval = Relay.lifetime) -> InboundPacket? {
        let channels = self.channels, contacts = self.contacts
        if let inner = unshield(wire) {
            return try? processor.process(inner, maxAge: maxAge,
                                          channelLookup: { id in channels.first { $0.id == id } },
                                          memberLookup: { id in contacts.first { $0.senderID == id }?.identity },
                                          pairSecret: pairSecrets)
        }
        guard isLegacyFromContact(wire), var link = legacy else { return nil }
        defer { legacy = link }
        return try? link.open(wire, maxAge: maxAge,
                              channelLookup: { id in channels.first { $0.id == id } },
                              identityLookup: { id in contacts.first { $0.id == id }?.identity })
    }
}
