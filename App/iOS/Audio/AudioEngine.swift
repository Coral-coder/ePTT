import AVFoundation
import EPTTCore

/// Microphone capture + encoding, voice playback and tone playback on a single AVAudioEngine.
///
/// Threading: callers invoke the public methods from one serial queue of their own. All engine
/// graph changes, conversion, encoding and decoding happen on `queue`, an internal serial queue;
/// the input tap (called on an audio thread) copies its buffer and hops to `queue`. The callbacks
/// `onEncodedFrame` and `onPlaybackPCM16k` are invoked on `queue` — do not call back into this
/// object synchronously from them in a way that waits on another queue.
final class AudioEngine {
    /// Called (on the internal serial audio queue) with each encoded 20 ms frame while capturing.
    var onEncodedFrame: ((Data) -> Void)?
    /// Decoded playback audio as mono Int16 little-endian 16 kHz chunks (Apple Watch forwarding).
    /// Called on the internal queue.
    var onPlaybackPCM16k: ((Data) -> Void)?

    /// Codec parameters of what capture produces, announced in BURST_START.
    var captureCodec: (codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8) {
        let rate = encoder.pcmFormat.sampleRate
        let ms = (Double(encoder.frameLength) * 1000 / rate).rounded()
        return (encoder.codecID, UInt32(rate), UInt8(clamping: Int(ms)))
    }

    var isRunning: Bool { engine.isRunning }

    // MARK: Private state (touched only on `queue` unless noted)

    private let queue = DispatchQueue(label: "NXTPTT.audio", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()

    private let engine = AVAudioEngine()
    private let voicePlayer = AVAudioPlayerNode()
    private let tonePlayer = AVAudioPlayerNode()
    private let encoder: VoiceEncoder

    /// Format used for tones (Float32 mono 48 kHz).
    private let toneFormat: AVAudioFormat?
    /// Format the voice player is currently connected with.
    private var voicePlayerFormat: AVAudioFormat?
    /// Int16 mono 16 kHz, for Watch forwarding.
    private let watchFormat: AVAudioFormat?

    /// True between start() and stop(); used to recover after configuration changes.
    private var wantsRunning = false
    private var tapInstalled = false
    private var voiceProcessingAttempted = false

    // Capture
    private var capturing = false
    private var micConverter: StreamingConverter?
    private var injectConverter: StreamingConverter?
    private var fifo: [Float] = []
    /// `ProcessInfo.systemUptime` of the last Watch audio injection.
    private var lastInjectionTime: TimeInterval = -.infinity
    private static let micSuppressionAfterInjection: TimeInterval = 0.5

    // Playback
    private var decoder: VoiceDecoder?
    private var watchConverter: StreamingConverter?

    private var configObserver: NSObjectProtocol?

    init() {
        encoder = VoiceCodecFactory.makeEncoder()
        toneFormat = AudioFormats.floatMono(sampleRate: 48_000)
        watchFormat = AudioFormats.int16Mono(sampleRate: 16_000)
        queue.setSpecific(key: queueKey, value: 1)

        engine.attach(voicePlayer)
        engine.attach(tonePlayer)

        // Route changes / media-services resets stop the engine; restart it if we should be running.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver = configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    // MARK: - Lifecycle

    /// Starts AVAudioEngine. The AVAudioSession must already be active.
    func start() throws {
        try onQueueSync {
            wantsRunning = true
            try startLocked()
        }
    }

    func stop() {
        onQueueSync {
            wantsRunning = false
            capturing = false
            fifo.removeAll()
            decoder = nil
            watchConverter = nil
            removeTapLocked()
            voicePlayer.stop()
            tonePlayer.stop()
            engine.stop()
        }
    }

    private func startLocked() throws {
        guard !engine.isRunning else { return }

        // Echo cancellation. Must be set while the engine is stopped and before reading the
        // input format (voice processing can change it).
        if !voiceProcessingAttempted {
            voiceProcessingAttempted = true
            do {
                if !engine.inputNode.isVoiceProcessingEnabled {
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                }
            } catch {
                NSLog("NXTPTT audio: voice processing unavailable: \(error)")
            }
        }

        // Playback graph.
        let mixer = engine.mainMixerNode
        if let toneFormat = toneFormat {
            engine.connect(tonePlayer, to: mixer, format: toneFormat)
        }
        if voicePlayerFormat == nil {
            voicePlayerFormat = toneFormat
        }
        if let format = voicePlayerFormat {
            engine.connect(voicePlayer, to: mixer, format: format)
        }

        // Capture tap (installed once per start; gated by `capturing`).
        installTapLocked()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapLocked()
            throw error
        }
    }

    private func installTapLocked() {
        removeTapLocked()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // No microphone (e.g. simulator without input, or permission denied).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            micConverter = nil
            return
        }
        micConverter = StreamingConverter(from: inputFormat, to: encoder.pcmFormat)
        guard micConverter != nil else {
            NSLog("NXTPTT audio: cannot convert mic format \(inputFormat) to \(encoder.pcmFormat)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            // Audio thread: copy (the engine may reuse `buffer`) and hop to our queue.
            guard let self = self, let copy = AudioEngine.copy(buffer) else { return }
            self.queue.async { self.handleMicBuffer(copy) }
        }
        tapInstalled = true
    }

    private func removeTapLocked() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func handleConfigurationChange() {
        guard wantsRunning, !engine.isRunning else { return }
        do {
            try startLocked()
        } catch {
            NSLog("NXTPTT audio: restart after configuration change failed: \(error)")
        }
    }

    // MARK: - Capture

    func startCapture() {
        queue.async {
            self.fifo.removeAll()
            self.micConverter?.reset()
            self.injectConverter?.reset()
            self.capturing = true
        }
    }

    /// Stops capturing and drops any partial frame.
    func stopCapture() {
        queue.async {
            self.capturing = false
            self.fifo.removeAll()
        }
    }

    /// Feeds mono Int16 little-endian samples from the Apple Watch into the capture pipeline.
    func injectCapturedPCM(_ samples: Data, sampleRate: Double) {
        queue.async {
            guard self.capturing, sampleRate > 0 else { return }
            let count = samples.count / 2
            guard count > 0,
                  let format = AudioFormats.floatMono(sampleRate: sampleRate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData
            else { return }

            // Mic buffers are ignored for a short while after each injection.
            self.lastInjectionTime = ProcessInfo.processInfo.systemUptime
            buffer.frameLength = AVAudioFrameCount(count)
            let out = channels[0]
            samples.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8)
                    out[i] = Float(Int16(bitPattern: bits)) / 32_768
                }
            }

            if sampleRate == self.encoder.pcmFormat.sampleRate {
                self.appendToFIFO(buffer)
                return
            }
            if self.injectConverter?.inputFormat.sampleRate != sampleRate {
                self.injectConverter = StreamingConverter(from: format, to: self.encoder.pcmFormat)
            }
            guard let converted = self.injectConverter?.convert(buffer) else { return }
            self.appendToFIFO(converted)
        }
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard capturing, let converter = micConverter else { return }
        // Watch audio takes precedence over the phone mic.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInjectionTime >= Self.micSuppressionAfterInjection else { return }
        guard let converted = converter.convert(buffer) else { return }
        appendToFIFO(converted)
    }

    /// Appends codec-format samples and emits as many whole frames as are available.
    private func appendToFIFO(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        AudioLevelMeter.shared.add(buffer)   // the voice being sent (mic or watch)
        fifo.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))

        let frameLength = Int(encoder.frameLength)
        guard frameLength > 0 else { return }
        while fifo.count >= frameLength {
            guard let frame = AVAudioPCMBuffer(pcmFormat: encoder.pcmFormat,
                                               frameCapacity: AVAudioFrameCount(frameLength)),
                  let out = frame.floatChannelData?[0]
            else {
                fifo.removeAll()
                return
            }
            frame.frameLength = AVAudioFrameCount(frameLength)
            for i in 0..<frameLength { out[i] = fifo[i] }
            fifo.removeFirst(frameLength)

            if let packet = encoder.encode(frame), !packet.isEmpty {
                onEncodedFrame?(packet)
            }
        }
    }

    // MARK: - Playback

    /// Prepares a decoder for an incoming burst.
    func beginPlayback(codec: VoiceCodecID, sampleRate: UInt32, frameMilliseconds: UInt8) {
        queue.async {
            guard let decoder = VoiceCodecFactory.makeDecoder(codec: codec, sampleRate: sampleRate,
                                                              frameMilliseconds: frameMilliseconds) else {
                NSLog("NXTPTT audio: no decoder for \(codec) @ \(sampleRate) Hz")
                self.decoder = nil
                self.watchConverter = nil
                return
            }
            self.decoder = decoder
            self.watchConverter = self.watchFormat.flatMap { StreamingConverter(from: decoder.pcmFormat, to: $0) }

            // Reconnect the voice player if the burst's PCM format differs. Reconnecting a node
            // upstream of a mixer is supported while the engine runs; stop the player first.
            if self.voicePlayerFormat != decoder.pcmFormat {
                self.voicePlayer.stop()
                self.engine.connect(self.voicePlayer, to: self.engine.mainMixerNode, format: decoder.pcmFormat)
                self.voicePlayerFormat = decoder.pcmFormat
            }
            self.startVoicePlayerIfPossible()
        }
    }

    /// Schedules one received frame; nil means the frame was lost (plays one frame of silence).
    func playFrame(_ frame: Data?) {
        queue.async {
            guard let decoder = self.decoder else { return }
            let buffer = frame.flatMap { decoder.decode($0) } ?? decoder.silence()
            AudioLevelMeter.shared.add(buffer)   // what is being heard

            if self.engine.isRunning, let format = self.voicePlayerFormat,
               buffer.format.sampleRate == format.sampleRate,
               buffer.format.channelCount == format.channelCount {
                self.voicePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                self.startVoicePlayerIfPossible()
            }
            self.emitWatchPCM(buffer)
        }
    }

    /// Ends the burst. Already scheduled audio keeps playing out.
    func endPlayback() {
        queue.async {
            self.decoder = nil
            self.watchConverter = nil
        }
    }

    /// Plays already decoded audio (a replayed message) through the voice player.
    /// Returns its length in seconds.
    func playBuffers(_ buffers: [AVAudioPCMBuffer]) -> TimeInterval {
        guard let format = buffers.first?.format, format.sampleRate > 0 else { return 0 }
        let seconds = buffers.reduce(0) { $0 + Double($1.frameLength) } / format.sampleRate
        queue.async {
            guard self.engine.isRunning else { return }
            if self.voicePlayerFormat != format {
                self.voicePlayer.stop()
                self.engine.connect(self.voicePlayer, to: self.engine.mainMixerNode, format: format)
                self.voicePlayerFormat = format
            }
            for buffer in buffers { self.voicePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil) }
            self.startVoicePlayerIfPossible()
            // Feed the live waveform as each buffer comes up, not all at once.
            var offset = 0.0
            for buffer in buffers {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + offset) {
                    AudioLevelMeter.shared.add(buffer)
                }
                offset += Double(buffer.frameLength) / format.sampleRate
            }
        }
        return seconds
    }

    private func startVoicePlayerIfPossible() {
        // play() raises an Objective-C exception if the engine is not running.
        guard engine.isRunning, !voicePlayer.isPlaying else { return }
        voicePlayer.play()
    }

    private func emitWatchPCM(_ buffer: AVAudioPCMBuffer) {
        guard let callback = onPlaybackPCM16k,
              let converter = watchConverter,
              let converted = converter.convert(buffer),
              let channels = converted.int16ChannelData
        else { return }
        let count = Int(converted.frameLength)
        let samples = channels[0]
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                raw.storeBytes(of: samples[i].littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        callback(data)
    }

    // MARK: - Tones

    func play(_ tone: Tone) {
        queue.async {
            guard self.engine.isRunning, let format = self.toneFormat else { return }
            let buffer = SoundLibrary.buffer(for: tone, format: format) ?? ToneSynth.buffer(for: tone, format: format)
            // A new tone replaces one that is still sounding.
            self.tonePlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !self.tonePlayer.isPlaying {
                self.tonePlayer.play()
            }
        }
    }

    /// A steady tone until `stopHoldTone` (the talk button is held but nothing can be sent).
    func startHoldTone() {
        queue.async {
            guard self.engine.isRunning, let format = self.toneFormat else { return }
            self.tonePlayer.scheduleBuffer(ToneSynth.holdBuffer(format: format), at: nil,
                                           options: [.interrupts, .loops], completionHandler: nil)
            if !self.tonePlayer.isPlaying { self.tonePlayer.play() }
        }
    }

    func stopHoldTone() {
        queue.async { self.tonePlayer.stop() }
    }

    // MARK: - Session (fallback when the PushToTalk framework is unavailable)

    static func activateSessionManually() throws {
        try configureSession()
        try AVAudioSession.sharedInstance().setActive(true)
        routeToSpeakerIfNeeded()
    }

    /// Walkie-talkie audio: record and play, loud speaker unless a headset or Bluetooth device is
    /// connected. Called before PushToTalk activates the session (it keeps our category) and
    /// before a manual activation.
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .allowBluetooth (HFP) gives a headset mic; A2DP is output-only, so it is not used.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.02)
        startWatchingRoute()
    }

    /// Voice processing (echo cancellation) favours the earpiece, like a phone call. A walkie
    /// talkie is held away from the face, so whenever output lands on the earpiece, move it to
    /// the speaker. Headphones and Bluetooth are left alone.
    static func routeToSpeakerIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        guard outputs.contains(.builtInReceiver) else { return }
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            NSLog("NXTPTT audio: speaker override failed: \(error)")
        }
    }

    private static var routeObserver: NSObjectProtocol?

    private static func startWatchingRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            routeToSpeakerIfNeeded()
        }
    }

    // MARK: - Helpers

    /// Runs `work` on `queue`, inline if already on it (avoids self-deadlock).
    private func onQueueSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// Deep copy of a PCM buffer (any layout).
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            to.copyMemory(from: from, byteCount: Int(bytes))
        }
        return copy
    }
}

/// An AVAudioConverter used as a streaming PCM converter (format, channel and sample-rate
/// conversion), keeping resampler state between calls.
final class StreamingConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let status = converter.convertSupplyingOnce(input, into: output)
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    func reset() {
        converter.reset()
    }
}
