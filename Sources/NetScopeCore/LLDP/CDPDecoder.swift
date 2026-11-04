import Foundation

/// Décodage d'une annonce CDP (Cisco Discovery Protocol, version 1 ou 2).
///
/// Trame 802.3 vers 01:00:0C:CC:CC:CC, en-tête LLC/SNAP (AA AA 03, OUI 00-00-0C, PID 0x2000),
/// puis version, TTL, somme de contrôle et des TLV (type 16 bits, longueur 16 bits en-tête compris).
public enum CDPDecoder {
    static let snapHeader: [UInt8] = [0xAA, 0xAA, 0x03, 0x00, 0x00, 0x0C, 0x20, 0x00]

    /// Charge qui suit le champ longueur 802.3 (en-tête LLC/SNAP compris).
    public static func decodeLLC(_ payload: [UInt8]) -> NetworkNeighbor? {
        guard payload.count >= 8, Array(payload[0..<8]) == snapHeader else { return nil }
        return decode(Array(payload[8...]))
    }

    /// Paquet CDP (version, TTL, somme de contrôle, TLV).
    public static func decode(_ packet: [UInt8]) -> NetworkNeighbor? {
        guard packet.count >= 4, packet[0] == 1 || packet[0] == 2 else { return nil }
        var neighbor = NetworkNeighbor(protocols: [.cdp], ttl: Int(packet[1]))
        var offset = 4
        var power: PoEPowerInfo?
        func add(_ info: PoEPowerInfo?) {
            guard let info else { return }
            power = power.map { $0.merged(with: info) } ?? info
        }
        while offset + 4 <= packet.count {
            let type = CaptureBytes.u16(packet, offset)
            let length = Int(CaptureBytes.u16(packet, offset + 2))
            guard length >= 4, offset + length <= packet.count else { break }
            let value = Array(packet[(offset + 4)..<(offset + length)])
            offset += length
            switch type {
            case 0x0001:
                neighbor.systemName = nonEmpty(CaptureBytes.text(value[...]))
            case 0x0002, 0x0016:
                for address in addresses(value) where !neighbor.managementAddresses.contains(address) {
                    // Adresses de gestion (0x0016) d'abord, puis celles de l'interface.
                    if type == 0x0016 { neighbor.managementAddresses.insert(address, at: 0) } else { neighbor.managementAddresses.append(address) }
                }
            case 0x0003:
                neighbor.portID = nonEmpty(CaptureBytes.text(value[...]))
            case 0x0004:
                if value.count >= 4 { neighbor.capabilities = capabilities(CaptureBytes.u32(value, 0)) }
            case 0x0005:
                let text = CaptureBytes.text(value[...])
                neighbor.systemDescription = nonEmpty(text)
                neighbor.softwareVersion = nonEmpty(softwareLine(text))
            case 0x0006:
                neighbor.model = nonEmpty(CaptureBytes.text(value[...]))
            case 0x0009:
                neighbor.vtpDomain = nonEmpty(CaptureBytes.text(value[...]))
            case 0x000A:
                if value.count >= 2 { neighbor.nativeVLAN = Int(CaptureBytes.u16(value, 0)) }
            case 0x000B:
                if let first = value.first { neighbor.duplex = first == 1 ? "Duplex intégral" : "Semi-duplex" }
            case 0x000E:
                // Appliance VLAN-ID : identifiant d'appareil (1 octet) puis VLAN (2 octets), répétés.
                if value.count >= 3 {
                    let vlan = Int(CaptureBytes.u16(value, 1))
                    if vlan > 0 && vlan < 4095 { neighbor.voiceVLAN = vlan }
                }
            case 0x0010:
                add(PoEDecoder.cdpPower(value))
            case 0x0019:
                add(PoEDecoder.cdpPowerRequested(value))
            case 0x001A:
                // Power Available : envoyé par le switch sur un port PoE.
                add(PoEDecoder.cdpPowerAvailable(value))
            default:
                break
            }
        }
        guard neighbor.systemName != nil || neighbor.portID != nil else { return nil }
        neighbor.power = power
        neighbor.poe = power?.summary
        return neighbor
    }

    /// Liste d'adresses : nombre (32 bits), puis type de protocole, longueur, protocole, longueur, adresse.
    static func addresses(_ value: [UInt8]) -> [String] {
        guard value.count >= 4 else { return [] }
        let count = Int(CaptureBytes.u32(value, 0))
        var result: [String] = []
        var offset = 4
        for _ in 0..<min(count, 16) {
            guard offset + 2 <= value.count else { break }
            let protocolLength = Int(value[offset + 1])
            let protocolStart = offset + 2
            guard protocolStart + protocolLength + 2 <= value.count else { break }
            let protocolBytes = Array(value[protocolStart..<(protocolStart + protocolLength)])
            let addressLength = Int(CaptureBytes.u16(value, protocolStart + protocolLength))
            let addressStart = protocolStart + protocolLength + 2
            guard addressStart + addressLength <= value.count else { break }
            let address = Array(value[addressStart..<(addressStart + addressLength)])
            // NLPID 0xCC = IPv4.
            if value[offset] == 1, protocolBytes == [0xCC], address.count == 4 {
                result.append(IPv4Address(CaptureBytes.u32(address, 0)).description)
            }
            offset = addressStart + addressLength
        }
        return result
    }

    static func capabilities(_ bits: UInt32) -> [String] {
        let names: [(UInt32, String)] = [(0x01, "Router"), (0x02, "Bridge"), (0x04, "Bridge source-route"), (0x08, "Switch"),
                                         (0x10, "Hôte"), (0x20, "IGMP"), (0x40, "Répéteur"), (0x80, "Téléphone"),
                                         (0x100, "Géré à distance"), (0x400, "Two-port MAC relay")]
        return names.compactMap { bits & $0.0 != 0 ? $0.1 : nil }
    }

    /// Ligne utile de la version Cisco (« Cisco IOS XE Software, Version 17.09.04a »).
    static func softwareLine(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { $0.contains("Version") } ?? lines.first ?? ""
    }

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}
