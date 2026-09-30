import SwiftUI
import EPTTCore

// The Talk screen's layouts for busy radio (Settings › Talk screen): a recent strip, a radio
// log, a talk board and pinned channels with a reply window.

// MARK: - Shared pieces

/// A small amber dot: messages held for this channel by Do Not Disturb.
struct MissedDot: View {
    var body: some View {
        Circle()
            .fill(Color(hex: 0xFFC24A))
            .frame(width: 9, height: 9)
            .shadow(color: Color(hex: 0xFFC24A), radius: 4)
            .accessibilityLabel("Missed messages")
    }
}

/// "LIVE" on a cyan pill.
struct LivePill: View {
    var body: some View {
        Text("LIVE")
            .font(NX.label(10.5, .bold))
            .tracking(1.5)
            .foregroundStyle(NX.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(NX.ice))
            .shadow(color: NX.cyan, radius: 5)
    }
}

/// Pin or unpin a channel for the Pinned layout.
struct PinMenuItem: View {
    @EnvironmentObject private var model: AppModel
    let channel: ChannelID

    var body: some View {
        Button {
            model.togglePin(channel)
        } label: {
            if model.isPinned(channel) {
                Label("Unpin from Talk", systemImage: "pin.slash")
            } else {
                Label("Pin to Talk", systemImage: "pin")
            }
        }
    }
}

// MARK: - A · Recent strip

/// Recent channels, people and teams mixed, newest first. Tap to switch.
struct RecentStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.recent.filter { $0.last != nil || $0.live != nil }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENT · TAP TO SWITCH")
                    .font(NX.label(11, .bold))
                    .tracking(2)
                    .foregroundStyle(NX.textMuted)
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(items.prefix(12)) { item in
                                chip(item, now: context.date)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func chip(_ item: RecentChannel, now: Date) -> some View {
        let selected = model.snapshot.settings.selectedChannel == item.channel.id
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            model.engine.select(item.channel.id)
        } label: {
            HStack(spacing: 8) {
                InitialsRing(name: item.name, size: 32, lit: item.live != nil || selected)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .font(NX.label(14, .bold))
                            .foregroundStyle(NX.text)
                            .lineLimit(1)
                        if item.missed > 0 { MissedDot() }
                    }
                    Text(item.live != nil ? "live" : item.last.map { RecentChannel.age($0.date, now: now) } ?? "")
                        .font(NX.body(12))
                        .foregroundStyle(item.live != nil ? NX.ice : NX.textMuted)
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .glassCapsule(glow: item.live != nil || selected ? 0.4 : 0.1, strong: item.live != nil || selected)
            .overlay(Capsule().strokeBorder(item.live != nil || selected ? NX.ice.opacity(0.85) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu { PinMenuItem(channel: item.channel.id) }
        .accessibilityLabel("\(item.name), \(item.detail(now: now))")
        .accessibilityHint("Switches to this channel")
    }
}

// MARK: - B · Radio log

/// Every key-up across every channel, newest first. Tap one to aim the talk button at it.
struct RadioLog: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", people = "People", teams = "Teams", missed = "Missed"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f == .missed && missedCount > 0 ? "Missed · \(missedCount)" : f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)

            TimelineView(.periodic(from: .now, by: 5)) { context in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let live = liveRow {
                            live
                        }
                        let rows = records
                        if rows.isEmpty && liveRow == nil {
                            Text(filter == .missed ? "Nothing missed." : "Nothing yet. Key-ups show up here as they happen.")
                                .font(NX.body(14))
                                .foregroundStyle(NX.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        ForEach(rows) { record in
                            row(record, now: context.date)
                        }
                    }
                }
                .glass(cornerRadius: 22, glow: 0.1)
            }
        }
    }

    private func isMissed(_ r: TransferRecord) -> Bool {
        !r.outgoing && r.legs.contains { $0.reason?.contains("Do Not Disturb") ?? false }
    }

    private var missedCount: Int { model.snapshot.held.count }

    private var records: [TransferRecord] {
        model.keyUps.prefix(40).filter { r in
            switch filter {
            case .all: return true
            case .people: return model.channel(for: r)?.kind == .direct
            case .teams: return model.channel(for: r)?.kind == .group
            case .missed: return isMissed(r)
            }
        }
    }

    /// Whoever is talking right now, on top.
    private var liveRow: AnyView? {
        let talk = model.snapshot.talk
        let id: ChannelID
        let who: String
        switch talk {
        case .receiving(let c, let talker):
            id = c
            who = talker.components(separatedBy: " · ").first ?? talker
        case .transmitting(let c):
            id = c
            who = "You"
        case .idle:
            return nil
        }
        guard let channel = model.snapshot.channels.first(where: { $0.id == id }) else { return nil }
        if filter == .missed || (filter == .people && channel.kind != .direct) || (filter == .teams && channel.kind != .group) {
            return nil
        }
        return AnyView(
            HStack(spacing: 10) {
                InitialsRing(name: who, size: 36, lit: true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(who).font(NX.label(15, .bold)).foregroundStyle(NX.text)
                        tag(for: channel)
                    }
                    Text("now").font(NX.body(12.5)).foregroundStyle(NX.textDim)
                }
                Spacer(minLength: 0)
                LivePill()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(NX.cyan.opacity(0.1))
        )
    }

    private func tag(for channel: Channel?) -> some View {
        let group = channel?.kind == .group
        return Text(group ? (channel.map(model.displayName(of:)) ?? "").uppercased() : "PRIVATE")
            .font(NX.label(10, .bold))
            .tracking(1)
            .foregroundStyle(NX.frost)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(group ? NX.cyan.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NX.frost.opacity(0.35), lineWidth: 1))
    }

    private func row(_ r: TransferRecord, now: Date) -> some View {
        let channel = model.channel(for: r)
        let who = r.outgoing ? "You" : (r.legs.first?.peer ?? "?")
        let missed = isMissed(r)
        let selected = channel != nil && channel?.id == model.snapshot.settings.selectedChannel
        let length = max(1, Int(r.seconds.rounded()))
        var detail = RecentChannel.age(r.date, now: now) + " · " + String(format: "%d:%02d", length / 60, length % 60)
        if missed {
            detail += " · missed"
        } else if r.outgoing {
            let got = r.legs.filter { $0.route != .failed }.count
            detail += got == r.legs.count ? " · delivered" : " · \(got) of \(r.legs.count) delivered"
        }
        return HStack(spacing: 10) {
            InitialsRing(name: who, size: 36, lit: false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(who).font(NX.label(15, .bold)).foregroundStyle(NX.text).lineLimit(1)
                    tag(for: channel)
                    if missed, !model.snapshot.held.isEmpty { MissedDot() }
                }
                Text(detail).font(NX.body(12.5)).foregroundStyle(NX.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            if missed, !model.snapshot.held.isEmpty {
                roundButton("play.fill", label: "Play missed messages") { model.engine.playHeld() }
            } else if !r.outgoing, let last = model.snapshot.replayable, abs(last.date.timeIntervalSince(r.date)) < 3,
                      last.expires > now {
                roundButton("play.fill", label: "Replay") { model.engine.replayLast() }
            }
            if let channel {
                roundButton("arrowshape.turn.up.left.fill", label: "Talk back on \(model.displayName(of: channel))",
                            lit: selected) {
                    model.engine.select(channel.id)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? NX.cyan.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(NX.frost.opacity(0.08)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if let channel { model.engine.select(channel.id) } }
        .contextMenu { if let channel { PinMenuItem(channel: channel.id) } }
    }

    private func roundButton(_ symbol: String, label: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(lit ? NX.ice : NX.frost)
                .frame(width: 34, height: 34)
                .background(GlassBackground(shape: Circle(), glow: lit ? 0.35 : 0.15))
                .overlay(Circle().strokeBorder(lit ? NX.ice.opacity(0.9) : NX.frost.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - C · Talk board

/// Every channel as its own hold-to-talk tile, by recent activity. Tap to select, hold to talk.
struct TalkBoard: View {
    @EnvironmentObject private var model: AppModel
    /// How many rows of tiles fit.
    let rows: Int

    var body: some View {
        let all = model.recent
        let shown = Array(all.prefix(rows * 2))
        VStack(alignment: .leading, spacing: 10) {
            Text("Hold a tile to talk · tap to select")
                .font(NX.body(13))
                .foregroundStyle(NX.textDim)
            if all.isEmpty {
                Text("No channels yet. Pair with someone or make a talk group.")
                    .font(NX.body(14))
                    .foregroundStyle(NX.textMuted)
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(shown) { item in
                        BoardTile(item: item, now: context.date)
                    }
                }
            }
            if all.count > shown.count {
                Button {
                    model.tab = .channels
                } label: {
                    Text("\(all.count - shown.count) more in Channels ›")
                        .font(NX.label(13, .semibold))
                        .foregroundStyle(NX.ice)
                }
                .buttonStyle(.plain)
            }
            if model.snapshot.talk == .idle, let reply = model.replyTarget,
               !shown.contains(where: { $0.channel.id == reply.channel }) {
                ReplyCard(target: reply, compact: true)
            }
        }
    }
}

/// One channel on the talk board: hold to talk on it, tap to make it the selected channel.
struct BoardTile: View {
    @EnvironmentObject private var model: AppModel
    let item: RecentChannel
    let now: Date
    @State private var talking = false
    @State private var holdTask: Task<Void, Never>?

    private var selected: Bool { model.snapshot.settings.selectedChannel == item.channel.id }
    private var lit: Bool { item.live != nil || talking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                InitialsRing(name: item.name, size: 38, lit: lit || selected)
                Spacer(minLength: 0)
                if item.live != nil {
                    LivePill()
                } else if item.missed > 0 {
                    MissedDot()
                } else if let last = item.last {
                    Text(RecentChannel.age(last.date, now: now))
                        .font(NX.body(12))
                        .foregroundStyle(NX.textMuted)
                }
            }
            Spacer(minLength: 6)
            Text(item.name)
                .font(NX.label(16, .bold))
                .foregroundStyle(NX.text)
                .lineLimit(1)
            Text(talking ? "Talking…" : item.detail(now: now))
                .font(NX.body(12.5))
                .foregroundStyle(lit ? NX.ice : NX.textDim)
                .lineLimit(1)
        }
        .padding(12)
        .frame(height: 112)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 22, glow: lit ? 0.5 : selected ? 0.3 : 0.1, strong: lit || selected)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(lit ? NX.ice.opacity(0.95) : selected ? NX.ice.opacity(0.5) : .clear, lineWidth: lit ? 1.5 : 1))
        .scaleEffect(talking ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: talking)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdTask == nil, !talking else { return }
                    // A short hold keys up; a quick tap only selects.
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        guard !Task.isCancelled else { return }
                        talking = true
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        model.engine.pressTalk(on: item.channel.id)
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    holdTask = nil
                    if talking {
                        talking = false
                        model.engine.releaseTalk()
                    } else {
                        UISelectionFeedbackGenerator().selectionChanged()
                        model.engine.select(item.channel.id)
                    }
                }
        )
        .contextMenu { PinMenuItem(channel: item.channel.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.detail(now: now))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Start talking") { model.engine.pressTalk(on: item.channel.id) }
        .accessibilityAction(named: "Stop talking") { model.engine.releaseTalk() }
        .accessibilityAction(named: "Select") { model.engine.select(item.channel.id) }
    }
}

// MARK: - D · Pinned + reply window

/// Up to three pinned channels (the most recent fill in until you pin some). Tap to select.
struct PinnedRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.pinned
        VStack(alignment: .leading, spacing: 8) {
            Text(model.snapshot.settings.pinnedChannels.isEmpty ? "PINNED · HOLD ONE TO PIN IT" : "PINNED")
                .font(NX.label(11, .bold))
                .tracking(2)
                .foregroundStyle(NX.textMuted)
            if items.isEmpty {
                Text("No channels yet. Pair with someone or make a talk group.")
                    .font(NX.body(14))
                    .foregroundStyle(NX.textMuted)
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        card(item, now: context.date)
                    }
                }
            }
        }
    }

    private func card(_ item: RecentChannel, now: Date) -> some View {
        let selected = model.snapshot.settings.selectedChannel == item.channel.id
        let lit = item.live != nil
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            model.engine.select(item.channel.id)
        } label: {
            VStack(spacing: 5) {
                InitialsRing(name: item.name, size: 40, lit: lit || selected)
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(NX.label(14, .bold))
                        .foregroundStyle(NX.text)
                        .lineLimit(1)
                    if item.missed > 0 { MissedDot() }
                }
                Text(lit ? "live" : item.last.map { RecentChannel.age($0.date, now: now) } ?? " ")
                    .font(NX.body(12))
                    .foregroundStyle(lit ? NX.ice : NX.textMuted)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .glass(cornerRadius: 18, glow: lit || selected ? 0.4 : 0.1, strong: lit || selected)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(lit || selected ? NX.ice.opacity(0.85) : .clear, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if model.isPinned(item.channel.id) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NX.textMuted)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { PinMenuItem(channel: item.channel.id) }
        .accessibilityLabel("\(item.name), \(item.detail(now: now))")
    }
}

/// "Sam just talked to you": the talk button answers them for a few seconds. In the compact
/// form (Talk board) the card itself is the hold-to-reply button.
struct ReplyCard: View {
    @EnvironmentObject private var model: AppModel
    let target: ReplyTarget
    var compact = false
    @State private var talking = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, target.until.timeIntervalSince(context.date))
            let fraction = target.until == .distantFuture ? 1 : left / AppModel.replySeconds
            HStack(spacing: 12) {
                InitialsRing(name: target.talker, size: compact ? 34 : 40, lit: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(compact ? (talking ? "Replying to \(target.talker)…" : "Hold here to reply to \(target.talker)")
                                 : "\(target.talker) just talked to you")
                        .font(NX.label(compact ? 14 : 15, .bold))
                        .foregroundStyle(NX.text)
                        .lineLimit(1)
                    if !compact {
                        Text("Hold the orb to reply · then back to \(model.selectedChannel.map(model.displayName(of:)) ?? "your channel")")
                            .font(NX.body(12.5))
                            .foregroundStyle(NX.textDim)
                            .lineLimit(1)
                    }
                    GeometryReader { geo in
                        Capsule().fill(NX.frost.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(LinearGradient(colors: [NX.ice, NX.cyan], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * min(1, max(0, fraction)))
                                    .shadow(color: NX.cyan, radius: 4)
                            }
                    }
                    .frame(height: 5)
                }
                if target.until != .distantFuture {
                    Text("\(Int(left.rounded(.up)))")
                        .font(NX.label(18, .bold))
                        .foregroundStyle(NX.ice)
                        .monospacedDigit()
                }
                if !compact {
                    Button {
                        model.dismissReply()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NX.textMuted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glass(cornerRadius: 18, glow: 0.4, strong: true)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NX.ice.opacity(0.85), lineWidth: 1))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !talking else { return }
                talking = true
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                model.holdReplyWindow()
                model.engine.pressTalk(on: target.channel)
            }
            .onEnded { _ in
                guard talking else { return }
                talking = false
                model.engine.releaseTalk()
                model.releaseReplyWindow()
            }, including: compact ? .all : .subviews)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.talker) just talked to you")
        .accessibilityAction(named: "Reply") { model.engine.pressTalk(on: target.channel) }
        .accessibilityAction(named: "Stop talking") { model.engine.releaseTalk() }
    }
}

/// Everyone who isn't pinned, on one line: "Alex 5m, Site B 9m, Mom 1h". Tap for Channels.
struct EveryoneElseLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let pinned = Set(model.pinned.map(\.channel.id))
        let rest = model.recent.filter { !pinned.contains($0.channel.id) }
        if !rest.isEmpty {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Button {
                    model.tab = .channels
                } label: {
                    HStack(spacing: 8) {
                        (Text("Everyone else · ").foregroundColor(NX.textMuted)
                         + Text(rest.prefix(3).map { item in
                             item.live != nil ? "\(item.name) live"
                                 : item.name + (item.last.map { " " + RecentChannel.age($0.date, now: context.date) } ?? "")
                         }.joined(separator: ", ")).foregroundColor(NX.text))
                            .font(NX.body(13))
                            .lineLimit(1)
                        if rest.contains(where: { $0.missed > 0 }) { MissedDot() }
                        Spacer(minLength: 0)
                        Text("All ›")
                            .font(NX.label(13, .semibold))
                            .foregroundStyle(NX.ice)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glass(cornerRadius: 18, glow: 0.1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
