import Foundation
import NetScopeCore

// Tests du module Ping : statistiques sur des séries fixes, paquets ICMP synthétiques,
// et seuls accès réseau : ping et traceroute vers 127.0.0.1.

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.0001) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Paquet tel que reçu sur macOS : en-tête IPv4 de 20 octets, puis le message ICMP.
private func ipPacket(source: IPv4Address, destination: IPv4Address, payload: [UInt8]) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 20)
    header[0] = 0x45
    header[9] = 1
    let s = source.octets, d = destination.octets
    header[12] = s.0; header[13] = s.1; header[14] = s.2; header[15] = s.3
    header[16] = d.0; header[17] = d.1; header[18] = d.2; header[19] = d.3
    return header + payload
}

func registerPingTests(_ suite: TestSuite) {
    suite.add("Ping : statistiques (min, moy, max, jitter, perte, P95)") {
        let stats = PingStatistics(values: [10, 12, nil, 11, 15])
        try expectEqual(stats.sent, 5, "envoyés")
        try expectEqual(stats.received, 4, "reçus")
        try expectEqual(stats.lost, 1, "perdus")
        try expect(near(stats.lossPercent, 20), "perte 20 %")
        try expect(near(stats.min, 10) && near(stats.max, 15) && near(stats.average, 12), "min/max/moy")
        // Écarts entre réponses consécutives : 2, 1, 4 → 7/3.
        try expect(near(stats.jitter, 7.0 / 3.0), "jitter = \(String(describing: stats.jitter))")
        try expect(near(stats.p95, 12), "P95 (rang inférieur) = \(String(describing: stats.p95))")
        try expect(near(stats.standardDeviation, 3.5.squareRoot()), "écart-type")

        let hundred = PingStatistics(values: (1...100).map { Double($0) })
        try expect(near(hundred.p95, 95), "P95 de 1…100 = 95")
        try expect(near(hundred.jitter, 1), "jitter d'une rampe = 1")
        try expect(near(hundred.lossPercent, 0), "aucune perte")

        let constant = PingStatistics(values: [5, 5, 5, 5])
        try expect(near(constant.jitter, 0) && near(constant.standardDeviation, 0), "série constante")

        let allLost = PingStatistics(values: [nil, nil, nil])
        try expect(allLost.average == nil && allLost.p95 == nil, "tout perdu : pas de moyenne")
        try expect(near(allLost.lossPercent, 100), "tout perdu : 100 %")
        try expect(near(PingStatistics.empty.lossPercent, 0), "série vide : 0 %")
        try expect(near(PingStatistics(values: [7]).jitter, 0), "une seule mesure : jitter 0")
    }

    suite.add("Ping : historique borné, pertes consécutives, état") {
        var history = PingHistory(capacity: 600)
        try expectEqual(PingTargetStatus.of(history), .attente, "vide : en attente")
        let start = Date()
        for index in 1...700 {
            history.append(PingSample(sequence: index, date: start, rttMs: Double(index % 7) + 1))
        }
        try expectEqual(history.samples.count, 600, "borné à 600")
        try expectEqual(history.samples.first?.sequence, 101, "les plus anciennes sont retirées")
        try expectEqual(history.totalSent, 700, "compteur d'envoi cumulé")
        try expectEqual(PingTargetStatus.of(history), .enLigne, "en ligne")
        history.append(PingSample(sequence: 701, date: start, rttMs: nil))
        try expectEqual(history.consecutiveLosses, 1, "1 perte")
        try expectEqual(PingTargetStatus.of(history), .perte, "perte récente")
        try expectEqual(history.samples.last?.failure, .timeout, "raison par défaut : délai")
        history.append(PingSample(sequence: 702, date: start, rttMs: nil))
        history.append(PingSample(sequence: 703, date: start, rttMs: nil))
        try expectEqual(PingTargetStatus.of(history), .horsLigne, "3 pertes : hors ligne")
        try expectEqual(history.values(last: 3), [nil, nil, nil], "3 dernières valeurs")
        try expectEqual(history.totalReceived, 700, "reçus")
        history.append(PingSample(sequence: 704, date: start, rttMs: 2))
        try expectEqual(history.consecutiveLosses, 0, "remise à zéro des pertes")
        try expectEqual(history.statistics(last: 5).lost, 3, "pertes sur la fenêtre")
        history.reset()
        try expect(history.isEmpty && history.totalSent == 0, "réinitialisation")
    }

    suite.add("Ping : statistiques MTR par saut") {
        var hop = PingHopStats()
        for value in [10.0, nil, 14, 12] as [Double?] { hop.record(value) }
        try expectEqual(hop.sent, 4, "envoyés")
        try expectEqual(hop.lost, 1, "perdus")
        try expect(near(hop.lossPercent, 25), "perte 25 %")
        try expect(near(hop.average, 12) && near(hop.best, 10) && near(hop.worst, 14) && near(hop.last, 12), "moy/meilleur/pire/dernier")
        try expect(near(hop.standardDeviation, (8.0 / 3).squareRoot()), "écart-type")
    }

    suite.add("Ping : paquets ICMP (somme de contrôle, lecture des réponses)") {
        let packet = PingICMP.echoRequestPacket(identifier: 0xBEEF, sequence: 513, payloadSize: 56)
        try expectEqual(packet.count, 64, "8 + 56 octets")
        try expectEqual(packet[0], PingICMP.echoRequest, "type 8")
        try expectEqual(PingICMP.checksum(packet), 0, "somme de contrôle valide")
        try expectEqual(PingICMP.echoRequestPacket(identifier: 1, sequence: 1, payloadSize: 1472).count + 20, 1500, "test MTU : 1500 octets")
        // Exemple classique de la RFC 1071.
        try expectEqual(PingICMP.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]), ~UInt16(0xDDF2), "RFC 1071")

        var reply = packet
        reply[0] = PingICMP.echoReply
        let target = IPv4Address("8.8.8.8")!, me = IPv4Address("10.0.0.5")!, router = IPv4Address("10.0.0.1")!
        let parsedReply = PingICMP.parse(ipPacket(source: target, destination: me, payload: reply))
        try expectEqual(parsedReply?.message, .echoReply(identifier: 0xBEEF, sequence: 513), "Echo Reply")
        try expectEqual(parsedReply?.source, target, "source lue dans l'en-tête IP")
        try expectEqual(PingICMP.parse(reply)?.message, .echoReply(identifier: 0xBEEF, sequence: 513), "sans en-tête IP")
        try expect(PingICMP.parse(packet) == nil, "notre propre Echo Request est ignoré")

        let original = ipPacket(source: me, destination: target, payload: Array(packet.prefix(8)))
        let exceeded = [PingICMP.timeExceeded, 0, 0, 0, 0, 0, 0, 0] + original
        let parsedExceeded = PingICMP.parse(ipPacket(source: router, destination: me, payload: exceeded))
        try expectEqual(parsedExceeded?.message, .timeExceeded(identifier: 0xBEEF, sequence: 513, originalDestination: target), "Time Exceeded")
        try expectEqual(parsedExceeded?.source, router, "routeur intermédiaire")
        let unreachable = [PingICMP.destinationUnreachable, 4, 0, 0, 0, 0, 0x05, 0xC8] + original
        try expectEqual(PingICMP.parse(unreachable)?.message,
                        .unreachable(code: 4, identifier: 0xBEEF, sequence: 513, originalDestination: target), "fragmentation nécessaire")
        try expect(PingICMP.parse([0x45, 0, 0]) == nil, "paquet tronqué")
    }

    suite.add("Ping : journal (coupure, retour, perte isolée, latence élevée)") {
        let now = Date()
        let lost = PingSample(sequence: 10, date: now, rttMs: nil)
        try expect(PingEventDetector.events(for: lost, previousLosses: 0, interval: 1, thresholdMs: 20, subject: "a").isEmpty,
                   "une perte seule n'est signalée qu'au retour")
        let cut = PingEventDetector.events(for: lost, previousLosses: 2, interval: 1, thresholdMs: 20, subject: "a")
        try expectEqual(cut.map(\.level), [.coupure], "coupure à la 3e perte")
        try expect(cut.first?.message.contains("3 paquets perdus") == true, "message de coupure")
        try expect(PingEventDetector.events(for: lost, previousLosses: 5, interval: 1, thresholdMs: 20, subject: "a").isEmpty,
                   "pas de nouvelle coupure ensuite")
        let back = PingEventDetector.events(for: PingSample(sequence: 15, date: now, rttMs: 3), previousLosses: 4,
                                            interval: 1, thresholdMs: 20, subject: "a")
        try expectEqual(back.map(\.level), [.retabli], "retour en ligne")
        try expect(back.first?.message.contains("après 4") == true, "durée de la coupure : \(back.first?.message ?? "")")
        let single = PingEventDetector.events(for: PingSample(sequence: 54, date: now, rttMs: 3), previousLosses: 1,
                                              interval: 1, thresholdMs: 20, subject: "a")
        try expect(single.first?.message == "1 paquet perdu (seq 53)", "perte isolée : \(single.first?.message ?? "")")
        let slow = PingEventDetector.events(for: PingSample(sequence: 9, date: now, rttMs: 17.4), previousLosses: 0,
                                            interval: 1, thresholdMs: 15, subject: "a")
        try expectEqual(slow.map(\.level), [.alerte], "latence élevée")
        try expect(slow.first?.message.hasPrefix("latence élevée 17,4") == true, "valeur à la française : \(slow.first?.message ?? "")")
        let still = PingEventDetector.events(for: PingSample(sequence: 10, date: now, rttMs: 18), previousLosses: 0,
                                             interval: 1, thresholdMs: 15, subject: "a", previousAboveThreshold: true)
        try expect(still.isEmpty, "latence toujours élevée : pas de nouvelle alerte")
        try expectEqual(PingEventDetector.defaultThreshold(for: IPv4Address("10.0.0.1")), 20, "seuil local")
        try expectEqual(PingEventDetector.defaultThreshold(for: IPv4Address("1.1.1.1")), 50, "seuil Internet")
    }

    suite.add("Ping : rapport MTR (cycles synthétiques)") {
        let destination = IPv4Address("8.8.8.8")!
        let gateway = IPv4Address("10.0.0.1")!, isp = IPv4Address("100.64.0.1")!
        var report = PingMTRReport(destination: destination)
        // 1er cycle : 30 sondes, la destination répond à partir du TTL 3.
        var replies: [Int: PingHopReply] = [1: PingHopReply(address: gateway, rttMs: 1, reachedDestination: false),
                                            2: PingHopReply(address: isp, rttMs: 5, reachedDestination: false)]
        for ttl in 3...30 { replies[ttl] = PingHopReply(address: destination, rttMs: 12, reachedDestination: true) }
        report.record(PingTraceCycle(probed: 30, replies: replies))
        try expectEqual(report.destinationTTL, 3, "destination au 3e saut")
        try expectEqual(report.hops.count, 3, "3 sauts")
        try expectEqual(report.probeLimit, 3, "les cycles suivants s'arrêtent à 3")
        try expect(report.hops[2].isDestination && !report.hops[1].isDestination, "dernier saut = destination")
        // 2e cycle : le saut 2 ne répond pas.
        report.record(PingTraceCycle(probed: 3, replies: [1: PingHopReply(address: gateway, rttMs: 3, reachedDestination: false),
                                                          3: PingHopReply(address: destination, rttMs: 14, reachedDestination: true)]))
        try expectEqual(report.cycles, 2, "cycles")
        try expect(near(report.hops[1].stats.lossPercent, 50), "perte du saut 2")
        try expect(near(report.hops[0].stats.average, 2), "moyenne du saut 1")
        try expect(near(report.hops[2].stats.worst, 14), "pire de la destination")
        let text = report.text(hostnames: [destination: "dns.google"])
        try expect(text.contains("dns.google") && text.contains("100.64.0.1") && text.contains("(sans PTR)"), "rapport texte")

        // Destination jamais atteinte : on garde les sauts qui répondent.
        var filtered = PingMTRReport(destination: destination)
        filtered.record(PingTraceCycle(probed: 30, replies: [1: PingHopReply(address: gateway, rttMs: 1, reachedDestination: false)]))
        try expectEqual(filtered.hops.count, 1, "seulement le saut qui répond")
        try expect(filtered.destinationTTL == nil, "destination non atteinte")
    }

    suite.add("Ping : passerelle par défaut, mise en forme, résolution numérique") {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 10.182.122.1
          interface: en0
        """
        try expectEqual(PingResolver.parseGateway(routeOutput: output), IPv4Address("10.182.122.1"), "ligne gateway")
        try expect(PingResolver.parseGateway(routeOutput: "gateway: link#15") == nil, "route par lien")
        try expectEqual(PingFormat.decimal(17.44), "17,4", "virgule décimale")
        try expectEqual(PingFormat.ms(nil), "—", "valeur absente")
        try expectEqual(PingFormat.duration(0.2), "0,2\u{00A0}s", "0,2 s")
        try expectEqual(PingFormat.duration(4), "4\u{00A0}s", "4 s")
        try expectEqual(PingFormat.duration(120), "2\u{00A0}min", "2 min")
        try expectEqual(PingFormat.duration(90), "1,5\u{00A0}min", "1,5 min")
        try expectEqual(PingFormat.percent(0.83), "0,8\u{00A0}%", "pourcentage")
        try expectEqual(try PingResolver.resolve(" 127.0.0.1 "), IPv4Address(127, 0, 0, 1), "adresse littérale sans DNS")
        try expectEqual(PingOptions(interval: 0.2).effectiveTimeout, 1, "délai court")
        try expectEqual(PingOptions(interval: 5).effectiveTimeout, 2, "délai long")
    }

    suite.add("Ping : ping continu vers 127.0.0.1") {
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var samples: [PingSample] = []
            func add(_ sample: PingSample) { lock.lock(); samples.append(sample); lock.unlock() }
            var snapshot: [PingSample] { lock.lock(); defer { lock.unlock() }; return samples }
        }
        let collector = Collector()
        let monitor = PingMonitor(address: IPv4Address(127, 0, 0, 1), options: PingOptions(interval: 0.2)) { collector.add($0) }
        do {
            try monitor.start()
        } catch {
            throw TestSkipped(reason: "socket ICMP refusée (\(error.localizedDescription))")
        }
        let deadline = Date().addingTimeInterval(4)
        while collector.snapshot.count < 5, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        monitor.stop()
        let samples = collector.snapshot
        try expect(samples.count >= 5, "5 mesures en moins de 4 s (\(samples.count))")
        try expectEqual(samples.prefix(5).map(\.sequence), [1, 2, 3, 4, 5], "ordre des séquences")
        try expect(samples.allSatisfy { !$0.isLost }, "aucune perte sur la boucle locale")
        try expect(samples.allSatisfy { ($0.rttMs ?? 99) < 50 }, "latence locale < 50 ms")
        // Test MTU sur la boucle locale (MTU 16 384) : 1472 octets avec DF passent.
        let big = Collector()
        let mtu = PingMonitor(address: IPv4Address(127, 0, 0, 1),
                              options: PingOptions(interval: 0.2, payloadSize: 1472, dontFragment: true)) { big.add($0) }
        try mtu.start()
        let mtuDeadline = Date().addingTimeInterval(3)
        while big.snapshot.count < 2, Date() < mtuDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        mtu.stop()
        try expect(big.snapshot.count >= 2 && big.snapshot.allSatisfy { !$0.isLost }, "1472 octets reçus")
    }

    suite.add("Ping : traceroute vers 127.0.0.1 (1 saut)") {
        let tracer: PingTracer
        do {
            tracer = try PingTracer(destination: IPv4Address(127, 0, 0, 1), maxHops: 5, timeout: 1)
        } catch {
            throw TestSkipped(reason: "socket ICMP refusée (\(error.localizedDescription))")
        }
        let cycle = try tracer.runCycle()
        try expectEqual(cycle.destinationTTL, 1, "destination atteinte au 1er saut")
        try expectEqual(cycle.replies[1]?.address, IPv4Address(127, 0, 0, 1), "adresse du saut")
        var report = PingMTRReport(destination: IPv4Address(127, 0, 0, 1))
        report.record(cycle)
        report.record(try tracer.runCycle(limit: report.probeLimit))
        try expectEqual(report.hops.count, 1, "1 saut")
        try expectEqual(report.hops[0].stats.sent, 2, "2 cycles")
        try expect(near(report.hops[0].stats.lossPercent, 0), "aucune perte")
    }
}
