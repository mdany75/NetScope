import Foundation
import NetScopeCore

// Note 111 : CLI de la FortiGate. Analyse de sorties fixes, commandes autorisées et moment où la CLI
// sert ; aucun ssh n'est lancé, aucun réseau.

func registerFortiCLITests(_ suite: TestSuite) {
    let mac = MACAddress("04:C1:03:BA:90:FA")!
    let other = MACAddress("04:C1:03:BA:93:17")!
    let ip116 = IPv4Address("10.182.122.116")!

    suite.add("CLI FortiGate : seules deux commandes de lecture") {
        try expectEqual(FortiCLI.commands, ["execute dhcp lease-list", "diagnose ip arp list"], "liste fermée")
        try expect(!FortiCLI.isAllowed("execute reboot"), "commande refusée")
        try expect(FortiCLI.remoteCommands("execute factoryreset", vdom: "").isEmpty, "rien à envoyer")
        try expectEqual(FortiCLI.remoteCommands(FortiCLI.arpList, vdom: ""), [FortiCLI.arpList, "sudo root diagnose ip arp list"], "sans VDOM, puis root")
        try expectEqual(FortiCLI.remoteCommands(FortiCLI.arpList, vdom: "root"), ["sudo root diagnose ip arp list", FortiCLI.arpList], "root, puis sans VDOM")
        try expectEqual(FortiCLI.remoteCommands(FortiCLI.arpList, vdom: "clients"), ["sudo clients diagnose ip arp list"], "autre VDOM : pas de repli")
        try expect(FortiCLI.remoteCommands(FortiCLI.arpList, vdom: "root\nexecute reboot").isEmpty, "VDOM piégé refusé")
        for vdom in ["", "root", "clients"] {
            try expect(FortiCLI.remoteCommands(FortiCLI.leaseList, vdom: vdom).allSatisfy { !$0.contains("edit") && !$0.contains("config") }, "aucun contexte qui peut créer un VDOM")
        }
        let target = ConfigSSHTarget(user: "lecture", host: "10.0.0.1")
        let arguments = FortiCLISSH.arguments(target, remoteCommand: FortiCLI.leaseList)
        try expectEqual(Array(arguments.suffix(3)), ["--", "lecture@10.0.0.1", "execute dhcp lease-list"], "commande après la destination")
        try expect(arguments.contains("StrictHostKeyChecking=ask"), "serveur inconnu jamais accepté tout seul")
    }

    suite.add("CLI FortiGate : baux DHCP et table ARP") {
        let leases = FortiCLI.parseLeases("""
        internal
          IP            MAC-Address        Hostname            VCI     Expiry
          10.182.122.116  04:c1:03:ba:90:fa  Clover-Flex-4-C406          Mon Nov  9 10:00:00 2026
          10.182.122.139  2a:e7:e6:63:11:92  iPad-5                      Mon Nov  9 11:00:00 2026

        Fortigate-60F #
        """)
        try expectEqual(leases.map(\.ip.description), ["10.182.122.116", "10.182.122.139"], "lignes reconnues seulement")
        try expectEqual(leases[0].mac, mac, "MAC du bail")

        let arp = FortiCLI.parseARP("""
        index=5 ifname=internal 10.182.122.116 04:c1:03:ba:90:fa state=00000002 use=12 confirm=34 update=56 ref=2
        index=5 ifname=internal 10.182.122.130 04:c1:03:ba:90:fa state=00000004 use=900 confirm=901 update=902 ref=0
        index=5 ifname=internal 10.182.122.250 state=00000020 use=1 confirm=1 update=1 ref=0
        index=5 ifname=internal 10.182.122.251 00:00:00:00:00:00 state=00000002 use=1 confirm=1 update=1 ref=0
        """)
        try expectEqual(arp.map(\.ip.description), ["10.182.122.116", "10.182.122.130"], "échecs et MAC nulles écartés")
        try expectEqual(arp.map(\.isReachable), [true, false], "joignable ou non")
    }

    suite.add("CLI FortiGate : choisir l’IP actuelle") {
        let snapshot = FortiCLISnapshot(leases: [FortiCLILease(ip: IPv4Address("10.182.122.130")!, mac: mac), FortiCLILease(ip: ip116, mac: mac)],
                                        arp: [FortiCLIARPEntry(ip: ip116, mac: mac, isReachable: true)])
        try expectEqual(snapshot.holder(of: ip116), mac, "détenteur par le bail")
        try expectEqual(snapshot.currentIP(of: mac, preferring: nil), ip116, "bail joignable préféré au premier bail")
        let noARP = FortiCLISnapshot(leases: snapshot.leases)
        try expectEqual(noARP.currentIP(of: mac, preferring: ip116), ip116, "sans ARP : l’IP cherchée")
        try expect(noARP.currentIP(of: mac, preferring: nil) == nil, "plusieurs baux sans preuve : pas de choix au hasard")
        let single = FortiCLISnapshot(leases: [FortiCLILease(ip: ip116, mac: mac)])
        try expectEqual(single.currentIP(of: mac, preferring: nil), ip116, "bail unique")
        let moved = FortiCLISnapshot(leases: [FortiCLILease(ip: ip116, mac: mac)], arp: [FortiCLIARPEntry(ip: ip116, mac: other, isReachable: true)])
        try expectEqual(moved.holder(of: ip116), other, "l’appareil qui répond passe devant un ancien bail")
        let reached = IPv4Address("10.182.122.200")!
        let elsewhere = FortiCLISnapshot(leases: [FortiCLILease(ip: ip116, mac: mac)], arp: [FortiCLIARPEntry(ip: reached, mac: mac, isReachable: true)])
        try expectEqual(elsewhere.currentIP(of: mac, preferring: nil), reached, "IP joignable devant un bail non confirmé")
        try expect(FortiCLI.parseARP("").isEmpty, "sortie vide")
    }

    func reader(_ responses: [String: (Int, String)]) -> FortiGateReader {
        FortiGateReader(transport: FortiFakeTransport(responses), tokenForRedaction: FortiFixtures.token)
    }
    let arp = #"{"status":"success","results":[{"ip":"10.182.122.116","mac":"04:c1:03:ba:93:17"},{"ip":"10.182.122.130","mac":"04:c1:03:ba:90:fa"}]}"#
    let wifi = #"{"status":"success","results":[{"mac":"04:c1:03:ba:90:fa","ip":"10.182.122.116","wtp_name":"FP231-A"}]}"#

    final class Calls: @unchecked Sendable { var count = 0 }

    suite.add("CLI FortiGate : lancée seulement s’il y a un doute") {
        let calls = Calls()
        let answer = FortiCLISnapshot(leases: [FortiCLILease(ip: ip116, mac: mac)])
        let cli: @Sendable () async -> Result<FortiCLISnapshot, ConfigBackupError> = { calls.count += 1; return .success(answer) }

        // Un seul appareil désigné par l'API : pas de doute, pas de SSH.
        let single = #"{"status":"success","results":[{"ip":"10.182.122.116","mac":"04:c1:03:ba:90:fa"}]}"#
        let certain = try await reader([FortiPaths.arp: (200, single)]).readDeviceSightingReport(FortiDeviceTarget(ip: ip116), cli: cli)
        try expectEqual(calls.count, 0, "IP filaire sans contradiction : aucune connexion")
        try expect(!certain.usedCLI, "API seule")

        // MAC avec une seule adresse : pas de doute ; avec deux : la CLI tranche.
        _ = try await reader([FortiPaths.arp: (200, single)]).readDeviceSightingReport(FortiDeviceTarget(macs: [mac]), cli: cli)
        try expectEqual(calls.count, 0, "MAC avec une adresse : aucune connexion")
        let twoIPs = #"{"status":"success","results":[{"ip":"10.182.122.116","mac":"04:c1:03:ba:90:fa"},{"ip":"10.182.122.130","mac":"04:c1:03:ba:90:fa"}]}"#
        let byMAC = try await reader([FortiPaths.arp: (200, twoIPs)]).readDeviceSightingReport(FortiDeviceTarget(macs: [mac]), cli: cli)
        try expectEqual(calls.count, 1, "MAC avec deux adresses : la CLI tranche")
        try expect(byMAC.usedCLI, "bail retenu")
        try expectEqual(byMAC.observations.filter { $0.kind == .ip }.map(\.value), [ip116.description], "une seule IP")
        calls.count = 0

        // Client Wi-Fi associé à cette IP : l'API suffit.
        let known = try await reader([FortiPaths.arp: (200, arp), FortiWifiPaths.client: (200, wifi)])
            .readDeviceSightingReport(FortiDeviceTarget(ip: ip116), cli: cli)
        try expectEqual(calls.count, 0, "aucune connexion SSH inutile")
        try expect(!known.usedCLI, "CLI non utilisée")

        // Sources contradictoires : le bail DHCP tranche.
        let contradictory = #"{"status":"success","results":[{"mac":"04:c1:03:ba:93:17","ipv4_address":"10.182.122.116"}]}"#
        let arpOther = #"{"status":"success","results":[{"ip":"10.182.122.116","mac":"04:c1:03:ba:90:fa"}]}"#
        let doubt = try await reader([FortiPaths.arp: (200, arpOther), FortiPaths.userDevices: (200, contradictory)]).readDeviceSightingReport(FortiDeviceTarget(ip: ip116), cli: cli)
        try expectEqual(calls.count, 1, "CLI appelée une fois")
        try expect(doubt.usedCLI, "CLI utilisée")
        try expect(doubt.observations.allSatisfy { $0.mac == mac }, "le bail désigne le bon appareil")
        try expect(doubt.observations.contains { $0.kind == .ip && $0.value == ip116.description }, "IP du bail")

        // CLI en panne : l'API reste montrée, l'erreur est remontée.
        let refused: @Sendable () async -> Result<FortiCLISnapshot, ConfigBackupError> = { .failure(ConfigBackupError(kind: .authentication, detail: "refusé")) }
        let failed = try await reader([FortiPaths.arp: (200, arpOther), FortiPaths.userDevices: (200, contradictory)]).readDeviceSightingReport(FortiDeviceTarget(ip: ip116), cli: refused)
        try expectEqual(failed.cliError?.kind, .authentication, "erreur remontée")
        try expect(failed.observations.isEmpty == false, "repli sur l’API")

        // CLI lue, mais rien sur cet appareil : pas de « confirmé ».
        let unrelated: @Sendable () async -> Result<FortiCLISnapshot, ConfigBackupError> = { .success(FortiCLISnapshot()) }
        let silent = try await reader([FortiPaths.arp: (200, twoIPs)]).readDeviceSightingReport(FortiDeviceTarget(macs: [mac]), cli: unrelated)
        try expect(!silent.usedCLI && silent.cliHadNothing, "la CLI n’a rien apporté")
    }

    suite.add("CLI FortiGate : réponses de ssh") {
        let host = "10.0.0.1"
        guard case .failure(let denied) = FortiCLISSH.interpret(status: 255, stdout: "", stderr: "Permission denied (publickey).", timedOut: false, host: host) else {
            throw TestFailure(message: "refus attendu", file: #fileID, line: #line)
        }
        try expectEqual(denied.kind, .authentication, "authentification")
        guard case .failure(let rejected) = FortiCLISSH.interpret(status: 0, stdout: "Unknown action 0\nCommand fail. Return code -1\n", stderr: "", timedOut: false, host: host) else {
            throw TestFailure(message: "commande refusée attendue", file: #fileID, line: #line)
        }
        try expectEqual(rejected.kind, .commandRejected, "droits insuffisants")
        guard case .failure(let cut) = FortiCLISSH.interpret(status: 0, stdout: "10.0.0.1 aa:bb:cc:dd:ee:ff\n", stderr: "", timedOut: true, host: host) else {
            throw TestFailure(message: "liste coupée refusée", file: #fileID, line: #line)
        }
        try expectEqual(cut.kind, .timeout, "sortie partielle : délai")
        let refusal = ConfigBackupError(kind: .commandRejected, detail: "refus")
        guard case .success(let half) = FortiCLI.merge(leases: .success("10.182.122.116 04:c1:03:ba:90:fa\n"), arp: .failure(refusal)) else {
            throw TestFailure(message: "baux gardés", file: #fileID, line: #line)
        }
        try expectEqual(half.leases.count, 1, "baux gardés quand ARP est refusé")
        try expectEqual(half.partialError?.kind, .commandRejected, "refus conservé")
        guard case .failure = FortiCLI.merge(leases: .failure(refusal), arp: .failure(refusal)) else {
            throw TestFailure(message: "deux refus : échec", file: #fileID, line: #line)
        }
        guard case .success(let empty) = FortiCLISSH.interpret(status: 0, stdout: "", stderr: "", timedOut: false, host: host) else {
            throw TestFailure(message: "sortie vide acceptée", file: #fileID, line: #line)
        }
        try expect(empty.isEmpty, "liste vide valable")
    }
}
