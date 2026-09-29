import Foundation

public enum PacketType: UInt8, Codable {
    case hello = 0x01
    case burstStart = 0x02
    case voice = 0x03
    case burstEnd = 0x04
    case callAlert = 0x05
    case wake = 0x06
    case groupInvite = 0x10
    case groupLeave = 0x11
    /// The sender's full signed contact card, e.g. after pairing face to face (PROTOCOL.md §12).
    case card = 0x12
    /// "Add me to this group", answering a group QR code (PROTOCOL.md §6.5). Opened with
    /// `GroupJoin.open`, never by `PacketProcessor` (the sender isn't a contact yet).
    case groupJoin = 0x13
}

/// 8-byte message identifier; equals the burst ID for burst packets and WAKE.
public struct MessageID: Hashable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 8 else { throw DecodingError.invalid("message id length") }
        self.bytes = Data(bytes)
    }

    public static func random() -> MessageID { try! MessageID(bytes: .random(count: 8)) }
    public var description: String { bytes.hex }
}

/// The 40-byte cleartext packet header (PROTOCOL.md §6). It is authenticated as AAD.
public struct PacketHeader: Equatable {
    public static let length = 40
    public static let version: UInt8 = 1

    public var type: PacketType
    public var epoch: UInt16
    public var channelID: ChannelID
    public var senderID: SenderID
    public var messageID: MessageID
    public var seq: UInt32

    public init(type: PacketType, epoch: UInt16, channelID: ChannelID, senderID: SenderID,
                messageID: MessageID, seq: UInt32) {
        self.type = type
        self.epoch = epoch
        self.channelID = channelID
        self.senderID = senderID
        self.messageID = messageID
        self.seq = seq
    }

    public var encoded: Data {
        var out = Data([PacketHeader.version, type.rawValue])
        out.appendBE(epoch)
        out.append(channelID.bytes)
        out.append(senderID.bytes)
        out.append(messageID.bytes)
        out.appendBE(seq)
        return out
    }

    /// Parses just the header so the receiver can pick keys before decrypting.
    public init(packet: Data) throws {
        guard packet.count >= PacketHeader.length + 16 else { throw DecodingError.truncated }
        var reader = ByteReader(packet.prefix(PacketHeader.length))
        guard try reader.readUInt(UInt8.self) == PacketHeader.version else {
            throw DecodingError.invalid("packet version")
        }
        guard let type = PacketType(rawValue: try reader.readUInt(UInt8.self)) else {
            throw DecodingError.invalid("packet type")
        }
        self.type = type
        epoch = try reader.readUInt(UInt16.self)
        channelID = try ChannelID(bytes: try reader.read(16))
        senderID = try SenderID(bytes: try reader.read(8))
        messageID = try MessageID(bytes: try reader.read(8))
        seq = try reader.readUInt(UInt32.self)
    }

    var nonce: Data {
        var n = Data([type.rawValue])
        n.append(Data(count: 7))
        n.appendBE(seq)
        return n
    }
}

public enum PacketCrypto {
    static func messageKey(channelKey: Data, messageID: MessageID, senderID: SenderID, epoch: UInt16) -> Data {
        var info = Primitives.label("ePTT/1 msg")
        info.append(senderID.bytes)
        info.appendBE(epoch)
        return Primitives.hkdf(ikm: channelKey, salt: messageID.bytes, info: info)
    }

    /// Seals a plaintext into a complete packet. The header's epoch and channel must match `keys`.
    public static func seal(_ plaintext: Data, header: PacketHeader, keys: ChannelKeys) throws -> Data {
        precondition(header.channelID == keys.channelID && header.epoch == keys.epoch, "header/keys mismatch")
        return try seal(plaintext, header: header, messageKey: messageKey(
            channelKey: keys.key, messageID: header.messageID, senderID: header.senderID, epoch: header.epoch))
    }

    /// Opens a packet whose header was already parsed. Throws if authentication fails.
    public static func open(_ packet: Data, header: PacketHeader, keys: ChannelKeys) throws -> Data {
        try open(packet, header: header, messageKey: messageKey(
            channelKey: keys.key, messageID: header.messageID, senderID: header.senderID, epoch: header.epoch))
    }

    /// VOICE and BURST_END are sealed under the burst's own key (PROTOCOL.md §6).
    public static func seal(_ plaintext: Data, header: PacketHeader, burstKey: Data) throws -> Data {
        try seal(plaintext, header: header, messageKey: BurstKeying.messageKey(
            burstKey: burstKey, burstID: header.messageID, senderID: header.senderID, epoch: header.epoch))
    }

    public static func open(_ packet: Data, header: PacketHeader, burstKey: Data) throws -> Data {
        try open(packet, header: header, messageKey: BurstKeying.messageKey(
            burstKey: burstKey, burstID: header.messageID, senderID: header.senderID, epoch: header.epoch))
    }

    static func seal(_ plaintext: Data, header: PacketHeader, messageKey: Data) throws -> Data {
        let aad = header.encoded
        let sealed = try Primitives.aeadSeal(key: messageKey, nonce: header.nonce, plaintext: plaintext, aad: aad)
        return aad + sealed
    }

    static func open(_ packet: Data, header: PacketHeader, messageKey: Data) throws -> Data {
        let aad = Data(packet.prefix(PacketHeader.length))
        return try Primitives.aeadOpen(key: messageKey, nonce: header.nonce,
                                       ciphertextAndTag: Data(packet.dropFirst(PacketHeader.length)), aad: aad)
    }

    /// Whether this packet type is sealed under a burst key rather than the channel key.
    static func usesBurstKey(_ type: PacketType) -> Bool { type == .voice || type == .burstEnd }
}
