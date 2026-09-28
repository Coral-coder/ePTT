import AVFoundation

/// The Nextel-style chirps. All are synthesized at run time; no audio assets ship with the app.
enum Tone {
    case talkPermit
    case endOfTransmission
    case busy
    case callAlert
}

enum ToneSynth {
    /// Peak amplitude of every tone.
    static let amplitude: Float = 0.35

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
            // Three quick high blips: the classic "chirp-chirp-chirp".
            for i in 0..<3 {
                synth.tone(frequency: 1_800, milliseconds: 45)
                if i < 2 { synth.silence(milliseconds: 35) }
            }
        case .endOfTransmission:
            // One short, higher blip.
            synth.tone(frequency: 2_400, milliseconds: 60)
        case .busy:
            // Low "bonk" with a fast exponential decay and a touch of second harmonic.
            synth.tone(frequency: 420, milliseconds: 350, fadeInMs: 2, fadeOutMs: 20,
                       decayPerSecond: 9, secondHarmonic: 0.35)
        case .callAlert:
            // Alternating trill for about one second.
            synth.trill(frequencies: (1_400, 1_900), segmentMilliseconds: 50, totalMilliseconds: 1_000)
        }
        // A short tail of silence so the last sample is never cut abruptly.
        synth.silence(milliseconds: 10)
        return synth.samples
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
