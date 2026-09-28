import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 16-byte identity identifier: `SHA-256(sign_pk)[0..16]` (PROTOCOL.md §3).
public struct IdentityID: Hashable, Codable, Comparable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw DecodingError.invalid("identity id length") }
        self.bytes = bytes
    }

    public init(signingPublicKey: Data) {
        bytes = Primitives.sha256(signingPublicKey).prefix(16)
    }

    public var senderID: SenderID { SenderID(unchecked: bytes.prefix(8)) }
    public var description: String { bytes.hex }

    public static func < (lhs: IdentityID, rhs: IdentityID) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

/// 8-byte sender identifier carried in packet headers.
public struct SenderID: Hashable, Codable, Comparable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 8 else { throw DecodingError.invalid("sender id length") }
        self.bytes = Data(bytes)
    }

    init(unchecked bytes: Data) { self.bytes = Data(bytes) }

    public var description: String { bytes.hex }
    public static func < (lhs: SenderID, rhs: SenderID) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

/// A peer's public identity: what we pin after verifying their contact card.
public struct PublicIdentity: Hashable, Codable {
    public let signingPublicKey: Data
    public let keyAgreementPublicKey: Data

    public init(signingPublicKey: Data, keyAgreementPublicKey: Data) throws {
        guard signingPublicKey.count == 32, keyAgreementPublicKey.count == 32 else {
            throw DecodingError.invalid("public key length")
        }
        self.signingPublicKey = Data(signingPublicKey)
        self.keyAgreementPublicKey = Data(keyAgreementPublicKey)
    }

    public var id: IdentityID { IdentityID(signingPublicKey: signingPublicKey) }
    public var senderID: SenderID { id.senderID }

    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// This device's identity, including private keys. Persist `signingSeed` and
/// `keyAgreementSeed` in the Keychain only.
public struct LocalIdentity {
    private let signingKey: Curve25519.Signing.PrivateKey
    private let keyAgreementKey: Curve25519.KeyAgreement.PrivateKey
    public let publicIdentity: PublicIdentity

    public init(signingSeed: Data, keyAgreementSeed: Data) throws {
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingSeed)
        keyAgreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyAgreementSeed)
        publicIdentity = try PublicIdentity(
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            keyAgreementPublicKey: keyAgreementKey.publicKey.rawRepresentation
        )
    }

    public static func generate() -> LocalIdentity {
        // Force-try is safe: fresh CryptoKit keys always round-trip through their raw form.
        try! LocalIdentity(
            signingSeed: Curve25519.Signing.PrivateKey().rawRepresentation,
            keyAgreementSeed: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
    }

    public var signingSeed: Data { signingKey.rawRepresentation }
    public var keyAgreementSeed: Data { keyAgreementKey.rawRepresentation }
    public var id: IdentityID { publicIdentity.id }
    public var senderID: SenderID { publicIdentity.senderID }

    public func sign(_ message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }

    /// Raw X25519 output with a peer. Throws on the all-zero (degenerate) result.
    public func sharedSecret(with peer: PublicIdentity) throws -> Data {
        try sharedSecret(withPublicKey: peer.keyAgreementPublicKey)
    }

    /// Raw X25519 output between our static key and any X25519 public key (e.g. an ephemeral one).
    public func sharedSecret(withPublicKey publicKey: Data) throws -> Data {
        try Primitives.x25519(privateKey: keyAgreementKey, publicKey: publicKey)
    }
}

public enum SafetyNumber {
    /// Six groups of five digits (PROTOCOL.md §3). Symmetric in its arguments.
    public static func compute(_ a: PublicIdentity, _ b: PublicIdentity) -> String {
        let (lo, hi) = a.signingPublicKey.lexicographicallyPrecedes(b.signingPublicKey)
            ? (a.signingPublicKey, b.signingPublicKey)
            : (b.signingPublicKey, a.signingPublicKey)
        let digest = [UInt8](Primitives.sha256(Primitives.label("ePTT/1 safety"), lo, hi))
        return (0..<6).map { i -> String in
            var value: UInt64 = 0
            for byte in digest[(5 * i)..<(5 * i + 5)] { value = value << 8 | UInt64(byte) }
            let group = String(value % 100_000)
            return String(repeating: "0", count: 5 - group.count) + group
        }.joined(separator: " ")
    }
}
