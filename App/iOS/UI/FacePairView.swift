import AVFoundation
import QuartzCore
import SwiftUI
import EPTTCore

/// Face-to-face pairing over monochrome light (PROTOCOL.md §12). Hold two phones screen to
/// screen, tops together: the top of each screen flashes a 4 × 4 grid of black and white tiles,
/// and each front camera reads the other's. Each round the receiver calibrates on the other
/// screen before reading, so blur, tilt and mirroring don't matter. Keys and relay mailbox
/// travel as light; names and the full signed cards follow through the encrypted relay.
struct FacePairView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = LightPairingSession()
    @State private var running = false
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if running {
                GeometryReader { geo in
                    LightLamp(sender: pairing.sender)
                        .frame(width: geo.size.width, height: geo.size.height * 0.56)
                }
                .ignoresSafeArea()
                LightCamera(session: pairing)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            VStack {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                    Spacer()
                }
                .padding(.horizontal, 14)
                Spacer()
                if running {
                    HandshakePanel(pairing: pairing) { dismiss() }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 14)
                } else {
                    intro
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pairing.onPaired = { profile in model.engine.addLightPaired(profile) }
            model.engine.lightProfile { data in
                guard let data else { return }
                pairing.prepare(profile: data)
            }
        }
        .onDisappear {
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PAIR FACE TO FACE")
                .font(NX.label(17, .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text("Open this on both phones and tap Start on both. Hold them screen to screen, tops together, about a hand apart, until both finish (around 10 seconds).")
                .font(NX.body(15))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Label("The top of the screen flashes black and white quickly. Don't look at it if flashing lights affect you.",
                  systemImage: "exclamationmark.triangle")
                .font(NX.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                savedBrightness = UIScreen.main.brightness
                // Bright enough to read, not so bright it blows out the other camera.
                UIScreen.main.brightness = 0.7
                pairing.start()
                running = true
            } label: {
                Text("START")
                    .font(NX.label(15, .bold))
                    .tracking(2)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(!pairing.isReady)
            .opacity(pairing.isReady ? 1 : 0.4)
        }
        .padding(22)
    }
}

/// The flashing tiles: the current symbol of this phone's transmission, redrawn every display
/// frame. White and black only.
private struct LightLamp: View {
    let sender: LightSender

    var body: some View {
        TimelineView(.animation) { _ in
            let symbol = sender.symbol(at: CACurrentMediaTime())
            Canvas { context, size in
                let gap: CGFloat = 8
                let w = (size.width - gap * CGFloat(OpticalLink.columns + 1)) / CGFloat(OpticalLink.columns)
                let h = (size.height - gap * CGFloat(OpticalLink.rows + 1)) / CGFloat(OpticalLink.rows)
                for j in 0..<OpticalLink.tiles where symbol[j] {
                    let x = gap + CGFloat(j % OpticalLink.columns) * (w + gap)
                    let y = gap + CGFloat(j / OpticalLink.columns) * (h + gap)
                    context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(Color(white: 0.92)))
                }
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }
}

/// Where the handshake is, as steps and a progress bar. White and grey only.
private struct HandshakePanel: View {
    @ObservedObject var pairing: LightPairingSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pairing.headline.uppercased())
                .font(NX.label(15, .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text(pairing.hint)
                .font(NX.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(8, geo.size.width * pairing.overallProgress))
                        .animation(.easeOut(duration: 0.25), value: pairing.overallProgress)
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("Pairing progress")
            .accessibilityValue("\(Int(pairing.overallProgress * 100)) percent")

            VStack(alignment: .leading, spacing: 7) {
                step("See the other phone", done: pairing.hasSeenPeer, active: pairing.stage == .looking)
                step(pairing.stage == .receiving
                        ? "Receive their keys · \(Int(pairing.receivedProgress * 100))%"
                        : "Receive their keys",
                     done: pairing.hasTheirs, active: pairing.stage == .receiving)
                step("They receive yours", done: pairing.peerHasMine, active: pairing.stage == .waitingForPeer)
                step("Compare the safety code", done: false, active: pairing.stage == .paired)
            }

            if let code = pairing.safetyCode {
                Text(code)
                    .font(NX.display(30))
                    .tracking(4)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Safety code \(code)")
            }
            if pairing.stage == .paired {
                Button(action: close) {
                    Text("DONE")
                        .font(NX.label(14, .bold))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func step(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(.white.opacity(done || active ? 0.85 : 0.3), lineWidth: 1.5)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                } else if active {
                    Circle().fill(.white).frame(width: 7, height: 7)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(NX.body(14, active ? .semibold : .regular))
                .foregroundStyle(.white.opacity(done || active ? 0.95 : 0.45))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : active ? "In progress" : "Not yet")
    }
}

// MARK: - Sending

/// This phone's transmission: data rounds with our profile, and once we have theirs, data and
/// acknowledgement rounds alternating (they may still need ours). Read from the display loop.
final class LightSender {
    private let lock = NSLock()
    private var payload: Data?
    private var received: Data?
    private var round: [OpticalLink.Symbol] = []
    private var roundStart = 0.0
    private var sentAck = true
    private static let dark = Array(repeating: false, count: OpticalLink.tiles)

    func start(payload: Data) {
        lock.lock(); defer { lock.unlock() }
        self.payload = payload
        roundStart = CACurrentMediaTime()
        round = OpticalLink.dataLoop(payload: payload)
    }

    func gotTheirs(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        received = data
    }

    func symbol(at time: Double) -> OpticalLink.Symbol {
        lock.lock(); defer { lock.unlock() }
        guard let payload, !round.isEmpty else { return Self.dark }
        var index = Int((time - roundStart) / OpticalLink.symbolSeconds)
        while index >= round.count {
            roundStart += Double(round.count) * OpticalLink.symbolSeconds
            index -= round.count
            if let received, !sentAck {
                round = OpticalLink.ackLoop(for: received)
                sentAck = true
            } else {
                round = OpticalLink.dataLoop(payload: payload)
                sentAck = false
            }
        }
        return round[max(0, index)]
    }
}

// MARK: - Session

@MainActor
final class LightPairingSession: ObservableObject {
    enum Stage { case looking, receiving, waitingForPeer, paired }

    @Published private(set) var isReady = false
    @Published private(set) var stage: Stage = .looking
    @Published private(set) var hasSeenPeer = false
    @Published private(set) var hasTheirs = false
    @Published private(set) var receivedProgress = 0.0
    @Published private(set) var peerHasMine = false
    @Published private(set) var failedRounds = 0
    @Published private(set) var safetyCode: String?

    let sender = LightSender()
    var onPaired: ((LightProfile) -> Void)?
    /// Called on the camera queue once the other phone is in view (lock exposure then).
    nonisolated(unsafe) var onFirstSighting: (() -> Void)?

    private var myPayload = Data()
    private var started = Date()
    private let receiverLock = NSLock()
    nonisolated(unsafe) private var receiver = OpticalLink.Receiver()
    nonisolated(unsafe) private var framesSinceProgress = 0

    var overallProgress: Double {
        (hasSeenPeer ? 0.1 : 0) + 0.7 * (hasTheirs ? 1 : receivedProgress) + (peerHasMine ? 0.2 : 0)
    }

    var headline: String {
        switch stage {
        case .looking: return "Looking for the other phone"
        case .receiving: return failedRounds > 0 ? "Missed some, reading again" : "Receiving their keys"
        case .waitingForPeer: return "Got theirs, sending yours"
        case .paired: return "Paired"
        }
    }

    var hint: String {
        switch stage {
        case .looking:
            return Date().timeIntervalSince(started) > 8
                ? "Both phones on Face to face with Start tapped, screens facing, tops together, about a hand apart."
                : "Hold the phones screen to screen, tops together, about a hand apart."
        case .receiving:
            return failedRounds > 1 ? "Hold them steadier and a little further apart." : "Keep them still until both finish."
        case .waitingForPeer: return "Keep holding them together so the other phone finishes reading yours."
        case .paired: return "Both phones should show this code. If they don't, remove the contact and try again."
        }
    }

    /// Our profile without the name: 82 bytes, which is what the light carries.
    func prepare(profile: Data) {
        guard let full = try? LightProfile(encoded: profile) else { return }
        myPayload = LightProfile(identity: full.identity, name: "", relayMailbox: full.relayMailbox).encoded
        isReady = myPayload.count == OpticalLink.payloadBytes
    }

    func start() {
        guard isReady else { return }
        started = Date()
        sender.start(payload: myPayload)
    }

    /// Camera queue: one frame of cell brightness.
    nonisolated func frame(time: Double, cells: [Float]) {
        receiverLock.lock()
        let events = receiver.add(time: time, cells: cells)
        framesSinceProgress += 1
        var progress: Double?
        if framesSinceProgress >= 6 {
            framesSinceProgress = 0
            progress = receiver.progress(at: time)
        }
        let firstSighting = receiver.roundsSeen == 1 && events.contains { if case .roundStarted = $0 { return true }; return false }
        receiverLock.unlock()
        if firstSighting { onFirstSighting?() }
        guard !events.isEmpty || progress != nil else { return }
        Task { @MainActor in self.handle(events, progress: progress) }
    }

    private func handle(_ events: [OpticalLink.Receiver.Event], progress: Double?) {
        if let progress, !hasTheirs { receivedProgress = progress }
        for event in events {
            switch event {
            case .roundStarted:
                hasSeenPeer = true
            case .roundIncomplete:
                failedRounds += 1
                receivedProgress = 0
            case .payload(let data):
                guard !hasTheirs, let profile = try? LightProfile(encoded: data) else { continue }
                hasTheirs = true
                receivedProgress = 1
                safetyCode = LightCode.safetyCode(myPayload, data)
                sender.gotTheirs(data)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPaired?(profile)
            case .ack(let value):
                if value == OpticalLink.ackValue(for: myPayload) { peerHasMine = true }
            }
        }
        let next: Stage = hasTheirs ? (peerHasMine ? .paired : .waitingForPeer) : (hasSeenPeer ? .receiving : .looking)
        if next == .paired && stage != .paired { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        stage = next
    }
}

// MARK: - Camera

/// Front camera → 16 × 12 cells of average brightness per frame → the session's receiver.
/// Exposure is pulled down so the other screen's white tiles don't blow out, then locked once
/// the other phone is in view, so brightness means the same thing for a whole round.
private struct LightCamera: UIViewControllerRepresentable {
    let session: LightPairingSession

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.session = session
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var session: LightPairingSession?
        private let capture = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.eptt.facepair.camera")
        private var device: AVCaptureDevice?

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { return }
            self.device = device
            capture.sessionPreset = .inputPriority
            capture.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(output) else { return }
            capture.addOutput(output)
            configure(device)
            session?.onFirstSighting = { [weak self] in self?.lockExposure() }
        }

        /// 60 fps at a modest size if the camera can, and exposure biased down.
        private func configure(_ device: AVCaptureDevice) {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let formats = device.formats.filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width <= 1280 && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
            }
            if let format = formats.max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            } else {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(max(device.minExposureTargetBias, -1.5), completionHandler: nil)
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
        }

        private func lockExposure() {
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let capture = self.capture
            queue.async { capture.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let capture = self.capture
            queue.async { capture.stopRunning() }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let session else { return }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let cols = OpticalLink.cellColumns, rows = OpticalLink.cellRows
            var cells = [Float](repeating: 0, count: cols * rows)
            let step = max(1, width / 160)
            for r in 0..<rows {
                let y0 = r * height / rows, y1 = (r + 1) * height / rows
                for c in 0..<cols {
                    let x0 = c * width / cols, x1 = (c + 1) * width / cols
                    var sum = 0, n = 0
                    var y = y0
                    while y < y1 {
                        let row = luma + y * stride
                        var x = x0
                        while x < x1 { sum += Int(row[x]); n += 1; x += step }
                        y += step
                    }
                    cells[r * cols + c] = n > 0 ? Float(sum) / Float(n) : 0
                }
            }
            session.frame(time: time, cells: cells)
        }
    }
}
