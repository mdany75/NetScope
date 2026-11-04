import Foundation

/// Types de liaison des fichiers pcap (LINKTYPE_*) que NetScope sait décoder.
public enum PcapLinkType {
    public static let null: UInt32 = 0
    public static let ethernet: UInt32 = 1
    public static let rawAlt: UInt32 = 12
    public static let raw: UInt32 = 101
    public static let loop: UInt32 = 108
    public static let linuxSLL: UInt32 = 113
    public static let ipv4: UInt32 = 228
    public static let ipv6: UInt32 = 229

    public static func label(_ type: UInt32) -> String {
        switch type {
        case ethernet: return "Ethernet"
        case null, loop: return "Boucle locale (BSD)"
        case raw, rawAlt: return "IP brut"
        case linuxSLL: return "Linux « cooked »"
        case ipv4: return "IPv4 brut"
        case ipv6: return "IPv6 brut"
        default: return "type \(type)"
        }
    }
}

/// Décodage d'un paquet en couches (Ethernet, 802.1Q, ARP, IPv4/IPv6, ICMP, TCP, UDP, DNS, DHCP,
/// LLDP/CDP, NetBIOS-NS, mDNS, HTTP, TLS…). Chaque couche donne un arbre de champs avec leur
/// position dans les octets et le paquet un résumé d'une ligne. Ne lève jamais d'erreur : un paquet
/// tronqué ou incohérent est décodé aussi loin que possible, le reste est noté dans `problems`.
public enum PacketDecoder {
    public static func decode(_ bytes: [UInt8], linkType: UInt32 = PcapLinkType.ethernet) -> DecodedPacket {
        var decoding = PacketDecoding(bytes)
        decoding.link(linkType)
        decoding.finish()
        return decoding.packet
    }
}

/// Somme de contrôle Internet (RFC 1071).
enum InternetChecksum {
    static func sum(_ bytes: ArraySlice<UInt8>, initial: UInt32 = 0) -> UInt32 {
        var sum = initial
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            // Repli à chaque mot : une très longue trame (16 Mio) ne déborde plus.
            if sum >> 31 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
            index += 2
        }
        if index < bytes.endIndex {
            sum += UInt32(bytes[index]) << 8
            if sum >> 31 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        }
        return sum
    }

    static func fold(_ value: UInt32) -> UInt16 {
        var sum = value
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func checksum(_ bytes: ArraySlice<UInt8>, initial: UInt32 = 0) -> UInt16 { fold(sum(bytes, initial: initial)) }
}

struct PacketDecoding {
    let b: ByteView
    var packet = DecodedPacket()
    /// Fin des données IP (le reste de la trame est du remplissage Ethernet).
    private var ipEnd: Int?
    private var ethernetLayer: Int?
    /// En-tête IP (pour le pseudo-en-tête des sommes TCP/UDP).
    private var pseudoHeader: UInt32?

    init(_ bytes: [UInt8]) { b = ByteView(bytes: bytes) }

    // MARK: Outils

    mutating func add(_ kind: PacketProtocol, _ title: String, _ offset: Int, _ length: Int, _ fields: [PacketField]) {
        packet.layers.append(PacketLayer(kind, title: title, offset, length, fields: fields))
        if kind != .data, !packet.protocols.contains(kind) || kind == .vlan { packet.protocols.append(kind) }
    }

    mutating func truncated(_ what: String) {
        packet.problems.append("\(what)\u{00A0}: paquet tronqué")
    }

    mutating func data(_ offset: Int, _ end: Int, title: String = "Données") {
        let length = end - offset
        guard length > 0 else { return }
        let preview = b.hex(offset, min(length, 24), separator: "") + (length > 24 ? "…" : "")
        add(.data, "\(title) (\(PacketText.octets(length)))", offset, length, [
            PacketField("Données", preview, offset, length),
            PacketField("Longueur", PacketText.octets(length), offset, length),
        ])
    }

    mutating func finish() {
        if let ipEnd, let ethernetLayer, ipEnd < b.count {
            let length = b.count - ipEnd
            let allZero = b.slice(ipEnd, length).allSatisfy { $0 == 0 }
            packet.layers[ethernetLayer].node.children.append(
                PacketField(allZero ? "Remplissage" : "Fin de trame", b.hex(ipEnd, min(length, 16), separator: "") + (length > 16 ? "…" : ""), ipEnd, length))
        }
        if packet.summary.isEmpty { packet.summary = packet.layers.last?.node.name ?? "Trame de \(PacketText.octets(b.count))" }
        packet.number()
    }

    // MARK: Liaison

    mutating func link(_ type: UInt32) {
        switch type {
        case PcapLinkType.ethernet: ethernet(0)
        case PcapLinkType.null, PcapLinkType.loop:
            guard b.has(0, 4) else { truncated("Boucle locale"); return }
            let little = CaptureBytes.le32(b.bytes, 0), big = b.u32(0)
            let family = [2, 24, 28, 30].contains(Int(little)) ? little : big
            let name = family == 2 ? "IPv4" : [24, 28, 30].contains(Int(family)) ? "IPv6" : "\(family)"
            add(.loopback, "Boucle locale, famille \(name)", 0, 4, [PacketField("Famille d’adresses", name, 0, 4)])
            if family == 2 { ipv4(4, b.count) } else if [24, 28, 30].contains(Int(family)) { ipv6(4, b.count) } else { data(4, b.count) }
        case PcapLinkType.raw, PcapLinkType.rawAlt, PcapLinkType.ipv4, PcapLinkType.ipv6: rawIP(0)
        case PcapLinkType.linuxSLL:
            guard b.has(0, 16) else { truncated("Linux SLL"); return }
            let proto = b.u16(14)
            add(.linuxSLL, "Linux « cooked », protocole \(PacketText.hex(UInt32(proto)))", 0, 16, [
                PacketField("Type de paquet", "\(b.u16(0))", 0, 2),
                PacketField("Type d’adresse", "\(b.u16(2))", 2, 2),
                PacketField("Adresse source", b.hex(6, Int(min(8, b.u16(4))), separator: ":"), 6, 8),
                PacketField("Protocole", etherTypeName(proto), 14, 2),
            ])
            etherType(proto, 16, b.count)
        default:
            data(0, b.count, title: "Trame (\(PcapLinkType.label(type)))")
        }
    }

    mutating func rawIP(_ offset: Int) {
        switch b.u8(offset) >> 4 {
        case 4: ipv4(offset, b.count)
        case 6: ipv6(offset, b.count)
        default: data(offset, b.count)
        }
    }

    mutating func ethernet(_ o: Int) {
        guard b.has(o, 14) else { truncated("Ethernet"); data(o, b.count); return }
        let destination = b.mac(o), source = b.mac(o + 6)
        packet.ethDestination = destination
        packet.ethSource = source
        packet.source = source.formatted()
        packet.destination = destination.isBroadcast ? "Diffusion" : destination.formatted()
        let type = b.u16(o + 12)
        var fields = [
            PacketField("Destination", macLabel(destination), o, 6),
            PacketField("Source", macLabel(source), o + 6, 6),
        ]
        if type < 0x0600 {
            fields.append(PacketField("Longueur", "\(type)", o + 12, 2))
            ethernetLayer = packet.layers.count
            add(.ethernet, "IEEE 802.3 Ethernet, \(source.formatted()) → \(destination.formatted())", o, 14, fields)
            let end = min(b.count, o + 14 + Int(type))
            ipEnd = end
            llc(o + 14, end)
        } else {
            fields.append(PacketField("Type", etherTypeName(type), o + 12, 2))
            ethernetLayer = packet.layers.count
            add(.ethernet, "Ethernet II, \(source.formatted()) → \(destination.formatted())", o, 14, fields)
            etherType(type, o + 14, b.count)
        }
    }

    private func macLabel(_ mac: MACAddress) -> String {
        if mac.isBroadcast { return "ff:ff:ff:ff:ff:ff (diffusion)" }
        if mac.isMulticast { return "\(mac.formatted()) (multidiffusion)" }
        return mac.formatted()
    }

    func etherTypeName(_ type: UInt16) -> String {
        let name: String
        switch type {
        case 0x0800: name = "IPv4"
        case 0x86DD: name = "IPv6"
        case 0x0806: name = "ARP"
        case 0x8035: name = "RARP"
        case 0x8100: name = "802.1Q (VLAN)"
        case 0x88A8: name = "802.1ad (QinQ)"
        case 0x88CC: name = "LLDP"
        case 0x888E: name = "802.1X (EAPOL)"
        case 0x8809: name = "Protocoles lents (LACP)"
        case 0x88F7: name = "PTP"
        case 0x8847: name = "MPLS"
        case 0x8864: name = "PPPoE"
        default: name = "inconnu"
        }
        return "\(name) (\(PacketText.hex(UInt32(type))))"
    }

    mutating func etherType(_ type: UInt16, _ o: Int, _ end: Int) {
        switch type {
        case 0x0800: ipv4(o, end)
        case 0x86DD: ipv6(o, end)
        case 0x0806: arp(o, end)
        case 0x88CC: lldp(o, end)
        case 0x8100, 0x88A8: vlan(o, end, outer: type)
        default:
            data(o, end)
            packet.summary = "Ethernet, type \(etherTypeName(type))"
        }
    }

    mutating func vlan(_ o: Int, _ end: Int, outer: UInt16) {
        guard b.has(o, 4) else { truncated("802.1Q"); return }
        let tci = b.u16(o)
        let priority = Int(tci >> 13), dei = Int(tci >> 12 & 1), id = Int(tci & 0x0FFF)
        let type = b.u16(o + 2)
        packet.vlanIDs.append(id)
        add(.vlan, "802.1Q (VLAN \(id)), priorité \(priority)", o, 4, [
            PacketField("Priorité (PCP)", "\(priority)", o, 2),
            PacketField("DEI", "\(dei)", o, 2),
            PacketField("Identifiant de VLAN", "\(id)", o, 2),
            PacketField("Type", etherTypeName(type), o + 2, 2),
        ])
        etherType(type, o + 4, end)
    }

    mutating func llc(_ o: Int, _ end: Int) {
        guard b.has(o, 3) else { truncated("LLC"); return }
        let dsap = b.u8(o), ssap = b.u8(o + 1), control = b.u8(o + 2)
        var fields = [
            PacketField("DSAP", PacketText.hex(UInt32(dsap), digits: 2), o, 1),
            PacketField("SSAP", PacketText.hex(UInt32(ssap), digits: 2), o + 1, 1),
            PacketField("Contrôle", PacketText.hex(UInt32(control), digits: 2), o + 2, 1),
        ]
        if dsap == 0xAA, ssap == 0xAA, b.has(o, 8) {
            let oui = b.u24(o + 3), pid = b.u16(o + 6)
            fields.append(PacketField("OUI", oui == 0x00000C ? "00:00:0c (Cisco)" : b.hex(o + 3, 3, separator: ":"), o + 3, 3))
            fields.append(PacketField("Identifiant de protocole", PacketText.hex(UInt32(pid)), o + 6, 2))
            add(.llc, "LLC / SNAP", o, 8, fields)
            if oui == 0x00000C, pid == 0x2000 { cdp(o + 8, end) } else if oui == 0 { etherType(pid, o + 8, end) } else { data(o + 8, end) }
        } else if dsap == 0x42, ssap == 0x42 {
            add(.llc, "LLC, DSAP STP", o, 3, fields)
            stp(o + 3, end)
        } else {
            add(.llc, "LLC", o, 3, fields)
            data(o + 3, end)
        }
    }

    // MARK: ARP

    mutating func arp(_ o: Int, _ end: Int) {
        guard b.has(o, 28) else { truncated("ARP"); data(o, end); return }
        let operation = Int(b.u16(o + 6))
        let senderMAC = b.mac(o + 8), senderIP = b.ipv4(o + 14), targetMAC = b.mac(o + 18), targetIP = b.ipv4(o + 24)
        packet.arpOperation = operation
        let opName: String
        switch operation {
        case 1: opName = "requête"
        case 2: opName = "réponse"
        case 3: opName = "requête RARP"
        case 4: opName = "réponse RARP"
        default: opName = "opération \(operation)"
        }
        let gratuitous = senderIP == targetIP
        add(.arp, "ARP, \(opName)" + (gratuitous ? " gratuite" : ""), o, 28, [
            PacketField("Type de matériel", b.u16(o) == 1 ? "Ethernet (1)" : "\(b.u16(o))", o, 2),
            PacketField("Type de protocole", etherTypeName(b.u16(o + 2)), o + 2, 2),
            PacketField("Taille matérielle", "\(b.u8(o + 4))", o + 4, 1),
            PacketField("Taille du protocole", "\(b.u8(o + 5))", o + 5, 1),
            PacketField("Opération", "\(opName) (\(operation))", o + 6, 2),
            PacketField("MAC de l’émetteur", senderMAC.formatted(), o + 8, 6),
            PacketField("IP de l’émetteur", senderIP.description, o + 14, 4),
            PacketField("MAC de la cible", targetMAC.formatted(), o + 18, 6),
            PacketField("IP de la cible", targetIP.description, o + 24, 4),
        ])
        ipEnd = o + 28
        switch operation {
        case 1 where gratuitous: packet.summary = "ARP gratuit pour \(senderIP)"
        case 1: packet.summary = "Qui a \(targetIP)\u{00A0}? Répondre à \(senderIP)"
        case 2: packet.summary = "\(senderIP) est à \(senderMAC.formatted())"
        default: packet.summary = "ARP \(opName)"
        }
    }

    // MARK: IP

    mutating func ipv4(_ o: Int, _ end: Int) {
        guard b.has(o, 20), end - o >= 20 else { truncated("IPv4"); data(o, end); return }
        let ihl = Int(b.u8(o) & 0x0F) * 4
        guard ihl >= 20, b.has(o, ihl) else { packet.problems.append("IPv4\u{00A0}: longueur d’en-tête invalide (\(ihl))"); data(o, end); return }
        let total = Int(b.u16(o + 2))
        var layerEnd = end
        if total >= ihl, o + total <= end { layerEnd = o + total } else if total > end - o { packet.problems.append("IPv4\u{00A0}: paquet tronqué (\(total) octets annoncés)") }
        ipEnd = layerEnd
        let id = b.u16(o + 4), flagsWord = b.u16(o + 6)
        let df = flagsWord & 0x4000 != 0, mf = flagsWord & 0x2000 != 0
        let fragmentOffset = Int(flagsWord & 0x1FFF) * 8
        let ttl = Int(b.u8(o + 8)), proto = b.u8(o + 9), checksum = b.u16(o + 10)
        let source = b.ipv4(o + 12), destination = b.ipv4(o + 16)
        let computed = InternetChecksum.checksum(b.slice(o, ihl))
        let checksumText = PacketText.hex(UInt32(checksum)) + (computed == 0 ? " (correcte)" : checksum == 0 ? " (non calculée\u{00A0}: déchargement matériel)" : " (incorrecte)")
        let dscp = b.u8(o + 1) >> 2, ecn = b.u8(o + 1) & 3
        var flagNames: [String] = []
        if df { flagNames.append("ne pas fragmenter") }
        if mf { flagNames.append("autres fragments") }
        var fields = [
            PacketField("Version", "4", o, 1),
            PacketField("Longueur d’en-tête", "\(ihl)\u{00A0}octets", o, 1),
            PacketField("Services différenciés", "DSCP \(dscp), ECN \(ecn)", o + 1, 1),
            PacketField("Longueur totale", "\(total)", o + 2, 2),
            PacketField("Identification", "\(PacketText.hex(UInt32(id))) (\(id))", o + 4, 2),
            PacketField("Drapeaux", flagNames.isEmpty ? "aucun" : flagNames.joined(separator: ", "), o + 6, 2, children: [
                PacketField("Ne pas fragmenter (DF)", df ? "oui" : "non", o + 6, 1),
                PacketField("Autres fragments (MF)", mf ? "oui" : "non", o + 6, 1),
            ]),
            PacketField("Décalage du fragment", "\(fragmentOffset)", o + 6, 2),
            PacketField("Durée de vie (TTL)", "\(ttl)", o + 8, 1),
            PacketField("Protocole", ipProtocolName(proto), o + 9, 1),
            PacketField("Somme de contrôle de l’en-tête", checksumText, o + 10, 2),
            PacketField("Adresse source", source.description, o + 12, 4),
            PacketField("Adresse de destination", destination.description, o + 16, 4),
        ]
        if ihl > 20 { fields.append(PacketField("Options", b.hex(o + 20, ihl - 20, separator: ""), o + 20, ihl - 20)) }
        packet.ipVersion = 4
        packet.ipSource = source.description
        packet.ipDestination = destination.description
        packet.ipProtocol = proto
        packet.ttl = ttl
        packet.source = source.description
        packet.destination = destination.description
        add(.ipv4, "IPv4, \(source) → \(destination)", o, ihl, fields)
        pseudoHeader = InternetChecksum.sum(b.slice(o + 12, 8)) + UInt32(proto) + UInt32(max(0, layerEnd - o - ihl))
        if fragmentOffset > 0 {
            data(o + ihl, layerEnd, title: "Fragment IPv4")
            packet.summary = "Fragment IPv4 (protocole \(proto), décalage \(fragmentOffset), ID \(PacketText.hex(UInt32(id))))"
            return
        }
        if mf { packet.problems.append("Premier fragment IPv4\u{00A0}: la suite est dans d’autres paquets") }
        ipPayload(proto, o + ihl, layerEnd, version: 4)
    }

    func ipProtocolName(_ proto: UInt8) -> String {
        let name: String
        switch proto {
        case 0: name = "Hop-by-Hop"
        case 1: name = "ICMP"
        case 2: name = "IGMP"
        case 6: name = "TCP"
        case 17: name = "UDP"
        case 41: name = "IPv6"
        case 43: name = "Routage IPv6"
        case 44: name = "Fragment IPv6"
        case 47: name = "GRE"
        case 50: name = "ESP"
        case 51: name = "AH"
        case 58: name = "ICMPv6"
        case 59: name = "Aucun en-tête suivant"
        case 60: name = "Options de destination"
        case 89: name = "OSPF"
        case 103: name = "PIM"
        case 112: name = "VRRP"
        case 132: name = "SCTP"
        default: name = "inconnu"
        }
        return "\(name) (\(proto))"
    }

    mutating func ipv6(_ o: Int, _ end: Int) {
        guard b.has(o, 40), end - o >= 40 else { truncated("IPv6"); data(o, end); return }
        let first = b.u32(o)
        let trafficClass = (first >> 20) & 0xFF, flowLabel = first & 0xFFFFF
        let payloadLength = Int(b.u16(o + 4))
        var next = b.u8(o + 6)
        let hopLimit = Int(b.u8(o + 7))
        let source = b.ipv6(o + 8), destination = b.ipv6(o + 24)
        var layerEnd = end
        if o + 40 + payloadLength <= end { layerEnd = o + 40 + payloadLength } else { packet.problems.append("IPv6\u{00A0}: paquet tronqué") }
        ipEnd = layerEnd
        var fields = [
            PacketField("Version", "6", o, 1),
            PacketField("Classe de trafic", PacketText.hex(trafficClass, digits: 2), o, 2),
            PacketField("Étiquette de flux", PacketText.hex(flowLabel, digits: 5), o + 1, 3),
            PacketField("Longueur de la charge", "\(payloadLength)", o + 4, 2),
            PacketField("En-tête suivant", ipProtocolName(next), o + 6, 1),
            PacketField("Limite de sauts", "\(hopLimit)", o + 7, 1),
            PacketField("Adresse source", source, o + 8, 16),
            PacketField("Adresse de destination", destination, o + 24, 16),
        ]
        var p = o + 40
        var fragmentOffset = 0
        var guardCount = 0
        // En-têtes d'extension : Hop-by-Hop, routage, options de destination, fragment.
        while [0, 43, 60, 44].contains(next), b.has(p, 8), guardCount < 8 {
            guardCount += 1
            let headerNext = b.u8(p)
            let length = next == 44 ? 8 : (Int(b.u8(p + 1)) + 1) * 8
            guard p + length <= layerEnd else { break }
            var children = [PacketField("En-tête suivant", ipProtocolName(headerNext), p, 1)]
            if next == 44 {
                fragmentOffset = Int(b.u16(p + 2) >> 3) * 8
                children.append(PacketField("Décalage", "\(fragmentOffset)", p + 2, 2))
                children.append(PacketField("Identification", PacketText.hex(b.u32(p + 4), digits: 8), p + 4, 4))
            }
            fields.append(PacketField("En-tête d’extension", ipProtocolName(next), p, length, children: children))
            next = headerNext
            p += length
        }
        packet.ipVersion = 6
        packet.ipSource = source
        packet.ipDestination = destination
        packet.ipProtocol = next
        packet.ttl = hopLimit
        packet.source = source
        packet.destination = destination
        add(.ipv6, "IPv6, \(source) → \(destination)", o, p - o, fields)
        var pseudo = InternetChecksum.sum(b.slice(o + 8, 32))
        pseudo += UInt32(max(0, layerEnd - p)) + UInt32(next)
        pseudoHeader = pseudo
        if fragmentOffset > 0 {
            data(p, layerEnd, title: "Fragment IPv6")
            packet.summary = "Fragment IPv6 (décalage \(fragmentOffset))"
            return
        }
        ipPayload(next, p, layerEnd, version: 6)
    }

    mutating func ipPayload(_ proto: UInt8, _ o: Int, _ end: Int, version: Int) {
        switch proto {
        case 1 where version == 4: icmp(o, end)
        case 2 where version == 4: igmp(o, end)
        case 6: tcp(o, end)
        case 17: udp(o, end)
        case 58 where version == 6: icmpv6(o, end)
        default:
            data(o, end)
            packet.summary = "IPv\(version), protocole \(ipProtocolName(proto))"
        }
    }

    // MARK: ICMP, ICMPv6, IGMP

    mutating func icmp(_ o: Int, _ end: Int) {
        guard end - o >= 4, b.has(o, 4) else { truncated("ICMP"); return }
        let type = b.u8(o), code = b.u8(o + 1), checksum = b.u16(o + 2)
        let valid = InternetChecksum.checksum(b.slice(o, end - o)) == 0
        let (typeName, codeName) = icmpNames(type, code)
        var fields = [
            PacketField("Type", "\(typeName) (\(type))", o, 1),
            PacketField("Code", codeName.map { "\($0) (\(code))" } ?? "\(code)", o + 1, 1),
            PacketField("Somme de contrôle", PacketText.hex(UInt32(checksum)) + (valid ? " (correcte)" : " (incorrecte)"), o + 2, 2),
        ]
        var summary = typeName + (codeName.map { " (\($0))" } ?? "")
        if (type == 0 || type == 8), b.has(o, 8) {
            let id = b.u16(o + 4), seq = b.u16(o + 6)
            fields.append(PacketField("Identifiant", "\(PacketText.hex(UInt32(id))) (\(id))", o + 4, 2))
            fields.append(PacketField("Numéro de séquence", "\(seq)", o + 6, 2))
            if end - o > 8 { fields.append(PacketField("Données", PacketText.octets(end - o - 8), o + 8, end - o - 8)) }
            summary += " id=\(PacketText.hex(UInt32(id))) séq=\(seq)" + (packet.ttl.map { " ttl=\($0)" } ?? "")
        } else if [3, 5, 11, 12].contains(type), b.has(o, 8) {
            if type == 3, code == 4 { fields.append(PacketField("MTU du saut suivant", "\(b.u16(o + 6))", o + 6, 2)) }
            if type == 5 { fields.append(PacketField("Passerelle", b.ipv4(o + 4).description, o + 4, 4)) }
            let inner = o + 8
            if b.has(inner, 20), b.u8(inner) >> 4 == 4 {
                let ihl = Int(b.u8(inner) & 0x0F) * 4
                let proto = b.u8(inner + 9)
                var text = "\(b.ipv4(inner + 12)) → \(b.ipv4(inner + 16)), \(ipProtocolName(proto))"
                if proto == 6 || proto == 17, b.has(inner + ihl, 4) { text += ", port \(b.u16(inner + ihl)) → \(b.u16(inner + ihl + 2))" }
                fields.append(PacketField("Paquet d’origine", text, inner, end - inner))
                summary += " · \(text)"
            }
        }
        add(.icmp, "ICMP, \(typeName)", o, end - o, fields)
        packet.summary = summary
    }

    func icmpNames(_ type: UInt8, _ code: UInt8) -> (String, String?) {
        switch type {
        case 0: return ("Réponse d’écho", nil)
        case 8: return ("Demande d’écho", nil)
        case 3:
            let codes = [0: "réseau inaccessible", 1: "hôte inaccessible", 2: "protocole inaccessible", 3: "port inaccessible",
                         4: "fragmentation nécessaire", 9: "réseau interdit", 10: "hôte interdit", 13: "filtré par l’administrateur"]
            return ("Destination inaccessible", codes[Int(code)])
        case 5: return ("Redirection", nil)
        case 11: return ("Temps dépassé", code == 0 ? "TTL épuisé en transit" : "réassemblage")
        case 12: return ("Problème de paramètre", nil)
        case 13: return ("Demande d’horodatage", nil)
        case 14: return ("Réponse d’horodatage", nil)
        default: return ("Type \(type)", nil)
        }
    }

    mutating func icmpv6(_ o: Int, _ end: Int) {
        guard end - o >= 4, b.has(o, 4) else { truncated("ICMPv6"); return }
        let type = b.u8(o), code = b.u8(o + 1), checksum = b.u16(o + 2)
        let valid = pseudoHeader.map { InternetChecksum.checksum(b.slice(o, end - o), initial: $0) == 0 } ?? false
        var fields = [
            PacketField("Type", "\(icmpv6Name(type)) (\(type))", o, 1),
            PacketField("Code", "\(code)", o + 1, 1),
            PacketField("Somme de contrôle", PacketText.hex(UInt32(checksum)) + (valid ? " (correcte)" : " (incorrecte)"), o + 2, 2),
        ]
        var summary = icmpv6Name(type)
        var options = o + 4
        switch type {
        case 128, 129:
            if b.has(o, 8) {
                fields.append(PacketField("Identifiant", PacketText.hex(UInt32(b.u16(o + 4))), o + 4, 2))
                fields.append(PacketField("Numéro de séquence", "\(b.u16(o + 6))", o + 6, 2))
                summary += " id=\(PacketText.hex(UInt32(b.u16(o + 4)))) séq=\(b.u16(o + 6))"
            }
            options = end
        case 2:
            fields.append(PacketField("MTU", "\(b.u32(o + 4))", o + 4, 4))
            summary += " (MTU \(b.u32(o + 4)))"
            options = end
        case 133:
            options = o + 8
        case 134:
            if b.has(o, 16) {
                fields.append(PacketField("Limite de sauts conseillée", "\(b.u8(o + 4))", o + 4, 1))
                let flags = b.u8(o + 5)
                fields.append(PacketField("Drapeaux", "M=\(flags >> 7 & 1) O=\(flags >> 6 & 1)", o + 5, 1))
                fields.append(PacketField("Durée de vie du routeur", "\(b.u16(o + 6))\u{00A0}s", o + 6, 2))
                fields.append(PacketField("Temps d’accessibilité", "\(b.u32(o + 8))\u{00A0}ms", o + 8, 4))
                fields.append(PacketField("Délai de retransmission", "\(b.u32(o + 12))\u{00A0}ms", o + 12, 4))
            }
            options = o + 16
        case 135, 136:
            if b.has(o, 24) {
                let target = b.ipv6(o + 8)
                if type == 136 {
                    let flags = b.u8(o + 4)
                    var names: [String] = []
                    if flags & 0x80 != 0 { names.append("routeur") }
                    if flags & 0x40 != 0 { names.append("sollicitée") }
                    if flags & 0x20 != 0 { names.append("remplacer") }
                    fields.append(PacketField("Drapeaux", names.isEmpty ? "aucun" : names.joined(separator: ", "), o + 4, 4))
                    summary += " \(target)" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
                } else {
                    summary += " pour \(target)"
                }
                fields.append(PacketField("Adresse cible", target, o + 8, 16))
            }
            options = o + 24
        case 143:
            if b.has(o, 8) {
                fields.append(PacketField("Nombre d’enregistrements", "\(b.u16(o + 6))", o + 6, 2))
                summary += " (\(b.u16(o + 6)) groupe\(b.u16(o + 6) > 1 ? "s" : ""))"
            }
            options = end
        default:
            options = end
        }
        // Options NDP : adresses de liaison, préfixe, MTU.
        var p = options
        while p + 2 <= end, b.has(p, 2) {
            let optionType = b.u8(p), length = Int(b.u8(p + 1)) * 8
            guard length > 0, p + length <= end else { break }
            switch optionType {
            case 1 where length >= 8, 2 where length >= 8:
                let mac = b.mac(p + 2)
                fields.append(PacketField(optionType == 1 ? "Option\u{00A0}: adresse de liaison source" : "Option\u{00A0}: adresse de liaison cible", mac.formatted(), p, length))
                if optionType == 1 { summary += " de \(mac.formatted())" } else { summary += " est à \(mac.formatted())" }
            case 3 where length >= 32:
                let prefix = "\(b.ipv6(p + 16))/\(b.u8(p + 2))"
                fields.append(PacketField("Option\u{00A0}: préfixe", prefix, p, length, children: [
                    PacketField("Longueur du préfixe", "\(b.u8(p + 2))", p + 2, 1),
                    PacketField("Durée de validité", "\(b.u32(p + 4))\u{00A0}s", p + 4, 4),
                    PacketField("Durée préférée", "\(b.u32(p + 8))\u{00A0}s", p + 8, 4),
                    PacketField("Préfixe", b.ipv6(p + 16), p + 16, 16),
                ]))
                summary += " · préfixe \(prefix)"
            case 5 where length >= 8:
                fields.append(PacketField("Option\u{00A0}: MTU", "\(b.u32(p + 4))", p, length))
            default:
                fields.append(PacketField("Option \(optionType)", PacketText.octets(length), p, length))
            }
            p += length
        }
        add(.icmpv6, "ICMPv6, \(icmpv6Name(type))", o, end - o, fields)
        packet.summary = summary
    }

    func icmpv6Name(_ type: UInt8) -> String {
        switch type {
        case 1: return "Destination inaccessible"
        case 2: return "Paquet trop gros"
        case 3: return "Temps dépassé"
        case 4: return "Problème de paramètre"
        case 128: return "Demande d’écho"
        case 129: return "Réponse d’écho"
        case 130: return "Requête d’écoute multicast"
        case 131: return "Rapport d’écoute multicast"
        case 133: return "Sollicitation de routeur"
        case 134: return "Annonce de routeur"
        case 135: return "Sollicitation de voisin"
        case 136: return "Annonce de voisin"
        case 137: return "Redirection"
        case 143: return "Rapport d’écoute multicast v2"
        default: return "Type \(type)"
        }
    }

    mutating func igmp(_ o: Int, _ end: Int) {
        guard end - o >= 8, b.has(o, 8) else { truncated("IGMP"); return }
        let type = b.u8(o)
        let name: String
        switch type {
        case 0x11: name = "Requête d’adhésion"
        case 0x12: name = "Rapport d’adhésion v1"
        case 0x16: name = "Rapport d’adhésion v2"
        case 0x17: name = "Départ du groupe"
        case 0x22: name = "Rapport d’adhésion v3"
        default: name = "Type \(PacketText.hex(UInt32(type), digits: 2))"
        }
        var fields = [
            PacketField("Type", "\(name) (\(PacketText.hex(UInt32(type), digits: 2)))", o, 1),
            PacketField("Délai de réponse maximal", "\(Double(b.u8(o + 1)) / 10)\u{00A0}s".replacingOccurrences(of: ".", with: ","), o + 1, 1),
            PacketField("Somme de contrôle", PacketText.hex(UInt32(b.u16(o + 2))), o + 2, 2),
        ]
        var summary = name
        if type == 0x22 {
            let count = Int(b.u16(o + 6))
            fields.append(PacketField("Nombre d’enregistrements", "\(count)", o + 6, 2))
            var p = o + 8
            var groups: [String] = []
            for _ in 0..<min(count, 32) where b.has(p, 8) {
                let aux = Int(b.u8(p + 1)) * 4, sources = Int(b.u16(p + 2))
                let group = b.ipv4(p + 4).description
                groups.append(group)
                let length = 8 + sources * 4 + aux
                fields.append(PacketField("Enregistrement", "groupe \(group), type \(b.u8(p))", p, length))
                p += length
            }
            if !groups.isEmpty { summary += " · " + groups.joined(separator: ", ") }
        } else {
            let group = b.ipv4(o + 4)
            fields.append(PacketField("Adresse du groupe", group.description, o + 4, 4))
            if group.value != 0 { summary += " · \(group)" }
        }
        add(.igmp, "IGMP, \(name)", o, end - o, fields)
        packet.summary = summary
    }

    // MARK: TCP et UDP

    mutating func tcp(_ o: Int, _ end: Int) {
        guard end - o >= 20, b.has(o, 20) else { truncated("TCP"); data(o, end); return }
        let sourcePort = b.u16(o), destinationPort = b.u16(o + 2)
        let seq = b.u32(o + 4), ack = b.u32(o + 8)
        let headerLength = Int(b.u8(o + 12) >> 4) * 4
        let flags = b.u16(o + 12) & 0x01FF
        let window = b.u16(o + 14), checksum = b.u16(o + 16), urgent = b.u16(o + 18)
        guard headerLength >= 20, o + headerLength <= end else {
            packet.problems.append("TCP\u{00A0}: longueur d’en-tête invalide (\(headerLength))")
            data(o, end)
            return
        }
        let payloadOffset = o + headerLength
        let payloadLength = max(0, end - payloadOffset)
        let info = TCPSegmentInfo(sequence: seq, acknowledgment: ack, flags: flags, window: window, payloadLength: payloadLength)
        packet.tcp = info
        packet.transport = TransportInfo(kind: .tcp, sourcePort: sourcePort, destinationPort: destinationPort,
                                         payloadOffset: payloadOffset, payloadLength: payloadLength)
        let flagList: [(String, UInt16)] = [("NS (nonce ECN)", 0x100), ("CWR", TCPSegmentInfo.cwr), ("ECE (écho ECN)", TCPSegmentInfo.ece),
                                            ("URG (urgent)", TCPSegmentInfo.urg), ("ACK (accusé)", TCPSegmentInfo.ack), ("PSH (pousser)", TCPSegmentInfo.psh),
                                            ("RST (réinitialisation)", TCPSegmentInfo.rst), ("SYN (synchronisation)", TCPSegmentInfo.syn), ("FIN (fin)", TCPSegmentInfo.fin)]
        let checksumValid = pseudoHeader.map { InternetChecksum.checksum(b.slice(o, end - o), initial: $0) == 0 }
        let checksumText = PacketText.hex(UInt32(checksum)) + (checksumValid == true ? " (correcte)" : checksumValid == false ? " (non vérifiée\u{00A0}: déchargement matériel possible)" : "")
        var fields = [
            PacketField("Port source", "\(sourcePort)", o, 2),
            PacketField("Port de destination", "\(destinationPort)", o + 2, 2),
            PacketField("Numéro de séquence (brut)", "\(seq)", o + 4, 4),
            PacketField("Numéro d’accusé (brut)", "\(ack)", o + 8, 4),
            PacketField("Longueur d’en-tête", "\(headerLength)\u{00A0}octets", o + 12, 1),
            PacketField("Drapeaux", "\(PacketText.hex(UInt32(flags), digits: 3)) (\(info.flagNames.isEmpty ? "aucun" : info.flagNames))", o + 12, 2,
                        children: flagList.map { PacketField($0.0, flags & $0.1 != 0 ? "oui" : "non", o + 12, 2) }),
            PacketField("Fenêtre", "\(window)", o + 14, 2),
            PacketField("Somme de contrôle", checksumText, o + 16, 2),
            PacketField("Pointeur urgent", "\(urgent)", o + 18, 2),
        ]
        if headerLength > 20 { fields.append(tcpOptions(o + 20, o + headerLength)) }
        if payloadLength > 0 { fields.append(PacketField("Charge utile TCP", PacketText.octets(payloadLength), payloadOffset, payloadLength)) }
        add(.tcp, "TCP, port \(sourcePort) → \(destinationPort), séq. \(seq), long. \(payloadLength)", o, headerLength, fields)
        packet.summary = Self.tcpSummary(sourcePort: sourcePort, destinationPort: destinationPort, info: info, relativeSeq: nil, relativeAck: nil)
        if payloadLength > 0 { application(payloadOffset, end, sourcePort: sourcePort, destinationPort: destinationPort, isTCP: true) }
    }

    /// « 52144 → 443 [SYN, ACK] Séq=0 Ack=1 Fen=65535 Long=0 ».
    static func tcpSummary(sourcePort: UInt16, destinationPort: UInt16, info: TCPSegmentInfo, relativeSeq: UInt32?, relativeAck: UInt32?) -> String {
        var text = "\(sourcePort) → \(destinationPort) [\(info.flagNames)] Séq=\(relativeSeq ?? info.sequence)"
        if info.has(TCPSegmentInfo.ack) { text += " Ack=\(relativeAck ?? info.acknowledgment)" }
        text += " Fen=\(info.window) Long=\(info.payloadLength)"
        return text
    }

    func tcpOptions(_ start: Int, _ end: Int) -> PacketField {
        var children: [PacketField] = []
        var names: [String] = []
        var p = start
        while p < end {
            let kind = b.u8(p)
            if kind == 0 { children.append(PacketField("Fin des options", "", p, 1)); break }
            if kind == 1 { children.append(PacketField("Sans opération (NOP)", "", p, 1)); p += 1; continue }
            let length = Int(b.u8(p + 1))
            guard length >= 2, p + length <= end else { break }
            switch kind {
            case 2 where length == 4:
                children.append(PacketField("Taille maximale de segment", "\(b.u16(p + 2))", p, length))
                names.append("MSS=\(b.u16(p + 2))")
            case 3 where length == 3:
                let shift = Int(b.u8(p + 2))
                children.append(PacketField("Facteur d’échelle de fenêtre", "\(shift) (× \(1 << min(shift, 14)))", p, length))
                names.append("WS=\(1 << min(shift, 14))")
            case 4:
                children.append(PacketField("SACK permis", "", p, length))
                names.append("SACK_PERM")
            case 5:
                var blocks: [String] = []
                var q = p + 2
                while q + 8 <= p + length { blocks.append("\(b.u32(q))–\(b.u32(q + 4))"); q += 8 }
                children.append(PacketField("SACK", blocks.joined(separator: ", "), p, length))
                names.append("SACK")
            case 8 where length == 10:
                children.append(PacketField("Horodatage", "TSval \(b.u32(p + 2)), TSecr \(b.u32(p + 6))", p, length))
                names.append("TS")
            default:
                children.append(PacketField("Option \(kind)", PacketText.octets(length), p, length))
            }
            p += length
        }
        return PacketField("Options", names.isEmpty ? PacketText.octets(end - start) : names.joined(separator: ", "), start, end - start, children: children)
    }

    mutating func udp(_ o: Int, _ end: Int) {
        guard end - o >= 8, b.has(o, 8) else { truncated("UDP"); data(o, end); return }
        let sourcePort = b.u16(o), destinationPort = b.u16(o + 2), length = Int(b.u16(o + 4)), checksum = b.u16(o + 6)
        var udpEnd = end
        if length >= 8, o + length <= end { udpEnd = o + length }
        let payloadOffset = o + 8, payloadLength = udpEnd - payloadOffset
        packet.transport = TransportInfo(kind: .udp, sourcePort: sourcePort, destinationPort: destinationPort,
                                         payloadOffset: payloadOffset, payloadLength: payloadLength)
        let checksumText: String
        if checksum == 0 {
            checksumText = "0x0000 (absente)"
        } else if let pseudo = pseudoHeader {
            let valid = InternetChecksum.checksum(b.slice(o, udpEnd - o), initial: pseudo) == 0
            checksumText = PacketText.hex(UInt32(checksum)) + (valid ? " (correcte)" : " (non vérifiée\u{00A0}: déchargement matériel possible)")
        } else {
            checksumText = PacketText.hex(UInt32(checksum))
        }
        var fields = [
            PacketField("Port source", "\(sourcePort)", o, 2),
            PacketField("Port de destination", "\(destinationPort)", o + 2, 2),
            PacketField("Longueur", "\(length)", o + 4, 2),
            PacketField("Somme de contrôle", checksumText, o + 6, 2),
        ]
        if payloadLength > 0 { fields.append(PacketField("Charge utile UDP", PacketText.octets(payloadLength), payloadOffset, payloadLength)) }
        add(.udp, "UDP, port \(sourcePort) → \(destinationPort), long. \(payloadLength)", o, 8, fields)
        packet.summary = "\(sourcePort) → \(destinationPort) Long=\(payloadLength)"
        if payloadLength > 0 { application(payloadOffset, udpEnd, sourcePort: sourcePort, destinationPort: destinationPort, isTCP: false) }
    }

    /// Choix du décodeur d'application : port connu, puis reconnaissance du contenu (HTTP, TLS).
    mutating func application(_ o: Int, _ end: Int, sourcePort: UInt16, destinationPort: UInt16, isTCP: Bool) {
        let ports = [sourcePort, destinationPort]
        func on(_ port: UInt16) -> Bool { ports.contains(port) }
        if isTCP {
            if TLSRecognizer.looksLikeTLS(b, o, end) { tls(o, end); return }
            if HTTPRecognizer.looksLikeHTTP(b, o, end) { http(o, end, kind: .http); return }
            if on(53), end - o >= 14 {
                // DNS sur TCP : longueur sur deux octets, puis le message.
                dns(o + 2, min(end, o + 2 + Int(b.u16(o))), kind: .dns, lengthPrefix: o)
                return
            }
            data(o, end)
            return
        }
        if on(5353) { dns(o, end, kind: .mdns); return }
        if on(53) || on(5355) { dns(o, end, kind: .dns, llmnr: on(5355)); return }
        if on(137) { dns(o, end, kind: .nbns); return }
        if on(67) || on(68) { dhcp(o, end); return }
        if on(1900), HTTPRecognizer.looksLikeHTTP(b, o, end) { http(o, end, kind: .ssdp); return }
        data(o, end)
    }
}

enum HTTPRecognizer {
    static let starts = ["GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE ", "HTTP/1.", "M-SEARCH ", "NOTIFY "]

    static func looksLikeHTTP(_ b: ByteView, _ o: Int, _ end: Int) -> Bool {
        guard end - o >= 8 else { return false }
        let head = String(decoding: b.slice(o, min(12, end - o)), as: UTF8.self)
        return starts.contains { head.hasPrefix($0) }
    }
}

enum TLSRecognizer {
    /// Enregistrement TLS : type 20 à 23, version 3.x, longueur plausible.
    static func looksLikeTLS(_ b: ByteView, _ o: Int, _ end: Int) -> Bool {
        guard end - o >= 5 else { return false }
        let type = b.u8(o), major = b.u8(o + 1), minor = b.u8(o + 2), length = b.u16(o + 3)
        return (20...23).contains(type) && major == 3 && minor <= 4 && length > 0 && length <= 18_432
    }
}
