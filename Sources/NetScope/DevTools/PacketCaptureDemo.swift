import Foundation
import NetScopeCore

/// Capture fictive de la démonstration (`--demo`) : douze secondes sur la prise Ethernet du
/// bureau 214 (en7). Paquets fabriqués par PacketForge, sommes de contrôle comprises ; rien n'est
/// capturé ni envoyé. On y trouve ARP, DNS, TLS vers outlook.office365.com (avec une retransmission
/// et un ACK en double), mDNS, DHCP, NetBIOS, HTTP vers l'imprimante, un RST, ICMP, IPv6, LLDP et STP.
/// Captures d'écran : NETSCOPE_OUTIL_DEMO=capture ; NETSCOPE_CAPTURE_VUE=flux|stats|filtre.
enum PacketCaptureDemo {
    static let interface = "en7"

    static let mac = MACAddress("3c:a6:f6:1b:22:9e")!
    static let me = IPv4Address("10.182.122.142")!
    static let gatewayMAC = MACAddress("04:d5:90:3a:7c:11")!
    static let gateway = IPv4Address("10.182.122.1")!
    static let printerMAC = MACAddress("94:dd:f8:18:15:7d")!
    static let printer = IPv4Address("10.182.122.111")!
    static let appleTVMAC = MACAddress("d0:03:4b:5e:21:8a")!
    static let appleTV = IPv4Address("10.182.122.58")!
    static let phoneMAC = MACAddress("ba:7e:21:c4:90:13")!
    static let otherPCMAC = MACAddress("b0:7b:25:44:9f:20")!
    static let otherPC = IPv4Address("10.182.122.137")!
    static let switchMAC = MACAddress("88:3a:30:9c:41:22")!
    static let broadcast = MACAddress(value: 0xFFFF_FFFF_FFFF)
    static let outlook = IPv4Address("52.96.88.50")!

    /// Début de la capture : 4 novembre 2026, 10 h 21 min 33 s (heure de l'Est).
    static let start: TimeInterval = 1_793_805_693.204_518

    static func records() -> [PacketRecord] {
        var list: [(Double, [UInt8])] = []
        func add(_ time: Double, _ frame: [UInt8]) { list.append((time, frame)) }
        let meMAC = mac

        // ARP : la passerelle.
        add(0.000_000, PacketForge.arp(operation: 1, senderMAC: meMAC, senderIP: me, targetMAC: MACAddress(value: 0), targetIP: gateway))
        add(0.001_204, PacketForge.arp(operation: 2, senderMAC: gatewayMAC, senderIP: gateway, targetMAC: meMAC, targetIP: me))

        // DNS : outlook.office365.com (A, réponse par CNAME), puis teams.microsoft.com (AAAA) plus loin.
        let name = PacketForge.dnsName("outlook.office365.com")
        let cname = PacketForge.dnsName("outlook.ha.office365.com")
        let cnamePointer: [UInt8] = [0xC0, UInt8(12 + name.count + 4 + 12)]
        add(0.010_311, udp(meMAC, me, 61_204, gatewayMAC, gateway, 53,
                           PacketForge.dnsMessage(id: 0x8F3A, flags: 0x0100, questions: [(name, 1, 1)])))
        add(0.034_118, udp(gatewayMAC, gateway, 53, meMAC, me, 61_204, PacketForge.dnsMessage(
            id: 0x8F3A, flags: 0x8180, questions: [(name, 1, 1)],
            answers: [PacketForge.Record(name: PacketForge.questionPointer, type: 5, ttl: 247, data: cname),
                      PacketForge.Record(name: cnamePointer, type: 1, ttl: 18, data: PacketForge.ipv4Bytes(outlook)),
                      PacketForge.Record(name: cnamePointer, type: 1, ttl: 18, data: PacketForge.ipv4Bytes(IPv4Address("52.96.88.66")!))])))
        let teams = PacketForge.dnsName("teams.microsoft.com")
        let teamsTarget = PacketForge.dnsName("teams-office-com.s-0005.dc-msedge.net")
        let teamsPointer: [UInt8] = [0xC0, UInt8(12 + teams.count + 4 + 12)]
        add(0.902_417, udp(meMAC, me, 61_211, gatewayMAC, gateway, 53,
                           PacketForge.dnsMessage(id: 0x41C7, flags: 0x0100, questions: [(teams, 28, 1)])))
        add(0.925_036, udp(gatewayMAC, gateway, 53, meMAC, me, 61_211, PacketForge.dnsMessage(
            id: 0x41C7, flags: 0x8180, questions: [(teams, 28, 1)],
            answers: [PacketForge.Record(name: PacketForge.questionPointer, type: 5, ttl: 1_800, data: teamsTarget),
                      PacketForge.Record(name: teamsPointer, type: 28, ttl: 240, data: PacketForge.ipv6Address("2620:1ec:42::132"))])))

        // TLS vers Outlook : poignée de main TCP, Client Hello (SNI), Server Hello, données.
        let client = (meMAC, me, UInt16(52_144)), server = (gatewayMAC, outlook, UInt16(443))
        let back = (gatewayMAC, outlook, UInt16(443)), toMe = (meMAC, me, UInt16(52_144))
        let c: UInt32 = 3_942_117_104, s: UInt32 = 1_220_446_911
        let hello = PacketForge.tlsClientHello(serverName: "outlook.office365.com")
        let serverHello = PacketForge.tlsServerHello(encryptedLength: 1_180)
        let clientData = PacketForge.tlsApplicationData(length: 610, seed: 0x21)
        let serverData = PacketForge.tlsApplicationData(length: 1_315, seed: 0x44)
        let serverData2 = PacketForge.tlsApplicationData(length: 1_315, seed: 0x45)
        add(0.040_515, PacketForge.tcpFrame(client, server, sequence: c, acknowledgment: 0, flags: 0x002, options: PacketForge.synOptions, id: 0x2A10))
        add(0.061_877, PacketForge.tcpFrame(back, toMe, sequence: s, acknowledgment: c + 1, flags: 0x012, window: 65_160,
                                            options: [0x02, 0x04, 0x05, 0xB4, 0x01, 0x03, 0x03, 0x08, 0x04, 0x02], ttl: 113, id: 0x6E01))
        add(0.061_990, PacketForge.tcpFrame(client, server, sequence: c + 1, acknowledgment: s + 1, flags: 0x010, window: 2_058, id: 0x2A11))
        add(0.062_345, PacketForge.tcpFrame(client, server, sequence: c + 1, acknowledgment: s + 1, flags: 0x018, window: 2_058, payload: hello, id: 0x2A12))
        let afterHello = c + 1 + UInt32(hello.count)
        add(0.085_710, PacketForge.tcpFrame(back, toMe, sequence: s + 1, acknowledgment: afterHello, flags: 0x010, window: 501, ttl: 113, id: 0x6E02))
        add(0.088_402, PacketForge.tcpFrame(back, toMe, sequence: s + 1, acknowledgment: afterHello, flags: 0x018, window: 501, payload: serverHello, ttl: 113, id: 0x6E03))
        let afterServerHello = s + 1 + UInt32(serverHello.count)
        add(0.088_560, PacketForge.tcpFrame(client, server, sequence: afterHello, acknowledgment: afterServerHello, flags: 0x010, window: 2_048, id: 0x2A13))
        add(0.090_118, PacketForge.tcpFrame(client, server, sequence: afterHello, acknowledgment: afterServerHello, flags: 0x018, window: 2_048, payload: clientData, id: 0x2A14))
        let afterClientData = afterHello + UInt32(clientData.count)
        // Le premier segment de données du serveur se perd en route : seul le second arrive, ce Mac
        // répète son accusé (ACK en double), puis le serveur renvoie le segment perdu.
        let secondSegment = afterServerHello + UInt32(serverData.count)
        add(0.112_906, PacketForge.tcpFrame(back, toMe, sequence: secondSegment, acknowledgment: afterClientData, flags: 0x018, window: 501, payload: serverData2, ttl: 113, id: 0x6E05))
        add(0.113_017, PacketForge.tcpFrame(client, server, sequence: afterClientData, acknowledgment: afterServerHello, flags: 0x010, window: 2_048,
                                            options: [0x01, 0x01, 0x05, 0x0A] + Self.be32(secondSegment) + Self.be32(secondSegment + UInt32(serverData2.count)), id: 0x2A15))
        add(0.418_330, PacketForge.tcpFrame(back, toMe, sequence: afterServerHello, acknowledgment: afterClientData, flags: 0x018, window: 501, payload: serverData, ttl: 113, id: 0x6E04))
        let afterServerData = secondSegment + UInt32(serverData2.count)
        add(0.418_412, PacketForge.tcpFrame(client, server, sequence: afterClientData, acknowledgment: afterServerData, flags: 0x010, window: 2_048, id: 0x2A16))

        // mDNS : recherche AirPlay et réponse de l'Apple TV du salon.
        let airplay = PacketForge.dnsName("_airplay._tcp.local")
        add(1.204_731, udp(meMAC, me, 5353, MACAddress("01:00:5e:00:00:fb")!, IPv4Address("224.0.0.251")!, 5353,
                           PacketForge.dnsMessage(id: 0, flags: 0, questions: [(airplay, 12, 1)]), ttl: 255))
        let instance = PacketForge.dnsName("Salon._airplay._tcp.local")
        let host = PacketForge.dnsName("Apple-TV-Salon.local")
        add(1.251_088, udp(appleTVMAC, appleTV, 5353, MACAddress("01:00:5e:00:00:fb")!, IPv4Address("224.0.0.251")!, 5353,
                           PacketForge.dnsMessage(id: 0, flags: 0x8400, questions: [], answers: [
                            PacketForge.Record(name: airplay, type: 12, ttl: 4_500, data: instance),
                            PacketForge.Record(name: instance, type: 33, klass: 0x8001, ttl: 120, data: [0, 0, 0, 0, 0x1B, 0x58] + host),
                            PacketForge.Record(name: instance, type: 16, klass: 0x8001, ttl: 4_500, data: [12] + Array("model=AppleTV".utf8.prefix(12))),
                            PacketForge.Record(name: host, type: 1, klass: 0x8001, ttl: 120, data: PacketForge.ipv4Bytes(appleTV)),
                           ]), ttl: 255))

        // DHCP : un téléphone se branche au Wi-Fi invité relayé sur ce VLAN.
        let xid: UInt32 = 0x7B2E_91C4
        let offered = IPv4Address("10.182.122.188")!
        let anyIP = IPv4Address(0), all = IPv4Address("255.255.255.255")!
        let phoneOptions: [(UInt8, [UInt8])] = [(53, [1]), (61, [1] + phoneMAC.bytes), (55, [1, 3, 6, 15, 119, 252]), (12, Array("iPhone-de-Julie".utf8))]
        add(2.003_117, udp(phoneMAC, anyIP, 68, broadcast, all, 67, PacketForge.dhcp(op: 1, xid: xid, client: phoneMAC, options: phoneOptions), ttl: 255))
        let serverOptions: [(UInt8, [UInt8])] = [(53, [2]), (54, PacketForge.ipv4Bytes(gateway)), (51, [0, 1, 0x51, 0x80]), (1, [255, 255, 255, 0]),
                                                  (3, PacketForge.ipv4Bytes(gateway)), (6, PacketForge.ipv4Bytes(gateway)), (15, Array("bureau.local".utf8))]
        add(2.007_442, udp(gatewayMAC, gateway, 67, broadcast, all, 68, PacketForge.dhcp(op: 2, xid: xid, client: phoneMAC, yourAddress: offered, options: serverOptions)))
        add(2.010_905, udp(phoneMAC, anyIP, 68, broadcast, all, 67, PacketForge.dhcp(op: 1, xid: xid, client: phoneMAC, options: [
            (53, [3]), (50, PacketForge.ipv4Bytes(offered)), (54, PacketForge.ipv4Bytes(gateway)), (12, Array("iPhone-de-Julie".utf8))]), ttl: 255))
        var ack = serverOptions
        ack[0] = (53, [5])
        add(2.014_336, udp(gatewayMAC, gateway, 67, broadcast, all, 68, PacketForge.dhcp(op: 2, xid: xid, client: phoneMAC, yourAddress: offered, options: ack)))

        // NetBIOS : un poste Windows cherche l'imprimante partagée.
        add(3.118_204, udp(otherPCMAC, otherPC, 137, broadcast, IPv4Address("10.182.122.255")!, 137,
                           PacketForge.dnsMessage(id: 0x82A4, flags: 0x0110, questions: [(PacketForge.netbiosName("IMPR-COMPTA", suffix: 0x20), 0x20, 1)])))

        // HTTP en clair vers la page d'état de l'imprimante.
        let web = (meMAC, me, UInt16(52_150)), printerPort = (printerMAC, printer, UInt16(80))
        let printerBack = (printerMAC, printer, UInt16(80)), toWeb = (meMAC, me, UInt16(52_150))
        let request = Array("GET /general/status.html HTTP/1.1\r\nHost: 10.182.122.111\r\nUser-Agent: NetScope/0.7\r\nAccept: text/html\r\n\r\n".utf8)
        let response = Array("HTTP/1.1 200 OK\r\nServer: debut/1.30\r\nContent-Type: text/html\r\nContent-Length: 64\r\n\r\n<html><body><p>Prête · Toner 62 %</p><p>Bac 1 : A4</p></body></html>".utf8)
        let pc: UInt32 = 881_442_001, ps: UInt32 = 20_119_500
        add(3.402_118, PacketForge.tcpFrame(web, printerPort, sequence: pc, acknowledgment: 0, flags: 0x002, options: PacketForge.synOptions, id: 0x2B01))
        add(3.403_906, PacketForge.tcpFrame(printerBack, toWeb, sequence: ps, acknowledgment: pc + 1, flags: 0x012, window: 8_192,
                                            options: [0x02, 0x04, 0x05, 0xB4], ttl: 64, id: 0x0101))
        add(3.404_011, PacketForge.tcpFrame(web, printerPort, sequence: pc + 1, acknowledgment: ps + 1, flags: 0x010, window: 2_058, id: 0x2B02))
        add(3.404_230, PacketForge.tcpFrame(web, printerPort, sequence: pc + 1, acknowledgment: ps + 1, flags: 0x018, window: 2_058, payload: request, id: 0x2B03))
        let afterRequest = pc + 1 + UInt32(request.count)
        add(3.431_667, PacketForge.tcpFrame(printerBack, toWeb, sequence: ps + 1, acknowledgment: afterRequest, flags: 0x019, window: 8_192, payload: response, id: 0x0102))
        let afterResponse = ps + 1 + UInt32(response.count) + 1
        add(3.431_802, PacketForge.tcpFrame(web, printerPort, sequence: afterRequest, acknowledgment: afterResponse, flags: 0x011, window: 2_058, id: 0x2B04))
        add(3.433_015, PacketForge.tcpFrame(printerBack, toWeb, sequence: afterResponse, acknowledgment: afterRequest + 1, flags: 0x010, window: 8_192, id: 0x0103))

        // Port fermé sur l'imprimante : réinitialisation.
        let probe = (meMAC, me, UInt16(52_160)), closed = (printerMAC, printer, UInt16(8_080))
        add(5.012_330, PacketForge.tcpFrame(probe, closed, sequence: 2_000_000, acknowledgment: 0, flags: 0x002, options: PacketForge.synOptions, id: 0x2B10))
        add(5.013_902, PacketForge.tcpFrame((printerMAC, printer, 8_080), (meMAC, me, 52_160), sequence: 0, acknowledgment: 2_000_001, flags: 0x014, window: 0, id: 0x0110))

        // Ping vers 8.8.8.8.
        var echo: [UInt8] = [8, 0, 0, 0, 0x00, 0x2A, 0x00, 0x01] + Array("NetScope ping 0123456789abcdef".utf8)
        var sum = InternetChecksumDemo.checksum(echo)
        echo[2] = UInt8(sum >> 8); echo[3] = UInt8(sum & 0xFF)
        add(6.002_118, PacketForge.ethernet(source: meMAC, destination: gatewayMAC, type: 0x0800,
                                            payload: PacketForge.ipv4(source: me, destination: IPv4Address("8.8.8.8")!, protocol: 1, payload: echo, id: 0x2C01)))
        echo[0] = 0; echo[2] = 0; echo[3] = 0
        sum = InternetChecksumDemo.checksum(echo)
        echo[2] = UInt8(sum >> 8); echo[3] = UInt8(sum & 0xFF)
        add(6.014_870, PacketForge.ethernet(source: gatewayMAC, destination: meMAC, type: 0x0800,
                                            payload: PacketForge.ipv4(source: IPv4Address("8.8.8.8")!, destination: me, protocol: 1, payload: echo, ttl: 117, id: 0x0000)))

        // IPv6 : sollicitation et annonce de voisin vers le routeur.
        let linkLocal = PacketForge.ipv6Address("fe80::1c2b:3aff:fe4d:5e6f"), router = PacketForge.ipv6Address("fe80::1")
        add(7.000_441, PacketForge.ethernet(source: meMAC, destination: MACAddress("33:33:ff:00:00:01")!, type: 0x86DD,
                                            payload: PacketForge.ipv6(source: linkLocal, destination: PacketForge.ipv6Address("ff02::1:ff00:1"), next: 58,
                                                                      payload: InternetChecksumDemo.icmpv6([135, 0, 0, 0, 0, 0, 0, 0] + router + [1, 1] + meMAC.bytes,
                                                                                                           source: linkLocal, destination: PacketForge.ipv6Address("ff02::1:ff00:1")))))
        add(7.001_870, PacketForge.ethernet(source: gatewayMAC, destination: meMAC, type: 0x86DD,
                                            payload: PacketForge.ipv6(source: router, destination: linkLocal, next: 58,
                                                                      payload: InternetChecksumDemo.icmpv6([136, 0, 0, 0, 0xE0, 0, 0, 0] + router + [2, 1] + gatewayMAC.bytes,
                                                                                                           source: router, destination: linkLocal))))

        // Annonces du switch : LLDP (toutes les 30 s) et BPDU RSTP (toutes les 2 s).
        add(8.512_004, lldpFrame())
        add(9.000_130, stpFrame())
        add(11.000_214, stpFrame())

        // SSDP : recherche des équipements UPnP.
        add(10.204_551, udp(meMAC, me, 58_812, MACAddress("01:00:5e:7f:ff:fa")!, IPv4Address("239.255.255.250")!, 1900,
                            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n".utf8), ttl: 1))

        // DNS d'un nom inexistant.
        let missing = PacketForge.dnsName("imprimante-rh.bureau.local")
        add(11.402_331, udp(meMAC, me, 61_330, gatewayMAC, gateway, 53, PacketForge.dnsMessage(id: 0x5D02, flags: 0x0100, questions: [(missing, 1, 1)])))
        add(11.404_809, udp(gatewayMAC, gateway, 53, meMAC, me, 61_330, PacketForge.dnsMessage(id: 0x5D02, flags: 0x8183, questions: [(missing, 1, 1)])))

        return list.sorted { $0.0 < $1.0 }.map { PacketRecord(timestamp: start + $0.0, data: $0.1) }
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func udp(_ sourceMAC: MACAddress, _ source: IPv4Address, _ sourcePort: UInt16,
                            _ destinationMAC: MACAddress, _ destination: IPv4Address, _ destinationPort: UInt16,
                            _ payload: [UInt8], ttl: UInt8 = 64) -> [UInt8] {
        PacketForge.udpFrame((sourceMAC, source, sourcePort), (destinationMAC, destination, destinationPort), payload: payload, ttl: ttl)
    }

    /// Trame LLDP du switch SW-ETG2-01 (port 1/22, PVID 1), comme la capture LLDP/CDP.
    private static func lldpFrame() -> [UInt8] {
        func tlv(_ type: Int, _ value: [UInt8]) -> [UInt8] {
            let header = UInt16(type) << 9 | UInt16(value.count)
            return [UInt8(header >> 8), UInt8(header & 0xFF)] + value
        }
        var pdu = tlv(1, [4] + MACAddress("88:3a:30:9c:41:00")!.bytes)
        pdu += tlv(2, [5] + Array("1/22".utf8))
        pdu += tlv(3, [0x00, 0x78])
        pdu += tlv(4, Array("Bureau 214 - prise B".utf8))
        pdu += tlv(5, Array("SW-ETG2-01".utf8))
        pdu += tlv(6, Array("Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012".utf8))
        pdu += tlv(7, [0x00, 0x14, 0x00, 0x14])
        pdu += tlv(8, [0x05, 0x01, 0x0A, 0xB6, 0x7A, 0x03, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00])
        pdu += tlv(127, [0x00, 0x80, 0xC2, 0x01, 0x00, 0x01])
        pdu += tlv(127, [0x00, 0x12, 0x0F, 0x01, 0x03, 0x6C, 0x01, 0x00, 0x1E])
        pdu += [0x00, 0x00]
        return PacketForge.ethernet(source: switchMAC, destination: MACAddress("01:80:c2:00:00:0e")!, type: 0x88CC, payload: pdu)
    }

    /// BPDU RSTP du switch (racine : le cœur SW-CORE-01).
    private static func stpFrame() -> [UInt8] {
        var bpdu: [UInt8] = [0x00, 0x00, 0x02, 0x02, 0x3C, 0x10, 0x00] + MACAddress("00:1b:54:aa:01:00")!.bytes
        bpdu += [0x00, 0x00, 0x4E, 0x20, 0x80, 0x00] + switchMAC.bytes
        bpdu += [0x80, 0x16, 0x01, 0x00, 0x14, 0x00, 0x02, 0x00, 0x0F, 0x00, 0x00]
        let llc: [UInt8] = [0x42, 0x42, 0x03] + bpdu
        var frame = MACAddress("01:80:c2:00:00:00")!.bytes + switchMAC.bytes + [UInt8(llc.count >> 8), UInt8(llc.count & 0xFF)] + llc
        if frame.count < 60 { frame += [UInt8](repeating: 0, count: 60 - frame.count) }
        return frame
    }
}

/// Sommes de contrôle des paquets ICMP fabriqués pour la démonstration.
enum InternetChecksumDemo {
    static func checksum(_ bytes: [UInt8], initial: UInt32 = 0) -> UInt16 {
        var sum = initial
        var index = 0
        while index + 1 < bytes.count { sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1]); index += 2 }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Message ICMPv6 avec sa somme (pseudo-en-tête IPv6).
    static func icmpv6(_ message: [UInt8], source: [UInt8], destination: [UInt8]) -> [UInt8] {
        var copy = message
        let pseudo = source + destination + [0, 0, UInt8(message.count >> 8), UInt8(message.count & 0xFF), 0, 0, 0, 58]
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < pseudo.count { sum += UInt32(pseudo[index]) << 8 | UInt32(pseudo[index + 1]); index += 2 }
        let value = checksum(copy, initial: sum)
        copy[2] = UInt8(value >> 8)
        copy[3] = UInt8(value & 0xFF)
        return copy
    }
}
