import Foundation
import NetScopeCore

// Notes 89 et 90 : test de câble (TDR) et scan d'un VLAN tagué. Tout est vérifié sur des textes
// fixes : aucune commande SSH, aucune interface créée, aucun scan.

private let ciscoOutput = """
TDR test last run on: November 06 10:12:41

Interface Speed Local pair Pair length        Remote pair Pair status
--------- ----- ---------- ------------------ ----------- --------------------
Gi1/0/12  1000M Pair A     31   +/- 4  meters Pair A      Normal
                Pair B     31   +/- 4  meters Pair B      Normal
                Pair C     27   +/- 4  meters N/A         Open
                Pair D     31   +/- 4  meters Pair D      Normal
"""

private let ciscoShort = """
Interface Speed Local pair Pair length        Remote pair Pair status
Gi1/0/3   auto  Pair A     12   +/- 1  meters N/A         Short
                Pair B     N/A                N/A         Not Completed
                Pair C     40   +/- 1  meters Pair C      Impedance Mismatch
                Pair D     40   +/- 1  meters Pair D      Normal
"""

private let arubaCX = """
Interface  Pair   Status        Length (m)
--------------------------------------------
1/1/12     1-2    OK            48
           3-6    OK            48
           4-5    Short         17
           7-8    OK            48
"""

private let arubaAOSS = """
 Cable Diagnostic Status - Virtual Cable Test

 Port  MDI  Cable    Distance  Pair     Pair     MDI
       Mode Status   to Fault  Skew     Polarity Pair
 ----- ---- -------- --------- -------- -------- ------
 A3    MDIX Open     22m       -        -        -
"""

private let fortiSwitchOutput = """
port3: cable (4 pairs, length +/- 10 meters)
 pair A Ok, length 35 meters
 pair B Ok, length 35 meters
 pair C Open, length 27 meters
 pair D Ok, length 35 meters
"""

private let fortiGateJSON = """
{"http_method":"GET","results":{"pairs":[{"pair":"A","status":"ok","length":35},{"pair":"B","status":"open","length":12},
{"pair":"C","status":"ok","length":35},{"pair":"D","status":"ok","length":35}]},"status":"success"}
"""

private let listVLANs = """
VLAN User Defined Name: NetScope-VLAN-20
Parent Device: en0
Device ("Hardware" Port): vlan0
Tag: 20

VLAN User Defined Name: Bureau-Voix
Parent Device: en0
Device ("Hardware" Port): vlan1
Tag: 30
"""

private func cableTarget(port: String = "Gi1/0/12", uplink: Bool = false) -> PortActionTarget {
    PortActionTarget(switchName: "SW-CORE-01", switchHost: IPv4Address("10.182.122.2"), portName: port, ifIndex: 12, isUplink: uplink)
}

func registerCableTestVLANTests(_ suite: TestSuite) {
    suite.add("Test de câble : désactivé par défaut, garde-fous et port strict") {
        let off = CableTestGuard.decide(target: cableTarget(), settings: PortActionSettings(), vendor: .cisco,
                                        hasSSHAccount: true, fortiGateProblem: nil)
        try expect(!off.isAllowed && off.refusals.contains(.disabled), "désactivé par défaut")
        var settings = PortActionSettings()
        settings.cableTestEnabled = true
        let ok = CableTestGuard.decide(target: cableTarget(), settings: settings, vendor: .cisco, hasSSHAccount: true, fortiGateProblem: nil)
        try expectEqual(ok.channel, .ssh(host: "10.182.122.2", vendor: .cisco), "SSH vers le switch")
        let uplink = CableTestGuard.decide(target: cableTarget(uplink: true), settings: settings, vendor: .cisco, hasSSHAccount: true, fortiGateProblem: nil)
        try expect(uplink.refusals.contains(.uplink), "uplink refusé")
        let unknown = CableTestGuard.decide(target: cableTarget(), settings: settings, vendor: nil, vendorName: "MikroTik", hasSSHAccount: true, fortiGateProblem: nil)
        try expect(unknown.reason?.contains("non prise en charge") == true, "marque inconnue : raison")
        let injected = CableTestGuard.decide(target: cableTarget(port: "Gi1/0/1; reload"), settings: settings, vendor: .cisco, hasSSHAccount: true, fortiGateProblem: nil)
        try expect(injected.refusals.contains(.invalidPort("Gi1/0/1; reload")), "port avec « ; » refusé")
        let noAccount = CableTestGuard.decide(target: cableTarget(), settings: settings, vendor: .cisco, hasSSHAccount: false, fortiGateProblem: nil)
        try expect(noAccount.refusals.contains(.noSSHAccount), "sans identifiant SSH")
        var ro = cableTarget(); ro.readOnlyController = "UniFi"
        try expect(!CableTestGuard.decide(target: ro, settings: settings, vendor: .cisco, hasSSHAccount: true, fortiGateProblem: nil).isAllowed, "contrôleur en lecture seule")
        for bad in ["", "Gi1/0/1 ", "-oProxyCommand", "Gi1/0/1\nreload", "port3", "Gi1/0/1|x", "Gi1/0/1é"] {
            try expect(!CableTestCommands.isValidPort(bad, vendor: .cisco), "Cisco refuse «\(bad)»")
        }
        try expect(CableTestCommands.isValidPort("GigabitEthernet1/0/24", vendor: .cisco), "nom long Cisco")
        try expect(CableTestCommands.isValidPort("A3", vendor: .aruba) && CableTestCommands.isValidPort("1/1/12", vendor: .aruba), "ports Aruba")
        try expect(CableTestCommands.isValidPort("port12", vendor: .fortiSwitch) && !CableTestCommands.isValidPort("port1 2", vendor: .fortiSwitch), "ports FortiSwitch")
        for vendor in CableTestVendor.allCases {
            let port = vendor == .cisco ? "Gi1/0/12" : (vendor == .aruba ? "12" : "port3")
            let plan = try unwrap(CableTestCommands.plan(vendor: vendor, port: port), "plan \(vendor)")
            try expect(CableTestCommands.isAllowed(plan), "plan \(vendor) dans la liste fermée")
        }
        try expectEqual(CableTestCommands.plan(vendor: .cisco, port: "Gi1/0/12")?.steps.count, 2, "Cisco : lancement puis lecture")
        try expectEqual(CableTestCommands.plan(vendor: .aruba, port: "1/1/12")?.steps.first?[2], "diag cable-diagnostic 1/1/12", "AOS-CX")
        try expect(!CableTestCommands.isAllowed(.init(steps: [["reload"]], waitSeconds: 0)), "commande hors liste refusée")
        let decoded = try JSONDecoder().decode(PortActionSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        try expectEqual(decoded.cableTestEnabled, false, "clé absente : test de câble désactivé")
    }

    suite.add("Test de câble : sorties Cisco, Aruba, FortiSwitch et FortiGate") {
        let cisco = try CableTestParser.cisco(ciscoOutput).get()
        try expectEqual(cisco.count, 4, "Cisco : 4 paires")
        try expectEqual(cisco[2], CablePairResult(pair: 3, status: .open, meters: 27), "Cisco : paire C ouverte à 27 m")
        let result = CableTestResult(date: Date(), switchName: "SW", switchHost: "10.0.0.2", portName: "Gi1/0/12", vendor: .cisco, channel: "SSH", pairs: cisco)
        try expectEqual(result.headline, "Paire 3 coupée à 27\u{00A0}m", "titre du défaut")
        try expectEqual(result.status, .failure, "défaut : échec au bilan")
        let short = try CableTestParser.cisco(ciscoShort).get()
        try expectEqual(short.map(\.status), [.short, .unknown, .impedance, .ok], "Cisco : court-circuit, non mesurée, mal terminée")
        try expectEqual(short[1].meters, nil, "N/A : pas de distance")
        if case .success = CableTestParser.cisco("% Invalid input detected at '^' marker.") { throw TestFailure(message: "Cisco : commande refusée non vue", file: #file, line: #line) }
        if case .failure(let e) = CableTestParser.cisco("TDR test is in progress on interface Gi1/0/12") {
            try expect(e.message.contains("pas fini"), "Cisco : test en cours")
        } else { throw TestFailure(message: "Cisco : test en cours non vu", file: #file, line: #line) }
        let cx = try CableTestParser.aruba(arubaCX, port: "1/1/12").get()
        try expectEqual(cx[2], CablePairResult(pair: 3, status: .short, meters: 17), "AOS-CX : paire 4-5 en court-circuit")
        let aoss = try CableTestParser.aruba(arubaAOSS, port: "A3").get()
        try expectEqual(aoss, [CablePairResult(pair: 0, status: .open, meters: 22)], "AOS-S : câble coupé à 22 m")
        try expectEqual(aoss[0].summary, "câble coupé à 22\u{00A0}m", "AOS-S : paire non précisée")
        let forti = try CableTestParser.fortiSwitch(fortiSwitchOutput).get()
        try expectEqual(forti.map(\.status), [.ok, .ok, .open, .ok], "FortiSwitch : paire C ouverte")
        let good = CableTestResult(date: Date(), switchName: "SW", switchHost: "", portName: "port3", vendor: .fortiSwitch, channel: "",
                                   pairs: [1, 2, 3, 4].map { CablePairResult(pair: $0, status: .ok, meters: 35) })
        try expectEqual(good.headline, "Câble correct · environ 35\u{00A0}m", "câble correct et longueur")
        let gate = try CableTestParser.fortiGate(Data(fortiGateJSON.utf8)).get()
        try expectEqual(gate[1], CablePairResult(pair: 2, status: .open, meters: 12), "FortiGate : paire B ouverte")
        if case .success = CableTestParser.fortiSwitch("") { throw TestFailure(message: "sortie vide acceptée", file: #file, line: #line) }
    }

    suite.add("Test de câble : historique du port") {
        var history = CableTestHistory()
        for i in 0..<12 {
            history.add(CableTestResult(date: Date(timeIntervalSince1970: TimeInterval(1_000 + i)), switchName: "SW", switchHost: "",
                                        portName: "Gi1/0/1", vendor: .cisco, channel: "", pairs: []))
        }
        try expectEqual(history.results(switchName: "sw", port: "gi1/0/1").count, CableTestHistory.perPort, "10 par port")
        try expectEqual(history.results.first?.date, Date(timeIntervalSince1970: 1_011), "le plus récent d'abord")
        try expect(history.latest(switchName: "SW", port: "Gi1/0/1", since: Date(timeIntervalSince1970: 2_000)) == nil, "trop ancien pour le bilan")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nstdr-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        try expectEqual(CableTestHistory.load(from: url), history, "relu à l'identique")
        var check = LinkCheckResult(date: Date(), interfaceName: "en0", steps: [])
        check.cableTest = history.results.first
        let data = try JSONEncoder().encode(check)
        try expectEqual(try JSONDecoder().decode(LinkCheckResult.self, from: data).cableTest?.portName, "Gi1/0/1", "bilan : test gardé")
    }

    suite.add("VLAN tagué : validation, commandes et restes") {
        try expectEqual(VLANScanRequest.parseID("20"), 20, "20")
        try expectEqual(VLANScanRequest.parseID("vlan 4094"), 4094, "4094")
        for bad in ["0", "4095", "-1", "20; rm", "", "1e3", "٣"] { try expect(VLANScanRequest.parseID(bad) == nil, "refuse «\(bad)»") }
        try expect(throws: { _ = try VLANScanRequest(vlan: 4095, parent: "en0", addressing: .dhcp) }, "4095 refusé")
        try expect(throws: { _ = try VLANScanRequest(vlan: 20, parent: "en0;x", addressing: .dhcp) }, "parent refusé")
        try expect(throws: { _ = try VLANScanRequest(vlan: 20, parent: "en0", addressing: .manual(address: IPv4Address("10.0.20.0")!, prefix: 24, router: IPv4Address("10.0.20.1")!)) }, "adresse de réseau refusée")
        try expect(throws: { _ = try VLANScanRequest(vlan: 20, parent: "en0", addressing: .manual(address: IPv4Address("10.0.20.50")!, prefix: 24, router: IPv4Address("10.0.21.1")!)) }, "passerelle hors réseau refusée")
        let dhcp = try VLANScanRequest(vlan: 20, parent: "en0", addressing: .dhcp)
        try expectEqual(VLANScanCommands.createScript(dhcp),
                        "/usr/sbin/networksetup -createVLAN NetScope-VLAN-20 en0 20 && /usr/sbin/networksetup -setdhcp NetScope-VLAN-20", "création DHCP")
        let fixed = try VLANScanRequest(vlan: 30, parent: "en7", addressing: .manual(address: IPv4Address("10.0.30.250")!, prefix: 24, router: IPv4Address("10.0.30.1")!))
        try expect(VLANScanCommands.createScript(fixed).hasSuffix("-setmanual NetScope-VLAN-30 10.0.30.250 255.255.255.0 10.0.30.1"), "IP fixe")
        let entries = VLANEntry.parseList(listVLANs)
        try expectEqual(entries.count, 2, "deux VLAN listés")
        try expectEqual(entries[0], VLANEntry(name: "NetScope-VLAN-20", parent: "en0", device: "vlan0", tag: 20), "VLAN de NetScope")
        try expectEqual(VLANScanCommands.deleteScript(entries), "/usr/sbin/networksetup -deleteVLAN NetScope-VLAN-20 en0 20", "seul le VLAN de NetScope est retiré")
        try expect(VLANScanCommands.deleteScript([entries[1]]) == nil, "VLAN de l'utilisateur jamais retiré")
        try expect(!VLANEntry(name: "NetScope-VLAN-20", parent: "en0", tag: 21).isNetScope, "nom et numéro doivent concorder")
        try expectEqual(VLANScanPlan.range(address: IPv4Address("10.0.20.57")!, netmask: IPv4Address("255.255.255.0")!), "10.0.20.0/24", "sous-réseau /24")
        try expectEqual(VLANScanPlan.range(address: IPv4Address("10.20.3.4")!, netmask: IPv4Address("255.255.0.0")!), "10.20.0.0/22", "limité à /22")
        try expect(VLANScanPlan.isSelfAssigned(IPv4Address("169.254.3.4")!), "169.254 : DHCP muet")
        let proposals = VLANProposal.merge([(20, "LLDP"), (20, "FortiGate"), (20, "LLDP"), (5000, "x"), (10, "SW-CORE-01")])
        try expectEqual(proposals.map(\.vlan), [10, 20], "triés, valides, sans doublon")
        try expectEqual(proposals[1].sources, ["LLDP", "FortiGate"], "sources gardées")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nsvlan-\(UUID().uuidString).json")
        VLANScanLedger.save([entries[0], entries[1]], to: url)
        try expectEqual(VLANScanLedger.load(from: url), [entries[0]], "trace : seulement les VLAN de NetScope")
        VLANScanLedger.save([], to: url)
        try expect(!FileManager.default.fileExists(atPath: url.path), "trace vide : fichier retiré")
    }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(message: message, file: #file, line: #line) }
    return value
}

private func expect(throws body: () throws -> Void, _ message: String) throws {
    do { try body() } catch { return }
    throw TestFailure(message: message, file: #file, line: #line)
}
