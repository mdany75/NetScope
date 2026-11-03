import Darwin
import Foundation

/// Export des résultats d'un scan.
public enum ScanCSV {
    /// En-têtes des colonnes.
    public static let columns = [
        "Statut", "IP", "Nom personnalisé", "Hostname", "Fabricant", "MAC", "Latence (ms)",
        "Ports ouverts", "Switch", "Port", "VLAN", "Type", "Plage", "Première vue", "Dernière vue",
    ]

    /// CSV séparé par des points-virgules (ce qu'attend Excel en français), dates ISO 8601.
    public static func make(_ devices: [Device]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines = [columns.map(escape).joined(separator: ";")]
        for device in devices {
            let latency = device.latencyMs.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
            let fields: [String] = [
                device.isOnline ? "En ligne" : "Hors ligne",
                device.ip.description,
                device.customName ?? "",
                device.hostname ?? "",
                device.vendorLabel,
                device.mac?.formatted(.upperColon) ?? "",
                latency,
                device.openPorts.map(String.init).joined(separator: " "),
                device.switchName ?? "",
                device.switchPort ?? "",
                device.vlan.map(String.init) ?? "",
                device.deviceType.label,
                device.rangeLabel ?? "",
                iso.string(from: device.firstSeen),
                iso.string(from: device.lastSeen),
            ]
            lines.append(fields.map(escape).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Données UTF-8 avec BOM, pour qu'Excel lise correctement les accents.
    public static func data(_ devices: [Device]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(make(devices).utf8)
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Réveil par le réseau (Wake-on-LAN) : paquet magique en UDP diffusé.
public enum ScanWakeOnLAN {
    public enum Failure: Error, LocalizedError, Equatable {
        case socket(Int32)
        case send(Int32)

        public var errorDescription: String? {
            switch self {
            case .socket(let code): return "Impossible d’ouvrir le socket UDP (\(String(cString: strerror(code))))."
            case .send(let code): return "Envoi du paquet magique impossible (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Paquet magique : 6 octets 0xFF puis 16 fois l'adresse MAC (102 octets).
    public static func magicPacket(for mac: MACAddress) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac.bytes, count: 16).joined())
    }

    /// Envoie le paquet magique à `broadcast:port` (par défaut 255.255.255.255:9).
    public static func send(to mac: MACAddress, broadcast: IPv4Address = IPv4Address(255, 255, 255, 255),
                            port: UInt16 = 9) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket(errno) }
        defer { close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = broadcast.value.bigEndian
        let packet = magicPacket(for: mac)
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw Failure.send(errno) }
    }
}
