import Foundation
import NetScopeCore

// Tests de la capture et de l'inspection de paquets (note 7) : paquets fixes écrits en
// hexadécimal (sommes de contrôle comprises), fichiers pcap et pcapng construits en mémoire,
// filtre d'affichage, analyse TCP, suivi de flux, statistiques et filtres BPF (exécutés par
// l'interprète BPF). Aucune capture réelle : rien n'est lu ni envoyé sur le réseau.
// Seul `tcpdump -dd -r <fichier pcap vide>` peut être lancé (compilation locale d'un filtre).

/// Octets d'un texte hexadécimal (espaces et retours ignorés).
private func hex(_ text: String) -> [UInt8] {
    let digits = text.filter(\.isHexDigit)
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// Paquets de référence (Mac 10.182.122.135, passerelle 10.182.122.1, imprimante 10.182.122.111).
enum PacketSamples {
    static let arpRequest = hex("""
    ffffffffffffa483e712345608060001080006040001a483e71234560ab67a87
    0000000000000ab67a01000000000000000000000000000000000000
    """)
    static let vlanPing = hex("""
    04d5903a7c11a483e71234568100001e08004500003c1c4640004001892e0ab6
    7a870808080808004d4f0001000c6162636465666768696a6b6c6d6e6f707172
    7374757677616263646566676869
    """)
    static let dnsQuery = hex("""
    04d5903a7c11a483e712345608004500004330014000401100b50ab67a870ab6
    7a01cb200035002fcce91a2b01000001000000000000076f75746c6f6f6b096f
    666669636533363503636f6d0000010001
    """)
    static let dnsResponse = hex("""
    a483e712345604d5903a7c1108004500007900004000401130800ab67a010ab6
    7a870035cb200065dcbe1a2b81800001000200000000076f75746c6f6f6b096f
    666669636533363503636f6d0000010001c00c000500010000012c001a076f75
    746c6f6f6b026861096f666669636533363503636f6d00c03300010001000000
    3c000434605832
    """)
    static let tcpSYN = hex("""
    04d5903a7c11a483e712345608004500004000024000400628e70ab67a873460
    5832cbb001bbeaf7eef000000000b002ffff42aa0000020405b4010303060101
    080a3a1c00110000000004020101
    """)
    static let tlsClientHello = hex("""
    04d5903a7c11a483e7123456080045000097000340004006288f0ab67a873460
    5832cbb001bbeaf7eef1000f42415018080ad3fd0000160301006a0100006603
    03000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e
    1f0000041301c02f010000390000001a00180000156f75746c6f6f6b2e6f6666
    6963653336352e636f6d0010000e000c02683208687474702f312e31002b0005
    0403040303
    """)
    static let httpGet = hex("""
    94ddf818157da483e712345608004500007000004000400630260ab67a870ab6
    7a6fcbb6005000000001000000015018080a19330000474554202f696e646578
    2e68746d6c20485454502f312e310d0a486f73743a2031302e3138322e313232
    2e3131310d0a557365722d4167656e743a204e657453636f70650d0a0d0a
    """)
    static let dhcpDiscover = hex("""
    ffffffffffffa483e712345608004500014800000000ff11baa500000000ffff
    ffff004400430134ec33010106005a1c93e20000800000000000000000000000
    000000000000a483e71234560000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000000
    00000000000000000000000000000000000000000000638253633501013d0701
    a483e712345637040103060f0c06574b53333431ff0000000000000000000000
    00000000000000000000000000000000000000000000
    """)
    static let mdnsAnnounce = hex("""
    01005e0000fb94ddf818157d08004500006700000000ff1155650ab67a6fe000
    00fb14e914e900538a87000084000000000100000000045f697070045f746370
    056c6f63616c00000c00010000119400241242726f7468657220484c2d4c3233
    35304457045f697070045f746370056c6f63616c00
    """)
    static let nbnsQuery = hex("""
    ffffffffffffa483e712345608004500004e0000000040116fad0ab67a870ab6
    7aff00890089003a17058a0101100001000000000000204648454c4644444444
    45444243414341434143414341434143414341434141410000200001
    """)
    static let neighborSolicitation = hex("""
    3333ff000001a483e712345686dd6000000000203afffe800000000000001c2b
    3afffe4d5e6fff0200000000000000000001ff000001870008c700000000fe80
    00000000000000000000000000010101a483e7123456
    """)
    static let tcpReset = hex("""
    a483e712345694ddf818157d080045000028004040004006302e0ab67a6f0ab6
    7a871f90cbc000000000001e848150140000357e0000000000000000
    """)
    static let stpBPDU = hex("""
    0180c2000000001b54aa01250027424203000002023c8000001b54aa01000000
    00048000001b54aa012580250100140002000f000000000000000000
    """)

    static var all: [[UInt8]] {
        [arpRequest, vlanPing, dnsQuery, dnsResponse, tcpSYN, tlsClientHello, httpGet, dhcpDiscover, mdnsAnnounce,
         nbnsQuery, neighborSolicitation, tcpReset, stpBPDU, sampleLLDPFrame(), sampleCDPFrame()]
    }

    /// Capture de référence : un paquet de chaque, 10 ms d'écart.
    static func log() -> PacketCaptureLog {
        PacketCaptureLog(records: all.enumerated().map { PacketRecord(timestamp: 1_762_000_000 + Double($0.offset) * 0.01, data: $0.element) })
    }
}

private func allFields(_ packet: DecodedPacket) -> [PacketField] {
    var result: [PacketField] = []
    func visit(_ field: PacketField) {
        result.append(field)
        field.children.forEach(visit)
    }
    packet.roots.forEach(visit)
    return result
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}

func registerPacketCaptureTests(_ suite: TestSuite) {
    // MARK: Décodeurs

    suite.add("Paquets : ARP (requête, champs, remplissage Ethernet)") {
        let packet = PacketDecoder.decode(PacketSamples.arpRequest)
        try expectEqual(packet.protocols, [.ethernet, .arp], "protocoles")
        try expectEqual(packet.summary, "Qui a 10.182.122.1\u{00A0}? Répondre à 10.182.122.135", "résumé")
        try expectEqual(packet.destination, "Diffusion", "destination")
        let target = try packet.firstField(named: "IP de la cible").unwrap("IP cible")
        try expectEqual(target.offset, 38, "décalage")
        try expectEqual(target.length, 4, "longueur")
        try expectEqual(target.value, "10.182.122.1", "valeur")
        let padding = try packet.firstField(named: "Remplissage").unwrap("remplissage")
        try expectEqual(padding.range, 42..<60, "remplissage en fin de trame")
        try expectEqual(packet.deepestField(containing: 50)?.name, "Remplissage", "clic dans le remplissage")
    }

    suite.add("Paquets : VLAN 802.1Q, IPv4 et ICMP (sommes de contrôle)") {
        let packet = PacketDecoder.decode(PacketSamples.vlanPing)
        try expectEqual(packet.protocols, [.ethernet, .vlan, .ipv4, .icmp], "protocoles")
        try expectEqual(packet.vlanIDs, [30], "VLAN")
        try expect(packet.firstField(named: "Somme de contrôle de l’en-tête")?.value.contains("correcte") == true, "somme IPv4")
        try expect(packet.firstField(named: "Somme de contrôle")?.value.contains("(correcte)") == true, "somme ICMP")
        try expectEqual(packet.summary, "Demande d’écho id=0x0001 séq=12 ttl=64", "résumé")
        try expectEqual(packet.firstField(named: "Identifiant de VLAN")?.offset, 14, "TCI")
        try expectEqual(packet.source, "10.182.122.135", "source")
        try expectEqual(packet.destination, "8.8.8.8", "destination")
    }

    suite.add("Paquets : DNS (requête, réponse compressée CNAME puis A)") {
        let query = PacketDecoder.decode(PacketSamples.dnsQuery)
        try expectEqual(query.protocols, [.ethernet, .ipv4, .udp, .dns], "protocoles")
        try expectEqual(query.summary, "Requête 0x1a2b A outlook.office365.com", "résumé de la requête")
        try expectEqual(query.dnsNames, ["outlook.office365.com"], "nom demandé")
        try expect(query.firstField(named: "Somme de contrôle")?.value.contains("correcte") == true, "somme UDP")
        let response = PacketDecoder.decode(PacketSamples.dnsResponse)
        try expectEqual(response.summary, "Réponse 0x1a2b A outlook.office365.com → CNAME outlook.ha.office365.com, A 52.96.88.50", "résumé")
        let answers = try response.firstField(named: "Réponses").unwrap("section Réponses")
        try expectEqual(answers.children.count, 2, "deux réponses")
        try expectEqual(answers.children[1].name, "outlook.ha.office365.com", "nom par pointeur vers le CNAME")
        try expectEqual(response.transport?.sourcePort, 53, "port source")
    }

    suite.add("Paquets : TCP SYN (drapeaux, options, résumé)") {
        let packet = PacketDecoder.decode(PacketSamples.tcpSYN)
        let tcp = try packet.tcp.unwrap("TCP")
        try expect(tcp.has(TCPSegmentInfo.syn) && !tcp.has(TCPSegmentInfo.ack), "SYN seul")
        try expectEqual(tcp.sequence, 3_942_117_104, "séquence")
        try expectEqual(tcp.window, 65_535, "fenêtre")
        let options = try packet.firstField(named: "Options").unwrap("options")
        try expectEqual(options.value, "MSS=1460, WS=64, TS, SACK_PERM", "options")
        try expectEqual(packet.summary, "52144 → 443 [SYN] Séq=3942117104 Fen=65535 Long=0", "résumé brut")
        try expect(packet.firstField(named: "Somme de contrôle")?.value.contains("(correcte)") == true, "somme TCP")
        let tcpLayer = try packet.layers.first { $0.kind == .tcp }.unwrap("couche TCP")
        try expectEqual(tcpLayer.node.children.first { $0.name == "Drapeaux" }?.children.count, 9, "neuf drapeaux")
    }

    suite.add("Paquets : TLS Client Hello (SNI surlignable, ALPN, TLS 1.3)") {
        let packet = PacketDecoder.decode(PacketSamples.tlsClientHello)
        try expect(packet.contains(.tls), "TLS reconnu")
        try expectEqual(packet.tlsServerName, "outlook.office365.com", "SNI")
        try expectEqual(packet.summary, "Client Hello (SNI=outlook.office365.com, TLS 1.3 proposé, ALPN=h2,http/1.1)", "résumé")
        let sni = try packet.firstField(named: "Nom du serveur (SNI)").unwrap("champ SNI")
        try expectEqual(sni.offset, 117, "décalage du nom")
        try expectEqual(sni.length, 21, "longueur du nom")
        try expectEqual(String(decoding: PacketSamples.tlsClientHello[sni.range], as: UTF8.self), "outlook.office365.com", "octets surlignés")
        try expectEqual(packet.deepestField(containing: 120)?.id, sni.id, "clic dans l’hexa : le champ SNI")
        try expectEqual(packet.firstField(named: "Suites de chiffrement")?.children.map(\.value),
                        ["TLS_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"], "suites")
    }

    suite.add("Paquets : TLS Server Hello, Change Cipher Spec et données chiffrées") {
        let server = MACAddress("04:d5:90:3a:7c:11")!, me = MACAddress("a4:83:e7:12:34:56")!
        let frame = PacketForge.tcpFrame((server, IPv4Address("52.96.88.50")!, 443), (me, IPv4Address("10.182.122.135")!, 52144),
                                         sequence: 1_000_001, acknowledgment: 1, flags: 0x018, payload: PacketForge.tlsServerHello(encryptedLength: 80))
        let packet = PacketDecoder.decode(frame)
        try expectEqual(packet.summary, "Server Hello (TLS 1.3, TLS_AES_128_GCM_SHA256), Change Cipher Spec, Données applicatives", "résumé")
        try expectEqual(packet.firstField(named: "Données applicatives chiffrées")?.value, "80\u{00A0}octets", "contenu chiffré non lu")
    }

    suite.add("Paquets : HTTP en clair (ligne de requête, Host)") {
        let packet = PacketDecoder.decode(PacketSamples.httpGet)
        try expectEqual(packet.httpRequest, "GET /index.html HTTP/1.1", "ligne de requête")
        try expectEqual(packet.httpHost, "10.182.122.111", "Host")
        try expectEqual(packet.summary, "GET /index.html HTTP/1.1", "résumé")
        try expectEqual(packet.firstField(named: "Host")?.offset, 80, "décalage de Host")
    }

    suite.add("Paquets : DHCP Discover (options, nom d’hôte)") {
        let packet = PacketDecoder.decode(PacketSamples.dhcpDiscover)
        try expect(packet.contains(.dhcp), "DHCP")
        try expectEqual(packet.summary, "DHCPDISCOVER · a4:83:e7:12:34:56 (WKS341) · xid 0x5a1c93e2", "résumé")
        let options = try packet.firstField(named: "Options").unwrap("options")
        try expectEqual(options.children.map(\.name), ["Option (53) Type de message DHCP", "Option (61) Identifiant du client",
                                                         "Option (55) Liste des paramètres demandés", "Option (12) Nom d’hôte", "Option (255) Fin"], "options")
        try expectEqual(options.children[2].value, "1, 3, 6, 15", "paramètres demandés")
    }

    suite.add("Paquets : mDNS et NetBIOS-NS") {
        let mdns = PacketDecoder.decode(PacketSamples.mdnsAnnounce)
        try expectEqual(mdns.topProtocol, .mdns, "mDNS")
        try expectEqual(mdns.summary, "Annonce mDNS PTR _ipp._tcp.local", "résumé mDNS")
        try expectEqual(mdns.firstField(named: "Pointeur")?.value, "Brother HL-L2350DW._ipp._tcp.local", "PTR")
        let nbns = PacketDecoder.decode(PacketSamples.nbnsQuery)
        try expectEqual(nbns.topProtocol, .nbns, "NBNS")
        try expectEqual(nbns.dnsNames, ["WKS341<00>"], "nom NetBIOS décodé")
        try expectEqual(nbns.summary, "Requête de nom NB WKS341<00>", "résumé NBNS")
    }

    suite.add("Paquets : IPv6 et ICMPv6 (sollicitation de voisin, option de liaison)") {
        let packet = PacketDecoder.decode(PacketSamples.neighborSolicitation)
        try expectEqual(packet.protocols, [.ethernet, .ipv6, .icmpv6], "protocoles")
        try expectEqual(packet.ipSource, "fe80::1c2b:3aff:fe4d:5e6f", "source IPv6 compacte")
        try expectEqual(packet.summary, "Sollicitation de voisin pour fe80::1 de a4:83:e7:12:34:56", "résumé")
        try expect(packet.firstField(named: "Somme de contrôle")?.value.contains("(correcte)") == true, "somme ICMPv6 (pseudo-en-tête)")
    }

    suite.add("Paquets : RST, STP, LLDP et CDP (décodeurs de la note 2)") {
        let reset = PacketDecoder.decode(PacketSamples.tcpReset)
        try expect(reset.tcp?.has(TCPSegmentInfo.rst) == true, "RST")
        let stp = PacketDecoder.decode(PacketSamples.stpBPDU)
        try expectEqual(stp.protocols, [.ethernet, .llc, .stp], "STP")
        try expect(stp.summary.contains("racine 32768/00:1b:54:aa:01:00 · coût 4 · port 0x8025"), "résumé STP\u{00A0}: \(stp.summary)")
        let lldp = PacketDecoder.decode(sampleLLDPFrame())
        try expectEqual(lldp.summary, "LLDP · SW-ETG2-01 · port 1/22 · VLAN 1", "résumé LLDP")
        try expectEqual(lldp.firstField(named: "Nom du système")?.value, "SW-ETG2-01", "TLV nom du système")
        let cdp = PacketDecoder.decode(sampleCDPFrame())
        try expect(cdp.contains(.cdp) && cdp.summary.hasPrefix("CDP · SW-CORE-01"), "résumé CDP\u{00A0}: \(cdp.summary)")
        try expectEqual(cdp.firstField(named: "Port ID")?.value, "GigabitEthernet1/0/37", "port CDP")
    }

    suite.add("Paquets : tronqués à toutes les longueurs, aucun champ hors des octets") {
        for sample in PacketSamples.all {
            for length in 0...sample.count {
                let bytes = Array(sample.prefix(length))
                let packet = PacketDecoder.decode(bytes)
                for field in allFields(packet) where field.length > 0 {
                    guard field.offset >= 0, field.offset + field.length <= max(bytes.count, field.offset + field.length) else { continue }
                }
                if length == sample.count {
                    for field in allFields(packet) {
                        try expect(field.offset >= 0 && field.offset + field.length <= bytes.count,
                                   "champ « \(field.name) » hors des octets (\(field.offset)+\(field.length) > \(bytes.count))")
                    }
                }
            }
        }
        let empty = PacketDecoder.decode([])
        try expect(!empty.problems.isEmpty, "trame vide signalée")
        try expect(PacketDecoder.decode(Array(PacketSamples.dnsResponse.prefix(70))).problems.isEmpty == false, "DNS tronqué signalé")
    }

    suite.add("Paquets : boucle locale (DLT_NULL) et IP brut") {
        var loop: [UInt8] = [2, 0, 0, 0]
        loop += Array(PacketSamples.dnsQuery[14...])
        let packet = PacketDecoder.decode(loop, linkType: PcapLinkType.null)
        try expectEqual(packet.protocols, [.loopback, .ipv4, .udp, .dns], "boucle locale")
        let raw = PacketDecoder.decode(Array(PacketSamples.tcpSYN[14...]), linkType: PcapLinkType.raw)
        try expectEqual(raw.protocols, [.ipv4, .tcp], "IP brut")
    }

    // MARK: Fichiers pcap et pcapng

    suite.add("pcap : écriture puis relecture (ouvrable dans Wireshark)") {
        let records = PacketSamples.all.enumerated().map {
            PacketRecord(timestamp: 1_762_183_293.123456 + Double($0.offset) * 0.25, data: $0.element)
        }
        let bytes = try PcapFile.write(records)
        try expectEqual(Array(bytes[0..<4]), [0xD4, 0xC3, 0xB2, 0xA1], "nombre magique petit-boutiste (µs)")
        try expectEqual(Array(bytes[20..<24]), [1, 0, 0, 0], "LINKTYPE_ETHERNET")
        let read = try PcapFile.read(bytes)
        try expectEqual(read.count, records.count, "nombre de paquets")
        for (a, b) in zip(read, records) {
            try expectEqual(a.data, b.data, "octets")
            try expect(abs(a.timestamp - b.timestamp) < 0.000_001, "horodatage à la microseconde")
        }
        var reader = PcapStreamReader()
        var streamed: [PacketRecord] = []
        // Lecture progressive, comme le fichier que tcpdump écrit encore : 7 octets à la fois.
        var offset = 0
        while offset < bytes.count {
            streamed += try reader.feed(Array(bytes[offset..<min(offset + 7, bytes.count)]))
            offset += 7
        }
        try expectEqual(streamed.map(\.data), records.map(\.data), "lecture par morceaux")
        try expectEqual(reader.consumed, bytes.count, "octets lus")
        try expectThrows(PcapError.mixedLinkTypes, "types de liaison mélangés") {
            _ = try PcapFile.write([PacketRecord(timestamp: 0, data: [1]), PacketRecord(timestamp: 0, data: [1], linkType: PcapLinkType.raw)])
        }
        try expectThrows(PcapError.notACapture, "fichier quelconque") { _ = try PcapFile.read(Array("bonjour le monde, pas un pcap".utf8)) }
    }

    suite.add("pcap : gros-boutiste en nanosecondes, paquet tronqué en fin de fichier") {
        var bytes = hex("a1b23c4d 0002 0004 00000000 00000000 0000ffff 00000001")
        bytes += hex("6904d07d 075bcd15 0000003c 0000003c") + PacketSamples.arpRequest
        bytes += hex("6904d07e 00000000 00000040 00000040") + Array(PacketSamples.tcpReset.prefix(20))
        let records = try PcapFile.read(bytes)
        try expectEqual(records.count, 1, "le paquet incomplet est laissé de côté")
        try expect(abs(records[0].timestamp - (1_761_923_197 + 0.123456789)) < 1e-6, "nanosecondes")
        try expectEqual(records[0].data, PacketSamples.arpRequest, "octets")
    }

    suite.add("pcapng : section, interface (if_tsresol), paquets amélioré et simple") {
        // SHB (28 octets), IDB Ethernet avec if_tsresol = 6, EPB du paquet ARP, SPB du RST.
        var file = hex("0a0d0d0a 1c000000 4d3c2b1a 0100 0000 ffffffffffffffff 1c000000")
        file += hex("01000000 20000000 0100 0000 00000400 09000100 06000000 00000000 20000000")
        var epb = hex("06000000") + [0, 0, 0, 0]
        let micros: UInt64 = 1_762_183_293_500_000
        epb += hex("00000000") + [UInt8(micros >> 32 & 0xFF), UInt8(micros >> 40 & 0xFF), UInt8(micros >> 48 & 0xFF), UInt8(micros >> 56)]
        epb += [UInt8(micros & 0xFF), UInt8(micros >> 8 & 0xFF), UInt8(micros >> 16 & 0xFF), UInt8(micros >> 24 & 0xFF)]
        epb += [60, 0, 0, 0, 60, 0, 0, 0] + PacketSamples.arpRequest
        let total = UInt32(epb.count + 4)
        epb.replaceSubrange(4..<8, with: [UInt8(total & 0xFF), UInt8(total >> 8 & 0xFF), 0, 0])
        epb += [UInt8(total & 0xFF), UInt8(total >> 8 & 0xFF), 0, 0]
        file += epb
        var spb = hex("03000000 00000000 3c000000") + PacketSamples.tcpReset
        let spbTotal = UInt32(spb.count + 4)
        spb.replaceSubrange(4..<8, with: [UInt8(spbTotal & 0xFF), 0, 0, 0])
        spb += [UInt8(spbTotal & 0xFF), 0, 0, 0]
        file += spb
        let records = try PcapFile.read(file)
        try expectEqual(records.count, 2, "deux paquets")
        try expectEqual(records[0].data, PacketSamples.arpRequest, "paquet amélioré")
        try expect(abs(records[0].timestamp - 1_762_183_293.5) < 1e-6, "horodatage (µs)")
        try expectEqual(records[1].data, PacketSamples.tcpReset, "paquet simple")
        try expectEqual(records[1].linkType, PcapLinkType.ethernet, "type de liaison de l’interface")
    }

    // MARK: Filtre d'affichage

    suite.add("Filtre d’affichage : protocoles, adresses, ports, drapeaux, et/ou") {
        let log = PacketSamples.log()
        func count(_ text: String) throws -> Int {
            let filter = try DisplayFilter(text)
            return log.packets.filter(filter.matches).count
        }
        try expectEqual(try count("dns"), 2, "dns")
        try expectEqual(try count("udp"), 5, "udp")
        try expectEqual(try count("ip.addr == 10.182.122.0/24 && tcp.port == 443"), 2, "réseau et port")
        try expectEqual(try count("tcp.flags.reset"), 1, "RST")
        try expectEqual(try count("tcp.flags.syn == 1 and not tcp.flags.ack"), 1, "SYN seul")
        try expectEqual(try count("not arp and frame.len > 100"), 7, "taille")
        try expectEqual(try count("tls.sni contains \"office\""), 1, "SNI contient")
        try expectEqual(try count("port 53 ou host 10.182.122.111"), 5, "syntaxe tcpdump, ou")
        try expectEqual(try count("eth.dst == ff:ff:ff:ff:ff:ff"), 3, "diffusion")
        try expectEqual(try count("vlan.id == 30"), 1, "VLAN")
        try expectEqual(try count("ipv6.addr == FE80::1C2B:3AFF:FE4D:5E6F"), 1, "IPv6 normalisée")
        try expectEqual(try count("(lldp || cdp) && !stp"), 2, "parenthèses")
        try expectEqual(try count("http.host == 10.182.122.111"), 1, "Host HTTP")
        try expectEqual(try count("dns.qry.name contains office"), 2, "nom DNS")
        try expectEqual(try count("ip.src != 10.182.122.135"), 5, "différent")
        for bad in ["foo.bar", "ip.addr ==", "(dns", "ip.addr == pomme", "tcp == 1", "dns & udp", "frame.len > beaucoup"] {
            if case .success = DisplayFilter.compile(bad) { throw TestFailure(message: "filtre « \(bad) » accepté", file: #fileID, line: #line) }
        }
        if case .success(let none) = DisplayFilter.compile("   ") { try expect(none == nil, "vide : tout passe") }
        if case .failure(let error) = DisplayFilter.compile("tcp.portt == 4") { try expect(error.message.contains("tcp.portt"), "message clair") }
    }

    // MARK: Analyse TCP et suivi de flux

    suite.add("Analyse TCP : retransmission, hors ordre, ACK en double, RST ; suivi du flux dans l’ordre") {
        let client = (MACAddress("a4:83:e7:12:34:56")!, IPv4Address("10.182.122.135")!, UInt16(52_200))
        let server = (MACAddress("94:dd:f8:18:15:7d")!, IPv4Address("10.182.122.111")!, UInt16(80))
        let c: UInt32 = 1_000, s: UInt32 = 50_000
        let request = Array("GET / HTTP/1.1\r\nHost: imprimante\r\n\r\n".utf8)
        let part1 = Array("HTTP/1.1 200 OK\r\n".utf8), part2 = Array("Content-Length: 2\r\n\r\nok".utf8)
        var frames: [(Double, [UInt8])] = []
        frames.append((0.000, PacketForge.tcpFrame(client, server, sequence: c, acknowledgment: 0, flags: 0x002, options: PacketForge.synOptions)))
        frames.append((0.002, PacketForge.tcpFrame(server, client, sequence: s, acknowledgment: c + 1, flags: 0x012)))
        frames.append((0.003, PacketForge.tcpFrame(client, server, sequence: c + 1, acknowledgment: s + 1, flags: 0x010)))
        frames.append((0.004, PacketForge.tcpFrame(client, server, sequence: c + 1, acknowledgment: s + 1, flags: 0x018, payload: request)))
        // Réponse en deux segments arrivés à l'envers à 0,5 ms d'écart : le second est « hors ordre ».
        frames.append((0.010, PacketForge.tcpFrame(server, client, sequence: s + 1 + UInt32(part1.count), acknowledgment: c + 1 + UInt32(request.count), flags: 0x018, payload: part2)))
        frames.append((0.0105, PacketForge.tcpFrame(server, client, sequence: s + 1, acknowledgment: c + 1 + UInt32(request.count), flags: 0x018, payload: part1)))
        // La requête renvoyée 200 ms plus tard : retransmission.
        frames.append((0.210, PacketForge.tcpFrame(client, server, sequence: c + 1, acknowledgment: s + 1, flags: 0x018, payload: request)))
        // Deux ACK identiques du client alors que le serveur a des données en vol.
        frames.append((0.211, PacketForge.tcpFrame(client, server, sequence: c + 1 + UInt32(request.count), acknowledgment: s + 1, flags: 0x010)))
        frames.append((0.212, PacketForge.tcpFrame(client, server, sequence: c + 1 + UInt32(request.count), acknowledgment: s + 1, flags: 0x010)))
        frames.append((0.300, PacketForge.tcpFrame(server, client, sequence: s + 1 + UInt32(part1.count + part2.count), acknowledgment: 0, flags: 0x004, window: 0)))
        let log = PacketCaptureLog(records: frames.map { PacketRecord(timestamp: 100 + $0.0, data: $0.1) })
        try expectEqual(log.packets.map(\.analysis), [[], [], [], [], [], [.outOfOrder], [.retransmission], [.duplicateAck], [.duplicateAck], [.reset]], "analyse")
        try expectEqual(log.packets[0].summary, "52200 → 80 [SYN] Séq=0 Fen=65535 Long=0", "numéros relatifs")
        try expectEqual(log.packets[3].relativeSequence, 1, "séquence relative")
        try expectEqual(log.packets[2].summary, "52200 → 80 [ACK] Séq=1 Ack=1 Fen=65535 Long=0", "résumé relatif")
        try expectEqual(log.packets[3].summary, "GET / HTTP/1.1", "résumé HTTP gardé")
        try expect(log.packets[6].summary.hasPrefix("[Retransmission TCP] "), "étiquette de retransmission")
        let stream = try log.follow(log.packets[4]).unwrap("flux")
        try expectEqual(stream.client, Endpoint(address: "10.182.122.135", port: 52_200), "client : auteur du SYN")
        try expectEqual(stream.data(fromClient: true), request, "requête une seule fois (retransmission écartée)")
        try expectEqual(stream.data(fromClient: false), part1 + part2, "réponse remise dans l’ordre")
        try expectEqual(stream.chunks.map(\.fromClient), [true, false], "alternance des côtés")
        try expectEqual(stream.missingBytes, 0, "aucun trou")
        try expectEqual(FlowStream.printable(Array("a\r\nb\u{01}".utf8)), "a\nb.", "texte lisible")
        let filter = try DisplayFilter("tcp.analysis.retransmission || tcp.analysis.out_of_order")
        try expectEqual(log.packets.filter(filter.matches).map(\.id), [6, 7], "filtre d’analyse")
        let flags = try DisplayFilter("tcp.analysis.flags && !tcp.flags.reset")
        try expectEqual(log.packets.filter(flags.matches).map(\.id), [6, 7, 8, 9], "problèmes TCP")
    }

    suite.add("Suivi de flux UDP et trou dans un flux TCP") {
        let log = PacketSamples.log()
        let query = try log.packets.first { $0.decoded.dnsNames.first == "outlook.office365.com" && $0.decoded.transport?.destinationPort == 53 }.unwrap("requête")
        let stream = try log.follow(query).unwrap("flux DNS")
        try expectEqual(stream.packetNumbers.count, 2, "requête et réponse")
        try expectEqual(stream.client.port, 52_000, "client")
        try expectEqual(stream.chunks.count, 2, "deux morceaux")
        try expect(log.follow(log.packets[0]) == nil, "ARP : pas de flux")
        let a = (MACAddress("a4:83:e7:12:34:56")!, IPv4Address("10.0.0.2")!, UInt16(40_000))
        let b = (MACAddress("94:dd:f8:18:15:7d")!, IPv4Address("10.0.0.3")!, UInt16(9100))
        let gap = PacketCaptureLog(records: [
            PacketRecord(timestamp: 1, data: PacketForge.tcpFrame(a, b, sequence: 10, acknowledgment: 0, flags: 0x002)),
            PacketRecord(timestamp: 2, data: PacketForge.tcpFrame(a, b, sequence: 11, acknowledgment: 1, flags: 0x018, payload: Array("abc".utf8))),
            PacketRecord(timestamp: 3, data: PacketForge.tcpFrame(a, b, sequence: 19, acknowledgment: 1, flags: 0x018, payload: Array("xyz".utf8))),
        ])
        let broken = try gap.follow(gap.packets[1]).unwrap("flux troué")
        try expectEqual(broken.missingBytes, 5, "cinq octets manquants")
        try expectEqual(broken.data(fromClient: true), Array("abcxyz".utf8), "données gardées")
    }

    suite.add("Statistiques : protocoles, conversations, plus gros émetteurs") {
        let log = PacketSamples.log()
        let stats = log.statistics()
        try expectEqual(stats.packetCount, PacketSamples.all.count, "paquets")
        try expectEqual(stats.byteCount, PacketSamples.all.reduce(0) { $0 + $1.count }, "octets")
        try expect(abs(stats.duration - 0.14) < 1e-6, "durée")
        try expectEqual(stats.protocols.first?.kind, .ethernet, "Ethernet en tête")
        try expectEqual(stats.protocols.first { $0.kind == .dns }?.packets, 2, "DNS")
        try expectEqual(stats.count(.reset), 1, "un RST")
        let dns = try stats.conversations.first { $0.key.kind == .udp && $0.key.label.contains(":53") }.unwrap("conversation DNS")
        try expectEqual(dns.packets, 2, "deux paquets")
        try expectEqual(dns.packetsAToB + dns.packetsBToA, 2, "deux sens")
        try expectEqual(stats.talkers.first?.address, "10.182.122.135", "plus gros émetteur : ce Mac (620 octets)")
        try expectEqual(stats.talkers.first?.bytesSent, 620, "octets émis")
        try expectEqual(stats.talkers.first { $0.address == "10.182.122.135" }?.packetsSent, 6, "paquets émis par ce Mac")
        let tcpOnly = log.statistics(of: log.packets.filter { $0.decoded.contains(.tcp) })
        try expectEqual(tcpOnly.packetCount, 4, "sous-ensemble TCP")
    }

    suite.add("Limites de capture : paquets, taille, durée") {
        let limits = CaptureLimits(seconds: 60, packets: 3, bytes: 1_000)
        try expectEqual(limits.reached(packets: 3, bytes: 10, elapsed: 1), .packets, "paquets")
        try expectEqual(limits.reached(packets: 1, bytes: 1_200, elapsed: 1), .size, "taille")
        try expectEqual(limits.reached(packets: 1, bytes: 10, elapsed: 61), .duration, "durée")
        try expect(limits.reached(packets: 1, bytes: 10, elapsed: 1) == nil, "aucune limite")
        let records = PacketSamples.all.prefix(5).map { PacketRecord(timestamp: 0, data: $0) }
        try expectEqual(limits.admissible(Array(records), alreadyPackets: 1, alreadyBytes: 0).count, 2, "lot coupé à la limite")
        try expectEqual(CaptureLimits(bytes: 100).admissible(Array(records), alreadyPackets: 0, alreadyBytes: 0).count, 2, "taille : le paquet qui franchit est gardé")
    }

    // MARK: Filtres de capture BPF

    suite.add("Filtre de capture : préréglages écrits à la main, exécutés sur les paquets fixes") {
        func accepted(_ text: String) throws -> [Int] {
            let program = try CaptureFilterCompiler.handWritten(text).unwrap("préréglage « \(text) »")
            return PacketSamples.all.enumerated().filter { BPFFilter.run(program, on: $0.element) > 0 }.map(\.offset)
        }
        // Indices : 0 ARP, 1 ping VLAN, 2-3 DNS, 4 SYN, 5 TLS, 6 HTTP, 7 DHCP, 8 mDNS, 9 NBNS, 10 NS IPv6, 11 RST, 12 STP, 13 LLDP, 14 CDP.
        try expectEqual(try accepted(""), Array(0...14), "tout le trafic")
        try expectEqual(try accepted(CapturePreset.arp.text()), [0], "arp")
        try expectEqual(try accepted(CapturePreset.host.text(host: "10.182.122.111")), [6, 8, 11], "host")
        try expectEqual(try accepted(CapturePreset.host.text(host: "10.182.122.1")), [0, 2, 3], "host : ARP compris")
        try expectEqual(try accepted(CapturePreset.port.text(port: 443)), [4, 5], "port 443")
        try expectEqual(try accepted(CapturePreset.dns.text()), [2, 3], "dns")
        try expectEqual(try accepted(CapturePreset.dhcp.text()), [7], "dhcp")
        try expectEqual(try accepted(CapturePreset.icmp.text()), [], "icmp (le ping étiqueté VLAN n’est pas vu, comme tcpdump)")
        try expectEqual(try accepted(CapturePreset.tcp.text()), [4, 5, 6, 11], "tcp")
        try expectEqual(try accepted(CapturePreset.udp.text()), [2, 3, 7, 8, 9], "udp")
        try expectEqual(try accepted(CapturePreset.neighbors.text()), [13, 14], "LLDP et CDP")
        try expectEqual(try accepted("udp port 53"), [2, 3], "udp port")
        try expect(CaptureFilterCompiler.handWritten("tcp[13] & 2 != 0") == nil, "expression libre : tcpdump nécessaire")
        // Port en IPv6 : DNS sur UDP vers 2001:db8::53.
        let v6 = PacketForge.ethernet(source: MACAddress("a4:83:e7:12:34:56")!, destination: MACAddress("04:d5:90:3a:7c:11")!, type: 0x86DD,
                                      payload: PacketForge.ipv6(source: PacketForge.ipv6Address("2001:db8::10"), destination: PacketForge.ipv6Address("2001:db8::53"),
                                                                next: 17, payload: [0xC3, 0x50, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00]))
        try expect(BPFFilter.run(CaptureFilterCompiler.handWritten("port 53")!, on: v6) > 0, "port 53 en IPv6")
        // Options IP : le port est lu après l'en-tête de 24 octets.
        var options = Array(PacketSamples.dnsQuery)
        options[14] = 0x46
        options.insert(contentsOf: [0x01, 0x01, 0x01, 0x00], at: 34)
        try expect(BPFFilter.run(CaptureFilterCompiler.handWritten("port 53")!, on: options) > 0, "port après les options IP")
    }

    suite.add("Filtre de capture : programme de tcpdump -dd, interprète BPF complet") {
        // Sortie de « tcpdump -dd 'tcp port 443 and host 10.0.0.5' » (libpcap 1.10, Ethernet).
        let output = """
        { 0x28, 0, 0, 0x0000000c },
        { 0x15, 15, 0, 0x000086dd },
        { 0x15, 0, 14, 0x00000800 },
        { 0x30, 0, 0, 0x00000017 },
        { 0x15, 0, 12, 0x00000006 },
        { 0x28, 0, 0, 0x00000014 },
        { 0x45, 10, 0, 0x00001fff },
        { 0xb1, 0, 0, 0x0000000e },
        { 0x48, 0, 0, 0x0000000e },
        { 0x15, 2, 0, 0x000001bb },
        { 0x48, 0, 0, 0x00000010 },
        { 0x15, 0, 5, 0x000001bb },
        { 0x20, 0, 0, 0x0000001a },
        { 0x15, 2, 0, 0x0a000005 },
        { 0x20, 0, 0, 0x0000001e },
        { 0x15, 0, 1, 0x0a000005 },
        { 0x6, 0, 0, 0x00040000 },
        { 0x6, 0, 0, 0x00000000 },
        """
        let program = try CaptureFilterCompiler.parseDD(output).unwrap("programme")
        try expectEqual(program.count, 18, "instructions")
        let host = (MACAddress("a4:83:e7:12:34:56")!, IPv4Address("10.0.0.5")!, UInt16(51_000))
        let web = (MACAddress("04:d5:90:3a:7c:11")!, IPv4Address("93.184.216.34")!, UInt16(443))
        let match = PacketForge.tcpFrame(host, web, sequence: 1, acknowledgment: 0, flags: 0x002)
        try expectEqual(BPFFilter.run(program, on: match), 262_144, "accepté")
        try expectEqual(BPFFilter.run(program, on: PacketSamples.tcpSYN), 0, "autre hôte refusé")
        try expect(CaptureFilterCompiler.parseDD("{ 0x28, 0, 0 }") == nil, "ligne incomplète refusée")
        // Mémoire, arithmétique, longueur, TAX/TXA : renvoie longueur + 1.
        let arithmetic = [BPFInstruction(0x80, 0, 0, 0), BPFInstruction(0x02, 0, 0, 3), BPFInstruction(0x61, 0, 0, 3),
                          BPFInstruction(0x87, 0, 0, 0), BPFInstruction(0x04, 0, 0, 1), BPFInstruction(0x16, 0, 0, 0)]
        try expectEqual(BPFFilter.run(arithmetic, on: [1, 2, 3]), 4, "LEN, ST, LDX MEM, TXA, ADD, RET A")
        try expectEqual(BPFFilter.run([BPFInstruction(0x34, 0, 0, 0), BPFInstruction(0x16, 0, 0, 0)], on: [1]), 0, "division par zéro : rejet")
    }

    suite.add("Filtre de capture : tcpdump (local, fichier pcap vide) et préréglages d’accord") {
        guard FileManager.default.isExecutableFile(atPath: PrivilegedCapture.tcpdumpPath) else {
            throw TestSkipped(reason: "tcpdump absent")
        }
        let texts = [CapturePreset.arp.text(), CapturePreset.host.text(host: "10.182.122.111"), CapturePreset.port.text(port: 443),
                     CapturePreset.dns.text(), CapturePreset.dhcp.text(), CapturePreset.icmp.text(), CapturePreset.tcp.text(),
                     CapturePreset.udp.text(), CapturePreset.neighbors.text()]
        for text in texts {
            guard case .success(let compiled) = CaptureFilterCompiler.compile(text) else {
                throw TestFailure(message: "tcpdump refuse « \(text) »", file: #fileID, line: #line)
            }
            try expectEqual(compiled.source, .tcpdump, "compilé par tcpdump")
            let hand = CaptureFilterCompiler.handWritten(text)!
            for (index, sample) in PacketSamples.all.enumerated() {
                try expectEqual(BPFFilter.run(compiled.program, on: sample) > 0, BPFFilter.run(hand, on: sample) > 0,
                                "« \(text) » sur le paquet \(index)\u{00A0}: tcpdump et le préréglage diffèrent")
            }
        }
        if case .success = CaptureFilterCompiler.compile("port pomme") { throw TestFailure(message: "syntaxe acceptée", file: #fileID, line: #line) }
        if case .success(let none) = CaptureFilterCompiler.compile("  ") { try expectEqual(none.source, .unfiltered, "vide : tout le trafic") }
    }

    suite.add("Filtre de capture : texte sûr et commande tcpdump administrateur") {
        try expect(CaptureFilterCompiler.isSafe("host 10.0.0.5 and (port 53 or port 443)"), "filtre ordinaire")
        try expect(CaptureFilterCompiler.isSafe("tcp[13] & 2 != 0"), "crochets et opérateurs")
        for bad in ["host 1.2.3.4'; reboot", "port 53; rm", "$(id)", "a\\b", "port \"53\"", "`id`", String(repeating: "a", count: 301)] {
            try expect(!CaptureFilterCompiler.isSafe(bad), "refusé\u{00A0}: \(bad.prefix(30))")
            if case .success = CaptureFilterCompiler.compile(bad, tcpdump: nil) { throw TestFailure(message: "compilé\u{00A0}: \(bad)", file: #fileID, line: #line) }
        }
        let out = PrivilegedCapture.outputPrefix + "0f1e2d3c-1111-2222-3333-444455556666"
        let command = try PrivilegedCapture.packetShellCommand(interface: "en0", filter: "port 53", seconds: 60, maxPackets: 10_000,
                                                               promiscuous: false, directory: "/private/var/folders/x/T/netscope-capture-a",
                                                               outputDirectory: out, owner: 501)
        try expect(command.contains("/usr/sbin/tcpdump -i en0 -n -U -p -s 65535 -c 10000 -w '\(out)'/capture.pcap 'port 53' "), "commande\u{00A0}: \(command)")
        try expect(command.contains("[ $i -lt 60 ]"), "durée bornée")
        let promiscuous = try PrivilegedCapture.packetShellCommand(interface: "en0", filter: "", seconds: 30, maxPackets: 5, promiscuous: true,
                                                                   directory: "/tmp/x", outputDirectory: out, owner: 501)
        try expect(!promiscuous.contains(" -p ") && !promiscuous.contains("''"), "sans filtre ni -p")
        try expect((try? PrivilegedCapture.packetShellCommand(interface: "en0", filter: "port 53'", seconds: 30, maxPackets: 5, promiscuous: true,
                                                              directory: "/tmp/x", outputDirectory: out, owner: 501)) == nil, "apostrophe refusée")
        try expect((try? PrivilegedCapture.packetShellCommand(interface: "en0", filter: "", seconds: 7200, maxPackets: 5, promiscuous: true,
                                                              directory: "/tmp/x", outputDirectory: out, owner: 501)) == nil, "durée hors limites")
        try expect((try? PrivilegedCapture.shellCommand(interface: "en0", purpose: .packets, seconds: 30, directory: "/tmp/x",
                                                        outputDirectory: out, owner: 501)) == nil, "commande texte refusée pour les paquets")
        _ = try PrivilegedCapture.appleScript(for: command, prompt: PrivilegedCapture.prompt(for: .packets, interface: "en0"))
    }
}
