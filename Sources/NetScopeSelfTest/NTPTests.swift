import Darwin
import Foundation
import NetScopeCore

// Note 115 : Test NTP. Calculs sur valeurs connues et faux serveur UDP sur 127.0.0.1 seulement.

private func stamp(_ seconds: UInt32, _ fraction: UInt32 = 0) -> NTPTimestamp {
    NTPTimestamp(raw: UInt64(seconds) << 32 | UInt64(fraction))
}

private func serverPacket(origin: NTPTimestamp, receive: NTPTimestamp, transmit: NTPTimestamp,
                          stratum: Int = 2, leap: Int = 0, reference: [UInt8] = [10, 0, 0, 1]) -> NTPPacket {
    var packet = NTPPacket()
    packet.mode = 4
    packet.leap = leap
    packet.stratum = stratum
    packet.poll = 6
    packet.precision = -20
    packet.rootDelay = 0x0000_8000
    packet.rootDispersion = 0x0001_0000
    packet.referenceID = reference
    packet.originTime = origin
    packet.receiveTime = receive
    packet.transmitTime = transmit
    return packet
}

private func sample(offset: Double = 0, roundTrip: Double = 0.01, stratum: Int = 2, leap: Int = 0, kiss: String? = nil) -> NTPSample {
    NTPSample(server: "ntp.exemple.ca", address: IPv4Address(127, 0, 0, 1), leap: leap, stratum: stratum, referenceID: kiss ?? "10.0.0.1",
              kissCode: kiss, serverTime: Date(timeIntervalSince1970: 1_800_000_000), offset: offset, roundTrip: roundTrip)
}

private func near(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-6) -> Bool { abs(actual - expected) <= tolerance }

private func udpLoopback() throws -> (fd: Int32, port: UInt16) {
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

/// Faux serveur : pour chaque requête reçue (numérotée), envoie les datagrammes rendus par `reply`.
private func serve(_ fd: Int32, requests: Int, _ reply: @escaping @Sendable (Int, NTPPacket) -> [[UInt8]]) {
    Thread.detachNewThread {
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        for index in 0..<requests {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0, let request = NTPPacket(bytes: Array(buffer[0..<count])) else { return }
            for datagram in reply(index, request) {
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, datagram, datagram.count, 0, $0, length) }
                }
            }
        }
    }
}

private func fast(port: UInt16, samples: Int = 4, timeout: TimeInterval = 0.3) -> NTPProbeOptions {
    NTPProbeOptions(port: port, timeout: timeout, samples: samples, interval: 0.01)
}

func registerNTPTests(_ suite: TestSuite) {
    suite.add("NTP : requête cliente v4, 48 octets, seul l’horodatage d’émission renseigné") {
        let bytes = NTPPacket.request(transmit: stamp(0xE000_0001, 0x8000_0000)).encoded()
        try expectEqual(bytes.count, 48, "taille")
        try expectEqual(bytes[0], 0x23, "LI 0, version 4, mode 3")
        try expect(bytes[1..<40].allSatisfy { $0 == 0 }, "aucune autre donnée envoyée")
        try expectEqual(Array(bytes[40..<48]), [0xE0, 0, 0, 1, 0x80, 0, 0, 0], "émission en gros-boutiste")
    }

    suite.add("NTP : un paquet encodé se relit à l’identique, champs signés compris") {
        let origin = stamp(100)
        let packet = serverPacket(origin: origin, receive: stamp(101), transmit: stamp(102), leap: 1)
        let decoded = try NTPPacket.reply(packet.encoded(), expectedOrigin: origin)
        try expectEqual(decoded, packet, "aller-retour")
        try expectEqual(decoded.precision, -20, "précision négative")
        let sent = NTPSample(server: "s", address: IPv4Address(127, 0, 0, 1), packet: decoded, sentAt: origin, receivedAt: stamp(103),
                             now: Date(timeIntervalSince1970: 1_800_000_000))
        try expect(near(sent.rootDelay, 0.5), "délai racine 16.16")
        try expect(near(sent.rootDispersion, 1), "dispersion racine 16.16")
        try expectEqual(sent.referenceID, "10.0.0.1", "référence IP en strate 2")
    }

    suite.add("NTP : décalage et délai sur valeurs connues") {
        // Serveur en avance de 10 s, 0,2 s de trajet aller et de retour, 1 s de traitement.
        let times = NTPTimes(t1: stamp(1000), t2: stamp(1010, 0x3333_3333), t3: stamp(1011, 0x3333_3333), t4: stamp(1001, 0x6666_6666))
        try expect(near(times.offset, 10), "décalage ((t2-t1)+(t3-t4))/2 : \(times.offset)")
        try expect(near(times.roundTrip, 0.4), "délai (t4-t1)-(t3-t2) : \(times.roundTrip)")
        let behind = NTPTimes(t1: stamp(1000), t2: stamp(995), t3: stamp(995), t4: stamp(1000))
        try expect(near(behind.offset, -5), "serveur en retard : décalage négatif")
    }

    suite.add("NTP : le changement d’ère de 2036 ne fausse ni le calcul ni la date") {
        let beforeRollover = stamp(0xFFFF_FFFF)
        let afterRollover = stamp(1)
        try expect(near(afterRollover.seconds(since: beforeRollover), 2), "écart à travers l’ère")
        try expect(near(beforeRollover.seconds(since: afterRollover), -2), "écart inverse")

        let era1Start = Date(timeIntervalSince1970: 2_085_978_496)
        try expectEqual(NTPTimestamp(date: era1Start).raw, 0, "7 février 2036 06:28:16 UTC : compteur à zéro")
        let inEra1 = era1Start.addingTimeInterval(3600)
        let encoded = NTPTimestamp(date: inEra1)
        try expect(near(encoded.date(near: inEra1.addingTimeInterval(120)).timeIntervalSince1970, inEra1.timeIntervalSince1970, 1e-3),
                   "relu dans l’ère 1 grâce à l’horloge locale")
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        try expect(near(NTPTimestamp(date: today).date(near: today).timeIntervalSince1970, 1_800_000_000, 1e-3), "ère 0")
    }

    suite.add("NTP : réponses forgées, tronquées ou d’un autre mode rejetées") {
        let origin = stamp(500, 0xABC)
        let good = serverPacket(origin: origin, receive: stamp(501), transmit: stamp(502))
        try expectThrows(NTPReplyError.originMismatch, "origine différente") {
            _ = try NTPPacket.reply(serverPacket(origin: stamp(500, 0xABD), receive: stamp(501), transmit: stamp(502)).encoded(), expectedOrigin: origin)
        }
        var symmetric = good
        symmetric.mode = 1
        try expectThrows(NTPReplyError.wrongMode(1), "mode symétrique") { _ = try NTPPacket.reply(symmetric.encoded(), expectedOrigin: origin) }
        try expectThrows(NTPReplyError.tooShort(47), "paquet tronqué") { _ = try NTPPacket.reply(Array(good.encoded().prefix(47)), expectedOrigin: origin) }
        var empty = good
        empty.transmitTime = stamp(0)
        try expectThrows(NTPReplyError.emptyTransmit, "émission nulle") { _ = try NTPPacket.reply(empty.encoded(), expectedOrigin: origin) }
        let refused = serverPacket(origin: origin, receive: stamp(0), transmit: stamp(0), stratum: 0, leap: 3, reference: Array("RATE".utf8))
        let kiss = try NTPPacket.reply(refused.encoded(), expectedOrigin: origin)
        try expectEqual(kiss.kissCode, "RATE", "un refus n’a pas d’heure, mais reste lisible")
    }

    suite.add("NTP : référence ASCII en strate 1, code Kiss seulement en strate 0") {
        let gps = serverPacket(origin: stamp(1), receive: stamp(2), transmit: stamp(3), stratum: 1, reference: [0x47, 0x50, 0x53, 0])
        try expectEqual(gps.referenceText, "GPS", "code de source primaire")
        try expectEqual(gps.kissCode, nil, "pas de Kiss en strate 1")
    }

    suite.add("NTP : verdict selon le décalage, aux bornes de 100 ms et 1 s") {
        try expectEqual(NTPVerdict.of(sample(offset: 0.0999)), .synchronized, "sous 100 ms")
        try expectEqual(NTPVerdict.of(sample(offset: -0.1)), .notableOffset, "100 ms, en retard aussi")
        try expectEqual(NTPVerdict.of(sample(offset: 1)), .notableOffset, "1 s inclus")
        try expectEqual(NTPVerdict.of(sample(offset: -1.001)), .largeOffset, "au-delà de 1 s")
    }

    suite.add("NTP : verdicts d’un serveur qui ne peut pas donner l’heure") {
        try expectEqual(NTPVerdict.of(nil), .silent, "muet")
        try expectEqual(NTPVerdict.of(sample(offset: 0.001, leap: 3)), .unsynchronized, "leap=3 passe avant le décalage")
        try expectEqual(NTPVerdict.of(sample(stratum: 16)), .unsynchronized, "strate 16")
        try expectEqual(NTPVerdict.of(sample(stratum: 0, leap: 3, kiss: "DENY")), .kissOfDeath(code: "DENY"), "refus")
        try expectEqual(NTPVerdict.of(sample(stratum: 0, leap: 3, kiss: "INIT")), .unsynchronized, "ntpd qui démarre n’est pas un refus")
        try expectEqual(NTPVerdict.of(sample(stratum: 0, leap: 3)), .unsynchronized, "strate 0 sans code : pas un refus")
        let silentSource = serverPacket(origin: stamp(0), receive: stamp(0), transmit: stamp(0), stratum: 0, leap: 3, reference: [0, 0, 0, 0])
        try expectEqual(silentSource.kissCode, nil, "référence nulle : aucun code")
    }

    suite.add("NTP : liste de serveurs (virgules, espaces, doublons, 8 au plus)") {
        let parsed = NTPProbe.parseServers(" a.exemple,b.exemple  c.exemple\nA.exemple;d.exemple ")
        try expectEqual(parsed.servers, ["a.exemple", "b.exemple", "c.exemple", "d.exemple"], "ordre conservé, doublon retiré")
        try expectEqual(parsed.ignored, 0, "rien d’écarté")
        let many = NTPProbe.parseServers((1...10).map { "10.0.0.\($0)" }.joined(separator: " "))
        try expectEqual(many.servers.count, 8, "8 au plus")
        try expectEqual(many.ignored, 2, "2 de trop signalés")
    }

    suite.add("NTP : mise en forme signée à la française") {
        try expectEqual(NTPFormat.offset(0.0123), "+12,3\u{00A0}ms", "millisecondes")
        try expectEqual(NTPFormat.offset(-1.482), "−1,482\u{00A0}s", "secondes")
        try expectEqual(NTPFormat.offset(8040), "+2\u{00A0}h 14\u{00A0}min", "heures")
    }

    suite.add("NTP : le serveur local répond, l’échantillon de plus faible délai est gardé") {
        let server = try udpLoopback()
        serve(server.fd, requests: 4) { index, request in
            // Délai annoncé 50 ms, sauf le 3e (10 ms), qui porte un décalage reconnaissable.
            let offset = index == 2 ? 0.5 : 0.25
            let received = Date().addingTimeInterval(offset + (index == 2 ? 0.005 : 0.025))
            let sent = received.addingTimeInterval(index == 2 ? -0.01 : -0.05)
            return [serverPacket(origin: request.transmitTime, receive: NTPTimestamp(date: received), transmit: NTPTimestamp(date: sent)).encoded()]
        }
        let result = await NTPProbe.query(server: "127.0.0.1", options: fast(port: server.port))
        try expectEqual(result.answered, 4, "quatre réponses")
        guard let best = result.sample else { throw TestFailure(message: "aucun échantillon", file: #fileID, line: #line) }
        try expect(near(best.offset, 0.5, 0.05), "décalage du meilleur échantillon : \(best.offset)")
        try expect(near(best.roundTrip, 0.01, 0.04), "délai du meilleur échantillon : \(best.roundTrip)")
        try expectEqual(result.verdict, .notableOffset, "verdict")
    }

    suite.add("NTP : une réponse forgée est écartée, la vraie qui suit est prise") {
        let server = try udpLoopback()
        serve(server.fd, requests: 1) { _, request in
            let now = NTPTimestamp(date: Date())
            let forged = serverPacket(origin: stamp(42), receive: now, transmit: now).encoded()
            return [forged, serverPacket(origin: request.transmitTime, receive: now, transmit: now).encoded()]
        }
        let result = await NTPProbe.query(server: "127.0.0.1", options: fast(port: server.port, samples: 1))
        try expectEqual(result.rejected, 1, "forgée comptée")
        try expectEqual(result.answered, 1, "vraie réponse acceptée")
        try expectEqual(result.verdict, .synchronized, "verdict")
    }

    suite.add("NTP : un Kiss-o’-Death arrête la salve") {
        let server = try udpLoopback()
        serve(server.fd, requests: 1) { _, request in
            [serverPacket(origin: request.transmitTime, receive: stamp(0), transmit: stamp(0), stratum: 0, leap: 3, reference: Array("RATE".utf8)).encoded()]
        }
        let result = await NTPProbe.query(server: "127.0.0.1", options: fast(port: server.port))
        try expectEqual(result.sent, 1, "plus rien après le refus")
        try expectEqual(result.verdict, .kissOfDeath(code: "RATE"), "verdict")
    }

    suite.add("NTP : serveur muet, port fermé, et explication associée") {
        let silent = try udpLoopback()
        defer { close(silent.fd) }
        let quiet = await NTPProbe.query(server: "127.0.0.1", options: fast(port: silent.port, samples: 2, timeout: 0.05))
        try expectEqual(quiet.sent, 2, "tous les essais envoyés")
        try expectEqual(quiet.verdict, .silent, "muet")
        try expect(NTPFormat.explanation(quiet).contains("filtré"), "explication de l’absence de réponse")

        let closed = try udpLoopback()
        close(closed.fd)
        let refused = await NTPProbe.query(server: "127.0.0.1", options: fast(port: closed.port, timeout: 0.3))
        try expectEqual(refused.verdict, .silent, "port fermé")
        try expect(refused.failure?.contains("fermé") == true, "cause : \(refused.failure ?? "aucune")")
        try expectEqual(refused.sent, 1, "inutile d’insister sur un port fermé")
    }
}
