import AVFoundation
import SwiftUI
import EPTTCore

/// Face-to-face pairing (EPTTCore `FacePairing`): hold two phones screen to screen. Each loops
/// its liquid codes and reads the other's with the front camera; both add each other.
struct FacePairView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pairing: FacePairing?
    @State private var frames: [String] = []
    @State private var status = "Hold your phones screen to screen"
    @State private var detail = "Tops together, about a hand apart. Both phones need this screen open."
    @State private var done: (name: String, code: String)?
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.86, energy: done == nil ? 1.2 : 1.8)

            // The front camera reads the other phone. Its preview stays hidden.
            FrontCodeScanner { handle($0) }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)

            VStack(spacing: 18) {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(NX.frost)
                    Spacer()
                }
                .padding(.horizontal, 22)

                if !frames.isEmpty {
                    CodeLoop(frames: frames)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .fill(LinearGradient(colors: [.white, Color(hex: 0xDDF8FF)], startPoint: .top, endPoint: .bottom))
                                .shadow(color: NX.cyan.opacity(done == nil ? 0.5 : 0.9), radius: done == nil ? 24 : 40)
                        )
                        .padding(.horizontal, 18)
                } else {
                    ProgressView().tint(NX.cyan).frame(height: 300)
                }

                VStack(spacing: 8) {
                    Text(status.uppercased())
                        .font(NX.label(16, .bold))
                        .tracking(2)
                        .foregroundStyle(NX.text)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(NX.body(14))
                        .foregroundStyle(NX.textDim)
                        .multilineTextAlignment(.center)
                    if let done {
                        Text(done.code)
                            .font(NX.display(32))
                            .tracking(4)
                            .foregroundStyle(.white)
                            .neonGlow(NX.cyan, radius: 12)
                            .padding(.top, 6)
                            .accessibilityLabel("Safety code \(done.code)")
                        Button("DONE") { dismiss() }
                            .buttonStyle(NXButtonStyle(kind: .gel))
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 26)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Full brightness makes the codes far easier to read from the other phone.
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
            model.engine.myCardURI { uri in
                guard let uri, let card = try? ContactCard(uri: uri) else {
                    status = "Couldn't load your card"
                    return
                }
                let session = FacePairing(localCard: card)
                pairing = session
                frames = session.frames
            }
        }
        .onDisappear {
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func handle(_ code: String) {
        guard var session = pairing, done == nil, let event = session.receive(code) else { return }
        pairing = session
        frames = session.frames
        switch event {
        case .gotOffer(let name):
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            status = "Got \(name)"
            detail = "Keep still while the other phone confirms…"
        case .completed(let card, let safetyCode):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            model.addContact(uri: card.uri)
            model.banner = "Paired with \(card.name) both ways"
            done = (card.name, safetyCode)
            status = "Paired with \(card.name)"
            detail = "Keep them together a moment so the other phone finishes too. Both screens should show this code:"
        case .rejected(let reason):
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            detail = reason
        }
    }
}

/// Loops through the pairing frames, a few per second, with a soft crossfade.
private struct CodeLoop: View {
    let frames: [String]
    @State private var index = 0

    var body: some View {
        ZStack {
            LiquidCode(text: frames[min(index, frames.count - 1)])
                .id(index)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.12), value: index)
        .task(id: frames) {
            index = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                index = (index + 1) % max(1, frames.count)
            }
        }
    }
}

/// Continuous QR reading with the front camera; reports every NXTPTT pairing frame it sees.
private struct FrontCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onCode = onCode
    }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var lastSeen: [String: Date] = [:]

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.sessionPreset = .high
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            let now = Date()
            for case let object as AVMetadataMachineReadableCodeObject in metadataObjects {
                guard let code = object.stringValue, code.hasPrefix(FacePairing.prefix) else { continue }
                // The same frame is seen many times a second; pass each on once per second.
                if let seen = lastSeen[code], now.timeIntervalSince(seen) < 1 { continue }
                lastSeen[code] = now
                onCode?(code)
            }
        }
    }
}
