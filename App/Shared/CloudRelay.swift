import CloudKit
import Foundation
import os
import EPTTCore

/// Store-and-forward fallback on the app's CloudKit public database (PROTOCOL.md §11).
///
/// Apple hosts it, so there is still no server to run. Records hold only sealed packets
/// (audio is protected by per-burst keys that only recipients can unwrap), are filed under
/// daily-rotating tags derived from a secret mailbox, and are deleted after delivery or expiry.
final class CloudRelay {
    static let recordType = "RelayMessage"
    private static let subscriptionID = "relay-inbox"

    private let database: CKDatabase
    private let log = Logger(subsystem: "app.eptt", category: "relay")

    /// Reads the container from Info.plist (`EPTTCloudContainer`); nil if the build has none.
    init?(bundle: Bundle = .main) {
        guard let identifier = bundle.object(forInfoDictionaryKey: "EPTTCloudContainer") as? String,
              identifier.hasPrefix("iCloud.") else { return nil }
        database = CKContainer(identifier: identifier).publicCloudDatabase
    }

    /// Leaves a sealed burst for a recipient. Returns the record name for later cleanup.
    func upload(payload: Data, tag: String) async throws -> String {
        let record = CKRecord(recordType: CloudRelay.recordType)
        record["mailbox"] = tag as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["expires"] = Date().addingTimeInterval(Relay.lifetime) as CKRecordValue
        let saved = try await database.save(record)
        return saved.recordID.recordName
    }

    /// Records waiting under any of our inbox tags, oldest first.
    func fetch(tags: [String]) async throws -> [(name: String, payload: Data, created: Date)] {
        let query = CKQuery(recordType: CloudRelay.recordType, predicate: NSPredicate(format: "mailbox IN %@", tags))
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        let records = results.compactMap { try? $0.1.get() }
        return records.compactMap { record -> (name: String, payload: Data, created: Date)? in
            guard let payload = record["payload"] as? Data else { return nil }
            if let expires = record["expires"] as? Date, expires < Date() { return nil }
            return (record.recordID.recordName, payload, record.creationDate ?? .distantPast)
        }
        .sorted { $0.created < $1.created }
    }

    /// Deletes a delivered or expired record. Recipients can only do this if the container's
    /// security roles allow it (docs/SETUP.md); otherwise the talker's expiry cleanup removes it.
    func delete(recordName: String) async {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch {
            log.notice("Relay delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// (Re)creates the push subscription for our current inbox tags. iCloud then notifies us of
    /// new relayed messages, which works even without an APNs push key.
    func subscribe(tags: [String]) async {
        let subscription = CKQuerySubscription(
            recordType: CloudRelay.recordType,
            predicate: NSPredicate(format: "mailbox IN %@", tags),
            subscriptionID: CloudRelay.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "New voice message"
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try? await database.deleteSubscription(withID: CloudRelay.subscriptionID)
            _ = try await database.save(subscription)
        } catch {
            log.notice("Relay subscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func isRelayNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }
}
