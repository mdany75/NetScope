import Foundation
import NetScopeCore

// Tests de la note 78 (Capture de paquets) : décodeurs SIP, RTP, RTCP, SNMP, Syslog, RADIUS et NTP
// sur des charges utiles fixes (octets recopiés en hexadécimal ou texte SIP tel quel), placées
// dans des trames Ethernet/IPv4/UDP fabriquées ; constats automatiques (retransmissions, fenêtre
// nulle, latence par flux, requêtes sans réponse, échecs, perte et gigue RTP, horloge NTP).
// Aucune capture réelle : rien n'est lu ni envoyé sur le réseau.

/// Octets d'un texte hexadécimal (espaces et retours ignorés).
private func bytes(_ text: String) -> [UInt8] {
    let digits = text.filter(\.isHexDigit)
    var result: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        result.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return result
}

/// Charges utiles de référence (applications), recopiées octet par octet.
enum ServicePayloads {
    /// SNMPv2c get-request, communauté « public », request-id 4660, sysName.0.
    static let snmpGet = bytes("""
    302702010104067075626c6963a01a02021234020100020100300e300c06082b
    060102010105000500
    """)
    /// Réponse : sysName.0 = « SW-ETG2-01 ».
    static let snmpResponse = bytes("""
    303102010104067075626c6963a224020212340201000201003018301606082b
    06010201010500040a53572d455447322d3031
    """)
    /// Réponse en erreur (noSuchName, request-id 4661).
    static let snmpError = bytes("""
    302702010104067075626c6963a21a02021235020102020100300e300c06082b
    060102010105000500
    """)
    /// RADIUS Access-Request id 42 : User-Name « jtremblay », mot de passe chiffré, NAS 10.182.122.1,
    /// NAS-Port-Type Wireless-802.11, Called/Calling-Station-Id, Message-Authenticator.
    static let radiusRequest = bytes("""
    012a007c101112131415161718191a1b1c1d1e1f010b6a7472656d626c617902
    12a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a504060ab67a013d06000000131e1a30
    342d44352d39302d33412d37432d32303a4275726561751f1342412d37452d32
    312d43342d39302d313350125c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
    """)
    /// Access-Reject id 42 avec Reply-Message « Mot de passe incorrect ».
    static let radiusReject = bytes("""
    032a003e9999999999999999999999999999999912184d6f7420646520706173
    736520696e636f727265637450123c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c
    """)
    /// NTP v4 client, horodatage d'émission 3 971 000 000,25.
    static let ntpClient = bytes("""
    230006ec00000000000000000000000000000000000000000000000000000000
    0000000000000000ecb0a6c040000000
    """)
    /// Réponse du serveur 10.10.0.5 (strate 2) : réception 2,25 s après l'origine.
    static let ntpServer = bytes("""
    240206e900000a5c00001b2e0a0a0005ecb0a68e00000000ecb0a6c040000000
    ecb0a6c280000000ecb0a6c280100000
    """)
    /// RTP PCMU, séquence 12045, horodatage 160320, SSRC 0x1a2b3c4d, 160 octets de voix.
    static let rtp = bytes("""
    80002f0d000272401a2b3c4d
    """) + [UInt8](repeating: 0xFF, count: 160)
    /// RTCP RR (perte 12/256, 3 perdus, gigue 96) suivi d'un SDES (CNAME).
    static let rtcp = bytes("""
    81c90007556677881a2b3c4d0c00000300002f44000000600000000000000000
    81ca000755667788011370686f6e654031302e3138322e3132322e3230000000
    """)
    static let sipInvite = Array("""
    INVITE sip:204@10.182.122.20 SIP/2.0\r
    Via: SIP/2.0/UDP 10.182.122.31:5060;branch=z9hG4bK776asdhds\r
    Max-Forwards: 70\r
    f: "Accueil" <sip:201@10.182.122.20>;tag=1928301774\r
    t: <sip:204@10.182.122.20>\r
    i: a84b4c76e66710@10.182.122.31\r
    CSeq: 314159 INVITE\r
    Contact: <sip:201@10.182.122.31>\r
    c: application/sdp\r
    l: 142\r
    \r
    v=0\r
    o=201 2890844526 2890844526 IN IP4 10.182.122.31\r
    s=Appel\r
    c=IN IP4 10.182.122.31\r
    t=0 0\r
    m=audio 16384 RTP/AVP 0 8 101\r
    a=rtpmap:0 PCMU/8000\r
    a=rtpmap:101 telephone-event/8000\r
    a=sendrecv\r

    """.utf8)
    static let sipBusy = Array("""
    SIP/2.0 486 Busy Here\r
    Via: SIP/2.0/UDP 10.182.122.31:5060;branch=z9hG4bK776asdhds\r
    From: "Accueil" <sip:201@10.182.122.20>;tag=1928301774\r
    To: <sip:204@10.182.122.20>;tag=a6c85cf\r
    Call-ID: a84b4c76e66710@10.182.122.31\r
    CSeq: 314159 INVITE\r
    Content-Length: 0\r
    \r

    """.utf8)
}

private let phone = (MACAddress("00:04:f2:11:22:33")!, IPv4Address("10.182.122.31")!)
private let pbx = (MACAddress("00:04:f2:aa:bb:cc")!, IPv4Address("10.182.122.20")!)
private let mac = (MACAddress("3c:a6:f6:1b:22:9e")!, IPv4Address("10.182.122.142")!)
private let fgt = (MACAddress("04:d5:90:3a:7c:11")!, IPv4Address("10.182.122.1")!)

private func udp(_ from: (MACAddress, IPv4Address), _ sourcePort: UInt16, _ to: (MACAddress, IPv4Address), _ destinationPort: UInt16, _ payload: [UInt8]) -> [UInt8] {
    PacketForge.udpFrame((from.0, from.1, sourcePort), (to.0, to.1, destinationPort), payload: payload)
}

func registerPacketFindingsTests(_ suite: TestSuite) {
    // MARK: Décodeurs

    suite.add("Paquets : SIP (INVITE à en-têtes courts et SDP, réponse 486)") {
        let invite = PacketDecoder.decode(udp(phone, 5060, pbx, 5060, ServicePayloads.sipInvite))
        try expectEqual(invite.protocols, [.ethernet, .ipv4, .udp, .sip], "protocoles")
        try expect(invite.summary.hasPrefix("Requête\u{00A0}: INVITE sip:204@10.182.122.20"), "résumé : \(invite.summary)")
        try expectEqual(invite.sipMethod, "INVITE", "méthode")
        try expectEqual(invite.sipCallID, "a84b4c76e66710@10.182.122.31", "Call-ID par sa forme courte « i: »")
        try expectEqual(invite.firstField(named: "From")?.value.hasPrefix("\"Accueil\""), true, "« f: » devient From")
        let sdp = try invite.firstField(named: "Description de session (SDP)").required("SDP")
        try expectEqual(sdp.value, "audio 16384 RTP/AVP 0 8 101", "média")
        try expect(sdp.children.contains { $0.name == "Codec (rtpmap)" && $0.value == "rtpmap:101 telephone-event/8000" }, "rtpmap")
        try expectEqual(invite.transaction?.isRequest, true, "requête")
        let busy = PacketDecoder.decode(udp(pbx, 5060, phone, 5060, ServicePayloads.sipBusy))
        try expectEqual(busy.sipStatus, 486, "code")
        try expect(busy.summary.hasPrefix("Réponse\u{00A0}: 486 Busy Here (INVITE)"), "résumé : \(busy.summary)")
        try expectEqual(busy.transaction?.key, invite.transaction?.key, "même transaction")
        try expectEqual(busy.transaction?.failure, "486 Busy Here", "échec")
        try expectEqual(busy.firstField(named: "Code")?.value, "486 (erreur du client)", "famille du code")
    }

    suite.add("Paquets : RTP (PCMU, SSRC) et RTCP (RR, perte, gigue, SDES)") {
        let rtp = PacketDecoder.decode(udp(phone, 16384, pbx, 20000, ServicePayloads.rtp))
        try expectEqual(rtp.topProtocol, .rtp, "RTP reconnu par son contenu")
        try expectEqual(rtp.rtp?.sequence, 12045, "séquence")
        try expectEqual(rtp.rtp?.ssrc, 0x1A2B_3C4D, "SSRC")
        try expectEqual(rtp.summary, "PT=PCMU, SSRC=0x1a2b3c4d, Séq=12045, Horo=160320", "résumé")
        try expectEqual(rtp.firstField(named: "Type de charge")?.value, "PCMU (G.711 µ-loi) (0)", "codec")
        try expectEqual(rtp.firstField(named: "Charge utile (PCMU)")?.length, 160, "charge utile")
        let rtcp = PacketDecoder.decode(udp(pbx, 20001, phone, 16385, ServicePayloads.rtcp))
        try expectEqual(rtcp.topProtocol, .rtcp, "RTCP")
        try expectEqual(rtcp.rtcpReports.first?.cumulativeLost, 3, "perdus")
        try expectEqual(rtcp.rtcpReports.first?.jitter, 96, "gigue")
        try expectEqual(rtcp.summary, "RR + SDES · perte 4,7\u{00A0}%, gigue 96", "résumé")
        try expectEqual(rtcp.firstField(named: "CNAME")?.value, "phone@10.182.122.20", "CNAME")
        // Données UDP quelconques sur des ports hauts : pas prises pour du RTP.
        let noise = PacketDecoder.decode(udp(phone, 40000, pbx, 40001, [0x17, 0xfe, 0xfd, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        try expectEqual(noise.topProtocol, .udp, "DTLS ou autre : pas RTP")
    }

    suite.add("Paquets : SNMP v2c (communauté masquée, sysName nommé, erreur, transaction)") {
        let get = PacketDecoder.decode(udp(mac, 50111, fgt, 161, ServicePayloads.snmpGet))
        try expectEqual(get.topProtocol, .snmp, "SNMP")
        try expectEqual(get.layers.last?.node.children.first?.value, "v2c (1)", "version")
        let community = try get.firstField(named: "Communauté").required("communauté")
        try expect(!community.value.contains("public"), "communauté jamais affichée en clair")
        try expect(community.value.contains("6\u{00A0}caractères"), "longueur donnée : \(community.value)")
        try expectEqual(community.offset, 42 + 7, "position dans la trame")
        try expectEqual(get.summary, "get-request id=4660 sysName.0", "résumé")
        let response = PacketDecoder.decode(udp(fgt, 161, mac, 50111, ServicePayloads.snmpResponse))
        try expectEqual(response.summary, "get-response id=4660 sysName.0 = SW-ETG2-01", "réponse")
        try expectEqual(response.transaction?.key, get.transaction?.key, "même request-id")
        let error = PacketDecoder.decode(udp(fgt, 161, mac, 50111, ServicePayloads.snmpError))
        try expectEqual(error.transaction?.failure, "objet inconnu", "noSuchName")
        try expect(error.summary.contains("objet inconnu"), "résumé de l’erreur")
    }

    suite.add("Paquets : Syslog (Cisco en UDP, FortiOS en TCP cadré par longueur)") {
        let cisco = PacketDecoder.decode(udp(fgt, 50514, mac, 5514, Array("<187>Nov  4 10:21:40 SW-ETG2-01 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down".utf8)))
        try expectEqual(cisco.topProtocol, .syslog, "Syslog")
        try expectEqual(cisco.syslogSeverity, 3, "gravité err")
        try expectEqual(cisco.firstField(named: "Priorité")?.value, "<187> (local7.err)", "priorité")
        try expectEqual(cisco.firstField(named: "Hôte")?.value, "SW-ETG2-01", "hôte")
        try expect(cisco.summary.hasPrefix("local7.err SW-ETG2-01\u{00A0}: "), "résumé : \(cisco.summary)")
        let line = "<189>date=2026-11-04 time=14:02:07 devname=\"FGT-SIEGE\" logid=\"0100032001\" level=\"notice\" msg=\"Admin login\""
        let framed = Array("\(line.utf8.count) \(line)".utf8)
        let tcp = PacketDecoder.decode(PacketForge.tcpFrame((fgt.0, fgt.1, 41_000), (mac.0, mac.1, 5514), sequence: 1, acknowledgment: 1, flags: 0x018, payload: framed))
        try expectEqual(tcp.topProtocol, .syslog, "Syslog en TCP")
        try expectEqual(tcp.firstField(named: "Longueur (RFC\u{00A0}6587)")?.value, "\(line.utf8.count)", "longueur")
        try expect(tcp.firstField(named: "Champs")?.children.contains { $0.name == "logid" && $0.value == "0100032001" } == true, "champs FortiOS")
        let filter = try DisplayFilter.compile("syslog.level <= 3").get()
        let log = PacketCaptureLog(records: [PacketRecord(timestamp: 1, data: udp(fgt, 50514, mac, 5514, Array("<187>x y: z".utf8)))])
        try expect(filter?.matches(log.packets[0]) == true, "filtre syslog.level")
    }

    suite.add("Paquets : RADIUS (Access-Request masqué, Access-Reject, attributs)") {
        let request = PacketDecoder.decode(udp(fgt, 1645, IPv4Pair.nps, 1812, ServicePayloads.radiusRequest))
        try expectEqual(request.topProtocol, .radius, "RADIUS")
        try expectEqual(request.summary, "Access-Request id=42 · utilisateur «\u{00A0}jtremblay\u{00A0}»", "résumé")
        try expect(request.firstField(named: "User-Password")?.value.hasPrefix("masqué") == true, "mot de passe masqué")
        try expectEqual(request.firstField(named: "NAS-IP-Address")?.value, "10.182.122.1", "NAS")
        try expectEqual(request.firstField(named: "NAS-Port-Type")?.value, "Wireless-802.11 (19)", "type de port")
        try expect(request.firstField(named: "Message-Authenticator")?.value.hasPrefix("masqué") == true, "authentifiant masqué")
        let reject = PacketDecoder.decode(udp(IPv4Pair.nps, 1812, fgt, 1645, ServicePayloads.radiusReject))
        try expectEqual(reject.radiusCode, 3, "Access-Reject")
        try expectEqual(reject.transaction?.failure, "accès refusé (Mot de passe incorrect)", "échec lisible")
        try expect(reject.summary.contains("Mot de passe incorrect"), "message de refus au résumé")
    }

    suite.add("Paquets : NTP (client, serveur strate 2, référence, horodatages)") {
        let client = PacketDecoder.decode(udp(mac, 123, IPv4Pair.ntp, 123, ServicePayloads.ntpClient))
        try expectEqual(client.topProtocol, .ntp, "NTP")
        try expectEqual(client.summary, "NTP v4, client", "résumé client")
        let server = PacketDecoder.decode(udp(IPv4Pair.ntp, 123, mac, 123, ServicePayloads.ntpServer))
        try expectEqual(server.summary, "NTP v4, serveur, strate 2, référence 10.10.0.5", "résumé serveur")
        try expectEqual(server.transaction?.key, client.transaction?.key, "origine = émission du client")
        try expectEqual(server.firstField(named: "Horodatage d’origine")?.value, "2025-11-01 15:33:20,250000 UTC", "horodatage lisible")
        try expectEqual(server.firstField(named: "Strate")?.value, "2 (référence secondaire)", "strate")
    }

    // MARK: Constats

    suite.add("Capture : constats (retransmission, fenêtre nulle, DNS sans réponse, RADIUS refusé, SIP, horloge)") {
        var list: [(Double, [UInt8])] = []
        // TCP vers l'imprimante : poignée de main, données, retransmission, fenêtre nulle.
        let client = (mac.0, mac.1, UInt16(52_150)), printer = (IPv4Pair.printerMAC, IPv4Pair.printer, UInt16(9100))
        let back = (IPv4Pair.printerMAC, IPv4Pair.printer, UInt16(9100)), toMac = (mac.0, mac.1, UInt16(52_150))
        let job = [UInt8](repeating: 0x1B, count: 1_000)
        list.append((0.000, PacketForge.tcpFrame(client, printer, sequence: 1_000, acknowledgment: 0, flags: 0x002)))
        list.append((0.004, PacketForge.tcpFrame(back, toMac, sequence: 5_000, acknowledgment: 1_001, flags: 0x012)))
        list.append((0.005, PacketForge.tcpFrame(client, printer, sequence: 1_001, acknowledgment: 5_001, flags: 0x010)))
        list.append((0.006, PacketForge.tcpFrame(client, printer, sequence: 1_001, acknowledgment: 5_001, flags: 0x018, payload: job)))
        list.append((0.306, PacketForge.tcpFrame(client, printer, sequence: 1_001, acknowledgment: 5_001, flags: 0x018, payload: job)))
        list.append((0.310, PacketForge.tcpFrame(back, toMac, sequence: 5_001, acknowledgment: 2_001, flags: 0x010, window: 0)))
        // DNS sans réponse, puis répété (une seule requête comptée).
        let name = PacketForge.dnsName("intranet.bureau.local")
        list.append((0.500, udp(mac, 61_001, fgt, 53, PacketForge.dnsMessage(id: 0x1111, flags: 0x0100, questions: [(name, 1, 1)]))))
        list.append((1.500, udp(mac, 61_001, fgt, 53, PacketForge.dnsMessage(id: 0x1111, flags: 0x0100, questions: [(name, 1, 1)]))))
        // DNS lent (300 ms) mais répondu.
        let slow = PacketForge.dnsName("outlook.office365.com")
        list.append((0.600, udp(mac, 61_002, fgt, 53, PacketForge.dnsMessage(id: 0x2222, flags: 0x0100, questions: [(slow, 1, 1)]))))
        list.append((0.900, udp(fgt, 53, mac, 61_002, PacketForge.dnsMessage(id: 0x2222, flags: 0x8180, questions: [(slow, 1, 1)]))))
        // RADIUS refusé, SNMP répondu, SIP occupé, NTP avec horloge décalée.
        list.append((1.000, udp(fgt, 1645, IPv4Pair.nps, 1812, ServicePayloads.radiusRequest)))
        list.append((1.020, udp(IPv4Pair.nps, 1812, fgt, 1645, ServicePayloads.radiusReject)))
        list.append((1.100, udp(mac, 50111, fgt, 161, ServicePayloads.snmpGet)))
        list.append((1.112, udp(fgt, 161, mac, 50111, ServicePayloads.snmpResponse)))
        list.append((1.200, udp(phone, 5060, pbx, 5060, ServicePayloads.sipInvite)))
        list.append((1.260, udp(pbx, 5060, phone, 5060, ServicePayloads.sipBusy)))
        list.append((1.300, udp(mac, 123, IPv4Pair.ntp, 123, ServicePayloads.ntpClient)))
        list.append((1.330, udp(IPv4Pair.ntp, 123, mac, 123, ServicePayloads.ntpServer)))
        // La capture continue : les requêtes ont eu le temps de recevoir leur réponse.
        list.append((4.000, udp(mac, 5353, IPv4Pair.mdns, 5353, PacketForge.dnsMessage(id: 0, flags: 0, questions: [(PacketForge.dnsName("_ipp._tcp.local"), 12, 1)]))))
        let log = PacketCaptureLog(records: list.map { PacketRecord(timestamp: 1_793_805_693 + $0.0, data: $0.1) })
        let report = CaptureFindingsAnalyzer.analyze(log)
        let categories = report.findings.map(\.category)
        try expect(categories.contains(.retransmission), "retransmission")
        try expect(categories.contains(.zeroWindow), "fenêtre nulle")
        let zero = try report.findings.first { $0.category == .zeroWindow }.required("fenêtre nulle")
        try expect(zero.title.contains("10.182.122.111"), "fenêtre annoncée par l’imprimante : \(zero.title)")
        let unanswered = try report.findings.first { $0.category == .unanswered }.required("sans réponse")
        try expect(unanswered.title.hasPrefix("1 requête DNS sans réponse"), "une seule requête malgré la répétition : \(unanswered.title)")
        try expect(report.findings.contains { $0.category == .failure && $0.title.contains("accès refusé (Mot de passe incorrect)") }, "RADIUS refusé")
        try expect(report.findings.contains { $0.category == .failure && $0.title.contains("486 Busy Here") }, "SIP occupé")
        try expect(report.findings.contains { $0.category == .latency && $0.title.contains("DNS") && $0.title.contains("300\u{00A0}ms") }, "DNS lent")
        let clock = try report.findings.first { $0.category == .clock }.required("horloge")
        try expect(clock.title.contains("+2,2\u{00A0}s"), "décalage d’environ 2,2 s : \(clock.title)")
        // Latences mesurées par flux.
        let handshake = try report.latencies.first { $0.kind == .tcp }.required("poignée de main")
        try expectEqual(handshake.count, 1, "une poignée de main")
        try expect(abs((handshake.median ?? 0) - 0.004) < 0.0005, "4 ms")
        let snmp = try report.latencies.first { $0.kind == .snmp }.required("SNMP")
        try expect(abs((snmp.median ?? 0) - 0.012) < 0.0005, "SNMP 12 ms")
        try expectEqual(report.findings.first?.severity, .critical, "le plus grave d’abord (retransmission de 50 %)")
        // Chaque filtre proposé se compile et retrouve ses paquets.
        for finding in report.findings {
            guard let text = finding.filter else { continue }
            let filter = try DisplayFilter.compile(text).get()
            let shown = log.packets.filter { filter?.matches($0) ?? true }.map(\.id)
            try expect(!shown.isEmpty, "« \(finding.title) » : le filtre « \(text) » montre des paquets")
        }
    }

    suite.add("Capture : flux RTP (perte, gigue RFC 3550, rapport RTCP, codec du SDP)") {
        var list: [(Double, [UInt8])] = []
        list.append((0, udp(phone, 5060, pbx, 5060, ServicePayloads.sipInvite)))
        // 50 paquets toutes les 20 ms, deux perdus (séq. 110 et 111), arrivées irrégulières.
        let jitters: [Double] = [0, 0.004, -0.003, 0.012, 0.001, -0.006, 0.015, 0, 0.008, -0.002]
        for index in 0..<52 where index != 10 && index != 11 {
            let header: [UInt8] = [0x80, 0x00, UInt8((100 + index) >> 8), UInt8((100 + index) & 0xFF)]
            let timestamp = UInt32(160 * index)
            let payload = header + [UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF),
                                    0x1A, 0x2B, 0x3C, 0x4D] + [UInt8](repeating: 0xFF, count: 160)
            list.append((0.1 + Double(index) * 0.02 + jitters[index % jitters.count], udp(phone, 16384, pbx, 20000, payload)))
        }
        list.append((1.3, udp(pbx, 20001, phone, 16385, ServicePayloads.rtcp)))
        let log = PacketCaptureLog(records: list.sorted { $0.0 < $1.0 }.map { PacketRecord(timestamp: 1_793_805_693 + $0.0, data: $0.1) })
        let report = CaptureFindingsAnalyzer.analyze(log)
        let stream = try report.rtpStreams.first.required("flux RTP")
        try expectEqual(stream.packets, 50, "paquets reçus")
        try expectEqual(stream.expected, 52, "paquets attendus")
        try expectEqual(stream.lost, 2, "perdus")
        try expectEqual(stream.codec, "PCMU", "codec annoncé par le SDP")
        try expectEqual(stream.clockRate, 8_000, "horloge")
        try expect(stream.jitter > 1 && stream.jitter < 20, "gigue plausible : \(stream.jitter) ms")
        try expect(abs((stream.reportedLoss ?? 0) - 12.0 / 256) < 0.0001, "perte RTCP")
        try expectEqual(stream.reportedJitter, 12, "gigue RTCP en ms (96 / 8 kHz)")
        let loss = try report.findings.first { $0.category == .rtpLoss }.required("perte RTP")
        try expect(loss.title.contains("3,8\u{00A0}%"), "2 sur 52 : \(loss.title)")
        try expectEqual(loss.filter, "rtp.ssrc == 439041101", "filtre par SSRC")
        try expectEqual(loss.severity, .warning, "entre 1 et 5 %")
        // Gigue exacte sur une suite régulière : nulle.
        let regular = (0..<10).map { (time: Double($0) * 0.02, timestamp: UInt32($0 * 160)) }
        try expect(CaptureFindingsAnalyzer.jitter(regular, rate: 8_000) < 1e-9, "aucune gigue")
        let shaky: [(time: Double, timestamp: UInt32)] = (0..<10).map { index in
            let late: Double = index % 2 == 0 ? 0 : 0.01
            return (time: Double(index) * 0.02 + late, timestamp: UInt32(index * 160))
        }
        try expect(CaptureFindingsAnalyzer.jitter(shaky, rate: 8_000) > 0.004, "gigue de 10 ms détectée")
    }

    suite.add("Capture : aucun constat sur une capture saine, formats (%, ms)") {
        let records = [
            PacketRecord(timestamp: 10.000, data: udp(mac, 50111, fgt, 161, ServicePayloads.snmpGet)),
            PacketRecord(timestamp: 10.008, data: udp(fgt, 161, mac, 50111, ServicePayloads.snmpResponse)),
        ]
        let report = CaptureFindingsAnalyzer.analyze(PacketCaptureLog(records: records))
        try expectEqual(report.findings.count, 0, "aucun constat")
        try expectEqual(report.latencies.count, 1, "une latence SNMP")
        try expectEqual(CaptureFindingsAnalyzer.milliseconds(0.0234), "23\u{00A0}ms", "ms")
        try expectEqual(CaptureFindingsAnalyzer.milliseconds(0.0042), "4,2\u{00A0}ms", "ms décimales")
        try expectEqual(CaptureFindingsAnalyzer.milliseconds(1.5), "1,50\u{00A0}s", "secondes")
        try expectEqual(CaptureFindingsAnalyzer.percent(0.0384), "3,8\u{00A0}%", "pour cent")
        try expectEqual(CaptureFindingsAnalyzer.median([3, 1, 2, 10]), 2.5, "médiane paire")
        try expectEqual(CaptureFindingsAnalyzer.analyze(PacketCaptureLog()).findings.count, 0, "capture vide")
    }
}

/// Adresses de l'essai (serveur NPS, serveur NTP, imprimante, groupe mDNS).
private enum IPv4Pair {
    static let nps = (MACAddress("00:15:5d:01:02:03")!, IPv4Address("10.10.0.12")!)
    static let ntp = (MACAddress("00:15:5d:04:05:06")!, IPv4Address("10.10.0.5")!)
    static let mdns = (MACAddress("01:00:5e:00:00:fb")!, IPv4Address("224.0.0.251")!)
    static let printerMAC = MACAddress("94:dd:f8:18:15:7d")!
    static let printer = IPv4Address("10.182.122.111")!
}

private extension Optional {
    func required(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
