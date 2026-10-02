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
        // One inbox per contact (§11.1): ask in batches so no single query gets unwieldy.
        var records: [CKRecord] = []
        for start in stride(from: 0, to: tags.count, by: 60) {
            let batch = Array(tags[start..<min(start + 60, tags.count)])
            let query = CKQuery(recordType: CloudRelay.recordType, predicate: NSPredicate(format: "mailbox IN %@", batch))
            var (results, cursor) = try await database.records(matching: query, resultsLimit: 50)
            records += results.compactMap { try? $0.1.get() }
            // Follow the cursor (a few pages at most), so one busy inbox can't hide the others.
            var pages = 1
            while let next = cursor, pages < 6 {
                (results, cursor) = try await database.records(continuingMatchFrom: next, resultsLimit: 50)
                records += results.compactMap { try? $0.1.get() }
                pages += 1
            }
        }
        return records.compactMap { record -> (name: String, payload: Data, created: Date)? in
            guard let payload = record["payload"] as? Data else { return nil }
            if let expires = record["expires"] as? Date, expires < Date() { return nil }
            return (record.recordID.recordName, payload, record.creationDate ?? .distantPast)
        }
        .sorted { $0.created < $1.created }
    }

    /// One record by name (the notification service extension gets the name from the push).
    func fetch(recordName: String) async throws -> Data? {
        let record = try await database.record(for: CKRecord.ID(recordName: recordName))
        if let expires = record["expires"] as? Date, expires < Date() { return nil }
        return record["payload"] as? Data
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

    /// (Re)creates the push subscriptions for our current inbox tags, one per tag. iCloud then
    /// notifies us of new relayed messages, which works even without an APNs push key.
    /// Throws if iCloud refused them, so the app can say so.
    func subscribe(tags: [String]) async throws {
        // One plain equality subscription per tag: the most widely supported predicate form.
        let subscriptions = tags.enumerated().map { index, tag -> CKSubscription in
            let subscription = CKQuerySubscription(
                recordType: CloudRelay.recordType,
                predicate: NSPredicate(format: "mailbox == %@", tag),
                subscriptionID: "\(CloudRelay.subscriptionID)-\(index)",
                options: [.firesOnRecordCreation]
            )
            let info = CKSubscription.NotificationInfo()
            info.alertBody = "New voice message"
            info.soundName = "default"
            // No background launch of the app for every record: the extension plays messages,
            // and the app reads the rest of the inbox when it next opens. (Waking the app for
            // each record cost battery on both phones.)
            info.shouldSendContentAvailable = false
            // Lets the notification service extension decode the message and play it as the sound.
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            return subscription
        }
        let existing = (try? await database.allSubscriptions()) ?? []
        let keep = Set(subscriptions.map(\.subscriptionID))
        // Includes the old single "relay-inbox" subscription from earlier versions.
        let stale = existing.map(\.subscriptionID).filter { $0.hasPrefix(CloudRelay.subscriptionID) && !keep.contains($0) }
        // In batches: iCloud limits how many changes one request may carry.
        for start in stride(from: 0, to: max(subscriptions.count, stale.count), by: 150) {
            let saving = Array(subscriptions.dropFirst(start).prefix(150))
            let deleting = Array(stale.dropFirst(start).prefix(150))
            let (saved, _) = try await database.modifySubscriptions(saving: saving, deleting: deleting)
            for case let (_, .failure(error)) in saved {
                log.error("Relay subscription failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    /// The whole story of a CloudKit error, for Settings › Status: its code, iCloud's own
    /// explanation and, for a batch, each item's error. `localizedDescription` alone cuts the
    /// reason off.
    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        var parts = ["CKError \(ck.errorCode)"]
        let info = (ck as NSError).userInfo
        if let server = info["ServerErrorDescription"] as? String { parts.append(server) }
        parts.append(ck.localizedDescription)
        if let items = ck.partialErrorsByItemID {
            for (id, itemError) in items.prefix(2) { parts.append("\(id): \(describe(itemError))") }
        }
        if let underlying = info[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    static func isRelayNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID?.hasPrefix(subscriptionID) == true
    }

    /// The relay record a push is about, if it is one of ours.
    static func recordName(inNotification userInfo: [AnyHashable: Any]) -> String? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID?.hasPrefix(subscriptionID) == true else { return nil }
        return notification.recordID?.recordName
    }
}
