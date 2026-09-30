import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import EPTTCore

/// Contacts, with a + menu to add someone: optical handshake (both phones add each other in
/// one go), your share link, or a talk group's code. Contact QR codes are off: they needed a
/// scan each way.
struct PairView: View {
    @EnvironmentObject private var model: AppModel
    @State private var uri: String?
    @State private var scanning = false
    @State private var facePairing = false
    @State private var creatingGroup = false

    var body: some View {
        NavigationStack {
            ZStack {
                GridBackground(horizon: 0.92, energy: 0.8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center) {
                            ScreenTitle(text: "Contacts")
                            Spacer()
                            addMenu
                        }

                        if model.snapshot.contacts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Nobody yet.")
                                    .font(NX.label(17, .semibold))
                                    .foregroundStyle(NX.text)
                                Text("Tap + and choose Optical handshake on both phones, then hold them screen to screen. They swap keys, addresses and forward-secrecy keys in one go. Not together? Tap + and send your link.")
                                    .font(NX.body(14))
                                    .foregroundStyle(NX.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 8)
                        }
                        VStack(spacing: 10) {
                            ForEach(model.snapshot.contacts) { contact in
                                NavigationLink {
                                    ContactDetailView(contact: contact)
                                } label: {
                                    ContactRow(contact: contact)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $scanning) { AddContactView() }
        .fullScreenCover(isPresented: $facePairing) { FacePairView() }
        .sheet(isPresented: $creatingGroup) { NewGroupView() }
        .onAppear { model.engine.myCardURI { uri = $0 } }
    }

    private var addMenu: some View {
        Menu {
            Button {
                facePairing = true
            } label: {
                Label("Optical handshake", systemImage: "iphone.radiowaves.left.and.right")
            }
            if let uri {
                ShareLink(item: uri) { Label("Share my link", systemImage: "square.and.arrow.up") }
            }
            Button {
                creatingGroup = true
            } label: {
                Label("New talk group", systemImage: "person.3")
            }
            Button {
                scanning = true
            } label: {
                Label("Join a group", systemImage: "qrcode.viewfinder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(NX.whiteHot)
                .frame(width: 46, height: 46)
                .background(GlassBackground(shape: Circle(), glow: 0.3))
                .overlay(Circle().strokeBorder(NX.cyan.opacity(0.7), lineWidth: 1))
                .shadow(color: NX.cyan.opacity(0.5), radius: 8)
        }
        .accessibilityLabel("Add")
        .accessibilityHint("Optical handshake, share your link, new talk group, or join a group")
    }
}

/// Your QR code inside a white glass plate with a scanning beam and light-line brackets.
struct QRFrame: View {
    let uri: String?
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.96), Color(hex: 0xD6F6FF, opacity: 0.93)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color(hex: 0xC8FAFF), lineWidth: 1))
                .shadow(color: NX.cyan.opacity(0.45), radius: 20)

            if let uri, let image = QRCode.image(for: uri) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .accessibilityLabel("Your contact code")
            } else {
                ProgressView().tint(NX.ink)
            }

            // Scanning beam.
            GeometryReader { geo in
                Capsule()
                    .fill(LinearGradient(colors: [.clear, NX.cyan, .white, NX.cyan, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3)
                    .shadow(color: NX.cyan, radius: 8)
                    .padding(.horizontal, 12)
                    .offset(y: sweep ? geo.size.height - 24 : 20)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Brackets().allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: 280, height: 280)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { sweep = true }
        }
    }

    private struct Brackets: View {
        var body: some View {
            ZStack {
                corner.frame(width: 34, height: 34).position(x: 9, y: 9)
                corner.rotationEffect(.degrees(180)).frame(width: 34, height: 34).position(x: 271, y: 271)
            }
            .frame(width: 280, height: 280)
            .neonGlow(NX.cyan, radius: 6)
        }

        private var corner: some View {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 34))
                p.addLine(to: CGPoint(x: 0, y: 14))
                p.addQuadCurve(to: CGPoint(x: 14, y: 0), control: .zero)
                p.addLine(to: CGPoint(x: 34, y: 0))
            }
            .stroke(NX.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

struct ContactRow: View {
    @EnvironmentObject private var model: AppModel
    let contact: Contact

    var body: some View {
        let online = model.snapshot.onlinePeers.contains(contact.id)
        HStack(spacing: 12) {
            InitialsRing(name: contact.name, size: 40, lit: online)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(NX.label(16, .bold)).foregroundStyle(NX.text)
                Text((model.snapshot.peerQuiet[contact.id] != nil ? "Do Not Disturb · " : "")
                     + (model.snapshot.peerRoutes[contact.id].map { "Connected · \($0.shortLabel)" } ?? (contact.isWakeable ? "Not connected · wakes by push" : "Not connected")))
                    .font(NX.body(13))
                    .foregroundStyle(NX.textDim)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(NX.frost.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .glass(cornerRadius: 18, glow: 0.1)
    }
}

struct ContactDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let contact: Contact

    var body: some View {
        Form {
            Section {
                Text(model.engine.safetyNumber(with: contact.id) ?? "—")
                    .font(NX.display(17))
                    .foregroundStyle(NX.text)
                Text("Compare this with \(contact.name)'s screen. If the numbers match, nobody is in the middle.")
                    .font(NX.body(13))
                    .foregroundStyle(NX.textDim)
            } header: {
                SectionCaption(text: "Safety number")
            }
            .nxRows()
            Section {
                Button {
                    if let channel = model.directChannel(for: contact) {
                        model.engine.select(channel.id)
                        model.tab = .talk
                    }
                } label: { Label("Talk privately", systemImage: "mic") }
                Button { model.engine.sendCallAlert(to: contact.id) } label: { Label("Call alert", systemImage: "bell.badge") }
            }
            .nxRows()
            Section {
                Toggle(isOn: Binding(
                    get: { model.snapshot.settings.priorityContacts.contains(contact.id) },
                    set: { model.engine.setPriority(contact.id, $0) }
                )) {
                    Label("Priority", systemImage: "star")
                }
            } header: {
                SectionCaption(text: "Do Not Disturb")
            } footer: {
                Text(model.snapshot.peerQuiet[contact.id].map { $0
                        ? "\(contact.name) is on Do Not Disturb, and you break through."
                        : "\(contact.name) is on Do Not Disturb: your messages are held on their phone until they're done." }
                     ?? "Priority contacts' messages and call alerts play even when you're on Do Not Disturb.")
                    .font(NX.body(13))
            }
            .nxRows()
            Section {
                LabeledContent("Background wake", value: contact.isWakeable ? "Yes" : "No")
                LabeledContent("Forward secrecy", value: contact.reachability.prekey != nil ? "Session keys active" : "After first exchange")
                ForEach(contact.reachability.candidates, id: \.self) { candidate in
                    Text(candidate.description).font(.caption.monospaced()).foregroundStyle(NX.textDim)
                }
            } header: {
                SectionCaption(text: "Reachability")
            }
            .nxRows()
            Section {
                Button("Remove contact", role: .destructive) {
                    model.engine.removeContact(contact.id)
                    dismiss()
                }
            }
            .nxRows()
        }
        .nxForm()
        // Pushed views don't pick up the tab bar's inset: keep the last row clear of it.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 84) }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddContactView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GridBackground(horizon: 0.9, energy: 0.7, moving: false)
                VStack(spacing: 16) {
                    QRScannerView { code in
                        if code.hasPrefix(ContactCard.uriPrefix) {
                            // Contacts pair by optical handshake now (or by link); contact QR codes are off.
                            model.banner = "Add contacts with an optical handshake, or open the link they send you"
                        } else {
                            model.open(link: code)
                        }
                        dismiss()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(NX.cyan, lineWidth: 2))
                    .neonGlow(NX.cyan, radius: 10)
                    .frame(maxHeight: 360)

                    Text("Scan a talk group's code, or paste an eptt:// link")
                        .font(NX.body(14))
                        .foregroundStyle(NX.textDim)
                    TextField("eptt://contact/…", text: $pasted, axis: .vertical)
                        .font(NX.body(15))
                        .padding(12)
                        .glass(cornerRadius: 14, glow: 0.1)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("ADD") {
                        model.open(link: pasted)
                        dismiss()
                    }
                    .buttonStyle(NXButtonStyle(kind: .gel))
                    .disabled(pasted.isEmpty)
                    .opacity(pasted.isEmpty ? 0.5 : 1)
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Camera QR scanner that reports the first `eptt://` code it sees (contact card or push key).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var reported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
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
            guard !reported,
                  let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                    .first(where: { $0.hasPrefix("eptt://") }) else { return }
            reported = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
