import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Credentials for token-based APNs auth. See docs/ARCHITECTURE.md ("APNs key") for why the
/// app carries these itself instead of a server.
public struct APNsCredentials {
    public let teamID: String
    public let keyID: String
    private let key: P256.Signing.PrivateKey

    /// - Parameter p8PEM: contents of the `AuthKey_XXXXXXXXXX.p8` file from the developer portal.
    public init(teamID: String, keyID: String, p8PEM: String) throws {
        self.teamID = teamID
        self.keyID = keyID
        key = try P256.Signing.PrivateKey(pemRepresentation: p8PEM)
    }

    /// An ES256 provider token. APNs accepts a token for up to 60 minutes; refresh every ~50.
    public func providerToken(issuedAt: Date = Date()) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID] as [String: Any], options: [.sortedKeys])
        let claims = try JSONSerialization.data(
            withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)] as [String: Any], options: [.sortedKeys])
        let signingInput = header.base64URLEncoded + "." + claims.base64URLEncoded
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + signature.rawRepresentation.base64URLEncoded
    }
}

/// A fully described APNs HTTP/2 request, independent of the networking stack.
public struct APNsRequest: Equatable {
    public enum Kind: Equatable {
        /// Wakes a PushToTalk listener (PROTOCOL.md §8.1).
        case pushToTalk
        /// Silent background push, used for wake acknowledgements (PROTOCOL.md §8.2).
        case background
    }

    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(kind: Kind, deviceToken: Data, environment: APNsEnvironment, bundleID: String,
                providerToken: String, packet: Data) {
        let host = environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        url = URL(string: "https://\(host)/3/device/\(deviceToken.hex)")!
        let packetString = packet.base64URLEncoded
        var headers = ["authorization": "bearer \(providerToken)"]
        switch kind {
        case .pushToTalk:
            headers["apns-push-type"] = "pushtotalk"
            headers["apns-topic"] = bundleID + ".voip-ptt"
            headers["apns-priority"] = "10"
            headers["apns-expiration"] = "0"
            body = try! JSONSerialization.data(withJSONObject: ["eptt": packetString] as [String: Any], options: [.sortedKeys])
        case .background:
            headers["apns-push-type"] = "background"
            headers["apns-topic"] = bundleID
            headers["apns-priority"] = "5"
            body = try! JSONSerialization.data(
                withJSONObject: ["aps": ["content-available": 1], "eptt": packetString] as [String: Any], options: [.sortedKeys])
        }
        self.headers = headers
    }

    /// Pulls the Chirp packet back out of a received push payload.
    public static func packet(fromPayload payload: [AnyHashable: Any]) -> Data? {
        (payload["eptt"] as? String).flatMap { Data(base64URLEncoded: $0) }
    }
}
