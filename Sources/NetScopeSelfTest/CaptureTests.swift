import Darwin
import Foundation
import NetScopeCore

// Tests du Test DHCP et de la capture LLDP/CDP : trames écrites à la main d'après les normes
// (IEEE 802.1AB, CDP v2, RFC 2131/2132). Aucune capture réelle, ni osascript, ni tcpdump ;
// le seul envoi est un échange DHCP simulé sur 127.0.0.1.

/// TLV LLDP : 7 bits de type, 9 bits de longueur.
private func lldpTLV(_ type: Int, _ value: [UInt8]) -> [UInt8] {
    let header = UInt16(type) << 9 | UInt16(value.count)
    return [UInt8(header >> 8), UInt8(header & 0xFF)] + value
}

/// TLV CDP : type et longueur (en-tête compris) sur 16 bits.
private func cdpTLV(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
    let length = UInt16(value.count + 4)
    return [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF)] + value
}

/// Trame LLDP d'un Aruba 2930F (port 1/22, PVID 1, PoE 802.3at non utilisé).
func sampleLLDPFrame() -> [UInt8] {
    var frame: [UInt8] = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E,   // destination LLDP
                          0x88, 0x3A, 0x30, 0x9C, 0x41, 0x22,   // source (port du switch)
                          0x88, 0xCC]                           // EtherType LLDP
    frame += [0x02, 0x07, 0x04, 0x88, 0x3A, 0x30, 0x9C, 0x41, 0x00]                 // Chassis ID, sous-type 4 (MAC)
    frame += [0x04, 0x05, 0x05] + Array("1/22".utf8)                                // Port ID, sous-type 5 (nom)
    frame += [0x06, 0x02, 0x00, 0x78]                                               // TTL 120 s
    frame += lldpTLV(4, Array("Bureau 214 - prise B".utf8))                         // Port Description
    frame += lldpTLV(5, Array("SW-ETG2-01".utf8))                                   // System Name
    frame += lldpTLV(6, Array("Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012".utf8))
    frame += [0x0E, 0x04, 0x00, 0x14, 0x00, 0x14]                                   // Capacités : Bridge + Router
    frame += [0x10, 0x0C, 0x05, 0x01, 0x0A, 0xB6, 0x7A, 0x03, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00] // gestion 10.182.122.3
    frame += [0xFE, 0x06, 0x00, 0x80, 0xC2, 0x01, 0x00, 0x01]                       // 802.1 PVID 1
    frame += [0xFE, 0x09, 0x00, 0x12, 0x0F, 0x01, 0x03, 0x6C, 0x01, 0x00, 0x1E]     // 802.3 MAC/PHY, MAU 30
    frame += [0xFE, 0x0C, 0x00, 0x12, 0x0F, 0x02, 0x07, 0x01, 0x05, 0x51, 0x00, 0x00, 0x00, 0x00] // PoE 802.3at, 0 W
    frame += [0xFE, 0x08, 0x00, 0x12, 0xBB, 0x02, 0x01, 0x00, 0x3C, 0x2E]           // MED voix : VLAN 30
    frame += [0x00, 0x00]                                                           // fin de LLDPDU
    return frame
}

/// Trame CDP v2 d'un Catalyst 9300 (Gi1/0/37, VLAN natif 1, voix 30).
func sampleCDPFrame() -> [UInt8] {
    var cdp: [UInt8] = [0x02, 0xB4, 0x00, 0x00]                                     // version 2, TTL 180, somme
    cdp += cdpTLV(0x0001, Array("SW-CORE-01.bureau.local".utf8))
    cdp += cdpTLV(0x0002, [0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0xCC, 0x00, 0x04, 0x0A, 0xB6, 0x7A, 0x02])
    cdp += cdpTLV(0x0003, Array("GigabitEthernet1/0/37".utf8))
    cdp += cdpTLV(0x0004, [0x00, 0x00, 0x00, 0x28])                                 // Switch + IGMP
    cdp += cdpTLV(0x0005, Array("Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc5)\nCopyright (c) 1986-2023 by Cisco Systems, Inc.".utf8))
    cdp += cdpTLV(0x0006, Array("cisco C9300-48P".utf8))
    cdp += cdpTLV(0x000A, [0x00, 0x01])
    cdp += cdpTLV(0x000B, [0x01])
    cdp += cdpTLV(0x000E, [0x01, 0x00, 0x1E])
    cdp += cdpTLV(0x0010, [0x3A, 0x98])                                             // 15 000 mW
    cdp += cdpTLV(0x0016, [0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0xCC, 0x00, 0x04, 0x0A, 0xB6, 0x7A, 0x02])
    let llc: [UInt8] = [0xAA, 0xAA, 0x03, 0x00, 0x00, 0x0C, 0x20, 0x00]
    let length = UInt16(llc.count + cdp.count)
    return [0x01, 0x00, 0x0C, 0xCC, 0xCC, 0xCC, 0x00, 0x1B, 0x54, 0xAA, 0x01, 0x25,
            UInt8(length >> 8), UInt8(length & 0xFF)] + llc + cdp
}

/// Offre DHCP du FortiGate (10.182.122.1) : 10.182.122.187/24, bail 24 h, options 66, 67 et 43.
func sampleDHCPOffer(xid: [UInt8] = [0x5A, 0x1C, 0x93, 0xE2]) -> [UInt8] {
    var p: [UInt8] = [0x02, 0x01, 0x06, 0x00] + xid + [0x00, 0x00, 0x80, 0x00]
    p += [0, 0, 0, 0]                                   // ciaddr
    p += [0x0A, 0xB6, 0x7A, 0xBB]                       // yiaddr 10.182.122.187
    p += [0, 0, 0, 0, 0, 0, 0, 0]                       // siaddr, giaddr
    p += [0x3C, 0x22, 0xFB, 0x7E, 0x05, 0xB1] + [UInt8](repeating: 0, count: 10)
    p += [UInt8](repeating: 0, count: 64 + 128)         // sname, file
    p += [0x63, 0x82, 0x53, 0x63]
    p += [53, 1, 2]                                     // DHCPOFFER
    p += [54, 4, 0x0A, 0xB6, 0x7A, 0x01]
    p += [51, 4, 0x00, 0x01, 0x51, 0x80]                // 86 400 s
    p += [58, 4, 0x00, 0x00, 0xA8, 0xC0]                // T1 43 200 s
    p += [59, 4, 0x00, 0x01, 0x27, 0x50]                // T2 75 600 s
    p += [1, 4, 0xFF, 0xFF, 0xFF, 0x00]
    p += [3, 4, 0x0A, 0xB6, 0x7A, 0x01]
    p += [6, 8, 0x0A, 0xB6, 0x7A, 0x01, 0x08, 0x08, 0x08, 0x08]
    p += [15, 12] + Array("bureau.local".utf8)
    p += [66, 12] + Array("10.182.122.2".utf8)
    p += [67, 10] + Array("pxelinux.0".utf8)
    p += [43, 6, 0x01, 0x04, 0x0A, 0xB6, 0x7A, 0x02]
    p += [255]
    return p
}

/// Offre d'un routeur TP-Link branché à l'envers, dans une trame Ethernet/IPv4/UDP complète.
func sampleRogueDHCPFrame() -> [UInt8] {
    var dhcp: [UInt8] = [0x02, 0x01, 0x06, 0x00, 0x5A, 0x1C, 0x93, 0xE2, 0x00, 0x00, 0x80, 0x00]
    dhcp += [0, 0, 0, 0, 192, 168, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0]
    dhcp += [0x3C, 0x22, 0xFB, 0x7E, 0x05, 0xB1] + [UInt8](repeating: 0, count: 10 + 64 + 128)
    dhcp += [0x63, 0x82, 0x53, 0x63, 53, 1, 2, 54, 4, 192, 168, 0, 1, 51, 4, 0x00, 0x00, 0x1C, 0x20,
             1, 4, 255, 255, 255, 0, 3, 4, 192, 168, 0, 1, 6, 4, 192, 168, 0, 1, 255]
    let udpLength = UInt16(8 + dhcp.count)
    let udp: [UInt8] = [0x00, 0x43, 0x00, 0x44, UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 0x00, 0x00] + dhcp
    let ipLength = UInt16(20 + udp.count)
    let ip: [UInt8] = [0x45, 0x00, UInt8(ipLength >> 8), UInt8(ipLength & 0xFF), 0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00,
                       0x0A, 0xB6, 0x7A, 0xFA,          // source 10.182.122.250
                       0xFF, 0xFF, 0xFF, 0xFF]
    return [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xD8, 0x07, 0xB6, 0x62, 0x4E, 0xA0, 0x08, 0x00] + ip + udp
}

/// Mise en forme comme `tcpdump -e -xx` (groupes de 2 octets, 16 octets par ligne).
private func tcpdumpText(_ frame: [UInt8], header: String) -> String {
    var lines = [header]
    for start in stride(from: 0, to: frame.count, by: 16) {
        let chunk = Array(frame[start..<min(start + 16, frame.count)])
        let groups = stride(from: 0, to: chunk.count, by: 2).map { i in
            chunk[i..<min(i + 2, chunk.count)].map { String(format: "%02x", $0) }.joined()
        }
        lines.append("\t0x" + String(format: "%04x", start) + ":  " + groups.joined(separator: " "))
    }
    return lines.joined(separator: "\n")
}

func registerCaptureTests(_ suite: TestSuite) {
    suite.add("LLDP : décodage d’une trame Aruba (port, VLAN, gestion, PoE, voix)") {
        let neighbor = try NeighborFrameDecoder.decode(sampleLLDPFrame(), interface: "en7").unwrap("trame LLDP")
        try expectEqual(neighbor.protocols, [.lldp], "protocole")
        try expectEqual(neighbor.chassisID, "88:3A:30:9C:41:00", "châssis (MAC)")
        try expectEqual(neighbor.portID, "1/22", "port")
        try expectEqual(neighbor.ttl, 120, "TTL")
        try expectEqual(neighbor.portDescription, "Bureau 214 - prise B", "description du port")
        try expectEqual(neighbor.systemName, "SW-ETG2-01", "nom système")
        try expectEqual(neighbor.capabilities, ["Bridge", "Router"], "capacités")
        try expectEqual(neighbor.managementAddresses, ["10.182.122.3"], "adresse de gestion")
        try expectEqual(neighbor.nativeVLAN, 1, "PVID")
        try expectEqual(neighbor.voiceVLAN, 30, "VLAN voix LLDP-MED")
        try expectEqual(neighbor.link, "1000BASE-T duplex intégral", "MAU")
        try expectEqual(neighbor.poe, "802.3at · non utilisé", "PoE")
        try expectEqual(neighbor.model, "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch", "modèle")
        try expectEqual(neighbor.sourceMAC, "88:3A:30:9C:41:22", "MAC source")
        try expectEqual(neighbor.interface, "en7", "interface")
        try expectEqual(neighbor.headline, "SW-ETG2-01 · port 1/22 · VLAN 1", "résumé")
    }

    suite.add("LLDP : trames tronquées ou incomplètes refusées sans plantage") {
        let frame = sampleLLDPFrame()
        for cut in [14, 16, 20, 25, 40] {
            _ = NeighborFrameDecoder.decode(Array(frame.prefix(cut)))
        }
        try expect(NeighborFrameDecoder.decode(Array(frame.prefix(20))) == nil, "sans Port ID : rien")
        // Longueur de TLV qui dépasse la trame : le décodage s'arrête.
        var bad = Array(frame.prefix(14)) + [0x02, 0x07, 0x04, 0x88]
        bad += [0x00, 0x00]
        try expect(NeighborFrameDecoder.decode(bad) == nil, "TLV trop long")
    }

    suite.add("CDP : décodage d’une trame Catalyst (port, VLAN natif et voix, plateforme, PoE)") {
        let neighbor = try NeighborFrameDecoder.decode(sampleCDPFrame()).unwrap("trame CDP")
        try expectEqual(neighbor.protocols, [.cdp], "protocole")
        try expectEqual(neighbor.systemName, "SW-CORE-01.bureau.local", "Device ID")
        try expectEqual(neighbor.portID, "GigabitEthernet1/0/37", "Port ID")
        try expectEqual(neighbor.model, "cisco C9300-48P", "plateforme")
        try expectEqual(neighbor.softwareVersion,
                        "Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc5)",
                        "version")
        try expectEqual(neighbor.nativeVLAN, 1, "VLAN natif")
        try expectEqual(neighbor.voiceVLAN, 30, "VLAN voix")
        try expectEqual(neighbor.duplex, "Duplex intégral", "duplex")
        try expectEqual(neighbor.capabilities, ["Switch", "IGMP"], "capacités")
        try expectEqual(neighbor.managementAddresses, ["10.182.122.2"], "adresses dédoublonnées")
        try expectEqual(neighbor.poe, "CDP · 15\u{00A0}W", "PoE")
        try expectEqual(neighbor.ttl, 180, "TTL")
        try expectEqual(neighbor.headline, "SW-CORE-01.bureau.local · port GigabitEthernet1/0/37 · VLAN 1", "résumé")
        // Un en-tête SNAP faux ou une destination autre ne donne rien.
        var other = sampleCDPFrame()
        other[0] = 0x01; other[5] = 0xCD
        try expect(NeighborFrameDecoder.decode(other) == nil, "autre destination")
    }

    suite.add("LLDP et CDP : fusion des annonces du même switch") {
        var lldp = sampleLLDPFrame()
        let cdp = sampleCDPFrame()
        // Même nom système des deux côtés (domaine ignoré).
        let neighbors = NeighborFrameDecoder.neighbors(in: [CapturedFrame(bytes: cdp), CapturedFrame(bytes: lldp)])
        try expectEqual(neighbors.count, 2, "deux switchs différents")
        lldp = sampleLLDPFrame()
        var a = try NeighborFrameDecoder.decode(lldp).unwrap("lldp")
        a.systemName = "SW-CORE-01"
        a.voiceVLAN = nil
        let b = try NeighborFrameDecoder.decode(cdp).unwrap("cdp")
        try expect(a.isSameDevice(as: b), "même équipement malgré le domaine")
        let merged = a.merged(with: b)
        try expectEqual(merged.protocols, [.lldp, .cdp], "protocoles")
        try expectEqual(merged.portID, "1/22", "le port LLDP l’emporte")
        try expectEqual(merged.voiceVLAN, 30, "VLAN voix complété par CDP")
        try expectEqual(merged.softwareVersion?.hasPrefix("Cisco IOS"), true, "version complétée")
    }

    suite.add("DHCP : construction du DHCPDISCOVER (broadcast, xid, chaddr, options 53, 55, 61)") {
        let mac = MACAddress("3C:22:FB:7E:05:B1")!
        let packet = DHCPDiscover.build(xid: 0x5A1C_93E2, mac: mac)
        try expectEqual(packet.count, 300, "taille minimale BOOTP")
        try expectEqual(Array(packet[0..<4]), [1, 1, 6, 0], "op, htype, hlen, hops")
        try expectEqual(Array(packet[4..<8]), [0x5A, 0x1C, 0x93, 0xE2], "xid")
        try expectEqual(Array(packet[10..<12]), [0x80, 0x00], "drapeau broadcast")
        try expect(packet[12..<28].allSatisfy { $0 == 0 }, "ciaddr, yiaddr, siaddr, giaddr à zéro")
        try expectEqual(Array(packet[28..<34]), [0x3C, 0x22, 0xFB, 0x7E, 0x05, 0xB1], "chaddr")
        try expectEqual(Array(packet[236..<240]), [0x63, 0x82, 0x53, 0x63], "cookie magique")
        try expectEqual(Array(packet[240..<243]), [53, 1, 1], "option 53 = DISCOVER")
        try expectEqual(Array(packet[243..<252]), [61, 7, 1, 0x3C, 0x22, 0xFB, 0x7E, 0x05, 0xB1], "option 61")
        try expectEqual(Array(packet[252..<256]), [57, 2, 0x05, 0xDC], "option 57 = 1500")
        let list = DHCPDiscover.parameterRequestList
        try expectEqual(Array(packet[256..<258]), [55, UInt8(list.count)], "option 55")
        try expectEqual(Array(packet[258..<(258 + list.count)]), list, "paramètres demandés")
        try expectEqual(packet[258 + list.count], 255, "fin des options")
        for code: UInt8 in [1, 3, 6, 15, 51, 54, 58, 59, 66, 67, 43] {
            try expect(list.contains(code), "option \(code) demandée")
        }
        // Jamais de DHCPREQUEST : le seul type construit est DISCOVER.
        try expect(!packet[240...].starts(with: [53, 1, 3]), "pas de REQUEST")
        let unicast = DHCPDiscover.build(xid: 1, mac: mac, broadcast: false)
        try expectEqual(unicast[10], 0, "sans drapeau broadcast")
    }

    suite.add("DHCP : décodage complet d’une offre (54, 1, 3, 6, 15, 51, 58, 59, 66, 67, 43)") {
        let offer = try DHCPParser.parse(sampleDHCPOffer()).unwrap("offre")
        try expectEqual(offer.messageType, .offer, "type")
        try expectEqual(offer.xid, 0x5A1C_93E2, "xid")
        try expect(offer.flagsBroadcast, "drapeau broadcast")
        try expectEqual(offer.offeredAddress.description, "10.182.122.187", "adresse proposée")
        try expectEqual(offer.serverIdentifier?.description, "10.182.122.1", "serveur (54)")
        try expectEqual(offer.subnetMask?.description, "255.255.255.0", "masque")
        try expectEqual(offer.routers.map(\.description), ["10.182.122.1"], "passerelle")
        try expectEqual(offer.dnsServers.map(\.description), ["10.182.122.1", "8.8.8.8"], "DNS")
        try expectEqual(offer.domainName, "bureau.local", "domaine")
        try expectEqual(offer.leaseTime, 86_400, "bail")
        try expectEqual(offer.renewalTime, 43_200, "T1")
        try expectEqual(offer.rebindingTime, 75_600, "T2")
        try expectEqual(offer.tftpServer, "10.182.122.2", "option 66")
        try expectEqual(offer.bootFile, "pxelinux.0", "option 67")
        try expectEqual(offer.vendorSpecificHex, "01 04 0A B6 7A 02", "option 43")
        try expectEqual(offer.clientMAC, MACAddress("3C:22:FB:7E:05:B1"), "chaddr")
        try expectEqual(offer.subnet?.description, "10.182.122.0/24", "réseau distribué")
        try expectEqual(offer.optionCodes, [53, 54, 51, 58, 59, 1, 3, 6, 15, 66, 67, 43], "options présentes")
        try expectEqual(DHCPOffer.leaseText(86_400), "24\u{00A0}h", "bail lisible")
        try expectEqual(DHCPOffer.leaseText(7_200), "2\u{00A0}h", "bail 2 h")
        try expectEqual(DHCPOffer.leaseText(2_700), "45\u{00A0}min", "bail 45 min")
        try expectEqual(DHCPOffer.leaseText(691_200), "8\u{00A0}j", "bail 8 jours")
        try expectEqual(DHCPOffer.leaseText(6_300), "1\u{00A0}h\u{00A0}45", "bail 1 h 45")
        try expectEqual(DHCPOffer.leaseText(300_000), "3\u{00A0}j 11\u{00A0}h", "bail 3 j 11 h")
        // Une requête (op 1) ou un paquet tronqué ne sont pas des réponses.
        try expect(DHCPParser.parse(DHCPDiscover.build(xid: 1, mac: MACAddress("3C:22:FB:7E:05:B1")!)) == nil, "DISCOVER refusé")
        try expect(DHCPParser.parse(Array(sampleDHCPOffer().prefix(239))) == nil, "tronqué")
    }

    suite.add("DHCP : trame capturée d’un serveur non autorisé (MAC et IP sources)") {
        let rogue = try DHCPParser.parseFrame(sampleRogueDHCPFrame()).unwrap("trame")
        try expectEqual(rogue.sourceMAC, MACAddress("D8:07:B6:62:4E:A0"), "MAC source")
        try expectEqual(rogue.sourceAddress?.description, "10.182.122.250", "IP source")
        try expectEqual(rogue.serverIdentifier?.description, "192.168.0.1", "identifiant du serveur")
        try expectEqual(rogue.offeredAddress.description, "192.168.0.100", "adresse proposée")
        try expectEqual(DHCPOffer.leaseText(rogue.leaseTime), "2\u{00A0}h", "bail")
        let legit = try DHCPParser.parse(sampleDHCPOffer()).unwrap("offre")

        let policy = DHCPServerPolicy(text: "10.182.122.1, 10.182.122.250x ;")
        try expectEqual(policy.allowed.map(\.description), ["10.182.122.1"], "liste autorisée")
        try expectEqual(policy.invalid, ["10.182.122.250x"], "entrée illisible signalée")
        try expectEqual(policy.status(of: legit), .expected, "serveur attendu")
        try expectEqual(policy.status(of: rogue), .unauthorized, "serveur non autorisé")
        try expectEqual(DHCPServerPolicy(text: "").status(of: rogue), .unchecked, "liste vide : non vérifié")
        try expectEqual(DHCPServerPolicy(text: "10.182.122.250").status(of: rogue), .expected, "autorisé par son IP source")

        let servers = DHCPServerPolicy.uniqueServers([legit, rogue, legit], xid: 0x5A1C_93E2)
        try expectEqual(servers.count, 2, "une ligne par serveur")
        try expectEqual(DHCPServerPolicy.uniqueServers([legit], xid: 0x1234).count, 0, "autre xid ignoré")
        // Le filtre noyau DHCP garde cette trame ; le filtre LLDP/CDP la rejette.
        try expect(BPFFilter.run(BPFFilter.dhcpClient, on: sampleRogueDHCPFrame()) > 0, "filtre DHCP")
        try expectEqual(BPFFilter.run(BPFFilter.neighbors, on: sampleRogueDHCPFrame()), 0, "filtre voisins")
    }

    suite.add("DHCP : échange simulé sur 127.0.0.1 (socket partagée, offre reçue)") {
        let server = try LocalUDPServer()
        defer { server.stop() }
        let offerBytes = sampleDHCPOffer()
        server.replyOnce { request in
            // Le faux serveur répond avec le xid reçu, seulement à un DISCOVER.
            guard request.count >= 243, request[0] == 1, request[240..<243].elementsEqual([53, 1, 1]) else { return [] }
            var reply = offerBytes
            reply.replaceSubrange(4..<8, with: request[4..<8])
            return reply
        }
        guard let fd = try DHCPProbe.openSocket(interface: "lo0", port: 0, bindAddress: IPv4Address(127, 0, 0, 1)) else {
            throw TestFailure(message: "socket non liée", file: #fileID, line: #line)
        }
        defer { close(fd) }
        try expect(DHCPProbe.localPort(fd) > 0, "port local")
        let xid: UInt32 = 0x0BAD_CAFE
        let sentAt = Date()
        try DHCPProbe.send(DHCPDiscover.build(xid: xid, mac: MACAddress("3C:22:FB:7E:05:B1")!), fd: fd,
                           to: IPv4Address(127, 0, 0, 1), port: server.port)
        let offers = DHCPProbe.receive(fd: fd, xid: xid, until: Date().addingTimeInterval(2), sentAt: sentAt)
        try expectEqual(offers.count, 1, "une offre")
        try expectEqual(offers.first?.sourceAddress?.description, "127.0.0.1", "adresse source")
        try expectEqual(offers.first?.offeredAddress.description, "10.182.122.187", "adresse proposée")
        try expect((offers.first?.delay ?? -1) >= 0, "délai mesuré")
    }

    suite.add("Capture : analyse de la sortie hexadécimale de tcpdump (-e -xx)") {
        let sample = """
        tcpdump: listening on en7, link-type EN10MB (Ethernet), snapshot length 1600 bytes
        10:21:33.123456 88:3a:30:9c:41:22 > 01:80:c2:00:00:0e, ethertype LLDP (0x88cc), length 18: LLDP
        \t0x0000:  0180 c200 000e 883a 309c 4122 88cc 0207
        \t0x0010:  04
        10:21:34.000001 aa:bb:cc:dd:ee:ff > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 14:
        \t0x0000:  ffff ffff ffff aabb ccdd eeff 0806
        """
        let frames = TcpdumpHexParser.frames(from: sample)
        try expectEqual(frames.count, 2, "deux trames")
        try expectEqual(frames[0].bytes, [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E, 0x88, 0x3A, 0x30, 0x9C, 0x41, 0x22, 0x88, 0xCC, 0x02, 0x07, 0x04],
                        "octets de la première trame")
        try expectEqual(frames[1].bytes.count, 14, "deuxième trame")
        try expectEqual(TcpdumpHexParser.frames(from: sample, includeLast: false).count, 1, "dernière trame en attente")

        // Aller-retour : trames LLDP et CDP mises en forme comme tcpdump, puis décodées.
        let text = tcpdumpText(sampleLLDPFrame(), header: "10:00:00.000000 88:3a:30:9c:41:22 > 01:80:c2:00:00:0e, ethertype LLDP (0x88cc)")
            + "\n" + tcpdumpText(sampleCDPFrame(), header: "10:00:30.000000 00:1b:54:aa:01:25 > 01:00:0c:cc:cc:cc, 802.3, length 300")
        let parsed = TcpdumpHexParser.frames(from: text)
        try expectEqual(parsed.map(\.bytes), [sampleLLDPFrame(), sampleCDPFrame()], "octets identiques")
        let neighbors = NeighborFrameDecoder.neighbors(in: parsed, interface: "en7")
        try expectEqual(neighbors.map(\.switchLabel), ["SW-ETG2-01", "SW-CORE-01.bureau.local"], "voisins décodés")

        // Colonne ASCII (-X) ignorée, décalage incohérent : trame abandonnée.
        let ascii = "h\n\t0x0000:  0102 0304  ....\n"
        try expectEqual(TcpdumpHexParser.frames(from: ascii).map(\.bytes), [[1, 2, 3, 4]], "colonne ASCII ignorée")
        let broken = "h\n\t0x0010:  0102\n"
        try expectEqual(TcpdumpHexParser.frames(from: broken).count, 0, "décalage incohérent")

        try expect(TcpdumpHexParser.isListening("tcpdump: listening on en7, link-type EN10MB"), "capture commencée")
        try expectEqual(TcpdumpHexParser.errorMessage("tcpdump: en9: No such device exists\n(BIOCSETIF failed: Device not configured)"),
                        "tcpdump: en9: No such device exists (BIOCSETIF failed: Device not configured)", "message d’erreur")
        try expectEqual(TcpdumpHexParser.errorMessage("tcpdump: listening on en7\n3 packets captured\n3 packets received by filter\n0 packets dropped by kernel"),
                        nil, "pas d’erreur")
    }

    suite.add("Capture : nom d’interface et commande tcpdump strictement validés") {
        for good in ["en0", "en7", "bridge100", "en12"] {
            try expect(CaptureInterfaceName.isValid(good), "\(good) accepté")
        }
        for bad in ["", "EN0", "en0 ", "en0;rm", "en0'", "en-0", "en0\n", "../en0", "abcdefghijklmnop", "ën0"] {
            try expect(!CaptureInterfaceName.isValid(bad), "« \(bad) » refusé")
        }
        let dir = "/private/var/folders/x_/ab-c1/T/netscope-capture-1234"
        let out = "/private/tmp/netscope-capture-1234-abcd"
        let command = try PrivilegedCapture.shellCommand(interface: "en7", purpose: .neighbors, seconds: 90, directory: dir + "/",
                                                         outputDirectory: out, owner: 501)
        try expectEqual(command,
                        "umask 022; /bin/mkdir -m 755 '\(out)' || exit 1; "
                        + "/usr/sbin/tcpdump -i en7 -n -tt -e -xx -l -s 1600 'ether proto 0x88cc or ether dst 01:00:0c:cc:cc:cc' "
                        + ">'\(out)'/capture.txt 2>'\(out)'/tcpdump.txt & p=$!; i=0; "
                        + "while [ $i -lt 90 ] && [ ! -e '\(dir)/arreter' ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done; "
                        + "kill $p 2>/dev/null; wait $p 2>/dev/null; /usr/sbin/chown -R 501 '\(out)'; exit 0", "commande complète")
        // Root n'écrit que dans le dossier qu'il vient de créer, jamais dans celui de l'utilisateur.
        try expect(!command.contains(">'\(dir)"), "aucune redirection vers le dossier de l’utilisateur")
        let dhcp = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .dhcp, seconds: 30, directory: dir,
                                                      outputDirectory: out, owner: 501)
        try expect(dhcp.contains("'udp dst port 68'"), "filtre DHCP fixe")
        for badOut in ["/tmp/netscope-capture-1", "/private/tmp/netscope-capture-", "/private/tmp/netscope-capture-a/b",
                       "/private/tmp/netscope-capture-A1", "/private/tmp/autre", "/private/tmp/netscope-capture-a b"] {
            try expectThrows(ToolError.invalidInput("Dossier de sortie refusé."), "sortie « \(badOut) » refusée") {
                _ = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .dhcp, seconds: 30, directory: dir,
                                                       outputDirectory: badOut, owner: 501)
            }
        }
        try expectThrows(ToolError.invalidInput("Utilisateur refusé."), "root refusé comme propriétaire") {
            _ = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .dhcp, seconds: 30, directory: dir,
                                                   outputDirectory: out, owner: 0)
        }

        try expectThrows(ToolError.invalidInput("Nom d’interface refusé : « en0;reboot »."), "injection par l’interface") {
            _ = try PrivilegedCapture.shellCommand(interface: "en0;reboot", purpose: .neighbors, seconds: 90, directory: dir, outputDirectory: out, owner: 501)
        }
        try expectThrows(ToolError.invalidInput("Dossier de capture refusé."), "apostrophe dans le dossier") {
            _ = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .neighbors, seconds: 90, directory: "/tmp/a'b", outputDirectory: out, owner: 501)
        }
        try expectThrows(ToolError.invalidInput("Dossier de capture refusé."), "remontée de dossier") {
            _ = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .neighbors, seconds: 90, directory: "/tmp/../etc", outputDirectory: out, owner: 501)
        }
        try expectThrows(ToolError.invalidInput("Dossier de capture refusé."), "chemin relatif") {
            _ = try PrivilegedCapture.shellCommand(interface: "en0", purpose: .neighbors, seconds: 90, directory: "tmp/x", outputDirectory: out, owner: 501)
        }
        for seconds in [0, 4, 181, 100_000] {
            try expect((try? PrivilegedCapture.shellCommand(interface: "en0", purpose: .neighbors, seconds: seconds, directory: dir, outputDirectory: out, owner: 501)) == nil,
                       "durée \(seconds) refusée")
        }
        let script = try PrivilegedCapture.appleScript(for: command, prompt: PrivilegedCapture.prompt(for: .neighbors, interface: "en7"))
        try expect(script.hasPrefix("do shell script \"umask 022; /bin/mkdir -m 755 "), "script AppleScript")
        try expect(script.contains("/usr/sbin/tcpdump -i en7 -n -tt "), "tcpdump dans le script")
        try expect(script.hasSuffix("with administrator privileges"), "droits d’administrateur")
        try expect((try? PrivilegedCapture.appleScript(for: "echo \"x\"", prompt: "p")) == nil, "guillemet refusé")
        try expect((try? PrivilegedCapture.appleScript(for: "echo x\\", prompt: "p")) == nil, "barre oblique inverse refusée")
    }

    suite.add("Capture : filtres BPF, tampon BPF et codes ioctl") {
        try expectEqual(BPFFilter.run(BPFFilter.neighbors, on: sampleLLDPFrame()), 65_535, "LLDP accepté")
        try expectEqual(BPFFilter.run(BPFFilter.neighbors, on: sampleCDPFrame()), 65_535, "CDP accepté")
        try expectEqual(BPFFilter.run(BPFFilter.dhcpClient, on: sampleLLDPFrame()), 0, "LLDP hors filtre DHCP")
        try expectEqual(BPFFilter.run(BPFFilter.neighbors, on: [0x01, 0x80]), 0, "trame trop courte")
        // UDP vers le port 67 (requête d'un autre client) : rejeté.
        var toServer = sampleRogueDHCPFrame()
        toServer[14 + 20 + 3] = 67
        try expectEqual(BPFFilter.run(BPFFilter.dhcpClient, on: toServer), 0, "port 67 rejeté")
        // Fragment IP : rejeté.
        var fragment = sampleRogueDHCPFrame()
        fragment[14 + 7] = 0x08
        try expectEqual(BPFFilter.run(BPFFilter.dhcpClient, on: fragment), 0, "fragment rejeté")

        // Deux enregistrements bpf_hdr (18 octets d'en-tête, alignés sur 4).
        func record(_ frame: [UInt8], seconds: UInt32) -> [UInt8] {
            func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
            var bytes = le32(seconds) + le32(500_000) + le32(UInt32(frame.count)) + le32(UInt32(frame.count)) + [18, 0]
            bytes += frame
            while bytes.count % 4 != 0 { bytes.append(0) }
            return bytes
        }
        let buffer = record(sampleLLDPFrame(), seconds: 1_700_000_000) + record(sampleCDPFrame(), seconds: 1_700_000_030)
        let frames = BPFBuffer.frames(in: buffer + [0, 0, 0, 0], length: buffer.count)
        try expectEqual(frames.map(\.bytes), [sampleLLDPFrame(), sampleCDPFrame()], "trames du tampon")
        try expectEqual(frames.first?.date?.timeIntervalSince1970, 1_700_000_000.5, "horodatage")
        try expectEqual(BPFBuffer.frames(in: Array(buffer.prefix(30))).count, 0, "enregistrement incomplet ignoré")

        try expectEqual(BPFIoctl.setInterface, 0x8020_426C, "BIOCSETIF")
        try expectEqual(BPFIoctl.immediate, 0x8004_4270, "BIOCIMMEDIATE")
        try expectEqual(BPFIoctl.getBufferLength, 0x4004_4266, "BIOCGBLEN")
        try expectEqual(BPFIoctl.setBufferLength, 0xC004_4266, "BIOCSBLEN")
        try expectEqual(BPFIoctl.setFilter, 0x8010_4267, "BIOCSETF")
        try expectEqual(BPFIoctl.promiscuous, 0x2000_4269, "BIOCPROMISC")
    }

    suite.add("Capture : horodatage des trames lues dans la sortie de tcpdump") {
        // -tt : secondes epoch ; chaque trame garde l'heure de sa ligne d'en-tête, pas l'heure de lecture.
        let text = tcpdumpText(sampleLLDPFrame(), header: "1762183293.250000 88:3a:30:9c:41:22 > 01:80:c2:00:00:0e, ethertype LLDP (0x88cc)")
            + "\n" + tcpdumpText(sampleCDPFrame(), header: "1762183323.500000 00:1b:54:aa:01:25 > 01:00:0c:cc:cc:cc, 802.3, length 300")
        let readAt = Date(timeIntervalSince1970: 1_762_183_400)
        let frames = TcpdumpHexParser.frames(from: text, now: readAt)
        try expectEqual(frames.map { $0.date?.timeIntervalSince1970 ?? 0 }, [1_762_183_293.25, 1_762_183_323.5], "deux dates")
        let neighbors = NeighborFrameDecoder.neighbors(in: frames, interface: "en7", now: readAt)
        try expectEqual(neighbors.first?.receivedAt?.timeIntervalSince1970, 1_762_183_293.25, "réception LLDP à l’heure de la trame")
        try expectEqual(neighbors.last?.receivedAt?.timeIntervalSince1970, 1_762_183_323.5, "réception CDP à l’heure de la trame")

        // Sans -tt : « HH:MM:SS.ffffff », heure locale du jour (ou de la veille juste après minuit).
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_762_183_293))
        let noon = midnight.addingTimeInterval(12 * 3600)
        try expectEqual(TcpdumpHexParser.timestamp(of: "10:21:33.500000 88:3a:30:9c:41:22 > x", now: noon)?.timeIntervalSince(midnight),
                        37_293.5, "heure du jour")
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let lateEvening = calendar.date(byAdding: .day, value: -1, to: nextMidnight)!.addingTimeInterval(86_399)
        try expectEqual(TcpdumpHexParser.timestamp(of: "23:59:59.000000 x", now: nextMidnight.addingTimeInterval(1800)),
                        lateEvening, "trame de la veille")
        for bad in ["tcpdump: listening on en7", "25:00:00.0 x", "10:61:00.0 x", "abc x", ".5 x", "0 x"] {
            try expect(TcpdumpHexParser.timestamp(of: bad) == nil, "« \(bad) » sans date")
        }
    }

    suite.add("DHCP : option 52 (options dans les champs file et sname)") {
        func offer(overload: UInt8, sname: [UInt8], file: [UInt8]) -> [UInt8] {
            var p: [UInt8] = [0x02, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x80, 0x00]
            p += [0, 0, 0, 0, 0x0A, 0x00, 0x00, 0x32, 0, 0, 0, 0, 0, 0, 0, 0]
            p += [0x3C, 0x22, 0xFB, 0x7E, 0x05, 0xB1] + [UInt8](repeating: 0, count: 10)
            p += sname + [UInt8](repeating: 0, count: 64 - sname.count)
            p += file + [UInt8](repeating: 0, count: 128 - file.count)
            p += [0x63, 0x82, 0x53, 0x63, 53, 1, 2, 54, 4, 0x0A, 0x00, 0x00, 0x01, 52, 1, overload, 255]
            return p
        }
        let fileOptions: [UInt8] = [66, 8] + Array("10.0.0.9".utf8) + [67, 8] + Array("boot.efi".utf8) + [255]
        let snameOptions: [UInt8] = [15, 7] + Array("site.ca".utf8) + [3, 4, 0x0A, 0x00, 0x00, 0xFE, 255]
        let both = try DHCPParser.parse(offer(overload: 3, sname: snameOptions, file: fileOptions)).unwrap("offre 52 = 3")
        try expectEqual(both.tftpServer, "10.0.0.9", "option 66 lue dans file")
        try expectEqual(both.bootFile, "boot.efi", "option 67 lue dans file")
        try expectEqual(both.domainName, "site.ca", "option 15 lue dans sname")
        try expectEqual(both.routers.map(\.description), ["10.0.0.254"], "option 3 lue dans sname")
        try expect(both.bootFileHeader == nil, "file n’est pas un nom de fichier")
        try expect(both.serverName == nil, "sname n’est pas un nom de serveur")

        // 52 = 1 : seul file porte des options ; sname reste le nom du serveur.
        let fileOnly = try DHCPParser.parse(offer(overload: 1, sname: Array("srv-dhcp".utf8), file: fileOptions)).unwrap("offre 52 = 1")
        try expectEqual(fileOnly.tftpServer, "10.0.0.9", "file lu comme options")
        try expectEqual(fileOnly.serverName, "srv-dhcp", "sname lu comme texte")
        try expect(fileOnly.domainName == nil, "sname non interprété")
        // 52 = 2 : l'inverse.
        let snameOnly = try DHCPParser.parse(offer(overload: 2, sname: snameOptions, file: Array("pxelinux.0".utf8))).unwrap("offre 52 = 2")
        try expectEqual(snameOnly.domainName, "site.ca", "sname lu comme options")
        try expectEqual(snameOnly.bootFileHeader, "pxelinux.0", "file lu comme texte")
        try expect(snameOnly.tftpServer == nil, "file non interprété")
    }

    suite.add("Capture : trames étiquetées 802.1Q / 802.1ad, en-tête IP avec options, fragments") {
        let lldp = sampleLLDPFrame()
        let tagged = Array(lldp[0..<12]) + [0x81, 0x00, 0x00, 0x0A] + Array(lldp[12...])
        let header = try EthernetHeader.parse(tagged).unwrap("en-tête 802.1Q")
        try expectEqual(header.vlanTag, 10, "VLAN de l’étiquette")
        try expectEqual(header.typeOrLength, 0x88CC, "EtherType après l’étiquette")
        try expectEqual(header.payloadOffset, 18, "charge utile décalée de 4")
        try expectEqual(NeighborFrameDecoder.decode(tagged, interface: "en7")?.switchLabel, "SW-ETG2-01", "LLDP étiqueté décodé")
        let qinq = Array(lldp[0..<12]) + [0x88, 0xA8, 0x00, 0x64, 0x81, 0x00, 0x00, 0x0A] + Array(lldp[12...])
        let outer = try EthernetHeader.parse(qinq).unwrap("en-tête 802.1ad")
        try expectEqual(outer.vlanTag, 10, "VLAN le plus intérieur")
        try expectEqual(outer.payloadOffset, 22, "charge utile décalée de 8")
        try expect(EthernetHeader.parse(Array(qinq.prefix(17))) == nil, "étiquette tronquée")

        // IHL = 6 : quatre octets d'options IP (NOP) avant UDP.
        let plain = sampleRogueDHCPFrame()
        var ipOptions = Array(plain[0..<14]) + [0x46] + Array(plain[15..<34]) + [0x01, 0x01, 0x01, 0x01] + Array(plain[34...])
        let total = (Int(ipOptions[16]) << 8 | Int(ipOptions[17])) + 4
        ipOptions[16] = UInt8(total >> 8)
        ipOptions[17] = UInt8(total & 0xFF)
        let withOptions = try DHCPParser.parseFrame(ipOptions).unwrap("offre avec options IP")
        try expectEqual(withOptions.offeredAddress.description, "192.168.0.100", "UDP trouvé après les options IP")
        try expect(BPFFilter.run(BPFFilter.dhcpClient, on: ipOptions) > 0, "filtre noyau : port lu après les options IP")

        // Premier fragment (drapeau « autres fragments ») : refusé des deux côtés.
        var firstFragment = plain
        firstFragment[14 + 6] = 0x20
        try expect(DHCPParser.parseFrame(firstFragment) == nil, "premier fragment refusé par l’analyseur")
        try expectEqual(BPFFilter.run(BPFFilter.dhcpClient, on: firstFragment), 0, "premier fragment refusé par le filtre")
        var laterFragment = plain
        laterFragment[14 + 7] = 0x08
        try expect(DHCPParser.parseFrame(laterFragment) == nil, "fragment suivant refusé par l’analyseur")
        // Trame DHCP étiquetée : décodée aussi.
        let taggedDHCP = Array(plain[0..<12]) + [0x81, 0x00, 0x00, 0x14] + Array(plain[12...])
        try expectEqual(DHCPParser.parseFrame(taggedDHCP)?.offeredAddress.description, "192.168.0.100", "offre étiquetée VLAN 20")
    }

    suite.add("Outils : interfaces sans adresse et alerte DHCP sans doublon") {
        let wifi = LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!, netmask: IPv4Address("255.255.255.0")!, kind: .wifi)
        let apipa = LocalInterface(name: "en7", address: IPv4Address("169.254.12.7")!, netmask: IPv4Address("255.255.0.0")!, kind: .ethernet)
        let bare = LocalInterface(name: "en8", address: IPv4Address(0), netmask: IPv4Address(0), kind: .autre)
        try expectEqual(wifi.linkSummary, "en0 · Wi-Fi", "adresse routable : nom et type")
        try expectEqual(wifi.addressLabel, "10.182.122.135", "adresse affichée")
        try expectEqual(apipa.linkSummary, "en7 · Ethernet · 169.254.12.7 (liaison locale)", "liaison locale")
        try expectEqual(bare.linkSummary, "en8 · Autre · sans adresse", "sans adresse")
        try expect(!bare.hasIPv4 && apipa.hasIPv4, "présence d’une adresse")
        try expectEqual(LocalInterfaces.preferredLinkInterface(in: [wifi, apipa], preferred: "en0")?.name, "en7", "Ethernet d’abord")
        try expectEqual(LocalInterfaces.preferredLinkInterface(in: [wifi, bare], preferred: "en0")?.name, "en0", "puis l’interface active")
        try expect(LocalInterfaces.preferredLinkInterface(in: []) == nil, "aucune interface")

        var store = InventoryStore()
        let ip = IPv4Address("10.182.122.250")!
        let now = Date()
        func alert(_ date: Date) -> InvEvent {
            InvEvent(date: date, kind: .dhcpNonAutorise, severity: .critique, key: "ip:10.182.122.250", ip: ip,
                     title: "Serveur DHCP non autorisé", detail: "Offre 192.168.0.100")
        }
        try expect(store.addAlert(alert(now)), "première alerte ajoutée")
        try expect(!store.addAlert(alert(now.addingTimeInterval(60))), "doublon refusé")
        try expectEqual(store.events.filter(\.isAlert).count, 1, "une seule alerte")
        try expect(store.addAlert(alert(now.addingTimeInterval(90_000))), "nouvelle alerte le lendemain")
        try expectEqual(InvEventKind.dhcpNonAutorise.label, "Serveur DHCP", "libellé")
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
