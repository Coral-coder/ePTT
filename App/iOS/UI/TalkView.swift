import SwiftUI
import EPTTCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            TalkView()
                .tabItem { Label("Talk", systemImage: "antenna.radiowaves.left.and.right") }
            ChannelsView()
                .tabItem { Label("Channels", systemImage: "person.3") }
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.crop.circle") }
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .top) { BannerView() }
    }
}

/// Transient status messages ("Channel busy", call alerts, …).
struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let text = model.banner {
            Text(text)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { model.banner = nil }
                }
        }
    }
}

struct TalkView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                channelPicker
                StatusPanel()
                Spacer()
                TalkButton()
                Spacer()
                if let channel = model.selectedChannel, channel.kind == .direct, let peer = channel.members.first {
                    Button {
                        model.engine.sendCallAlert(to: peer)
                    } label: {
                        Label("Call alert", systemImage: "bell.badge")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("NXTPTT")
        }
    }

    private var channelPicker: some View {
        Menu {
            ForEach(model.snapshot.channels) { channel in
                Button {
                    model.engine.select(channel.id)
                } label: {
                    Label(model.displayName(of: channel),
                          systemImage: channel.kind == .group ? "person.3.fill" : "person.fill")
                }
            }
        } label: {
            HStack {
                Image(systemName: model.selectedChannel?.kind == .group ? "person.3.fill" : "person.fill")
                Text(model.selectedChannel.map(model.displayName(of:)) ?? "Choose a channel")
                    .font(.title3.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .disabled(model.snapshot.channels.isEmpty)
    }
}

struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            switch model.snapshot.talk {
            case .idle:
                Text(model.selectedChannel.map { model.isOnline($0) ? "Connected" : "Standing by" } ?? "No channel")
                    .foregroundStyle(.secondary)
            case .transmitting:
                Text("Talking…").foregroundStyle(.red)
            case .receiving(_, let talker):
                Label(talker, systemImage: "speaker.wave.2.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.headline)
        .frame(height: 30)
    }
}

/// The big hold-to-talk button.
struct TalkButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var pressed = false

    private var transmitting: Bool {
        if case .transmitting = model.snapshot.talk { return true }
        return false
    }

    private var receiving: Bool {
        if case .receiving = model.snapshot.talk { return true }
        return false
    }

    var body: some View {
        let color: Color = transmitting ? .red : (receiving ? .green : .orange)
        Circle()
            .fill(color.gradient)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: transmitting ? "mic.fill" : "mic")
                        .font(.system(size: 54, weight: .bold))
                    Text(transmitting ? "RELEASE TO LISTEN" : "HOLD TO TALK")
                        .font(.caption.weight(.heavy))
                }
                .foregroundStyle(.white)
            )
            .frame(width: 230, height: 230)
            .scaleEffect(pressed ? 0.94 : 1)
            .shadow(color: color.opacity(0.4), radius: pressed ? 4 : 14)
            .animation(.spring(response: 0.2), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        model.engine.pressTalk()
                    }
                    .onEnded { _ in
                        pressed = false
                        model.engine.releaseTalk()
                    }
            )
            .disabled(model.selectedChannel == nil)
            .accessibilityLabel("Push to talk")
            .accessibilityAddTraits(.isButton)
    }
}
