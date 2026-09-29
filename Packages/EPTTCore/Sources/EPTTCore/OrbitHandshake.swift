import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Face-to-face pairing over Orbit codes (PROTOCOL.md §12). Phones held screen to screen, each
/// cycling its codes and reading the other's with the front camera.
///
/// 1. OFFER (kind 0): our `LightProfile`, in 28-byte frames.
/// 2. Once we hold the peer's whole offer, ACK (kind 1): the first 8 bytes of SHA-256 of the
///    offer we read, then our profile again.
/// 3. We are done when we read an ACK whose hash matches our own offer: the peer holds our real
///    profile, and we hold theirs. Both screens then show the same six-digit safety code.
///
/// A random session byte in every frame lets a phone ignore its own reflection.
public struct OrbitHandshake {
    public enum Event: Equatable {
        case gotOffer(LightProfile)
        case completed(LightProfile, safetyCode: String)
        case rejected(String)
    }

    public let session: UInt8
    private let offer: Data
    public private(set) var peer: LightProfile?
    private var peerOffer: Data?
    public private(set) var isComplete = false
    /// Frames being collected, by (peer session, kind).
    private var partial: [UInt16: [Int: [UInt8]]] = [:]
    private var totals: [UInt16: Int] = [:]
    /// How many of the current set's frames we hold, and how many there are (for progress).
    public private(set) var collected = (have: 0, of: 0)

    public init(profile: LightProfile, session: UInt8 = .random(in: 0...255)) {
        offer = profile.encoded
        self.session = session
    }

    /// The frames to show, in a loop: OFFER until we hold the peer's offer, then ACK.
    public var frames: [OrbitCode.Frame] {
        if let peerOffer {
            return Self.split(kind: 1, session: session, message: Data(SHA256.hash(data: peerOffer)).prefix(8) + offer)
        }
        return Self.split(kind: 0, session: session, message: offer)
    }

    /// Feeds one decoded code.
    public mutating func receive(_ frame: OrbitCode.Frame) -> Event? {
        guard frame.session != session, !isComplete else { return nil }
        let key = UInt16(frame.session) << 8 | UInt16(frame.kind)
        if totals[key] != frame.total { totals[key] = frame.total; partial[key] = [:] }
        partial[key, default: [:]][frame.index] = frame.payload
        let chunks = partial[key] ?? [:]
        if frame.kind == 1 || peerOffer == nil { collected = (chunks.count, frame.total) }
        guard chunks.count == frame.total else { return nil }
        let message = Data((0..<frame.total).flatMap { chunks[$0] ?? [] })

        if frame.kind == 0 {
            guard peerOffer == nil else { return nil }
            guard let profile = Self.profile(in: message) else { return .rejected("That isn't an NXTPTT code") }
            guard profile.encoded != offer else { return nil }
            peerOffer = profile.encoded
            peer = profile
            collected = (0, 0)
            return .gotOffer(profile)
        }
        guard message.count > 8 else { return nil }
        guard message.prefix(8) == Data(SHA256.hash(data: offer)).prefix(8) else {
            partial[key] = [:]
            return .rejected("The other phone read someone else's code; keep holding")
        }
        guard let profile = Self.profile(in: message.dropFirst(8)), profile.encoded != offer else {
            return .rejected("That isn't an NXTPTT code")
        }
        if let peer, peer != profile { return .rejected("Two different phones answered; try again") }
        peer = profile
        peerOffer = profile.encoded
        isComplete = true
        return .completed(profile, safetyCode: LightCode.safetyCode(offer, profile.encoded))
    }

    /// A profile from the front of zero-padded bytes.
    static func profile(in data: Data) -> LightProfile? {
        let d = Data(data)
        guard d.count >= 82 else { return nil }
        let length = 82 + Int(d[81])
        guard d.count >= length, d[length...].allSatisfy({ $0 == 0 }) else { return nil }
        return try? LightProfile(encoded: d.prefix(length))
    }

    static func split(kind: UInt8, session: UInt8, message: Data) -> [OrbitCode.Frame] {
        let size = OrbitCode.payloadBytes
        let total = (message.count + size - 1) / size
        precondition(total <= 7)
        return (0..<total).map { i in
            let chunk = message.dropFirst(i * size).prefix(size)
            return OrbitCode.Frame(kind: kind, index: i, total: total, session: session, payload: Array(chunk))
        }
    }
}
