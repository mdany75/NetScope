import Foundation
import NetScopeCore

// Tests du test MTU (notes 78 et 79) : dichotomie avec une sonde simulée (aucun paquet envoyé),
// diagnostic, lecture des messages ICMP et de la sortie de /sbin/ping, historique.

/// Chemin simulé : `mtu` du chemin, MTU de l'interface locale, messages « fragmentation
/// nécessaire » envoyés ou non (trou noir), pertes au hasard reproductibles.
private final class SimulatedPath: @unchecked Sendable {
    let mtu: Int
    let interfaceMTU: Int
    let sendsICMP: Bool
    let reachable: Bool
    /// Tailles dont le premier envoi est perdu (perte isolée).
    var dropOnce: Set<Int>
    private(set) var sent: [Int] = []
    private let lock = NSLock()

    init(mtu: Int, interfaceMTU: Int = 1500, sendsICMP: Bool = true, reachable: Bool = true, dropOnce: Set<Int> = []) {
        self.mtu = mtu
        self.interfaceMTU = interfaceMTU
        self.sendsICMP = sendsICMP
        self.reachable = reachable
        self.dropOnce = dropOnce
    }

    func probe(_ size: Int) -> PathMTUOutcome {
        lock.lock()
        defer { lock.unlock() }
        sent.append(size)
        if size > interfaceMTU { return .tooBig(reportedMTU: nil, from: nil, local: true) }
        guard reachable else { return .lost }
        if dropOnce.remove(size) != nil { return .lost }
        if size <= mtu { return .reply(rttMs: 10 + Double(size) / 1000) }
        return sendsICMP ? .tooBig(reportedMTU: mtu, from: IPv4Address(100, 64, 0, 1), local: false) : .lost
    }
}

private func search(_ path: SimulatedPath, maxSize: Int = 1500) async -> PathMTUResult {
    await PathMTUSearch.run(options: PathMTUOptions(maxSize: maxSize, attempts: 2, timeout: 1, interfaceMTU: path.interfaceMTU)) { size in
        path.probe(size)
    }
}

func registerPathMTUTests(_ suite: TestSuite) {
    suite.add("Test MTU : chemin Ethernet standard en deux sondes") {
        let path = SimulatedPath(mtu: 1500)
        let result = await search(path)
        try expectEqual(result.status, .found, "MTU trouvé")
        try expectEqual(result.mtu, 1500, "MTU 1500")
        try expectEqual(path.sent, [84, 1500], "écho de 84 octets, puis 1500 tout de suite")
        try expectEqual(result.diagnosis?.kind, .standard, "Ethernet standard")
        try expectEqual(result.recommendedMSS, 1460, "MSS 1460")
        try expect(!result.isBlackHole, "pas de trou noir")
    }

    suite.add("Test MTU : PPPoE avec « fragmentation nécessaire » (MTU annoncé vérifié directement)") {
        let path = SimulatedPath(mtu: 1492)
        let result = await search(path)
        try expectEqual(result.mtu, 1492, "MTU 1492")
        try expectEqual(path.sent, [84, 1500, 1492], "le MTU annoncé par le routeur est essayé, et il suffit")
        try expectEqual(result.diagnosis?.kind, .pppoe, "PPPoE probable")
        try expectEqual(result.fragmentationMessages, 1, "un message ICMP 3/4")
        try expectEqual(result.limitingRouter, IPv4Address(100, 64, 0, 1), "routeur qui limite")
        try expectEqual(result.steps.last?.high, 1493, "1493 refusé par déduction")
        try expectEqual(result.steps.map(\.payload), [56, 1472, 1464], "données ICMP = taille − 28")
    }

    suite.add("Test MTU : trou noir (aucun message ICMP), dichotomie exacte") {
        for mtu in [1400, 1436, 1420, 1476, 1280, 1499, 576] {
            let path = SimulatedPath(mtu: mtu, sendsICMP: false)
            let result = await search(path)
            try expectEqual(result.mtu, mtu, "MTU \(mtu) retrouvé par dichotomie")
            try expect(result.isBlackHole, "trou noir signalé pour \(mtu)")
            let distinctSizes = Set(path.sent).count
            try expect(distinctSizes <= 13, "au plus 13 tailles pour 1500 (\(distinctSizes) pour \(mtu))")
            // Chaque taille perdue est retentée une fois avant d'être jugée trop grande.
            try expect(result.steps.allSatisfy { $0.outcome != .lost || $0.attempts == 2 }, "pertes retentées")
        }
    }

    suite.add("Test MTU : une perte isolée ne fausse pas le résultat") {
        let path = SimulatedPath(mtu: 1500, dropOnce: [1500])
        let result = await search(path)
        try expectEqual(result.mtu, 1500, "la deuxième sonde de 1500 passe")
        try expectEqual(result.steps.count, 2, "deux étapes")
        try expectEqual(result.steps[1].attempts, 2, "deux envois à 1500")
        try expectEqual(result.probesSent, 3, "trois sondes en tout")
    }

    suite.add("Test MTU : trames jumbo, interface locale à 1500 et cible injoignable") {
        let jumbo = SimulatedPath(mtu: 9000, interfaceMTU: 9000)
        let jumboResult = await search(jumbo, maxSize: PathMTUOptions.jumboSize)
        try expectEqual(jumboResult.mtu, 9000, "jumbo de bout en bout")
        try expectEqual(jumboResult.diagnosis?.kind, .jumbo, "diagnostic jumbo")

        // Interface de ce Mac à 1500 : le système refuse 9000 (EMSGSIZE), le MTU de l'interface sert d'indice.
        let local = SimulatedPath(mtu: 9000, interfaceMTU: 1500)
        let localResult = await search(local, maxSize: PathMTUOptions.jumboSize)
        try expectEqual(localResult.mtu, 1500, "limité par l'interface")
        try expect(localResult.localLimit, "limite locale signalée")
        try expectEqual(local.sent, [84, 9000, 1500], "9000 refusé, 1500 essayé aussitôt")

        let partial = SimulatedPath(mtu: 4000, interfaceMTU: 9000, sendsICMP: false)
        let partialResult = await search(partial, maxSize: PathMTUOptions.jumboSize)
        try expectEqual(partialResult.mtu, 4000, "jumbo partiel retrouvé")
        try expectEqual(partialResult.diagnosis?.kind, .jumboPartial, "jumbo partiel")

        let dead = SimulatedPath(mtu: 1500, reachable: false)
        let deadResult = await search(dead)
        if case .unreachable = deadResult.status {} else { try expect(false, "injoignable attendu : \(deadResult.status)") }
        try expectEqual(deadResult.mtu, nil, "pas de MTU")
        try expectEqual(dead.sent, [84, 84], "deux échos de 84 octets seulement")
    }

    suite.add("Test MTU : diagnostic des valeurs courantes") {
        let expected: [(Int, PathMTUDiagnosis.Kind)] = [
            (9000, .jumbo), (9216, .jumbo), (4470, .jumboPartial), (1500, .standard), (1492, .pppoe), (1480, .ipInIP),
            (1476, .gre), (1460, .dsLite), (1450, .vxlan), (1420, .wireguard), (1438, .ipsec), (1400, .ipsec),
            (1360, .ipsec), (1488, .reduced), (1300, .reduced), (1200, .veryLow),
        ]
        for (mtu, kind) in expected {
            try expectEqual(PathMTUDiagnosis(mtu: mtu).kind, kind, "diagnostic de \(mtu)")
        }
        try expectEqual(PathMTUDiagnosis(mtu: 1492).overhead, 8, "8 octets de PPPoE")
        try expect(PathMTUDiagnosis(mtu: 1400).explanation.contains("IPsec"), "explication IPsec")
        try expectEqual(PathMTUDiagnosis(mtu: 1500).severity, .normal, "1500 normal")
        try expectEqual(PathMTUDiagnosis(mtu: 1492).severity, .reduced, "1492 réduit")
        try expectEqual(PathMTUDiagnosis(mtu: 1100).severity, .problem, "1100 anormal")
    }

    suite.add("Test MTU : lecture du « fragmentation nécessaire » (MTU du saut suivant)") {
        // ICMP 3/4 précédé d'un en-tête IP de 20 octets, MTU 1480 en octets 6-7.
        var packet = [UInt8](repeating: 0, count: 20 + 8)
        packet[0] = 0x45
        packet[20] = 3
        packet[21] = 4
        packet[26] = 0x05
        packet[27] = 0xC8
        try expectEqual(PathMTUICMP.nextHopMTU(packet), 1480, "MTU 1480 lu")
        try expectEqual(PathMTUICMP.nextHopMTU(Array(packet[20...])), 1480, "sans en-tête IP")
        var noValue = packet
        noValue[26] = 0
        noValue[27] = 0
        try expectEqual(PathMTUICMP.nextHopMTU(noValue), nil, "ancien routeur sans valeur (RFC 792)")
        var otherCode = packet
        otherCode[21] = 1
        try expectEqual(PathMTUICMP.nextHopMTU(otherCode), nil, "hôte inaccessible : pas un MTU")
    }

    suite.add("Test MTU : sortie de /sbin/ping -D -s (secours)") {
        let address = IPv4Address(1, 1, 1, 1)
        try expectEqual(PathMTUPingCommand.arguments(size: 1500, destination: address, timeout: 1.5),
                        ["-D", "-n", "-c", "1", "-W", "1500", "-s", "1472", "1.1.1.1"], "arguments")
        let ok = """
        PING 1.1.1.1 (1.1.1.1): 1464 data bytes
        1472 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.418 ms

        --- 1.1.1.1 ping statistics ---
        1 packets transmitted, 1 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 12.418/12.418/12.418/0.000 ms
        """
        try expectEqual(PathMTUPingCommand.parse(ok), .reply(rttMs: 12.418), "écho reçu")
        let local = "PING 1.1.1.1 (1.1.1.1): 8972 data bytes\nping: sendto: Message too long\n\n--- 1.1.1.1 ping statistics ---\n1 packets transmitted, 0 packets received, 100.0% packet loss\n"
        try expectEqual(PathMTUPingCommand.parse(local), .tooBig(reportedMTU: nil, from: nil, local: true), "refusé par l'interface")
        let frag = "PING 1.1.1.1 (1.1.1.1): 1472 data bytes\n36 bytes from 100.64.0.1: frag needed and DF set (MTU 1492)\nVr HL TOS  Len   ID Flg  off TTL Pro  cks      Src      Dst\n"
        try expectEqual(PathMTUPingCommand.parse(frag), .tooBig(reportedMTU: 1492, from: IPv4Address(100, 64, 0, 1), local: false),
                        "fragmentation nécessaire avec MTU")
        let lost = "PING 1.1.1.1 (1.1.1.1): 1472 data bytes\n\n--- 1.1.1.1 ping statistics ---\n1 packets transmitted, 0 packets received, 100.0% packet loss\n"
        try expectEqual(PathMTUPingCommand.parse(lost), .lost, "aucune réponse")
        try expectEqual(PathMTUPingCommand.parse("92 bytes from 10.0.0.1: Destination Host Unreachable\n"), .unreachable(code: 1, from: nil),
                        "hôte inaccessible")
    }

    suite.add("Test MTU : historique borné, mesure précédente et CSV") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var list: [PathMTUMeasurement] = []
        for index in 0..<60 {
            let item = PathMTUMeasurement(date: start.addingTimeInterval(Double(index) * 60), target: "1.1.1.1", address: "1.1.1.1",
                                          mtu: index == 59 ? 1500 : 1492, maxTested: 1500, kind: index == 59 ? .standard : .pppoe,
                                          probes: 3, blackHole: false, method: .socket)
            list = PathMTUHistory.inserting(item, into: list)
        }
        try expectEqual(list.count, PathMTUHistory.capacity, "50 mesures au plus")
        try expectEqual(list.first?.mtu, 1500, "la plus récente d'abord")
        try expectEqual(PathMTUHistory.previous(of: list[0], in: list)?.mtu, 1492, "mesure précédente vers la même adresse")
        try expectEqual(list[0].sentence, "MTU du chemin = 1500\u{00A0}octets vers 1.1.1.1", "phrase du résultat")
        let csv = PathMTUHistory.csv(Array(list.prefix(2)))
        try expect(csv.hasPrefix("date;cible;adresse;mtu;diagnostic"), "en-tête CSV")
        try expect(csv.contains(";1.1.1.1;1.1.1.1;1500;Ethernet standard;3;non;ICMP DF"), "ligne CSV : \(csv)")

        let path = SimulatedPath(mtu: 1492)
        let result = await search(path)
        let measurement = PathMTUMeasurement(result: result, target: "one.one.one.one", address: IPv4Address(1, 1, 1, 1), method: .socket)
        try expectEqual(measurement.kind, .pppoe, "diagnostic gardé")
        try expectEqual(measurement.probes, 3, "sondes gardées")
        try expectEqual(measurement.sentence, "MTU du chemin = 1492\u{00A0}octets vers one.one.one.one (1.1.1.1)", "nom et adresse")
        let data = try JSONEncoder().encode(measurement)
        try expectEqual(try JSONDecoder().decode(PathMTUMeasurement.self, from: data), measurement, "aller-retour JSON")
    }

    suite.add("Test MTU : sonde réelle vers 127.0.0.1 (boucle locale, MTU 16 384)") {
        let prober: PathMTUProber
        do {
            prober = try PathMTUProber(destination: IPv4Address(127, 0, 0, 1), timeout: 1)
        } catch {
            throw TestSkipped(reason: "socket ICMP ou bit DF refusés (\(error.localizedDescription))")
        }
        let result = await PathMTUSearch.run(options: PathMTUOptions(maxSize: PathMTUOptions.jumboSize, attempts: 2, timeout: 1)) { size in
            await prober.probeAsync(size: size)
        }
        try expectEqual(result.status, .found, "mesure aboutie")
        try expectEqual(result.mtu, 9000, "9000 octets passent sur la boucle locale")
        try expectEqual(result.steps.count, 2, "deux étapes")
        try expect(PathMTULocal.interfaceMTU("lo0") ?? 0 >= 9000, "MTU de lo0 lu par getifaddrs")
    }
}
