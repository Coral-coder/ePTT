import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Thin wrappers over CryptoKit (or swift-crypto on Linux) matching PROTOCOL.md's notation.
///
/// Protocol 2 uses a CNSA-aligned suite for everything that protects content (PROTOCOL.md §0):
/// AES-256-GCM, HKDF-SHA-384 and ML-KEM-1024 (hybrid with X25519). Identity IDs, safety
/// numbers and card signatures keep their protocol-1 definitions so existing pairings survive.
enum Primitives {
    static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func sha384(_ parts: Data...) -> Data {
        var hasher = SHA384()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// HKDF-SHA-384.
    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        let key = HKDF<SHA384>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// AES-256-GCM. Returns ciphertext || 16-byte tag.
    static func aeadSeal(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        precondition(key.count == 32, "AES-256 key")
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    static func aeadOpen(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16, key.count == 32 else { throw DecodingError.truncated }
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertextAndTag.prefix(ciphertextAndTag.count - 16),
            tag: ciphertextAndTag.suffix(16)
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    static func label(_ s: String) -> Data { Data(s.utf8) }

    /// Protocol-2 domain separation: every derivation label starts with this.
    static func v2(_ s: String) -> Data { Data(("NXTPTT/2 " + s).utf8) }
}

/// ML-KEM-1024 (FIPS 203), the post-quantum half of every key exchange in protocol 2.
public enum PQKEM {
    public static let publicKeyLength = 1568
    public static let ciphertextLength = 1568

    /// A fresh decapsulation key. Keep only `seed` (64 bytes); the private key is rebuilt from it.
    public static func generate() throws -> (seed: Data, publicKey: Data) {
        let key = try MLKEM1024.PrivateKey()
        return (key.seedRepresentation, key.publicKey.rawRepresentation)
    }

    /// Encapsulates to a peer's public key: (shared secret, ciphertext to send).
    public static func encapsulate(to publicKey: Data) throws -> (sharedSecret: Data, ciphertext: Data) {
        guard publicKey.count == publicKeyLength else { throw DecodingError.invalid("ML-KEM public key length") }
        let result = try MLKEM1024.PublicKey(rawRepresentation: publicKey).encapsulate()
        return (result.sharedSecret.withUnsafeBytes { Data($0) }, result.encapsulated)
    }

    public static func decapsulate(seed: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count == ciphertextLength else { throw DecodingError.invalid("ML-KEM ciphertext length") }
        let key = try MLKEM1024.PrivateKey(seedRepresentation: seed, publicKey: nil)
        return try key.decapsulate(ciphertext).withUnsafeBytes { Data($0) }
    }
}
