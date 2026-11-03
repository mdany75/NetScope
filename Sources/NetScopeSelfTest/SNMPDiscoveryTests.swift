import Darwin
import Foundation
import NetScopeCore

// Tests de la découverte SNMP automatique, de l'ARP des routeurs, des switchs chaînés et des VLAN.
// Les faux agents écoutent sur 127.0.0.1 ; les adresses 10.0.0.x des tests sont redirigées vers eux
// par `SNMPDiscovery.endpoint` : aucun paquet ne part vers le réseau.

func registerSNMPDiscoveryTests(_ suite: TestSuite) {
    suite.add("SNMP découverte : classification par sysObjectID et sysDescr") {
        func kind(_ oid: String?, _ descr: String, ports: Int? = nil, printer: Bool = false) -> SNMPDeviceKind {
            SNMPDiscovery.classify(sysObjectID: oid, sysDescr: descr, bridgePorts: ports, hasPrinterMIB: printer)
        }
        try expectEqual(kind("1.3.6.1.4.1.9.1.2494", "Cisco IOS Software [Cupertino], Catalyst L3 Switch Software"), .switch, "Catalyst")
        try expectEqual(kind("1.3.6.1.4.1.9.1.2068", "Cisco IOS Software [Fuji], ISR Software (X86_64_LINUX_IOSD)"), .routeur, "Cisco ISR")
        try expectEqual(kind("1.3.6.1.4.1.9.1.2114", "Cisco Adaptive Security Appliance Version 9.16"), .routeur, "Cisco ASA")
        try expectEqual(kind("1.3.6.1.4.1.12356.106.1.248", "FortiSwitch-248E-FPOE v7.2.5"), .switch, "FortiSwitch")
        try expectEqual(kind("1.3.6.1.4.1.12356.101.1.10006", "FortiGate-100F"), .routeur, "FortiGate")
        try expectEqual(kind("1.3.6.1.4.1.12356.120.10.231", "FortiAP-231F"), .autre, "FortiAP")
        try expectEqual(kind("1.3.6.1.4.1.47196.4.1.1.1.62", "Aruba JL658A 6300M"), .switch, "Aruba CX")
        try expectEqual(kind("1.3.6.1.4.1.11.2.3.7.11.181", "HP J9773A 2530-24G-PoEP Switch"), .switch, "ProCurve")
        try expectEqual(kind("1.3.6.1.4.1.11.2.3.9.1", "HP ETHERNET MULTI-ENVIRONMENT"), .imprimante, "HP JetDirect")
        try expectEqual(kind("1.3.6.1.4.1.2636.1.1.1.2.132", "Juniper Networks, Inc. ex2300-24p Ethernet Switch"), .switch, "Juniper EX")
        try expectEqual(kind("1.3.6.1.4.1.2636.1.1.1.2.135", "Juniper Networks, Inc. srx300 internet router"), .routeur, "Juniper SRX")
        try expectEqual(kind("1.3.6.1.4.1.14988.1", "RouterOS RB4011iGS+"), .routeur, "MikroTik routeur")
        try expectEqual(kind("1.3.6.1.4.1.14988.1", "RouterOS CRS326-24G-2S+"), .switch, "MikroTik CRS")
        try expectEqual(kind("1.3.6.1.4.1.11863.1.1.3", "JetStream 24-Port Gigabit L2 Managed Switch"), .switch, "TP-Link")
        try expectEqual(kind("1.3.6.1.4.1.4526.100.4.37", "GS724Tv4 ProSafe"), .switch, "Netgear")
        try expectEqual(kind("1.3.6.1.4.1.171.10.76.28", "DGS-1210-28"), .switch, "D-Link")
        try expectEqual(kind("1.3.6.1.4.1.890.1.5.8.66", "GS1900-24E"), .switch, "Zyxel")
        try expectEqual(kind("1.3.6.1.4.1.674.10892.5", "Dell iDRAC"), .autre, "Dell iDRAC : pas un switch")
        try expectEqual(kind("1.3.6.1.4.1.674.10895.3031", "PowerConnect 5524P"), .switch, "Dell PowerConnect")
        try expectEqual(kind("1.3.6.1.4.1.6027.1.3.24", "Dell EMC Networking OS10 Enterprise"), .switch, "Dell OS10")
        try expectEqual(kind("1.3.6.1.4.1.41112.1.6", "UAP-AC-Pro 6.5.28"), .autre, "point d'accès UniFi")
        try expectEqual(kind("1.3.6.1.4.1.8072.3.2.10", "Linux nas 5.10.0", ports: nil), .autre, "Linux sans pont")
        try expectEqual(kind("1.3.6.1.4.1.8072.3.2.10", "Linux usw-flex 4.4", ports: 5), .switch, "pont de 5 ports : switch")
        try expectEqual(kind(nil, "Brother NC-8300h, Firmware Ver.1.10"), .imprimante, "Brother")
        try expectEqual(kind("1.3.6.1.4.1.1602.4.7", "Canon iR-ADV C5535", printer: true), .imprimante, "Printer-MIB")
        try expectEqual(kind("1.3.6.1.4.1.311.1.1.3.1.2", "Windows Server 2022"), .autre, "serveur Windows")
        try expectEqual(SNMPSystemInfo(name: "", descr: "", objectID: "1.3.6.1.4.1.171.10.76.28").brand, "D-Link", "marque D-Link")
        try expectEqual(SNMPSystemInfo(name: "", descr: "", objectID: "1.3.6.1.4.1.890.1.5").brand, "Zyxel", "marque Zyxel")
    }

    suite.add("SNMP découverte : communautés, switch par dot1dBaseNumPorts, hôte muet ignoré") {
        let switchAgent = try SNMPFakeAgent(tables: ["lecture": [
            SNMPVarBind(oid: SNMPOIDs.sysDescr, value: .octetString(Array("Linux switch-etage 4.14".utf8))),
            SNMPVarBind(oid: SNMPOIDs.sysObjectID, value: .oid("1.3.6.1.4.1.8072.3.2.10")),
            SNMPVarBind(oid: SNMPOIDs.sysName, value: .octetString(Array("SW-ETG2-01".utf8))),
            SNMPVarBind(oid: SNMPOIDs.dot1dBaseNumPorts, value: .integer(28)),
        ]])
        let printerAgent = try SNMPFakeAgent(tables: ["public": [
            SNMPVarBind(oid: SNMPOIDs.sysDescr, value: .octetString(Array("Lexmark CX725".utf8))),
            SNMPVarBind(oid: SNMPOIDs.sysName, value: .octetString(Array("IMP-COMPTA".utf8))),
            SNMPVarBind(oid: SNMPOIDs.prtGeneralConfigChanges, value: .counter32(3)),
        ]])
        let both = [SNMPVarBind(oid: SNMPOIDs.sysName, value: .octetString(Array("DEUX-COMMUNAUTES".utf8)))]
        let twoCommunities = try SNMPFakeAgent(tables: ["public": both, "lecture": both])
        let strict = try SNMPFakeAgent(tables: ["lecture": [
            SNMPVarBind(oid: SNMPOIDs.sysDescr, value: .octetString(Array("Cisco IOS Software, C2960X Software".utf8))),
            SNMPVarBind(oid: SNMPOIDs.sysObjectID, value: .oid("1.3.6.1.4.1.9.1.1208")),
            SNMPVarBind(oid: SNMPOIDs.sysName, value: .octetString(Array("SW-ANCIEN".utf8))),
        ]], strict: true)
        let mute = try SNMPFakeAgent(tables: [:], mute: true)
        let closedPort = try SNMPFakeAgent.unusedPort()
        defer { [switchAgent, printerAgent, twoCommunities, strict, mute].forEach { $0.stop() } }

        let localhost = IPv4Address("127.0.0.1")!
        let ports: [String: UInt16] = ["10.0.0.2": switchAgent.port, "10.0.0.3": printerAgent.port, "10.0.0.4": mute.port,
                                       "10.0.0.5": closedPort, "10.0.0.7": twoCommunities.port, "10.0.0.8": strict.port]
        let discovery = SNMPDiscovery(communities: ["public", "", "lecture", "public"], timeout: 0.25, retries: 1, concurrency: 64,
                                      endpoint: { (localhost, ports[$0.description] ?? closedPort) })
        try expectEqual(discovery.communities, ["public", "lecture"], "communautés vides et doublons retirés")

        let hosts = ["10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.7", "10.0.0.8", "10.0.0.2"].compactMap(IPv4Address.init)
        let progress = ProgressRecorder()
        let started = Date()
        let found = await discovery.discover(hosts) { done, total in progress.record(done, total) }
        let elapsed = Date().timeIntervalSince(started)

        try expectEqual(found.map(\.host.description), ["10.0.0.2", "10.0.0.3", "10.0.0.7", "10.0.0.8"], "hôtes qui répondent, triés")
        let sw = found[0]
        try expectEqual(sw.community, "lecture", "communauté retenue après l'échec de « public »")
        try expectEqual(sw.bridgePorts, 28, "dot1dBaseNumPorts")
        try expectEqual(sw.kind, .switch, "switch détecté par la BRIDGE-MIB")
        try expectEqual(sw.sysName, "SW-ETG2-01", "sysName")
        try expectEqual(sw.target().community, "lecture", "cible de relevé avec la communauté retenue")
        try expectEqual(found[1].kind, .imprimante, "imprimante par la Printer-MIB")
        try expectEqual(found[1].community, "public", "première communauté acceptée")
        try expectEqual(found[2].community, "public", "deux communautés valables : la première de la liste")
        try expectEqual(found[2].kind, .autre, "sans indice : autre")
        try expectEqual(found[3].sysName, "SW-ANCIEN", "agent strict relu variable par variable")
        try expectEqual(found[3].kind, .switch, "Cisco reconnu par sysObjectID")
        try expectEqual(found[3].brand, "Cisco", "marque")
        try expectEqual(progress.last?.done, 6, "progression : 6 hôtes distincts traités")
        try expectEqual(progress.last?.total, 6, "progression : total sans doublon")
        // Hôte muet : 2 communautés × 2 envois × 0,25 s ≈ 1 s, en parallèle des autres.
        try expect(elapsed < 2.5, "hôte muet abandonné dans le délai (\(String(format: "%.2f", elapsed)) s)")
        try expect(mute.requestCount >= 4, "hôte muet : renvoi et seconde communauté (\(mute.requestCount) requêtes)")
    }

    suite.add("SNMP découverte : annulation rapide") {
        let mute = try SNMPFakeAgent(tables: [:], mute: true)
        defer { mute.stop() }
        let localhost = IPv4Address("127.0.0.1")!
        let port = mute.port
        let discovery = SNMPDiscovery(communities: ["a", "b", "c"], timeout: 2, retries: 2, concurrency: 64,
                                      endpoint: { _ in (localhost, port) })
        let hosts = (1...300).map { IPv4Address(10, 1, UInt8($0 / 256), UInt8($0 % 256)) }
        let started = Date()
        let task = Task { await discovery.discover(hosts) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        try expect(result.isEmpty, "rien de trouvé")
        try expect(Date().timeIntervalSince(started) < 1.5, "arrêt en moins de 1,5 s")
        try expectEqual(await SNMPDiscovery(communities: [""]).discover(hosts), [], "aucune communauté : rien n'est envoyé")
    }

    suite.add("SNMP : ARP d'un routeur (ipNetToMedia et ipNetToPhysical)") {
        let routerTable: [SNMPVarBind] = [
            SNMPVarBind(oid: SNMPOIDs.ipNetToMediaPhysAddress.appending([3, 10, 20, 0, 15]),
                        value: .octetString([0x70, 0x4C, 0xA5, 0x1E, 0x22, 0x9A])),
            SNMPVarBind(oid: SNMPOIDs.ipNetToMediaPhysAddress.appending([3, 10, 20, 0, 255]),
                        value: .octetString([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),  // diffusion : ignorée
            SNMPVarBind(oid: SNMPOIDs.ipNetToPhysicalPhysAddress.appending([4, 1, 4, 10, 30, 0, 22]),
                        value: .octetString([0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D])),
            SNMPVarBind(oid: SNMPOIDs.ipNetToPhysicalPhysAddress.appending([4, 1, 10, 30, 0, 23]),
                        value: .octetString([0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7E])),
            SNMPVarBind(oid: SNMPOIDs.ipNetToPhysicalPhysAddress.appending([4, 2, 16, 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
                        value: .octetString([0x02, 0, 0, 0, 0, 1])),  // IPv6 : ignorée
        ]
        let agent = try SNMPFakeAgent(tables: ["routeur": routerTable])
        defer { agent.stop() }
        let localhost = IPv4Address("127.0.0.1")!
        let arp = await SNMPDiscovery.routerARP(host: localhost, community: "routeur", port: agent.port, timeout: 0.5)
        try expectEqual(arp.count, 3, "trois entrées IPv4 valables")
        try expectEqual(arp[IPv4Address("10.20.0.15")!], MACAddress("70:4c:a5:1e:22:9a"), "ipNetToMedia")
        try expectEqual(arp[IPv4Address("10.30.0.22")!], MACAddress("94:dd:f8:18:15:7d"), "ipNetToPhysical avec longueur")
        try expectEqual(arp[IPv4Address("10.30.0.23")!], MACAddress("94:dd:f8:18:15:7e"), "ipNetToPhysical sans longueur")
        try expectEqual(await SNMPDiscovery.routerARP(host: localhost, community: "mauvaise", port: agent.port, timeout: 0.2, retries: 0),
                        [:], "mauvaise communauté : table vide, sans erreur")
        let poller = SNMPSwitchPoller(target: SNMPTarget(host: localhost, port: agent.port, community: "routeur", timeout: 0.5))
        try expectEqual(try await poller.arp()[MACAddress("94:dd:f8:18:15:7d")!], IPv4Address("10.30.0.22"), "arp() : MAC → IP")
        try expectEqual(SNMPParse.arpPhysicalIndex([4, 1, 4, 10, 0, 0, 1])?.ip, IPv4Address("10.0.0.1"), "index ipNetToPhysical")
        try expect(SNMPParse.arpPhysicalIndex([4, 2, 4, 10, 0, 0, 1]) == nil, "type d'adresse autre qu'IPv4 refusé")
    }

    suite.add("SNMP : switchs chaînés, port d'accès plutôt que l'uplink") {
        func iface(_ n: Int) -> SNMPInterface { SNMPInterface(index: n, name: "Gi1/0/\(n)", operStatus: .up, speedMbps: 1000) }
        let pcA = MACAddress("02:00:00:00:03:01")!   // derrière B, port 3 (mini-switch de 3 postes)
        let pcB = MACAddress("02:00:00:00:04:01")!   // B, port 4
        var fdbB = [SNMPFDBEntry(mac: pcB, vlan: 20, bridgePort: 4, ifIndex: 4)]
        for n in 1...3 { fdbB.append(SNMPFDBEntry(mac: MACAddress(bytes: [2, 0, 0, 0, 3, UInt8(n)]), vlan: 20, bridgePort: 3, ifIndex: 3)) }
        // Le cœur A ne voit que deux de ces postes, sur son port 1 (vers B), sans LLDP.
        let fdbA = [SNMPFDBEntry(mac: pcA, vlan: 20, bridgePort: 1, ifIndex: 1), SNMPFDBEntry(mac: pcB, vlan: 20, bridgePort: 1, ifIndex: 1)]
        let core = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.1")!, system: SNMPSystemInfo(name: "SW-CORE", descr: ""),
                                      interfaces: (1...4).map(iface), fdb: fdbA)
        let floor = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.2")!, system: SNMPSystemInfo(name: "SW-ETAGE", descr: ""),
                                       interfaces: (1...4).map(iface), fdb: fdbB, pvid: [3: 20, 4: 20])
        try expectEqual(core.uplinkInterfaces(), [], "seul, le cœur ne sait pas que son port 1 est un uplink")
        try expectEqual(SNMPLocator.uplinks(in: [core, floor])[core.host], [1], "convergence : le port 1 mène à deux ports de B")
        let location = SNMPLocator.locate(pcA, in: [core, floor])
        try expectEqual(location?.switchName, "SW-ETAGE", "switch d'accès")
        try expectEqual(location?.portName, "Gi1/0/3", "port d'accès")
        try expectEqual(location?.vlan, 20, "VLAN")
        try expectEqual(SNMPLocator.sightings(of: pcA, in: [core, floor]).count, 2, "vu sur deux switchs")

        // LLDP : un voisin qui porte le nom d'un switch relevé est un uplink, même annoncé comme simple station.
        let neighbor = SNMPLLDPNeighbor(localPortNum: 2, ifIndex: 2, sysName: "sw-etage.bureau.local", portID: "Gi1/0/24", capabilities: [.station])
        let mac = MACAddress("02:00:00:00:09:09")!
        var lldpCore = core
        lldpCore.neighbors = [neighbor]
        lldpCore.fdb = [SNMPFDBEntry(mac: mac, vlan: 30, bridgePort: 2, ifIndex: 2)]
        var lldpFloor = floor
        lldpFloor.fdb = [SNMPFDBEntry(mac: mac, vlan: 30, bridgePort: 4, ifIndex: 4)]
        try expect(SNMPLocator.uplinks(in: [lldpCore, lldpFloor])[core.host]?.contains(2) == true, "uplink par le nom LLDP")
        try expectEqual(SNMPLocator.locate(mac, in: [lldpCore, lldpFloor])?.switchName, "SW-ETAGE", "localisé sur le switch d'étage")

        // ARP : la MAC de gestion du switch B apprise sur le port 3 du cœur fait de ce port un uplink.
        let bMAC = MACAddress("02:00:00:00:0b:0b")!
        var arpCore = core
        arpCore.fdb = [SNMPFDBEntry(mac: bMAC, vlan: 1, bridgePort: 3, ifIndex: 3)]
        arpCore.arp = [bMAC: floor.host]
        try expect(SNMPLocator.uplinks(in: [arpCore, floor])[core.host]?.contains(3) == true, "uplink par la MAC d'un switch relevé")
    }

    suite.add("SNMP : VLAN par fdbId (Q-BRIDGE) et par communauté@vlan (Cisco)") {
        let localhost = IPv4Address("127.0.0.1")!
        let qbridge = try SNMPFakeAgent(tables: ["q": [
            SNMPVarBind(oid: SNMPOIDs.dot1qVlanFdbId.appending([0, 30]), value: .integer(5)),
            SNMPVarBind(oid: SNMPOIDs.dot1qVlanFdbId.appending([0, 40]), value: .integer(6)),
            SNMPVarBind(oid: SNMPOIDs.dot1qVlanFdbId.appending([0, 41]), value: .integer(6)),
            SNMPVarBind(oid: SNMPOIDs.dot1qTpFdbPort.appending([5, 2, 0, 0, 0, 0, 1]), value: .integer(7)),
            SNMPVarBind(oid: SNMPOIDs.dot1qTpFdbPort.appending([6, 2, 0, 0, 0, 0, 2]), value: .integer(8)),
            SNMPVarBind(oid: SNMPOIDs.dot1qTpFdbPort.appending([99, 2, 0, 0, 0, 0, 3]), value: .integer(9)),
        ]])
        defer { qbridge.stop() }
        let qPoller = SNMPSwitchPoller(target: SNMPTarget(host: localhost, port: qbridge.port, community: "q", timeout: 0.5))
        let qFdb = try await qPoller.fdb(bridgePorts: [:])
        func vlan(_ last: UInt8, _ fdb: [SNMPFDBEntry]) -> Int?? { fdb.first { $0.mac == MACAddress(bytes: [2, 0, 0, 0, 0, last]) }.map(\.vlan) }
        try expectEqual(vlan(1, qFdb), .some(30), "fdbId 5 → VLAN 30")
        try expectEqual(vlan(2, qFdb), .some(nil), "fdbId partagé par deux VLAN : VLAN inconnu")
        try expectEqual(vlan(3, qFdb), .some(99), "fdbId absent de la table : c'est le VLAN")

        func vtp(_ vlan: UInt32, state: Int64 = 1) -> SNMPVarBind { SNMPVarBind(oid: SNMPOIDs.vtpVlanState.appending([1, vlan]), value: .integer(state)) }
        func context(_ port: UInt32, _ ifIndex: Int64, _ last: UInt8) -> [SNMPVarBind] {
            [SNMPVarBind(oid: SNMPOIDs.dot1dBasePortIfIndex.appending(port), value: .integer(ifIndex)),
             SNMPVarBind(oid: SNMPOIDs.dot1dTpFdbPort.appending([2, 0, 0, 0, 1, UInt32(last)]), value: .integer(Int64(port)))]
        }
        let cisco = try SNMPFakeAgent(tables: [
            "c": [vtp(1), vtp(10), vtp(20), vtp(30, state: 2), vtp(1002)],
            "c@1": [],
            "c@10": context(3, 10103, 1),
            "c@20": context(5, 10105, 2),
        ])
        defer { cisco.stop() }
        let cPoller = SNMPSwitchPoller(target: SNMPTarget(host: localhost, port: cisco.port, community: "c", timeout: 0.5))
        try expectEqual(try await cPoller.vtpVLANs(), [1, 10, 20], "VLAN actifs, réservés exclus")
        let cFdb = try await cPoller.fdb(bridgePorts: [:])
        try expectEqual(cFdb.count, 2, "deux MAC, une par VLAN")
        let first = cFdb.first { $0.mac == MACAddress(bytes: [2, 0, 0, 0, 1, 1]) }
        try expectEqual(first?.vlan, 10, "VLAN 10")
        try expectEqual(first?.ifIndex, 10103, "port de pont traduit dans le contexte du VLAN")
        try expectEqual(cFdb.first { $0.mac == MACAddress(bytes: [2, 0, 0, 0, 1, 2]) }?.vlan, 20, "VLAN 20")
    }
}

/// Enregistre la dernière progression reçue (appelée depuis un autre fil).
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (done: Int, total: Int)?

    func record(_ done: Int, _ total: Int) {
        lock.lock(); value = (done, total); lock.unlock()
    }

    var last: (done: Int, total: Int)? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Faux agent SNMP à plusieurs communautés (127.0.0.1 seulement)

/// Agent v2c de test : une table par communauté ; `mute` lit les requêtes sans jamais répondre ;
/// `strict` répond noSuchName à tout GET qui contient un objet absent (comportement SNMP v1).
final class SNMPFakeAgent: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let tables: [String: [SNMPVarBind]]
    private let mute: Bool
    private let strict: Bool
    private let lock = NSLock()
    private var running = true
    private var requests = 0
    private let finished = DispatchSemaphore(value: 0)

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    init(tables: [String: [SNMPVarBind]], mute: Bool = false, strict: Bool = false) throws {
        self.tables = tables.mapValues { $0.sorted { $0.oid < $1.oid } }
        self.mute = mute
        self.strict = strict
        (fd, port) = try Self.bindLoopback()
        Thread.detachNewThread { [self] in self.serve() }
    }

    /// Port UDP libre de 127.0.0.1 (socket fermée aussitôt) : un envoi y reçoit « port fermé ».
    static func unusedPort() throws -> UInt16 {
        let (sock, port) = try bindLoopback()
        close(sock)
        return port
    }

    private static func bindLoopback() throws -> (Int32, UInt16) {
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
        return (sock, UInt16(bigEndian: address.sin_port))
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
            guard count > 0, let request = try? SNMPMessage(decoding: Array(buffer[0..<count])) else { continue }
            lock.lock(); requests += 1; lock.unlock()
            guard !mute, let table = tables[request.community] else { continue }
            let reply = SNMPMessage(community: request.community, pdu: answer(request.pdu, table: table)).encoded()
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, raw.count, 0, $0, peerLength) }
                }
            }
        }
        finished.signal()
    }

    private func answer(_ pdu: SNMPPDU, table: [SNMPVarBind]) -> SNMPPDU {
        func next(after oid: SNMPOID) -> SNMPVarBind {
            table.first { $0.oid > oid } ?? SNMPVarBind(oid: oid, value: .endOfMibView)
        }
        var binds: [SNMPVarBind] = []
        switch pdu.type {
        case .getRequest:
            for (position, request) in pdu.varbinds.enumerated() {
                if let row = table.first(where: { $0.oid == request.oid }) {
                    binds.append(row)
                } else if strict {
                    return SNMPPDU(type: .response, requestID: pdu.requestID, errorStatus: SNMPErrorStatus.noSuchName.rawValue,
                                   errorIndex: position + 1, varbinds: pdu.varbinds)
                } else {
                    binds.append(SNMPVarBind(oid: request.oid, value: .noSuchInstance))
                }
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
