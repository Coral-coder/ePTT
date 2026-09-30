import Foundation
import Security
import EPTTCore

/// Stores the device identity's private keys. They never leave this device
/// (`ThisDeviceOnly`) and are readable after first unlock so pushes can wake a locked phone.
enum IdentityKeychain {
    private static let service = "app.eptt.identity"
    private static let account = "local-identity-v1"

    static func loadOrCreate() -> LocalIdentity {
        if let stored = load() { return stored }
        let identity = LocalIdentity.generate()
        save(identity)
        return identity
    }

    private static func load() -> LocalIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 64 else { return nil }
        return try? LocalIdentity(signingSeed: data.prefix(32), keyAgreementSeed: data.suffix(32))
    }

    private static func save(_ identity: LocalIdentity) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = identity.signingSeed + identity.keyAgreementSeed
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// An APNs signing key shared among a group of friends, so builds published on a public page do
/// not have to carry it (docs/SETUP.md, "Sharing the push key").
struct PushKey: Codable, Equatable {
    static let uriPrefix = "eptt://pushkey/"

    var teamID: String
    var keyID: String
    var pem: String

    init(teamID: String, keyID: String, pem: String) {
        self.teamID = teamID
        self.keyID = keyID
        self.pem = pem
    }

    init(uri: String) throws {
        guard uri.hasPrefix(PushKey.uriPrefix),
              let data = Data(base64URLEncoded: String(uri.dropFirst(PushKey.uriPrefix.count))) else {
            throw EPTTCore.DecodingError.invalid("push key link")
        }
        self = try JSONDecoder().decode(PushKey.self, from: data)
        _ = try APNsCredentials(teamID: teamID, keyID: keyID, p8PEM: pem) // validate before storing
    }

    var uri: String {
        PushKey.uriPrefix + ((try? JSONEncoder().encode(self)) ?? Data()).base64URLEncoded
    }

    /// The key bundled into this build (TestFlight builds carry one), if any.
    static func fromBundle(_ bundle: Bundle = .main) -> PushKey? {
        guard let teamID = bundle.object(forInfoDictionaryKey: "EPTTAPNsTeamID") as? String, !teamID.isEmpty,
              let keyID = bundle.object(forInfoDictionaryKey: "EPTTAPNsKeyID") as? String, !keyID.isEmpty,
              let url = bundle.url(forResource: "APNsAuthKey", withExtension: "p8"),
              let pem = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PushKey(teamID: teamID, keyID: keyID, pem: pem)
    }
}

enum PushKeyKeychain {
    private static let service = "app.eptt.pushkey"
    private static let account = "apns-v1"

    static func load() -> PushKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PushKey.self, from: data)
    }

    static func save(_ key: PushKey?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, let data = try? JSONEncoder().encode(key) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Session prekeys (private keys). Device-only; deleting old ones is what gives forward secrecy.
enum PrekeyKeychain {
    private static let service = "app.eptt.prekeys"
    private static let account = "prekeys-v1"

    static func load() -> PrekeyStore {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let store = try? JSONDecoder().decode(PrekeyStore.self, from: data) else { return PrekeyStore() }
        return store
    }

    static func save(_ store: PrekeyStore) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = try? JSONEncoder().encode(store) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// A copy of the display name the user chose, so it survives anything that resets the app's
/// saved state (a failed migration, an offload and reinstall). Not secret; the Keychain is just
/// the one store iOS keeps across all of those.
enum NameKeychain {
    private static let service = "app.eptt.profile"
    private static let account = "display-name-v1"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let name = String(data: data, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    static func save(_ name: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(name.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
