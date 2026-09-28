import Foundation
import SwiftUI
import EPTTCore

/// Main-thread view model: mirrors the engine's snapshots for SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot = EngineSnapshot()
    @Published var banner: String?

    let engine = PTTEngine()
    private let watch = WatchBridge()
    private var started = false

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
            banner = "Contact added"
        } catch {
            banner = "That isn't a valid ePTT contact code"
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
        }
    }
}
