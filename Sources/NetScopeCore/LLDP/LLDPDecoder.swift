import Foundation

/// Décodage d'une LLDPDU (IEEE 802.1AB) : la charge qui suit l'EtherType 0x88CC.
///
/// TLV : 7 bits de type, 9 bits de longueur. Types 1 à 8 de base, 127 propre à une organisation :
/// 802.1 (00-80-C2 : PVID, noms de VLAN), 802.3 (00-12-0F : MAC/PHY, PoE, taille de trame) et
/// LLDP-MED (00-12-BB : politique réseau voix, PoE étendu, inventaire).
public enum LLDPDecoder {
    static let capabilityNames = ["Autre", "Répéteur", "Bridge", "Point d’accès Wi-Fi", "Router", "Téléphone",
                                  "DOCSIS", "Station", "C-VLAN", "S-VLAN", "TPMR"]

    public static func decode(_ pdu: [UInt8]) -> NetworkNeighbor? {
        var neighbor = NetworkNeighbor(protocols: [.lldp])
        var offset = 0
        var sawChassis = false
        var medModel: String?
        var medManufacturer: String?
        var poeBase: String?
        var poeMED: String?
        while offset + 2 <= pdu.count {
            let header = CaptureBytes.u16(pdu, offset)
            let type = Int(header >> 9)
            let length = Int(header & 0x01FF)
            let start = offset + 2, end = start + length
            guard end <= pdu.count else { break }
            let value = Array(pdu[start..<end])
            offset = end
            switch type {
            case 0:
                offset = pdu.count
            case 1:
                guard !value.isEmpty else { return nil }
                neighbor.chassisID = identifier(subtype: value[0], value[1...], macSubtype: 4, addressSubtype: 5)
                sawChassis = true
            case 2:
                guard !value.isEmpty else { return nil }
                neighbor.portID = identifier(subtype: value[0], value[1...], macSubtype: 3, addressSubtype: 4)
            case 3:
                if value.count >= 2 { neighbor.ttl = Int(CaptureBytes.u16(value, 0)) }
            case 4:
                neighbor.portDescription = nonEmpty(CaptureBytes.text(value[...]))
            case 5:
                neighbor.systemName = nonEmpty(CaptureBytes.text(value[...]))
            case 6:
                neighbor.systemDescription = nonEmpty(CaptureBytes.text(value[...]))
            case 7:
                if value.count >= 4 {
                    let system = CaptureBytes.u16(value, 0)
                    let enabled = CaptureBytes.u16(value, 2)
                    neighbor.capabilities = names(enabled != 0 ? enabled : system)
                }
            case 8:
                if let address = managementAddress(value), !neighbor.managementAddresses.contains(address) {
                    neighbor.managementAddresses.append(address)
                }
            case 127:
                guard value.count >= 4 else { break }
                let oui = UInt32(value[0]) << 16 | UInt32(value[1]) << 8 | UInt32(value[2])
                let subtype = value[3]
                let info = Array(value[4...])
                switch (oui, subtype) {
                case (0x0080C2, 1):
                    if info.count >= 2 {
                        let pvid = Int(CaptureBytes.u16(info, 0))
                        if pvid > 0 { neighbor.nativeVLAN = pvid }
                    }
                case (0x0080C2, 3):
                    if info.count >= 3 {
                        let id = Int(CaptureBytes.u16(info, 0))
                        let nameLength = Int(info[2])
                        let name = CaptureBytes.text(info.dropFirst(3).prefix(nameLength))
                        neighbor.vlanNames.append(name.isEmpty ? "VLAN \(id)" : "\(id) \(name)")
                    }
                case (0x00120F, 1):
                    if info.count >= 5 { neighbor.link = mauLabel(CaptureBytes.u16(info, 3)) }
                case (0x00120F, 2):
                    poeBase = powerViaMDI(info)
                case (0x00120F, 4):
                    if info.count >= 2 { neighbor.maxFrameSize = Int(CaptureBytes.u16(info, 0)) }
                case (0x0012BB, 2):
                    // Politique réseau : application 1 = voix ; 3 octets drapeaux (U, T, X) + VLAN sur 12 bits.
                    if info.count >= 4, info[0] == 1 {
                        let policy = UInt32(info[1]) << 16 | UInt32(info[2]) << 8 | UInt32(info[3])
                        let unknown = policy & 0x80_0000 != 0
                        let vlan = Int((policy >> 9) & 0x0FFF)
                        if !unknown, vlan > 0 { neighbor.voiceVLAN = vlan }
                    }
                case (0x0012BB, 4):
                    if info.count >= 3 {
                        let watts = Double(CaptureBytes.u16(info, 1)) / 10
                        poeMED = "LLDP-MED · \(wattsText(watts))"
                    }
                case (0x0012BB, 7):
                    neighbor.softwareVersion = neighbor.softwareVersion ?? nonEmpty(CaptureBytes.text(info[...]))
                case (0x0012BB, 9):
                    medManufacturer = nonEmpty(CaptureBytes.text(info[...]))
                case (0x0012BB, 10):
                    medModel = nonEmpty(CaptureBytes.text(info[...]))
                default:
                    break
                }
            default:
                break
            }
        }
        guard sawChassis, neighbor.portID != nil else { return nil }
        neighbor.poe = poeBase ?? poeMED
        if let medModel {
            neighbor.model = [medManufacturer, medModel].compactMap { $0 }.joined(separator: " ")
        } else if let description = neighbor.systemDescription {
            neighbor.model = modelFromDescription(description)
        }
        return neighbor
    }

    /// Identifiant de châssis ou de port : MAC, adresse réseau ou texte selon le sous-type.
    static func identifier(subtype: UInt8, _ data: ArraySlice<UInt8>, macSubtype: UInt8, addressSubtype: UInt8) -> String {
        if subtype == macSubtype, data.count == 6 {
            return MACAddress(bytes: Array(data)).formatted(.upperColon)
        }
        if subtype == addressSubtype, let first = data.first {
            let address = Array(data.dropFirst())
            if first == 1, address.count == 4 { return IPv4Address(CaptureBytes.u32(address, 0)).description }
            return CaptureBytes.hex(address[...], separator: ":")
        }
        let text = CaptureBytes.text(data)
        if text.isEmpty || text.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return CaptureBytes.hex(data, separator: ":")
        }
        return text
    }

    /// Adresse de gestion : longueur (1 + adresse), sous-type (1 = IPv4, 2 = IPv6), adresse…
    static func managementAddress(_ value: [UInt8]) -> String? {
        guard value.count >= 2 else { return nil }
        let length = Int(value[0])
        guard length >= 2, value.count >= 1 + length else { return nil }
        let subtype = value[1]
        let address = Array(value[2..<(1 + length)])
        switch (subtype, address.count) {
        case (1, 4): return IPv4Address(CaptureBytes.u32(address, 0)).description
        case (2, 16):
            return stride(from: 0, to: 16, by: 2).map { String(CaptureBytes.u16(address, $0), radix: 16) }.joined(separator: ":")
        case (6, 6): return MACAddress(bytes: address).formatted(.upperColon)
        default: return CaptureBytes.hex(address[...], separator: ":")
        }
    }

    static func names(_ bits: UInt16) -> [String] {
        capabilityNames.enumerated().compactMap { index, name in bits & (1 << index) != 0 ? name : nil }
    }

    /// Power via MDI (802.3) : prise en charge, état, et l'extension 802.3at (puissance allouée).
    static func powerViaMDI(_ info: [UInt8]) -> String? {
        guard info.count >= 3 else { return nil }
        let support = info[0]
        let isPSE = support & 0x01 != 0
        let supported = support & 0x02 != 0
        let enabled = support & 0x04 != 0
        guard supported || isPSE else { return "Pas de PoE" }
        let standard = info.count >= 8 ? "802.3at" : "802.3af"
        guard enabled else { return "\(standard) · désactivé" }
        if info.count >= 8 {
            let allocated = Double(CaptureBytes.u16(info, 6)) / 10
            return allocated > 0 ? "\(standard) · \(wattsText(allocated)) alloués" : "\(standard) · non utilisé"
        }
        let powerClass = Int(info[2])
        return powerClass >= 1 ? "\(standard) · classe \(powerClass - 1)" : standard
    }

    static func wattsText(_ watts: Double) -> String {
        let text = watts == watts.rounded() ? String(Int(watts)) : String(format: "%.1f", watts).replacingOccurrences(of: ".", with: ",")
        return "\(text)\u{00A0}W"
    }

    /// Type MAU (IANA-MAU-MIB) des liens courants.
    static func mauLabel(_ type: UInt16) -> String {
        switch type {
        case 10: return "10BASE-T semi-duplex"
        case 11: return "10BASE-T duplex intégral"
        case 15: return "100BASE-TX semi-duplex"
        case 16: return "100BASE-TX duplex intégral"
        case 29: return "1000BASE-T semi-duplex"
        case 30: return "1000BASE-T duplex intégral"
        default: return "MAU \(type)"
        }
    }

    /// « Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012, … » → avant la virgule.
    static func modelFromDescription(_ description: String) -> String {
        let first = description.split(whereSeparator: { $0 == "," || $0 == "\n" }).first.map(String.init) ?? description
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}
