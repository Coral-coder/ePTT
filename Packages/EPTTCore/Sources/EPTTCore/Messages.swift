import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Milliseconds since the Unix epoch.
public func currentTimestamp(_ date: Date = Date()) -> UInt64 {
    UInt64(max(0, date.timeIntervalSince1970 * 1000))
}

/// HELLO (0x01): identity refresh, reachability and keep-alive on a direct channel.
public struct Hello: Equatable {
    public static let replyRequested: UInt8 = 0x01
    /// The sender is on Do Not Disturb: their phone holds messages instead of playing them.
    public static let doNotDisturb: UInt8 = 0x02
    /// Sent with `doNotDisturb` to a contact the sender marked as priority: you break through.
    public static let breaksThrough: UInt8 = 0x04
    /// The sender's app is going to the background: stop treating it as live and reach it by
    /// push or relay until it says hello again.
    public static let away: UInt8 = 0x08
    /// The sender sends delivery receipts (0x20), so a talker can wait for them.
    public static let sendsReceipts: UInt8 = 0x10
    /// This HELLO is a receipt for a burst just heard (its start or its end).
    public static let receipt: UInt8 = 0x20

    public var name: String
    public var timestamp: UInt64
    public var reachability: Reachability
    public var flags: UInt8
    /// How many of the recipient's one-time prekeys the sender still holds (so the recipient
    /// knows when to hand out more; PROTOCOL.md §3.2).
    public var heldOneTimeKeys: UInt16?

    public init(name: String, timestamp: UInt64, reachability: Reachability, flags: UInt8 = 0,
                heldOneTimeKeys: UInt16? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.reachability = reachability
        self.flags = flags
        self.heldOneTimeKeys = heldOneTimeKeys
    }

    public var wantsReply: Bool { flags & Hello.replyRequested != 0 }
    public var isDoNotDisturb: Bool { flags & Hello.doNotDisturb != 0 }
    public var recipientBreaksThrough: Bool { flags & Hello.breaksThrough != 0 }
    public var isAway: Bool { flags & Hello.away != 0 }
    public var sendsReceipts: Bool { flags & Hello.sendsReceipts != 0 }
    public var isReceipt: Bool { flags & Hello.receipt != 0 }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        reachability.add(to: &b)
        b.add(.flags, integer: flags)
        if let heldOneTimeKeys { b.add(.heldOneTimeKeys, integer: heldOneTimeKeys) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
        reachability = try Reachability(fields: f)
        flags = try f.uint(.flags) ?? 0
        heldOneTimeKeys = try f.uint(.heldOneTimeKeys)
    }
}

public enum VoiceCodecID: UInt8, Codable {
    case opus = 1
    case pcm16 = 2
}

/// BURST_START (0x02): opens a signed transmission and carries its per-recipient key envelopes.
public struct BurstStart: Equatable {
    public var timestamp: UInt64
    public var codec: VoiceCodecID
    public var sampleRate: UInt32
    public var frameMilliseconds: UInt8
    public var signature: Data
    /// One-time X25519 public key for this burst's envelopes.
    public var ephemeralPublicKey: Data
    /// The burst key wrapped for each recipient (PROTOCOL.md §6.2).
    public var envelopes: [Data]
    /// The talker lets recipients replay this message (flags bit 0; PROTOCOL.md §6.1).
    public var allowsReplay: Bool

    public init(timestamp: UInt64, codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8, signature: Data,
                ephemeralPublicKey: Data, envelopes: [Data], allowsReplay: Bool = false) {
        self.allowsReplay = allowsReplay
        self.timestamp = timestamp
        self.codec = codec
        self.sampleRate = sampleRate
        self.frameMilliseconds = frameMilliseconds
        self.signature = signature
        self.ephemeralPublicKey = ephemeralPublicKey
        self.envelopes = envelopes
    }

    /// Covers everything in the body, so no one holding the channel key (another group member)
    /// can re-seal it with different audio parameters or replay permission (PROTOCOL.md §6.1).
    public static func signatureInput(channelID: ChannelID, senderID: SenderID, burstID: MessageID,
                                      timestamp: UInt64, ephemeralPublicKey: Data, envelopes: [Data],
                                      codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8,
                                      allowsReplay: Bool) -> Data {
        var d = Primitives.v2("burst-start")
        d.append(channelID.bytes)
        d.append(senderID.bytes)
        d.append(burstID.bytes)
        d.appendBE(timestamp)
        d.append(ephemeralPublicKey)
        d.append(Primitives.sha256(envelopes.reduce(Data(), +)))
        d.append(codec.rawValue)
        d.appendBE(sampleRate)
        d.append(frameMilliseconds)
        d.append(allowsReplay ? 1 : 0)
        return d
    }

    /// Builds and signs a BURST_START for the local identity.
    public static func signed(by identity: LocalIdentity, channelID: ChannelID, burstID: MessageID, timestamp: UInt64,
                              ephemeralPublicKey: Data, envelopes: [Data],
                              codec: VoiceCodecID = .opus, sampleRate: UInt32 = 48_000,
                              frameMilliseconds: UInt8 = 20, allowsReplay: Bool = false) throws -> BurstStart {
        let input = signatureInput(channelID: channelID, senderID: identity.senderID, burstID: burstID,
                                   timestamp: timestamp, ephemeralPublicKey: ephemeralPublicKey, envelopes: envelopes,
                                   codec: codec, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds,
                                   allowsReplay: allowsReplay)
        return BurstStart(timestamp: timestamp, codec: codec, sampleRate: sampleRate,
                          frameMilliseconds: frameMilliseconds, signature: try identity.sign(input),
                          ephemeralPublicKey: ephemeralPublicKey, envelopes: envelopes, allowsReplay: allowsReplay)
    }

    public func verify(sender: PublicIdentity, channelID: ChannelID, burstID: MessageID) -> Bool {
        sender.isValidSignature(signature, for: BurstStart.signatureInput(
            channelID: channelID, senderID: sender.senderID, burstID: burstID, timestamp: timestamp,
            ephemeralPublicKey: ephemeralPublicKey, envelopes: envelopes, codec: codec, sampleRate: sampleRate,
            frameMilliseconds: frameMilliseconds, allowsReplay: allowsReplay))
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.codec, integer: codec.rawValue)
        b.add(.sampleRate, integer: sampleRate)
        b.add(.frameMilliseconds, integer: frameMilliseconds)
        b.add(.signature, signature)
        b.add(.ephemeralKey, ephemeralPublicKey)
        for envelope in envelopes { b.add(.envelope, envelope) }
        if allowsReplay { b.add(.flags, integer: UInt8(1)) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        guard let codec = VoiceCodecID(rawValue: try f.requireUInt(.codec)) else {
            throw DecodingError.invalid("codec")
        }
        self.codec = codec
        sampleRate = try f.requireUInt(.sampleRate)
        frameMilliseconds = try f.requireUInt(.frameMilliseconds)
        signature = try f.require(.signature)
        ephemeralPublicKey = try f.require(.ephemeralKey)
        envelopes = f.all(.envelope)
        allowsReplay = (f.first(.flags)?.last ?? 0) & 1 != 0
        guard ephemeralPublicKey.count == 32, !envelopes.isEmpty else { throw DecodingError.invalid("burst keying") }
    }
}

/// VOICE (0x03) body: consecutive encoded frames; the header's seq is the first frame's index.
public enum VoiceBody {
    public static func encode(_ frames: [Data]) -> Data {
        precondition(frames.count <= 255)
        var out = Data([UInt8(frames.count)])
        for frame in frames {
            out.appendBE(UInt16(frame.count))
            out.append(frame)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> [Data] {
        var reader = ByteReader(data)
        let count = try reader.readUInt(UInt8.self)
        var frames: [Data] = []
        for _ in 0..<count {
            let length = try reader.readUInt(UInt16.self)
            frames.append(try reader.read(Int(length)))
        }
        guard reader.isAtEnd else { throw DecodingError.invalid("voice trailing bytes") }
        return frames
    }
}

/// BURST_END (0x04).
public struct BurstEnd: Equatable {
    public var timestamp: UInt64
    public var frameCount: UInt32

    public init(timestamp: UInt64, frameCount: UInt32) {
        self.timestamp = timestamp
        self.frameCount = frameCount
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.frameCount, integer: frameCount)
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        frameCount = try f.requireUInt(.frameCount)
    }
}

/// CALL_ALERT (0x05): the Nextel "call alert" page. Any typed text is sealed separately to the
/// recipient's one-time prekey and the pair's post-quantum epoch secret, like a burst key, so it
/// gets per-message forward secrecy (PROTOCOL.md §6.1).
public struct CallAlert: Equatable {
    public var name: String
    public var timestamp: UInt64
    public var text: String?
    /// The local key the text was sealed to, once opened (a one-time key is deleted after use).
    public var openedWith: UInt32?

    public init(name: String, timestamp: UInt64, text: String? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.text = text
    }

    /// Plaintext without text (a bare page).
    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        return b.encoded
    }

    /// Plaintext with `text` sealed for `target`. `messageID` must be the packet's message ID.
    public func encoded(sealingTextFor target: SealTarget, channelID: ChannelID, messageID: MessageID) throws -> Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        if let text, !text.isEmpty {
            let textKey = Data.random(count: 32)
            let keying = try BurstKeying.makeEnvelopes(burstKey: textKey, channelID: channelID, burstID: messageID,
                                                       targets: [target])
            let plain = Data(String(text.prefix(256)).utf8.prefix(256))
            let sealed = try Primitives.aeadSeal(key: Self.textKey(textKey), nonce: Data(count: 12), plaintext: plain,
                                                 aad: messageID.bytes)
            b.add(.ephemeralKey, keying.ephemeralPublicKey)
            for envelope in keying.envelopes { b.add(.envelope, envelope) }
            b.add(.sealedText, sealed)
        }
        return b.encoded
    }

    static func textKey(_ key: Data) -> Data {
        Primitives.hkdf(ikm: key, salt: Data(), info: Primitives.v2("alert-text"))
    }

    /// Decodes and, if there is sealed text, opens it.
    public init(decoding data: Data, channelID: ChannelID, messageID: MessageID, recipient: SenderID,
                sender: PublicIdentity, agreement: LocalKeyAgreement, pairSecret: PairSecretLookup) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
        guard let sealed = f.first(.sealedText) else { return }
        let opened = try BurstKeying.open(envelopes: f.all(.envelope), ephemeralPublicKey: try f.require(.ephemeralKey),
                                          channelID: channelID, burstID: messageID, recipient: recipient,
                                          sender: sender, agreement: agreement, pairSecret: pairSecret)
        let plain = try Primitives.aeadOpen(key: Self.textKey(opened.burstKey), nonce: Data(count: 12),
                                            ciphertextAndTag: sealed, aad: messageID.bytes)
        text = String(data: plain, encoding: .utf8)
        openedWith = opened.keyID
    }

    /// Decodes a page without opening any text (for code that only needs the name).
    public init(decodingUnopened data: Data) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
    }
}

/// WAKE (0x06): carried inside a PushToTalk APNs push; message_id is the burst ID.
public struct Wake: Equatable {
    public var name: String
    public var timestamp: UInt64
    public var candidates: [Candidate]

    public init(name: String, timestamp: UInt64, candidates: [Candidate]) {
        self.name = name
        self.timestamp = timestamp
        self.candidates = candidates
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        for c in candidates { b.add(.candidate, c.encoded) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
        candidates = f.all(.candidate).compactMap { try? Candidate(encoded: $0) }
    }
}

/// GROUP_INVITE (0x10): delivers a talk group's keys and member cards over a direct channel,
/// sealed a second time to the invitee's prekey (PROTOCOL.md §6.3).
public struct GroupInvite: Equatable {
    public var timestamp: UInt64
    public var name: String
    public var keys: ChannelKeys
    /// Signed cards of every member, including the inviter and the invitee.
    public var memberCards: [ContactCard]

    public init(timestamp: UInt64, name: String, keys: ChannelKeys, memberCards: [ContactCard]) {
        self.timestamp = timestamp
        self.name = name
        self.keys = keys
        self.memberCards = memberCards
    }

    var innerEncoded: Data {
        var b = TLVBuilder()
        b.add(.groupID, keys.channelID.bytes)
        b.add(.groupName, name)
        b.add(.groupKey, keys.key)
        b.add(.groupEpoch, integer: keys.epoch)
        for card in memberCards { b.add(.memberCard, card.encoded) }
        return b.encoded
    }

    /// The packet plaintext for one invitee. `messageID` must be the packet's message ID.
    public func sealed(for target: SealTarget, messageID: MessageID) throws -> Data {
        try sealed(for: target, messageID: messageID, ephemeral: .init())
    }

    func sealed(for target: SealTarget, messageID: MessageID, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.ephemeralKey, ephemeral.publicKey.rawRepresentation)
        b.add(.sealedInvite, try InviteSealing.seal(innerEncoded, ephemeral: ephemeral, messageID: messageID, target: target))
        return b.encoded
    }

    public init(decoding data: Data, messageID: MessageID, recipient: SenderID, sender: PublicIdentity,
                agreement: LocalKeyAgreement, pairSecret: PairSecretLookup) throws {
        let outer = try TLVFields(data)
        timestamp = try outer.requireUInt(.timestamp)
        let inner = try InviteSealing.open(try outer.require(.sealedInvite),
                                           ephemeralPublicKey: try outer.require(.ephemeralKey),
                                           messageID: messageID, recipient: recipient, sender: sender,
                                           agreement: agreement, pairSecret: pairSecret)
        let f = try TLVFields(inner)
        name = f.string(.groupName) ?? "Talk group"
        keys = try ChannelKeys(channelID: try ChannelID(bytes: try f.require(.groupID)),
                               epoch: try f.requireUInt(.groupEpoch), key: try f.require(.groupKey))
        memberCards = try f.all(.memberCard).map { try ContactCard(encoded: $0) }
    }
}

/// GROUP_LEAVE (0x11).
public struct GroupLeave: Equatable {
    public var timestamp: UInt64
    public var groupID: ChannelID

    public init(timestamp: UInt64, groupID: ChannelID) {
        self.timestamp = timestamp
        self.groupID = groupID
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.groupID, groupID.bytes)
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        groupID = try ChannelID(bytes: try f.require(.groupID))
    }
}
