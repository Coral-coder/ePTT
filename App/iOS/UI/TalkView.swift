import SwiftUI
import EPTTCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.tab {
            case .talk: TalkView()
            case .channels: ChannelsView()
            case .pair: PairView()
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NeonTabBar(selection: $model.tab)
        }
        .overlay(alignment: .top) { BannerView() }
        .fullScreenCover(isPresented: Binding(get: { model.needsOnboarding }, set: { _ in })) {
            OnboardingView()
        }
        .preferredColorScheme(.dark)
        .tint(NX.cyan)
    }
}

/// Transient status messages ("Channel busy", call alerts, …) on a glass capsule.
struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let text = model.banner {
            Text(text)
                .font(NX.label(14, .semibold))
                .foregroundStyle(NX.text)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glass(cornerRadius: 22, glow: 0.35, strong: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { model.banner = nil } }
                .task(id: text) {
                    // Long messages (delivery failures) stay up long enough to read.
                    let seconds = max(2.5, min(8, Double(text.count) / 15))
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    withAnimation { model.banner = nil }
                }
        }
    }
}

struct TalkView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pressed = false
    @State private var txStart: Date?
    @State private var rxStart: Date?

    private var talk: EngineSnapshot.Talk { model.snapshot.talk }

    private var orbMode: TalkOrb.Mode {
        switch talk {
        case .transmitting: return .transmitting
        case .receiving: return .receiving
        case .idle: return model.selectedChannel == nil ? .disabled : .idle
        }
    }

    private var energy: Double {
        switch talk {
        case .idle: return 1
        case .receiving: return 1.3
        case .transmitting: return 1.8
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                GridBackground(horizon: 0.64, energy: energy)
                VStack(spacing: 16) {
                    header
                    ChannelCapsule()
                    status
                    Spacer(minLength: 0)
                    orb(diameter: max(150, min(300, geo.size.width - 60, geo.size.height * (model.selectedChannel?.kind == .group ? 0.34 : 0.44))))
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: talk) { newValue in
            switch newValue {
            case .transmitting:
                if txStart == nil { txStart = Date() }
                rxStart = nil
            case .receiving:
                if rxStart == nil { rxStart = Date() }
                txStart = nil
            case .idle:
                txStart = nil
                rxStart = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("NXTPTT")
                .font(NX.display(22))
                .tracking(7)
                .foregroundStyle(Color(hex: 0xEAFFFF))
                .neonGlow(NX.cyan, radius: 10)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                model.tab = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(NX.frost)
                    .frame(width: 44, height: 44)
                    .background(GlassBackground(shape: Circle(), glow: 0.25))
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch talk {
        case .idle:
            VStack(spacing: 10) {
                BreathingText(text: idleCaption)
                HStack(spacing: 8) {
                    RouteChip(title: "Nearby", symbol: "dot.radiowaves.left.and.right")
                    RouteChip(title: "Internet", symbol: "globe", lit: hasInternetPath)
                    RouteChip(title: relayReady ? "Relay ready" : "No relay", symbol: "icloud", lit: relayReady)
                }
                if let channel = model.selectedChannel, channel.kind == .group {
                    GroupHistory(channel: channel)
                }
            }
            .padding(.top, 6)
        case .transmitting:
            VStack(spacing: 6) {
                Text("TALK PERMIT")
                    .font(NX.label(13, .bold))
                    .tracking(5.5)
                    .foregroundStyle(Color(hex: 0xBFFCFF))
                    .neonGlow(NX.cyan, radius: 10)
                ElapsedText(since: txStart)
                    .font(NX.display(30, relativeTo: .largeTitle))
                    .foregroundStyle(.white)
                    .neonGlow(NX.cyan, radius: 14)
                ActivityBars(count: 18, maxHeight: 26)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transmitting")
        case .receiving(_, let talker):
            VStack(spacing: 12) {
                TalkerCard(talker: talker, route: model.snapshot.receivingRoute, since: rxStart)
                ActivityBars(count: 30, maxHeight: 32)
            }
        }
    }

    private var idleCaption: String {
        guard let channel = model.selectedChannel else { return "NO CHANNEL" }
        return model.connectionStatus(channel).uppercased()
    }

    private var relayReady: Bool {
        model.snapshot.relayAvailable && model.snapshot.settings.relayEnabled
    }

    /// True when we have an address the wider internet can reach (not only LAN addresses).
    private var hasInternetPath: Bool {
        model.snapshot.candidates.contains { candidate in
            switch candidate {
            case .ipv4(let bytes, _):
                let b = [UInt8](bytes)
                guard b.count == 4 else { return false }
                return !(b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168))
            case .ipv6(let bytes, _):
                return (bytes.first ?? 0) & 0xE0 == 0x20   // global unicast 2000::/3
            case .host:
                return true
            }
        }
    }

    // MARK: Orb

    private func orb(diameter: CGFloat) -> some View {
        TalkOrb(mode: orbMode, diameter: diameter, pressed: pressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed, model.selectedChannel != nil else { return }
                        pressed = true
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        model.engine.pressTalk()
                    }
                    .onEnded { _ in
                        guard pressed else { return }
                        pressed = false
                        model.engine.releaseTalk()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Push to talk")
            .accessibilityValue(orbMode == .transmitting ? "Transmitting" : orbMode == .receiving ? "Receiving" : "Ready")
            .accessibilityHint("Touch and hold to talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Start talking") { model.engine.pressTalk() }
            .accessibilityAction(named: "Stop talking") { model.engine.releaseTalk() }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch talk {
        case .transmitting:
            Text("Live on \(model.selectedChannel.map(model.displayName(of:)) ?? "the channel") · end-to-end encrypted")
                .font(NX.body(13))
                .foregroundStyle(Color(hex: 0xCFFBFF))
                .multilineTextAlignment(.center)
                .frame(minHeight: 50)
        case .receiving:
            Text("End-to-end encrypted · fresh key for this transmission")
                .font(NX.body(13))
                .foregroundStyle(NX.textMuted)
                .multilineTextAlignment(.center)
                .frame(minHeight: 50)
        case .idle:
            VStack(spacing: 10) {
                if let channel = model.selectedChannel, channel.kind == .direct, let peer = channel.members.first {
                    Button {
                        model.engine.sendCallAlert(to: peer)
                    } label: {
                        Label("CALL ALERT", systemImage: "bell")
                    }
                    .buttonStyle(NXButtonStyle(kind: .glass))
                    .frame(maxWidth: 220)
                } else {
                    Text("Hold the orb to key up")
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)
                        .frame(minHeight: 50)
                }
                ReplayChip()
            }
        }
    }
}

/// Replays the last message received; shown for an hour after it arrived.
struct ReplayChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let last = model.snapshot.lastMessage, last.expires > context.date {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    model.engine.replayLast()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text("REPLAY")
                            .font(NX.label(12, .bold))
                            .tracking(2)
                        Text("\(last.talker) · \(Self.length(last.seconds)) · \(Self.age(last.date, now: context.date))")
                            .font(NX.body(12))
                            .foregroundStyle(NX.textDim)
                            .lineLimit(1)
                    }
                    .foregroundStyle(NX.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(NX.frost.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay last message from \(last.talker)")
            }
        }
    }

    private static func length(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "just now" : "\(minutes) min ago"
    }
}

/// The selected channel as a glass capsule; tap to switch.
struct ChannelCapsule: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.snapshot.channels) { channel in
                Button {
                    model.engine.select(channel.id)
                } label: {
                    Label(model.displayName(of: channel), systemImage: channel.kind == .group ? "person.3" : "person")
                }
            }
        } label: {
            HStack(spacing: 12) {
                GelBead(size: 44) {
                    Image(systemName: model.selectedChannel?.kind == .direct ? "person.fill" : "person.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text((model.selectedChannel.map(model.displayName(of:)) ?? "Choose a channel").uppercased())
                        .font(NX.label(17, .bold))
                        .tracking(1)
                        .foregroundStyle(NX.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(NX.body(13))
                        .foregroundStyle(NX.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NX.frost)
            }
            .padding(.leading, 10)
            .padding(.trailing, 18)
            .frame(minHeight: 64)
            .glassCapsule(glow: 0.2, strong: true)
        }
        .disabled(model.snapshot.channels.isEmpty)
        .accessibilityLabel("Channel: \(model.selectedChannel.map(model.displayName(of:)) ?? "none")")
    }

    private var subtitle: String {
        guard let channel = model.selectedChannel else {
            return model.snapshot.channels.isEmpty ? "Pair with someone to get started" : "Tap to pick one"
        }
        let online = channel.members.filter { model.snapshot.onlinePeers.contains($0) }.count
        if channel.kind == .group {
            return "Talk group · \(online + 1) of \(channel.members.count + 1) on the grid"
        }
        return online > 0 ? "Private · on the grid" : "Private · wakes by push"
    }
}

/// Who is talking, how it reached us, and for how long.
struct TalkerCard: View {
    let talker: String
    let route: Route?
    let since: Date?

    var body: some View {
        HStack(spacing: 14) {
            InitialsRing(name: talker.components(separatedBy: " · ").first ?? talker, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(talker)
                    .font(NX.label(18, .bold))
                    .foregroundStyle(NX.text)
                    .lineLimit(1)
                if let route {
                    Label(route.label, systemImage: route.symbol)
                        .font(NX.body(13))
                        .foregroundStyle(NX.textDim)
                }
            }
            Spacer(minLength: 0)
            ElapsedText(since: since, short: true)
                .font(NX.display(14))
                .foregroundStyle(NX.frost)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glass(cornerRadius: 22, glow: 0.3, strong: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(talker) is talking")
    }
}

/// mm:ss since a date, ticking once a second.
struct ElapsedText: View {
    let since: Date?
    var short = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(since ?? timeline.date)))
            Text(short ? String(format: "%d:%02d", seconds / 60, seconds % 60)
                       : String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .monospacedDigit()
        }
    }
}

/// A caption that slowly pulses, like a light waiting for traffic.
struct BreathingText: View {
    let text: String
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(NX.label(13, .semibold))
            .tracking(5.5)
            .foregroundStyle(Color(hex: 0x8FF3FF))
            .opacity(reduceMotion ? 1 : (bright ? 1 : 0.55))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// The last few transmissions on a talk group, by who spoke, from the past hour.
struct GroupHistory: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel
    static let limit = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = entries(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                SectionCaption(text: "Recent")
                if items.isEmpty {
                    Text("Nobody has talked here in the last hour.")
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)
                } else {
                    ForEach(items) { record in
                        HStack(spacing: 10) {
                            Image(systemName: record.outgoing ? "arrow.up.right" : "arrow.down.left")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(record.outgoing ? NX.ice : NX.cyan)
                                .frame(width: 14)
                            Text(talker(of: record))
                                .font(NX.body(14, .medium))
                                .foregroundStyle(NX.text)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(max(1, Int(record.seconds.rounded())))s · \(age(record.date, now: context.date))")
                                .font(NX.body(12))
                                .foregroundStyle(NX.textDim)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(cornerRadius: 16, glow: 0.08)
        }
    }

    private func entries(now: Date) -> [TransferRecord] {
        let name = model.displayName(of: channel)
        let cutoff = now.addingTimeInterval(-PTTEngine.replayLifetime)
        return Array(model.snapshot.transfers
            .filter { $0.channel == name && $0.date > cutoff && $0.seconds > 0 }
            .sorted { $0.date > $1.date }
            .prefix(Self.limit))
    }

    private func talker(of record: TransferRecord) -> String {
        if record.outgoing { return model.snapshot.settings.displayName.isEmpty ? "You" : "\(model.snapshot.settings.displayName) (you)" }
        let peer = record.legs.first?.peer ?? "?"
        // Relayed entries may be labelled "Name · Group".
        return peer.components(separatedBy: " · ").first ?? peer
    }

    private func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "now" : "\(minutes)m ago"
    }
}
