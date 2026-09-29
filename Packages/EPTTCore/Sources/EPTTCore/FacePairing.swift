import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Face-to-face pairing: two phones held screen to screen, each showing a looping series of
/// small codes and reading the other's with its front camera (PROTOCOL.md §12).
///
/// 1. Each side shows OFFER frames: a fresh 16-byte nonce and its signed contact card, split into
///    chunks small enough to read at arm's length.
/// 2. Once it has the peer's whole offer, it shows ACK frames instead: its own nonce and card
///    again, plus SHA-256 of the exact offer it received.
/// 3. A side completes when it reads an ACK whose hash matches its own offer: the peer provably
///    holds our real card, and we hold theirs (the ACK carries it). Both sides add each other.
///
/// The optical channel is the security boundary: only something in front of the camera can take
/// part, the cards are signed by their identity keys, and the ACK hash binds each side to what
/// it actually received. Both screens then show a six-digit safety code over both offers.
public struct FacePairing {
    public enum Event: Equatable {
        /// We now hold the peer's card (from their offer); we're showing ACK frames.
        case gotOffer(name: String)
        /// Done: the peer confirmed our card and we hold theirs.
        case completed(card: ContactCard, safetyCode: String)
        /// A frame decoded but failed a check (wrong hash, bad signature).
        case rejected(String)
    }

    public static let prefix = "NXP1:"
    /// Card bytes per frame; keeps each code at a low QR version that reads well screen to screen.
    public static let chunkBytes = 96

    private enum Kind: UInt8 { case offer = 1, ack = 2 }

    public let session: Data          // 4 random bytes, tells our frames from the peer's
    private let nonce: Data           // 16 random bytes
    private let localCard: ContactCard
    public private(set) var peerCard: ContactCard?
    private var peerOffer: Data?
    public private(set) var isComplete = false
    /// Chunks being assembled, by (peer session, kind).
    private var partial: [Data: [Int: Data]] = [:]
    private var totals: [Data: Int] = [:]

    public init(localCard: ContactCard) {
        self.localCard = localCard
        session = .random(count: 4)
        nonce = .random(count: 16)
    }

    /// What this side offers: nonce ‖ card.
    private var offer: Data { nonce + localCard.encoded }

    /// The frames to show now, in a loop: OFFER until we hold the peer's offer, then ACK.
    public var frames: [String] {
        if let peerOffer {
            let hash = Data(SHA256.hash(data: peerOffer))
            return Self.encode(kind: .ack, session: session, message: nonce + hash + localCard.encoded)
        }
        return Self.encode(kind: .offer, session: session, message: offer)
    }

    /// Feeds one scanned code. Returns an event when something changed.
    public mutating func receive(_ text: String) -> Event? {
        guard text.hasPrefix(Self.prefix),
              let bytes = Data(base64URLEncoded: String(text.dropFirst(Self.prefix.count))),
              bytes.count > 7, let kind = Kind(rawValue: bytes[bytes.startIndex]) else { return nil }
        let frameSession = bytes.subdata(in: bytes.startIndex + 1 ..< bytes.startIndex + 5)
        guard frameSession != session else { return nil }            // our own reflection
        let index = Int(bytes[bytes.startIndex + 5]), total = Int(bytes[bytes.startIndex + 6])
        guard total > 0, index < total else { return nil }
        let key = frameSession + Data([kind.rawValue])
        if totals[key] != total { totals[key] = total; partial[key] = [:] }
        partial[key, default: [:]][index] = bytes.subdata(in: bytes.startIndex + 7 ..< bytes.endIndex)
        guard let chunks = partial[key], chunks.count == total else { return nil }
        let message = (0..<total).reduce(into: Data()) { $0 += chunks[$1] ?? Data() }

        switch kind {
        case .offer:
            guard peerOffer == nil, message.count > 16,
                  let card = try? ContactCard(encoded: message.subdata(in: message.startIndex + 16 ..< message.endIndex))
            else { return peerOffer == nil ? .rejected("That code isn't a valid NXTPTT card") : nil }
            guard card.id != localCard.id else { return nil }
            peerOffer = message
            peerCard = card
            return .gotOffer(name: card.name)
        case .ack:
            guard !isComplete, message.count > 48 else { return nil }
            let peerNonce = message.subdata(in: message.startIndex ..< message.startIndex + 16)
            let hash = message.subdata(in: message.startIndex + 16 ..< message.startIndex + 48)
            guard hash == Data(SHA256.hash(data: offer)) else {
                return .rejected("The other phone confirmed a different card; try again")
            }
            guard let card = try? ContactCard(encoded: message.subdata(in: message.startIndex + 48 ..< message.endIndex)),
                  card.id != localCard.id else { return .rejected("That code isn't a valid NXTPTT card") }
            if let peerCard, peerCard.id != card.id { return .rejected("Two different phones answered; try again") }
            let theirOffer = peerNonce + card.encoded
            if peerOffer == nil { peerOffer = theirOffer }
            peerCard = card
            isComplete = true
            return .completed(card: card, safetyCode: Self.safetyCode(offer, theirOffer))
        }
    }

    /// Six digits over both offers, in a fixed order so both phones show the same code.
    public static func safetyCode(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Data(SHA256.hash(data: Data("ePTT/1 face-pairing".utf8) + first + second))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    private static func encode(kind: Kind, session: Data, message: Data) -> [String] {
        let total = max(1, (message.count + chunkBytes - 1) / chunkBytes)
        return (0..<total).map { index in
            let start = message.startIndex + index * chunkBytes
            let chunk = message.subdata(in: start ..< min(message.endIndex, start + chunkBytes))
            let frame = Data([kind.rawValue]) + session + Data([UInt8(index), UInt8(total)]) + chunk
            return prefix + frame.base64URLEncoded
        }
    }
}
