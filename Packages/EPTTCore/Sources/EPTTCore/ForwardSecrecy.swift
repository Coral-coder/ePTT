import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Forward secrecy (PROTOCOL.md §3.1, §6.2, §6.3): rotating signed prekeys, one-time prekeys, a
// random key per burst wrapped to each recipient with a one-time ephemeral key and the pair's
// post-quantum epoch secret, and sealed group invites.

extension Primitives {
    /// X25519 with raw keys; rejects the all-zero output.
    static func x25519(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let raw = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        guard raw.contains(where: { $0 != 0 }) else { throw DecodingError.invalid("degenerate shared secret") }
        return raw
    }
}

/// A peer's current session prekey, signed by their identity key.
public struct SignedPrekey: Equatable, Codable {
    public static let encodedLength = 100

    public let id: UInt32
    public let publicKey: Data
    public let signature: Data

    public init(encoded data: Data) throws {
        guard data.count == SignedPrekey.encodedLength else { throw DecodingError.invalid("prekey length") }
        var reader = ByteReader(data)
        id = try reader.readUInt(UInt32.self)
        publicKey = try reader.read(32)
        signature = try reader.read(64)
        guard id != 0 else { throw DecodingError.invalid("prekey id 0 is reserved") }
    }

    init(id: UInt32, publicKey: Data, signature: Data) {
        self.id = id
        self.publicKey = publicKey
        self.signature = signature
    }

    public var encoded: Data {
        var out = Data.be(id)
        out.append(publicKey)
        out.append(signature)
        return out
    }

    static func signatureInput(id: UInt32, publicKey: Data) -> Data {
        var d = Primitives.label("ePTT/1 prekey")
        d.appendBE(id)
        d.append(publicKey)
        return d
    }

    public func isValid(for identity: PublicIdentity) -> Bool {
        identity.isValidSignature(signature, for: SignedPrekey.signatureInput(id: id, publicKey: publicKey))
    }
}

/// This device's prekeys. Persist it in the Keychain; it contains private keys.
public struct PrekeyStore: Codable, Equatable {
    public static let rotationInterval: TimeInterval = 6 * 3600
    /// How long a replaced prekey stays usable before its private key is deleted: the relay's
    /// lifetime plus margin, no more. Only bursts sent when no one-time key was left use it.
    public static let retention: TimeInterval = 30 * 3600

    struct Entry: Codable, Equatable {
        let id: UInt32
        let seed: Data
        let created: Date
        var retired: Date?
    }

    private(set) var entries: [Entry] = []

    public init() {}

    public var currentID: UInt32? { entries.last?.id }

    /// Creates the first prekey, rotates a stale one and deletes expired ones.
    /// Returns true if the advertised prekey changed.
    @discardableResult
    public mutating func rotateIfNeeded(now: Date = Date()) -> Bool {
        entries.removeAll { entry in
            guard let retired = entry.retired else { return false }
            return now.timeIntervalSince(retired) > PrekeyStore.retention
        }
        if let current = entries.last, now.timeIntervalSince(current.created) < PrekeyStore.rotationInterval {
            return false
        }
        if !entries.isEmpty { entries[entries.count - 1].retired = now }
        let nextID = (entries.last?.id ?? 0) &+ 1
        entries.append(Entry(id: nextID == 0 ? 1 : nextID, seed: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                             created: now, retired: nil))
        return true
    }

    /// The current prekey, signed for publication.
    public func current(signedBy identity: LocalIdentity) throws -> SignedPrekey? {
        guard let entry = entries.last else { return nil }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entry.seed).publicKey.rawRepresentation
        let signature = try identity.sign(SignedPrekey.signatureInput(id: entry.id, publicKey: publicKey))
        return SignedPrekey(id: entry.id, publicKey: publicKey, signature: signature)
    }

    /// X25519 between our prekey `id` and a peer's public key, if we still hold that prekey.
    public func agreement(id: UInt32, with publicKey: Data) throws -> Data {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw DecodingError.invalid("prekey \(id) no longer held")
        }
        return try Primitives.x25519(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entry.seed),
                                     publicKey: publicKey)
    }

    /// Test hook: install a prekey with a known seed.
    mutating func install(id: UInt32, seed: Data, created: Date = Date()) {
        entries.append(Entry(id: id, seed: seed, created: created, retired: nil))
    }
}

/// Key agreement for the local device: key `0` is the static identity key, ids with the top bit
/// set are one-time prekeys (only for the peer they were issued to), others signed prekeys.
public typealias LocalKeyAgreement = (_ keyID: UInt32, _ peerPublicKey: Data, _ sender: IdentityID?) throws -> Data

extension LocalIdentity {
    /// Combines the identity's static key (id 0), the signed prekeys and the one-time prekeys.
    public func keyAgreement(prekeys: @escaping () -> PrekeyStore,
                             oneTimeKeys: @escaping () -> OneTimeKeyStore = { OneTimeKeyStore() }) -> LocalKeyAgreement {
        let identity = self
        return { id, publicKey, sender in
            if id == 0 { return try identity.sharedSecret(withPublicKey: publicKey) }
            if OneTimeKeyStore.isOneTime(id) {
                guard let sender else { throw DecodingError.invalid("one-time key needs a sender") }
                return try oneTimeKeys().agreement(id: id, with: publicKey, from: sender)
            }
            return try prekeys().agreement(id: id, with: publicKey)
        }
    }
}

/// Where to seal something for a recipient: a one-time prekey of theirs, else their signed
/// prekey (else, for group invites only, their static key), mixed with the pair's epoch secret.
public struct SealTarget: Equatable {
    public let recipient: SenderID
    public let prekeyID: UInt32
    public let publicKey: Data
    /// The pairwise session epoch whose burst secret is mixed in.
    public let pairEpoch: UInt16
    public let pairSecret: Data

    public init(recipient: SenderID, prekeyID: UInt32, publicKey: Data, pairEpoch: UInt16, pairSecret: Data) {
        self.recipient = recipient
        self.prekeyID = prekeyID
        self.publicKey = publicKey
        self.pairEpoch = pairEpoch
        self.pairSecret = pairSecret
    }

    /// Prefers a one-time prekey, then the signed prekey, then (only if `allowStatic`) the
    /// static key. Nil if no acceptable key is known.
    public init?(identity: PublicIdentity, oneTimeKey: OneTimeKey?, prekey: SignedPrekey?, epoch: EpochKeys,
                 allowStatic: Bool = false) {
        recipient = identity.senderID
        pairEpoch = epoch.epoch
        pairSecret = epoch.burstSecret
        if let oneTimeKey {
            prekeyID = oneTimeKey.id
            publicKey = oneTimeKey.publicKey
        } else if let prekey {
            prekeyID = prekey.id
            publicKey = prekey.publicKey
        } else if allowStatic {
            prekeyID = 0
            publicKey = identity.keyAgreementPublicKey
        } else {
            return nil
        }
    }

    /// recipient(8) ‖ key id(4) ‖ pair epoch(2).
    var aad: Data { recipient.bytes + Data.be(prekeyID) + Data.be(pairEpoch) }
}

/// Finds the pair secret for (sender, pair epoch) when opening an envelope.
public typealias PairSecretLookup = (_ sender: SenderID, _ pairEpoch: UInt16) -> Data?

public enum BurstKeying {
    /// aad(14) ‖ AES-256-GCM(burst key) (32 + 16).
    public static let envelopeLength = 62

    /// Fresh burst key plus one envelope per recipient. The ephemeral private key never
    /// leaves this function.
    public static func makeEnvelopes(burstKey: Data, channelID: ChannelID, burstID: MessageID,
                                     targets: [SealTarget]) throws -> (ephemeralPublicKey: Data, envelopes: [Data]) {
        try makeEnvelopes(burstKey: burstKey, ephemeral: Curve25519.KeyAgreement.PrivateKey(),
                          channelID: channelID, burstID: burstID, targets: targets)
    }

    static func makeEnvelopes(burstKey: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey, channelID: ChannelID,
                              burstID: MessageID, targets: [SealTarget]) throws -> (ephemeralPublicKey: Data, envelopes: [Data]) {
        let envelopes = try targets.map { target -> Data in
            let dh = try Primitives.x25519(privateKey: ephemeral, publicKey: target.publicKey)
            let aad = target.aad
            let wrapKey = wrapKey(dh: dh, pairSecret: target.pairSecret, channelID: channelID, burstID: burstID, aad: aad)
            let sealed = try Primitives.aeadSeal(key: wrapKey, nonce: Data(count: 12), plaintext: burstKey, aad: aad)
            return aad + sealed
        }
        return (ephemeral.publicKey.rawRepresentation, envelopes)
    }

    public struct Opened: Equatable {
        public let burstKey: Data
        /// The local key the envelope was sealed to (a one-time prekey is deleted after use).
        public let keyID: UInt32
        public let pairEpoch: UInt16
    }

    /// Finds our envelope and recovers the burst key.
    public static func open(envelopes: [Data], ephemeralPublicKey: Data, channelID: ChannelID, burstID: MessageID,
                            recipient: SenderID, sender: PublicIdentity, agreement: LocalKeyAgreement,
                            pairSecret: PairSecretLookup) throws -> Opened {
        guard let envelope = envelopes.first(where: { $0.count == envelopeLength && $0.prefix(8) == recipient.bytes }) else {
            throw DecodingError.invalid("no envelope for us")
        }
        let aad = Data(envelope.prefix(14))
        let keyID = try UInt32(bigEndianBytes: aad.subdata(in: aad.startIndex + 8 ..< aad.startIndex + 12))
        let pairEpoch = try UInt16(bigEndianBytes: aad.suffix(2))
        // Voice and text are never sealed to the static key, nor under the classical epoch 0.
        guard keyID != 0, pairEpoch >= 1 else { throw DecodingError.invalid("envelope not post-quantum") }
        guard let secret = pairSecret(sender.senderID, pairEpoch) else {
            throw DecodingError.invalid("pair epoch \(pairEpoch) not held")
        }
        let dh = try agreement(keyID, ephemeralPublicKey, sender.id)
        let key = wrapKey(dh: dh, pairSecret: secret, channelID: channelID, burstID: burstID, aad: aad)
        let burstKey = try Primitives.aeadOpen(key: key, nonce: Data(count: 12),
                                               ciphertextAndTag: Data(envelope.dropFirst(14)), aad: aad)
        return Opened(burstKey: burstKey, keyID: keyID, pairEpoch: pairEpoch)
    }

    /// wrap = HKDF(ikm = X25519(eph, recipient key) ‖ pair burst secret, salt = burst ID, info = label ‖ channel ‖ aad)
    static func wrapKey(dh: Data, pairSecret: Data, channelID: ChannelID, burstID: MessageID, aad: Data) -> Data {
        Primitives.hkdf(ikm: dh + pairSecret, salt: burstID.bytes, info: Primitives.v2("wrap") + channelID.bytes + aad)
    }

    public static func messageKey(burstKey: Data, burstID: MessageID, senderID: SenderID, epoch: UInt16) -> Data {
        var info = Primitives.v2("burst-msg")
        info.append(senderID.bytes)
        info.appendBE(epoch)
        return Primitives.hkdf(ikm: burstKey, salt: burstID.bytes, info: info)
    }
}

enum InviteSealing {
    /// Group invites carry the group key: sealed to the invitee's prekey (static key only before
    /// they have published one) and the pair's current epoch secret.
    static func seal(_ inner: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey, messageID: MessageID,
                     target: SealTarget) throws -> Data {
        let dh = try Primitives.x25519(privateKey: ephemeral, publicKey: target.publicKey)
        let key = Primitives.hkdf(ikm: dh + target.pairSecret, salt: messageID.bytes,
                                  info: Primitives.v2("invite") + target.aad)
        let sealed = try Primitives.aeadSeal(key: key, nonce: Data(count: 12), plaintext: inner, aad: target.aad)
        return Data.be(target.prekeyID) + Data.be(target.pairEpoch) + sealed
    }

    static func open(_ sealed: Data, ephemeralPublicKey: Data, messageID: MessageID, recipient: SenderID,
                     sender: PublicIdentity, agreement: LocalKeyAgreement, pairSecret: PairSecretLookup) throws -> Data {
        guard sealed.count > 6 + 16 else { throw DecodingError.truncated }
        let prekeyID = try UInt32(bigEndianBytes: Data(sealed.prefix(4)))
        let pairEpoch = try UInt16(bigEndianBytes: Data(sealed.dropFirst(4).prefix(2)))
        // Epoch 0 is classical: invites need a post-quantum pair secret, like bursts.
        guard pairEpoch >= 1, let secret = pairSecret(sender.senderID, pairEpoch) else {
            throw DecodingError.invalid("pair epoch")
        }
        let aad = recipient.bytes + Data.be(prekeyID) + Data.be(pairEpoch)
        let key = Primitives.hkdf(ikm: try agreement(prekeyID, ephemeralPublicKey, sender.id) + secret,
                                  salt: messageID.bytes, info: Primitives.v2("invite") + aad)
        return try Primitives.aeadOpen(key: key, nonce: Data(count: 12), ciphertextAndTag: Data(sealed.dropFirst(6)),
                                       aad: aad)
    }
}
