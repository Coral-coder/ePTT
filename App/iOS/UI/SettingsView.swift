import SwiftUI
import EPTTCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var staticCandidates = ""

    private var settings: Settings { model.snapshot.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Display name", text: $name)
                        .onSubmit { model.engine.updateSettings { [name] in $0.displayName = name } }
                }

                Section {
                    Toggle("Always listening", isOn: binding(\.alwaysListening))
                } footer: {
                    Text("Keeps the app running with an open audio session, so it hears peers without push wake-ups. Uses noticeably more battery and shows the microphone indicator. With it off, iOS wakes ePTT through Apple's Push to Talk service when someone keys up.")
                }

                Section {
                    Toggle("Discover public address (STUN)", isOn: binding(\.stunEnabled))
                    TextField("Extra addresses, e.g. me.tailnet.ts.net:47474", text: $staticCandidates, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(saveStaticCandidates)
                } header: {
                    Text("Network")
                } footer: {
                    Text("STUN asks a public server what your address looks like from the internet; it never carries audio. Extra addresses let you publish an overlay VPN (Tailscale, ZeroTier, WireGuard) address that works through any NAT. Separate them with commas.")
                }

                Section {
                    NavigationLink("Push key") { PushKeyView() }
                } footer: {
                    Text("The push key lets ePTT wake your friends' phones when you key up. Everyone in your group needs the same key; share it in person.")
                }

                Section("Apple Watch") {
                    Toggle("Play received audio on watch", isOn: binding(\.forwardAudioToWatch))
                }

                Section("Status") {
                    LabeledContent("Push to Talk", value: model.snapshot.pushToTalkAvailable ? "Ready" : "Unavailable")
                    LabeledContent("Background wake", value: model.snapshot.wakeAvailable ? "Enabled" : "No push key installed")
                    ForEach(model.snapshot.candidates, id: \.self) { candidate in
                        Text(candidate.description).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                name = settings.displayName
                staticCandidates = settings.staticCandidates.joined(separator: ", ")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in model.engine.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func saveStaticCandidates() {
        let entries = staticCandidates.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        model.engine.updateSettings { $0.staticCandidates = entries }
    }
}

/// Enter the APNs key from the developer portal once, then share it with your group as a QR code.
struct PushKeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var teamID = ""
    @State private var keyID = ""
    @State private var pem = ""
    @State private var shareURI: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: model.snapshot.wakeAvailable ? "Installed" : "Not installed")
            } footer: {
                Text("Anyone holding this key can send push notifications to ePTT users whose push tokens they know. It cannot decrypt or fake audio. Only share it with people you trust, and revoke it in the Apple developer portal if it leaks.")
            }

            if let shareURI, let image = QRCode.image(for: shareURI) {
                Section("Share with your group") {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)
                    ShareLink(item: shareURI) { Label("Share link", systemImage: "square.and.arrow.up") }
                }
            }

            Section {
                TextField("Team ID", text: $teamID)
                TextField("Key ID", text: $keyID)
                TextEditor(text: $pem)
                    .font(.caption.monospaced())
                    .frame(minHeight: 120)
                Button("Install key") {
                    let uri = PushKey(teamID: teamID.trimmingCharacters(in: .whitespaces),
                                      keyID: keyID.trimmingCharacters(in: .whitespaces),
                                      pem: pem.trimmingCharacters(in: .whitespacesAndNewlines)).uri
                    model.open(link: uri)
                    shareURI = model.engine.pushKeyURI()
                }
                .disabled(teamID.isEmpty || keyID.isEmpty || pem.isEmpty)
            } header: {
                Text("Enter a key")
            } footer: {
                Text("Paste the contents of the AuthKey_XXXXXXXXXX.p8 file, or scan a friend's push key QR code from Contacts → Add.")
                    .textSelection(.enabled)
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .navigationTitle("Push key")
        .onAppear { shareURI = model.engine.pushKeyURI() }
    }
}
