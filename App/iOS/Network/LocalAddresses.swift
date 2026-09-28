import Darwin
import Foundation
import EPTTCore

/// Enumerates this device's own interface addresses as UDP candidates (ARCHITECTURE.md,
/// "Networking without a server").
enum LocalAddresses {
    /// Addresses of up, non-loopback interfaces, paired with `port`.
    ///
    /// - IPv4: every routable address (private LAN addresses help peers on the same Wi-Fi).
    /// - IPv6: routable addresses only (no link-local, loopback or unspecified).
    /// - VPN tunnels (`utun*`, `ipsec*`) are skipped, except Tailscale overlay addresses
    ///   (100.64.0.0/10 and fd7a:115c:a1e0::/48), which are valuable.
    static func candidates(port: UInt16) -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var result: [Candidate] = []
        var seen = Set<Candidate>()
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let candidate = candidate(from: entry.pointee, port: port),
                  seen.insert(candidate).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func candidate(from entry: ifaddrs, port: UInt16) -> Candidate? {
        let flags = Int32(bitPattern: entry.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { return nil }
        guard let sockaddrPointer = entry.ifa_addr, let namePointer = entry.ifa_name else { return nil }
        let interfaceName = String(cString: namePointer)

        let candidate: Candidate
        switch Int32(sockaddrPointer.pointee.sa_family) {
        case AF_INET:
            var address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            let bytes = withUnsafeBytes(of: &address) { Data($0) }
            guard bytes.count == 4 else { return nil }
            candidate = .ipv4(bytes, port: port)
        case AF_INET6:
            var address = sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            let bytes = withUnsafeBytes(of: &address) { Data($0) }
            guard bytes.count == 16 else { return nil }
            candidate = .ipv6(bytes, port: port)
        default:
            return nil
        }

        guard candidate.isRoutable else { return nil }
        let isTunnel = interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ipsec")
        if isTunnel && !isOverlay(candidate) { return nil }
        // Note: IPv6 temporary/deprecated flags (SIOCGIFAFLAG_IN6) are not exposed on iOS,
        // so privacy addresses are included; they are still reachable while they exist.
        return candidate
    }

    /// Tailscale's CGNAT range 100.64.0.0/10 and ULA prefix fd7a:115c:a1e0::/48.
    static func isOverlay(_ candidate: Candidate) -> Bool {
        switch candidate {
        case .ipv4(let address, _):
            let b = [UInt8](address)
            return b.count == 4 && b[0] == 100 && (b[1] & 0xC0) == 0x40
        case .ipv6(let address, _):
            let b = [UInt8](address)
            return b.count == 16
                && b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11
                && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0
        case .host:
            return false
        }
    }
}
