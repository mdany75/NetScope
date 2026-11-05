import Foundation
import NetScopeCore

// Note 78 (0.26.0) : Wake-on-LAN vers plusieurs postes, broadcast dirigé vers un autre
// sous-réseau et suivi par ping « réveillé en N s ». Aucun paquet n'est envoyé.

func registerWakePlanTests(_ suite: TestSuite) {
    let local = Subnet(address: IPv4Address("10.182.122.0")!, prefix: 24)
    let dell = MACAddress("B0:7B:25:44:A1:6C")!
    let backup = MACAddress("00:50:56:AA:10:31")!
    let unknown = MACAddress("B0:7B:25:44:9F:20")!

    suite.add("Wake-on-LAN : broadcast local ou dirigé selon le sous-réseau du poste") {
        let targets = [WakeTarget(mac: dell, ip: IPv4Address("10.182.122.117"), name: "WKS346"),
                       WakeTarget(mac: backup, ip: IPv4Address("10.10.0.31"), name: "SRV-BACKUP"),
                       WakeTarget(mac: unknown, ip: nil, name: "Manuel"),
                       WakeTarget(mac: dell, ip: IPv4Address("10.182.122.117"), name: "doublon")]
        let plan = WakeOnLAN.plan(targets, mode: .automatic, local: local)
        try expectEqual(plan.count, 3, "doublon de MAC retiré")
        try expectEqual(plan[0].kind, .local, "même sous-réseau : broadcast local")
        try expectEqual(plan[0].broadcast, IPv4Address("10.182.122.255")!, "broadcast local")
        try expectEqual(plan[1].kind, .directed, "autre sous-réseau : broadcast dirigé")
        try expectEqual(plan[1].broadcast, IPv4Address("10.10.0.255")!, "/24 supposé")
        try expectEqual(plan[1].label, "broadcast dirigé 10.10.0.255 (10.10.0.0/24)", "libellé")
        try expectEqual(plan[2].kind, .local, "adresse inconnue : réseau local")

        let known = [Subnet(address: IPv4Address("10.10.0.0")!, prefix: 16), Subnet(address: IPv4Address("10.10.0.0")!, prefix: 23)]
        let precise = WakeOnLAN.plan([targets[1]], mode: .automatic, local: local, knownSubnets: known)
        try expectEqual(precise[0].broadcast, IPv4Address("10.10.1.255")!, "le sous-réseau connu le plus précis (/23)")

        let manual = WakeOnLAN.plan(targets, mode: .manual, local: local, manual: IPv4Address("10.182.122.127"))
        try expect(manual.allSatisfy { $0.kind == .manual && $0.broadcast == IPv4Address("10.182.122.127")! }, "adresse saisie pour tous")
        let noInterface = WakeOnLAN.plan([targets[0]], mode: .automatic, local: nil)
        try expectEqual(noInterface[0].broadcast, IPv4Address(255, 255, 255, 255), "sans interface : diffusion générale")
        try expectEqual(WakeOnLAN.directedBroadcast(for: IPv4Address("192.168.50.21")!, prefix: 26), IPv4Address("192.168.50.63")!, "/26")
        try expectEqual(WakeOnLAN.directedBroadcast(for: IPv4Address("192.168.50.21")!, prefix: 40), IPv4Address("192.168.50.23")!,
                        "préfixe borné à /30")
    }

    suite.add("Wake-on-LAN : suivi par ping « réveillé en N s »") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var followUp = WakeFollowUp(start: start)
        try expectEqual(followUp.label, "attente du premier écho…", "en attente")
        try expectEqual(followUp.record(reply: false, at: start.addingTimeInterval(2)), .waiting, "pas encore de réponse")
        try expectEqual(followUp.record(reply: true, at: start.addingTimeInterval(17.6)), .awake(seconds: 18), "réveillé")
        try expectEqual(followUp.label, "réveillé en 18\u{00A0}s", "libellé")
        try expectEqual(followUp.record(reply: false, at: start.addingTimeInterval(200)), .awake(seconds: 18), "état final gardé")
        try expectEqual(followUp.probes, 2, "deux essais comptés")

        var silent = WakeFollowUp(start: start, timeout: 60)
        try expectEqual(silent.record(reply: false, at: start.addingTimeInterval(30)), .waiting, "délai pas atteint")
        try expectEqual(silent.record(reply: false, at: start.addingTimeInterval(60)), .noReply, "délai atteint")
        try expect(silent.label.hasPrefix("aucune réponse au ping après"), "libellé sans réponse")
        var expired = WakeFollowUp(start: start, timeout: 60)
        try expectEqual(expired.expire(at: start.addingTimeInterval(59)), .waiting, "pas encore expiré")
        try expectEqual(expired.expire(at: start.addingTimeInterval(61)), .noReply, "expiré")
        try expectEqual(WakeOnLAN.magicPacket(for: dell).count, WakeOnLAN.packetLength, "paquet magique de 102 octets")
    }
}
