import AVFoundation
import SwiftUI
import EPTTCore

/// Face-to-face pairing over light only (PROTOCOL.md §12). Hold two phones screen to screen,
/// tops together: each shows a ring of flowing colour lobes near the top, where the other
/// phone's front camera is, and reads the other's ring. Keys, name and relay mailbox travel as
/// light; the full signed cards follow through the encrypted relay.
struct FacePairView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = LightPairingSession()
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            LightRing(frame: pairing.shownFrame, clock: pairing.clock, pulse: pairing.pulse,
                      progress: pairing.progress, done: pairing.done != nil)
                .ignoresSafeArea()

            LightCamera { pairing.reading($0) }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)

            VStack {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(NX.frost)
                    Spacer()
                }
                .padding(.horizontal, 22)
                Spacer()
                VStack(spacing: 8) {
                    Text(pairing.status.uppercased())
                        .font(NX.label(15, .bold))
                        .tracking(2)
                        .foregroundStyle(NX.text)
                    Text(pairing.detail)
                        .font(NX.body(13))
                        .foregroundStyle(NX.textDim)
                    if let done = pairing.done {
                        Text(done.code)
                            .font(NX.display(30))
                            .tracking(4)
                            .foregroundStyle(.white)
                            .neonGlow(NX.cyan, radius: 12)
                            .padding(.top, 4)
                            .accessibilityLabel("Safety code \(done.code)")
                        Button("DONE") { dismiss() }
                            .buttonStyle(NXButtonStyle(kind: .gel))
                            .padding(.top, 6)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
            pairing.onPaired = { profile in
                model.engine.addLightPaired(profile)
                model.banner = "Paired with \(profile.name) both ways"
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

// MARK: - Session

@MainActor
final class LightPairingSession: ObservableObject {
    @Published private(set) var shownFrame: [Int] = Array(repeating: 0, count: LightCode.dataLobes)
    @Published private(set) var clock = false
    @Published private(set) var pulse = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Hold your phones screen to screen"
    @Published private(set) var detail = "Tops together, about a hand apart, with Face to face open on both."
    @Published private(set) var done: (name: String, code: String)?

    var onPaired: ((LightProfile) -> Void)?

    /// Frame time. The camera sees each frame in 4–5 video frames at 30 fps.
    static let frameSeconds = 0.15

    private var myProfile = Data()
    private var frames: [[Int]] = []
    private var ticker: Task<Void, Never>?
    private var assembler = LightCode.Assembler()
    // One reading per displayed frame: the clock flips on every frame, and a frame counts once
    // two readings in the same clock phase agree.
    private var phase: Bool?
    private var candidate: [Int]?
    private var acceptedThisPhase = false

    func start(profile: Data) {
        myProfile = profile
        frames = LightCode.frames(for: profile)
        ticker = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.shownFrame = self.frames[index % self.frames.count]
                self.clock = index.isMultiple(of: 2)
                index += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.frameSeconds * 1_000_000_000))
            }
        }
    }

    func stop() { ticker?.cancel() }

    func reading(_ reading: LightCode.Reading?) {
        guard done == nil, let reading else { return }
        if reading.clock != phase {
            phase = reading.clock
            candidate = nil
            acceptedThisPhase = false
        }
        guard !acceptedThisPhase, let symbols = reading.symbols else { return }
        guard symbols == candidate else { candidate = symbols; return }
        acceptedThisPhase = true
        pulse += 1
        let payload = assembler.add(symbols)
        progress = assembler.progress
        if progress > 0 {
            status = "Reading… \(Int(progress * 100))%"
            detail = "Keep still. Hold them together until both finish."
        }
        guard let payload, let profile = try? LightProfile(encoded: payload) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        progress = 1
        done = (profile.name, LightCode.safetyCode(myProfile, payload))
        status = "Paired with \(profile.name)"
        detail = "Keep them together a moment so the other phone finishes too. Both should show:"
        onPaired?(profile)
    }
}

// MARK: - Visual

/// The ring of 14 lobes near the top of the screen (where the other phone's front camera is):
/// slot 0 white, slot 1 dark, slots 2…13 the frame's colours, and a clock disc in the middle.
/// The lobes keep their places but wobble and breathe, flowing tendrils swirl in the dark
/// background, and everything kicks when this phone reads a frame from the other.
struct LightRing: View {
    let frame: [Int]
    let clock: Bool
    let pulse: Int
    let progress: Double
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
                let radius = w * 0.37, lobe = w * 0.068

                // Dark flowing tendrils (too dark for the other camera to mistake for a lobe).
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: w * 0.05))
                    for i in 0..<9 {
                        let p = Double(i) * 0.7
                        let a = t * (0.25 + 0.03 * Double(i)) + p + kick * 0.6
                        let r = radius * (0.9 + 0.5 * sin(t * 0.4 + p))
                        let c = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a * 1.2) * r * 1.3 + w * 0.3)
                        let s = w * (0.18 + 0.05 * sin(t + p))
                        layer.fill(Path(ellipseIn: CGRect(x: c.x - s, y: c.y - s * 0.6, width: s * 2, height: s * 1.2)),
                                   with: .color(Color(red: 0.0, green: 0.13 + 0.05 * sin(p), blue: 0.22)))
                    }
                }

                // Progress: how much of the other phone's code has been read.
                var arc = Path()
                arc.addArc(center: center, radius: radius + lobe * 1.7, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * progress), clockwise: false)
                // Kept dark (under 30 % brightness) so the other camera never reads it as a lobe.
                context.stroke(arc, with: .color(Color(red: 0, green: 0.2, blue: 0.27)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))

                // The lobes.
                let kickScale = 1 + 0.06 * max(0, 1 - (kick.truncatingRemainder(dividingBy: 1)) * 3)
                for slot in 0..<LightCode.slots {
                    let rgb: (r: Double, g: Double, b: Double)
                    switch slot {
                    case 0: rgb = (1, 1, 1)
                    case 1: continue
                    default: rgb = LightCode.palette[frame[slot - 2]]
                    }
                    let a = -Double.pi / 2 + Double(slot) * 2 * .pi / Double(LightCode.slots)
                        + 0.03 * sin(t * 1.7 + Double(slot))
                    let c = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                    context.fill(blob(at: c, radius: lobe * kickScale, time: t, seed: Double(slot)),
                                 with: .color(Color(red: rgb.r, green: rgb.g, blue: rgb.b)))
                }

                // The clock.
                let clockRadius = w * 0.12 * (1 + 0.03 * sin(t * 2))
                context.fill(blob(at: center, radius: clockRadius, time: t, seed: 99),
                             with: .color(clock ? .white : Color(white: 0.42)))
                if done {
                    var glow = context
                    glow.addFilter(.shadow(color: NX.cyan, radius: w * 0.05))
                    glow.stroke(Path(ellipseIn: CGRect(x: center.x - radius - lobe * 2.2, y: center.y - radius - lobe * 2.2,
                                                       width: (radius + lobe * 2.2) * 2, height: (radius + lobe * 2.2) * 2)),
                                with: .color(Color(red: 0, green: 0.2, blue: 0.27)), lineWidth: 3)
                }
            }
        }
        .onChange(of: pulse) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.3)) { kick += 1 }
        }
        .accessibilityHidden(true)
    }

    /// A wobbling, roughly round blob.
    private func blob(at c: CGPoint, radius: Double, time t: Double, seed: Double) -> Path {
        var path = Path()
        let points = 28
        for i in 0...points {
            let a = Double(i) / Double(points) * 2 * .pi
            let wobble = 1 + 0.06 * sin(3 * a + t * 2.1 + seed) + 0.04 * sin(5 * a - t * 1.4 + seed * 2)
            let p = CGPoint(x: c.x + cos(a) * radius * wobble, y: c.y + sin(a) * radius * wobble)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
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
