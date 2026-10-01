import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// The pairwise session ratchet (PROTOCOL.md §5.3).
//
// Two paired devices share a root key that is replaced, never reused, by a fully ephemeral
// hybrid exchange: a fresh ML-KEM-1024 key pair and a fresh X25519 key pair on each side, both
// thrown away the moment the new root exists. Each root yields that epoch's channel key (control
// traffic) and burst secret (mixed into every voice envelope). Old roots are deleted, so:
//
//   - stealing a device later does not recover past epochs (forward secrecy), and
//   - an attacker who copied a device's state loses access again at the next rekey they don't
//     actively intercept (post-compromise security), and
//   - recording traffic now and breaking X25519 with a quantum computer later is not enough:
//     every epoch from 1 on also needs the ML-KEM-1024 secret (store-now-decrypt-later).
//
// Epoch 0 comes from the two static X25519 keys alone. It only carries the traffic needed to
// run the first exchange; no voice or text is ever sealed under it.

/// The keys one epoch of a pairwise session provides.
public struct EpochKeys: Codable, Equatable {
    public let epoch: UInt16
    /// Seals control packets on the direct channel at this epoch.
    public let channelKey: Data
    /// Mixed into every burst / text envelope between the two devices at this epoch.
    public let burstSecret: Data
    /// When a newer epoch replaced this one; it is deleted `PairSession.retention` later.
    public var retired: Date?

    static func derive(root: Data, epoch: UInt16, channelID: ChannelID) -> EpochKeys {
        let info = channelID.bytes + Data.be(epoch)
        return EpochKeys(epoch: epoch,
                         channelKey: Primitives.hkdf(ikm: root, salt: Data(), info: Primitives.v2("chan") + info),
                         burstSecret: Primitives.hkdf(ikm: root, salt: Data(), info: Primitives.v2("burst") + info),
                         retired: nil)
    }
}

/// PQ_OFFER (0x07): starts a rekey. Carries one-time public keys only.
public struct PQOffer: Equatable {
    public var offerID: MessageID
    public var baseEpoch: UInt16
    public var timestamp: UInt64
    public var kemPublicKey: Data
    public var dhPublicKey: Data

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.ephemeralKey, dhPublicKey)
        b.add(.kemPublicKey, kemPublicKey)
        b.add(.offerID, offerID.bytes)
        b.add(.baseEpoch, integer: baseEpoch)
        return b.encoded
    }

    public init(offerID: MessageID, baseEpoch: UInt16, timestamp: UInt64, kemPublicKey: Data, dhPublicKey: Data) {
        self.offerID = offerID
        self.baseEpoch = baseEpoch
        self.timestamp = timestamp
        self.kemPublicKey = kemPublicKey
        self.dhPublicKey = dhPublicKey
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        dhPublicKey = try f.require(.ephemeralKey)
        kemPublicKey = try f.require(.kemPublicKey)
        offerID = try MessageID(bytes: try f.require(.offerID))
        baseEpoch = try f.requireUInt(.baseEpoch)
        guard dhPublicKey.count == 32, kemPublicKey.count == PQKEM.publicKeyLength else {
            throw DecodingError.invalid("rekey offer keys")
        }
    }
}

/// PQ_ACCEPT (0x08): completes a rekey.
public struct PQAccept: Equatable {
    public var offerID: MessageID
    public var baseEpoch: UInt16
    public var timestamp: UInt64
    public var kemCiphertext: Data
    public var dhPublicKey: Data

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        b.add(.ephemeralKey, dhPublicKey)
        b.add(.kemCiphertext, kemCiphertext)
        b.add(.offerID, offerID.bytes)
        b.add(.baseEpoch, integer: baseEpoch)
        return b.encoded
    }

    public init(offerID: MessageID, baseEpoch: UInt16, timestamp: UInt64, kemCiphertext: Data, dhPublicKey: Data) {
        self.offerID = offerID
        self.baseEpoch = baseEpoch
        self.timestamp = timestamp
        self.kemCiphertext = kemCiphertext
        self.dhPublicKey = dhPublicKey
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        dhPublicKey = try f.require(.ephemeralKey)
        kemCiphertext = try f.require(.kemCiphertext)
        offerID = try MessageID(bytes: try f.require(.offerID))
        baseEpoch = try f.requireUInt(.baseEpoch)
        guard dhPublicKey.count == 32, kemCiphertext.count == PQKEM.ciphertextLength else {
            throw DecodingError.invalid("rekey accept keys")
        }
    }
}

/// One side of a pairwise session. Contains secrets: persist it only where channel keys live.
public struct PairSession: Codable, Equatable {
    /// How long a replaced epoch's keys stay usable (relayed messages can take this long).
    public static let retention: TimeInterval = 24 * 3600
    /// At most this many old epochs are kept, however recent.
    public static let maxRetained = 8
    /// An unanswered offer is abandoned (and its private keys deleted) after this long.
    public static let offerLifetime: TimeInterval = 24 * 3600

    struct PendingOffer: Codable, Equatable {
        let offerID: MessageID
        let baseEpoch: UInt16
        let kemSeed: Data
        let kemPublicKey: Data
        let dhSeed: Data
        let created: Date
    }

    struct SentAccept: Codable, Equatable {
        let offerID: MessageID
        let plaintext: Data
    }

    /// The newest epoch we hold keys for.
    public private(set) var epoch: UInt16
    /// The current root. Only the newest is ever kept.
    private var root: Data
    public private(set) var epochStarted: Date
    /// Newest last.
    private(set) var epochs: [EpochKeys]
    private var pending: PendingOffer?
    private var lastAccept: SentAccept?
    /// A responder's previous root, kept only until the initiator confirms the new epoch. If the
    /// initiator never got our accept and offers again from the old epoch, we step back to it.
    private var unconfirmedBase: Data?
    /// The epoch we seal with. A responder keeps sealing with the old epoch until the initiator
    /// shows it completed (by sending under the new one), so nothing is sent that the other
    /// side can't open yet.
    public private(set) var sendEpoch: UInt16

    /// Epoch 0 from the static X25519 keys: enough to run the first real exchange, nothing more.
    public static func bootstrap(local: LocalIdentity, peer: PublicIdentity, channelID: ChannelID,
                                 now: Date = Date()) throws -> PairSession {
        let shared = try local.sharedSecret(with: peer)
        let (lo, hi) = local.id < peer.id ? (local.id, peer.id) : (peer.id, local.id)
        let root = Primitives.hkdf(ikm: shared, salt: Primitives.v2("root0"), info: lo.bytes + hi.bytes)
        return PairSession(epoch: 0, root: root, epochStarted: now,
                           epochs: [EpochKeys.derive(root: root, epoch: 0, channelID: channelID)],
                           pending: nil, lastAccept: nil, unconfirmedBase: nil, sendEpoch: 0)
    }

    /// True once a post-quantum exchange has completed (epoch ≥ 1). Voice and text need this.
    public var isQuantumSafe: Bool { epoch >= 1 }

    public var currentKeys: EpochKeys { epochs[epochs.count - 1] }

    public func keys(forEpoch e: UInt16) -> EpochKeys? { epochs.last { $0.epoch == e } }

    public func channelKeys(channelID: ChannelID, epoch e: UInt16) -> ChannelKeys? {
        keys(forEpoch: e).flatMap { try? ChannelKeys(channelID: channelID, epoch: e, key: $0.channelKey) }
    }

    /// Keys to seal outgoing traffic with.
    public func sendingKeys(channelID: ChannelID) -> ChannelKeys {
        channelKeys(channelID: channelID, epoch: sendEpoch) ?? channelKeys(channelID: channelID, epoch: epoch)!
    }

    /// Every epoch's channel keys still held (for unshielding and opening).
    public func allChannelKeys(channelID: ChannelID) -> [ChannelKeys] {
        epochs.reversed().compactMap { try? ChannelKeys(channelID: channelID, epoch: $0.epoch, key: $0.channelKey) }
    }

    public var hasPendingOffer: Bool { pending != nil }

    /// Call when a packet sealed under `e` arrives from the peer: they hold that epoch.
    public mutating func peerUsed(epoch e: UInt16) {
        if e > sendEpoch, keys(forEpoch: e) != nil {
            sendEpoch = e
            if e == epoch { unconfirmedBase = nil }
        }
    }

    /// Deletes expired epochs and abandoned offers.
    public mutating func expire(now: Date = Date()) {
        let inUse = sendEpoch
        epochs.removeAll { k in
            guard let retired = k.retired, k.epoch != inUse else { return false }
            return now.timeIntervalSince(retired) > PairSession.retention
        }
        while epochs.count > PairSession.maxRetained + 1 { epochs.removeFirst() }
        if let p = pending, now.timeIntervalSince(p.created) > PairSession.offerLifetime { pending = nil }
    }

    // MARK: Rekey

    /// Starts a rekey (or returns the pending one, to retransmit).
    public mutating func offer(now: Date = Date()) throws -> PQOffer {
        if let p = pending, p.baseEpoch == epoch {
            return PQOffer(offerID: p.offerID, baseEpoch: p.baseEpoch, timestamp: currentTimestamp(now),
                           kemPublicKey: p.kemPublicKey, dhPublicKey: try Self.dhPublic(p.dhSeed))
        }
        let kem = try PQKEM.generate()
        let dh = Curve25519.KeyAgreement.PrivateKey()
        let p = PendingOffer(offerID: .random(), baseEpoch: epoch, kemSeed: kem.seed, kemPublicKey: kem.publicKey,
                             dhSeed: dh.rawRepresentation, created: now)
        pending = p
        return PQOffer(offerID: p.offerID, baseEpoch: p.baseEpoch, timestamp: currentTimestamp(now),
                       kemPublicKey: p.kemPublicKey, dhPublicKey: dh.publicKey.rawRepresentation)
    }

    public enum OfferResult: Equatable {
        /// Send this accept back (plaintext of a PQ_ACCEPT). The session advanced.
        case reply(Data)
        /// Nothing to do (stale, duplicate we can't serve, or we win the tie-break).
        case ignore
    }

    /// Answers a peer's offer. `localWins`: our identity sorts lower, so when both sides offer at
    /// once, ours stands and theirs is ignored.
    public mutating func receive(offer: PQOffer, channelID: ChannelID, localID: IdentityID, peerID: IdentityID,
                                 now: Date = Date()) throws -> OfferResult {
        if let sent = lastAccept, sent.offerID == offer.offerID { return .reply(sent.plaintext) }
        if offer.baseEpoch &+ 1 == epoch, sendEpoch < epoch, let base = unconfirmedBase {
            // They never completed our last accept: undo that epoch and answer this offer instead.
            let undone = epoch
            epochs.removeAll { $0.epoch == undone }
            for i in epochs.indices where epochs[i].epoch == offer.baseEpoch { epochs[i].retired = nil }
            root = base
            epoch = offer.baseEpoch
            unconfirmedBase = nil
        }
        guard offer.baseEpoch == epoch, epoch < UInt16.max else { return .ignore }
        if let p = pending, p.baseEpoch == epoch, localID < peerID { return .ignore }
        let kem = try PQKEM.encapsulate(to: offer.kemPublicKey)
        let dh = Curve25519.KeyAgreement.PrivateKey()
        let dhShared = try Primitives.x25519(privateKey: dh, publicKey: offer.dhPublicKey)
        let accept = PQAccept(offerID: offer.offerID, baseEpoch: offer.baseEpoch, timestamp: currentTimestamp(now),
                              kemCiphertext: kem.ciphertext, dhPublicKey: dh.publicKey.rawRepresentation)
        let transcript = Self.transcript(offer: offer, accept: accept, a: localID, b: peerID)
        let base = root
        advance(to: Self.ratchet(root: root, kemSecret: kem.sharedSecret, dhSecret: dhShared, transcript: transcript),
                channelID: channelID, confirmed: false, now: now)
        unconfirmedBase = base
        pending = nil
        lastAccept = SentAccept(offerID: offer.offerID, plaintext: accept.encoded)
        return .reply(accept.encoded)
    }

    /// Completes our own offer. Returns false if it doesn't match (stale or a duplicate).
    @discardableResult
    public mutating func receive(accept: PQAccept, channelID: ChannelID, localID: IdentityID, peerID: IdentityID,
                                 now: Date = Date()) throws -> Bool {
        guard let p = pending, p.offerID == accept.offerID, p.baseEpoch == accept.baseEpoch,
              accept.baseEpoch == epoch else { return false }
        let kemSecret = try PQKEM.decapsulate(seed: p.kemSeed, ciphertext: accept.kemCiphertext)
        let dh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: p.dhSeed)
        let dhShared = try Primitives.x25519(privateKey: dh, publicKey: accept.dhPublicKey)
        let offer = PQOffer(offerID: p.offerID, baseEpoch: p.baseEpoch, timestamp: 0, kemPublicKey: p.kemPublicKey,
                            dhPublicKey: dh.publicKey.rawRepresentation)
        let transcript = Self.transcript(offer: offer, accept: accept, a: localID, b: peerID)
        advance(to: Self.ratchet(root: root, kemSecret: kemSecret, dhSecret: dhShared, transcript: transcript),
                channelID: channelID, confirmed: true, now: now)
        unconfirmedBase = nil
        pending = nil   // the KEM and X25519 private keys go with it
        return true
    }

    private mutating func advance(to newRoot: Data, channelID: ChannelID, confirmed: Bool, now: Date) {
        let next = epoch + 1
        for i in epochs.indices where epochs[i].retired == nil { epochs[i].retired = now }
        epochs.append(EpochKeys.derive(root: newRoot, epoch: next, channelID: channelID))
        root = newRoot   // the old root is gone: the chain can't be walked back
        epoch = next
        epochStarted = now
        if confirmed { sendEpoch = next }
        expire(now: now)
    }

    // MARK: Derivation (PROTOCOL.md §5.3)

    static func dhPublic(_ seed: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    /// Binds the new root to both identities and every public value exchanged.
    static func transcript(offer: PQOffer, accept: PQAccept, a: IdentityID, b: IdentityID) -> Data {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        return Primitives.sha384(Primitives.v2("transcript"), lo.bytes, hi.bytes, offer.offerID.bytes,
                                 Data.be(offer.baseEpoch), offer.kemPublicKey, offer.dhPublicKey,
                                 accept.kemCiphertext, accept.dhPublicKey)
    }

    /// root' = HKDF-SHA-384(ikm = ML-KEM secret ‖ X25519 secret, salt = root, info = label ‖ transcript)
    static func ratchet(root: Data, kemSecret: Data, dhSecret: Data, transcript: Data) -> Data {
        Primitives.hkdf(ikm: kemSecret + dhSecret, salt: root, info: Primitives.v2("ratchet") + transcript)
    }

    /// Test hook: a session at a given root.
    static func testing(root: Data, epoch: UInt16, channelID: ChannelID, now: Date = Date()) -> PairSession {
        PairSession(epoch: epoch, root: root, epochStarted: now,
                    epochs: [EpochKeys.derive(root: root, epoch: epoch, channelID: channelID)],
                    pending: nil, lastAccept: nil, unconfirmedBase: nil, sendEpoch: epoch)
    }
}
