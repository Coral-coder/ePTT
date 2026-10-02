import AVFoundation
import SwiftUI
import EPTTCore

/// Face-to-face pairing with Orbit codes (PROTOCOL.md §12): both phones show a cycle of round
/// codes, screen to screen, and read the other's with the front camera. Our own code, format and
/// reader (`OrbitCode`); no system scanner.
struct FacePairView: View {
    /// Invite whoever we pair with to this talk group.
    var group: Channel?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = OrbitPairingSession()
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            OrbitCamera(session: pairing)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                    Spacer()
                    Text(group.map { "ADD TO \($0.name.uppercased())" } ?? "OPTICAL HANDSHAKE")
                        .font(NX.label(12, .semibold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                GeometryReader { geo in
                    OrbitDisplay(pairing: pairing, diameter: min(geo.size.width - 12, geo.size.height))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                OrbitStepsPanel(pairing: pairing, groupName: group?.name) { dismiss() }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.8
            let groupID = group?.id
            // Add them as soon as their signed card is read, so pairing isn't lost if the other
            // phone closes before this one sees its confirmation. Group invites wait for that.
            pairing.onGotCard = { card in model.engine.addFacePaired(card) }
            pairing.onPaired = { card in
                model.engine.faceVerified(card.id)
                if let groupID { model.engine.addMember(card.id, toGroup: groupID) }
            }
            model.engine.faceCard { card in
                guard let card else { return }
                pairing.start(card: card)
            }
        }
        .onDisappear {
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

/// The code inside a glowing ring like the talk orb. The next frame swaps in every
/// `frameSeconds` while the whole code turns smoothly (18°/s: about a pixel of blur per camera
/// exposure, which the reader shrugs off). A satellite circles the ring and an arc fills with
/// progress. Both sit outside the code's black surround, where the reader doesn't look.
private struct OrbitDisplay: View {
    @ObservedObject var pairing: OrbitPairingSession
    let diameter: CGFloat

    var body: some View {
        // The code's margin disc (radius 1.20) fills 78 % of the space; the ring sits at 1.5.
        let codeSize = diameter * 0.78
        let ring = diameter * 0.98
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let tick = Int(t / OrbitPairingSession.frameSeconds)
            ZStack {
                Circle()
                    .strokeBorder(NX.cyan.opacity(pairing.stage == .paired ? 0.9 : 0.45), lineWidth: 2)
                    .shadow(color: NX.cyan.opacity(0.8), radius: 10)
                    .frame(width: ring, height: ring)
                Circle()
                    .trim(from: 0, to: pairing.progress)
                    .stroke(NX.ice, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: NX.cyan, radius: 8)
                    .frame(width: ring, height: ring)
                    .animation(.easeOut(duration: 0.3), value: pairing.progress)
                Circle()
                    .fill(NX.whiteHot)
                    .frame(width: 9, height: 9)
                    .shadow(color: NX.cyan, radius: 6)
                    .offset(y: -ring / 2)
                    .rotationEffect(.degrees(t * 90))
                if !pairing.images.isEmpty {
                    Image(decorative: pairing.images[tick % pairing.images.count], scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: codeSize, height: codeSize)
                        .clipShape(Circle())
                        .rotationEffect(.degrees((t * 18).truncatingRemainder(dividingBy: 360)))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .accessibilityElement()
        .accessibilityLabel("Pairing code. Hold it facing the other phone's screen.")
    }
}

private struct OrbitStepsPanel: View {
    @ObservedObject var pairing: OrbitPairingSession
    let groupName: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pairing.headline.uppercased())
                .font(NX.label(15, .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text(pairing.hint(groupName: groupName))
                .font(NX.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(NX.cyan.opacity(0.9))
                        .frame(width: max(8, geo.size.width * pairing.progress))
                        .animation(.easeOut(duration: 0.25), value: pairing.progress)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Pairing progress")
            .accessibilityValue("\(Int(pairing.progress * 100)) percent")

            VStack(alignment: .leading, spacing: 6) {
                step("See the other phone", done: pairing.stage != .looking, active: pairing.stage == .looking)
                step(pairing.stage == .receiving && pairing.collected.of > 0
                        ? "Read their card · \(pairing.collected.have) of \(pairing.collected.of)"
                        : "Read their card",
                     done: pairing.stage == .confirming || pairing.stage == .paired, active: pairing.stage == .receiving)
                step("They confirm they read ours", done: pairing.stage == .paired, active: pairing.stage == .confirming)
            }

            if let code = pairing.safetyCode {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SAFETY CODE").font(NX.label(10, .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
                        Text(code).font(NX.display(24)).tracking(3).foregroundStyle(.white)
                            .accessibilityLabel("Safety code \(code)")
                    }
                    Spacer()
                    Button(action: close) {
                        Text("DONE")
                            .font(NX.label(14, .bold))
                            .tracking(2)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(NX.cyan))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
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
                    Circle().fill(NX.cyan).frame(width: 7, height: 7)
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

final class OrbitPairingSession: ObservableObject {
    enum Stage { case looking, receiving, confirming, paired }

    static let frameSeconds = 0.25
    static let imageSize = 560

    @Published private(set) var stage: Stage = .looking
    @Published private(set) var images: [CGImage] = []
    @Published private(set) var collected = (have: 0, of: 0)
    @Published private(set) var safetyCode: String?
    @Published private(set) var peerName = ""
    @Published private(set) var slow = false
    var onGotCard: ((ContactCard) -> Void)?
    var onPaired: ((ContactCard) -> Void)?
    private var addedPeer = false

    private let lock = NSLock()
    private var handshake: OrbitHandshake?
    private var shownFrames: [OrbitCode.Frame] = []
    /// Rendered codes by frame; the loop gains ACK frames later but keeps its card frames.
    private var imageCache: [OrbitCode.Frame: CGImage] = [:]
    private var busy = false
    private let render = DispatchQueue(label: "app.eptt.orbit.render", qos: .userInitiated)

    var progress: Double {
        switch stage {
        case .looking: return 0.03
        case .receiving: return 0.05 + 0.75 * (collected.of > 0 ? Double(collected.have) / Double(collected.of) : 0)
        case .confirming: return 0.88
        case .paired: return 1
        }
    }

    var headline: String {
        switch stage {
        case .looking: return "Looking for the other phone"
        case .receiving: return "Reading their code"
        case .confirming: return peerName.isEmpty ? "Got theirs, confirming" : "Got \(peerName), confirming"
        case .paired: return peerName.isEmpty ? "Paired" : "Paired with \(peerName)"
        }
    }

    func hint(groupName: String?) -> String {
        switch stage {
        case .looking:
            return slow
                ? "Open Optical handshake on the other phone too. Screens facing, tops together, about 15–20 cm apart. Tilt a little if there's glare."
                : "Hold the phones screen to screen, tops together, about 15–20 cm apart."
        case .receiving, .confirming:
            return "Keep them still until both finish."
        case .paired:
            return groupName.map { "Both phones should show this code. They've been added to \($0)." }
                ?? "Both phones should show this code. If they don't, remove the contact and try again."
        }
    }

    func start(card: ContactCard) {
        lock.lock()
        guard handshake == nil else { lock.unlock(); return }
        handshake = OrbitHandshake(card: card)
        lock.unlock()
        refreshImages()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.stage == .looking { self?.slow = true }
        }
    }

    /// Redraws the codes if the frames to show have changed.
    private func refreshImages() {
        lock.lock()
        let frames = handshake?.frames ?? []
        let changed = frames != shownFrames
        shownFrames = frames
        lock.unlock()
        guard changed else { return }
        render.async { [weak self] in
            guard let self else { return }
            let images: [CGImage] = frames.compactMap { frame in
                if let cached = self.imageCache[frame] { return cached }
                let image = Self.image(OrbitCode.render(frame, size: Self.imageSize), size: Self.imageSize)
                self.imageCache[frame] = image
                return image
            }
            DispatchQueue.main.async { self.images = images }
        }
    }

    private static func image(_ pixels: [UInt8], size: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Camera queue. Drops the frame if the last one is still being read.
    func readFrame(luma: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        lock.lock()
        if busy || handshake == nil { lock.unlock(); return }
        busy = true
        lock.unlock()
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<height { (out.baseAddress! + y * width).update(from: luma + y * stride, count: width) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frame = OrbitCode.read(luma: pixels, width: width, height: height)
            guard let self else { return }
            self.lock.lock()
            self.busy = false
            guard let frame, var handshake = self.handshake else { self.lock.unlock(); return }
            let event = handshake.receive(frame)
            self.handshake = handshake
            let ours = frame.session == handshake.session
            let collected = handshake.collected, complete = handshake.isComplete, peer = handshake.peer
            let code = handshake.safetyCode
            self.lock.unlock()
            guard !ours else { return }
            Task { @MainActor in
                self.update(event: event, collected: collected, complete: complete, peer: peer, code: code)
            }
        }
    }

    /// Works from the handshake's state, not just the event, so updates arriving out of order
    /// can't lose the moment of completion.
    @MainActor
    private func update(event: OrbitHandshake.Event?, collected: (have: Int, of: Int), complete: Bool,
                        peer: ContactCard?, code: String?) {
        guard stage != .paired else { return }
        self.collected = collected
        if let peer {
            if !peer.name.isEmpty { peerName = peer.name }
            if !addedPeer {
                addedPeer = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onGotCard?(peer)
            }
        }
        if complete, let peer, let code {
            safetyCode = code
            stage = .paired
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onPaired?(peer)
        } else {
            stage = peer != nil ? .confirming : .receiving
        }
        refreshImages()
    }
}

// MARK: - Camera

/// Front camera → greyscale frames → the session. VGA is plenty: the code fills much of the view.
private struct OrbitCamera: UIViewControllerRepresentable {
    let session: OrbitPairingSession

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.session = session
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var session: OrbitPairingSession?
        private let capture = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.eptt.orbit.camera")

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { return }
            capture.sessionPreset = capture.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
            capture.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(output) else { return }
            capture.addOutput(output)
            if (try? device.lockForConfiguration()) != nil {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                // A bright white disc on a dark screen: pull exposure down so it doesn't bloom.
                device.setExposureTargetBias(max(device.minExposureTargetBias, -0.7), completionHandler: nil)
                device.unlockForConfiguration()
            }
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
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            session.readFrame(luma: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                              height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                              stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        }
    }
}
