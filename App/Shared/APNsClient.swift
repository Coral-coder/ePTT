import Foundation
import os
import EPTTCore

/// Sends pushes straight to Apple, peer to peer. There is no NXTPTT server: the signing key ships
/// with the app (docs/ARCHITECTURE.md, "APNs key"; docs/SETUP.md for provisioning).
final class APNsClient {
    private let credentials: APNsCredentials
    private let session: URLSession
    private let log = Logger(subsystem: "app.eptt", category: "apns")
    private let lock = NSLock()
    private var cachedToken: (value: String, issued: Date)?

    let bundleID: String
    /// The environment of *this* build's push tokens (what peers must use to reach us).
    let environment: APNsEnvironment

    /// Loads credentials from Info.plist (`EPTTAPNsTeamID`, `EPTTAPNsKeyID`, `EPTTAPNsEnvironment`)
    /// and the bundled `APNsAuthKey.p8`. Returns nil when the build has no key, in which case
    /// the app still works in the foreground and through the iCloud relay.
    static func fromBundle(_ bundle: Bundle = .main) -> APNsClient? {
        let log = Logger(subsystem: "app.eptt", category: "apns")
        guard let teamID = bundle.object(forInfoDictionaryKey: "EPTTAPNsTeamID") as? String, !teamID.isEmpty,
              let keyID = bundle.object(forInfoDictionaryKey: "EPTTAPNsKeyID") as? String, !keyID.isEmpty,
              let keyURL = bundle.url(forResource: "APNsAuthKey", withExtension: "p8"),
              let pem = try? String(contentsOf: keyURL, encoding: .utf8) else {
            log.notice("No APNs key bundled")
            return nil
        }
        do {
            let credentials = try APNsCredentials(teamID: teamID, keyID: keyID, p8PEM: pem)
            return APNsClient(credentials: credentials, bundleID: bundle.bundleIdentifier ?? "",
                              environment: environment(of: bundle))
        } catch {
            log.error("Bundled APNs key is invalid: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A key shared in-app (see `PushKey`), used when the build has none bundled.
    static func fromKeychain(_ bundle: Bundle = .main) -> APNsClient? {
        guard let key = PushKeyKeychain.load(),
              let credentials = try? APNsCredentials(teamID: key.teamID, keyID: key.keyID, p8PEM: key.pem) else {
            return nil
        }
        return APNsClient(credentials: credentials, bundleID: bundle.bundleIdentifier ?? "",
                          environment: environment(of: bundle))
    }

    static func environment(of bundle: Bundle) -> APNsEnvironment {
        (bundle.object(forInfoDictionaryKey: "EPTTAPNsEnvironment") as? String) == "production" ? .production : .development
    }

    init(credentials: APNsCredentials, bundleID: String, environment: APNsEnvironment) {
        self.credentials = credentials
        self.bundleID = bundleID
        self.environment = environment
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Wakes a PushToTalk listener with a sealed WAKE packet. `completion` gets nil when Apple
    /// accepted the push, otherwise the reason it didn't (called on a background queue).
    func sendWake(_ packet: Data, to contact: Contact, completion: ((String?) -> Void)? = nil) {
        guard let token = contact.reachability.apnsPTTToken else {
            completion?("no push token for them")
            return
        }
        send(.pushToTalk, packet: packet, token: token, contact: contact, completion: completion)
    }

    /// A call alert as a visible notification (decrypted and completed by the extension).
    func sendAlert(_ packet: Data, to contact: Contact, completion: ((String?) -> Void)? = nil) {
        guard let token = contact.reachability.apnsDeviceToken else {
            completion?("no notification token for them")
            return
        }
        send(.alert(title: "Call alert", body: "Someone is trying to reach you"), packet: packet, token: token,
             contact: contact, completion: completion)
    }

    /// Delivers a HELLO to a (foreground) talker as a silent background push.
    func sendBackground(_ packet: Data, to contact: Contact) {
        guard let token = contact.reachability.apnsDeviceToken else { return }
        send(.background, packet: packet, token: token, contact: contact)
    }

    private func send(_ kind: APNsRequest.Kind, packet: Data, token: Data, contact: Contact,
                      completion: ((String?) -> Void)? = nil) {
        guard let providerToken = providerToken() else {
            completion?("the push key couldn't sign a request")
            return
        }
        let request = APNsRequest(
            kind: kind,
            deviceToken: token,
            environment: contact.reachability.apnsEnvironment ?? .production,
            bundleID: contact.reachability.apnsTopic ?? bundleID,
            providerToken: providerToken,
            packet: packet
        )
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }

        let name = contact.name
        session.dataTask(with: urlRequest) { [log] data, response, error in
            if let error {
                log.error("APNs \(String(describing: kind), privacy: .public) to \(name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                completion?("couldn't reach Apple: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                log.error("APNs \(String(describing: kind), privacy: .public) rejected (\(http.statusCode)): \(body, privacy: .public)")
                // APNs answers {"reason":"BadDeviceToken"} and the like.
                let reason = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String) ?? body
                completion?("Apple rejected it (\(http.statusCode) \(reason))")
            } else {
                completion?(nil)
            }
        }.resume()
    }

    private func providerToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedToken, Date().timeIntervalSince(cached.issued) < 50 * 60 { return cached.value }
        do {
            let now = Date()
            let token = try credentials.providerToken(issuedAt: now)
            cachedToken = (token, now)
            return token
        } catch {
            log.error("Could not sign APNs token: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
