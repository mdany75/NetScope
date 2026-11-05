import Darwin
import Foundation
import NetScopeCore

// Note 78 : serveur et client iperf3 intégrés. Protocole sur données fixes, puis de vrais tests
// sur 127.0.0.1 seulement : client intégré ↔ serveur intégré, et un client « à la iperf3 » écrit
// octet par octet (mêmes messages, même JSON que iperf 3.17) pour vérifier la compatibilité.

func registerIperfServerTests(_ suite: TestSuite) {
    suite.add("iperf3 intégré : états, cookie, JSON encadré et numéros des flux") {
        try expectEqual(IperfState.paramExchange.byte, 9, "PARAM_EXCHANGE")
        try expectEqual(IperfState.createStreams.byte, 10, "CREATE_STREAMS")
        try expectEqual(IperfState.accessDenied.byte, 0xFF, "ACCESS_DENIED = -1")
        try expectEqual(IperfState.serverError.byte, 0xFE, "SERVER_ERROR = -2")
        try expectEqual(IperfState(byte: 16), .iperfDone, "IPERF_DONE relu")
        try expectEqual(IperfState(byte: 0x7F), nil, "état inconnu")
        let cookie = IperfProtocol.makeCookie()
        try expectEqual(cookie.count, 37, "cookie de 37 octets")
        try expectEqual(cookie.last, 0, "cookie terminé par NUL")
        try expect(cookie.dropLast().allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".utf8.contains($0) }, "alphabet d’iperf3")
        try expect(IperfProtocol.makeCookie() != cookie, "cookie aléatoire")
        let frame = try IperfProtocol.frame(["a": 1])
        try expectEqual(Array(frame.prefix(4)), [0, 0, 0, 7], "longueur big-endian")
        try expectEqual(String(decoding: frame.dropFirst(4), as: UTF8.self), #"{"a":1}"#, "JSON sans NUL")
        try expectEqual(try IperfProtocol.frameLength([0, 0, 1, 0]), 256, "longueur relue")
        try expectThrows(IperfProtocolError.malformed("longueur JSON invalide (0)"), "longueur nulle") {
            _ = try IperfProtocol.frameLength([0, 0, 0, 0])
        }
        try expectThrows(IperfProtocolError.malformed("longueur JSON invalide (2147483647)"), "longueur démesurée") {
            _ = try IperfProtocol.frameLength([0x7F, 0xFF, 0xFF, 0xFF])
        }
        try expectEqual(IperfProtocol.streamIDs(count: 1), [1], "un flux")
        try expectEqual(IperfProtocol.streamIDs(count: 4), [1, 3, 4, 5], "numérotation d’iperf_add_stream")
        try expectEqual(IperfProtocol.displayAddress("::ffff:10.10.0.20"), "10.10.0.20", "IPv4 dans IPv6")
        try expectEqual(IperfProtocol.displayAddress("fe80::1"), "fe80::1", "IPv6 gardée")
    }

    suite.add("iperf3 intégré : paramètres d’un vrai client, résultats et refus") {
        let real = #"{"tcp":true,"omit":0,"time":10,"num":0,"blockcount":0,"parallel":4,"reverse":true,"len":131072,"pacing_timer":1000,"client_version":"3.17.1"}"#
        let parsed = try IperfTestParameters.parse(Array(real.utf8))
        try expectEqual(parsed, IperfTestParameters(tcp: true, reverse: true, time: 10, parallel: 4, clientVersion: "3.17.1"), "paramètres relus")
        let udp = try IperfTestParameters.parse(Array(#"{"udp":1,"time":5,"parallel":1,"bandwidth":1048576,"len":1460}"#.utf8))
        try expect(udp.udp && !udp.tcp, "UDP en entier 1")
        try expectEqual(udp.blockSize, 1460, "taille des blocs")
        let config = IperfServerConfiguration(maxDuration: 60, maxStreams: 8)
        try expectEqual(config.refusal(for: udp)?.code, .unimplemented, "UDP refusé")
        try expectEqual(config.refusal(for: IperfTestParameters(bidirectional: true))?.code, .unimplemented, "bidirectionnel refusé")
        try expectEqual(config.refusal(for: IperfTestParameters(parallel: 9))?.code, .numStreams, "trop de flux")
        try expectEqual(config.refusal(for: IperfTestParameters(time: 61))?.code, .duration, "trop long")
        try expect(config.refusal(for: parsed) == nil || parsed.parallel > 8, "test normal accepté")
        try expect(config.refusal(for: IperfTestParameters(time: 10, parallel: 8)) == nil, "8 flux, 10 s accepté")
        try expectThrows(IperfProtocolError.malformed("paramètres du test"), "JSON illisible") {
            _ = try IperfTestParameters.parse(Array("pas du json".utf8))
        }

        let results = IperfExchangedResults(cpuTotal: 3.5, cpuUser: 1, cpuSystem: 2.5, senderHasRetransmits: -1, streams: [
            .init(id: 1, bytes: 1_000_000, endTime: 10), .init(id: 3, bytes: 500_000, endTime: 10.02),
        ])
        let data = try JSONSerialization.data(withJSONObject: results.json)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // Clés que get_results d'iperf3 exige (sinon « unable to receive results »).
        for key in ["cpu_util_total", "cpu_util_user", "cpu_util_system", "sender_has_retransmits", "streams"] {
            try expect(object[key] != nil, "clé \(key)")
        }
        let stream = (object["streams"] as? [[String: Any]])?.first ?? [:]
        for key in ["id", "bytes", "retransmits", "jitter", "errors", "packets", "start_time", "end_time"] {
            try expect(stream[key] != nil, "clé de flux \(key)")
        }
        let reread = try IperfExchangedResults.parse([UInt8](data))
        try expectEqual(reread, results, "résultats relus")
        try expectEqual(reread.totalBytes, 1_500_000, "total")
        try expect(abs(reread.duration - 10.02) < 1e-9, "durée")
        try expectThrows(IperfProtocolError.malformed("résultats sans sender_has_retransmits"), "clé manquante") {
            _ = try IperfExchangedResults.parse(Array(#"{"streams":[]}"#.utf8))
        }
        try expectEqual(IperfNativeClient.unsupportedReason(IperfOptions(host: "x", transport: .udp)) != nil, true, "UDP hors moteur intégré")
        try expectEqual(IperfNativeClient.unsupportedReason(IperfOptions(host: "x")), nil, "TCP normal pris en charge")
    }

    suite.add("iperf3 intégré : client NetScope ↔ serveur NetScope sur 127.0.0.1 (normal et -R)") {
        let events = IperfEventLog()
        let server = IperfServer(configuration: IperfServerConfiguration(port: 0, bindAddress: "127.0.0.1")) { events.add($0) }
        let port = try server.start()
        defer { server.stop() }
        try expect(port > 0, "port choisi")
        let intervals = IperfEventLog()
        let normal = try await IperfNativeClient.run(IperfOptions(host: "127.0.0.1", port: Int(port), duration: 2, streams: 2)) { interval in
            intervals.add(.interval(UUID(), interval))
        }
        try expect(!normal.reverse && normal.streams == 2, "deux flux, sens normal")
        try expect((normal.sentBytes ?? 0) > 0 && (normal.receivedBytes ?? 0) > 0, "octets envoyés et reçus")
        try expect(normal.megabitsPerSecond > 1, "débit mesuré (\(normal.megabitsPerSecond) Mb/s)")
        try expect(normal.intervals.count >= 2, "un intervalle par seconde (\(normal.intervals.count))")
        try expect(intervals.count >= 2, "intervalles remis en direct")
        let finished = try await events.waitFinished(count: 1)
        try expectEqual(finished[0].streams, 2, "flux vus par le serveur")
        try expectEqual(finished[0].reverse, false, "sens vu par le serveur")
        try expectEqual(finished[0].bytes, normal.receivedBytes ?? -1, "octets reçus = résultat du serveur")
        try expectEqual(finished[0].clientBytes, normal.sentBytes, "octets annoncés par le client")
        try expectEqual(finished[0].client, "127.0.0.1", "adresse du client")
        // Le serveur se libère dès la fin de l'échange (aucune attente de fil déjà arrêté).
        for _ in 0..<20 where server.isBusy { try await Task.sleep(nanoseconds: 50_000_000) }
        try expect(!server.isBusy, "serveur libre après le test")

        let reverse = try await IperfNativeClient.run(IperfOptions(host: "127.0.0.1", port: Int(port), duration: 1, streams: 1,
                                                                  direction: .reverse))
        try expect(reverse.reverse && (reverse.receivedBytes ?? 0) > 0, "sens inverse : ce Mac reçoit")
        let both = try await events.waitFinished(count: 2)
        try expect(both[1].reverse, "le serveur a envoyé")
        try expectEqual(both[1].bytes, reverse.sentBytes ?? -1, "octets envoyés par le serveur")
    }

    suite.add("iperf3 intégré : serveur occupé, client refusé (ACCESS_DENIED), arrêt du serveur") {
        let server = IperfServer(configuration: IperfServerConfiguration(port: 0, bindAddress: "127.0.0.1"))
        let port = try server.start()
        let first = Task { try await IperfNativeClient.run(IperfOptions(host: "127.0.0.1", port: Int(port), duration: 2, streams: 1)) }
        var waited = 0
        while !server.isBusy, waited < 50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        try expect(server.isBusy, "premier test en cours")
        do {
            _ = try await IperfNativeClient.run(IperfOptions(host: "127.0.0.1", port: Int(port), duration: 1, streams: 1))
            throw TestFailure(message: "deuxième client accepté", file: #fileID, line: #line)
        } catch let error as IperfProtocolError {
            try expectEqual(error, .accessDenied, "serveur occupé")
        }
        _ = try await first.value
        server.stop()
        do {
            _ = try await IperfNativeClient.run(IperfOptions(host: "127.0.0.1", port: Int(port), duration: 1, streams: 1), connectTimeout: 1)
            throw TestFailure(message: "serveur encore à l’écoute", file: #fileID, line: #line)
        } catch is IperfProtocolError {
        }
    }

    suite.add("iperf3 intégré : un client écrit comme iperf 3.17 (octet par octet) obtient ses résultats") {
        let server = IperfServer(configuration: IperfServerConfiguration(port: 0, bindAddress: "127.0.0.1"))
        let port = try server.start()
        defer { server.stop() }
        try await Task.detached {
            let cookie = Array("abcdefghijklmnopqrstuvwxyz2345672345".utf8) + [0]
            let control = try rawConnect(port)
            defer { close(control) }
            try rawSend(control, cookie)
            try expectEqual(try rawRead(control, 1), [9], "PARAM_EXCHANGE")
            let params = #"{"tcp":true,"omit":0,"time":1,"num":0,"blockcount":0,"parallel":2,"len":131072,"pacing_timer":1000,"client_version":"3.17.1"}"#
            try rawSend(control, jsonFrame(params))
            try expectEqual(try rawRead(control, 1), [10], "CREATE_STREAMS")
            let streams = try (0..<2).map { _ -> Int32 in
                let fd = try rawConnect(port)
                try rawSend(fd, cookie)
                return fd
            }
            defer { streams.forEach { close($0) } }
            try expectEqual(try rawRead(control, 2), [1, 2], "TEST_START puis TEST_RUNNING")
            let block = [UInt8](repeating: 0x5A, count: 65_536)
            var sent = 0
            let end = Date().addingTimeInterval(1)
            while Date() < end {
                for fd in streams { try rawSend(fd, block); sent += block.count }
            }
            try rawSend(control, [4])
            try expectEqual(try rawRead(control, 1), [13], "EXCHANGE_RESULTS")
            let ours = #"{"cpu_util_total":1.2,"cpu_util_user":0.4,"cpu_util_system":0.8,"sender_has_retransmits":1,"congestion_used":"cubic","streams":[{"id":1,"bytes":\#(sent / 2),"retransmits":0,"jitter":0,"errors":0,"omitted_errors":0,"packets":0,"omitted_packets":0,"start_time":0,"end_time":1.0},{"id":3,"bytes":\#(sent / 2),"retransmits":0,"jitter":0,"errors":0,"omitted_errors":0,"packets":0,"omitted_packets":0,"start_time":0,"end_time":1.0}]}"#
            try rawSend(control, jsonFrame(ours))
            let header = try rawRead(control, 4)
            let length = try IperfProtocol.frameLength(header)
            let theirs = try IperfExchangedResults.parse(try rawRead(control, length))
            try expectEqual(theirs.streams.map(\.id), [1, 3], "mêmes numéros de flux que le client")
            try expect(theirs.totalBytes > 0 && theirs.totalBytes <= Int64(sent), "octets reçus par le serveur")
            try expectEqual(theirs.senderHasRetransmits, -1, "le serveur n’émet pas")
            try expectEqual(try rawRead(control, 1), [14], "DISPLAY_RESULTS")
            try rawSend(control, [16])
        }.value
    }

    suite.add("iperf3 intégré : UDP refusé par SERVER_ERROR et code d’erreur iperf3") {
        let server = IperfServer(configuration: IperfServerConfiguration(port: 0, bindAddress: "127.0.0.1"))
        let port = try server.start()
        defer { server.stop() }
        try await Task.detached {
            let control = try rawConnect(port)
            defer { close(control) }
            try rawSend(control, IperfProtocol.makeCookie())
            try expectEqual(try rawRead(control, 1), [9], "PARAM_EXCHANGE")
            try rawSend(control, jsonFrame(#"{"udp":true,"time":5,"parallel":1,"len":1460,"bandwidth":1048576}"#))
            try expectEqual(try rawRead(control, 1), [0xFE], "SERVER_ERROR")
            try expectEqual(try rawRead(control, 8), [0, 0, 0, 13, 0, 0, 0, 0], "i_errno IEUNIMP puis errno 0")
        }.value
    }
}

/// Événements du serveur, lus par le test.
private final class IperfEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IperfServerEvent] = []

    func add(_ event: IperfServerEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    private var finished: [IperfServerTest] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { if case .testFinished(let test) = $0 { return test } else { return nil } }
    }

    func waitFinished(count: Int) async throws -> [IperfServerTest] {
        for _ in 0..<100 {
            let list = finished
            if list.count >= count { return list }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TestFailure(message: "le serveur n’a pas signalé la fin du test", file: #fileID, line: #line)
    }
}

private func jsonFrame(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    let length = UInt32(bytes.count)
    return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + bytes
}

private func rawConnect(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard ok == 0 else {
        close(fd)
        throw TestFailure(message: "connexion à 127.0.0.1:\(port) impossible", file: #fileID, line: #line)
    }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

private func rawSend(_ fd: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
        guard n > 0 else { throw TestFailure(message: "envoi impossible", file: #fileID, line: #line) }
        offset += n
    }
}

private func rawRead(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    var result = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = result.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: done), count - done, 0) }
        guard n > 0 else { throw TestFailure(message: "lecture impossible (\(done)/\(count) octets)", file: #fileID, line: #line) }
        done += n
    }
    return result
}
