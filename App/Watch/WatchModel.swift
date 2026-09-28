import AVFoundation
import Foundation
import WatchConnectivity
import WatchKit
import EPTTCore

/// The watch is a remote for the phone: it sends hold-to-talk commands and microphone audio
/// over WatchConnectivity, and shows who is talking (docs/ARCHITECTURE.md, "Apple Watch").
@MainActor
final class WatchModel: NSObject, ObservableObject {
    struct ChannelItem: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var channels: [ChannelItem] = []
    @Published var selected: String = ""
    @Published var state: WatchProtocol.TalkState = .offline
    @Published var talker = ""
    @Published var listening = false
    @Published var phoneReachable = false
    /// Standalone status (iPhone out of range): what the relay path is doing.
    @Published var standaloneStatus: WatchEngine.Status = .idle
    @Published private(set) var standaloneReady = false

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let audio = WatchAudio()
    let engine = WatchEngine.shared
    private var standaloneBurst = false

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
        engine.onStatus = { [weak self] status in
            self?.standaloneStatus = status
            if case .playing = status { WKInterfaceDevice.current().play(.notification) }
        }
        engine.onPlayback = { [weak self] pcm in self?.audio.play(pcm) }
        refreshStandalone()
    }

    /// With the iPhone out of range, a set-up watch talks on its own through the iCloud relay.
    var isStandalone: Bool { !phoneReachable && standaloneReady }

    var selectedName: String { channels.first { $0.id == selected }?.name ?? "No channel" }

    func press() {
        if isStandalone {
            guard let bytes = Data(hex: selected), let id = try? ChannelID(bytes: bytes),
                  engine.beginBurst(on: id) else {
                WKInterfaceDevice.current().play(.failure)
                return
            }
            standaloneBurst = true
            WKInterfaceDevice.current().play(.start)
            audio.startRecording { [weak self] chunk in self?.engine.append(pcm16k: chunk) }
            return
        }
        guard phoneReachable else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        WKInterfaceDevice.current().play(.start)
        send([WatchProtocol.command: WatchProtocol.Command.press.rawValue])
        audio.startRecording { [weak self] chunk in
            self?.session?.sendMessageData(Data([WatchProtocol.audioFromWatch]) + chunk, replyHandler: nil, errorHandler: nil)
        }
    }

    func release() {
        audio.stopRecording()
        if standaloneBurst {
            standaloneBurst = false
            // Let the last microphone chunk arrive before sealing the burst.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [engine] in engine.endBurst() }
        } else {
            send([WatchProtocol.command: WatchProtocol.Command.release.rawValue])
        }
        WKInterfaceDevice.current().play(.stop)
    }

    func select(_ channel: ChannelItem) {
        selected = channel.id
        send([WatchProtocol.command: WatchProtocol.Command.select.rawValue, WatchProtocol.channelID: channel.id])
    }

    /// Checks the relay for messages (on launch, on activation and on iCloud notifications).
    func fetchRelay() {
        engine.fetchRelay()
    }

    fileprivate func refreshStandalone() {
        standaloneReady = engine.isConfigured
        guard standaloneReady, channels.isEmpty || !phoneReachable else { return }
        // Without the phone, list channels from the mirrored state.
        let names = engine.channels.map { channel -> ChannelItem in
            let name = channel.kind == .direct
                ? (channel.members.first.flatMap { engine.contactName($0) } ?? channel.name)
                : channel.name
            return ChannelItem(id: channel.id.bytes.hex, name: name)
        }
        if !names.isEmpty { channels = names }
        if selected.isEmpty { selected = names.first?.id ?? "" }
    }

    func setListening(_ on: Bool) {
        listening = on
        send([WatchProtocol.command: WatchProtocol.Command.listenOnWatch.rawValue, WatchProtocol.enabled: on])
    }

    private func send(_ message: [String: Any]) {
        guard let session, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func apply(_ context: [String: Any]) {
        if let list = context[WatchProtocol.channels] as? [[String: String]] {
            channels = list.compactMap { item in
                guard let id = item["id"], let name = item["name"] else { return nil }
                return ChannelItem(id: id, name: name)
            }
        }
        if let selected = context[WatchProtocol.selected] as? String { self.selected = selected }
        if let listening = context[WatchProtocol.listening] as? Bool { self.listening = listening }
        let newTalker = context[WatchProtocol.talker] as? String ?? ""
        if let raw = context[WatchProtocol.state] as? String, let newState = WatchProtocol.TalkState(rawValue: raw) {
            if newState == .receiving && state != .receiving {
                WKInterfaceDevice.current().play(.notification)
            }
            state = newState
        }
        talker = newTalker
    }

    fileprivate func refreshReachability() {
        phoneReachable = session?.isReachable ?? false
        if !phoneReachable { state = .offline }
        refreshStandalone()
    }

    fileprivate func playReceived(_ pcm: Data) {
        guard listening else { return }
        audio.play(pcm)
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.refreshReachability()
            self.apply(context)
            self.send([WatchProtocol.command: WatchProtocol.Command.sync.rawValue])
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshReachability()
            if self.phoneReachable { self.send([WatchProtocol.command: WatchProtocol.Command.sync.rawValue]) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.phoneReachable = true
            self.apply(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchProtocol.sync] as? Data,
              let sync = try? JSONDecoder().decode(WatchSync.self, from: data) else { return }
        WatchEngine.shared.apply(sync)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.refreshStandalone()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData.first == WatchProtocol.audioToWatch else { return }
        let pcm = Data(messageData.dropFirst())
        Task { @MainActor in self.playReceived(pcm) }
    }
}

/// Microphone capture and speaker playback as mono Int16 16 kHz PCM.
final class WatchAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "app.eptt.watch.audio")
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WatchProtocol.audioSampleRate,
                                          channels: 1, interleaved: true)
    private let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WatchProtocol.audioSampleRate,
                                            channels: 1, interleaved: false)
    private var converter: AVAudioConverter?
    private var recording = false
    private var playerAttached = false

    private func activateSession(_ then: @escaping () -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [])
        } catch {
            return
        }
        session.activate(options: []) { success, _ in
            if success { then() }
        }
    }

    func startRecording(onChunk: @escaping (Data) -> Void) {
        activateSession { [weak self] in
            self?.queue.async { self?.beginCapture(onChunk: onChunk) }
        }
    }

    private func beginCapture(onChunk: @escaping (Data) -> Void) {
        guard !recording, let pcmFormat else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else { return }
        self.converter = converter
        recording = true
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = pcmFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            onChunk(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            recording = false
        }
    }

    func stopRecording() {
        queue.async { [self] in
            guard recording else { return }
            recording = false
            engine.inputNode.removeTap(onBus: 0)
            if !playerAttached { engine.stop() }
        }
    }

    func play(_ pcm: Data) {
        queue.async { [self] in
            guard let floatFormat, let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                                                 frameCapacity: AVAudioFrameCount(pcm.count / 2)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<Int(buffer.frameLength) { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
            }
            if !playerAttached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: floatFormat)
                playerAttached = true
            }
            if !engine.isRunning {
                activateSession { [weak self] in
                    self?.queue.async {
                        guard let self else { return }
                        try? self.engine.start()
                        self.schedule(buffer)
                    }
                }
            } else {
                schedule(buffer)
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}
