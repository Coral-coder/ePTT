import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Thin wrappers over CryptoKit (or swift-crypto on Linux) matching PROTOCOL.md's notation.
enum Primitives {
    static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func aeadSeal(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    static func aeadOpen(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw DecodingError.truncated }
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertextAndTag.prefix(ciphertextAndTag.count - 16),
            tag: ciphertextAndTag.suffix(16)
        )
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    static func label(_ s: String) -> Data { Data(s.utf8) }
}
