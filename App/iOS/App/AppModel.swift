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
                self?.snapshot = snapshot
                self?.watch.update(snapshot)
            }
        }
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.show(event) }
        }
        engine.onWatchAudio = { [weak self] pcm in
            Task { @MainActor in self?.watch.sendAudio(pcm) }
        }
        engine.onWatchSync = { [weak self] sync in
            Task { @MainActor in self?.watch.sendSync(sync) }
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

    // MARK: - Derived data

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

    /// Handles any `eptt://` link: a contact card or a shared push key.
    func open(link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.hasPrefix(PushKey.uriPrefix) {
            do {
                try engine.installPushKey(uri: link)
                banner = "Push key installed: background wake-ups enabled"
            } catch {
                banner = "That push key link is invalid"
            }
        } else {
            addContact(uri: link)
        }
    }

    func addContact(uri: String) {
        do {
            try engine.addContact(uri: uri.trimmingCharacters(in: .whitespacesAndNewlines))
            banner = "Added. Now let them scan your code too"
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
