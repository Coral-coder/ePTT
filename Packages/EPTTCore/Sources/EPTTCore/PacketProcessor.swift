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
    case card(ContactCard)
    case pqOffer(PQOffer)
    case pqAccept(PQAccept)
    case oneTimeKeys(OneTimeKeyBatch)
}

public struct InboundPacket: Equatable {
    public let header: PacketHeader
    public let channel: Channel
    public let sender: PublicIdentity
    public let message: InboundMessage
    /// For a BURST_START or a call alert with text: the local key its envelope was sealed to.
    public var openedKeyID: UInt32? = nil
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
    /// VOICE/BURST_END for a burst whose BURST_START we have not opened (yet). Callers may retry
    /// the packet after the start arrives.
    case unknownBurst
    /// A BURST_START that carries no envelope we can open (not addressed to us, or sealed to a
    /// prekey we have already deleted).
    case notARecipient
    /// One fragment of a larger message; the rest hasn't arrived yet.
    case incomplete
}

/// Remembers recently seen control messages to drop replays (PROTOCOL.md §6.4).
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
    private let agreement: LocalKeyAgreement
    private var replay = ReplayGuard()

    private struct BurstRef: Hashable {
        let sender: SenderID
        let burst: MessageID
    }
    /// Keys of recently opened bursts, oldest first.
    private var burstKeys: [BurstRef: Data] = [:]
    private var burstOrder: [BurstRef] = []
    private static let maxBurstKeys = 64

    private struct FragmentRef: Hashable {
        let sender: SenderID
        let message: MessageID
        let type: PacketType
    }
    private var fragments: [FragmentRef: (total: Int, parts: [Int: Data], first: Date)] = [:]
    private static let maxFragmentSets = 16

    /// - Parameter agreement: X25519 with our static key (prekey 0) or a held prekey.
    public init(local: LocalIdentity, agreement: LocalKeyAgreement? = nil) {
        self.local = local
        let identity = local
        self.agreement = agreement ?? { id, publicKey, _ in
            guard id == 0 else { throw DecodingError.invalid("no prekeys configured") }
            return try identity.sharedSecret(withPublicKey: publicKey)
        }
    }

    /// Opens an inner packet (already unshielded, PROTOCOL.md §6.6).
    /// - Parameters:
    ///   - maxAge: how old a timestamp may be. Live traffic uses the default; relayed
    ///     (store-and-forward) bursts pass a longer window.
    ///   - channelLookup: returns the channel for an ID, if we are in it.
    ///   - memberLookup: returns a known peer's identity for a sender ID.
    ///   - pairSecret: the burst secret of our pairwise session with a sender at an epoch.
    public mutating func process(
        _ packet: Data,
        now: Date = Date(),
        maxAge: TimeInterval = ReplayGuard.maxClockSkew,
        channelLookup: (ChannelID) -> Channel?,
        memberLookup: (SenderID) -> PublicIdentity?,
        pairSecret: PairSecretLookup = { _, _ in nil }
    ) throws -> InboundPacket {
        guard let header = try? PacketHeader(packet: packet) else { throw InboundError.malformed }
        guard header.senderID != local.senderID else { throw InboundError.ownPacket }
        guard let channel = channelLookup(header.channelID) else { throw InboundError.unknownChannel }
        guard let keys = channel.keys(forEpoch: header.epoch) else { throw InboundError.unknownEpoch }
        guard let sender = memberLookup(header.senderID), channel.members.contains(sender.id) else {
            throw InboundError.notAMember
        }
        var packet = packet
        if channel.kind == .group, PacketCrypto.needsGroupSignature(header.type) {
            guard let body = PacketCrypto.verifyGroupSignature(packet, sender: sender) else {
                throw InboundError.badSignature
            }
            packet = body
        }

        var plaintext: Data
        if PacketCrypto.usesBurstKey(header.type) {
            guard let burstKey = burstKeys[BurstRef(sender: header.senderID, burst: header.messageID)] else {
                throw InboundError.unknownBurst
            }
            guard let opened = try? PacketCrypto.open(packet, header: header, burstKey: burstKey) else {
                throw InboundError.authenticationFailed
            }
            plaintext = opened
        } else {
            guard let opened = try? PacketCrypto.open(packet, header: header, keys: keys) else {
                throw InboundError.authenticationFailed
            }
            plaintext = opened
        }

        switch header.type {
        case .hello, .groupInvite, .groupLeave, .pqOffer, .pqAccept, .oneTimeKeys, .card:
            guard channel.kind == .direct else { throw InboundError.wrongChannelKind }
        default:
            break
        }
        // A direct channel's epoch 0 is classical (static keys only): it carries the rekey and
        // self-authenticating messages (signed cards and prekeys), never anything that could be
        // forged by someone who later breaks or steals a static key.
        if channel.kind == .direct, header.epoch == 0 {
            switch header.type {
            case .hello, .card, .pqOffer, .pqAccept: break
            default: throw InboundError.unknownEpoch
            }
        }

        if header.type == .pqOffer || header.type == .pqAccept {
            plaintext = try reassemble(header: header, fragment: plaintext, now: now)
        }

        var opened: UInt32?
        let message: InboundMessage
        do {
            message = try decode(header: header, plaintext: plaintext, channel: channel, sender: sender,
                                 pairSecret: pairSecret, opened: &opened)
        } catch let error as InboundError {
            throw error
        } catch {
            throw InboundError.malformed
        }

        if let timestamp = message.timestamp {
            let delta = Double(timestamp) / 1000 - now.timeIntervalSince1970
            guard delta <= ReplayGuard.maxClockSkew, -delta <= max(maxAge, ReplayGuard.maxClockSkew) else {
                throw InboundError.staleTimestamp
            }
        }
        if case .hello(let hello) = message, let prekey = hello.reachability.prekey, !prekey.isValid(for: sender) {
            throw InboundError.badSignature
        }
        if case .burstStart(let start) = message {
            guard start.verify(sender: sender, channelID: channel.id, burstID: header.messageID) else {
                throw InboundError.badSignature
            }
            let ref = BurstRef(sender: header.senderID, burst: header.messageID)
            if burstKeys[ref] == nil {
                guard let result = try? BurstKeying.open(envelopes: start.envelopes,
                                                         ephemeralPublicKey: start.ephemeralPublicKey,
                                                         channelID: channel.id, burstID: header.messageID,
                                                         recipient: local.senderID, sender: sender,
                                                         agreement: agreement, pairSecret: pairSecret) else {
                    throw InboundError.notARecipient
                }
                remember(ref, result.burstKey)
                opened = result.keyID
            }
        }
        if message.isReplayTracked,
           !replay.accept(sender: header.senderID, message: header.messageID, type: header.type, now: now) {
            throw InboundError.replay
        }
        return InboundPacket(header: header, channel: channel, sender: sender, message: message, openedKeyID: opened)
    }

    /// Collects the fragments of a PQ_OFFER / PQ_ACCEPT. Each is "index(1) ‖ total(1) ‖ bytes",
    /// with seq = index (so every fragment has its own nonce).
    private mutating func reassemble(header: PacketHeader, fragment: Data, now: Date) throws -> Data {
        guard fragment.count >= 2 else { throw InboundError.malformed }
        let bytes = [UInt8](fragment)
        let index = Int(bytes[0]), total = Int(bytes[1])
        guard total >= 1, total <= 8, index < total, UInt32(index) == header.seq else { throw InboundError.malformed }
        if total == 1 { return Data(bytes[2...]) }
        fragments = fragments.filter { now.timeIntervalSince($0.value.first) < 60 }
        let ref = FragmentRef(sender: header.senderID, message: header.messageID, type: header.type)
        var entry = fragments[ref] ?? (total, [:], now)
        guard entry.total == total else { throw InboundError.malformed }
        entry.parts[index] = Data(bytes[2...])
        guard entry.parts.count == total else {
            if fragments[ref] == nil, fragments.count >= Self.maxFragmentSets {
                fragments.remove(at: fragments.startIndex)
            }
            fragments[ref] = entry
            throw InboundError.incomplete
        }
        fragments[ref] = nil
        return (0..<total).reduce(Data()) { $0 + (entry.parts[$1] ?? Data()) }
    }

    /// Forgets a finished burst's key (forward secrecy: keys should not outlive their use).
    public mutating func forgetBurst(sender: SenderID, burst: MessageID) {
        let ref = BurstRef(sender: sender, burst: burst)
        burstKeys[ref] = nil
        burstOrder.removeAll { $0 == ref }
    }

    /// The highest frame index a VOICE packet may carry: far beyond any burst (a minute at
    /// 20 ms is 3 000 frames), and far enough from UInt32.max that index + offset can't overflow.
    public static let maxVoiceSeq: UInt32 = 1 << 24

    private mutating func remember(_ ref: BurstRef, _ key: Data) {
        burstKeys[ref] = key
        burstOrder.append(ref)
        while burstOrder.count > PacketProcessor.maxBurstKeys {
            burstKeys[burstOrder.removeFirst()] = nil
        }
    }

    private func decode(header: PacketHeader, plaintext: Data, channel: Channel, sender: PublicIdentity,
                        pairSecret: PairSecretLookup, opened: inout UInt32?) throws -> InboundMessage {
        switch header.type {
        case .hello: return .hello(try Hello(decoding: plaintext))
        case .burstStart: return .burstStart(try BurstStart(decoding: plaintext))
        case .voice:
            let frames = try VoiceBody.decode(plaintext)
            // Frame indices are seq, seq + 1, …: they must not wrap (receivers index by them).
            guard header.seq <= PacketProcessor.maxVoiceSeq,
                  UInt64(header.seq) + UInt64(frames.count) <= UInt64(PacketProcessor.maxVoiceSeq) else {
                throw DecodingError.invalid("voice seq")
            }
            return .voice(firstFrameIndex: header.seq, frames: frames)
        case .burstEnd: return .burstEnd(try BurstEnd(decoding: plaintext))
        case .callAlert:
            let alert = try CallAlert(decoding: plaintext, channelID: channel.id, messageID: header.messageID,
                                      recipient: local.senderID, sender: sender, agreement: agreement,
                                      pairSecret: pairSecret)
            opened = alert.openedWith
            return .callAlert(alert)
        case .wake: return .wake(try Wake(decoding: plaintext))
        case .groupInvite:
            return .groupInvite(try GroupInvite(decoding: plaintext, messageID: header.messageID,
                                                recipient: local.senderID, sender: sender, agreement: agreement,
                                                pairSecret: pairSecret))
        case .groupLeave: return .groupLeave(try GroupLeave(decoding: plaintext))
        case .card: return .card(try ContactCard(encoded: plaintext))
        case .pqOffer: return .pqOffer(try PQOffer(decoding: plaintext))
        case .pqAccept: return .pqAccept(try PQAccept(decoding: plaintext))
        case .oneTimeKeys: return .oneTimeKeys(try OneTimeKeyBatch(decoding: plaintext))
        case .groupJoin: throw DecodingError.invalid("GROUP_JOIN is opened with GroupJoin.open")
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
        case .card(let m): return m.timestamp
        case .pqOffer(let m): return m.timestamp
        case .pqAccept(let m): return m.timestamp
        case .oneTimeKeys(let m): return m.timestamp
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

/// Builds outbound (inner) packets for the local identity. Shield them before sending.
public struct PacketBuilder {
    public let local: LocalIdentity

    public init(local: LocalIdentity) { self.local = local }

    /// - Parameter group: a talk-group packet; it gets the sender's signature (§6.7).
    public func seal(_ type: PacketType, plaintext: Data, keys: ChannelKeys,
                     messageID: MessageID = .random(), seq: UInt32 = 0, group: Bool = false) throws -> Data {
        precondition(!PacketCrypto.usesBurstKey(type), "VOICE/BURST_END must use sealBurst")
        let packet = try PacketCrypto.seal(plaintext, header: header(type, keys: keys, messageID: messageID, seq: seq),
                                           keys: keys)
        return group && PacketCrypto.needsGroupSignature(type) ? try PacketCrypto.signForGroup(packet, identity: local) : packet
    }

    /// VOICE and BURST_END: sealed under the burst key (forward secrecy).
    public func sealBurst(_ type: PacketType, plaintext: Data, keys: ChannelKeys, burstID: MessageID,
                          burstKey: Data, seq: UInt32, group: Bool = false) throws -> Data {
        precondition(PacketCrypto.usesBurstKey(type))
        let packet = try PacketCrypto.seal(plaintext, header: header(type, keys: keys, messageID: burstID, seq: seq),
                                           burstKey: burstKey)
        return group ? try PacketCrypto.signForGroup(packet, identity: local) : packet
    }

    /// PQ_OFFER / PQ_ACCEPT: split so each packet fits a datagram.
    /// Every transmission takes a fresh `messageID` (the default): a re-sent offer or accept is
    /// a new message on the wire, never the same nonce over different bytes.
    public func sealFragmented(_ type: PacketType, plaintext: Data, keys: ChannelKeys, messageID: MessageID = .random(),
                               chunk: Int = 880) throws -> [Data] {
        precondition(type == .pqOffer || type == .pqAccept)
        let total = max(1, (plaintext.count + chunk - 1) / chunk)
        precondition(total <= 8)
        return try (0..<total).map { i in
            let part = plaintext.dropFirst(i * chunk).prefix(chunk)
            return try seal(type, plaintext: Data([UInt8(i), UInt8(total)]) + part, keys: keys,
                            messageID: messageID, seq: UInt32(i))
        }
    }

    private func header(_ type: PacketType, keys: ChannelKeys, messageID: MessageID, seq: UInt32) -> PacketHeader {
        PacketHeader(type: type, epoch: keys.epoch, channelID: keys.channelID,
                     senderID: local.senderID, messageID: messageID, seq: seq)
    }
}

/// Everything needed to talk on a channel for one burst: the random burst key and the signed
/// BURST_START that carries it to each recipient.
public struct OutgoingBurst {
    public let burstID: MessageID
    public let burstKey: Data
    public let start: BurstStart

    public init(identity: LocalIdentity, channelID: ChannelID, burstID: MessageID = .random(), timestamp: UInt64,
                targets: [SealTarget], codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8,
                allowsReplay: Bool = false) throws {
        let burstKey = Data.random(count: 32)
        let keying = try BurstKeying.makeEnvelopes(burstKey: burstKey, channelID: channelID, burstID: burstID,
                                                   targets: targets)
        self.burstID = burstID
        self.burstKey = burstKey
        start = try BurstStart.signed(by: identity, channelID: channelID, burstID: burstID, timestamp: timestamp,
                                      ephemeralPublicKey: keying.ephemeralPublicKey, envelopes: keying.envelopes,
                                      codec: codec, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds,
                                      allowsReplay: allowsReplay)
    }
}
