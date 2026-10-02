import Foundation
import SwiftUI
import EPTTCore

/// Main-thread view model: mirrors the engine's snapshots for SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot = EngineSnapshot()
    @Published var banner: String?
    @Published var tab: NXTab = .talk
    /// Someone on another channel just talked to us: for a few seconds the talk button (Pinned
    /// layout) or the reply bar (Talk board) answers them.
    @Published private(set) var replyTarget: ReplyTarget?
    private var replyTimer: Task<Void, Never>?
    /// A reply is being held right now.
    @Published private(set) var replying = false
    static let replySeconds: Double = 8

    let engine = PTTEngine()
    private let watch = WatchBridge()
    private var started = false
    /// Set while a single-press (Action Button / Siri) transmission is keyed up.
    private var latched = false
    private var latchTimer: Task<Void, Never>?
    /// How long a latched transmission may run before it unkeys itself.
    static let latchLimit: Duration = .seconds(60)

    private init() {
        engine.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let before = self.snapshot.talk
                self.snapshot = snapshot
                self.watch.update(snapshot)
                self.noteTalkChange(from: before, to: snapshot.talk)
            }
        }
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.show(event) }
        }
        engine.onWatchAudio = { [weak self] pcm in
            Task { @MainActor in self?.watch.sendAudio(pcm) }
        }
        engine.onWatchWipe = { [weak self] in
            Task { @MainActor in self?.watch.sendWipe() }
        }
        engine.onWatchSync = { [weak self] sync in
            Task { @MainActor in self?.watch.sendSync(sync) }
        }
        engine.onPhoneClaim = { [weak self] date in
            Task { @MainActor in self?.watch.sendPhoneClaim(date) }
        }
        watch.engine = engine
    }

    /// Idempotent; called from `application(_:didFinishLaunchingWithOptions:)` so PushToTalk is
    /// ready before any wake push is delivered.
    func start() {
        guard !started else { return }
        started = true
        engine.start()
        watch.activate()
    }

    // MARK: - Single-press talk

    var isTransmitting: Bool {
        if case .transmitting = snapshot.talk { return true }
        return false
    }

    func toggleLatchedTalk() {
        setLatchedTalk(!(latched || isTransmitting))
    }

    func setLatchedTalk(_ on: Bool) {
        latchTimer?.cancel()
        latchTimer = nil
        latched = on
        guard on else {
            engine.releaseTalk()
            return
        }
        tab = .talk
        engine.pressTalk()
        latchTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.latchLimit)
            guard !Task.isCancelled else { return }
            self?.setLatchedTalk(false)
        }
    }

    // MARK: - Reply window

    private func noteTalkChange(from before: EngineSnapshot.Talk, to now: EngineSnapshot.Talk) {
        guard case .receiving(let channel, let talker) = before, now != before,
              channel != snapshot.settings.selectedChannel,
              !talker.hasPrefix("Replay · "), !talker.hasPrefix("Held · ") else { return }
        if case .receiving(let next, _) = now, next == channel { return }
        replyTarget = ReplyTarget(channel: channel, talker: talker.components(separatedBy: " · ").first ?? talker,
                                  until: Date().addingTimeInterval(Self.replySeconds))
        replyTimer?.cancel()
        replyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.replySeconds))
            guard !Task.isCancelled else { return }
            self?.replyTarget = nil
        }
    }

    /// Keeps the reply window open while replying, and for a moment after.
    func holdReplyWindow() {
        guard let target = replyTarget else { return }
        replyTimer?.cancel()
        replying = true
        replyTarget = ReplyTarget(channel: target.channel, talker: target.talker, until: .distantFuture)
    }

    func releaseReplyWindow() {
        replying = false
        guard let target = replyTarget else { return }
        replyTarget = ReplyTarget(channel: target.channel, talker: target.talker,
                                  until: Date().addingTimeInterval(Self.replySeconds))
        replyTimer?.cancel()
        replyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.replySeconds))
            guard !Task.isCancelled else { return }
            self?.replyTarget = nil
        }
    }

    func dismissReply() {
        replyTimer?.cancel()
        replyTarget = nil
    }

    // MARK: - Recent activity

    /// Just the person from a talker label: "Sam · Crew" → "Sam", "Replay · Sam" → "Sam".
    static func talkerName(_ label: String) -> String {
        var rest = label
        for prefix in ["Replay · ", "Held · "] where rest.hasPrefix(prefix) { rest.removeFirst(prefix.count) }
        return rest.components(separatedBy: " · ").first ?? rest
    }

    /// Every channel with its latest activity, live first, then most recent; quiet ones last.
    var recent: [RecentChannel] {
        let transfers = snapshot.transfers
        let held = snapshot.held
        return snapshot.channels.map { channel -> RecentChannel in
            let name = displayName(of: channel)
            let last = transfers.first { $0.channelID == channel.id || ($0.channelID == nil && $0.channel == name) }
            var live: String?
            switch snapshot.talk {
            case .receiving(let id, let talker) where id == channel.id:
                live = AppModel.talkerName(talker)
            case .transmitting(let id) where id == channel.id:
                live = "You"
            default: break
            }
            let missed = held.filter { $0.channel == name }.count
            return RecentChannel(channel: channel, name: name, last: last, live: live, missed: missed)
        }
        .sorted { a, b in
            if (a.live != nil) != (b.live != nil) { return a.live != nil }
            switch (a.last?.date, b.last?.date) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Recent key-ups across every channel, newest first (the Radio log).
    var keyUps: [TransferRecord] { snapshot.transfers }

    func channel(for record: TransferRecord) -> Channel? {
        if let id = record.channelID { return snapshot.channels.first { $0.id == id } }
        return snapshot.channels.first { displayName(of: $0) == record.channel }
    }

    /// Pinned channels that still exist; until three are pinned, the most recent fill in.
    var pinned: [RecentChannel] {
        let all = recent
        var out = snapshot.settings.pinnedChannels.compactMap { id in all.first { $0.channel.id == id } }
        for item in all where out.count < 3 && !out.contains(where: { $0.channel.id == item.channel.id }) {
            out.append(item)
        }
        return Array(out.prefix(3))
    }

    func isPinned(_ id: ChannelID) -> Bool { snapshot.settings.pinnedChannels.contains(id) }

    func togglePin(_ id: ChannelID) {
        engine.updateSettings { settings in
            if let i = settings.pinnedChannels.firstIndex(of: id) {
                settings.pinnedChannels.remove(at: i)
            } else {
                settings.pinnedChannels = Array((settings.pinnedChannels + [id]).suffix(3))
            }
        }
    }

    // MARK: - Profile

    /// Onboarding shows until the user has chosen a name.
    /// (Only once the engine has published its saved state, so it never flashes up at launch.)
    var needsOnboarding: Bool { snapshot.localIdentity != nil && !snapshot.settings.nameConfirmed }

    /// Sets the name everyone sees when you talk. Returns false for an empty name.
    @discardableResult
    func setDisplayName(_ raw: String) -> Bool {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !name.isEmpty else { return false }
        engine.updateSettings {
            $0.displayName = name
            $0.nameConfirmed = true
        }
        return true
    }

    // MARK: - Derived data

    /// Whether everyone on `channel` has a post-quantum link with us (protocol 2, session past
    /// its classical epoch 0), so anything said there is post-quantum end to end.
    func isQuantumSafe(_ channel: Channel) -> Bool {
        guard !channel.members.isEmpty else { return false }
        return channel.members.allSatisfy { member in
            !snapshot.legacyContacts.contains(member)
                && (snapshot.channels.first { $0.kind == .direct && $0.members == [member] }?.session?.sendEpoch ?? 0) >= 1
        }
    }

    var selectedChannel: Channel? {
        snapshot.settings.selectedChannel.flatMap { id in snapshot.channels.first { $0.id == id } }
    }

    var groups: [Channel] { snapshot.channels.filter { $0.kind == .group } }

    func displayName(of channel: Channel) -> String {
        guard channel.kind == .direct, let member = channel.members.first,
              let contact = snapshot.contacts.first(where: { $0.id == member }) else { return channel.name }
        return contact.name
    }

    func isOnline(_ channel: Channel) -> Bool {
        channel.members.contains { snapshot.onlinePeers.contains($0) }
    }

    func directChannel(for contact: Contact) -> Channel? {
        snapshot.channels.first { $0.kind == .direct && $0.members == [contact.id] }
    }

    // MARK: - Actions

    /// Handles any `nxtptt://` link (or an old `eptt://` one): a contact card or a shared push key.
    /// A link opened from outside NXTPTT (Messages, Safari, the Camera app): say what it will
    /// do and wait for a yes. Links scanned or pasted inside the app open straight away.
    @Published var linkPrompt: LinkPrompt?

    func openFromOutside(_ raw: String) {
        let link = LinkScheme.normalize(raw)
        if link.hasPrefix(PushKey.uriPrefix) {
            guard (try? PushKey(uri: link)) != nil else {
                banner = "That push key link is invalid"
                return
            }
            linkPrompt = LinkPrompt(
                title: "Install this push key?", confirm: "Install",
                message: (snapshot.wakeAvailable ? "It replaces the push key already on this phone. " : "")
                    + "Wake-ups and call alerts are sent with it. Only accept one from someone you trust.",
                link: link)
        } else if link.hasPrefix(GroupJoinCode.uriPrefix) {
            guard let code = try? GroupJoinCode(uri: link) else {
                banner = "That isn't a valid talk group code"
                return
            }
            let inviter = code.inviter.name.isEmpty ? "The person who shared it" : code.inviter.name
            linkPrompt = LinkPrompt(
                title: "Join \(code.groupName)?", confirm: "Ask to join",
                message: "\(inviter) will be asked to let you in, and gets your contact details (name, push tokens and addresses).",
                link: link)
        } else if let card = try? ContactCard(uri: link) {
            linkPrompt = LinkPrompt(
                title: "Add \(card.name.isEmpty ? "this contact" : card.name)?", confirm: "Add",
                message: "They're added to your contacts, and your phone says hello to them so you can talk.",
                link: link)
        } else {
            banner = "That isn't a valid NXTPTT link"
        }
    }

    func open(link: String) {
        let link = LinkScheme.normalize(link)
        if link.hasPrefix(PushKey.uriPrefix) {
            do {
                try engine.installPushKey(uri: link)
                banner = "Push key installed: background wake-ups enabled"
            } catch {
                banner = "That push key link is invalid"
            }
        } else if link.hasPrefix(GroupJoinCode.uriPrefix) {
            do {
                try engine.joinGroup(uri: link)
            } catch {
                banner = "That isn't a valid talk group code"
            }
        } else {
            addContact(uri: link)
        }
    }

    func addContact(uri: String) {
        do {
            try engine.addContact(uri: uri.trimmingCharacters(in: .whitespacesAndNewlines))
            banner = "Added. Send them your link too, so they can add you back"
        } catch {
            banner = "That isn't a valid NXTPTT contact code"
        }
    }

    private func show(_ event: EngineEvent) {
        switch event {
        case .busy: banner = "Channel busy"
        case .preempted: banner = "Someone else keyed up first"
        case .callAlert(let from, let text): banner = "Call alert from \(from)" + (text.map { ": \($0)" } ?? "")
        case .joinedGroup(let name): banner = "Joined talk group \(name)"
        case .unreachable(let name): banner = "Couldn't connect to \(name)"
        case .message(let text): banner = text
        case .delivery(let legs): banner = Self.deliverySummary(legs)
        }
    }

    /// One line per transmission: "Delivered to Sam · Wi-Fi", "Sent to Sam via iCloud relay",
    /// or "Not delivered to Sam: <reason>".
    static func deliverySummary(_ legs: [TransferRecord.Leg]) -> String? {
        guard let summary = baseDeliverySummary(legs) else { return nil }
        // Recipients on Do Not Disturb got it, but their phone holds it for later.
        let held = legs.filter { $0.route != .failed && ($0.reason?.contains("Do Not Disturb") ?? false) }.map(\.peer)
        guard !held.isEmpty else { return summary }
        let who = held.count == 1 ? held[0] : "\(held[0]) and \(held.count - 1) more"
        return summary + " · held by \(who) (Do Not Disturb)"
    }

    private static func baseDeliverySummary(_ legs: [TransferRecord.Leg]) -> String? {
        guard !legs.isEmpty else { return nil }
        if let failed = legs.first(where: { $0.route == .failed }) {
            let others = legs.filter { $0.route == .failed }.count - 1
            let who = others > 0 ? "\(failed.peer) and \(others) more" : failed.peer
            return "Not delivered to \(who)" + (failed.reason.map { ": \($0)" } ?? "")
        }
        if legs.count == 1, let leg = legs.first {
            return leg.route == .relay ? "Sent to \(leg.peer) via iCloud relay"
                                       : "Delivered to \(leg.peer) · \(leg.route.shortLabel)"
        }
        let relayed = legs.filter { $0.route == .relay }.count
        return relayed > 0 ? "Delivered to \(legs.count) (\(relayed) via iCloud relay)" : "Delivered to all \(legs.count)"
    }

    /// "Connected · Wi-Fi" when a live path to the channel exists, otherwise what will happen instead.
    func connectionStatus(_ channel: Channel) -> String {
        if let route = channel.members.lazy.compactMap({ self.snapshot.peerRoutes[$0] }).first {
            return "Connected · \(route.shortLabel)"
        }
        if snapshot.relayAvailable && snapshot.settings.relayEnabled { return "Not connected · will use iCloud relay" }
        return "Not connected"
    }
}

struct ReplyTarget: Equatable {
    var channel: ChannelID
    var talker: String
    var until: Date
}

/// A channel with its most recent activity, for the Talk screen layouts.
struct RecentChannel: Identifiable {
    var channel: Channel
    var name: String
    var last: TransferRecord?
    /// Who is talking on it right now ("You" when we are).
    var live: String?
    /// Messages held for it by Do Not Disturb.
    var missed: Int

    var id: ChannelID { channel.id }

    /// "Jordan talking", "Sam · 20s", "You · 9m", or the channel type when quiet.
    func detail(now: Date) -> String {
        if let live { return live == "You" ? "You're talking" : "\(live) talking" }
        guard let last else { return channel.kind == .group ? "Talk group" : "Private" }
        let who = last.outgoing ? "You" : (last.legs.first?.peer ?? "")
        return (who.isEmpty ? "" : who + " · ") + RecentChannel.age(last.date, now: now)
    }

    /// "now", "20s", "5m", "3h", "2d".
    static func age(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

/// "Install this push key?" / "Join Crew?" / "Add Sam?" for a link opened from outside.
struct LinkPrompt: Identifiable {
    let id = UUID()
    var title: String
    var confirm: String
    var message: String
    var link: String
}
