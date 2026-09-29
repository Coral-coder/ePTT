import AVFoundation
import MultipeerConnectivity
import SwiftUI
import EPTTCore

/// Face-to-face pairing (PROTOCOL.md §12): hold two phones screen to screen. They swap cards over
/// a nearby radio link while each screen dances a colour rhythm that the other reads with its
/// front camera. A card is accepted only when the radio and the light agree.
struct FacePairView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = FlowPairingSession()
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            FlowField(symbol: pairing.shownSymbol, peerPulse: pairing.peerPulse,
                      progress: pairing.progress, done: pairing.done != nil)
                .ignoresSafeArea()

            // The front camera reads the other phone; no preview needed.
            ColorCamera { pairing.cameraSample($0) }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)

            VStack {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                    Spacer()
                }
                .padding(.horizontal, 22)
                Spacer()
                VStack(spacing: 8) {
                    Text(pairing.status.uppercased())
                        .font(NX.label(15, .bold))
                        .tracking(2)
                    Text(pairing.detail)
                        .font(NX.body(13))
                        .opacity(0.85)
                    if let done = pairing.done {
                        Text(done.code)
                            .font(NX.display(30))
                            .tracking(4)
                            .neonGlow(NX.cyan, radius: 12)
                            .padding(.top, 4)
                            .accessibilityLabel("Safety code \(done.code)")
                        Button("DONE") { dismiss() }
                            .buttonStyle(NXButtonStyle(kind: .gel))
                            .padding(.top, 6)
                    }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.45)))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
            pairing.onVerified = { card in
                model.addContact(uri: card.uri)
                model.banner = "Paired with \(card.name) both ways"
            }
            model.engine.myCardURI { uri in
                guard let uri, let card = try? ContactCard(uri: uri) else { return }
                pairing.start(card: card)
            }
        }
        .onDisappear {
            pairing.stop()
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Session logic

@MainActor
final class FlowPairingSession: NSObject, ObservableObject {
    @Published private(set) var shownSymbol = FlowCode.sync
    @Published private(set) var peerPulse = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Hold your phones screen to screen"
    @Published private(set) var detail = "Tops together, a hand apart. Open Face to face on both."
    @Published private(set) var done: (name: String, code: String)?

    var onVerified: ((ContactCard) -> Void)?

    /// How long each colour stays on screen.
    static let symbolSeconds = 0.1

    private var card: ContactCard?
    private let nonce = Data.random(count: 16)
    private var symbols: [Int] = []
    private var ticker: Task<Void, Never>?
    private var decoder = FlowCode.Decoder()
    private var decoded: Set<Data> = []
    private var offers: [MCPeerID: (nonce: Data, card: ContactCard)] = [:]

    private let peerID = MCPeerID(displayName: UUID().uuidString)
    private lazy var session: MCSession = {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    static let serviceType = "nxpt-pair"   // Info.plist lists _nxpt-pair._tcp/_udp

    private var myOffer: Data { nonce + (card?.encoded ?? Data()) }

    func start(card: ContactCard) {
        self.card = card
        symbols = FlowCode.symbols(for: FlowPairing.commitment(nonce: nonce, card: card.encoded))
        ticker = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.shownSymbol = self.symbols[index % self.symbols.count]
                index += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.symbolSeconds * 1_000_000_000))
            }
        }
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        ticker?.cancel()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    func cameraSample(_ sample: Int?) {
        guard done == nil else { return }
        let (symbol, commitment) = decoder.push(sample)
        if symbol != nil { peerPulse += 1 }
        progress = Double(decoder.progress) / Double(FlowCode.digits)
        if decoder.progress > 0, offers.isEmpty {
            status = "Reading…"
            detail = "Keep still. Waiting for the other phone's radio too."
        } else if decoder.progress > 0 {
            status = "Reading…"
            detail = "Keep still."
        }
        if let commitment {
            decoded.insert(commitment)
            match()
        }
    }

    private func received(_ data: Data, from peer: MCPeerID) {
        guard data.count > 20, data.prefix(4) == Data("NXPO".utf8) else { return }
        let nonce = data.subdata(in: data.startIndex + 4 ..< data.startIndex + 20)
        guard let card = try? ContactCard(encoded: data.subdata(in: data.startIndex + 20 ..< data.endIndex)),
              card.id != self.card?.id else { return }
        offers[peer] = (nonce, card)
        match()
    }

    /// Accepts a radio offer only if its commitment is the one the camera read.
    private func match() {
        guard done == nil else { return }
        for (_, offer) in offers where decoded.contains(FlowPairing.commitment(nonce: offer.nonce, card: offer.card.encoded)) {
            let code = FlowPairing.safetyCode(myOffer, offer.nonce + offer.card.encoded)
            done = (offer.card.name, code)
            progress = 1
            status = "Paired with \(offer.card.name)"
            detail = "Hold on a moment so the other phone finishes too. Both should show:"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onVerified?(offer.card)
            return
        }
        if !decoded.isEmpty, !offers.isEmpty {
            detail = "The phone you're facing isn't the one on the radio. Keep them together."
        }
    }

    private func sendOffer(to peer: MCPeerID) {
        guard let card else { return }
        try? session.send(Data("NXPO".utf8) + nonce + card.encoded, toPeers: [peer], with: .reliable)
    }
}

extension FlowPairingSession: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        Task { @MainActor in self.sendOffer(to: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.received(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, self.session) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            // One side invites (the lower ID), so the pair doesn't connect twice.
            guard self.peerID.displayName < peerID.displayName else { return }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

// MARK: - Visual

/// The display colours for the rhythm's symbols; the camera side classifies by hue.
enum FlowPalette {
    static let colors: [Color] = [
        Color(red: 0.00, green: 0.86, blue: 1.00),   // cyan
        Color(red: 0.55, green: 0.27, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.16, blue: 0.35),   // rose
        Color(red: 0.51, green: 1.00, blue: 0.16),   // lime
    ]
    static let hues: [Double] = [188, 262, 347, 97]

    static func color(_ symbol: Int) -> Color { symbol < colors.count ? colors[symbol] : .white }
}

/// A full-screen field of liquid lobes in the current colour. Only brightness moves, so the hue
/// the other camera averages stays clean. The lobes swirl on their own and jump whenever the
/// other phone's colour changes, and a ring fills as its code is read.
struct FlowField: View {
    let symbol: Int
    let peerPulse: Int
    let progress: Double
    let done: Bool
    @State private var kick = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let base = FlowPalette.color(done ? 0 : symbol)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height)
                // Dark and bright lobes orbiting the centre: a slowly morphing, amorphous flow.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: radius * 0.08))
                    for i in 0..<7 {
                        let phase = Double(i) * 0.9
                        let swirl = t * (0.35 + 0.05 * Double(i)) + phase + kick
                        let orbit = radius * (0.18 + 0.05 * sin(t * 0.7 + phase) + 0.04 * kick.truncatingRemainder(dividingBy: 1))
                        let p = CGPoint(x: center.x + cos(swirl) * orbit * 1.1, y: center.y + sin(swirl * 1.3) * orbit * 1.6)
                        let r = radius * (0.16 + 0.05 * sin(t * 1.3 + phase))
                        let shade: Color = i.isMultiple(of: 2) ? .white.opacity(0.35) : .black.opacity(0.3)
                        layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 1.2, width: r * 2, height: r * 2.4)),
                                   with: .color(shade))
                    }
                }
                // Progress ring for the other phone's code.
                var ring = Path()
                ring.addArc(center: center, radius: radius * 0.42, startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * progress), clockwise: false)
                context.stroke(ring, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
        .onChange(of: peerPulse) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.25)) { kick += 0.35 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Camera

/// Front-camera colour reader: averages the middle of each video frame and classifies it as one
/// of the rhythm's colours (or white), reporting one sample per frame on the main queue.
private struct ColorCamera: UIViewControllerRepresentable {
    let onSample: (Int?) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onSample = onSample
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) { controller.onSample = onSample }

    final class Controller: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onSample: ((Int?) -> Void)?
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
            // Keep the camera from chasing the colours with its white balance.
            if (try? device.lockForConfiguration()) != nil {
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
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
            let sample = Self.classify(Self.averageColor(buffer))
            DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
        }

        /// Mean RGB (0...1) over the middle 60 % of the frame, on a sparse grid.
        static func averageColor(_ buffer: CVPixelBuffer) -> (r: Double, g: Double, b: Double) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            let steps = 24
            for iy in 0..<steps {
                let y = Int(Double(height) * (0.2 + 0.6 * Double(iy) / Double(steps - 1)))
                for ix in 0..<steps {
                    let x = Int(Double(width) * (0.2 + 0.6 * Double(ix) / Double(steps - 1)))
                    let p = pixels + y * stride + x * 4
                    b += Double(p[0]); g += Double(p[1]); r += Double(p[2]); n += 1
                }
            }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        /// Nearest rhythm colour by hue, white for the sync flash, nil when unclear.
        static func classify(_ c: (r: Double, g: Double, b: Double)) -> Int? {
            let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b)
            guard maxC > 0.18 else { return nil }                        // too dark to tell
            let saturation = (maxC - minC) / maxC
            if saturation < 0.22 { return maxC > 0.45 ? FlowCode.sync : nil }
            var hue: Double
            let delta = maxC - minC
            if maxC == c.r { hue = 60 * ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == c.g { hue = 60 * ((c.b - c.r) / delta + 2) }
            else { hue = 60 * ((c.r - c.g) / delta + 4) }
            if hue < 0 { hue += 360 }
            let distances = FlowPalette.hues.map { target -> Double in
                let d = abs(hue - target).truncatingRemainder(dividingBy: 360)
                return min(d, 360 - d)
            }
            guard let best = distances.enumerated().min(by: { $0.element < $1.element }), best.element < 40 else { return nil }
            return best.offset
        }
    }
}
