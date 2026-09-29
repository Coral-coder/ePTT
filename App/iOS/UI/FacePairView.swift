import AVFoundation
import SwiftUI
import EPTTCore

/// Face-to-face pairing over light only (PROTOCOL.md §12). Hold two phones screen to screen,
/// tops together: each shows a ring of glowing light blobs near the top, where the other
/// phone's front camera is, and reads the other's ring. Keys, name and relay mailbox travel as
/// light; the full signed cards follow through the encrypted relay.
///
/// Everything else on screen stays black, white or grey: the other camera only reads colour
/// as data, so no coloured UI may appear while pairing.
struct FacePairView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = LightPairingSession()
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            LightRing(frame: pairing.shownFrame, clock: pairing.clock, pulse: pairing.pulse,
                      seesPeer: pairing.seesPeer, done: pairing.stage == .paired)
                .ignoresSafeArea()

            LightCamera { pairing.reading($0) }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)

            VStack {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 22)
                Spacer()
                HandshakePanel(pairing: pairing) { dismiss() }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
            pairing.onPaired = { profile in
                model.engine.addLightPaired(profile)
            }
            model.engine.lightProfile { data in
                guard let data else { return }
                pairing.start(profile: data)
            }
        }
        .onDisappear {
            pairing.stop()
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
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

            // Overall progress: finding each other, their keys arriving, ours confirmed.
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
                     done: pairing.receivedProgress >= 1, active: pairing.stage == .receiving)
                step("They receive yours", done: pairing.peerHasMine,
                     active: pairing.stage == .waitingForPeer)
                step("Compare the safety code", done: false, active: pairing.stage == .paired)
            }

            if let code = pairing.safetyCode {
                Text(code)
                    .font(NX.display(30))
                    .tracking(4)
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.5), radius: 10)
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

// MARK: - Session

@MainActor
final class LightPairingSession: ObservableObject {
    enum Stage { case looking, receiving, waitingForPeer, paired }

    @Published private(set) var shownFrame: [Int] = Array(repeating: 0, count: LightCode.dataLobes)
    @Published private(set) var clock = false
    @Published private(set) var pulse = 0
    @Published private(set) var stage: Stage = .looking
    /// The other phone's ring is in view right now.
    @Published private(set) var seesPeer = false
    @Published private(set) var hasSeenPeer = false
    @Published private(set) var receivedProgress = 0.0
    /// The other phone showed that it has our whole message.
    @Published private(set) var peerHasMine = false
    @Published private(set) var safetyCode: String?
    @Published private(set) var peerName: String?

    var onPaired: ((LightProfile) -> Void)?

    /// Frame time. The camera sees each frame in 4–5 video frames at 30 fps.
    static let frameSeconds = 0.15

    private var myProfile = Data()
    private var received: Data?
    private var frames: [[Int]] = []
    private var ticker: Task<Void, Never>?
    private var assembler = LightCode.Assembler()
    private var started = Date()
    private var lastSeen = Date.distantPast
    // One reading per displayed frame: the clock flips on every frame, and a frame counts once
    // two readings in the same clock phase agree.
    private var phase: Bool?
    private var candidate: [Int]?
    private var acceptedThisPhase = false

    var overallProgress: Double {
        (hasSeenPeer ? 0.1 : 0) + 0.7 * receivedProgress + (peerHasMine ? 0.2 : 0)
    }

    var headline: String {
        switch stage {
        case .looking: return hasSeenPeer ? "Lost sight of the other phone" : "Looking for the other phone"
        case .receiving: return seesPeer ? "Receiving their keys" : "Hold still, lost sight of them"
        case .waitingForPeer: return "Got theirs, sending yours"
        case .paired: return "Paired with \(peerName ?? "them")"
        }
    }

    var hint: String {
        switch stage {
        case .looking:
            return Date().timeIntervalSince(started) > 8
                ? "Both phones on Face to face, screens facing, tops together about a hand apart. Turn the brightness up."
                : "Hold the phones screen to screen, tops together, about a hand apart."
        case .receiving: return "Keep them still until both finish."
        case .waitingForPeer: return "Keep holding them together so the other phone finishes reading yours."
        case .paired: return "Both phones should show this code. If they don't, remove the contact and try again."
        }
    }

    func start(profile: Data) {
        myProfile = profile
        frames = LightCode.frames(for: profile)
        started = Date()
        ticker = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                // Once we have theirs, every third frame says "got yours".
                if let received = self.received, index % 3 == 2 {
                    self.shownFrame = LightCode.ackFrame(for: received)
                } else {
                    self.shownFrame = self.frames[index % self.frames.count]
                }
                self.clock = index.isMultiple(of: 2)
                index += 1
                if self.seesPeer, Date().timeIntervalSince(self.lastSeen) > 1.2 {
                    self.seesPeer = false
                    self.refreshStage()
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.frameSeconds * 1_000_000_000))
            }
        }
    }

    func stop() { ticker?.cancel() }

    func reading(_ reading: LightCode.Reading?) {
        guard let reading else { return }
        lastSeen = Date()
        if !seesPeer || !hasSeenPeer {
            seesPeer = true
            hasSeenPeer = true
            refreshStage()
        }
        if reading.clock != phase {
            phase = reading.clock
            candidate = nil
            acceptedThisPhase = false
        }
        guard !acceptedThisPhase, let symbols = reading.symbols else { return }
        guard symbols == candidate else { candidate = symbols; return }
        acceptedThisPhase = true
        pulse += 1

        if LightCode.isAck(symbols, for: myProfile) {
            if !peerHasMine {
                peerHasMine = true
                refreshStage()
            }
            return
        }
        guard received == nil else { return }
        let payload = assembler.add(symbols)
        receivedProgress = assembler.progress
        guard let payload, let profile = try? LightProfile(encoded: payload) else {
            refreshStage()
            return
        }
        received = payload
        receivedProgress = 1
        peerName = profile.name
        safetyCode = LightCode.safetyCode(myProfile, payload)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onPaired?(profile)
        refreshStage()
    }

    private func refreshStage() {
        let next: Stage
        if received != nil {
            next = peerHasMine ? .paired : .waitingForPeer
        } else if receivedProgress > 0 {
            next = .receiving
        } else {
            next = .looking
        }
        if next == .paired && stage != .paired {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        stage = next
    }
}

// MARK: - Visual

/// The ring of 14 light blobs near the top of the screen (where the other phone's front camera
/// is): slot 0 white, slot 1 dark, slots 2…13 the frame's colours, and a pearl clock in the
/// middle that flips white/grey each frame. Each blob is liquid light: a glowing halo of its
/// own colour, a wobbling body and a soft sheen. Colours never mix between blobs, so the other
/// camera reads them cleanly. Faint deep-blue light drifts behind, too dark to read as data.
struct LightRing: View {
    let frame: [Int]
    let clock: Bool
    let pulse: Int
    let seesPeer: Bool
    let done: Bool
    @State private var kick = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                let w = size.width
                let center = CGPoint(x: w / 2, y: max(w * 0.5, size.height * 0.27))
                let radius = w * 0.37, lobe = w * 0.066
                let energy = seesPeer ? 1.0 : 0.55

                // Drifting deep light behind everything (max channel under 0.25: never data).
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: w * 0.07))
                    for i in 0..<7 {
                        let p = Double(i) * 0.9
                        let a = t * (0.18 + 0.02 * Double(i)) + p + kick * 0.4
                        let r = radius * (1.0 + 0.45 * sin(t * 0.35 + p))
                        let c = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a * 1.3) * r * 1.2 + w * 0.2)
                        let s = w * (0.16 + 0.05 * sin(t * 0.8 + p))
                        layer.fill(Path(ellipseIn: CGRect(x: c.x - s, y: c.y - s * 0.7, width: s * 2, height: s * 1.4)),
                                   with: .color(Color(red: 0.02, green: 0.10 + 0.04 * sin(p), blue: 0.22)))
                    }
                }

                let kickPhase = kick.truncatingRemainder(dividingBy: 1)
                let kickScale = 1 + 0.08 * max(0, 1 - kickPhase * 3)

                // Blob positions and colours.
                var blobs: [(CGPoint, (r: Double, g: Double, b: Double), Double)] = []
                for slot in 0..<LightCode.slots {
                    let rgb: (r: Double, g: Double, b: Double)
                    switch slot {
                    case 0: rgb = (1, 1, 1)
                    case 1: continue
                    default: rgb = LightCode.palette[frame[slot - 2]]
                    }
                    let a = -Double.pi / 2 + Double(slot) * 2 * .pi / Double(LightCode.slots)
                        + 0.035 * sin(t * 1.6 + Double(slot))
                    let c = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                    blobs.append((c, rgb, Double(slot)))
                }

                // Halos: each blob's own colour, dimmed, blurred.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: lobe * 0.55))
                    for (c, rgb, seed) in blobs {
                        let k = 0.5 * energy
                        layer.fill(blob(at: c, radius: lobe * 1.25 * kickScale, time: t, seed: seed + 50),
                                   with: .color(Color(red: rgb.r * k, green: rgb.g * k, blue: rgb.b * k)))
                    }
                }

                // Bodies, with a sheen of the same hue (lighter, still clearly that colour).
                for (c, rgb, seed) in blobs {
                    let breathe = 1 + 0.05 * sin(t * 2.4 + seed * 0.8) * energy
                    let body = blob(at: c, radius: lobe * kickScale * breathe, time: t, seed: seed)
                    context.fill(body, with: .color(Color(red: rgb.r, green: rgb.g, blue: rgb.b)))
                    let sheen = CGPoint(x: c.x - lobe * 0.28, y: c.y - lobe * 0.3)
                    let tint = (r: rgb.r + (1 - rgb.r) * 0.35, g: rgb.g + (1 - rgb.g) * 0.35, b: rgb.b + (1 - rgb.b) * 0.35)
                    context.fill(blob(at: sheen, radius: lobe * 0.32, time: t * 1.3, seed: seed + 7),
                                 with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)))
                }

                // The clock: a pearl that flips white/grey each frame, with a soft grey halo.
                let clockRadius = w * 0.12 * (1 + 0.03 * sin(t * 2))
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: clockRadius * 0.35))
                    layer.fill(blob(at: center, radius: clockRadius * 1.25, time: t, seed: 98),
                               with: .color(Color(white: clock ? 0.4 : 0.2)))
                }
                context.fill(blob(at: center, radius: clockRadius, time: t, seed: 99),
                             with: .color(clock ? .white : Color(white: 0.42)))

                if done {
                    // Settled: a thin white ring of light around everything.
                    let r = radius + lobe * 2.3
                    var glow = context
                    glow.addFilter(.shadow(color: .white.opacity(0.6), radius: w * 0.03))
                    glow.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                with: .color(Color(white: 0.5)), lineWidth: 2)
                }
            }
        }
        .onChange(of: pulse) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.3)) { kick += 1 }
        }
        .accessibilityHidden(true)
    }

    /// A wobbling, roughly round liquid blob.
    private func blob(at c: CGPoint, radius: Double, time t: Double, seed: Double) -> Path {
        var path = Path()
        let points = 32
        var pts: [CGPoint] = []
        for i in 0..<points {
            let a = Double(i) / Double(points) * 2 * .pi
            let wobble = 1 + 0.07 * sin(3 * a + t * 2.1 + seed) + 0.04 * sin(5 * a - t * 1.4 + seed * 2)
            pts.append(CGPoint(x: c.x + cos(a) * radius * wobble, y: c.y + sin(a) * radius * wobble))
        }
        // Smooth closed curve through the points (midpoint quadratic).
        func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        path.move(to: mid(pts[points - 1], pts[0]))
        for i in 0..<points {
            path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % points]), control: pts[i])
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Camera

/// Front camera → `LightCode.read` on every video frame, off the main thread.
private struct LightCamera: UIViewControllerRepresentable {
    let onReading: (LightCode.Reading?) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onReading = onReading
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) { controller.onReading = onReading }

    final class Controller: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onReading: ((LightCode.Reading?) -> Void)?
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.eptt.facepair.camera")

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.sessionPreset = .vga640x480
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            if (try? device.lockForConfiguration()) != nil {
                // Don't let white balance chase the colours; keep the frame rate steady.
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = self.session
            queue.async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            queue.async { session.stopRunning() }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let reading = LightCode.read(width: width, height: height, step: 4) { x, y in
                let p = pixels + y * stride + x * 4
                return (Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
            }
            DispatchQueue.main.async { [weak self] in self?.onReading?(reading) }
        }
    }
}
