import Foundation
import NetScopeCore

// Notes 96 et 97 (1.1.0) : serveur DHCP pirate, conflits d'adresses IP et bornes Wi-Fi pirates,
// sur données fixes. Aucun DHCPDISCOVER, aucune requête ARP ni balayage Wi-Fi.

private func offer(server: String, mac: String?, offered: String, router: String? = nil, xid: UInt32 = 7) -> DHCPOffer {
    var o = DHCPOffer(messageType: .offer, xid: xid, flagsBroadcast: true, offeredAddress: IPv4Address(offered)!)
    o.serverIdentifier = IPv4Address(server)
    o.sourceMAC = mac.flatMap(MACAddress.init)
    o.subnetMask = IPv4Address("255.255.255.0")
    o.routers = router.flatMap { IPv4Address($0) }.map { [$0] } ?? []
    o.dnsServers = [IPv4Address("8.8.8.8")!]
    return o
}

private func vendor(_ mac: MACAddress) -> String? {
    switch mac.ouiValue {
    case 0x04D590, 0x704CA5: return "Fortinet"
    case 0x9C5322: return "TP-Link"
    case 0x788A20: return "Ubiquiti"
    default: return nil
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

func registerPirateTests(_ suite: TestSuite) {
    // MARK: Note 96 : DHCP pirate

    suite.add("DHCP pirate : serveur déclaré, FortiGate du site et pirate") {
        let forti = offer(server: "10.0.0.1", mac: "04:D5:90:3A:7B:11", offered: "10.0.0.50", router: "10.0.0.1")
        let home = offer(server: "192.168.0.1", mac: "9C:53:22:01:02:03", offered: "192.168.0.100", router: "192.168.0.1")
        let declared = offer(server: "10.0.0.5", mac: "00:11:22:33:44:55", offered: "10.0.0.60", router: "10.0.0.1")
        // Rien de déclaré : la FortiGate (passerelle d'elle-même, MAC Fortinet) suffit à juger.
        let policy = RogueDHCPPolicy(text: "")
        try expect(!policy.isConfigured, "rien de déclaré")
        try expectEqual(policy.verdict(of: home), .nonVerifie, "sans référence : non vérifié")
        try expectEqual(policy.verdict(of: forti, isFortinet: { vendor($0) == "Fortinet" }), .fortiGate, "FortiGate reconnue par sa MAC")
        let site = RogueDHCPPolicy(text: "10.0.0.5", fortiGates: [IPv4Address("10.0.0.1")!])
        let findings = RogueDHCPAnalyzer.findings([declared, forti, home, forti], policy: site, vendor: vendor)
        try expectEqual(findings.count, 3, "une ligne par serveur")
        try expectEqual(findings.first?.verdict, .pirate, "pirate en tête")
        try expectEqual(findings.first?.reason, "Routeur domestique probable (branché à l’envers)", "routeur domestique")
        try expectEqual(findings.first?.gateway, IPv4Address("192.168.0.1"), "passerelle de l'offre")
        try expectEqual(findings.first?.pool, "192.168.0.0/24", "plage distribuée")
        try expectEqual(findings.first { $0.server == IPv4Address("10.0.0.1") }?.verdict, .fortiGate, "FortiGate par son adresse")
        try expectEqual(findings.first { $0.server == IPv4Address("10.0.0.5") }?.verdict, .attendu, "serveur déclaré")
        let result = RogueDHCPAnalyzer.monitorResult(findings, policyConfigured: true, now: now)
        try expect(!result.reachable, "sonde en panne")
        try expect(result.error?.contains("192.168.0.1 (9C:53:22:01:02:03)") == true, "pirate nommé avec sa MAC")
        let ok = RogueDHCPAnalyzer.monitorResult(Array(findings.dropFirst()), policyConfigured: true, now: now)
        try expect(ok.reachable && ok.error == nil && ok.problem == nil, "seulement des serveurs attendus")
        try expect(RogueDHCPAnalyzer.monitorResult([], policyConfigured: true, now: now).problem != nil, "aucune offre : alerte")
    }

    suite.add("DHCP pirate : le Test DHCP accepte la FortiGate du site") {
        let forti = offer(server: "10.0.0.1", mac: "04:D5:90:3A:7B:11", offered: "10.0.0.50", router: "10.0.0.1")
        var policy = DHCPServerPolicy(text: "10.0.0.5")
        try expectEqual(policy.status(of: forti), .unauthorized, "sans FortiGate connue")
        policy.fortiGates = [IPv4Address("10.0.0.1")!]
        try expectEqual(policy.status(of: forti), .expected, "adresse de la FortiGate")
        var byMAC = DHCPServerPolicy(text: "10.0.0.5")
        byMAC.isFortinet = { vendor($0) == "Fortinet" }
        try expectEqual(byMAC.status(of: forti), .expected, "MAC Fortinet passerelle d'elle-même")
    }

    suite.add("DHCP pirate : la sonde sans envoi possible n'évalue rien") {
        let probe = MonProbe(name: "DHCP", kind: .rogueDHCP, target: "en0")
        let context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], now: now)
        let outcome = await MonRunner.run(probe, context: context)
        try expect(outcome.noData, "aucun DHCPDISCOVER sans fonction d'envoi")
        var withFake = context
        withFake.rogueDHCPPolicy = RogueDHCPPolicy(text: "10.0.0.5")
        withFake.rogueDHCPDiscover = { _ in .success([offer(server: "10.0.0.9", mac: nil, offered: "10.0.0.70")]) }
        let rogue = await MonRunner.run(probe, context: withFake)
        try expect(!rogue.result.reachable, "réponse simulée d'un pirate : panne")
    }

    // MARK: Note 96 : conflits d'IP

    suite.add("Conflits d'IP : deux MAC, réponses contradictoires, MAC instable, sites séparés") {
        let gw = IPv4Address("10.0.0.1")!
        let ip = IPv4Address("10.0.0.20")!
        let a = MACAddress("04:D5:90:3A:7B:11")!, b = MACAddress("3C:7C:3F:A1:52:E8")!
        let c = MACAddress("F8:FF:C2:4A:10:3B")!, d = MACAddress("B8:27:EB:9E:41:0D")!
        var obs = [
            IPObservation(site: "Siège", ip: gw, mac: a, source: .arp, date: now.addingTimeInterval(-90)),
            IPObservation(site: "Siège", ip: gw, mac: b, source: .arp, date: now.addingTimeInterval(-60)),
            IPObservation(site: "Siège", ip: ip, mac: c, source: .scan, date: now.addingTimeInterval(-1200)),
            IPObservation(site: "Siège", ip: ip, mac: d, source: .fortiGate, date: now.addingTimeInterval(-300)),
            // Même IP sur un autre site : jamais un conflit (adresses privées partagées).
            IPObservation(site: "Laval", ip: ip, mac: a, source: .scan, date: now),
            // Trop vieux : hors fenêtre.
            IPObservation(site: "Laval", ip: ip, mac: b, source: .scan, date: now.addingTimeInterval(-7200)),
        ]
        // Proxy ARP : une MAC qui répond pour huit IP est ignorée.
        for n in 100..<108 {
            obs.append(IPObservation(site: "Siège", ip: IPv4Address("10.0.0.\(n)")!, mac: MACAddress("00:00:5E:00:01:01")!, source: .arp, date: now))
        }
        obs.append(IPObservation(site: "Siège", ip: IPv4Address("10.0.0.100")!, mac: c, source: .scan, date: now.addingTimeInterval(-10)))
        let mac = MACAddress("A4:83:E7:5C:21:9F")!
        let changes = [("10.0.0.61", 9.0), ("10.0.0.74", 7.0), ("10.0.0.61", 4.0), ("10.0.0.88", 2.0)].map {
            IPChange(site: "Siège", mac: mac, ip: IPv4Address($0.0)!, date: now.addingTimeInterval(-$0.1 * 3600))
        }
        let old = IPChange(site: "Siège", mac: c, ip: ip, date: now.addingTimeInterval(-3 * 86_400))
        let conflicts = IPConflictAnalyzer.analyze(obs, changes: changes + [old, old, old, old], gateways: ["Siège": gw], now: now)
        try expectEqual(conflicts.map(\.kind), [.arpContradictoire, .ipDeuxMAC, .macInstable], "ordre de gravité")
        try expect(conflicts[0].involvesGateway && conflicts[0].ip == gw, "passerelle usurpée en tête")
        try expect(conflicts[0].detail.contains("usurpation possible"), "usurpation signalée")
        try expectEqual(conflicts[1].ip, ip, "IP en double")
        try expectEqual(conflicts[1].sources, [.fortiGate, .scan], "sources combinées")
        try expectEqual(conflicts[2].ips.map(\.description), ["10.0.0.61", "10.0.0.74", "10.0.0.61", "10.0.0.88"], "suite des IP")
        try expect(!conflicts.contains { $0.site == "Laval" }, "rien pour Laval")
        let result = MonPirateChecks.conflictResult(conflicts, now: now)
        try expect(!result.reachable, "conflit : panne")
        try expectEqual(result.value, "2 conflits · 1 MAC instable", "valeur de la sonde")
        let unstable = MonPirateChecks.conflictResult([conflicts[2]], now: now)
        try expect(unstable.reachable && unstable.problem != nil, "MAC instable : alerte")
    }

    // MARK: Note 97 : bornes Wi-Fi pirates

    suite.add("Bornes pirates : sosie, borne branchée, voisine acceptée, FortiAP connue") {
        let site = "Siège"
        let forti = [
            FortiRogueAP(site: site, ssid: "Bureau-Corp", bssid: MACAddress("02:1F:6B:A0:44:93"), channel: 6, rssi: -58, status: .rogue, onWire: true),
            FortiRogueAP(site: site, ssid: "Cafe-Voisin", bssid: MACAddress("9C:53:22:5D:18:C2"), channel: 6, rssi: -78),
            FortiRogueAP(site: site, ssid: "UBNT-Logistik", bssid: MACAddress("78:8A:20:4E:C3:05"), channel: 11, rssi: -69),
            FortiRogueAP(site: site, ssid: "DIRECT-7D", bssid: MACAddress("96:DD:F8:18:15:7D"), channel: 1, rssi: -61, status: .accepted),
            FortiRogueAP(site: "Laval", ssid: "Invités", bssid: MACAddress("A4:2B:B0:11:72:0C"), channel: 11, rssi: -80),
        ].map(RogueAPSighting.init)
        let local = [
            WifiNetwork(ssid: "Invités", bssid: MACAddress("70:4C:A5:1E:22:A2"), channel: 36, rssi: -49, security: .open),
            WifiNetwork(ssid: "Invités", bssid: MACAddress("D2:6E:0E:41:9B:07"), channel: 11, rssi: -55, security: .open),
            // Même borne que la FortiGate : fusionnée, signal le plus fort retenu.
            WifiNetwork(ssid: "Cafe-Voisin", bssid: MACAddress("9C:53:22:5D:18:C2"), channel: 6, rssi: -70),
        ].map { RogueAPSighting($0, site: site) }
        let wired = [RogueAPWiredMAC(site: site, mac: MACAddress("78:8A:20:4E:C3:00")!, place: "SW-ETG2-01 · port 1/22")]
        let accepted: Set<String> = [RogueAPAnalyzer.key(site: site, bssid: MACAddress("9C:53:22:5D:18:C2"), ssid: nil),
                                     RogueAPAnalyzer.key(site: site, bssid: MACAddress("D2:6E:0E:41:9B:07"), ssid: nil)]
        let findings = RogueAPAnalyzer.classify(forti + local, siteSSIDs: [site: ["Groupe-Interne", "Invités"], "Laval": ["Groupe-Interne"]],
                                                wired: wired, accepted: accepted, vendor: vendor)
        func find(_ bssid: String) -> RogueAPFinding? { findings.first { $0.bssid == MACAddress(bssid) } }
        try expectEqual(findings.count, 7, "une ligne par borne")
        try expectEqual(find("D2:6E:0E:41:9B:07")?.classification, .pirate, "sosie d'Invités, même accepté")
        try expectEqual(find("D2:6E:0E:41:9B:07")?.reasons, [.sosie], "raison : sosie")
        try expectEqual(find("02:1F:6B:A0:44:93")?.reasons, [.filaire, .nonAutorisee], "on-wire et rogue")
        try expectEqual(find("78:8A:20:4E:C3:05")?.reasons, [.filaire], "MAC filaire voisine du BSSID")
        try expectEqual(find("78:8A:20:4E:C3:05")?.wiredPlace, "SW-ETG2-01 · port 1/22", "port de switch")
        try expectEqual(find("9C:53:22:5D:18:C2")?.reasons, [.acceptee], "voisine acceptée")
        try expectEqual(find("9C:53:22:5D:18:C2")?.sources, [.fortiGate, .thisMac], "deux sources fusionnées")
        try expectEqual(find("9C:53:22:5D:18:C2")?.rssi, -70, "signal le plus fort")
        try expectEqual(find("96:DD:F8:18:15:7D")?.reasons, [.acceptee], "acceptée dans FortiOS")
        try expectEqual(find("70:4C:A5:1E:22:A2")?.classification, .connue, "FortiAP du site vue par ce Mac")
        try expectEqual(find("A4:2B:B0:11:72:0C")?.classification, .voisine, "Invités de Laval n'est pas un sosie du Siège")
        try expectEqual(findings.prefix(3).map(\.classification), [.pirate, .pirate, .pirate], "pirates d'abord")
        let result = RogueAPAnalyzer.monitorResult(RogueAPAnalyzer.filter(findings, target: "siège"), now: now)
        try expect(!result.reachable, "sosie ou borne branchée : panne")
        try expectEqual(result.value, "3 pirates · 2 voisines", "valeur de la sonde")
        let quiet = RogueAPAnalyzer.monitorResult(RogueAPAnalyzer.filter(findings, target: "Laval"), now: now)
        try expect(quiet.reachable && quiet.problem == nil, "Laval sans pirate")
    }

    suite.add("Rapport : section Pirates et conflits") {
        let dhcp = RogueDHCPAnalyzer.findings([offer(server: "192.168.0.1", mac: "9C:53:22:01:02:03", offered: "192.168.0.100", router: "192.168.0.1")],
                                              policy: RogueDHCPPolicy(text: "10.0.0.1"), vendor: vendor)
        var input = ReportInput(devices: [])
        input.rogueDHCP = dhcp
        input.ipConflicts = IPConflictAnalyzer.analyze([
            IPObservation(site: "Siège", ip: IPv4Address("10.0.0.1")!, mac: MACAddress("04:D5:90:3A:7B:11")!, source: .arp, date: now),
            IPObservation(site: "Siège", ip: IPv4Address("10.0.0.1")!, mac: MACAddress("3C:7C:3F:A1:52:E8")!, source: .arp, date: now),
        ], gateways: ["Siège": IPv4Address("10.0.0.1")!], now: now)
        let config = ReportConfig(sections: [.pirates, .imprimantes], client: "Client", site: "Siège", technician: "Dany", date: "2026-11-06")
        let document = ReportBuilder.build(config: config, input: input)
        try expectEqual(document.sections.map(\.kind), [.imprimantes, .pirates], "ordre des sections")
        guard let blocks = document.sections.first(where: { $0.kind == .pirates })?.blocks else { throw TestFailure(message: "section pirates", file: #fileID, line: #line) }
        guard case .kpis(let kpis) = blocks[1] else { throw TestFailure(message: "indicateurs attendus", file: #fileID, line: #line) }
        try expectEqual(kpis.map(\.value), ["1", "1", "0", "0"], "un pirate DHCP, un conflit")
        guard case .paragraph(let advice) = blocks.last! else { throw TestFailure(message: "conseils attendus", file: #fileID, line: #line) }
        try expect(advice.contains("usurpation ARP possible"), "conseil passerelle")
        try expect(advice.contains("Serveur DHCP pirate 192.168.0.1"), "conseil DHCP")
    }
}
