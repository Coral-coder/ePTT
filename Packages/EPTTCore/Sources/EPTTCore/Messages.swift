import Foundation

/// Milliseconds since the Unix epoch.
public func currentTimestamp(_ date: Date = Date()) -> UInt64 {
    UInt64(max(0, date.timeIntervalSince1970 * 1000))
}

/// HELLO (0x01): identity refresh, reachability and keep-alive on a direct channel.
public struct Hello: Equatable {
    public static let replyRequested: UInt8 = 0x01

    public var name: String
    public var timestamp: UInt64
    public var reachability: Reachability
    public var flags: UInt8

    public init(name: String, timestamp: UInt64, reachability: Reachability, flags: UInt8 = 0) {
        self.name = name
        self.timestamp = timestamp
        self.reachability = reachability
        self.flags = flags
    }

    public var wantsReply: Bool { flags & Hello.replyRequested != 0 }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        reachability.add(to: &b)
        b.add(.flags, integer: flags)
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
        reachability = try Reachability(fields: f)
        flags = try f.uint(.flags) ?? 0
    }
}

public enum VoiceCodecID: UInt8, Codable {
    case opus = 1
    case pcm16 = 2
}

/// BURST_START (0x02): opens a signed transmission.
public struct BurstStart: Equatable {
    public var timestamp: UInt64
    public var codec: VoiceCodecID
    public var sampleRate: UInt32
    public var frameMilliseconds: UInt8
    public var signature: Data

    public init(timestamp: UInt64, codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8, signature: Data) {
        self.timestamp = timestamp
        self.codec = codec
        self.sampleRate = sampleRate
        self.frameMilliseconds = frameMilliseconds
        self.signature = signature
    }

    public static func signatureInput(channelID: ChannelID, senderID: SenderID, burstID: MessageID,
                                      timestamp: UInt64) -> Data {
        var d = Primitives.label("ePTT/1 burst")
        d.append(channelID.bytes)
        d.append(senderID.bytes)
        d.append(burstID.bytes)
        d.appendBE(timestamp)
        return d
    }

    /// Builds and signs a BURST_START for the local identity.
    public static func signed(by identity: LocalIdentity, channelID: ChannelID, burstID: MessageID, timestamp: UInt64,
                              codec: VoiceCodecID = .opus, sampleRate: UInt32 = 16_000,
                              frameMilliseconds: UInt8 = 20) throws -> BurstStart {
        let input = signatureInput(channelID: channelID, senderID: identity.senderID, burstID: burstID,
                                   timestamp: timestamp)
        return BurstStart(timestamp: timestamp, codec: codec, sampleRate: sampleRate,
                          frameMilliseconds: frameMilliseconds, signature: try identity.sign(input))
    }

    public func verify(sender: PublicIdentity, channelID: ChannelID, burstID: MessageID) -> Bool {
        sender.isValidSignature(signature, for: BurstStart.signatureInput(
            channelID: channelID, senderID: sender.senderID, burstID: burstID, timestamp: timestamp))
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.codec, integer: codec.rawValue)
        b.add(.sampleRate, integer: sampleRate)
        b.add(.frameMilliseconds, integer: frameMilliseconds)
        b.add(.signature, signature)
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

/// CALL_ALERT (0x05): the Nextel "call alert" page.
public struct CallAlert: Equatable {
    public var name: String
    public var timestamp: UInt64
    public var text: String?

    public init(name: String, timestamp: UInt64, text: String? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.text = text
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.name, name)
        b.add(.timestamp, integer: timestamp)
        if let text { b.add(.text, text, maxBytes: 256) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        name = f.string(.name) ?? ""
        timestamp = try f.requireUInt(.timestamp)
        text = f.string(.text)
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

/// GROUP_INVITE (0x10): delivers a talk group's keys and member cards over a direct channel.
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

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.groupID, keys.channelID.bytes)
        b.add(.groupName, name)
        b.add(.groupKey, keys.key)
        b.add(.groupEpoch, integer: keys.epoch)
        for card in memberCards { b.add(.memberCard, card.encoded) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
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
