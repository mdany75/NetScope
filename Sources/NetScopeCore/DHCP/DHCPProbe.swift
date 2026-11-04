import Darwin
import Foundation

/// Envoi d'un DHCPDISCOVER et réception des offres, sans droits particuliers.
///
/// Le port UDP 68 est déjà tenu par macOS (configd) : on essaie de le partager (SO_REUSEADDR et
/// SO_REUSEPORT : les datagrammes en broadcast sont remis à chaque socket). Si macOS refuse, le
/// DISCOVER part d'un port libre avec le drapeau broadcast, et les offres doivent être lues par
/// une capture (BPF ou tcpdump). Jamais de DHCPREQUEST : aucun bail n'est pris.
public enum DHCPProbe {
    public static let serverPort: UInt16 = 67
    public static let clientPort: UInt16 = 68
    public static let broadcast = IPv4Address(255, 255, 255, 255)

    /// Socket UDP liée à `port` (68 par défaut), en broadcast, attachée à l'interface si possible.
    /// Renvoie nil si la liaison est refusée (port tenu par le système sans partage).
    public static func openSocket(interface: String?, port: UInt16, bindAddress: IPv4Address = IPv4Address(0)) throws -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ToolSocket.lastError("socket UDP") }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, size)
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, size) == 0 else {
            close(fd)
            throw ToolSocket.lastError("option broadcast")
        }
        if let interface, CaptureInterfaceName.isValid(interface) {
            var index = Int32(if_nametoindex(interface))
            if index > 0 { setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size) }
        }
        var addr = ToolSocket.address(bindAddress, port: port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Port local d'une socket liée.
    public static func localPort(_ fd: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    public static func send(_ packet: [UInt8], fd: Int32, to destination: IPv4Address = broadcast, port: UInt16 = serverPort) throws {
        var addr = ToolSocket.address(destination, port: port)
        let sent = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { throw ToolSocket.lastError("envoi du DHCPDISCOVER vers \(destination):\(port)") }
    }

    /// Écoute jusqu'à `deadline` et renvoie les réponses DHCP portant `xid` (avec l'adresse source).
    public static func receive(fd: Int32, xid: UInt32, until deadline: Date, sentAt: Date = Date(),
                               isCancelled: () -> Bool = { false }) -> [DHCPOffer] {
        var offers: [DHCPOffer] = []
        var buffer = [UInt8](repeating: 0, count: 1500)
        while !isCancelled() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            guard ready > 0 else { continue }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) }
                }
            }
            guard count > 0, var offer = DHCPParser.parse(Array(buffer[0..<count])), offer.xid == xid else { continue }
            offer.sourceAddress = IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr))
            offer.delay = Date().timeIntervalSince(sentAt)
            offers.append(offer)
        }
        return offers
    }
}
