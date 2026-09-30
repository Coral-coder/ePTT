import Foundation
import Network
import os
import EPTTCore

private let transportLog = Logger(subsystem: "app.eptt", category: "transport")

/// One UDP socket's worth of peer-to-peer transport (ARCHITECTURE.md, "Networking without a
/// server"; PROTOCOL.md §2 and §9).
///
/// - A single `NWListener` (AWDL enabled) receives datagrams and advertises `_eptt._udp`.
/// - Outgoing `.hostPort` connections are bound to the listener's port so NAT/firewall
///   pinholes and STUN mappings match the address we advertise.
/// - Candidates = local interface addresses + STUN-mapped public addresses + static ones.
///
/// Threading: all callbacks are delivered on `queue`, and all methods must be called on `queue`.
final class UDPTransport {
    static let serviceType = "_eptt._udp"

    /// Every non-STUN datagram received, with the remote endpoint (reply with `send(_:to:)`).
    var onPacket: ((Data, NWEndpoint) -> Void)?
    /// A Bonjour result for `_eptt._udp` appeared that is not our own advert.
    var onPeerDiscovered: ((NWEndpoint) -> Void)?
    /// `localCandidates` changed.
    var onCandidatesChanged: (([Candidate]) -> Void)?

    /// User-configured candidates (e.g. an overlay VPN host), always appended to `localCandidates`.
    var staticCandidates: [Candidate] = [] {
        didSet { recomputeCandidates() }
    }

    var stunEnabled: Bool = true {
        didSet {
            guard stunEnabled != oldValue else { return }
            if stunEnabled {
                startSTUN()
            } else {
                cancelSTUNQueries()
                stunMapped = []
                recomputeCandidates()
            }
        }
    }

    private(set) var localCandidates: [Candidate] = []
    /// Bound listener port once the listener is ready.
    private(set) var port: UInt16?

    // MARK: - Private state

    private final class Conn {
        let connection: NWConnection
        let endpoint: NWEndpoint
        let isOutbound: Bool
        /// Local port an outbound connection was bound to (nil if unbound / inbound).
        let boundPort: UInt16?
        var lastActivity: TimeInterval
        var pending: [Data] = []
        var isReady = false
        var closed = false

        init(connection: NWConnection, endpoint: NWEndpoint, isOutbound: Bool, boundPort: UInt16?) {
            self.connection = connection
            self.endpoint = endpoint
            self.isOutbound = isOutbound
            self.boundPort = boundPort
            self.lastActivity = UDPTransport.now()
        }
    }

    private static let maxPendingPerConnection = 64
    private static let maxPreReadySends = 64
    private static let idleTimeout: TimeInterval = 120
    private static let sweepInterval: TimeInterval = 30
    private static let stunTimeout: TimeInterval = 3

    private let queue: DispatchQueue
    private let preferredPort: UInt16
    private let serviceName: String

    private var isRunning = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var sweepTimer: DispatchSourceTimer?

    private var connections: [ObjectIdentifier: Conn] = [:]
    /// Preferred connection for sending to an endpoint.
    private var routes: [NWEndpoint: ObjectIdentifier] = [:]
    /// `.hostPort` sends made before the listener port is known (they must be bound to it).
    private var preReadySends: [(Data, NWEndpoint)] = []

    private var lastLocalAddresses: [Candidate] = []
    private var stunMapped: [Candidate] = []
    /// Outstanding STUN transactions: transaction ID → timeout work item.
    private var stunQueries: [Data: DispatchWorkItem] = [:]

    init(queue: DispatchQueue, preferredPort: UInt16 = 47474) {
        self.queue = queue
        self.preferredPort = preferredPort
        self.serviceName = "eptt-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        pathMonitor?.cancel()
        sweepTimer?.cancel()
        for conn in connections.values { conn.connection.cancel() }
        for item in stunQueries.values { item.cancel() }
    }

    // MARK: - Lifecycle

    /// Idempotent. (Re)creates a failed or cancelled listener, browser and path monitor.
    func start() {
        isRunning = true

        if let existing = listener, Self.isDead(existing.state) {
            listener = nil
            port = nil
            existing.cancel()
        }
        if listener == nil { startListener(on: preferredListenerPort) }

        if let existing = browser, Self.isDead(existing.state) {
            browser = nil
            existing.cancel()
        }
        if browser == nil { startBrowser() }

        if pathMonitor == nil { startPathMonitor() }

        if sweepTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
            timer.setEventHandler { [weak self] in self?.sweepIdleConnections() }
            timer.resume()
            sweepTimer = timer
        }

        recomputeCandidates()
    }

    func stop() {
        isRunning = false

        let oldListener = listener
        listener = nil
        port = nil
        oldListener?.cancel()

        let oldBrowser = browser
        browser = nil
        oldBrowser?.cancel()

        pathMonitor?.cancel()
        pathMonitor = nil

        sweepTimer?.cancel()
        sweepTimer = nil

        closeAllConnections()
        preReadySends.removeAll()
        cancelSTUNQueries()
        stunMapped = []
        lastLocalAddresses = []
    }

    // MARK: - Sending

    func send(_ data: Data, to candidate: Candidate) {
        guard candidate.port != 0, let remotePort = NWEndpoint.Port(rawValue: candidate.port) else {
            transportLog.debug("Dropping send to candidate with invalid port: \(candidate.description, privacy: .private)")
            return
        }
        let host = NWEndpoint.Host(candidate.hostString)
        send(data, to: .hostPort(host: host, port: remotePort))
    }

    func send(_ data: Data, to endpoint: NWEndpoint) {
        if let id = routes[endpoint], let conn = connections[id], !conn.closed {
            enqueue(data, on: conn)
            return
        }

        if case .hostPort = endpoint, port == nil {
            // Outgoing hostPort connections must share the listener's port; wait for it.
            guard isRunning else {
                transportLog.debug("Dropping send while stopped")
                return
            }
            if preReadySends.count >= Self.maxPreReadySends { preReadySends.removeFirst() }
            preReadySends.append((data, endpoint))
            return
        }

        guard let conn = makeOutboundConnection(to: endpoint) else { return }
        enqueue(data, on: conn)
    }

    private func enqueue(_ data: Data, on conn: Conn) {
        if conn.isReady {
            transmit(data, on: conn)
        } else {
            if conn.pending.count >= Self.maxPendingPerConnection { conn.pending.removeFirst() }
            conn.pending.append(data)
        }
    }

    private func transmit(_ data: Data, on conn: Conn) {
        conn.lastActivity = Self.now()
        let endpoint = conn.endpoint
        conn.connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                transportLog.debug("Send to \(String(describing: endpoint), privacy: .private) failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    private func flushPending(_ conn: Conn) {
        guard conn.isReady, !conn.closed else { return }
        let queued = conn.pending
        conn.pending.removeAll()
        for data in queued { transmit(data, on: conn) }
    }

    // MARK: - Connections

    private func makeOutboundConnection(to endpoint: NWEndpoint) -> Conn? {
        let parameters = Self.makeUDPParameters()
        var boundPort: UInt16?

        switch endpoint {
        case .hostPort(let host, _):
            parameters.allowLocalEndpointReuse = true
            if let listenerPort = port, let localPort = NWEndpoint.Port(rawValue: listenerPort) {
                let anyAddress: NWEndpoint.Host
                if case .ipv6 = host {
                    anyAddress = NWEndpoint.Host("::")
                } else {
                    // IPv4 literals and names (e.g. STUN servers, overlay DNS names) bind IPv4.
                    anyAddress = NWEndpoint.Host("0.0.0.0")
                }
                parameters.requiredLocalEndpoint = .hostPort(host: anyAddress, port: localPort)
                boundPort = listenerPort
            }
        case .service:
            parameters.includePeerToPeer = true
        default:
            parameters.includePeerToPeer = true
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        let conn = Conn(connection: connection, endpoint: endpoint, isOutbound: true, boundPort: boundPort)
        adopt(conn)
        return conn
    }

    /// Every new source address becomes a connection; spoofed sources could otherwise open
    /// thousands. Past this, the least recently active inbound one makes room.
    private static let maxInboundConnections = 128

    private func adoptInbound(_ connection: NWConnection) {
        let inbound = connections.values.filter { !$0.isOutbound && !$0.closed }
        if inbound.count >= Self.maxInboundConnections,
           let oldest = inbound.min(by: { $0.lastActivity < $1.lastActivity }) {
            close(oldest)
        }
        let conn = Conn(connection: connection, endpoint: connection.endpoint, isOutbound: false, boundPort: nil)
        adopt(conn)
    }

    private func adopt(_ conn: Conn) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        if let currentID = routes[conn.endpoint], let current = connections[currentID],
           !current.closed, current.isReady {
            // Keep the working route; this connection still receives.
        } else {
            routes[conn.endpoint] = id
        }

        conn.connection.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            self.handleState(state, of: conn)
        }
        conn.connection.start(queue: queue)
        receiveLoop(conn)
    }

    private func handleState(_ state: NWConnection.State, of conn: Conn) {
        switch state {
        case .ready:
            conn.isReady = true
            if let currentID = routes[conn.endpoint], let current = connections[currentID],
               current !== conn, !current.isReady {
                routes[conn.endpoint] = ObjectIdentifier(conn)
            }
            flushPending(conn)
        case .waiting(let error):
            transportLog.debug("Connection to \(String(describing: conn.endpoint), privacy: .private) waiting: \(String(describing: error), privacy: .public)")
        case .failed(let error):
            transportLog.info("Connection to \(String(describing: conn.endpoint), privacy: .private) failed: \(String(describing: error), privacy: .public)")
            close(conn)
        case .cancelled:
            close(conn)
        default:
            break
        }
    }

    private func receiveLoop(_ conn: Conn) {
        conn.connection.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, !conn.closed else { return }
            if let data, !data.isEmpty {
                conn.lastActivity = Self.now()
                self.deliver(data, from: conn.endpoint)
            }
            if conn.closed { return } // a callback may have stopped the transport
            if let error {
                transportLog.debug("Receive from \(String(describing: conn.endpoint), privacy: .private) failed: \(String(describing: error), privacy: .public)")
                self.close(conn)
                return
            }
            switch conn.connection.state {
            case .cancelled, .failed:
                self.close(conn)
            default:
                self.receiveLoop(conn)
            }
        }
    }

    private func deliver(_ data: Data, from endpoint: NWEndpoint) {
        if STUN.isSTUN(data) {
            handleSTUNResponse(data)
        } else {
            onPacket?(data, endpoint)
        }
    }

    /// Idempotent: cancels the connection and removes it from the caches.
    private func close(_ conn: Conn) {
        guard !conn.closed else { return }
        conn.closed = true
        conn.pending.removeAll()
        conn.connection.cancel()

        let id = ObjectIdentifier(conn)
        connections[id] = nil
        if routes[conn.endpoint] == id {
            routes[conn.endpoint] = nil
            let sameEndpoint = connections.values.filter { $0.endpoint == conn.endpoint && !$0.closed }
            if let replacement = sameEndpoint.first(where: { $0.isReady }) ?? sameEndpoint.first {
                routes[conn.endpoint] = ObjectIdentifier(replacement)
            }
        }
    }

    private func closeAllConnections() {
        let all = Array(connections.values)
        for conn in all { close(conn) }
        connections.removeAll()
        routes.removeAll()
    }

    private func sweepIdleConnections() {
        let cutoff = Self.now() - Self.idleTimeout
        let idle = connections.values.filter { $0.lastActivity < cutoff }
        for conn in idle {
            transportLog.debug("Closing idle connection to \(String(describing: conn.endpoint), privacy: .private)")
            close(conn)
        }
    }

    // MARK: - Listener

    private var preferredListenerPort: NWEndpoint.Port {
        NWEndpoint.Port(rawValue: preferredPort) ?? .any
    }

    private func startListener(on requestedPort: NWEndpoint.Port) {
        let parameters = Self.makeUDPParameters()
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: requestedPort)
        } catch {
            transportLog.error("Listener creation on port \(requestedPort.rawValue) failed: \(String(describing: error), privacy: .public)")
            if requestedPort != .any { startListener(on: .any) }
            return
        }

        newListener.service = NWListener.Service(name: serviceName, type: Self.serviceType)

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener else { return }
            self.handleListenerState(state, of: newListener, requestedPort: requestedPort)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.isRunning else {
                connection.cancel()
                return
            }
            self.adoptInbound(connection)
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, of current: NWListener, requestedPort: NWEndpoint.Port) {
        switch state {
        case .ready:
            let newPort = current.port?.rawValue
            let previousPort = port
            port = newPort
            transportLog.info("Listening on UDP port \(newPort ?? 0) as \(self.serviceName, privacy: .public)")
            if previousPort != newPort {
                // Outbound connections bound to another port no longer match our candidates.
                let stale = connections.values.filter { $0.isOutbound && $0.boundPort != nil && $0.boundPort != newPort }
                for conn in stale { close(conn) }
            }
            recomputeCandidates()
            startSTUN()
            let queued = preReadySends
            preReadySends.removeAll()
            for (data, endpoint) in queued { send(data, to: endpoint) }
        case .waiting(let error), .failed(let error):
            transportLog.error("Listener on port \(requestedPort.rawValue) error: \(String(describing: error), privacy: .public)")
            if case .waiting = state, !Self.isAddressInUse(error) {
                return // waits for a usable network; the listener recovers by itself
            }
            listener = nil
            port = nil
            current.cancel()
            if Self.isAddressInUse(error), requestedPort != .any {
                transportLog.info("Port \(requestedPort.rawValue) in use, retrying on any port")
                startListener(on: .any)
            }
            // Otherwise the next start() or path update recreates the listener.
            recomputeCandidates()
        case .cancelled:
            listener = nil
            port = nil
        default:
            break
        }
    }

    // MARK: - Browser

    private func startBrowser() {
        let parameters = Self.makeUDPParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)

        newBrowser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self, self.isRunning else { return }
            for change in changes {
                guard case .added(let result) = change else { continue }
                guard case .service(let name, _, _, _) = result.endpoint, name != self.serviceName else { continue }
                transportLog.debug("Discovered peer \(name, privacy: .private)")
                self.onPeerDiscovered?(result.endpoint)
            }
        }
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self, let newBrowser, self.browser === newBrowser else { return }
            switch state {
            case .failed(let error):
                transportLog.error("Bonjour browser failed: \(String(describing: error), privacy: .public)")
                self.browser = nil
                newBrowser.cancel()
            case .cancelled:
                self.browser = nil
            default:
                break
            }
        }

        browser = newBrowser
        newBrowser.start(queue: queue)
    }

    // MARK: - Path monitoring

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard isRunning else { return }
        transportLog.info("Path update: \(String(describing: path.status), privacy: .public)")

        if listener == nil { startListener(on: preferredListenerPort) }
        if browser == nil { startBrowser() }

        guard let port else {
            recomputeCandidates()
            return
        }

        let local = LocalAddresses.candidates(port: port)
        guard local != lastLocalAddresses else { return }

        let removed = Set(lastLocalAddresses).subtracting(local)
        if !removed.isEmpty {
            // Addresses went away: connections and the STUN mapping belong to the old network.
            transportLog.info("Local addresses changed; resetting connections")
            closeAllConnections()
            stunMapped = []
        }
        recomputeCandidates(local: local)
        if path.status == .satisfied { startSTUN() }
    }

    // MARK: - Candidates

    private func recomputeCandidates(local precomputed: [Candidate]? = nil) {
        let local: [Candidate]
        if let precomputed {
            local = precomputed
        } else if let port {
            local = LocalAddresses.candidates(port: port)
        } else {
            local = []
        }
        lastLocalAddresses = local

        var seen = Set<Candidate>()
        var combined: [Candidate] = []
        for candidate in local + stunMapped + staticCandidates {
            if seen.insert(candidate).inserted { combined.append(candidate) }
        }
        guard combined != localCandidates else { return }
        localCandidates = combined
        transportLog.info("Candidates: \(combined.map(\.description).joined(separator: ", "), privacy: .private)")
        onCandidatesChanged?(combined)
    }

    // MARK: - STUN

    private func startSTUN() {
        guard stunEnabled, isRunning, port != nil else { return }
        cancelSTUNQueries()

        for (server, serverPort) in STUN.defaultServers {
            guard let remotePort = NWEndpoint.Port(rawValue: serverPort) else { continue }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server), port: remotePort)
            let transactionID = Data.random(count: 12)

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.stunQueries.removeValue(forKey: transactionID) != nil else { return }
                transportLog.info("STUN request to \(server, privacy: .public) timed out")
            }
            stunQueries[transactionID] = timeout
            queue.asyncAfter(deadline: .now() + Self.stunTimeout, execute: timeout)

            send(STUN.bindingRequest(transactionID: transactionID), to: endpoint)
        }
    }

    private func cancelSTUNQueries() {
        for item in stunQueries.values { item.cancel() }
        stunQueries.removeAll()
    }

    private func handleSTUNResponse(_ data: Data) {
        guard data.count >= 20 else { return }
        let start = data.startIndex
        let transactionID = Data(data[(start + 8)..<(start + 20)])
        guard let timeout = stunQueries[transactionID] else { return }

        let mapped: Candidate
        do {
            mapped = try STUN.parseBindingResponse(data, transactionID: transactionID)
        } catch {
            transportLog.debug("Ignoring STUN message: \(String(describing: error), privacy: .public)")
            return
        }
        timeout.cancel()
        stunQueries[transactionID] = nil

        guard mapped.isRoutable, mapped.port != 0 else { return }
        let localHosts = Set(lastLocalAddresses.map(\.hostString))
        guard !localHosts.contains(mapped.hostString) else { return } // not behind NAT
        guard !stunMapped.contains(mapped) else { return }
        transportLog.info("STUN mapped address: \(mapped.description, privacy: .private)")
        stunMapped.append(mapped)
        recomputeCandidates()
    }

    // MARK: - Helpers

    private static func makeUDPParameters() -> NWParameters {
        NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EADDRINUSE { return true }
        return false
    }

    private static func isDead(_ state: NWListener.State) -> Bool {
        switch state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private static func isDead(_ state: NWBrowser.State) -> Bool {
        switch state {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}
