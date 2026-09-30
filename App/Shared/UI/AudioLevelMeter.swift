import AVFoundation
import Foundation

/// Recent audio levels (0…1), newest last, for the live waveform: the voice being sent while
/// transmitting, and what is heard while receiving. Written from the audio queue, read by the UI
/// each frame; a lock keeps it cheap (no SwiftUI updates per buffer).
final class AudioLevelMeter {
    static let shared = AudioLevelMeter()

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: 48)
    private var lastUpdate = Date.distantPast

    /// Adds one buffer's level (RMS mapped from -50…0 dBFS to 0…1).
    func add(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let level = max(0, min(1, (db + 50) / 50))
        lock.lock()
        levels.removeFirst()
        levels.append(level)
        lastUpdate = Date()
        lock.unlock()
    }

    /// The newest `count` levels, oldest first; they fade out when no audio has arrived lately.
    func recent(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let age = Date().timeIntervalSince(lastUpdate)
        let fade = Float(max(0, 1 - age / 0.4))
        return levels.suffix(count).map { $0 * fade }
    }
}
