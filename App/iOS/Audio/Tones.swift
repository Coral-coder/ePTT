import AVFoundation

/// The Nextel sounds. They are synthesized at run time from the published specification of the
/// iDEN chirp, so no recordings ship with the app. Users can import their own (SoundLibrary).
enum Tone: String, CaseIterable, Identifiable {
    /// The chirp: played when you get the floor and when an incoming call starts.
    case talkPermit
    /// Optional "roger beep" when the other side releases. Nextel had none, so it's off by default.
    case endOfTransmission
    /// The "bonk": someone else has the channel, or you were cut off.
    case busy
    /// Call alert: a run of chirps, like a Nextel page.
    case callAlert

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .talkPermit: return "Chirp"
        case .endOfTransmission: return "Roger beep"
        case .busy: return "Bonk"
        case .callAlert: return "Call alert"
        }
    }
}

enum ToneSynth {
    /// Peak amplitude of every tone.
    static let amplitude: Float = 0.35

    /// The two pitches of the iDEN chirp on record: 1800 Hz (classic) and 911 Hz (deep).
    static let classicChirpHz: Double = 1_800
    static let deepChirpHz: Double = 911
    /// Pitch used for chirps. Set from Settings.
    static var chirpFrequency: Double = classicChirpHz

    /// Renders `tone` into a buffer of `format` (normally Float32 mono 48 kHz). Every channel
    /// gets the same signal. Float32 and Int16 formats are supported.
    static func buffer(for tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let samples = render(tone, sampleRate: format.sampleRate > 0 ? format.sampleRate : 48_000)
        let frames = AVAudioFrameCount(max(1, samples.count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            // Only happens for a non-PCM format, which is a programming error.
            fatalError("ToneSynth: cannot allocate a PCM buffer for format \(format)")
        }
        buffer.frameLength = frames

        let channelCount = Int(format.channelCount)
        let stride = buffer.stride // 1 for non-interleaved, channelCount for interleaved
        if let channels = buffer.floatChannelData {
            let planes = format.isInterleaved ? 1 : channelCount
            for plane in 0..<planes {
                let out = channels[plane]
                for (i, s) in samples.enumerated() {
                    if format.isInterleaved {
                        for c in 0..<channelCount { out[i * stride + c] = s }
                    } else {
                        out[i] = s
                    }
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let planes = format.isInterleaved ? 1 : channelCount
            for plane in 0..<planes {
                let out = channels[plane]
                for (i, s) in samples.enumerated() {
                    let v = Int16((max(-1, min(1, s)) * 32_767).rounded())
                    if format.isInterleaved {
                        for c in 0..<channelCount { out[i * stride + c] = v }
                    } else {
                        out[i] = v
                    }
                }
            }
        }
        return buffer
    }

    // MARK: - Recipes

    static func render(_ tone: Tone, sampleRate: Double) -> [Float] {
        var synth = Synth(sampleRate: sampleRate)
        switch tone {
        case .talkPermit:
            chirp(into: &synth)
        case .endOfTransmission:
            // A single short blip at the chirp pitch.
            synth.tone(frequency: chirpFrequency, milliseconds: 40, fadeInMs: 2, fadeOutMs: 2)
        case .busy:
            // The "bonk": a low, hollow tone that drops in pitch and dies away quickly.
            synth.tone(frequency: 560, milliseconds: 90, fadeInMs: 2, fadeOutMs: 4, secondHarmonic: 0.3)
            synth.tone(frequency: 400, milliseconds: 260, fadeInMs: 2, fadeOutMs: 30,
                       decayPerSecond: 7, secondHarmonic: 0.3)
        case .callAlert:
            // A Nextel page: the chirp, over and over.
            for i in 0..<4 {
                chirp(into: &synth)
                if i < 3 { synth.silence(milliseconds: 180) }
            }
        }
        // A short tail of silence so the last sample is never cut abruptly.
        synth.silence(milliseconds: 10)
        return synth.samples
    }

    /// The iDEN chirp: a tone played 24 ms on, 24 off, 24 on, 24 off, 48 on.
    private static func chirp(into synth: inout Synth) {
        let f = chirpFrequency
        synth.tone(frequency: f, milliseconds: 24, fadeInMs: 1.5, fadeOutMs: 1.5)
        synth.silence(milliseconds: 24)
        synth.tone(frequency: f, milliseconds: 24, fadeInMs: 1.5, fadeOutMs: 1.5)
        synth.silence(milliseconds: 24)
        synth.tone(frequency: f, milliseconds: 48, fadeInMs: 1.5, fadeOutMs: 1.5)
    }

    /// 16-bit mono WAV of a tone, for previews.
    static func wav(for tone: Tone, sampleRate: Double = 48_000) -> Data {
        let samples = render(tone, sampleRate: sampleRate)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples { append(Int16((max(-1, min(1, s)) * 32_767).rounded())) }
        return data
    }

    // MARK: - Synthesizer

    private struct Synth {
        let sampleRate: Double
        var samples: [Float] = []

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
        }

        private func count(_ milliseconds: Double) -> Int {
            max(0, Int((sampleRate * milliseconds / 1000).rounded()))
        }

        /// Linear fade in/out envelope value for sample `i` of `n`.
        private func edge(_ i: Int, of n: Int, fadeIn: Int, fadeOut: Int) -> Float {
            var gain: Float = 1
            if fadeIn > 0, i < fadeIn { gain = min(gain, Float(i) / Float(fadeIn)) }
            if fadeOut > 0, i >= n - fadeOut { gain = min(gain, Float(n - 1 - i) / Float(fadeOut)) }
            return max(0, gain)
        }

        mutating func silence(milliseconds: Double) {
            samples.append(contentsOf: repeatElement(0, count: count(milliseconds)))
        }

        mutating func tone(frequency: Double, milliseconds: Double,
                           fadeInMs: Double = 5, fadeOutMs: Double = 5,
                           decayPerSecond: Double = 0, secondHarmonic: Float = 0) {
            let n = count(milliseconds)
            guard n > 0 else { return }
            let fadeIn = min(count(fadeInMs), n / 2)
            let fadeOut = min(count(fadeOutMs), n / 2)
            let step = 2 * Double.pi * frequency / sampleRate
            // Normalize so the peak stays at `amplitude` with the harmonic mixed in.
            let norm = 1 / (1 + abs(secondHarmonic))
            samples.reserveCapacity(samples.count + n)
            for i in 0..<n {
                let phase = step * Double(i)
                var v = Float(sin(phase)) + secondHarmonic * Float(sin(2 * phase))
                v *= norm
                if decayPerSecond > 0 {
                    v *= Float(exp(-decayPerSecond * Double(i) / sampleRate))
                }
                samples.append(v * ToneSynth.amplitude * edge(i, of: n, fadeIn: fadeIn, fadeOut: fadeOut))
            }
        }

        /// Alternates between two frequencies every `segmentMilliseconds`, keeping the phase
        /// continuous across switches so there are no clicks.
        mutating func trill(frequencies: (Double, Double), segmentMilliseconds: Double, totalMilliseconds: Double) {
            let n = count(totalMilliseconds)
            let segment = max(1, count(segmentMilliseconds))
            guard n > 0 else { return }
            let fade = min(count(5), n / 2)
            var phase = 0.0
            samples.reserveCapacity(samples.count + n)
            for i in 0..<n {
                let frequency = (i / segment) % 2 == 0 ? frequencies.0 : frequencies.1
                phase += 2 * Double.pi * frequency / sampleRate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                let v = Float(sin(phase)) * ToneSynth.amplitude * edge(i, of: n, fadeIn: fade, fadeOut: fade)
                samples.append(v)
            }
        }
    }
}
