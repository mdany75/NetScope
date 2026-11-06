import Darwin
import Foundation
import NetScopeCore

// Note 69 : scan de ports UDP ciblé. Paquets construits comparés octet par octet, réponses
// recopiées (ou reconstruites champ par champ d'après les RFC) ; aller-retour sur 127.0.0.1 seulement.

private func bytes(_ hex: String) -> [UInt8] {
    let clean = hex.filter { !$0.isWhitespace }
    var result: [UInt8] = []
    var index = clean.startIndex
    while index < clean.endIndex {
        let next = clean.index(index, offsetBy: 2)
        result.append(UInt8(clean[index..<next], radix: 16) ?? 0)
        index = next
    }
    return result
}

/// Nom DNS sans compression (« _ipp._tcp.local. »).
private func dnsName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.split(separator: ".") {
        out.append(UInt8(label.utf8.count))
        out += Array(label.utf8)
    }
    return out + [0]
}

/// Réponse de ntpd 4.2.8 (strate 2, référence 132.246.11.229) : en-tête recopié d'une capture,
/// horodatages à zéro.
private let ntpServerReply: [UInt8] = bytes("24 02 03 e9 00 00 04 b1 00 00 05 3c 84 f6 0b e5") + [UInt8](repeating: 0, count: 32)

/// Réponse de « ntpq -c rv » (mode 6, READVAR).
private func ntpMode6Reply() -> [UInt8] {
    let text = Array("version=\"ntpd 4.2.8p15@1.3728-o Wed Sep 23 11:46:38 UTC 2020 (1)\", processor=\"x86_64\", system=\"Linux/5.10.0\"".utf8)
    return [0x16, 0x82, 0x00, 0x01, 0x06, 0x15, 0x00, 0x00, 0x00, 0x00, UInt8(text.count >> 8), UInt8(text.count & 0xFF)] + text
}

/// Réponse monlist (mode 7, MON_GETLIST_1) : 6 entrées de 72 octets annoncées.
private let ntpMonlistReply: [UInt8] = bytes("97 00 03 2a 00 06 00 48") + [UInt8](repeating: 0, count: 72)

/// Réponse IPMI à Get Channel Authentication Capabilities d'un iDRAC (capture de nmap ipmi-version).
private let ipmiReply = bytes("06 00 ff 07 00 00 00 00 00 00 00 00 00 10 81 1c 63 20 00 38 00 01 97 04 03 00 00 00 00 09")

/// Même réponse, connexion anonyme permise (octet d'état 0x05).
private let ipmiAnonymousReply = bytes("06 00 ff 07 00 00 00 00 00 00 00 00 00 10 81 1c 63 20 00 38 00 01 97 05 03 00 00 00 00 08")

/// GetResponse SNMP v2c de sysDescr.0 (MikroTik), communauté « public ».
private let snmpPublicReply: [UInt8] = bytes("30 34 02 01 01 04 06") + Array("public".utf8)
    + bytes("a2 27 02 01 01 02 01 00 02 01 00 30 1c 30 1a 06 08 2b 06 01 02 01 01 01 00 04 0e") + Array("RouterOS RB750".utf8)

/// Réponse BIND à version.bind (CH TXT).
private func dnsVersionReply(id: UInt16) -> [UInt8] {
    let version = Array("9.18.24-1-Debian".utf8)
    return [UInt8(id >> 8), UInt8(id & 0xFF), 0x84, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        + dnsName("version.bind") + [0x00, 0x10, 0x00, 0x03]
        + [0xC0, 0x0C, 0x00, 0x10, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, UInt8(version.count + 1), UInt8(version.count)] + version
}

/// Réponse mDNS en envoi direct d'une imprimante : trois types de services.
private func mdnsReply(id: UInt16) -> [UInt8] {
    var out: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x84, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]
    for service in ["_ipp._tcp.local", "_printer._tcp.local", "_http._tcp.local"] {
        let rdata = dnsName(service)
        out += dnsName("_services._dns-sd._udp.local") + [0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, UInt8(rdata.count)] + rdata
    }
    return out
}

/// Réponse NBSTAT d'un poste Windows (deux noms et l'adresse MAC).
private func netbiosReply(id: UInt16) -> [UInt8] {
    func entry(_ name: String, _ suffix: UInt8, group: Bool) -> [UInt8] {
        let padded = Array((name + String(repeating: " ", count: 15)).utf8.prefix(15))
        return padded + [suffix, group ? 0x84 : 0x04, 0x00]
    }
    let rdata: [UInt8] = [0x02] + entry("WKS346", 0x00, group: false) + entry("BUREAU", 0x00, group: true)
        + [0xB0, 0x7B, 0x25, 0x44, 0xA1, 0x6C] + [UInt8](repeating: 0, count: 40)
    return [UInt8(id >> 8), UInt8(id & 0xFF), 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        + [0x20] + Array("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8) + [0x00]
        + [0x00, 0x21, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
}

private let sipReply = Array("""
SIP/2.0 200 OK\r
Via: SIP/2.0/UDP 10.182.122.135:50512;branch=z9hG4bK-ns1;rport=50512\r
From: <sip:netscope@10.182.122.135>;tag=ns1\r
To: <sip:10.182.122.121>;tag=1859842412\r
Call-ID: 1@netscope\r
CSeq: 1 OPTIONS\r
User-Agent: Yealink SIP-T54W 96.86.0.70\r
Allow: INVITE, INFO, PRACK, ACK, BYE, CANCEL, OPTIONS, NOTIFY, REGISTER, SUBSCRIBE, REFER, PUBLISH, UPDATE, MESSAGE\r
Content-Length: 0\r
\r

""".utf8)

private let ssdpReply = Array("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: http://10.182.122.106:8008/ssdp/device-desc.xml\r\nSERVER: Linux/4.9 UPnP/1.0 BrightSign/8.5\r\nST: upnp:rootdevice\r\nUSN: uuid:2f402f80-da50-11e1-9b23-90ac3f0d1876::upnp:rootdevice\r\n\r\n".utf8)

// MARK: - Serveurs locaux (127.0.0.1)

private func udpLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw TestSkipped(reason: "socket UDP indisponible") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { close(fd); throw TestSkipped(reason: "impossible d'écouter sur 127.0.0.1") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

/// Reçoit une requête sur `fd` et répond `reply(requête)` depuis `replyFD` (le même, ou un autre
/// port comme un serveur TFTP), dans un fil à part.
private func serveOnce(_ fd: Int32, replyFrom replyFD: Int32? = nil, _ reply: @escaping @Sendable ([UInt8]) -> [UInt8]) {
    let out = replyFD ?? fd
    Thread.detachNewThread {
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard n > 0 else { return }
        let response = reply(Array(buffer[0..<n]))
        _ = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(out, response, response.count, 0, $0, length) }
        }
    }
}

private let loopback = IPv4Address(127, 0, 0, 1)

func registerUDPScanTests(_ suite: TestSuite) {
    suite.add("UDP ciblé : communauté du site jamais envoyée à un hôte public hors des plages") {
        let ranges = ["10.93.226.0/24", "203.0.113.10-203.0.113.20"]
        try expect(!UDPCommunityPolicy.maySendSiteCommunity(to: IPv4Address(8, 8, 8, 8), siteRanges: ranges),
                   "hôte public : aucune communauté envoyée")
        try expect(!UDPCommunityPolicy.maySendSiteCommunity(to: IPv4Address(8, 8, 8, 8), siteRanges: []), "site sans plage")
        try expect(UDPCommunityPolicy.maySendSiteCommunity(to: IPv4Address(192, 168, 1, 10), siteRanges: []), "adresse privée")
        try expect(UDPCommunityPolicy.maySendSiteCommunity(to: IPv4Address(203, 0, 113, 15), siteRanges: ranges),
                   "adresse publique des plages du site")
        try expect(!UDPCommunityPolicy.maySendSiteCommunity(to: IPv4Address(203, 0, 113, 21), siteRanges: ranges),
                   "juste après la plage du site")
    }

    suite.add("UDP ciblé : sondes DNS, SNMP, IPMI, NTP, TFTP construites octet par octet") {
        try expectEqual(UDPProbePayload.dnsVersionBind(id: 0x1234),
                        bytes("12 34 00 00 00 01 00 00 00 00 00 00 07 76 65 72 73 69 6f 6e 04 62 69 6e 64 00 00 10 00 03"),
                        "version.bind CH TXT sans récursion")
        try expectEqual(UDPProbePayload.snmpGetSysDescr(community: "public", requestID: 1),
                        bytes("30 26 02 01 01 04 06 70 75 62 6c 69 63 a0 19 02 01 01 02 01 00 02 01 00 30 0e 30 0c 06 08 2b 06 01 02 01 01 01 00 05 00"),
                        "GetRequest v2c sysDescr.0")
        try expectEqual(UDPProbePayload.ipmiChannelAuthCapabilities,
                        bytes("06 00 ff 07 00 00 00 00 00 00 00 00 00 09 20 18 c8 81 00 38 8e 04 b5"), "RMCP Get Channel Auth Capabilities")
        try expectEqual(UDPProbePayload.ipmiChecksum([0x20, 0x18]), 0xC8, "somme de l'en-tête IPMI")
        try expectEqual(UDPProbePayload.ipmiChecksum([0x81, 0x00, 0x38, 0x8E, 0x04]), 0xB5, "somme des données IPMI")
        let ntp = UDPProbePayload.ntpClientRequest(transmit: 0x0102_0304_0506_0708)
        try expectEqual(ntp.count, 48, "requête NTP de 48 octets")
        try expectEqual(ntp[0], 0x23, "LI 0, version 4, mode 3")
        try expectEqual(Array(ntp[40..<48]), [1, 2, 3, 4, 5, 6, 7, 8], "heure d'envoi dans transmit")
        try expectEqual(UDPProbePayload.ntpReadVariables(sequence: 1), bytes("16 02 00 01 00 00 00 00 00 00 00 00"), "mode 6 READVAR")
        try expectEqual(UDPProbePayload.ntpMonlistRequest, bytes("17 00 03 2a 00 00 00 00"), "mode 7 monlist (charge de nmap)")
        try expectEqual(UDPProbePayload.ntpTimestamp(Date(timeIntervalSince1970: 0)) >> 32, 2_208_988_800, "époque NTP 1900")
        try expectEqual(UDPProbePayload.tftpReadRequest(file: "a.txt"), [0, 1] + Array("a.txt".utf8) + [0] + Array("octet".utf8) + [0],
                        "RRQ en mode octet")
        let discovery = UDPProbePayload.snmpV3Discovery(messageID: 77)
        let decoded = try SNMPv3Codec.decode(discovery)
        try expectEqual(decoded.usm.user, "", "découverte v3 sans utilisateur")
        try expect(decoded.usm.engineID.isEmpty && decoded.flags & 0x04 != 0 && decoded.flags & 0x03 == 0, "noAuthNoPriv, rapport demandé")
    }

    suite.add("UDP ciblé : paquets par service et communauté SNMP seulement si choisie") {
        let target = IPv4Address(10, 182, 122, 121)
        var context = UDPProbePayload.Context(target: target, localAddress: IPv4Address(10, 182, 122, 135), localPort: 50512,
                                              transactionID: 0x2222, snmpCommunity: nil, ntpControlChecks: false, nonce: "ab12")
        try expectEqual(UDPProbePayload.packets(for: .snmp, context: context).count, 1, "sans communauté : découverte v3 seule")
        try expect(!UDPProbePayload.packets(for: .snmp, context: context).joined().contains(Array("public".utf8)) ,
                   "« public » jamais envoyé sans choix")
        try expectEqual(UDPProbePayload.packets(for: .ntp, context: context).count, 1, "NTP mode 3 seul")
        context.snmpCommunity = "lecture-site"
        context.ntpControlChecks = true
        let snmp = UDPProbePayload.packets(for: .snmp, context: context)
        try expectEqual(snmp.count, 2, "v3 puis v2c avec la communauté du site")
        try expectEqual(try SNMPMessage(decoding: snmp[1]).community, "lecture-site", "communauté choisie")
        try expectEqual(UDPProbePayload.packets(for: .ntp, context: context).count, 3, "modes 3, 6 et 7")
        let sip = String(decoding: UDPProbePayload.packets(for: .sip, context: context)[0], as: UTF8.self)
        try expect(sip.hasPrefix("OPTIONS sip:10.182.122.121 SIP/2.0\r\n"), "ligne de requête SIP")
        try expect(sip.contains("Via: SIP/2.0/UDP 10.182.122.135:50512;branch=z9hG4bK-nsab12;rport\r\n"), "Via avec branche RFC 3261")
        try expect(sip.contains("CSeq: 1 OPTIONS\r\n") && sip.hasSuffix("Content-Length: 0\r\n\r\n"), "fin de l'en-tête SIP")
        let ssdp = String(decoding: UDPProbePayload.packets(for: .ssdp, context: context)[0], as: UTF8.self)
        try expect(ssdp.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 10.182.122.121:1900\r\n") && ssdp.contains("MAN: \"ssdp:discover\""), "M-SEARCH direct")
        let mdns = UDPProbePayload.packets(for: .mdns, context: context)[0]
        try expectEqual(Array(mdns[0..<4]), [0x22, 0x22, 0x00, 0x00], "mDNS : identifiant repris, sans récursion")
        try expect(UDPProbePayload.packets(for: .dns, context: context).count == 2, "DNS : version.bind et A localhost")
        try expectEqual(UDPProbePayload.packets(for: .netbios, context: context)[0], NamesNetBIOS.nodeStatusQuery(id: 0x2222), "NBSTAT")
        try expect(String(decoding: UDPProbePayload.packets(for: .tftp, context: context)[0], as: UTF8.self).contains("netscope-sonde-ab12.txt"),
                   "TFTP : fichier de test inexistant")
        try expectEqual(UDPService.allCases.map(\.port), [53, 69, 123, 137, 161, 623, 1900, 5060, 5353], "services dans l'ordre des ports")
        try expectEqual(UDPService.forPort(623), .ipmi, "service d'un port")
    }

    suite.add("UDP ciblé : lecture des réponses NTP (mode 3, 6, 7 et non synchronisé)") {
        let basic = try UDPProbeReader.read(.ntp, datagrams: [ntpServerReply]).unwrapUDP("réponse NTP")
        try expectEqual(basic.summary, "NTPv4 · strate 2 · réf. 132.246.11.229", "strate et référence")
        try expect(basic.findings.isEmpty, "mode 3 seul : aucun constat")
        let all = try UDPProbeReader.read(.ntp, datagrams: [ntpServerReply, ntpMode6Reply(), ntpMonlistReply]).unwrapUDP("trois réponses")
        try expectEqual(all.findings.map(\.kind), [.ntpMode6, .ntpMode7], "modes 6 et 7 relevés")
        try expect(all.details.contains { $0.contains("ntpd 4.2.8p15@1.3728-o") }, "version lue en mode 6 : \(all.details)")
        try expect(all.details.contains { $0.contains("6 clients récents") }, "monlist : nombre d'entrées")
        var unsynced = ntpServerReply
        unsynced[0] = 0xE4
        unsynced[1] = 16
        try expectEqual(UDPProbeReader.read(.ntp, datagrams: [unsynced])?.summary, "NTPv4 · non synchronisé", "LI 3, strate 16")
        try expectEqual(UDPProbeReader.ntpVariable("system", in: "version=\"a\", system=\"Linux\""), "Linux", "variable mode 6")
    }

    suite.add("UDP ciblé : SNMP public, SNMP v3 et fabricant du moteur") {
        let v2 = try UDPProbeReader.read(.snmp, datagrams: [snmpPublicReply], community: "public").unwrapUDP("v2c")
        try expectEqual(v2.summary, "SNMP v2c · RouterOS RB750", "sysDescr lu")
        try expectEqual(v2.findings.map(\.kind), [.snmpPublic], "communauté public : constat élevé")
        let engine: [UInt8] = [0x80, 0x00, 0x30, 0x44, 0x04] + Array("FGT60F".utf8)
        let usmStatsUnknownEngineIDs: SNMPOID = "1.3.6.1.6.3.15.1.1.4.0"
        let report = try SNMPv3Codec.encode(msgID: 9, pdu: SNMPPDU(type: .report, requestID: 9,
                                                                   varbinds: [SNMPVarBind(oid: usmStatsUnknownEngineIDs, value: .counter32(3))]),
                                            usm: SNMPUSMParameters(engineID: engine, boots: 7, time: 90_000), level: .noAuthNoPriv,
                                            reportable: false, contextEngineID: engine, contextName: "")
        let v3 = try UDPProbeReader.read(.snmp, datagrams: [report]).unwrapUDP("rapport v3")
        try expectEqual(v3.summary, "SNMP v3 · moteur Fortinet", "fabricant d'après l'engineID")
        try expect(v3.findings.isEmpty, "v3 seul : aucun constat")
        try expect(v3.details.contains { $0.contains("1\u{00A0}j 1\u{00A0}h") }, "durée du moteur : \(v3.details)")
        try expectEqual(UDPProbeReader.snmpEngineVendor([0x80, 0x00, 0x00, 0x09, 0x03, 0, 0]), "Cisco", "Cisco")
        try expectEqual(UDPProbeReader.snmpEngineVendor([0x00, 0x00, 0x00, 0x09, 0x03]), nil, "format ancien")
        let both = try UDPProbeReader.read(.snmp, datagrams: [report, snmpPublicReply], community: "public").unwrapUDP("deux")
        try expect(both.summary.hasPrefix("SNMP v2c") && both.details.first == "SNMP v3 · moteur Fortinet", "v2c et v3")
    }

    suite.add("UDP ciblé : IPMI, SIP, TFTP, DNS, mDNS, NetBIOS et SSDP lus") {
        let caps = try UDPProbeReader.ipmiCapabilities(ipmiReply).unwrapUDP("capacités IPMI")
        try expect(caps.supportsV2 && caps.supportsV15, "IPMI 2.0 et 1.5")
        try expectEqual(caps.authTypes, ["aucune", "MD2", "MD5", "mot de passe"], "types d'authentification")
        try expect(!caps.anonymousLogin && !caps.nullUsernames, "pas d'anonyme")
        let ipmi = try UDPProbeReader.read(.ipmi, datagrams: [ipmiReply]).unwrapUDP("IPMI")
        try expectEqual(ipmi.summary, "BMC · IPMI 2.0 et 1.5", "résumé IPMI")
        try expectEqual(ipmi.findings.map(\.kind), [.ipmiExposed], "IPMI exposé")
        try expectEqual(UDPProbeReader.read(.ipmi, datagrams: [ipmiAnonymousReply])?.findings.map(\.kind), [.ipmiExposed, .ipmiAnonymous],
                        "connexion anonyme")
        try expect(UDPProbeReader.ipmiCapabilities(Array(ipmiReply.prefix(20))) == nil, "réponse tronquée refusée")

        let sip = try UDPProbeReader.read(.sip, datagrams: [sipReply]).unwrapUDP("SIP")
        try expectEqual(sip.summary, "SIP 200 OK · Yealink SIP-T54W 96.86.0.70", "agent SIP")
        try expectEqual(sip.findings.map(\.kind), [.sipExposed], "SIP exposé")

        let tftp = try UDPProbeReader.read(.tftp, datagrams: [[0, 5, 0, 1] + Array("File not found".utf8) + [0]]).unwrapUDP("TFTP")
        try expectEqual(tftp.summary, "Serveur TFTP · erreur 1 «\u{00A0}File not found\u{00A0}»", "erreur attendue")
        try expectEqual(tftp.findings.map(\.kind), [.tftpOpen], "TFTP joignable")

        let dns = try UDPProbeReader.read(.dns, datagrams: [dnsVersionReply(id: 7)]).unwrapUDP("DNS")
        try expectEqual(dns.summary, "Serveur DNS · 9.18.24-1-Debian", "version de BIND")

        let mdns = try UDPProbeReader.read(.mdns, datagrams: [mdnsReply(id: 3)]).unwrapUDP("mDNS")
        try expectEqual(mdns.summary, "mDNS · 3 services\u{00A0}: ipp, printer, http", "services annoncés")

        let netbios = try UDPProbeReader.read(.netbios, datagrams: [netbiosReply(id: 5)]).unwrapUDP("NetBIOS")
        try expectEqual(netbios.summary, "NetBIOS · WKS346 · groupe BUREAU", "nom et groupe")
        try expect(netbios.details.contains("Adresse MAC annoncée\u{00A0}: B0:7B:25:44:A1:6C"), "MAC annoncée : \(netbios.details)")

        let ssdp = try UDPProbeReader.read(.ssdp, datagrams: [ssdpReply]).unwrapUDP("SSDP")
        try expectEqual(ssdp.summary, "UPnP · Linux/4.9 UPnP/1.0 BrightSign/8.5", "SERVER")
        try expect(ssdp.details.contains("Description\u{00A0}: http://10.182.122.106:8008/ssdp/device-desc.xml"), "LOCATION")

        let unknown = try UDPProbeReader.read(.sip, datagrams: [[0xDE, 0xAD, 0xBE, 0xEF]]).unwrapUDP("inconnu")
        try expect(!unknown.recognized && unknown.summary.contains("4\u{00A0}octets"), "réponse non reconnue : port ouvert quand même")
        try expect(UDPProbeReader.read(.dns, datagrams: []) == nil, "aucune réponse")
    }

    suite.add("UDP ciblé : états, bilan, constats triés et CSV") {
        try expectEqual(UDPPortState.classify(replies: 1, refused: true, unreachable: false), .open, "réponse d'abord")
        try expectEqual(UDPPortState.classify(replies: 0, refused: true, unreachable: false), .closed, "ICMP port injoignable")
        try expectEqual(UDPPortState.classify(replies: 0, refused: false, unreachable: true), .filtered, "ICMP interdit")
        try expectEqual(UDPPortState.classify(replies: 0, refused: false, unreachable: false), .openFiltered, "silence")
        let summary = UDPScanSummary(host: "10.182.122.111", results: [
            UDPProbeResult(service: .snmp, state: .open, rttMs: 3.2, summary: "SNMP v2c · Brother; NC-8300h", findings: [.snmpPublic]),
            UDPProbeResult(service: .dns, state: .closed),
            UDPProbeResult(service: .sip, state: .open, findings: [.sipExposed]),
            UDPProbeResult(service: .ipmi, state: .openFiltered),
            UDPProbeResult(service: .ntp, state: .open, findings: [.ntpMode6, .ntpMode7]),
            UDPProbeResult(service: .tftp, state: .closed),
        ], duration: 2)
        try expectEqual(summary.results.map(\.port), [53, 69, 123, 161, 623, 5060], "triés par port")
        try expectEqual(summary.summary, "3 ouverts, 1 ouvert|filtré, 2 fermés", "résumé")
        try expectEqual(summary.findings.map(\.kind), [.ntpMode7, .snmpPublic, .ntpMode6, .sipExposed], "les plus graves d'abord")
        let csv = summary.csv.components(separatedBy: "\n")
        try expectEqual(csv[0], "port;proto;etat;service;reponse;delai_ms;constats", "en-tête CSV")
        try expectEqual(csv[4], "161;udp;ouvert;snmp;SNMP v2c · Brother, NC-8300h;3.2;SNMP «\u{00A0}public\u{00A0}» ouvert", "ligne SNMP sans « ; »")
    }

    suite.add("UDP ciblé : aller-retour sur 127.0.0.1 (ouvert, fermé, réponse d'un autre port, silence)") {
        // NTP : le serveur local répond la réponse recopiée.
        let ntp = try udpLoopbackSocket()
        defer { close(ntp.fd) }
        serveOnce(ntp.fd) { request in
            request.count == 48 && request[0] == 0x23 ? ntpServerReply : []
        }
        let options = UDPProbeOptions(timeout: 1, attempts: 1, ntpControlChecks: false)
        let open = await UDPPortScanner.probe(host: loopback, service: .ntp, port: ntp.port, options: options)
        try expectEqual(open.state, .open, "NTP local ouvert")
        try expectEqual(open.summary, "NTPv4 · strate 2 · réf. 132.246.11.229", "réponse lue")
        try expect((open.rttMs ?? -1) >= 0, "délai mesuré")

        // Port fermé : ICMP port injoignable sur l'interface de bouclage.
        let freed = try udpLoopbackSocket()
        close(freed.fd)
        let closed = await UDPPortScanner.probe(host: loopback, service: .dns, port: freed.port,
                                                options: UDPProbeOptions(timeout: 1, attempts: 2))
        try expectEqual(closed.state, .closed, "port local fermé (ECONNREFUSED)")

        // TFTP : erreur renvoyée d'un autre port (identifiant de transfert du serveur).
        let tftp = try udpLoopbackSocket()
        let transfer = try udpLoopbackSocket()
        defer { close(tftp.fd); close(transfer.fd) }
        serveOnce(tftp.fd, replyFrom: transfer.fd) { request in
            request.starts(with: [0, 1]) ? [0, 5, 0, 1] + Array("File not found".utf8) + [0] : []
        }
        let tftpResult = await UDPPortScanner.probe(host: loopback, service: .tftp, port: tftp.port,
                                                    options: UDPProbeOptions(timeout: 1, attempts: 1))
        try expectEqual(tftpResult.state, .open, "réponse reçue d'un autre port")
        try expectEqual(tftpResult.findings.map(\.kind), [.tftpOpen], "TFTP lu")

        // Silence : ouvert|filtré.
        let mute = try udpLoopbackSocket()
        defer { close(mute.fd) }
        let silent = await UDPPortScanner.probe(host: loopback, service: .sip, port: mute.port,
                                                options: UDPProbeOptions(timeout: 0.3, attempts: 1))
        try expectEqual(silent.state, .openFiltered, "aucune réponse")

        // Scan de plusieurs services avec ports remplacés.
        let summary = await UDPPortScanner.scan(host: loopback, services: [.sip, .dns], options: UDPProbeOptions(timeout: 0.3, attempts: 1),
                                                ports: [.sip: mute.port, .dns: freed.port])
        try expectEqual(summary.results.first { $0.service == .dns }?.state, .closed, "bilan : DNS fermé")
        try expectEqual(summary.results.first { $0.service == .sip }?.state, .openFiltered, "bilan : SIP muet")
    }
}

private extension Optional {
    func unwrapUDP(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : absent", file: file, line: line) }
        return value
    }
}
