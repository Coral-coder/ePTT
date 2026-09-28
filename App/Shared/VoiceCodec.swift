import AVFoundation
import EPTTCore

// MARK: - Protocols

/// Turns fixed-length PCM frames into codec packets.
protocol VoiceEncoder: AnyObject {
    /// The PCM format `encode` expects: Float32, mono, non-interleaved, at the codec sample rate.
    var pcmFormat: AVAudioFormat { get }
    /// Samples per frame (e.g. 960 for 20 ms at 48 kHz).
    var frameLength: AVAudioFrameCount { get }
    var codecID: VoiceCodecID { get }
    /// Encodes exactly one frame. Returns nil if the codec produced no packet.
    func encode(_ buffer: AVAudioPCMBuffer) -> Data?
}

/// Turns received codec packets back into PCM.
protocol VoiceDecoder: AnyObject {
    /// The PCM format of decoded buffers: Float32, mono, non-interleaved.
    var pcmFormat: AVAudioFormat { get }
    func decode(_ frame: Data) -> AVAudioPCMBuffer?
    /// One frame of silence, used for lost frames.
    func silence() -> AVAudioPCMBuffer
}

// MARK: - Helpers

enum AudioFormats {
    /// Float32, mono, non-interleaved PCM.
    static func floatMono(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Int16, mono, interleaved PCM (the wire / Watch format).
    static func int16Mono(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    /// Opus with one packet per `framesPerPacket` samples.
    static func opus(sampleRate: Double, framesPerPacket: AVAudioFrameCount) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,          // variable-size packets
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)
        return withUnsafePointer(to: &asbd) { AVAudioFormat(streamDescription: $0) }
    }

    /// Samples in one frame of `milliseconds` at `sampleRate`.
    static func frameCount(sampleRate: Double, milliseconds: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(max(1, (sampleRate * milliseconds / 1000).rounded()))
    }

    /// A zero-filled buffer of `frames` samples (AVAudioPCMBuffer memory is zeroed on allocation,
    /// but we clear it explicitly to be safe).
    static func silentBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }
}

extension AVAudioConverter {
    /// Runs one conversion pass, handing `input` to the converter exactly once and then
    /// reporting `.noDataNow`, which keeps the converter's streaming state (resampler history,
    /// codec state) intact for the next call.
    func convertSupplyingOnce(_ input: AVAudioBuffer, into output: AVAudioBuffer) -> AVAudioConverterOutputStatus {
        var supplied = false
        var error: NSError?
        let status = convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            // Put the converter back into a usable state for the next frame.
            reset()
        }
        return status
    }
}

// MARK: - Opus (Apple's built-in codec via AVAudioConverter)

final class OpusEncoder: VoiceEncoder {
    let pcmFormat: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let codecID: VoiceCodecID = .opus

    private let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(sampleRate: Double = 48_000, frameMilliseconds: Double = 20, bitRate: Int = 24_000) {
        let frames = AudioFormats.frameCount(sampleRate: sampleRate, milliseconds: frameMilliseconds)
        guard let pcm = AudioFormats.floatMono(sampleRate: sampleRate),
              let opus = AudioFormats.opus(sampleRate: sampleRate, framesPerPacket: frames),
              let converter = AVAudioConverter(from: pcm, to: opus)
        else { return nil }

        // Only touch bitRate when the encoder advertises the values it accepts; pick the
        // closest one to what we want.
        if let rates = converter.applicableEncodeBitRates, !rates.isEmpty {
            let candidates = rates.map { $0.intValue }
            if let best = candidates.min(by: { abs($0 - bitRate) < abs($1 - bitRate) }) {
                converter.bitRate = best
            }
        }

        self.pcmFormat = pcm
        self.frameLength = frames
        self.opusFormat = opus
        self.converter = converter
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        let maxPacket = converter.maximumOutputPacketSize > 0 ? converter.maximumOutputPacketSize : 1500
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: maxPacket)

        let status = converter.convertSupplyingOnce(buffer, into: output)
        guard status != .error, output.packetCount > 0, output.byteLength > 0 else { return nil }

        var offset = 0
        var length = Int(output.byteLength)
        if let descriptions = output.packetDescriptions, descriptions[0].mDataByteSize > 0 {
            offset = Int(descriptions[0].mStartOffset)
            length = Int(descriptions[0].mDataByteSize)
        }
        guard offset >= 0, length > 0, offset + length <= Int(output.byteLength) else { return nil }
        return Data(bytes: output.data.advanced(by: offset), count: length)
    }
}

final class OpusDecoder: VoiceDecoder {
    let pcmFormat: AVAudioFormat

    private let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let frameLength: AVAudioFrameCount
    private let silenceTemplate: AVAudioPCMBuffer

    /// Opus can decode at 8, 12, 16, 24 or 48 kHz regardless of the rate it was encoded at.
    static let supportedSampleRates: Set<UInt32> = [8_000, 12_000, 16_000, 24_000, 48_000]

    init?(sampleRate: Double = 48_000, frameMilliseconds: Double = 20) {
        let frames = AudioFormats.frameCount(sampleRate: sampleRate, milliseconds: frameMilliseconds)
        guard let pcm = AudioFormats.floatMono(sampleRate: sampleRate),
              let opus = AudioFormats.opus(sampleRate: sampleRate, framesPerPacket: frames),
              let converter = AVAudioConverter(from: opus, to: pcm),
              let silence = AudioFormats.silentBuffer(format: pcm, frames: frames)
        else { return nil }
        self.pcmFormat = pcm
        self.opusFormat = opus
        self.converter = converter
        self.frameLength = frames
        self.silenceTemplate = silence
    }

    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty, frame.count <= 4_000 else { return nil }

        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        guard Int(input.byteCapacity) >= frame.count else { return nil }
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            input.data.copyMemory(from: base, byteCount: frame.count)
        }
        input.byteLength = UInt32(frame.count)
        input.packetCount = 1
        if let descriptions = input.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        }

        // An Opus packet can carry up to 120 ms; leave room for that.
        let capacity = max(frameLength, AudioFormats.frameCount(sampleRate: pcmFormat.sampleRate, milliseconds: 120))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }

        let status = converter.convertSupplyingOnce(input, into: output)
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    func silence() -> AVAudioPCMBuffer {
        AudioFormats.silentBuffer(format: pcmFormat, frames: frameLength) ?? silenceTemplate
    }
}

// MARK: - PCM16 fallback (raw Int16 little-endian mono)

final class PCM16Encoder: VoiceEncoder {
    let pcmFormat: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let codecID: VoiceCodecID = .pcm16

    init?(sampleRate: Double = 16_000, frameMilliseconds: Double = 20) {
        guard let pcm = AudioFormats.floatMono(sampleRate: sampleRate) else { return nil }
        self.pcmFormat = pcm
        self.frameLength = AudioFormats.frameCount(sampleRate: sampleRate, milliseconds: frameMilliseconds)
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let x = samples[i]
                let clamped = x.isFinite ? max(-1, min(1, x)) : 0
                let value = Int16((clamped * 32_767).rounded())
                raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data
    }
}

final class PCM16Decoder: VoiceDecoder {
    let pcmFormat: AVAudioFormat

    private let frameLength: AVAudioFrameCount
    private let silenceTemplate: AVAudioPCMBuffer

    init?(sampleRate: Double = 16_000, frameMilliseconds: Double = 20) {
        let frames = AudioFormats.frameCount(sampleRate: sampleRate, milliseconds: frameMilliseconds)
        guard let pcm = AudioFormats.floatMono(sampleRate: sampleRate),
              let silence = AudioFormats.silentBuffer(format: pcm, frames: frames)
        else { return nil }
        self.pcmFormat = pcm
        self.frameLength = frames
        self.silenceTemplate = silence
    }

    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        let count = frame.count / 2
        // Reject empty frames and anything longer than 120 ms.
        let maxFrames = Int(AudioFormats.frameCount(sampleRate: pcmFormat.sampleRate, milliseconds: 120))
        guard count > 0, count <= maxFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = channels[0]
        frame.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8)
                out[i] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        return buffer
    }

    func silence() -> AVAudioPCMBuffer {
        AudioFormats.silentBuffer(format: pcmFormat, frames: frameLength) ?? silenceTemplate
    }
}

// MARK: - Factory

enum VoiceCodecFactory {
    /// Opus when the platform's converter supports it, otherwise raw PCM16 at 16 kHz.
    static func makeEncoder() -> VoiceEncoder {
        if let opus = OpusEncoder() { return opus }
        if let pcm = PCM16Encoder() { return pcm }
        // Creating a Float32 mono 16 kHz format cannot fail in practice.
        fatalError("NXTPTT: unable to create any voice encoder")
    }

    static func makeDecoder(codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8) -> VoiceDecoder? {
        let frameMs = Double(frameMilliseconds == 0 ? 20 : frameMilliseconds)
        switch codec {
        case .opus:
            // Decode at the announced rate when Opus supports it, else at 48 kHz.
            let rate = OpusDecoder.supportedSampleRates.contains(sampleRate) ? Double(sampleRate) : 48_000
            return OpusDecoder(sampleRate: rate, frameMilliseconds: frameMs)
                ?? OpusDecoder(sampleRate: 48_000, frameMilliseconds: frameMs)
        case .pcm16:
            guard (8_000...48_000).contains(sampleRate) else { return nil }
            return PCM16Decoder(sampleRate: Double(sampleRate), frameMilliseconds: frameMs)
        }
    }
}
