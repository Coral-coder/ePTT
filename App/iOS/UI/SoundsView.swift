import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The Nextel sounds: preview them, pick the chirp pitch, or import your own recordings.
struct SoundsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing: Tone?
    @State private var customized: Set<Tone> = []
    @State private var player: AVAudioPlayer?
    @State private var error: String?

    private var settings: Settings { model.snapshot.settings }

    var body: some View {
        Form {
            Section {
                Picker("Chirp", selection: Binding(
                    get: { settings.deepChirp },
                    set: { value in model.engine.updateSettings { $0.deepChirp = value } }
                )) {
                    Text("Classic (1800 Hz)").tag(false)
                    Text("Deep (911 Hz)").tag(true)
                }
                Toggle("Roger beep", isOn: Binding(
                    get: { settings.rogerBeep },
                    set: { value in model.engine.updateSettings { $0.rogerBeep = value } }
                ))
            } footer: {
                Text("The chirp follows the iDEN spec: a tone played 24 ms on, 24 off, 24 on, 24 off, 48 on. You hear it when you get the channel and when a call comes in. Nextel had no beep at the end of a transmission, so the roger beep is off by default.")
            }

            Section {
                ForEach(Tone.allCases) { tone in
                    HStack {
                        Button {
                            preview(tone)
                        } label: {
                            Label(tone.displayName, systemImage: "play.circle")
                        }
                        Spacer()
                        if customized.contains(tone) {
                            Text("Custom").font(.caption).foregroundStyle(.secondary)
                            Button("Reset") {
                                SoundLibrary.reset(tone)
                                refresh()
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("Import") { importing = tone }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Have your own recordings of the original Nextel sounds? Import a short audio file (up to 5 seconds) to replace any of these.")
            }
        }
        .navigationTitle("Nextel sounds")
        .onAppear(perform: refresh)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.audio]) { result in
            guard let tone = importing else { return }
            importing = nil
            do {
                try SoundLibrary.importSound(from: try result.get(), for: tone)
                refresh()
                preview(tone)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .alert("Couldn't import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func refresh() {
        customized = Set(Tone.allCases.filter(SoundLibrary.hasCustom))
    }

    private func preview(_ tone: Tone) {
        // The synthesizer reads the pitch from here; mirror the setting for previews too.
        ToneSynth.chirpFrequency = settings.deepChirp ? ToneSynth.deepChirpHz : ToneSynth.classicChirpHz
        // Don't disturb a live talk session (always-listening or PushToTalk already set this up).
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        player = try? AVAudioPlayer(data: SoundLibrary.previewData(for: tone))
        player?.play()
    }
}
