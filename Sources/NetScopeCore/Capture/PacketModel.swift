import Darwin
import Foundation

// Capture et inspection de paquets (note 7) : modèle commun aux décodeurs, au filtre d'affichage,
// à l'analyse TCP, au suivi de flux et aux statistiques. Aucun accès réseau ici.

/// Protocole reconnu par un décodeur (une couche d'un paquet).
public enum PacketProtocol: String, Sendable, CaseIterable, Codable, Hashable {
    case ethernet, vlan, llc, stp, loopback, linuxSLL, arp, ipv4, ipv6, icmp, icmpv6, igmp, tcp, udp
    case dns, mdns, nbns, dhcp, lldp, cdp, http, ssdp, tls, data

    /// Nom court affiché dans la colonne « Protocole ».
    public var label: String {
        switch self {
        case .ethernet: return "Ethernet"
        case .vlan: return "802.1Q"
        case .llc: return "LLC"
        case .stp: return "STP"
        case .loopback: return "Boucle"
        case .linuxSLL: return "SLL"
        case .arp: return "ARP"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .icmp: return "ICMP"
        case .icmpv6: return "ICMPv6"
        case .igmp: return "IGMP"
        case .tcp: return "TCP"
        case .udp: return "UDP"
        case .dns: return "DNS"
        case .mdns: return "mDNS"
        case .nbns: return "NBNS"
        case .dhcp: return "DHCP"
        case .lldp: return "LLDP"
        case .cdp: return "CDP"
        case .http: return "HTTP"
        case .ssdp: return "SSDP"
        case .tls: return "TLS"
        case .data: return "Données"
        }
    }

    /// Nom employé dans le filtre d'affichage (« tcp », « ip », « tls »…).
    public var filterName: String {
        switch self {
        case .ethernet: return "eth"
        case .ipv4: return "ip"
        case .linuxSLL: return "sll"
        default: return rawValue
        }
    }

    public static func named(_ name: String) -> PacketProtocol? {
        let lowered = name.lowercased()
        if lowered == "ipv4" { return .ipv4 }
        if lowered == "nbt" || lowered == "netbios" { return .nbns }
        if lowered == "ssl" { return .tls }
        if lowered == "bootp" { return .dhcp }
        return allCases.first { $0.filterName == lowered }
    }
}

/// Un champ décodé : nom, valeur lisible, position et longueur dans les octets du paquet (pour
/// surligner l'hexadécimal), et ses sous-champs.
public struct PacketField: Sendable, Equatable, Identifiable {
    /// Numéro unique dans le paquet (attribué après le décodage, en profondeur d'abord).
    public var id: Int = 0
    public var name: String
    public var value: String
    public var offset: Int
    public var length: Int
    public var children: [PacketField]

    public init(_ name: String, _ value: String, _ offset: Int, _ length: Int, children: [PacketField] = []) {
        self.name = name
        self.value = value
        self.offset = offset
        self.length = max(0, length)
        self.children = children
    }

    public var range: Range<Int> { offset..<(offset + length) }

    /// « Port source : 443 » (espace insécable avant le deux-points) ; le nom seul sans valeur.
    public var text: String { value.isEmpty ? name : "\(name)\u{00A0}: \(value)" }

    /// Sous-champs pour une arborescence (nil : feuille).
    public var childrenOrNil: [PacketField]? { children.isEmpty ? nil : children }

    /// Le champ le plus profond qui contient l'octet `byte` (clic dans la vue hexadécimale).
    /// Les sous-champs sont cherchés même hors de la plage du parent (remplissage en fin de trame).
    public func deepest(containing byte: Int) -> PacketField? {
        for child in children { if let found = child.deepest(containing: byte) { return found } }
        return length > 0 && range.contains(byte) ? self : nil
    }

    /// Champ de numéro `id` dans ce sous-arbre.
    public func find(_ id: Int) -> PacketField? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }
}

/// Une couche du paquet (Ethernet, IPv4, TCP, TLS…) : un champ racine et son protocole.
public struct PacketLayer: Sendable, Equatable {
    public var kind: PacketProtocol
    public var node: PacketField

    public init(_ kind: PacketProtocol, title: String, _ offset: Int, _ length: Int, fields: [PacketField]) {
        self.kind = kind
        node = PacketField(title, "", offset, length, children: fields)
    }
}

/// En-tête TCP décodé (pour l'analyse et le filtre).
public struct TCPSegmentInfo: Sendable, Equatable {
    public var sequence: UInt32
    public var acknowledgment: UInt32
    public var flags: UInt16
    public var window: UInt16
    public var payloadLength: Int

    public static let fin: UInt16 = 0x001, syn: UInt16 = 0x002, rst: UInt16 = 0x004, psh: UInt16 = 0x008
    public static let ack: UInt16 = 0x010, urg: UInt16 = 0x020, ece: UInt16 = 0x040, cwr: UInt16 = 0x080

    public func has(_ flag: UInt16) -> Bool { flags & flag != 0 }

    /// « SYN, ACK » (ordre de Wireshark).
    public var flagNames: String {
        var names: [String] = []
        if has(Self.fin) { names.append("FIN") }
        if has(Self.syn) { names.append("SYN") }
        if has(Self.rst) { names.append("RST") }
        if has(Self.psh) { names.append("PSH") }
        if has(Self.ack) { names.append("ACK") }
        if has(Self.urg) { names.append("URG") }
        if has(Self.ece) { names.append("ECE") }
        if has(Self.cwr) { names.append("CWR") }
        return names.joined(separator: ", ")
    }

    /// Longueur dans l'espace des numéros de séquence (SYN et FIN comptent pour un).
    public var sequenceLength: UInt32 {
        UInt32(payloadLength) + (has(Self.syn) ? 1 : 0) + (has(Self.fin) ? 1 : 0)
    }
}

/// Transport (TCP ou UDP) : ports et position de la charge utile.
public struct TransportInfo: Sendable, Equatable {
    public var kind: PacketProtocol
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payloadOffset: Int
    public var payloadLength: Int
}

/// Un paquet décodé : couches, adresses, résumé d'une ligne et clés utiles aux filtres.
public struct DecodedPacket: Sendable, Equatable {
    public var layers: [PacketLayer] = []
    /// Protocoles reconnus, de la couche liaison à la couche application.
    public var protocols: [PacketProtocol] = []
    public var source = ""
    public var destination = ""
    public var summary = ""
    public var ethSource: MACAddress?
    public var ethDestination: MACAddress?
    public var vlanIDs: [Int] = []
    public var ipSource: String?
    public var ipDestination: String?
    public var ipVersion: Int?
    public var ipProtocol: UInt8?
    public var ttl: Int?
    public var transport: TransportInfo?
    public var tcp: TCPSegmentInfo?
    public var dnsNames: [String] = []
    public var tlsServerName: String?
    public var tlsHandshake: String?
    public var httpHost: String?
    public var httpRequest: String?
    public var httpStatus: Int?
    public var arpOperation: Int?
    /// Problèmes de décodage (paquet tronqué, longueur incohérente).
    public var problems: [String] = []

    public init() {}

    /// Protocole le plus haut (colonne « Protocole »).
    public var topProtocol: PacketProtocol { protocols.last ?? .data }

    public func contains(_ kind: PacketProtocol) -> Bool { protocols.contains(kind) }

    /// Les champs racines de toutes les couches.
    public var roots: [PacketField] { layers.map(\.node) }

    public func field(_ id: Int) -> PacketField? {
        for layer in layers { if let found = layer.node.find(id) { return found } }
        return nil
    }

    /// Champ le plus profond qui contient l'octet `byte`.
    public func deepestField(containing byte: Int) -> PacketField? {
        for layer in layers.reversed() { if let found = layer.node.deepest(containing: byte) { return found } }
        return nil
    }

    /// Premier champ dont le nom correspond (recherche en profondeur), pour la démonstration et les tests.
    public func firstField(named name: String) -> PacketField? {
        func search(_ field: PacketField) -> PacketField? {
            if field.name == name { return field }
            for child in field.children { if let found = search(child) { return found } }
            return nil
        }
        for layer in layers { if let found = search(layer.node) { return found } }
        return nil
    }

    /// Numérote tous les champs (identifiants stables pour l'arborescence et la sélection).
    mutating func number() {
        var next = 1
        func visit(_ field: inout PacketField) {
            field.id = next
            next += 1
            for index in field.children.indices { visit(&field.children[index]) }
        }
        for index in layers.indices { visit(&layers[index].node) }
    }
}

/// Lecture sûre dans les octets d'un paquet : jamais de lecture hors limites.
struct ByteView {
    let bytes: [UInt8]

    var count: Int { bytes.count }

    func has(_ offset: Int, _ length: Int) -> Bool { offset >= 0 && length >= 0 && offset + length <= bytes.count }
    func u8(_ i: Int) -> UInt8 { CaptureBytes.u8(bytes, i) }
    func u16(_ i: Int) -> UInt16 { CaptureBytes.u16(bytes, i) }
    func u32(_ i: Int) -> UInt32 { CaptureBytes.u32(bytes, i) }
    func u24(_ i: Int) -> UInt32 { UInt32(u8(i)) << 16 | UInt32(u8(i + 1)) << 8 | UInt32(u8(i + 2)) }

    /// Tranche bornée aux octets présents.
    func slice(_ offset: Int, _ length: Int) -> ArraySlice<UInt8> {
        let start = min(max(0, offset), bytes.count)
        let end = min(max(start, offset + length), bytes.count)
        return bytes[start..<end]
    }

    func array(_ offset: Int, _ length: Int) -> [UInt8] { Array(slice(offset, length)) }

    func mac(_ offset: Int) -> MACAddress { MACAddress(bytes: array(offset, 6) + [UInt8](repeating: 0, count: max(0, 6 - slice(offset, 6).count))) }

    func ipv4(_ offset: Int) -> IPv4Address { IPv4Address(u32(offset)) }

    func ipv6(_ offset: Int) -> String { PacketText.ipv6(array(offset, 16)) }

    func hex(_ offset: Int, _ length: Int, separator: String = " ") -> String {
        CaptureBytes.hex(slice(offset, length), separator: separator).lowercased()
    }

    func text(_ offset: Int, _ length: Int) -> String { CaptureBytes.text(slice(offset, length)) }
}

/// Mise en forme commune des valeurs (français, espaces insécables).
public enum PacketText {
    /// Adresse IPv6 en notation compacte (inet_ntop, RFC 5952).
    public static func ipv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "?" }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { raw in for i in 0..<16 { raw[i] = bytes[i] } }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    /// « 0x1a2b ».
    public static func hex(_ value: UInt32, digits: Int = 4) -> String { "0x" + String(format: "%0\(digits)x", value) }

    /// « 1 234 » (espace insécable fine entre les milliers).
    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// « 1,2 Ko », « 3,4 Mo ».
    public static func bytes(_ value: Int) -> String {
        if value < 1024 { return "\(value)\u{00A0}o" }
        let units = ["Ko", "Mo", "Go"]
        var size = Double(value) / 1024
        var unit = 0
        while size >= 1024, unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: "%.1f", size).replacingOccurrences(of: ".", with: ",") + "\u{00A0}" + units[unit]
    }

    /// « 1,204518 » (secondes, six décimales, virgule française).
    public static func seconds(_ value: Double, decimals: Int = 6) -> String {
        String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « 5 octets » / « 1 octet ».
    public static func octets(_ count: Int) -> String { count == 1 ? "1\u{00A0}octet" : "\(number(count))\u{00A0}octets" }

    /// Caractère affichable de la colonne ASCII (« . » sinon).
    public static func ascii(_ byte: UInt8) -> Character {
        byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : "."
    }
}
