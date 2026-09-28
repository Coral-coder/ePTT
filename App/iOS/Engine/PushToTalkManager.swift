import AVFoundation
import Foundation
import PushToTalk
import UIKit
import os

/// Wraps Apple's PushToTalk framework.
///
/// The framework allows one joined channel per app, so ePTT joins a single system channel and
/// multiplexes its own direct channels and talk groups over it (docs/ARCHITECTURE.md).
/// The framework is what lets a suspended app be woken by a `pushtotalk` push, and it owns the
/// audio session: audio may only run between `didActivate` and `didDeactivate`.
final class PushToTalkManager: NSObject {
    /// The one system channel. Fixed so it survives relaunches and restoration.
    static let systemChannelUUID = UUID(uuidString: "6E505454-0000-4000-8000-000000000001")!

    // Callbacks into the engine. They are invoked on the framework's queue; the engine hops as needed.
    var onJoined: (() -> Void)?
    var onLeft: (() -> Void)?
    var onPushToken: ((Data) -> Void)?
    var onBeginTransmitting: ((_ fromSystemUI: Bool) -> Void)?
    var onEndTransmitting: (() -> Void)?
    var onAudioActivated: ((AVAudioSession) -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onTransmitFailed: ((Error) -> Void)?
    /// Must return the name of the participant to show, or nil to reject the push.
    var onIncomingPush: (([String: Any]) -> String?)?

    private let log = Logger(subsystem: "app.eptt", category: "ptt")
    private var manager: PTChannelManager?
    private var descriptorName = "ePTT"
    private(set) var isJoined = false
    var isAvailable: Bool { manager != nil }

    /// Creates the channel manager. Call as early as possible at launch so pushes are handled.
    func setUp() async {
        do {
            manager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
            if manager?.activeChannelUUID == nil { join() } else { isJoined = true; onJoined?() }
        } catch {
            log.error("PushToTalk unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func join() {
        manager?.requestJoinChannel(channelUUID: Self.systemChannelUUID, descriptor: descriptor())
    }

    func leave() {
        manager?.leaveChannel(channelUUID: Self.systemChannelUUID)
    }

    func requestBeginTransmitting() {
        manager?.requestBeginTransmitting(channelUUID: Self.systemChannelUUID)
    }

    func stopTransmitting() {
        manager?.stopTransmitting(channelUUID: Self.systemChannelUUID)
    }

    /// Updates the Lock Screen / Dynamic Island label, e.g. to the selected channel's name.
    func setDescriptorName(_ name: String) {
        descriptorName = name
        guard let manager, isJoined else { return }
        Task { try? await manager.setChannelDescriptor(descriptor(), channelUUID: Self.systemChannelUUID) }
    }

    /// Shows who is talking (or clears it). Setting a participant makes iOS activate the audio session.
    func setActiveRemoteParticipant(_ name: String?) {
        guard let manager else { return }
        let participant = name.map { PTParticipant(name: $0, image: nil) }
        Task {
            do {
                try await manager.setActiveRemoteParticipant(participant, channelUUID: Self.systemChannelUUID)
            } catch {
                log.error("setActiveRemoteParticipant failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setServiceStatus(_ status: PTServiceStatus) {
        guard let manager, isJoined else { return }
        Task { try? await manager.setServiceStatus(status, channelUUID: Self.systemChannelUUID) }
    }

    private func descriptor() -> PTChannelDescriptor {
        PTChannelDescriptor(name: descriptorName, image: UIImage(systemName: "antenna.radiowaves.left.and.right"))
    }
}

extension PushToTalkManager: PTChannelManagerDelegate {
    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        isJoined = true
        onJoined?()
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        isJoined = false
        onLeft?()
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        onBeginTransmitting?(source != .developerRequest)
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        onEndTransmitting?()
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        onPushToken?(pushToken)
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        // Leaving the channel would let anyone holding a push token knock us offline, so an
        // unauthenticated push gets a placeholder participant that the engine clears at once.
        let name = onIncomingPush?(pushPayload) ?? "ePTT"
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        onAudioActivated?(audioSession)
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        onAudioDeactivated?()
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
        log.error("Join failed: \(error.localizedDescription, privacy: .public)")
    }

    func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID,
                        error: Error) {
        log.error("Begin transmitting failed: \(error.localizedDescription, privacy: .public)")
        onTransmitFailed?(error)
    }
}

extension PushToTalkManager: PTChannelRestorationDelegate {
    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        descriptor()
    }
}
