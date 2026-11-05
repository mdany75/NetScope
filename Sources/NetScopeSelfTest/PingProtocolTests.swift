import Darwin
import Foundation
import NetScopeCore

// Tests du ping TCP et HTTP et du traceroute TCP/UDP (note 65) : saisie des cibles, calcul des
// temps sur des dates fixes, sorties de /usr/sbin/traceroute fixes ; seul accès réseau : une
// connexion TCP vers un port d'écoute ouvert sur 127.0.0.1.

private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [PingSample] = []
    func add(_ sample: PingSample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }
    var snapshot: [PingSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Port d'écoute TCP sur 127.0.0.1 (port choisi par le système).
private func listenLocal() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: IPv4Address(127, 0, 0, 1).value.bigEndian)
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(fd, 16) == 0 else {
        close(fd)
        return nil
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

func registerPingProtocolTests(_ suite: TestSuite) {
    suite.add("Ping TCP/HTTP : saisie des cibles (préfixes, port, mode choisi)") {
        try expectEqual(PingTargetSpec.parse("10.0.0.5")?.kind, .icmp, "adresse seule : ICMP")
        try expectEqual(PingTargetSpec.parse("10.0.0.5", mode: .tcp, defaultPort: 3389)?.canonical, "tcp://10.0.0.5:3389", "mode TCP")
        let port = PingTargetSpec.parse("cam-quai:554")
        try expectEqual(port?.kind, .tcp(port: 554), "hôte:port → TCP")
        try expectEqual(port?.host, "cam-quai", "hôte")
        try expectEqual(PingTargetSpec.parse("tcp://nas.local:5000")?.kind, .tcp(port: 5000), "préfixe tcp://")
        try expectEqual(PingTargetSpec.parse("tcp://nas.local", defaultPort: 22)?.kind, .tcp(port: 22), "tcp:// sans port : port du mode")
        let https = PingTargetSpec.parse("https://portail.exemple.ca")
        try expectEqual(https?.canonical, "https://portail.exemple.ca/", "URL normalisée avec « / »")
        try expectEqual(https?.host, "portail.exemple.ca", "hôte de l'URL")
        try expectEqual(https?.kind.label, "HTTPS", "libellé HTTPS")
        try expectEqual(https?.kind.tcpPort, 443, "port 443")
        try expectEqual(PingTargetSpec.parse("http://10.0.0.9:8080/sante")?.kind.tcpPort, 8080, "port de l'URL")
        try expectEqual(PingTargetSpec.parse("intranet", mode: .http, defaultPort: 443)?.canonical, "https://intranet/", "mode HTTP")
        try expectEqual(PingTargetSpec.parse("intranet", mode: .http, defaultPort: 80)?.canonical, "http://intranet/", "mode HTTP port 80")
        try expectEqual(PingTargetSpec.parse("10.0.0.5:0"), nil, "port 0 refusé")
        try expectEqual(PingTargetSpec.parse("10.0.0.5:99999"), nil, "port hors limite refusé")
        try expectEqual(PingTargetSpec.parse("a b"), nil, "espace refusé")
        try expectEqual(PingTargetSpec.parse("https://"), nil, "URL sans hôte refusée")
        try expectEqual(PingTargetSpec.endpoint(kind: .tcp(port: 443), address: "10.0.0.5"), "10.0.0.5:443", "libellé TCP")
        try expectEqual(PingTargetSpec.endpoint(kind: .http(URL(string: "https://portail.exemple.ca/")!), address: "x"),
                        "portail.exemple.ca", "libellé HTTP sans schéma ni « / »")
        try expectEqual(PingTargetSpec.endpoint(kind: .http(URL(string: "https://site.ca/api/sante")!), address: "x"),
                        "site.ca/api/sante", "libellé HTTP avec chemin")
        try expectEqual(PingTraceProtocol.suggested(for: .tcp(port: 3389)), .tcp(port: 3389), "traceroute TCP vers le port sondé")
        try expectEqual(PingTraceProtocol.suggested(for: https!.kind), .tcp(port: 443), "traceroute TCP 443 pour HTTPS")
        try expectEqual(PingTraceProtocol.suggested(for: .icmp), .icmp, "ICMP par défaut")
    }

    suite.add("Ping TCP : temps de la poignée de main et classement des erreurs") {
        let ok = PingTCP.classify(connectErrno: EINPROGRESS, socketError: 0, timedOut: false, startMs: 1000, endMs: 1012.5)
        try expectEqual(ok.rttMs, 12.5, "SYN → SYN/ACK en 12,5 ms")
        try expectEqual(ok.failure, nil, "aucune perte")
        let instant = PingTCP.classify(connectErrno: 0, socketError: 0, timedOut: false, startMs: 5, endMs: 5.2)
        try expect(abs((instant.rttMs ?? 0) - 0.2) < 0.0001, "connexion immédiate (boucle locale)")
        let refused = PingTCP.classify(connectErrno: EINPROGRESS, socketError: ECONNREFUSED, timedOut: false, startMs: 0, endMs: 3)
        try expectEqual(refused.failure, .refused, "RST : port fermé")
        try expectEqual(refused.rttMs, nil, "un port fermé compte comme une perte")
        try expectEqual(refused.detail, "RST en 3,0\u{00A0}ms", "temps du RST gardé")
        try expectEqual(PingTCP.classify(connectErrno: EINPROGRESS, socketError: 0, timedOut: true, startMs: 0, endMs: 2000).failure,
                        .timeout, "rien dans le délai")
        try expectEqual(PingTCP.classify(connectErrno: EHOSTUNREACH, socketError: 0, timedOut: false, startMs: 0, endMs: 1).failure,
                        .unreachable(code: 1, from: nil), "hôte inaccessible")
        try expectEqual(PingFailure.refused.label, "port fermé (RST)", "libellé")
    }

    suite.add("Ping HTTP : découpage du temps (DNS, TCP, TLS, attente) et code") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ ms: Double) -> Date { t0.addingTimeInterval(ms / 1000) }
        let timing = PingHTTPTiming.from(fetchStart: at(0), dnsStart: at(1), dnsEnd: at(4), connectStart: at(4), connectEnd: at(40),
                                         tlsStart: at(16), tlsEnd: at(40), requestStart: at(41), responseStart: at(79))
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.01 } ?? false }
        try expect(near(timing.dnsMs, 3), "DNS 3 ms")
        try expect(near(timing.tcpMs, 12), "TCP 12 ms (jusqu'au début du TLS)")
        try expect(near(timing.tlsMs, 24), "TLS 24 ms")
        try expect(near(timing.waitMs, 38), "attente 38 ms")
        try expect(near(timing.totalMs, 79), "total 79 ms")
        try expectEqual(timing.summary, "DNS 3,0 · TCP 12,0 · TLS 24,0 · attente 38,0\u{00A0}ms", "résumé")
        // Connexion réutilisée ou HTTP en clair : pas de TLS, TCP = toute la connexion.
        let plain = PingHTTPTiming.from(fetchStart: at(0), dnsStart: nil, dnsEnd: nil, connectStart: at(0), connectEnd: at(2),
                                        tlsStart: nil, tlsEnd: nil, requestStart: at(2), responseStart: at(9))
        try expect(near(plain.tcpMs, 2) && plain.tlsMs == nil && near(plain.totalMs, 9), "HTTP en clair")
        try expectEqual(plain.summary, "TCP 2,0 · attente 7,0\u{00A0}ms", "résumé sans DNS ni TLS")

        let good = PingHTTP.result(status: 200, timing: timing, fallbackMs: 90)
        try expect(near(good.rttMs, 79) && good.statusCode == 200 && good.failure == nil, "200 : réponse comptée")
        let notFound = PingHTTP.result(status: 404, timing: PingHTTPTiming(), fallbackMs: 51)
        try expect(near(notFound.rttMs, 51) && notFound.statusCode == 404, "404 : le serveur répond (temps mesuré à défaut)")
        let error = PingHTTP.result(status: 503, timing: timing, fallbackMs: 90)
        try expectEqual(error.failure, .httpStatus(503), "503 : perte")
        try expectEqual(error.statusCode, 503, "code gardé")
        try expectEqual(PingHTTP.statusCode(fromStatusLine: "HTTP/1.1 301 Moved Permanently"), 301, "ligne d'état")
        try expectEqual(PingHTTP.statusCode(fromStatusLine: "HTTP/2 200"), 200, "HTTP/2")
        try expectEqual(PingHTTP.statusCode(fromStatusLine: "SSH-2.0-OpenSSH_9.6"), nil, "pas du HTTP")
    }

    suite.add("Traceroute TCP/UDP : arguments et lecture de la sortie de /usr/sbin/traceroute") {
        let destination = IPv4Address(8, 8, 8, 8)
        try expectEqual(PingTracerouteOutput.arguments(destination: destination, protocol: .tcp(port: 443), maxHops: 30),
                        ["-n", "-q", "1", "-w", "1", "-m", "30", "-P", "TCP", "-p", "443", "-e", "8.8.8.8"], "TCP : SYN vers 443, port fixe")
        try expectEqual(PingTracerouteOutput.arguments(destination: destination, protocol: .udp, maxHops: 12),
                        ["-n", "-q", "1", "-w", "1", "-m", "12", "-P", "UDP", "8.8.8.8"], "UDP : ports hauts")
        let output = """
        traceroute: Warning: Multiple interfaces found; using 10.182.122.135 @ en0
        traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 40 byte packets
         1  10.182.122.1  2.311 ms
         2  *
         3  100.64.0.1  5.204 ms
         4  154.11.12.37  7.9 ms  154.11.12.38  8.1 ms *
         5  dns.google (8.8.8.8)  13.402 ms
        """
        let hops = PingTracerouteOutput.parseHops(output)
        try expectEqual(hops.map(\.ttl), [1, 2, 3, 4, 5], "cinq sauts, en-tête et avertissement ignorés")
        try expectEqual(hops[1].replies, [], "saut muet")
        try expectEqual(hops[3].replies.map(\.address), [IPv4Address(154, 11, 12, 37), IPv4Address(154, 11, 12, 38)],
                        "deux routeurs au même TTL")
        try expectEqual(hops[4].replies.first?.address, destination, "nom et adresse entre parenthèses")
        let cycle = PingTracerouteOutput.cycle(output, destination: destination)
        try expectEqual(cycle.probed, 5, "5 TTL sondés")
        try expectEqual(cycle.destinationTTL, 5, "destination atteinte au 5e saut")
        try expectEqual(cycle.replies[2], nil, "pas de réponse au 2e saut")
        try expect(abs((cycle.replies[4]?.rttMs ?? 0) - 7.9) < 0.001, "première réponse gardée")
        var report = PingMTRReport(destination: destination)
        report.record(cycle)
        try expectEqual(report.hops.count, 5, "rapport MTR de 5 sauts")
        try expectEqual(report.probeLimit, 5, "les cycles suivants s'arrêtent à la destination")

        let filtered = " 1  10.0.0.1  1.0 ms\n 2  10.0.0.254  3.5 ms !Z\n 3  *\n"
        let filteredHops = PingTracerouteOutput.parseHops(filtered)
        try expectEqual(filteredHops[1].replies.first?.annotation, "!Z", "annotation lue")
        try expectEqual(PingTracerouteOutput.annotationLabel("!Z"), "interdit par l’administrateur (pare-feu)", "!Z expliqué")
        try expectEqual(PingTracerouteOutput.annotationLabel("!F-1480"), "fragmentation nécessaire (MTU 1480)", "!F expliqué")
        try expectEqual(PingTracerouteOutput.cycle(filtered, destination: destination).destinationTTL, nil, "destination non atteinte")

        let tracer = PingSystemTracer(destination: destination, protocol: .tcp(port: 443), maxHops: 30)
        try expectEqual(tracer.hopLimit(destinationTTL: nil), 30, "premier cycle : 30 sauts")
        try expectEqual(tracer.hopLimit(destinationTTL: 7), 7, "destination connue : 7 sauts")
    }

    suite.add("Ping TCP : connexion réelle à 127.0.0.1 (port ouvert, puis fermé)") {
        guard let (fd, port) = listenLocal() else { throw TestSkipped(reason: "écoute TCP locale impossible") }
        let open = PingTCP.probe(IPv4Address(127, 0, 0, 1), port: port, timeout: 1)
        try expect(open.rttMs != nil && (open.rttMs ?? 99) < 50, "port ouvert : temps mesuré (\(String(describing: open.rttMs)))")

        let collector = SampleCollector()
        let monitor = PingProbeMonitor.tcp(address: IPv4Address(127, 0, 0, 1), port: port,
                                           options: PingOptions(interval: 0.1)) { collector.add($0) }
        try monitor.start()
        let deadline = Date().addingTimeInterval(3)
        while collector.snapshot.count < 4, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        monitor.stop()
        let samples = collector.snapshot
        try expect(samples.count >= 4, "4 mesures TCP en moins de 3 s (\(samples.count))")
        try expectEqual(samples.prefix(4).map(\.sequence), [1, 2, 3, 4], "ordre des séquences")
        try expect(samples.allSatisfy { !$0.isLost }, "aucune perte")

        close(fd)
        let closed = PingTCP.probe(IPv4Address(127, 0, 0, 1), port: port, timeout: 1)
        try expectEqual(closed.failure, .refused, "port fermé : RST")
    }
}
