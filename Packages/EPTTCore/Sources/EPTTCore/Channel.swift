import Foundation

/// 16-byte channel identifier (PROTOCOL.md §5).
public struct ChannelID: Hashable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw DecodingError.invalid("channel id length") }
        self.bytes = Data(bytes)
    }

    init(unchecked bytes: Data) { self.bytes = Data(bytes) }

    public static func random() -> ChannelID { ChannelID(unchecked: .random(count: 16)) }

    public var description: String { bytes.hex }

    /// A stable UUID view, handy for PushToTalk and SwiftUI identifiers.
    public var uuid: UUID {
        let b = [UInt8](bytes)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Key material for one channel at one epoch.
public struct ChannelKeys: Equatable, Codable {
    public let channelID: ChannelID
    public let epoch: UInt16
    public let key: Data

    public init(channelID: ChannelID, epoch: UInt16, key: Data) throws {
        guard key.count == 32 else { throw DecodingError.invalid("channel key length") }
        self.channelID = channelID
        self.epoch = epoch
        self.key = Data(key)
    }

    /// Both peers compute the same ID without communicating.
    public static func directChannelID(_ a: IdentityID, _ b: IdentityID) -> ChannelID {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        return ChannelID(unchecked: Primitives.sha256(Primitives.label("ePTT/1 direct-id"), lo.bytes, hi.bytes).prefix(16))
    }

    /// Fresh talk-group keys (PROTOCOL.md §5.2).
    public static func newGroup() -> ChannelKeys {
        try! ChannelKeys(channelID: .random(), epoch: 1, key: .random(count: 32))
    }

    /// The next epoch's keys for a rekey.
    public func rekeyed() -> ChannelKeys {
        try! ChannelKeys(channelID: channelID, epoch: epoch &+ 1, key: .random(count: 32))
    }
}

public enum ChannelKind: String, Codable {
    case direct
    case group
}

/// A channel as the app knows it: who is in it and how to encrypt for it.
public struct Channel: Identifiable, Equatable, Codable {
    public var id: ChannelID { keys.channelID }
    public var kind: ChannelKind
    public var name: String
    public var keys: ChannelKeys
    /// Keys from the previous epoch, accepted briefly after a rekey (talk groups).
    public var previousKeys: ChannelKeys?
    /// Direct channels: the pairwise session ratchet that supplies `keys` (PROTOCOL.md §5.3).
    public var session: PairSession?
    /// Members other than the local user.
    public var members: [IdentityID]
    /// Whether incoming traffic on this channel should be played (Nextel "scan").
    public var isMonitored: Bool
    /// Talk groups: members removed, kept so an invite that raced the removal can't undo it.
    public var removed: [GroupRemoval]?
    /// Talk groups: who sent us the current key (nil: we made it).
    public var keyAuthor: IdentityID?

    public init(kind: ChannelKind, name: String, keys: ChannelKeys, members: [IdentityID], isMonitored: Bool = true) {
        self.kind = kind
        self.name = name
        self.keys = keys
        self.members = members
        self.isMonitored = isMonitored
    }

    public static func direct(local: LocalIdentity, peer: ContactCard) throws -> Channel {
        try direct(local: local, peer: peer.identity, name: peer.name)
    }

    /// A direct channel at epoch 0 of a fresh session (PROTOCOL.md §5.1, §5.3).
    public static func direct(local: LocalIdentity, peer: PublicIdentity, name: String) throws -> Channel {
        let id = ChannelKeys.directChannelID(local.id, peer.id)
        let session = try PairSession.bootstrap(local: local, peer: peer, channelID: id)
        var channel = Channel(kind: .direct, name: name, keys: session.sendingKeys(channelID: id), members: [peer.id])
        channel.session = session
        return channel
    }

    /// Replaces a direct channel's session and points `keys` at the epoch to send with.
    public mutating func apply(session: PairSession) {
        self.session = session
        keys = session.sendingKeys(channelID: id)
        previousKeys = nil
    }

    /// Keys matching a received packet's epoch, if we still have them.
    public func keys(forEpoch epoch: UInt16) -> ChannelKeys? {
        if let session { return session.channelKeys(channelID: id, epoch: epoch) }
        if keys.epoch == epoch { return keys }
        if let previous = previousKeys, previous.epoch == epoch { return previous }
        return nil
    }

    /// Every key a packet on this channel might be shielded with.
    public var shieldCandidates: [ChannelKeys] {
        if let session { return session.allChannelKeys(channelID: id) }
        return [keys] + (previousKeys.map { [$0] } ?? [])
    }
}
