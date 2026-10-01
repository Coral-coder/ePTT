import Foundation
import EPTTCore
import EPTTLegacy

/// Talks protocol 1 (the classical protocol of builds before protocol 2) with contacts who
/// haven't updated yet. Everything in and out is in protocol-2 types, so the engine handles a
/// protocol-1 message exactly like any other; only the wire format and the cryptography differ.
///
/// Protocol 1 is classical: X25519 / ChaCha20-Poly1305 / HKDF-SHA-256, no post-quantum layer,
/// no packet shield, unsigned group packets. The engine only uses it for contacts it has never
/// seen speak protocol 2, and never again once it has (PROTOCOL.md §10.1).
public struct LegacyLink {
    private let local: EPTTLegacy.LocalIdentity
    private var processor: EPTTLegacy.PacketProcessor
    /// Protocol-1 direct channel keys (static X25519), by channel: one key agreement each.
    private var directKeys: [Data: EPTTLegacy.ChannelKeys] = [:]

    /// - Parameter agreement: X25519 with our static key (id 0) or a signed prekey, for opening
    ///   protocol-1 envelopes. (Protocol 1 has no one-time prekeys.)
    public init(signingSeed: Data, keyAgreementSeed: Data,
                agreement: @escaping (_ keyID: UInt32, _ peerPublicKey: Data) throws -> Data) throws {
        local = try EPTTLegacy.LocalIdentity(signingSeed: signingSeed, keyAgreementSeed: keyAgreementSeed)
        processor = EPTTLegacy.PacketProcessor(local: local, agreement: agreement)
    }

    /// Protocol-1 packets travel bare: version byte 1 and a 40-byte header in the clear.
    /// (A protocol-2 wire packet starts with a random nonce, so this is only a hint: the
    /// packet still has to authenticate.)
    public static func looksLegacy(_ wire: Data) -> Bool {
        wire.count >= 40 + 16 && wire.first == 1
    }

    // MARK: Receiving

    /// Opens a protocol-1 packet and returns it as protocol 2 would have.
    ///
    /// - Parameters:
    ///   - channelLookup: our (protocol-2) channel for an ID.
    ///   - memberLookup: a contact's identity for a sender ID.
    public mutating func open(_ packet: Data, now: Date = Date(), maxAge: TimeInterval,
                              channelLookup: (EPTTCore.ChannelID) -> EPTTCore.Channel?,
                              identityLookup: (EPTTCore.IdentityID) -> EPTTCore.PublicIdentity?) throws -> EPTTCore.InboundPacket {
        let local = self.local
        let inbound: EPTTLegacy.InboundPacket
        do {
            inbound = try processor.process(
            packet, now: now, maxAge: maxAge,
            channelLookup: { id in
                guard let v2ID = try? EPTTCore.ChannelID(bytes: id.bytes), let channel = channelLookup(v2ID) else { return nil }
                return Self.legacyChannel(channel, local: local, members: channel.members.compactMap(identityLookup))
            },
            memberLookup: { sender in
                // A sender ID is the first 8 bytes of the identity ID.
                guard let channel = (try? EPTTCore.ChannelID(bytes: Data(packet.dropFirst(4).prefix(16)))).flatMap(channelLookup)
                else { return nil }
                return channel.members.first { $0.bytes.prefix(8) == sender.bytes }.flatMap(identityLookup).flatMap(Self.legacy)
            })
        } catch let error as EPTTLegacy.InboundError {
            throw Self.convert(error)
        }
        return try convert(inbound, channelLookup: channelLookup)
    }

    public mutating func forgetBurst(sender: EPTTCore.SenderID, burst: EPTTCore.MessageID) {
        guard let s = try? EPTTLegacy.SenderID(bytes: sender.bytes), let b = try? EPTTLegacy.MessageID(bytes: burst.bytes)
        else { return }
        processor.forgetBurst(sender: s, burst: b)
    }

    // MARK: Sending

    /// Seals a control message (HELLO, CARD, WAKE, GROUP_LEAVE, bare CALL_ALERT) in protocol 1.
    /// The plaintext encodings are shared; protocol 1 ignores tags it doesn't know.
    public mutating func seal(_ type: EPTTCore.PacketType, plaintext: Data, channel: EPTTCore.Channel,
                              peer: EPTTCore.PublicIdentity?, messageID: EPTTCore.MessageID = .random()) throws -> Data {
        let keys = try sendingKeys(channel, peer: peer)
        guard let legacyType = EPTTLegacy.PacketType(rawValue: type.rawValue) else { throw LegacyError.unsupported }
        return try EPTTLegacy.PacketBuilder(local: local).seal(legacyType, plaintext: plaintext, keys: keys,
                                                               messageID: EPTTLegacy.MessageID(bytes: messageID.bytes))
    }

    /// A call alert, with its text sealed only by the protocol-1 channel key.
    public mutating func sealCallAlert(name: String, timestamp: UInt64, text: String?, channel: EPTTCore.Channel,
                                       peer: EPTTCore.PublicIdentity, messageID: EPTTCore.MessageID) throws -> Data {
        let alert = EPTTLegacy.CallAlert(name: name, timestamp: timestamp, text: text)
        return try seal(.callAlert, plaintext: alert.encoded, channel: channel, peer: peer, messageID: messageID)
    }

    /// A protocol-1 BURST_START for `recipients`, with the burst key it carries.
    public mutating func startBurst(channel: EPTTCore.Channel, peer: EPTTCore.PublicIdentity?, burstID: EPTTCore.MessageID,
                                    timestamp: UInt64, recipients: [(identity: EPTTCore.PublicIdentity, prekey: EPTTCore.SignedPrekey?)],
                                    codec: UInt8, sampleRate: UInt32, frameMilliseconds: UInt8,
                                    allowsReplay: Bool) throws -> (packet: Data, burstKey: Data) {
        let keys = try sendingKeys(channel, peer: peer)
        let targets = try recipients.map { r in
            EPTTLegacy.SealTarget(identity: try Self.legacy(r.identity)!,
                                  prekey: try r.prekey.map { try EPTTLegacy.SignedPrekey(encoded: $0.encoded) })
        }
        guard let codecID = EPTTLegacy.VoiceCodecID(rawValue: codec) else { throw LegacyError.unsupported }
        let id = try EPTTLegacy.MessageID(bytes: burstID.bytes)
        let burst = try EPTTLegacy.OutgoingBurst(identity: local, channelID: keys.channelID, burstID: id, timestamp: timestamp,
                                                 targets: targets, codec: codecID, sampleRate: sampleRate,
                                                 frameMilliseconds: frameMilliseconds, allowsReplay: allowsReplay)
        let packet = try EPTTLegacy.PacketBuilder(local: local).seal(.burstStart, plaintext: burst.start.encoded, keys: keys,
                                                                     messageID: id)
        return (packet, burst.burstKey)
    }

    /// VOICE or BURST_END under a protocol-1 burst key.
    public mutating func sealBurst(_ type: EPTTCore.PacketType, plaintext: Data, channel: EPTTCore.Channel,
                                   peer: EPTTCore.PublicIdentity?, burstID: EPTTCore.MessageID, burstKey: Data,
                                   seq: UInt32) throws -> Data {
        let keys = try sendingKeys(channel, peer: peer)
        guard let legacyType = EPTTLegacy.PacketType(rawValue: type.rawValue) else { throw LegacyError.unsupported }
        return try EPTTLegacy.PacketBuilder(local: local).sealBurst(legacyType, plaintext: plaintext, keys: keys,
                                                                    burstID: EPTTLegacy.MessageID(bytes: burstID.bytes),
                                                                    burstKey: burstKey, seq: seq)
    }

    /// A protocol-1 GROUP_INVITE on the direct channel with `peer`, sealed to their signed
    /// prekey (or static key).
    public mutating func sealInvite(_ invite: EPTTCore.GroupInvite, direct: EPTTCore.Channel, peer: EPTTCore.PublicIdentity,
                                    prekey: EPTTCore.SignedPrekey?, messageID: EPTTCore.MessageID = .random()) throws -> Data {
        let legacyInvite = EPTTLegacy.GroupInvite(
            timestamp: invite.timestamp, name: invite.name,
            keys: try EPTTLegacy.ChannelKeys(channelID: EPTTLegacy.ChannelID(bytes: invite.keys.channelID.bytes),
                                             epoch: invite.keys.epoch, key: invite.keys.key),
            memberCards: try invite.memberCards.map { try EPTTLegacy.ContactCard(encoded: $0.encoded) })
        let target = EPTTLegacy.SealTarget(identity: try Self.legacy(peer)!,
                                           prekey: try prekey.map { try EPTTLegacy.SignedPrekey(encoded: $0.encoded) })
        let id = try EPTTLegacy.MessageID(bytes: messageID.bytes)
        let plaintext = try legacyInvite.sealed(for: target, messageID: id)
        return try EPTTLegacy.PacketBuilder(local: local).seal(.groupInvite, plaintext: plaintext,
                                                               keys: try sendingKeys(direct, peer: peer), messageID: id)
    }

    // MARK: Conversion

    static func convert(_ error: EPTTLegacy.InboundError) -> EPTTCore.InboundError {
        switch error {
        case .malformed: return .malformed
        case .unknownChannel: return .unknownChannel
        case .unknownEpoch: return .unknownEpoch
        case .notAMember: return .notAMember
        case .ownPacket: return .ownPacket
        case .authenticationFailed: return .authenticationFailed
        case .staleTimestamp: return .staleTimestamp
        case .replay: return .replay
        case .badSignature: return .badSignature
        case .wrongChannelKind: return .wrongChannelKind
        case .unknownBurst: return .unknownBurst
        case .notARecipient: return .notARecipient
        }
    }

    /// The burst (message) ID of a protocol-1 packet, read from its clear header.
    public static func messageID(of packet: Data) -> EPTTCore.MessageID? {
        guard packet.count >= 40 else { return nil }
        return try? EPTTCore.MessageID(bytes: Data(packet[packet.startIndex + 28 ..< packet.startIndex + 36]))
    }

    /// The sender of a protocol-1 packet, read from its clear header.
    public static func senderID(of packet: Data) -> EPTTCore.SenderID? {
        guard packet.count >= 40 else { return nil }
        return try? EPTTCore.SenderID(bytes: Data(packet[packet.startIndex + 20 ..< packet.startIndex + 28]))
    }

    enum LegacyError: Error { case unsupported }

    static func legacy(_ identity: EPTTCore.PublicIdentity) -> EPTTLegacy.PublicIdentity? {
        try? EPTTLegacy.PublicIdentity(signingPublicKey: identity.signingPublicKey,
                                       keyAgreementPublicKey: identity.keyAgreementPublicKey)
    }

    /// Protocol-1 keys for a channel: a direct channel's come from the static keys (§5.1 of
    /// protocol 1), a talk group's are the group key itself.
    private mutating func sendingKeys(_ channel: EPTTCore.Channel, peer: EPTTCore.PublicIdentity?) throws -> EPTTLegacy.ChannelKeys {
        switch channel.kind {
        case .direct:
            if let hit = directKeys[channel.id.bytes] { return hit }
            guard let peer, let legacyPeer = Self.legacy(peer) else { throw LegacyError.unsupported }
            let keys = try EPTTLegacy.ChannelKeys.direct(local: local, peer: legacyPeer)
            guard keys.channelID.bytes == channel.id.bytes else { throw LegacyError.unsupported }
            directKeys[channel.id.bytes] = keys
            return keys
        case .group:
            return try EPTTLegacy.ChannelKeys(channelID: EPTTLegacy.ChannelID(bytes: channel.id.bytes),
                                              epoch: channel.keys.epoch, key: channel.keys.key)
        }
    }

    private static func legacyChannel(_ channel: EPTTCore.Channel, local: EPTTLegacy.LocalIdentity,
                                      members: [EPTTCore.PublicIdentity]) -> EPTTLegacy.Channel? {
        let memberIDs = channel.members.compactMap { try? EPTTLegacy.IdentityID(bytes: $0.bytes) }
        switch channel.kind {
        case .direct:
            guard let peer = members.first, let legacyPeer = legacy(peer),
                  let c = try? EPTTLegacy.Channel.direct(local: local, peer: legacyPeer, name: channel.name),
                  c.id.bytes == channel.id.bytes else { return nil }
            return c
        case .group:
            guard let id = try? EPTTLegacy.ChannelID(bytes: channel.id.bytes),
                  let keys = try? EPTTLegacy.ChannelKeys(channelID: id, epoch: channel.keys.epoch, key: channel.keys.key)
            else { return nil }
            var c = EPTTLegacy.Channel(kind: .group, name: channel.name, keys: keys, members: memberIDs)
            c.previousKeys = channel.previousKeys.flatMap {
                try? EPTTLegacy.ChannelKeys(channelID: id, epoch: $0.epoch, key: $0.key)
            }
            return c
        }
    }

    private func convert(_ inbound: EPTTLegacy.InboundPacket,
                         channelLookup: (EPTTCore.ChannelID) -> EPTTCore.Channel?) throws -> EPTTCore.InboundPacket {
        let h = inbound.header
        guard let type = EPTTCore.PacketType(rawValue: h.type.rawValue),
              let channelID = try? EPTTCore.ChannelID(bytes: h.channelID.bytes),
              let channel = channelLookup(channelID),
              let sender = try? EPTTCore.PublicIdentity(signingPublicKey: inbound.sender.signingPublicKey,
                                                         keyAgreementPublicKey: inbound.sender.keyAgreementPublicKey)
        else { throw LegacyError.unsupported }
        let header = EPTTCore.PacketHeader(type: type, epoch: h.epoch, channelID: channelID,
                                           senderID: try EPTTCore.SenderID(bytes: h.senderID.bytes),
                                           messageID: try EPTTCore.MessageID(bytes: h.messageID.bytes), seq: h.seq)
        let message: EPTTCore.InboundMessage
        switch inbound.message {
        case .hello(let m): message = .hello(try EPTTCore.Hello(decoding: m.encoded))
        case .burstStart(let m): message = .burstStart(try EPTTCore.BurstStart(decoding: m.encoded))
        case .voice(let index, let frames): message = .voice(firstFrameIndex: index, frames: frames)
        case .burstEnd(let m): message = .burstEnd(try EPTTCore.BurstEnd(decoding: m.encoded))
        case .callAlert(let m): message = .callAlert(EPTTCore.CallAlert(name: m.name, timestamp: m.timestamp, text: m.text))
        case .wake(let m): message = .wake(try EPTTCore.Wake(decoding: m.encoded))
        case .groupLeave(let m): message = .groupLeave(try EPTTCore.GroupLeave(decoding: m.encoded))
        case .card(let m): message = .card(try EPTTCore.ContactCard(encoded: m.encoded))
        case .groupInvite(let m):
            message = .groupInvite(EPTTCore.GroupInvite(
                timestamp: m.timestamp, name: m.name,
                keys: try EPTTCore.ChannelKeys(channelID: EPTTCore.ChannelID(bytes: m.keys.channelID.bytes),
                                               epoch: m.keys.epoch, key: m.keys.key),
                memberCards: try m.memberCards.map { try EPTTCore.ContactCard(encoded: $0.encoded) }))
        }
        return EPTTCore.InboundPacket(header: header, channel: channel, sender: sender, message: message, isLegacy: true)
    }
}
