import Darwin
import Foundation
import NetScopeCore

// Tests des outils : aucun trafic hors de 127.0.0.1 (serveurs locaux ouverts par les tests).

func registerToolsTests(_ suite: TestSuite) {
    suite.add("Wake-on-LAN : paquet magique de 102 octets (6 × FF + 16 × MAC)") {
        let mac = MACAddress("B0:7B:25:4A:91:0E")!
        let packet = WakeOnLAN.magicPacket(for: mac)
        try expectEqual(packet.count, 102, "taille")
        try expect(packet.prefix(6).allSatisfy { $0 == 0xFF }, "6 × FF en tête")
        for index in 0..<16 {
            let start = 6 + index * 6
            try expectEqual(Array(packet[start..<(start + 6)]), [0xB0, 0x7B, 0x25, 0x4A, 0x91, 0x0E], "répétition \(index + 1)")
        }
        let iface = LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!, netmask: IPv4Address("255.255.255.0")!)
        try expectEqual(WakeOnLAN.defaultBroadcast(for: iface).description, "10.182.122.255", "broadcast de l’interface")
        try expectEqual(WakeOnLAN.defaultBroadcast(for: nil).description, "255.255.255.255", "broadcast par défaut")
    }

    suite.add("Wake-on-LAN : envoi UDP reçu sur 127.0.0.1") {
        let receiver = try LocalUDPServer()
        defer { receiver.stop() }
        let mac = MACAddress("94:dd:f8:18:15:7d")!
        let sent = try WakeOnLAN.send(to: mac, broadcast: IPv4Address(127, 0, 0, 1), ports: [receiver.port])
        try expectEqual(sent, 102, "octets envoyés")
        let received = try receiver.receive(timeout: 2)
        try expectEqual(received, WakeOnLAN.magicPacket(for: mac), "paquet reçu identique")
    }

    suite.add("DNS : encodage d’une requête") {
        let query = try DNSMessageCodec.query(name: "example.com", type: .mx, id: 0x1234)
        let expected: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
                                 7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 15, 0, 1]
        try expectEqual(query, expected, "octets de la requête")
        try expectEqual(DNSLookup.reverseName(for: IPv4Address("10.182.122.111")!), "111.122.182.10.in-addr.arpa", "nom inverse")
        try expectEqual(DNSLookup.queryName(for: "10.182.122.111", type: .ptr), "111.122.182.10.in-addr.arpa", "PTR d’une IP")
        try expectEqual(DNSLookup.queryName(for: "10.182.122.111", type: .a), "10.182.122.111", "A d’une IP inchangé")
        try expectThrows(DNSError.invalidName("exa mple.com"), "espace refusé") {
            _ = try DNSMessageCodec.query(name: "exa mple.com", type: .a, id: 1)
        }
        try expectEqual(DNSLookup.command(for: "10.182.122.111", type: .ptr, server: IPv4Address("10.182.122.1")),
                        "dig -x 10.182.122.111 @10.182.122.1", "commande équivalente")
    }

    suite.add("DNS : décodage d’une réponse fixe (compression, A, MX, TXT, AAAA, SOA)") {
        let message = try DNSMessageCodec.parse(DNSFixture.response)
        try expectEqual(message.id, 0x1234, "identifiant")
        try expect(message.isResponse && message.recursionAvailable && !message.isTruncated, "drapeaux")
        try expectEqual(message.rcodeLabel, "NOERROR", "code de réponse")
        try expectEqual(message.questions, ["example.com."], "question")
        try expectEqual(message.answers.count, 4, "nombre de réponses")
        let a = message.answers[0]
        try expectEqual(a.name, "example.com.", "nom par pointeur")
        try expectEqual(a.typeLabel, "A", "type A")
        try expectEqual(a.ttl, 300, "TTL")
        try expectEqual(a.value, "93.184.216.34", "adresse A")
        try expectEqual(message.answers[1].value, "10 mail.example.com.", "MX avec pointeur dans les données")
        try expectEqual(message.answers[2].value, "\"v=spf1 -all\" \"bonjour\"", "TXT à deux chaînes")
        try expectEqual(message.answers[3].value, "2001:db8::1", "AAAA compacte")
        try expectEqual(message.authority.count, 1, "autorité")
        try expectEqual(message.authority[0].value, "ns.example.com. admin.example.com. 2026110301 7200 3600 1209600 300", "SOA")
    }

    suite.add("DNS : réponses invalides refusées") {
        try expectThrows(DNSError.truncatedMessage, "en-tête trop court") { _ = try DNSMessageCodec.parse([0x12, 0x34, 0x81]) }
        var cut = DNSFixture.response
        cut.removeLast(10)
        try expectThrows(DNSError.truncatedMessage, "réponse coupée") { _ = try DNSMessageCodec.parse(cut) }
        // Pointeur qui se désigne lui-même (boucle infinie évitée).
        let loop: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        try expectThrows(DNSError.badPointer, "boucle de pointeurs") { _ = try DNSMessageCodec.parse(loop) }
        let nx = try DNSMessageCodec.parse([0, 9, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0])
        try expectEqual(nx.rcodeLabel, "NXDOMAIN", "NXDOMAIN")
        let dig = DNSLookup.parseDigAnswer("google.com.\t\t300\tIN\tMX\t10 smtp.google.com.\n;; commentaire\n")
        try expectEqual(dig, [DNSRecord(name: "google.com.", typeCode: 15, ttl: 300, value: "10 smtp.google.com.")], "sortie de dig")
    }

    suite.add("DNS : requête UDP vers un serveur local (127.0.0.1)") {
        let server = try LocalUDPServer()
        defer { server.stop() }
        server.replyOnce { query in
            // Réponse fixe, avec l'identifiant de la requête.
            var response = DNSFixture.response
            response[0] = query[0]
            response[1] = query[1]
            return response
        }
        let result = try await DNSLookup.resolve("example.com", type: .a, server: IPv4Address(127, 0, 0, 1),
                                                 port: server.port, timeout: 2)
        try expectEqual(result.rcode, "NOERROR", "code")
        try expectEqual(result.records.first?.value, "93.184.216.34", "première réponse")
        try expect(result.serverLabel.contains("127.0.0.1#\(server.port) (UDP)"), "serveur interrogé : \(result.serverLabel)")
        try expect(result.summary.hasPrefix("NOERROR · 4 réponses"), "résumé : \(result.summary)")
    }

    suite.add("Scan de ports : port local ouvert, port fermé, bannière") {
        let listener = try LocalTCPServer { fd in
            let banner = Array("SSH-2.0-NetScopeTest\r\n".utf8)
            _ = send(fd, banner, banner.count, 0)
        }
        defer { listener.stop() }
        let closedPort = try LocalTCPServer.unusedPort()
        let options = PortScanOptions(timeout: 2, concurrency: 4, grabBanners: true, bannerTimeout: 2,
                                      extraListenPorts: [listener.port])
        let summary = await PortScanner.scan(host: "127.0.0.1", ports: [listener.port, closedPort], options: options)
        try expectEqual(summary.scannedCount, 2, "ports sondés")
        let open = summary.results.first { $0.port == listener.port }
        try expectEqual(open?.state, .open, "port ouvert")
        try expectEqual(open?.banner, "SSH-2.0-NetScopeTest", "bannière lue")
        try expect((open?.rttMs ?? -1) >= 0, "délai mesuré")
        try expectEqual(summary.results.first { $0.port == closedPort }?.state, .closed, "port fermé (refusé)")
        try expect(summary.summary.hasPrefix("1 port ouvert"), "résumé : \(summary.summary)")
        let up = await PortScanner.isHostUp(host: "127.0.0.1", ports: [closedPort], timeout: 1)
        try expect(up, "hôte joignable (refus = présent)")
    }

    suite.add("HTTP : sonde d’un serveur local, titre et en-tête Server") {
        let server = try LocalTCPServer { fd in
            var request = [UInt8](repeating: 0, count: 2048)
            _ = recv(fd, &request, request.count, 0)
            let body = "<html><head><TITLE>\n  Brother  DCP-L2640DW &amp; co\n</TITLE></head><body>ok</body></html>"
            let response = "HTTP/1.1 200 OK\r\nServer: debut/1.30\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            let bytes = Array(response.utf8)
            _ = send(fd, bytes, bytes.count, 0)
        }
        defer { server.stop() }
        let result = try await HTTPProbe.probe(URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 4)
        try expectEqual(result.statusCode, 200, "code HTTP")
        try expectEqual(result.server, "debut/1.30", "serveur")
        try expectEqual(result.title, "Brother DCP-L2640DW & co", "titre")
        try expect(result.certificate == nil, "pas de certificat en HTTP")
        try expectEqual(HTTPProbe.extractTitle(from: "<html><body>sans titre</body></html>"), nil, "page sans titre")
        let raw = try HTTPProbe.parseRawResponse(Data("HTTP/1.0 301 Moved\r\nLocation: https://x/\r\n\r\n".utf8))
        try expectEqual(raw.status, 301, "réponse brute : code")
        try expectEqual(raw.headers["location"], "https://x/", "réponse brute : Location")
    }

    suite.add("Whois : champs clés d’une réponse ARIN et validation de la cible") {
        let raw = """
        # ARIN WHOIS data and services are subject to the Terms of Use
        NetRange:       8.8.8.0 - 8.8.8.255
        CIDR:           8.8.8.0/24
        NetName:        GOGL
        OriginAS:       AS15169
        Organization:   Google LLC (GOGL)
        RegDate:        2014-03-14
        Ref:            https://rdap.arin.net/registry/ip/8.8.8.0
        OrgName:        Google LLC
        Country:        US
        OrgAbuseEmail:  network-abuse@google.com
        """
        let fields = Whois.summarize(raw)
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        try expectEqual(map["Organisation"], "Google LLC", "organisation")
        try expectEqual(map["ASN"], "AS15169", "ASN")
        try expectEqual(map["Bloc"], "8.8.8.0/24", "bloc")
        try expectEqual(map["Pays"], "US", "pays")
        try expectEqual(map["Registre"], "ARIN", "registre")
        try expectEqual(map["Création"], "2014-03-14", "date")
        try expectEqual(try Whois.validate(" 8.8.8.8 "), "8.8.8.8", "cible nettoyée")
        for bad in ["-h evil", "a b", "", "x;rm"] {
            try expect((try? Whois.validate(bad)) == nil, "« \(bad) » refusée")
        }
    }

    suite.add("Convertisseur MAC/OUI : formats, fabricant et type d’adresse") {
        let info = try unwrap(MACVendorLookup.lookup("94dd.f818.157d"), "MAC Cisco acceptée")
        try expectEqual(info.formats.map(\.value), ["94:DD:F8:18:15:7D", "94-DD-F8-18-15-7D", "94dd.f818.157d", "94ddf818157d"], "formats")
        try expectEqual(info.vendor, "Brother", "fabricant")
        try expectEqual(info.oui, "94:DD:F8", "OUI")
        try expectEqual(info.kind, "Universelle (UAA)", "universelle")
        let random = try unwrap(MACVendorLookup.lookup("DA:A1:19:5C:07:E2"), "MAC aléatoire acceptée")
        try expectEqual(random.kind, "Administrée localement", "administrée localement")
        try expect(random.cast.contains("aléatoire"), "MAC privée signalée")
        try expect(MACVendorLookup.lookup("94:dd:f8:18:15") == nil, "MAC incomplète refusée")
        try expectEqual(MACVendorLookup.hexDigitCount("94:dd:f8:18:15"), 10, "chiffres comptés")
        try expectEqual(PortScanner.serviceName(9100), "jetdirect", "service connu")
        try expectEqual(PortScanner.webScheme(for: 8443), "https", "schéma web")
    }
}

private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message, file: file, line: line) }
    return value
}

// MARK: - Réponse DNS fixe

enum DNSFixture {
    /// Réponse à « example.com A » : A, MX (pointeur dans les données), TXT, AAAA ; SOA en autorité.
    static let response: [UInt8] = {
        var b: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 4, 0, 1, 0, 0]
        // Question (décalage 12) : example.com A IN
        b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        // A 93.184.216.34, TTL 300
        b += [0xC0, 12, 0, 1, 0, 1, 0, 0, 0x01, 0x2C, 0, 4, 93, 184, 216, 34]
        // MX 10 mail.example.com (« mail » + pointeur vers example.com)
        b += [0xC0, 12, 0, 15, 0, 1, 0, 0, 0x0E, 0x10, 0, 9, 0, 10, 4] + Array("mail".utf8) + [0xC0, 12]
        // TXT « v=spf1 -all » « bonjour »
        let txt: [UInt8] = [11] + Array("v=spf1 -all".utf8) + [7] + Array("bonjour".utf8)
        b += [0xC0, 12, 0, 16, 0, 1, 0, 0, 0x0E, 0x10, 0, UInt8(txt.count)] + txt
        // AAAA 2001:db8::1
        b += [0xC0, 12, 0, 28, 0, 1, 0, 0, 0x01, 0x2C, 0, 16, 0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [1]
        // SOA en autorité : ns.example.com admin.example.com 2026110301 7200 3600 1209600 300
        var soa: [UInt8] = [2] + Array("ns".utf8) + [0xC0, 12, 5] + Array("admin".utf8) + [0xC0, 12]
        for value: UInt32 in [2026110301, 7200, 3600, 1209600, 300] {
            soa += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        b += [0xC0, 12, 0, 6, 0, 1, 0, 0, 0x01, 0x2C, 0, UInt8(soa.count)] + soa
        return b
    }()
}

// MARK: - Serveurs locaux (127.0.0.1 seulement)

private func loopback(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return addr
}

private func bindLoopback(_ fd: Int32) throws -> UInt16 {
    var addr = loopback(port: 0)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw TestFailure(message: "bind impossible", file: #fileID, line: #line) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { throw TestFailure(message: "getsockname impossible", file: #fileID, line: #line) }
    return UInt16(bigEndian: addr.sin_port)
}

/// Serveur TCP local : accepte les connexions et appelle `handler` pour chacune.
final class LocalTCPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        port = try bindLoopback(fd)
        guard listen(fd, 16) == 0 else { throw TestFailure(message: "listen impossible", file: #fileID, line: #line) }
        let socket = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(socket, nil, nil)
                if client < 0 { return }
                if self?.isStopped ?? true { close(client); return }
                DispatchQueue.global().async {
                    handler(client)
                    close(client)
                }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    /// Port TCP libre de 127.0.0.1 (lié puis relâché) : une connexion y sera refusée.
    static func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        defer { close(fd) }
        return try bindLoopback(fd)
    }
}

/// Serveur UDP local : reçoit un datagramme, ou répond une fois à une requête.
final class LocalUDPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        port = try bindLoopback(fd)
    }

    func receive(timeout: TimeInterval) throws -> [UInt8] {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw TestFailure(message: "aucun datagramme reçu", file: #fileID, line: #line) }
        return Array(buffer[0..<n])
    }

    func replyOnce(_ makeResponse: @escaping @Sendable ([UInt8]) -> [UInt8]) {
        let socket = fd
        Thread.detachNewThread {
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
            }
            guard n > 0 else { return }
            let response = makeResponse(Array(buffer[0..<n]))
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, response, response.count, 0, $0, length) }
            }
        }
    }

    func stop() {
        close(fd)
    }
}
