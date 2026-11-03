import Darwin
import Foundation
import NetScopeCore

// Tests du moteur SNMP (BER, messages, index, localisation, client contre un faux agent sur
// 127.0.0.1) et de l'analyse Wi-Fi. Aucun autre accès réseau.

func registerSNMPTests(_ suite: TestSuite) {
    suite.add("SNMP BER : aller-retour de chaque type") {
        let values: [SNMPValue] = [
            .integer(0), .integer(127), .integer(128), .integer(255), .integer(256), .integer(-1), .integer(-128), .integer(-129),
            .integer(Int64(Int32.max)), .integer(Int64(Int32.min)), .integer(.max), .integer(.min),
            .octetString([]), .octetString(Array("Gi1/0/12 · bureau".utf8)), .octetString([UInt8](repeating: 0x41, count: 300)),
            .null, .oid("1.3.6.1.2.1.1.5.0"), .oid("1.0.8802.1.1.2.1.4.1.1.9"), .oid("1.3.6.1.4.1.2636.1.1.1.2.4294967295"),
            .oid("2.999.3"), .ipAddress(IPv4Address("10.182.122.2")!),
            .counter32(0), .counter32(0x80), .counter32(.max), .gauge32(1000), .timeTicks(1_228_026_000),
            .counter64(0), .counter64(3_410_000_000_000), .counter64(.max), .opaque([1, 2, 3]),
            .noSuchObject, .noSuchInstance, .endOfMibView,
        ]
        for value in values {
            var reader = SNMPBERReader(SNMPBER.encode(value))
            let decoded = try reader.readValue()
            try expectEqual(decoded, value, "aller-retour \(value)")
            try expect(reader.isAtEnd, "rien après \(value)")
        }
        try expectEqual(SNMPBER.encode(.integer(128)), [0x02, 0x02, 0x00, 0x80], "128 sur deux octets")
        try expectEqual(SNMPBER.encode(.integer(-129)), [0x02, 0x02, 0xFF, 0x7F], "−129 en complément à deux")
        try expectEqual(SNMPBER.encode(.counter32(.max)), [0x41, 0x05, 0x00, 0xFF, 0xFF, 0xFF, 0xFF], "Counter32 max avec zéro de tête")
        try expectEqual(SNMPBER.encode(.oid("1.3.6.1.4.1.2636")), [0x06, 0x07, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x94, 0x4C], "OID base 128")
        try expectEqual(SNMPBER.encodeLength(300), [0x82, 0x01, 0x2C], "longueur en forme longue")
        try expect(SNMPOID("1.3.6.1.2.1.2") < SNMPOID("1.3.6.1.2.1.10"), "ordre numérique des OID")
        try expect(SNMPOID("1.3.6.1") < SNMPOID("1.3.6.1.0"), "un préfixe précède ses descendants")
        try expect(SNMPOID(String("1.3.a")) == nil, "OID illisible refusé")
    }

    suite.add("SNMP BER : messages tronqués ou invalides refusés") {
        let message = SNMPMessage(community: "lecture", pdu: SNMPPDU(type: .getRequest, requestID: 7, varbinds: [SNMPVarBind(oid: SNMPOIDs.sysName)]))
        let bytes = message.encoded()
        for cut in [1, 5, bytes.count / 2, bytes.count - 1] {
            var failed = false
            do { _ = try SNMPMessage(decoding: Array(bytes.prefix(cut))) } catch { failed = true }
            try expect(failed, "message coupé à \(cut) octets refusé")
        }
        var v3 = bytes
        v3[4] = 3  // version
        var refused = false
        do { _ = try SNMPMessage(decoding: v3) } catch { refused = true }
        try expect(refused, "SNMP v3 refusé")
    }

    suite.add("SNMP : aller-retour d'un message GetBulk") {
        let pdu = SNMPPDU.getBulk(requestID: 123_456, nonRepeaters: 0, maxRepetitions: 25, oids: [SNMPOIDs.ifName, SNMPOIDs.ifAlias])
        let message = SNMPMessage(community: "lecture-seule", pdu: pdu)
        let decoded = try SNMPMessage(decoding: message.encoded())
        try expectEqual(decoded, message, "message identique")
        try expectEqual(decoded.pdu.type, .getBulkRequest, "type GetBulk (0xA5)")
        try expectEqual(decoded.pdu.errorIndex, 25, "max-repetitions")
    }

    suite.add("SNMP : décodage d'une réponse GetResponse capturée") {
        // Octets fixes, assemblés indépendamment de l'encodeur : sysName, sysUpTime, ifHighSpeed.12,
        // ifHCInOctets.1, ipAdEntAddr, sysLocation absent (noSuchInstance).
        let bytes: [UInt8] = [
            0x30, 0x81, 0x95, 0x02, 0x01, 0x01, 0x04, 0x07, 0x6C, 0x65, 0x63, 0x74, 0x75, 0x72, 0x65, 0xA2, 0x81, 0x86, 0x02, 0x02,
            0x12, 0x34, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00, 0x30, 0x7A, 0x30, 0x16, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01,
            0x05, 0x00, 0x04, 0x0A, 0x53, 0x57, 0x2D, 0x43, 0x4F, 0x52, 0x45, 0x2D, 0x30, 0x31, 0x30, 0x10, 0x06, 0x08, 0x2B, 0x06,
            0x01, 0x02, 0x01, 0x01, 0x03, 0x00, 0x43, 0x04, 0x49, 0x32, 0x30, 0x90, 0x30, 0x11, 0x06, 0x0B, 0x2B, 0x06, 0x01, 0x02,
            0x01, 0x1F, 0x01, 0x01, 0x01, 0x0F, 0x0C, 0x42, 0x02, 0x03, 0xE8, 0x30, 0x15, 0x06, 0x0B, 0x2B, 0x06, 0x01, 0x02, 0x01,
            0x1F, 0x01, 0x01, 0x01, 0x06, 0x01, 0x46, 0x06, 0x03, 0x19, 0xF3, 0xD6, 0xB4, 0x00, 0x30, 0x16, 0x06, 0x0E, 0x2B, 0x06,
            0x01, 0x02, 0x01, 0x04, 0x14, 0x01, 0x01, 0x0A, 0x81, 0x36, 0x7A, 0x02, 0x40, 0x04, 0x0A, 0xB6, 0x7A, 0x02, 0x30, 0x0C,
            0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x06, 0x00, 0x81, 0x00,
        ]
        let message = try SNMPMessage(decoding: bytes)
        try expectEqual(message.version, 1, "v2c")
        try expectEqual(message.community, "lecture", "communauté")
        try expectEqual(message.pdu.type, .response, "GetResponse")
        try expectEqual(message.pdu.requestID, 0x1234, "request-id")
        try expectEqual(message.pdu.varbinds.count, 6, "6 variables")
        let v = message.pdu.varbinds
        try expectEqual(v[0].oid, SNMPOIDs.sysName, "OID sysName")
        try expectEqual(v[0].value.stringValue, "SW-CORE-01", "sysName")
        try expectEqual(v[1].value, .timeTicks(1_228_026_000), "sysUpTime")
        try expectEqual(SNMPFormat.duration(seconds: 1_228_026_000 / 100), "142 j 03 h", "uptime lisible")
        try expectEqual(v[2].oid, SNMPOIDs.ifHighSpeed.appending(12), "OID ifHighSpeed.12")
        try expectEqual(v[2].value, .gauge32(1000), "ifHighSpeed")
        try expectEqual(v[3].value, .counter64(3_410_000_000_000), "ifHCInOctets")
        try expectEqual(SNMPFormat.bytes(3_410_000_000_000), "3,41\u{00A0}To", "volume lisible")
        try expectEqual(v[4].oid.description, "1.3.6.1.2.1.4.20.1.1.10.182.122.2", "OID avec composant > 127")
        try expectEqual(v[4].value, .ipAddress(IPv4Address("10.182.122.2")!), "IpAddress")
        try expectEqual(v[5].value, .noSuchInstance, "exception noSuchInstance")
        try expectEqual(message.encoded(), bytes, "réencodage identique aux octets capturés")
    }

    suite.add("SNMP : index Q-BRIDGE, BRIDGE-MIB, LLDP et ARP") {
        let q = SNMPParse.qBridgeIndex([20, 0x70, 0x4C, 0xA5, 0x1E, 0x22, 0x9A])
        try expectEqual(q?.vlan, 20, "VLAN de l'index Q-BRIDGE")
        try expectEqual(q?.mac, MACAddress("70:4c:a5:1e:22:9a"), "MAC de l'index Q-BRIDGE")
        let oid: SNMPOID = "1.3.6.1.2.1.17.7.1.2.2.1.2.40.188.173.40.111.1.90"
        let parsed = oid.suffix(after: SNMPOIDs.dot1qTpFdbPort).flatMap(SNMPParse.qBridgeIndex)
        try expectEqual(parsed?.vlan, 40, "VLAN depuis l'OID complet")
        try expectEqual(parsed?.mac.description, "bc:ad:28:6f:01:5a", "MAC depuis l'OID complet")
        try expect(SNMPParse.qBridgeIndex([20, 1, 2, 3, 4, 5]) == nil, "index trop court refusé")
        try expect(SNMPParse.qBridgeIndex([20, 1, 2, 3, 4, 5, 256]) == nil, "octet > 255 refusé")
        try expectEqual(SNMPParse.bridgeIndex([0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D]), MACAddress("94:dd:f8:18:15:7d"), "index BRIDGE-MIB")
        let lldp = SNMPParse.lldpIndex([0, 12, 3])
        try expectEqual(lldp?.localPort, 12, "port local LLDP")
        try expectEqual(lldp?.remIndex, 3, "index distant LLDP")
        try expectEqual(SNMPParse.arpIndex([5, 10, 182, 122, 111])?.ip, IPv4Address("10.182.122.111"), "index ARP")
        let caps = SNMPLLDPCapabilities(bits: [0x28, 0x00])
        try expect(caps.contains(.bridge) && caps.contains(.router), "bits LLDP pont + routeur")
        try expect(!SNMPLLDPCapabilities(bits: [0x10]).isInfrastructure, "point d'accès seul : pas d'infrastructure")
        try expectEqual(SNMPParse.portIDText(.octetString(Array("Gi1/0/1".utf8))), "Gi1/0/1", "port LLDP texte")
        try expectEqual(SNMPParse.portIDText(.octetString([0x70, 0x4C, 0xA5, 0x1E, 0x22, 0x9A])), "70:4C:A5:1E:22:9A", "port LLDP MAC")
    }

    suite.add("SNMP : localisation d'une MAC, uplinks ignorés") {
        let host = IPv4Address("10.0.0.2")!
        let interfaces = (1...6).map { SNMPInterface(index: $0, name: "Gi1/0/\($0)", operStatus: .up, speedMbps: 1000) }
        let pc = MACAddress("b0:7b:25:44:a1:6c")!
        let far = MACAddress("8c:16:45:2b:9e:03")!
        var fdb = [
            SNMPFDBEntry(mac: pc, vlan: 10, bridgePort: 3, ifIndex: 3),
            SNMPFDBEntry(mac: pc, vlan: 10, bridgePort: 1, ifIndex: 1),
            SNMPFDBEntry(mac: far, vlan: 10, bridgePort: 1, ifIndex: 1),
        ]
        // Port 5 : 9 MAC sans voisin (switch non administré) ; port 6 : AP avec 9 clients Wi-Fi.
        for n in 0..<9 {
            fdb.append(SNMPFDBEntry(mac: MACAddress(bytes: [0x02, 0, 0, 0, 5, UInt8(n)]), vlan: 10, bridgePort: 5, ifIndex: 5))
            fdb.append(SNMPFDBEntry(mac: MACAddress(bytes: [0x02, 0, 0, 0, 6, UInt8(n)]), vlan: 20, bridgePort: 6, ifIndex: 6))
        }
        let neighbors = [
            SNMPLLDPNeighbor(localPortNum: 1, ifIndex: 1, sysName: "SW-ETG2-01", portID: "1/25", capabilities: [.bridge]),
            SNMPLLDPNeighbor(localPortNum: 6, ifIndex: 6, sysName: "FortiAP-231F", portID: "eth0", capabilities: [.accessPoint]),
        ]
        let snapshot = SNMPSwitchSnapshot(host: host, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco IOS"),
                                          interfaces: interfaces, fdb: fdb, neighbors: neighbors)
        try expectEqual(snapshot.uplinkInterfaces(), [1, 5], "uplinks : voisin pont et port à 9 MAC")
        let location = SNMPLocator.locate(pc, in: [snapshot])
        try expectEqual(location?.portName, "Gi1/0/3", "port d'accès retenu")
        try expectEqual(location?.vlan, 10, "VLAN")
        try expectEqual(location?.switchName, "SW-CORE-01", "switch")
        try expect(SNMPLocator.locate(far, in: [snapshot]) == nil, "MAC vue seulement sur l'uplink : non localisée")
        try expectEqual(SNMPLocator.sightings(of: far, in: [snapshot]).first?.isUplink, true, "mais signalée sur l'uplink")
        try expectEqual(SNMPLocator.locate(MACAddress(bytes: [0x02, 0, 0, 0, 6, 1]), in: [snapshot])?.portName, "Gi1/0/6",
                        "client Wi-Fi localisé sur le port de l'AP")
        try expect(!SNMPInterface(index: 99, name: "Vlan1", type: 53).isPhysical, "Vlan1 n'est pas un port physique")
        try expect(!SNMPInterface(index: 98, name: "Po1", type: 6).isPhysical, "Po1 n'est pas un port physique")
        try expect(SNMPInterface(index: 97, name: "Te1/1/1", type: 6).isModular, "Te1/1/1 est un port de module")
    }

    suite.add("SNMP : client contre un faux agent sur 127.0.0.1 (get, walk, relevé complet)") {
        var table: [SNMPVarBind] = [
            SNMPVarBind(oid: SNMPOIDs.sysDescr, value: .octetString(Array("Cisco IOS Software, C9300 Software".utf8))),
            SNMPVarBind(oid: SNMPOIDs.sysObjectID, value: .oid("1.3.6.1.4.1.9.1.2494")),
            SNMPVarBind(oid: SNMPOIDs.sysUpTime, value: .timeTicks(360_000)),
            SNMPVarBind(oid: SNMPOIDs.sysName, value: .octetString(Array("SW-TEST".utf8))),
        ]
        for i in 1...30 {
            table.append(SNMPVarBind(oid: SNMPOIDs.ifDescr.appending(UInt32(i)), value: .octetString(Array("GigabitEthernet1/0/\(i)".utf8))))
            table.append(SNMPVarBind(oid: SNMPOIDs.ifType.appending(UInt32(i)), value: .integer(6)))
            table.append(SNMPVarBind(oid: SNMPOIDs.ifOperStatus.appending(UInt32(i)), value: .integer(i % 3 == 0 ? 2 : 1)))
            table.append(SNMPVarBind(oid: SNMPOIDs.ifName.appending(UInt32(i)), value: .octetString(Array("Gi1/0/\(i)".utf8))))
            table.append(SNMPVarBind(oid: SNMPOIDs.ifHighSpeed.appending(UInt32(i)), value: .gauge32(1000)))
            table.append(SNMPVarBind(oid: SNMPOIDs.dot1dBasePortIfIndex.appending(UInt32(i)), value: .integer(Int64(i))))
        }
        table.append(SNMPVarBind(oid: SNMPOIDs.dot1qTpFdbPort.appending([30, 0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D]), value: .integer(14)))
        table.append(SNMPVarBind(oid: SNMPOIDs.lldpRemSysName.appending([0, 1, 1]), value: .octetString(Array("SW-CORE-01".utf8))))
        table.append(SNMPVarBind(oid: SNMPOIDs.lldpRemPortId.appending([0, 1, 1]), value: .octetString(Array("Gi1/0/47".utf8))))
        table.append(SNMPVarBind(oid: SNMPOIDs.lldpLocPortId.appending(1), value: .octetString(Array("Gi1/0/1".utf8))))

        let agent = try SNMPTestAgent(community: "essai", table: table)
        defer { agent.stop() }
        let localhost = IPv4Address("127.0.0.1")!
        let client = SNMPClient(target: SNMPTarget(host: localhost, port: agent.port, community: "essai", timeout: 1, retries: 1))

        let got = try await client.get([SNMPOIDs.sysName, SNMPOIDs.sysLocation])
        try expectEqual(got.first?.value.stringValue, "SW-TEST", "get sysName")
        try expectEqual(got.last?.value, .noSuchInstance, "sysLocation absent")

        let names = try await client.walk(SNMPOIDs.ifName, maxRepetitions: 7)
        try expectEqual(names.count, 30, "walk : 30 lignes en plusieurs GetBulk")
        try expectEqual(names.last?.value.stringValue, "Gi1/0/30", "dernière ligne")
        try expect(agent.requestCount >= 5, "plusieurs requêtes GetBulk (\(agent.requestCount))")
        try expectEqual(try await client.walk(SNMPOIDs.ifAlias).count, 0, "table absente : liste vide")

        let snapshot = try await SNMPSwitchPoller(client: client).snapshot()
        try expectEqual(snapshot.system.name, "SW-TEST", "relevé : nom")
        try expectEqual(snapshot.system.brand, "Cisco", "relevé : marque d'après sysObjectID")
        try expectEqual(snapshot.system.uptimeText, "1 h 00 min", "relevé : uptime")
        try expectEqual(snapshot.physicalPorts.count, 30, "relevé : 30 ports physiques")
        try expectEqual(snapshot.interfaces.filter(\.isUp).count, 20, "relevé : 20 ports actifs")
        try expectEqual(snapshot.fdb.first?.ifIndex, 14, "relevé : MAC sur l'ifIndex 14")
        try expectEqual(snapshot.fdb.first?.vlan, 30, "relevé : VLAN 30")
        try expectEqual(snapshot.neighbors.first?.ifIndex, 1, "relevé : voisin LLDP sur Gi1/0/1")
        let location = SNMPLocator.locate(MACAddress("94:dd:f8:18:15:7d")!, in: [snapshot])
        try expectEqual(location?.portName, "Gi1/0/14", "relevé : imprimante localisée")

        let wrong = SNMPClient(target: SNMPTarget(host: localhost, port: agent.port, community: "mauvaise", timeout: 0.3, retries: 0))
        do {
            _ = try await wrong.get([SNMPOIDs.sysName])
            throw TestFailure(message: "mauvaise communauté : réponse inattendue", file: #fileID, line: #line)
        } catch let error as SNMPError {
            try expectEqual(error, .timeout("127.0.0.1"), "mauvaise communauté : délai dépassé")
        }
    }

    suite.add("SNMP : communauté vide jamais envoyée") {
        let client = SNMPClient(target: SNMPTarget(host: IPv4Address("127.0.0.1")!, port: 9, community: ""))
        do {
            _ = try await client.get([SNMPOIDs.sysName])
            throw TestFailure(message: "aucune erreur", file: #fileID, line: #line)
        } catch let error as SNMPError {
            try expectEqual(error, .emptyCommunity, "erreur communauté vide")
        }
    }

    suite.add("Wi-Fi : géométrie des canaux et recommandations") {
        func net(_ ssid: String?, _ bssid: String, _ channel: Int, _ band: WifiBand, _ width: Int, _ rssi: Int,
                 _ security: WifiSecurity = .wpa2Personal, connected: Bool = false) -> WifiNetwork {
            WifiNetwork(ssid: ssid, bssid: MACAddress(bssid), channel: channel, band: band, widthMHz: width, rssi: rssi,
                        noise: -92, security: security, isConnected: connected)
        }
        let span44 = WifiChannelLayout.span(channel: 44, band: .ghz5, widthMHz: 80)
        try expectEqual(span44.center, 1.5, "canal 44 en 80 MHz : bloc 36–48")
        try expectEqual(span44.half, 2, "demi-largeur 80 MHz")
        try expectEqual(WifiChannelLayout.span(channel: 6, band: .ghz24, widthMHz: 20).half, 2, "2,4 GHz : ±2 canaux")
        let connected = net("Bureau-Corp", "70:4c:a5:1e:22:a0", 44, .ghz5, 80, -52, .wpa3Enterprise, connected: true)
        let networks = [
            connected,
            net("Bureau-Corp", "70:4c:a5:3b:91:18", 36, .ghz5, 80, -66, .wpa3Enterprise),
            net("Bureau-Corp", "02:1f:6b:a0:44:93", 6, .ghz24, 20, -58),
            net("Invite-Libre", "70:4c:a5:3b:91:11", 6, .ghz24, 20, -62, .open),
            net(nil, "9c:53:22:7b:0e:41", 6, .ghz24, 20, -74),
            net("Cafe-Voisin", "9c:53:22:5d:18:c2", 6, .ghz24, 20, -78),
            net("Entrepot-Nord", "94:b4:0f:62:7a:01", 6, .ghz24, 20, -71),
            net("DIRECT-imprimante", "96:dd:f8:18:15:7d", 1, .ghz24, 20, -61),
            net("Voisin-5", "3c:52:a1:09:7e:2c", 40, .ghz5, 20, -70),
        ]
        try expect(WifiChannelLayout.overlaps(networks[0], networks[1]), "36 et 44 en 80 MHz se chevauchent")
        try expect(!WifiChannelLayout.overlaps(networks[7], networks[3]), "canaux 1 et 6 : pas de chevauchement")
        try expectEqual(WifiAdvisor.occupancy24(networks)[6], 5, "5 réseaux sur le canal 6")
        try expectEqual(WifiAdvisor.bestChannel24(networks), 11, "canal 11 libre")
        try expectEqual(WifiAdvisor.suspiciousTwins(networks, connected: connected).map(\.bssid), [MACAddress("02:1f:6b:a0:44:93")],
                        "jumeau suspect : même SSID, autre constructeur")
        let recos = WifiAdvisor.recommendations(networks: networks, connected: connected)
        let ids = recos.map(\.id)
        try expectEqual(recos.first?.severity, .critique, "le jumeau suspect d'abord")
        try expect(ids.contains("encombre-24"), "canal 6 encombré")
        try expect(ids.contains("deplacer-24"), "conseil de canal")
        try expect(ids.contains { $0.hasPrefix("ouvert-") }, "réseau ouvert signalé")
        try expect(ids.contains("cache"), "SSID caché signalé")
        try expect(ids.contains("chevauchement-5"), "chevauchement 5 GHz signalé")
        try expectEqual(WifiQuality.dbm(-52), "\u{2212}52\u{00A0}dBm", "format dBm")
        try expectEqual(WifiQuality.percent(rssi: -30), 100, "barre pleine à −30 dBm")
    }
}

// MARK: - Faux agent SNMP (127.0.0.1 seulement)

/// Agent SNMP v2c minimal pour les tests : Get, GetNext et GetBulk sur une table fixe.
final class SNMPTestAgent: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let community: String
    private let table: [SNMPVarBind]
    private let lock = NSLock()
    private var running = true
    private var requests = 0
    private let finished = DispatchSemaphore(value: 0)

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    init(community: String, table: [SNMPVarBind]) throws {
        self.community = community
        self.table = table.sorted { $0.oid < $1.oid }
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw TestSkipped(reason: "socket UDP indisponible") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(sock)
            throw TestSkipped(reason: "impossible d'écouter sur 127.0.0.1")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        fd = sock
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in self.serve() }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        close(fd)
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while isRunning {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &peerLength) }
                }
            }
            guard count > 0, let request = try? SNMPMessage(decoding: Array(buffer[0..<count])),
                  request.community == community else { continue }
            lock.lock(); requests += 1; lock.unlock()
            let reply = SNMPMessage(community: community, pdu: answer(request.pdu)).encoded()
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, raw.count, 0, $0, peerLength) }
                }
            }
        }
        finished.signal()
    }

    private func next(after oid: SNMPOID) -> SNMPVarBind {
        table.first { $0.oid > oid } ?? SNMPVarBind(oid: oid, value: .endOfMibView)
    }

    private func answer(_ pdu: SNMPPDU) -> SNMPPDU {
        var binds: [SNMPVarBind] = []
        switch pdu.type {
        case .getRequest:
            binds = pdu.varbinds.map { request in
                table.first { $0.oid == request.oid } ?? SNMPVarBind(oid: request.oid, value: .noSuchInstance)
            }
        case .getNextRequest:
            binds = pdu.varbinds.map { next(after: $0.oid) }
        case .getBulkRequest:
            for request in pdu.varbinds {
                var current = request.oid
                for _ in 0..<max(1, pdu.errorIndex) {
                    let bind = next(after: current)
                    binds.append(bind)
                    if bind.value == .endOfMibView { break }
                    current = bind.oid
                }
            }
        default:
            break
        }
        return SNMPPDU(type: .response, requestID: pdu.requestID, varbinds: binds)
    }
}
