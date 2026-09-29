import Foundation

/// A talk-group invite shown as a QR code (PROTOCOL.md §6.5). It does not contain the group key:
/// it carries the inviter's signed card and a random secret that lets whoever scans it ask the
/// inviter to be added. The inviter's phone then sends the group key the usual way, sealed to the
/// new member (GROUP_INVITE, §6.3).
public struct GroupJoinCode: Equatable {
    public static let uriPrefix = "eptt://join/"
    /// How long a code works for.
    public static let lifetime: TimeInterval = 24 * 3600

    public let groupID: ChannelID
    public let groupName: String
    public let inviter: ContactCard
    /// 32 random bytes; anyone who has them can ask to join until `expires`.
    public let secret: Data
    /// Unix time in milliseconds.
    public let expires: UInt64

    public init(groupID: ChannelID, groupName: String, inviter: ContactCard, secret: Data = .random(count: 32),
                expires: UInt64) {
        self.groupID = groupID
        self.groupName = groupName
        self.inviter = inviter
        self.secret = secret
        self.expires = expires
    }

    public var isExpired: Bool { isExpired(at: Date()) }

    public func isExpired(at date: Date) -> Bool {
        Double(expires) / 1000 <= date.timeIntervalSince1970
    }

    /// The keys a GROUP_JOIN for this code is sealed with. The channel ID is derived from the
    /// secret, so the inviter can tell which code a request answers without trying each one.
    public var joinKeys: ChannelKeys { GroupJoinCode.joinKeys(secret: secret) }

    public static func joinKeys(secret: Data) -> ChannelKeys {
        let id = Primitives.sha256(Primitives.label("ePTT/1 join-id"), secret).prefix(16)
        let key = Primitives.hkdf(ikm: secret, salt: Primitives.label("ePTT/1 join"), info: Data(id))
        return try! ChannelKeys(channelID: ChannelID(unchecked: Data(id)), epoch: 0, key: key)
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.groupID, groupID.bytes)
        b.add(.groupName, groupName)
        b.add(.inviteSecret, secret)
        b.add(.timestamp, integer: expires)
        b.add(.memberCard, inviter.encoded)
        return b.encoded
    }

    public init(encoded data: Data) throws {
        let f = try TLVFields(data)
        groupID = ChannelID(unchecked: try f.require(.groupID))
        guard groupID.bytes.count == 16 else { throw DecodingError.invalid("group id") }
        groupName = f.string(.groupName) ?? "Talk group"
        secret = try f.require(.inviteSecret)
        guard secret.count == 32 else { throw DecodingError.invalid("invite secret") }
        expires = try f.requireUInt(.timestamp)
        inviter = try ContactCard(encoded: try f.require(.memberCard))
    }

    public var uri: String { GroupJoinCode.uriPrefix + encoded.base64URLEncoded }

    public init(uri: String) throws {
        guard uri.hasPrefix(GroupJoinCode.uriPrefix),
              let data = Data(base64URLEncoded: String(uri.dropFirst(GroupJoinCode.uriPrefix.count))) else {
            throw DecodingError.invalid("join uri")
        }
        try self.init(encoded: data)
    }
}

/// GROUP_JOIN (0x13): "add me", sent to the inviter under a code's join keys. Carries the new
/// member's signed card; the sender ID must be the card's.
public struct GroupJoin: Equatable {
    public var timestamp: UInt64
    public var card: ContactCard

    public init(timestamp: UInt64, card: ContactCard) {
        self.timestamp = timestamp
        self.card = card
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.memberCard, card.encoded)
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        card = try ContactCard(encoded: try f.require(.memberCard))
    }

    /// Seals a request for `code` from the local identity.
    public static func seal(card: ContactCard, for code: GroupJoinCode, timestamp: UInt64,
                            builder: PacketBuilder) throws -> Data {
        try builder.seal(.groupJoin, plaintext: GroupJoin(timestamp: timestamp, card: card).encoded,
                         keys: code.joinKeys)
    }

    /// Opens a GROUP_JOIN against our live codes. Returns the code it answers and the request, or
    /// nil if it isn't a valid request for any of them.
    public static func open(_ packet: Data, codes: [GroupJoinCode], now: Date = Date(),
                            maxAge: TimeInterval) -> (code: GroupJoinCode, join: GroupJoin)? {
        guard let header = try? PacketHeader(packet: packet), header.type == .groupJoin,
              let code = codes.first(where: { $0.joinKeys.channelID == header.channelID }),
              !code.isExpired(at: now),
              let plaintext = try? PacketCrypto.open(packet, header: header, keys: code.joinKeys),
              let join = try? GroupJoin(decoding: plaintext),
              join.card.identity.senderID == header.senderID else { return nil }
        let age = now.timeIntervalSince1970 - Double(join.timestamp) / 1000
        guard age <= max(maxAge, ReplayGuard.maxClockSkew), -age <= ReplayGuard.maxClockSkew else { return nil }
        return (code, join)
    }
}
