import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Forward secrecy (PROTOCOL.md §3.1, §6.2, §6.3): rotating signed prekeys, a random key per
// burst wrapped to each recipient with a one-time ephemeral key, and sealed group invites.

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
    public static let rotationInterval: TimeInterval = 24 * 3600
    /// How long a replaced prekey stays usable before its private key is deleted.
    public static let retention: TimeInterval = 7 * 24 * 3600

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

/// Key agreement for the local device: prekey `0` means the static identity key.
public typealias LocalKeyAgreement = (_ prekeyID: UInt32, _ peerPublicKey: Data) throws -> Data

extension LocalIdentity {
    /// Combines the identity's static key (id 0) with the prekey store.
    public func keyAgreement(prekeys: @escaping () -> PrekeyStore) -> LocalKeyAgreement {
        let identity = self
        return { id, publicKey in
            if id == 0 { return try identity.sharedSecret(withPublicKey: publicKey) }
            return try prekeys().agreement(id: id, with: publicKey)
        }
    }
}

/// Where to seal something for a recipient: their prekey if known, else their static key.
public struct SealTarget: Equatable {
    public let recipient: SenderID
    public let prekeyID: UInt32
    public let publicKey: Data

    public init(recipient: SenderID, prekeyID: UInt32, publicKey: Data) {
        self.recipient = recipient
        self.prekeyID = prekeyID
        self.publicKey = publicKey
    }

    public init(identity: PublicIdentity, prekey: SignedPrekey?) {
        recipient = identity.senderID
        if let prekey {
            prekeyID = prekey.id
            publicKey = prekey.publicKey
        } else {
            prekeyID = 0
            publicKey = identity.keyAgreementPublicKey
        }
    }

    var aad: Data { recipient.bytes + Data.be(prekeyID) }
}

public enum BurstKeying {
    public static let envelopeLength = 60

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
            let wrapKey = Primitives.hkdf(ikm: try Primitives.x25519(privateKey: ephemeral, publicKey: target.publicKey),
                                          salt: burstID.bytes, info: wrapInfo(channelID: channelID, aad: target.aad))
            let aad = target.aad
            let sealed = try Primitives.aeadSeal(key: wrapKey, nonce: Data(count: 12), plaintext: burstKey, aad: aad)
            return aad + sealed
        }
        return (ephemeral.publicKey.rawRepresentation, envelopes)
    }

    /// Finds our envelope and recovers the burst key.
    public static func open(envelopes: [Data], ephemeralPublicKey: Data, channelID: ChannelID, burstID: MessageID,
                            recipient: SenderID, agreement: LocalKeyAgreement) throws -> Data {
        guard let envelope = envelopes.first(where: { $0.count == envelopeLength && $0.prefix(8) == recipient.bytes }) else {
            throw DecodingError.invalid("no envelope for us")
        }
        let aad = Data(envelope.prefix(12))
        let prekeyID = try UInt32(bigEndianBytes: aad.suffix(4))
        let wrapKey = Primitives.hkdf(ikm: try agreement(prekeyID, ephemeralPublicKey), salt: burstID.bytes,
                                      info: wrapInfo(channelID: channelID, aad: aad))
        return try Primitives.aeadOpen(key: wrapKey, nonce: Data(count: 12),
                                       ciphertextAndTag: Data(envelope.dropFirst(12)), aad: aad)
    }

    static func wrapInfo(channelID: ChannelID, aad: Data) -> Data {
        Primitives.label("ePTT/1 wrap") + channelID.bytes + aad
    }

    public static func messageKey(burstKey: Data, burstID: MessageID, senderID: SenderID, epoch: UInt16) -> Data {
        var info = Primitives.label("ePTT/1 burst-msg")
        info.append(senderID.bytes)
        info.appendBE(epoch)
        return Primitives.hkdf(ikm: burstKey, salt: burstID.bytes, info: info)
    }
}

enum InviteSealing {
    static func seal(_ inner: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey, messageID: MessageID,
                     target: SealTarget) throws -> Data {
        let key = Primitives.hkdf(ikm: try Primitives.x25519(privateKey: ephemeral, publicKey: target.publicKey),
                                  salt: messageID.bytes, info: Primitives.label("ePTT/1 invite") + target.aad)
        let sealed = try Primitives.aeadSeal(key: key, nonce: Data(count: 12), plaintext: inner, aad: target.aad)
        return Data.be(target.prekeyID) + sealed
    }

    static func open(_ sealed: Data, ephemeralPublicKey: Data, messageID: MessageID, recipient: SenderID,
                     agreement: LocalKeyAgreement) throws -> Data {
        guard sealed.count > 4 + 16 else { throw DecodingError.truncated }
        let prekeyID = try UInt32(bigEndianBytes: Data(sealed.prefix(4)))
        let aad = recipient.bytes + Data.be(prekeyID)
        let key = Primitives.hkdf(ikm: try agreement(prekeyID, ephemeralPublicKey), salt: messageID.bytes,
                                  info: Primitives.label("ePTT/1 invite") + aad)
        return try Primitives.aeadOpen(key: key, nonce: Data(count: 12), ciphertextAndTag: Data(sealed.dropFirst(4)),
                                       aad: aad)
    }
}
