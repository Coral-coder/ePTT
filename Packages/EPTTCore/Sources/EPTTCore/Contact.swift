import Foundation

/// A pinned peer plus what we have learned about reaching them since scanning their card.
public struct Contact: Identifiable, Equatable, Codable {
    public let identity: PublicIdentity
    public var name: String
    public var reachability: Reachability
    /// Timestamp of the newest card or HELLO applied, so stale updates are ignored.
    public var updatedAt: UInt64
    public var platform: Platform?
    /// The newest signed card, forwarded verbatim in group invites.
    public var cardData: Data

    public var id: IdentityID { identity.id }
    public var senderID: SenderID { identity.senderID }

    public init(card: ContactCard) {
        identity = card.identity
        name = card.name
        reachability = card.reachability
        updatedAt = card.timestamp
        platform = card.platform
        cardData = card.encoded
    }

    /// Applies a newer card for the same identity. Returns false if it is not newer or not ours.
    @discardableResult
    public mutating func apply(card: ContactCard) -> Bool {
        guard card.identity == identity, card.timestamp > updatedAt else { return false }
        name = card.name
        reachability.merge(card.reachability)
        updatedAt = card.timestamp
        platform = card.platform ?? platform
        cardData = card.encoded
        return true
    }

    /// Applies a HELLO received on this contact's direct channel.
    @discardableResult
    public mutating func apply(hello: Hello) -> Bool {
        guard hello.timestamp > updatedAt else { return false }
        if !hello.name.isEmpty { name = hello.name }
        reachability.merge(hello.reachability)
        updatedAt = hello.timestamp
        return true
    }

    /// Whether we can wake this contact through APNs.
    public var isWakeable: Bool {
        reachability.apnsPTTToken != nil && reachability.apnsTopic != nil
    }
}
