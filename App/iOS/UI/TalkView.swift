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
        .alert(model.linkPrompt?.title ?? "", isPresented: Binding(
            get: { model.linkPrompt != nil },
            set: { if !$0 { model.linkPrompt = nil } }
        ), presenting: model.linkPrompt) { prompt in
            Button(prompt.confirm) {
                model.linkPrompt = nil
                model.open(link: prompt.link)
            }
            Button("Cancel", role: .cancel) { model.linkPrompt = nil }
        } message: { prompt in
            Text(prompt.message)
        }
        .sheet(item: Binding(get: { model.snapshot.joinRequests.first }, set: { _ in })) { request in
            JoinRequestView(request: request)
        }
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
                // On Talk, sit below the header and channel capsule so the person we're talking
                // to stays visible.
                .padding(.top, model.tab == .talk ? 140 : 8)
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

/// Someone scanned one of our group codes: let them in or not.
struct JoinRequestView: View {
    @EnvironmentObject private var model: AppModel
    let request: JoinRequest

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.9, energy: 0.7, moving: false)
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                InitialsRing(name: request.name, size: 84, lit: true)
                Text("Wants to join \(request.group)")
                    .font(NX.label(14, .semibold))
                    .foregroundStyle(NX.textDim)
                    .multilineTextAlignment(.center)
                Text(request.name)
                    .font(NX.display(26))
                    .foregroundStyle(NX.text)
                    .multilineTextAlignment(.center)
                Text("\(request.name) scanned your code for \(request.group). Letting them in adds them to the group and to your contacts, and everyone in the group gets their details.")
                    .font(NX.body(15))
                    .foregroundStyle(NX.textDim)
                    .multilineTextAlignment(.center)
                if !request.members.isEmpty {
                    Text("Already in: " + request.members.map { $0.isEmpty ? "Unnamed" : $0 }.joined(separator: ", "))
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                Button("LET THEM IN") { model.engine.answerJoinRequest(request.id, allow: true) }
                    .buttonStyle(NXButtonStyle(kind: .gel))
                Button("DON'T LET IN") { model.engine.answerJoinRequest(request.id, allow: false) }
                    .buttonStyle(NXButtonStyle(kind: .glass))
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

struct TalkView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pressed = false
    /// This press is a reply (Pinned layout's reply window).
    @State private var replying = false
    @State private var txStart: Date?
    @State private var rxStart: Date?

    private var talk: EngineSnapshot.Talk { model.snapshot.talk }

    private var layout: TalkLayout { model.snapshot.settings.talkLayout }

    /// Where the orb sends: in the Pinned layout, whoever just talked to us (for a few seconds);
    /// otherwise the selected channel.
    private var orbTarget: ChannelID? {
        layout == .pinned ? model.replyTarget?.channel : nil
    }

    private var orbMode: TalkOrb.Mode {
        switch talk {
        case .transmitting: return .transmitting
        case .receiving: return .receiving
        case .idle: return model.selectedChannel == nil && orbTarget == nil ? .disabled : .idle
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
                    switch layout {
                    case .classic: classicLayout(geo)
                    case .strip: stripLayout(geo)
                    case .log: logLayout(geo)
                    case .board: boardLayout(geo)
                    case .pinned: pinnedLayout(geo)
                    }
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

    // MARK: Layouts

    @ViewBuilder
    private func classicLayout(_ geo: GeometryProxy) -> some View {
        ChannelCapsule()
        WatchHandoffBar()
        QuietBar()
        status
        Spacer(minLength: 0)
        orb(diameter: max(150, min(300, geo.size.width - 60, geo.size.height * (model.selectedChannel?.kind == .group ? 0.34 : 0.44))))
        Spacer(minLength: 0)
        footer
        replayRow
    }

    @ViewBuilder
    private func stripLayout(_ geo: GeometryProxy) -> some View {
        ChannelCapsule()
        RecentStrip()
        WatchHandoffBar()
        QuietBar()
        status
        Spacer(minLength: 0)
        orb(diameter: max(140, min(280, geo.size.width - 60, geo.size.height * (model.selectedChannel?.kind == .group ? 0.3 : 0.38))))
        Spacer(minLength: 0)
        footer
        replayRow
    }

    @ViewBuilder
    private func logLayout(_ geo: GeometryProxy) -> some View {
        WatchHandoffBar()
        QuietBar()
        RadioLog()
            .frame(maxHeight: geo.size.height * 0.46)
        Spacer(minLength: 0)
        orb(diameter: max(130, min(220, geo.size.height * 0.28)))
        targetCaption
        Spacer(minLength: 0)
        replayRow
    }

    @ViewBuilder
    private func boardLayout(_ geo: GeometryProxy) -> some View {
        WatchHandoffBar()
        QuietBar()
        TalkBoard(rows: max(2, Int((geo.size.height - 240) / 122)))
        Spacer(minLength: 0)
        replayRow
    }

    @ViewBuilder
    private func pinnedLayout(_ geo: GeometryProxy) -> some View {
        PinnedRow()
        WatchHandoffBar()
        QuietBar()
        if case .receiving = talk {
            status
        } else if talk == .idle, let reply = model.replyTarget {
            ReplyCard(target: reply)
        }
        Spacer(minLength: 0)
        orb(diameter: max(130, min(260, geo.size.width - 80, geo.size.height * 0.32)))
        targetCaption
        Spacer(minLength: 0)
        EveryoneElseLine()
        replayRow
    }

    private var replayRow: some View {
        HStack(alignment: .center) {
            AllowReplayToggle()
            Spacer()
            ReplayButton(enabled: talk == .idle)
        }
    }

    /// "→ Sam": who the orb talks to, in layouts without the channel capsule.
    private var targetCaption: some View {
        let id = orbTarget ?? model.snapshot.settings.selectedChannel
        let channel = id.flatMap { id in model.snapshot.channels.first { $0.id == id } }
        let text: String
        switch talk {
        case .transmitting: text = "Talking to " + (channel.map(model.displayName(of:)) ?? "the channel")
        case .receiving(_, let talker): text = "Hearing " + talker
        case .idle: text = channel.map { (orbTarget != nil ? "Hold to reply to " : "Hold to talk to ") + model.displayName(of: $0) }
            ?? "Pick a channel above"
        }
        return Text(text)
            .font(NX.label(14, .semibold))
            .foregroundStyle(NX.textDim)
            .lineLimit(1)
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
            DoNotDisturbButton()
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
                ActivityBars(count: 18, maxHeight: 26, live: model.snapshot.settings.liveWaveform)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transmitting")
        case .receiving(_, let talker):
            VStack(spacing: 12) {
                TalkerCard(talker: talker, route: model.snapshot.receivingRoute, since: rxStart)
                ActivityBars(count: 30, maxHeight: 32, live: model.snapshot.settings.liveWaveform)
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
        TalkOrb(mode: orbMode, diameter: diameter, pressed: pressed,
                quantumSafe: (orbTarget.flatMap { id in model.snapshot.channels.first { $0.id == id } } ?? model.selectedChannel)
                    .map(model.isQuantumSafe) ?? false)
            .contentShape(Circle())
            .modifier(HoldToTalk(onPress: {
                guard model.selectedChannel != nil || orbTarget != nil else { return }
                pressed = true
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                replying = orbTarget != nil
                if replying { model.holdReplyWindow() }
                model.engine.pressTalk(on: orbTarget)
            }, onRelease: { _ in
                guard pressed else { return }
                pressed = false
                model.engine.releaseTalk()
                // Only a reply keeps the reply window open a little longer.
                if replying { model.releaseReplyWindow() }
                replying = false
            }))
            .accessibilityElement()
            .accessibilityLabel("Push to talk")
            .accessibilityValue(orbMode == .transmitting ? "Transmitting" : orbMode == .receiving ? "Receiving" : "Ready")
            .accessibilityHint("Touch and hold to talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Start talking") { model.engine.pressTalk(on: orbTarget) }
            .accessibilityAction(named: "Stop talking") { model.engine.releaseTalk() }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch talk {
        case .transmitting:
            Text("Live on \(model.selectedChannel.map(model.displayName(of:)) ?? "the channel") · end-to-end encrypted"
                 + (model.snapshot.settings.allowReplay ? " · replay allowed" : ""))
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
            }
        }
    }
}

/// Whether what you send next may be replayed by the people who receive it. Each message
/// carries the setting it was sent with.
struct AllowReplayToggle: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let on = model.snapshot.settings.allowReplay
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            model.engine.updateSettings { $0.allowReplay = !on }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text(on ? "REPLAY OK" : "NO REPLAY")
                    .font(NX.label(11, .bold))
                    .tracking(1.5)
            }
            .foregroundStyle(on ? NX.ink : NX.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(on ? AnyShapeStyle(NX.cyan) : AnyShapeStyle(.ultraThinMaterial)))
            .overlay(Capsule().strokeBorder(NX.frost.opacity(on ? 0.8 : 0.35), lineWidth: 1))
            .shadow(color: on ? NX.cyan.opacity(0.6) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Let recipients replay my messages")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Replays the last message received. Greyed out unless that message's talker allowed replay
/// and it is under an hour old.
struct ReplayButton: View {
    @EnvironmentObject private var model: AppModel
    /// False while talking or receiving.
    var enabled = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let last = model.snapshot.replayable.flatMap { $0.expires > context.date ? $0 : nil }
            let active = enabled && last != nil
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                model.engine.replayLast()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(active ? NX.frost : NX.textMuted.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .background(GlassBackground(shape: Circle(), glow: active ? 0.35 : 0))
                    .overlay(Circle().strokeBorder(active ? NX.cyan.opacity(0.7) : .white.opacity(0.08), lineWidth: 1))
                    .shadow(color: active ? NX.cyan.opacity(0.5) : .clear, radius: 6)
                    .opacity(active ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!active)
            .accessibilityLabel("Replay last message")
            .accessibilityValue(last.map { "From \($0.talker), \(max(1, Int($0.seconds.rounded()))) seconds" } ?? "Not available")
        }
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
            let quiet = channel.members.filter { model.snapshot.peerQuiet[$0] == false }.count
            return "Talk group · \(online + 1) of \(channel.members.count + 1) on the grid"
                + (quiet > 0 ? " · \(quiet) on Do Not Disturb" : "")
        }
        if let peer = channel.members.first, let breaksThrough = model.snapshot.peerQuiet[peer] {
            return breaksThrough ? "Do Not Disturb · you break through" : "Do Not Disturb · your messages are held"
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
        let cutoff = now.addingTimeInterval(-3600)
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

// MARK: - Do Not Disturb

/// The moon in the header: Do Not Disturb for a while, or until turned off.
struct DoNotDisturbButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosingTime = false

    private var on: Bool { model.snapshot.settings.quietUntil.map { $0 > Date() } ?? false }

    var body: some View {
        Menu {
            if on {
                Button { model.engine.setDoNotDisturb(until: nil) } label: { Label("Turn off", systemImage: "moon.zzz") }
            }
            Button { model.engine.setDoNotDisturb(until: .distantFuture) } label: { Label("Until I turn it off", systemImage: "moon") }
            Button { model.engine.setDoNotDisturb(until: Date().addingTimeInterval(3600)) } label: { Label("For 1 hour", systemImage: "clock") }
            Button { model.engine.setDoNotDisturb(until: Self.nextMorning()) } label: { Label("Until 8 AM", systemImage: "sunrise") }
            Button { choosingTime = true } label: { Label("Until a time…", systemImage: "clock.badge") }
        } label: {
            Image(systemName: on ? "moon.fill" : "moon")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(on ? NX.ink : NX.frost)
                .frame(width: 44, height: 44)
                .background {
                    if on {
                        Circle().fill(NX.frost).shadow(color: NX.cyan.opacity(0.7), radius: 8)
                    } else {
                        GlassBackground(shape: Circle(), glow: 0.25)
                    }
                }
        }
        .accessibilityLabel("Do Not Disturb")
        .accessibilityValue(on ? "On" : "Off")
        .sheet(isPresented: $choosingTime) { QuietUntilPicker() }
    }

    static func nextMorning(from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today8 = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        return today8 > now ? today8 : calendar.date(byAdding: .day, value: 1, to: today8) ?? today8
    }
}

/// Pick when Do Not Disturb ends.
private struct QuietUntilPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date().addingTimeInterval(2 * 3600)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker("Until", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                Text("Messages are kept on this phone, not played, until then. Then they play one after another. Priority contacts still come through.")
                    .font(NX.body(14))
                    .foregroundStyle(NX.textDim)
                    .multilineTextAlignment(.center)
                Button("SET") {
                    model.engine.setDoNotDisturb(until: time)
                    dismiss()
                }
                .buttonStyle(NXButtonStyle(kind: .gel))
                Spacer()
            }
            .padding(22)
            .background(GridBackground(horizon: 0.96, energy: 0.6, moving: false))
            .navigationTitle("Do Not Disturb until")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

/// The Apple Watch has taken over (its app was opened); this phone is standing by.
struct WatchHandoffBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.snapshot.usingWatch {
            HStack(spacing: 10) {
                Image(systemName: "applewatch").foregroundStyle(NX.frost)
                VStack(alignment: .leading, spacing: 1) {
                    Text("USING APPLE WATCH").font(NX.label(12, .bold)).tracking(1.5).foregroundStyle(NX.text)
                    Text("Messages go to your watch").font(NX.body(12)).foregroundStyle(NX.textDim)
                }
                Spacer(minLength: 0)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    model.engine.takeOverFromWatch()
                } label: {
                    Text("USE IPHONE").font(NX.label(12, .bold)).tracking(1.2)
                        .foregroundStyle(NX.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(NX.frost))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glass(cornerRadius: 18, glow: 0.12)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Under the channel: Do Not Disturb status, and held messages ready to play.
struct QuietBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let until = model.snapshot.settings.quietUntil.flatMap { $0 > context.date ? $0 : nil }
            let held = model.snapshot.held
            if until != nil || !held.isEmpty {
                HStack(spacing: 10) {
                    if let until {
                        Image(systemName: "moon.fill").foregroundStyle(NX.frost)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("DO NOT DISTURB").font(NX.label(12, .bold)).tracking(1.5).foregroundStyle(NX.text)
                            Text(Self.untilText(until, now: context.date)).font(NX.body(12)).foregroundStyle(NX.textDim)
                        }
                    }
                    Spacer(minLength: 0)
                    if !held.isEmpty {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.engine.playHeld()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: model.snapshot.playingHeld ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("\(held.count) HELD").font(NX.label(12, .bold)).tracking(1.2)
                            }
                            .foregroundStyle(NX.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(NX.frost))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.snapshot.playingHeld)
                        .contextMenu {
                            Button(role: .destructive) { model.engine.discardHeld() } label: {
                                Label("Delete held messages", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("Play \(held.count) held messages")
                    }
                    if until != nil {
                        Button("Turn off") { model.engine.setDoNotDisturb(until: nil) }
                            .font(NX.body(13, .semibold))
                            .foregroundStyle(NX.frost)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(cornerRadius: 16, glow: 0.12)
            }
        }
    }

    static func untilText(_ until: Date, now: Date) -> String {
        if until == .distantFuture { return "Until you turn it off · messages are held" }
        let time = until.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDate(until, inSameDayAs: now) ? "" : " tomorrow"
        return "Until \(time)\(day) · messages are held"
    }
}
