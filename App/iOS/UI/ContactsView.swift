import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import EPTTCore

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var showingMyCard = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.snapshot.contacts) { contact in
                    NavigationLink {
                        ContactDetailView(contact: contact)
                    } label: {
                        HStack {
                            Circle()
                                .fill(model.snapshot.onlinePeers.contains(contact.id) ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 10, height: 10)
                            Text(contact.name)
                        }
                    }
                }
                if model.snapshot.contacts.isEmpty {
                    Text("Scan a friend's Chirp code to add them. There is no directory: you add people in person or through a link they send you.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingMyCard = true } label: { Label("My code", systemImage: "qrcode") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Label("Add", systemImage: "person.badge.plus") }
                }
            }
            .sheet(isPresented: $adding) { AddContactView() }
            .sheet(isPresented: $showingMyCard) { MyCardView() }
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let contact: Contact

    var body: some View {
        Form {
            Section("Safety number") {
                Text(model.engine.safetyNumber(with: contact.id) ?? "—")
                    .font(.system(.title3, design: .monospaced))
                Text("Compare this with \(contact.name)'s screen. If the numbers match, nobody is in the middle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    if let channel = model.directChannel(for: contact) { model.engine.select(channel.id) }
                } label: { Label("Talk privately", systemImage: "mic") }
                Button { model.engine.sendCallAlert(to: contact.id) } label: { Label("Call alert", systemImage: "bell.badge") }
            }
            Section("Reachability") {
                LabeledContent("Background wake", value: contact.isWakeable ? "Yes" : "No")
                ForEach(contact.reachability.candidates, id: \.self) { candidate in
                    Text(candidate.description).font(.caption.monospaced())
                }
            }
            Section {
                Button("Remove contact", role: .destructive) {
                    model.engine.removeContact(contact.id)
                    dismiss()
                }
            }
        }
        .navigationTitle(contact.name)
    }
}

struct AddContactView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRScannerView { code in
                    model.open(link: code)
                    dismiss()
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxHeight: 360)

                Text("Or paste an eptt:// link")
                    .foregroundStyle(.secondary)
                TextField("eptt://contact/…", text: $pasted, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    model.open(link: pasted)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasted.isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle("Add contact")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct MyCardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var uri: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let uri, let image = QRCode.image(for: uri) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                    Text(model.snapshot.settings.displayName).font(.title2.weight(.semibold))
                    ShareLink(item: uri) { Label("Share link", systemImage: "square.and.arrow.up") }
                    Text("Your code includes your current network addresses. Share a fresh one if it has been a while.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("My Chirp code")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { model.engine.myCardURI { uri = $0 } }
        }
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
