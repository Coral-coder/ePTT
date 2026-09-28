import Foundation
import MultipeerConnectivity
import os

/// Nearby links over MultipeerConnectivity, which picks Bluetooth, peer-to-peer Wi-Fi or the
/// local network automatically. Works with Wi-Fi and cellular off, like Nextel Direct Talk.
///
/// The session itself is unencrypted on purpose: every Chirp packet is already sealed and
/// authenticated end to end, so the transport only needs to move bytes.
final class NearbyTransport: NSObject {
    static let serviceType = "chirp-ptt"   // ≤15 chars; Info.plist lists _chirp-ptt._tcp/_udp

    /// All callbacks are delivered on `queue`; all methods must be called on `queue`.
    var onPacket: ((Data, MCPeerID) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?

    private let queue: DispatchQueue
    private let log = Logger(subsystem: "app.eptt", category: "nearby")
    private let peerID = MCPeerID(displayName: "chirp-" + String(UInt32.random(in: .min ... .max), radix: 36))
    private lazy var session: MCSession = {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        return session
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// Idempotent; restarts discovery after returning from the background.
    func start() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()

        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    func send(_ data: Data, to peer: MCPeerID) {
        guard session.connectedPeers.contains(peer) else { return }
        do {
            // Voice is real-time: a late packet is useless, so don't retransmit.
            try session.send(data, toPeers: [peer], with: .unreliable)
        } catch {
            log.debug("Nearby send failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension NearbyTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Anyone nearby may connect; they still can't read or inject anything without channel keys.
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log.error("Advertising failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension NearbyTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Only one side invites, so two phones don't cross invitations.
        guard self.peerID.displayName < peerID.displayName, !session.connectedPeers.contains(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension NearbyTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        queue.async { [weak self] in self?.onPeerConnected?(peerID) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { [weak self] in self?.onPacket?(data, peerID) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}
