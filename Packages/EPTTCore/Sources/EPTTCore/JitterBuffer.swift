import Foundation

/// Reorders incoming voice frames and releases them at playout cadence.
///
/// Playback begins once `targetFrames` are buffered (or the oldest frame has waited
/// `targetDelay`), then one frame is pulled per frame period. A late-joining listener
/// that receives a backlog simply hears the burst time-shifted; nothing is skipped.
public struct JitterBuffer {
    public enum Pull: Equatable {
        /// Still filling up before playout starts, or an underrun with nothing buffered.
        case waiting
        /// The next frame.
        case frame(Data)
        /// The next frame was lost; the caller should conceal (play silence or PLC).
        case missing
        /// Every frame of an ended burst has been pulled.
        case finished
    }

    public let targetFrames: Int
    public let targetDelay: TimeInterval
    public let capacity: Int

    private var frames: [UInt32: Data] = [:]
    private var nextIndex: UInt32 = 0
    private var started = false
    private var firstArrival: Date?
    private var endIndex: UInt32?

    public init(targetFrames: Int = 4, targetDelay: TimeInterval = 0.08, capacity: Int = 3_000) {
        self.targetFrames = targetFrames
        self.targetDelay = targetDelay
        self.capacity = capacity
    }

    public var bufferedCount: Int { frames.count }

    /// Inserts a frame. Returns false for duplicates, late frames and overflow.
    @discardableResult
    public mutating func insert(index: UInt32, frame: Data, now: Date = Date()) -> Bool {
        guard index >= nextIndex, frames[index] == nil, frames.count < capacity else { return false }
        if let end = endIndex, index >= end { return false }
        frames[index] = frame
        if firstArrival == nil { firstArrival = now }
        return true
    }

    /// Records the burst's total frame count from BURST_END.
    public mutating func markEnded(frameCount: UInt32) {
        endIndex = frameCount
        frames = frames.filter { $0.key < frameCount }
    }

    public mutating func pull(now: Date = Date()) -> Pull {
        if let end = endIndex, nextIndex >= end { return .finished }

        if !started {
            guard let first = firstArrival else { return .waiting }
            let ready = frames.count >= targetFrames
                || now.timeIntervalSince(first) >= targetDelay
                || endIndex != nil
            guard ready else { return .waiting }
            started = true
            // Start from the earliest frame we have; frames before it are presumed lost.
            if frames[nextIndex] == nil, let lowest = frames.keys.min() {
                nextIndex = lowest
            }
        }

        if let frame = frames.removeValue(forKey: nextIndex) {
            nextIndex &+= 1
            return .frame(frame)
        }
        // Nothing queued at all: an underrun. Wait rather than racing ahead of the sender,
        // unless the burst has ended, in which case the gap is permanent.
        if frames.isEmpty && endIndex == nil { return .waiting }
        nextIndex &+= 1
        return .missing
    }
}

/// The talker's copy of every sealed packet in the current burst, replayed to late joiners
/// (PROTOCOL.md §7). Packets are stored sealed so retransmissions are byte-identical.
public struct BurstBacklog {
    public let burst: MessageID
    public let maxPackets: Int
    public private(set) var packets: [Data] = []

    public init(burst: MessageID, maxPackets: Int = 2_000) {
        self.burst = burst
        self.maxPackets = maxPackets
    }

    public mutating func append(_ packet: Data) {
        guard packets.count < maxPackets else { return }
        packets.append(packet)
    }
}

/// Holds items briefly, keyed by some identifier, e.g. VOICE packets that arrived
/// before their BURST_START.
public struct ExpiringQueue<Key: Hashable, Value> {
    public let lifetime: TimeInterval
    public let maxPerKey: Int
    private var items: [Key: [(Date, Value)]] = [:]

    public init(lifetime: TimeInterval = 1.0, maxPerKey: Int = 64) {
        self.lifetime = lifetime
        self.maxPerKey = maxPerKey
    }

    public mutating func append(_ value: Value, for key: Key, now: Date = Date()) {
        expire(now: now)
        var list = items[key, default: []]
        guard list.count < maxPerKey else { return }
        list.append((now, value))
        items[key] = list
    }

    /// Removes and returns the unexpired items for `key`, oldest first.
    public mutating func take(_ key: Key, now: Date = Date()) -> [Value] {
        expire(now: now)
        return items.removeValue(forKey: key)?.map(\.1) ?? []
    }

    public mutating func expire(now: Date = Date()) {
        for (key, list) in items {
            let kept = list.filter { now.timeIntervalSince($0.0) < lifetime }
            items[key] = kept.isEmpty ? nil : kept
        }
    }
}
