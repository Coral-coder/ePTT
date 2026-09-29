import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Face-to-face pairing over Orbit codes (PROTOCOL.md §12). Phones held screen to screen, each
/// cycling its codes and reading the other's with the front camera.
///
/// Each side sends its whole signed contact card: keys, name, push tokens, network addresses,
/// relay mailbox and its signed forward-secrecy prekey. So once paired, either phone can reach
/// the other directly and forward-secret from the first transmission; nothing waits on the relay.
///
/// 1. OFFER (kind 0): our card, in 26-byte frames, looped.
/// 2. Once we hold the other phone's whole card we add one ACK frame (kind 1) to the loop: the
///    first 8 bytes of SHA-256 of their card, then of ours.
/// 3. We are done when we hold their card and read their ACK naming both cards exactly. Then
///    both screens show the same six-digit safety code, computed over both cards.
///
/// A random session byte in every frame lets a phone ignore its own reflection.
public struct OrbitHandshake {
    public enum Event: Equatable {
        case gotOffer(ContactCard)
        case completed(ContactCard, safetyCode: String)
        case rejected(String)
    }

    public let session: UInt8
    private let offer: Data
    private let ownID: IdentityID
    public private(set) var peer: ContactCard?
    /// The peer's ACK named our card; this is the card it said it was showing.
    public private(set) var peerHasOurs = false
    private var ackedPeerTag: Data?
    public private(set) var isComplete = false
    /// Offer frames collected, by peer session.
    private var partial: [UInt8: [Int: [UInt8]]] = [:]
    private var totals: [UInt8: Int] = [:]
    /// How many of the peer's card frames we hold, and how many there are (for progress).
    public private(set) var collected = (have: 0, of: 0)

    public init(card: ContactCard, session: UInt8 = .random(in: 0...255)) {
        offer = card.encoded
        ownID = card.id
        self.session = session
    }

    private static func tag(_ data: Data) -> Data { Data(SHA256.hash(data: data)).prefix(8) }

    /// The frames to show, in a loop: our card, plus an ACK every few frames once we hold theirs.
    /// After completing, only the ACK (the other phone may still need it).
    public var frames: [OrbitCode.Frame] {
        let card = Self.split(kind: 0, session: session, message: offer)
        guard let peer else { return card }
        let ack = OrbitCode.Frame(kind: 1, index: 0, total: 1, session: session,
                                  payload: Array(Self.tag(peer.encoded) + Self.tag(offer)))
        if isComplete { return [ack] }
        var out: [OrbitCode.Frame] = []
        for (i, frame) in card.enumerated() {
            if i % 4 == 0 { out.append(ack) }
            out.append(frame)
        }
        return out
    }

    /// Feeds one decoded code.
    public mutating func receive(_ frame: OrbitCode.Frame) -> Event? {
        guard frame.session != session, !isComplete else { return nil }
        if frame.kind == 1 { return receiveAck(frame) }
        guard peer == nil else { return nil }
        if totals[frame.session] != frame.total { totals[frame.session] = frame.total; partial[frame.session] = [:] }
        partial[frame.session, default: [:]][frame.index] = frame.payload
        let chunks = partial[frame.session] ?? [:]
        collected = (chunks.count, frame.total)
        guard chunks.count == frame.total else { return nil }
        let message = Data((0..<frame.total).flatMap { chunks[$0] ?? [] })
        guard let card = Self.card(in: message) else {
            partial[frame.session] = [:]
            return .rejected("That code didn't check out; keep holding")
        }
        guard card.id != ownID else { return nil }
        if let ackedPeerTag, ackedPeerTag != Self.tag(card.encoded) {
            partial[frame.session] = [:]
            return .rejected("Two different phones answered; try again")
        }
        peer = card
        if peerHasOurs { return complete() }
        return .gotOffer(card)
    }

    private mutating func receiveAck(_ frame: OrbitCode.Frame) -> Event? {
        let named = Data(frame.payload.prefix(16))
        guard named.prefix(8) == Self.tag(offer) else {
            return .rejected("The other phone read someone else's code; keep holding")
        }
        peerHasOurs = true
        guard let peer else {
            ackedPeerTag = Data(named.suffix(8))
            return nil
        }
        guard named.suffix(8) == Self.tag(peer.encoded) else {
            return .rejected("Two different phones answered; try again")
        }
        return complete()
    }

    private mutating func complete() -> Event? {
        guard let peer else { return nil }
        isComplete = true
        return .completed(peer, safetyCode: LightCode.safetyCode(offer, peer.encoded))
    }

    /// A verified card from the front of zero-padded bytes. The card is TLV records; the
    /// signature record is last, so trailing padding is cut after it.
    static func card(in data: Data) -> ContactCard? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 <= bytes.count {
            let tag = bytes[i], length = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            guard tag != 0, i + 3 + length <= bytes.count else { return nil }
            i += 3 + length
            if tag == Tag.cardSignature.rawValue {
                guard bytes[i...].allSatisfy({ $0 == 0 }) else { return nil }
                return try? ContactCard(encoded: Data(bytes[0..<i]))
            }
        }
        return nil
    }

    static func split(kind: UInt8, session: UInt8, message: Data) -> [OrbitCode.Frame] {
        let size = OrbitCode.payloadBytes
        let total = max(1, (message.count + size - 1) / size)
        precondition(total <= OrbitCode.maxFrames)
        return (0..<total).map { i in
            let chunk = message.dropFirst(i * size).prefix(size)
            return OrbitCode.Frame(kind: kind, index: i, total: total, session: session, payload: Array(chunk))
        }
    }
}
