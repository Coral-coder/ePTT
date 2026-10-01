import SwiftUI
import UserNotifications
import EPTTCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var staticCandidates = ""
    @State private var notificationStatus = "…"
    @FocusState private var nameFocused: Bool

    private var settings: Settings { model.snapshot.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onChange(of: nameFocused) { focused in if !focused { saveName() } }
                }
                .nxRows()

                Section {
                    Picker("Layout", selection: Binding(
                        get: { settings.talkLayout },
                        set: { value in model.engine.updateSettings { $0.talkLayout = value } }
                    )) {
                        ForEach(TalkLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                } header: {
                    Text("Talk screen")
                } footer: {
                    Text(settings.talkLayout.summary + (settings.talkLayout == .classic ? "" : " Long-press a channel in Channels to pin or unpin it."))
                }
                .nxRows()

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
                .nxRows()

                Section {
                    Label("Push to Talk shortcut", systemImage: "hand.tap")
                } header: {
                    Text("Action Button & Siri")
                } footer: {
                    Text("In Settings › Action Button, choose Shortcut › NXTPTT › Push to Talk. Press once to key up and again to unkey; it unkeys on its own after a minute. You can also say \u{201C}Hey Siri, talk on NXTPTT.\u{201D} The side button itself can't be used by apps; Bluetooth PTT buttons can.")
                }
                .nxRows()

                Section("Sounds") {
                    NavigationLink("Nextel sounds") { SoundsView() }
                }
                .nxRows()

                Section {
                    Toggle("iCloud relay fallback", isOn: binding(\.relayEnabled))
                        .disabled(!model.snapshot.relayAvailable)
                } footer: {
                    Text("If someone can't be reached directly, NXTPTT leaves the encrypted transmission in iCloud for up to 24 hours and deletes it once delivered. Apple only ever sees encrypted data. Requires being signed in to iCloud.")
                }
                .nxRows()

                Section {
                    Button("Erase received audio now", role: .destructive) { model.engine.burnReceivedAudio() }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Messages are decrypted only to play. Lock-screen sounds are deleted 10 minutes after they arrive, and a replayable message after an hour; this erases both now. The app hides its screen in the app switcher and while the screen is recorded or mirrored.")
                }
                .nxRows()

                Section {
                    NavigationLink("Push key") { PushKeyView() }
                } footer: {
                    Text("The push key lets NXTPTT wake your friends' phones when you key up. Everyone in your group needs the same key; share it in person.")
                }
                .nxRows()

                Section {
                    Toggle("Live waveform", isOn: binding(\.liveWaveform))
                } footer: {
                    Text("Off: the animated wave. On: the wave follows the actual audio: your voice while you talk, theirs while you listen.")
                }
                .nxRows()

                Section {
                    Toggle("Play received audio on watch", isOn: binding(\.playOnWatch))
                    Toggle("Standalone watch", isOn: binding(\.standaloneWatch))
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Copies your NXTPTT identity, contacts and keys to your paired watch over the encrypted watch link, so it can send and receive through the iCloud relay when your iPhone isn't nearby.")
                }
                .nxRows()

                Section("Status") {
                    LabeledContent("Push to Talk", value: model.snapshot.pushToTalkAvailable ? "Ready" : "Unavailable")
                    LabeledContent("Background wake", value: model.snapshot.wakeAvailable ? "Enabled" : "No push key installed")
                    LabeledContent("Can be woken", value: model.snapshot.hasPushToken ? "Yes (token shared with contacts)" : "No Push to Talk token yet")
                    LabeledContent("Contacts you can wake", value: {
                        let contacts = model.snapshot.contacts
                        return "\(contacts.filter(\.isWakeable).count) of \(contacts.count)"
                    }())
                    LabeledContent("Last wake sent", value: model.snapshot.lastWakeSent ?? "None yet")
                    LabeledContent("Last wake received", value: model.snapshot.lastWakeReceived.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? "None yet")
                    LabeledContent("Voice message alerts", value: model.snapshot.relayAlerts)
                    LabeledContent("Notifications", value: notificationStatus)
                    LabeledContent("Last iCloud alert", value: model.snapshot.lastRelayAlert.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? "None yet")
                    ForEach(model.snapshot.candidates, id: \.self) { candidate in
                        Text(candidate.description).font(.caption.monospaced())
                    }
                }
                .nxRows()

                Section {
                    ShareLink(item: ShareAppView.link,
                              subject: Text("NXTPTT"),
                              message: Text("Get NXTPTT on TestFlight so we can talk:")) {
                        Label("Share NXTPTT", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink {
                        ShareAppView()
                    } label: {
                        Label("Show download QR code", systemImage: "qrcode")
                    }
                } header: {
                    Text("Invite someone")
                } footer: {
                    Text("Sends the TestFlight link so they can install NXTPTT.")
                }
                .nxRows()
            }
            .nxForm()
            .clearsTabBar()
            .toggleStyle(NeonToggleStyle())
            .navigationTitle("Settings")
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    notificationStatus = settings.soundSetting == .enabled ? "Allowed" : "Allowed, sound off"
                case .denied: notificationStatus = "Off (turn on in iOS Settings)"
                default: notificationStatus = "Not asked yet"
                }
            }
            .onDisappear { if name != settings.displayName { saveName() } }
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

    /// Saves the name when editing ends (Return, or tapping elsewhere). Empty names are ignored.
    private func saveName() {
        if !model.setDisplayName(name) { name = settings.displayName }
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
                Text("Anyone holding this key can send push notifications to NXTPTT users whose push tokens they know. It cannot decrypt or fake audio. Only share it with people you trust, and revoke it in the Apple developer portal if it leaks.")
            }
            .nxRows()

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
                .nxRows()
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
                Text("Paste the contents of the AuthKey_XXXXXXXXXX.p8 file, or scan a friend's push key QR code with Contacts → + → Join a group.")
                    .textSelection(.enabled)
            }
            .nxRows()
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .nxForm()
        .clearsTabBar()
        .navigationTitle("Push key")
        .onAppear { shareURI = model.engine.pushKeyURI() }
    }
}

/// The TestFlight link as a big QR code, for someone standing next to you.
struct ShareAppView: View {
    static let link = URL(string: "https://testflight.apple.com/join/Uz9Gks2E")!

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.9, energy: 0.7, moving: false)
            VStack(spacing: 18) {
                Text("Scan with the Camera app to get NXTPTT")
                    .font(NX.label(16, .semibold))
                    .foregroundStyle(NX.text)
                    .multilineTextAlignment(.center)
                if let image = QRCode.image(for: ShareAppView.link.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: 300)
                        .accessibilityLabel("QR code for the NXTPTT TestFlight link")
                }
                Text(ShareAppView.link.absoluteString)
                    .font(NX.body(13))
                    .foregroundStyle(NX.textDim)
                    .textSelection(.enabled)
                ShareLink(item: ShareAppView.link, subject: Text("NXTPTT"),
                          message: Text("Get NXTPTT on TestFlight so we can talk:")) {
                    Text("SHARE LINK")
                }
                .buttonStyle(NXButtonStyle(kind: .gel))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
        }
        .clearsTabBar()
        .navigationTitle("Get NXTPTT")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
