import Darwin
import Foundation

/// Réveil d'un poste par paquet magique (Wake-on-LAN) : 6 × FF puis 16 fois l'adresse MAC,
/// soit 102 octets, envoyés en UDP vers l'adresse de broadcast du réseau (ports 9 et 7 par défaut).
public enum WakeOnLAN {
    public static let defaultPorts: [UInt16] = [9, 7]
    public static let packetLength = 102

    /// Paquet magique de 102 octets pour cette adresse MAC.
    public static func magicPacket(for mac: MACAddress) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        let bytes = mac.bytes
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Adresse de broadcast par défaut : celle du réseau de l'interface active, sinon 255.255.255.255.
    public static func defaultBroadcast(for interface: LocalInterface?) -> IPv4Address {
        interface?.subnet.broadcast ?? IPv4Address(255, 255, 255, 255)
    }

    /// Envoie le paquet magique vers `broadcast` sur chacun des `ports`. Renvoie le nombre d'octets envoyés.
    @discardableResult
    public static func send(to mac: MACAddress, broadcast: IPv4Address,
                            ports: [UInt16] = WakeOnLAN.defaultPorts) throws -> Int {
        guard !ports.isEmpty else { throw ToolError.invalidInput("Aucun port UDP choisi.") }
        let packet = magicPacket(for: mac)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ToolSocket.lastError("socket UDP") }
        defer { close(fd) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ToolSocket.lastError("option broadcast")
        }
        var total = 0
        for port in ports {
            var addr = ToolSocket.address(broadcast, port: port)
            let sent = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == packet.count else { throw ToolSocket.lastError("envoi vers \(broadcast):\(port)") }
            total += sent
        }
        return total
    }
}
