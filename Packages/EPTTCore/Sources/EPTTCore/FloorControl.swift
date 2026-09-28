import Foundation

/// Orders overlapping bursts identically on every device (PROTOCOL.md §7).
public struct BurstOrder: Comparable, Equatable {
    public let timestamp: UInt64
    public let sender: SenderID

    public init(timestamp: UInt64, sender: SenderID) {
        self.timestamp = timestamp
        self.sender = sender
    }

    public static func < (lhs: BurstOrder, rhs: BurstOrder) -> Bool {
        lhs.timestamp != rhs.timestamp ? lhs.timestamp < rhs.timestamp : lhs.sender < rhs.sender
    }
}

/// Decentralized half-duplex floor control. Pure state machine: feed it events,
/// act on the outputs. The same rules run on every device, so collisions resolve
/// consistently without an arbiter.
public struct FloorControl {
    public static let hangTime: TimeInterval = 1.5

    public enum State: Equatable {
        case idle
        case transmitting(channel: ChannelID, burst: MessageID, order: BurstOrder)
        case receiving(channel: ChannelID, burst: MessageID, order: BurstOrder, lastHeard: Date)
    }

    public enum Output: Equatable {
        /// Start transmitting with this burst ID and BURST_START timestamp.
        case transmitGranted(channel: ChannelID, burst: MessageID, timestamp: UInt64)
        /// Someone else holds this channel: play the busy "bonk".
        case busy(channel: ChannelID)
        /// Stop transmitting (released or lost a collision). `preempted` means play the bonk.
        case transmitEnded(channel: ChannelID, burst: MessageID, preempted: Bool)
        /// Begin playing a remote burst.
        case receiveStarted(channel: ChannelID, burst: MessageID, sender: SenderID)
        /// Stop playing a remote burst (BURST_END, hang-time timeout or interruption).
        case receiveEnded(channel: ChannelID, burst: MessageID)
    }

    public private(set) var state: State = .idle
    public let localSender: SenderID

    public init(localSender: SenderID) { self.localSender = localSender }

    // MARK: - Local user

    public mutating func pressTalk(on channel: ChannelID, now: Date = Date(),
                                   burst: MessageID = .random()) -> [Output] {
        switch state {
        case .transmitting:
            return []
        case .receiving(let rxChannel, let rxBurst, _, _):
            if rxChannel == channel { return [.busy(channel: channel)] }
            // Talking on the selected channel pre-empts playback of a scanned one.
            let timestamp = currentTimestamp(now)
            state = .transmitting(channel: channel, burst: burst, order: BurstOrder(timestamp: timestamp, sender: localSender))
            return [.receiveEnded(channel: rxChannel, burst: rxBurst),
                    .transmitGranted(channel: channel, burst: burst, timestamp: timestamp)]
        case .idle:
            let timestamp = currentTimestamp(now)
            state = .transmitting(channel: channel, burst: burst, order: BurstOrder(timestamp: timestamp, sender: localSender))
            return [.transmitGranted(channel: channel, burst: burst, timestamp: timestamp)]
        }
    }

    public mutating func releaseTalk() -> [Output] {
        guard case .transmitting(let channel, let burst, _) = state else { return [] }
        state = .idle
        return [.transmitEnded(channel: channel, burst: burst, preempted: false)]
    }

    // MARK: - Remote traffic

    /// A verified BURST_START from another member.
    public mutating func remoteBurstStarted(channel: ChannelID, burst: MessageID, sender: SenderID,
                                            timestamp: UInt64, now: Date = Date()) -> [Output] {
        let order = BurstOrder(timestamp: timestamp, sender: sender)
        switch state {
        case .idle:
            state = .receiving(channel: channel, burst: burst, order: order, lastHeard: now)
            return [.receiveStarted(channel: channel, burst: burst, sender: sender)]

        case .transmitting(let txChannel, let txBurst, let txOrder):
            // Bursts on other channels do not contend with ours; they are simply not played.
            guard txChannel == channel, order < txOrder else { return [] }
            state = .receiving(channel: channel, burst: burst, order: order, lastHeard: now)
            return [.transmitEnded(channel: txChannel, burst: txBurst, preempted: true),
                    .receiveStarted(channel: channel, burst: burst, sender: sender)]

        case .receiving(let rxChannel, let rxBurst, let rxOrder, _):
            if rxBurst == burst && rxChannel == channel {
                touch(now: now)
                return []
            }
            // A collision between two remote talkers on our channel: follow the winner.
            guard rxChannel == channel, order < rxOrder else { return [] }
            state = .receiving(channel: channel, burst: burst, order: order, lastHeard: now)
            return [.receiveEnded(channel: rxChannel, burst: rxBurst),
                    .receiveStarted(channel: channel, burst: burst, sender: sender)]
        }
    }

    /// Any packet (voice or retransmitted start) of the burst being received.
    public mutating func remoteActivity(channel: ChannelID, burst: MessageID, now: Date = Date()) {
        guard case .receiving(let rxChannel, let rxBurst, _, _) = state,
              rxChannel == channel, rxBurst == burst else { return }
        touch(now: now)
    }

    public mutating func remoteBurstEnded(channel: ChannelID, burst: MessageID) -> [Output] {
        guard case .receiving(let rxChannel, let rxBurst, _, _) = state,
              rxChannel == channel, rxBurst == burst else { return [] }
        state = .idle
        return [.receiveEnded(channel: channel, burst: burst)]
    }

    /// Call periodically (e.g. every 250 ms) to apply the hang-time timeout.
    public mutating func tick(now: Date = Date()) -> [Output] {
        guard case .receiving(let channel, let burst, _, let lastHeard) = state,
              now.timeIntervalSince(lastHeard) > FloorControl.hangTime else { return [] }
        state = .idle
        return [.receiveEnded(channel: channel, burst: burst)]
    }

    // MARK: - Queries

    public var isTransmitting: Bool {
        if case .transmitting = state { return true }
        return false
    }

    public func isReceiving(burst: MessageID, on channel: ChannelID) -> Bool {
        if case .receiving(let c, let b, _, _) = state { return c == channel && b == burst }
        return false
    }

    private mutating func touch(now: Date) {
        if case .receiving(let c, let b, let o, _) = state {
            state = .receiving(channel: c, burst: b, order: o, lastHeard: now)
        }
    }
}
