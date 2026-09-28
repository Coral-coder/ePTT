import Foundation

/// A decrypted, validated inbound message.
public enum InboundMessage: Equatable {
    case hello(Hello)
    case burstStart(BurstStart)
    case voice(firstFrameIndex: UInt32, frames: [Data])
    case burstEnd(BurstEnd)
    case callAlert(CallAlert)
    case wake(Wake)
    case groupInvite(GroupInvite)
    case groupLeave(GroupLeave)
}

public struct InboundPacket: Equatable {
    public let header: PacketHeader
    public let channel: Channel
    public let sender: PublicIdentity
    public let message: InboundMessage
}

public enum InboundError: Error, Equatable {
    case malformed
    case unknownChannel
    case unknownEpoch
    case notAMember
    case ownPacket
    case authenticationFailed
    case staleTimestamp
    case replay
    case badSignature
    case wrongChannelKind
}

/// Remembers recently seen control messages to drop replays (PROTOCOL.md §6.2).
public struct ReplayGuard {
    public static let window: TimeInterval = 300
    public static let maxClockSkew: TimeInterval = 120

    private struct Key: Hashable {
        let sender: SenderID
        let message: MessageID
        let type: PacketType
    }

    private var seen: [Key: Date] = [:]

    public init() {}

    /// Returns false if this (sender, message, type) was seen within the window; records it otherwise.
    public mutating func accept(sender: SenderID, message: MessageID, type: PacketType, now: Date = Date()) -> Bool {
        if seen.count > 4096 { prune(now: now) }
        let key = Key(sender: sender, message: message, type: type)
        if let at = seen[key], now.timeIntervalSince(at) < ReplayGuard.window { return false }
        seen[key] = now
        return true
    }

    public mutating func prune(now: Date = Date()) {
        seen = seen.filter { now.timeIntervalSince($0.value) < ReplayGuard.window }
    }

    public static func isFresh(_ timestamp: UInt64, now: Date = Date()) -> Bool {
        let delta = Double(timestamp) / 1000 - now.timeIntervalSince1970
        return abs(delta) <= maxClockSkew
    }
}

/// Parses, authenticates and validates raw datagrams against the local state.
public struct PacketProcessor {
    public let local: LocalIdentity
    private var replay = ReplayGuard()

    public init(local: LocalIdentity) { self.local = local }

    /// - Parameters:
    ///   - channelLookup: returns the channel for an ID, if we are in it.
    ///   - memberLookup: returns a known peer's identity for a sender ID.
    public mutating func process(
        _ packet: Data,
        now: Date = Date(),
        channelLookup: (ChannelID) -> Channel?,
        memberLookup: (SenderID) -> PublicIdentity?
    ) throws -> InboundPacket {
        guard let header = try? PacketHeader(packet: packet) else { throw InboundError.malformed }
        guard header.senderID != local.senderID else { throw InboundError.ownPacket }
        guard let channel = channelLookup(header.channelID) else { throw InboundError.unknownChannel }
        guard let keys = channel.keys(forEpoch: header.epoch) else { throw InboundError.unknownEpoch }
        guard let sender = memberLookup(header.senderID), channel.members.contains(sender.id) else {
            throw InboundError.notAMember
        }
        guard let plaintext = try? PacketCrypto.open(packet, header: header, keys: keys) else {
            throw InboundError.authenticationFailed
        }

        let message: InboundMessage
        do {
            message = try decode(header: header, plaintext: plaintext)
        } catch {
            throw InboundError.malformed
        }

        switch message {
        case .hello, .groupInvite, .groupLeave:
            guard channel.kind == .direct else { throw InboundError.wrongChannelKind }
        default:
            break
        }

        if let timestamp = message.timestamp {
            guard ReplayGuard.isFresh(timestamp, now: now) else { throw InboundError.staleTimestamp }
        }
        if case .burstStart(let start) = message,
           !start.verify(sender: sender, channelID: channel.id, burstID: header.messageID) {
            throw InboundError.badSignature
        }
        if message.isReplayTracked,
           !replay.accept(sender: header.senderID, message: header.messageID, type: header.type, now: now) {
            throw InboundError.replay
        }
        return InboundPacket(header: header, channel: channel, sender: sender, message: message)
    }

    private func decode(header: PacketHeader, plaintext: Data) throws -> InboundMessage {
        switch header.type {
        case .hello: return .hello(try Hello(decoding: plaintext))
        case .burstStart: return .burstStart(try BurstStart(decoding: plaintext))
        case .voice: return .voice(firstFrameIndex: header.seq, frames: try VoiceBody.decode(plaintext))
        case .burstEnd: return .burstEnd(try BurstEnd(decoding: plaintext))
        case .callAlert: return .callAlert(try CallAlert(decoding: plaintext))
        case .wake: return .wake(try Wake(decoding: plaintext))
        case .groupInvite: return .groupInvite(try GroupInvite(decoding: plaintext))
        case .groupLeave: return .groupLeave(try GroupLeave(decoding: plaintext))
        }
    }
}

extension InboundMessage {
    var timestamp: UInt64? {
        switch self {
        case .hello(let m): return m.timestamp
        case .burstStart(let m): return m.timestamp
        case .burstEnd(let m): return m.timestamp
        case .callAlert(let m): return m.timestamp
        case .wake(let m): return m.timestamp
        case .groupInvite(let m): return m.timestamp
        case .groupLeave(let m): return m.timestamp
        case .voice: return nil
        }
    }

    /// Voice is deduplicated per frame by the jitter buffer instead. BURST_START/END repeats
    /// are expected retransmissions, so they are tracked and the duplicates dropped here.
    var isReplayTracked: Bool {
        if case .voice = self { return false }
        return true
    }
}

/// Builds outbound packets for the local identity.
public struct PacketBuilder {
    public let local: LocalIdentity

    public init(local: LocalIdentity) { self.local = local }

    public func seal(_ type: PacketType, plaintext: Data, keys: ChannelKeys,
                     messageID: MessageID = .random(), seq: UInt32 = 0) throws -> Data {
        let header = PacketHeader(type: type, epoch: keys.epoch, channelID: keys.channelID,
                                  senderID: local.senderID, messageID: messageID, seq: seq)
        return try PacketCrypto.seal(plaintext, header: header, keys: keys)
    }
}
