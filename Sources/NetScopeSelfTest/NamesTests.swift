import Darwin
import Foundation
import NetScopeCore

// Tests de la résolution de noms (mDNS, NetBIOS, chaîne) : les seuls échanges réels se font
// avec de faux répondeurs UDP sur 127.0.0.1 (ports éphémères).

func registerNamesTests(_ suite: TestSuite) {
    suite.add("Noms : requête PTR mDNS (unicast, puis bit QU)") {
        let query = NamesMDNS.query(for: IPv4Address("192.168.1.10")!, id: 0x1234, unicastResponse: false)
        var expected: [UInt8] = [0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["10", "1", "168", "192", "in-addr", "arpa"] {
            expected.append(UInt8(label.utf8.count))
            expected += Array(label.utf8)
        }
        expected += [0, 0, 12, 0x00, 0x01]
        try expectEqual(query, expected, "octets de la requête unicast")
        let qu = NamesMDNS.query(for: IPv4Address("192.168.1.10")!, id: 0x1234, unicastResponse: true)
        try expectEqual(Array(qu.suffix(2)), [0x80, 0x01], "classe IN avec bit QU")
        try expectEqual(qu.count, expected.count, "même taille")
    }

    suite.add("Noms : requête NBSTAT (nom « * » encodé)") {
        let query = NamesNetBIOS.nodeStatusQuery(id: 0xBEEF)
        let expected: [UInt8] = [0xBE, 0xEF, 0x00, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0x20]
            + Array("CK".utf8) + Array(repeating: Array("AA".utf8), count: 15).flatMap { $0 }
            + [0x00, 0x00, 0x21, 0x00, 0x01]
        try expectEqual(query, expected, "octets de la requête")
        try expectEqual(query.count, 50, "taille")
    }

    suite.add("Noms : réponse mDNS avec compression (PTR et A additionnel)") {
        let ip = IPv4Address("192.168.1.10")!
        let response = NamesFixture.mdnsResponse(id: 0x1234, ip: ip, name: "Macmini-de-Dany", includeQuestion: true)
        try expectEqual(NamesMDNS.hostname(in: response, for: ip), "Macmini-de-Dany.local", "nom par le PTR")
        try expectEqual(NamesFormat.display("Macmini-de-Dany.local"), "Macmini-de-Dany", "affichage sans .local")
        try expectEqual(NamesFormat.display("Macmini-de-Dany.local", stripLocal: false), "Macmini-de-Dany.local", "affichage complet")
        try expectEqual(NamesFormat.display("nas.maison.lan."), "nas.maison.lan", "autre domaine gardé")
        try expect(NamesMDNS.hostname(in: response, for: IPv4Address("192.168.1.11")!) == nil, "autre adresse ignorée")
        // Réponse sans PTR : nom tiré de l'enregistrement A qui pointe vers l'adresse.
        let aOnly = NamesFixture.mdnsAOnly(ip: ip, name: "imprimante")
        try expectEqual(NamesMDNS.hostname(in: aOnly, for: ip), "imprimante.local", "nom par le A")
        try expect(NamesMDNS.hostname(in: [0x12, 0x34, 0x84], for: ip) == nil, "réponse tronquée refusée")
        try expect(NamesMDNS.hostname(in: NamesMDNS.query(for: ip, id: 1, unicastResponse: false), for: ip) == nil,
                   "une requête n'est pas une réponse")
    }

    suite.add("Noms : réponse NBSTAT (3 noms et adresse MAC)") {
        let response = NamesFixture.nbstatResponse(id: 0xBEEF)
        let status = try unwrap(NamesNetBIOS.parseNodeStatus(response), "réponse décodée")
        try expectEqual(status.entries, [
            NetBIOSNameEntry(name: "DESKTOP-DANY", suffix: 0x00, isGroup: false),
            NetBIOSNameEntry(name: "WORKGROUP", suffix: 0x00, isGroup: true),
            NetBIOSNameEntry(name: "DESKTOP-DANY", suffix: 0x20, isGroup: false),
        ], "table des noms")
        try expectEqual(status.hostname, "DESKTOP-DANY", "nom de machine")
        try expectEqual(status.domain, "WORKGROUP", "groupe de travail")
        try expectEqual(status.mac, MACAddress("00:1a:2b:3c:4d:5e"), "adresse MAC")
        let samba = NamesFixture.nbstatResponse(id: 1, mac: [0, 0, 0, 0, 0, 0])
        try expect(NamesNetBIOS.parseNodeStatus(samba)?.mac == nil, "MAC nulle ignorée")
        try expect(NamesNetBIOS.parseNodeStatus(Array(response.prefix(60))) == nil, "réponse tronquée refusée")
        try expect(NamesNetBIOS.parseNodeStatus(NamesNetBIOS.nodeStatusQuery(id: 1)) == nil, "une requête n'est pas une réponse")
    }

    suite.add("Noms : noms génériques d’opérateur") {
        let ip = IPv4Address("24.84.12.7")!
        for generic in ["24-84-12-7.dhcp.isp.net", "7.12.84.24.dynamic.telus.net", "s0102030405.vc.shawcable.net.ip-24-84-12-7",
                        "host-24-84-12-7.example.com", "ip-10-0-0-1.ec2.internal", "dhcp-128.corp.example",
                        "pool-71-105.isp.com", "c0a80105.ip.example"] {
            let target = generic.hasPrefix("c0a8") ? IPv4Address("192.168.1.5")! : ip
            try expect(NameResolverChain.isGenericName(generic, for: target), "générique : \(generic)")
        }
        for real in ["Macmini-de-Dany.local", "imprimante-bureau.maison.lan", "iphone-de-dany", "hostmaster.example.com", "sw-core-01"] {
            try expect(!NameResolverChain.isGenericName(real, for: ip), "parlant : \(real)")
        }
    }

    suite.add("Noms : aller-retour mDNS unicast sur 127.0.0.1") {
        let responder = try NamesResponder { request in NamesFixture.mdnsReply(to: request, name: "Macmini-de-Dany") }
        defer { responder.stop() }
        let mdns = NamesMDNS(unicastPort: responder.port, multicast: nil)
        let name = await mdns.name(for: IPv4Address(127, 0, 0, 1), timeout: .seconds(2))
        try expectEqual(name, "Macmini-de-Dany.local", "nom reçu")
    }

    suite.add("Noms : repli « multicast » (bit QU) quand l’unicast reste muet") {
        let silent = try NamesResponder { _ in nil }
        defer { silent.stop() }
        let classes = NamesBox<[UInt16]>([])
        let responder = try NamesResponder { request in
            classes.mutate { $0.append(UInt16(request[request.count - 2]) << 8 | UInt16(request[request.count - 1])) }
            return NamesFixture.mdnsReply(to: request, name: "chromecast-salon")
        }
        defer { responder.stop() }
        // Le « groupe multicast » est remplacé par le faux répondeur local : rien ne sort de la machine.
        let mdns = NamesMDNS(unicastPort: silent.port, multicast: NamesEndpoint(IPv4Address(127, 0, 0, 1), port: responder.port),
                             fallbackDelay: .milliseconds(100))
        let name = await mdns.name(for: IPv4Address(127, 0, 0, 1), timeout: .seconds(2))
        try expectEqual(name, "chromecast-salon.local", "nom reçu par le repli")
        try expectEqual(classes.value, [0x8001], "requête de repli avec le bit QU")
        try expectEqual(silent.requestCount, 1, "requête unicast envoyée d’abord")
    }

    suite.add("Noms : 24 requêtes mDNS simultanées sur un seul socket") {
        let responder = try NamesResponder { request in
            // Le nom renvoyé dérive de la question : « 7.0.0.10.in-addr.arpa » → « hote-7 ».
            let label = String(decoding: request[13..<(13 + Int(request[12]))], as: UTF8.self)
            return NamesFixture.mdnsReply(to: request, name: "hote-\(label)")
        }
        defer { responder.stop() }
        let mdns = NamesMDNS(unicastPort: responder.port, unicastHost: IPv4Address(127, 0, 0, 1), multicast: nil)
        let names = await withTaskGroup(of: (Int, String?).self) { group in
            for index in 1...24 {
                group.addTask { (index, await mdns.name(for: IPv4Address(10, 0, 0, UInt8(index)), timeout: .seconds(3))) }
            }
            var result: [Int: String] = [:]
            for await (index, name) in group { result[index] = name }
            return result
        }
        for index in 1...24 {
            try expectEqual(names[index], "hote-\(index).local", "réponse de 10.0.0.\(index)")
        }
    }

    suite.add("Noms : délai respecté sans réponse") {
        let silent = try NamesResponder { _ in nil }
        defer { silent.stop() }
        let start = Date()
        let name = await NamesMDNS(unicastPort: silent.port, multicast: nil).name(for: IPv4Address(127, 0, 0, 1), timeout: .milliseconds(300))
        let elapsed = Date().timeIntervalSince(start)
        try expect(name == nil, "aucun nom")
        try expect(elapsed >= 0.25 && elapsed < 1.5, "délai de 300 ms respecté (\(elapsed) s)")
        let status = await NamesNetBIOS(port: silent.port).status(for: IPv4Address(127, 0, 0, 1), timeout: .milliseconds(200))
        try expect(status == nil, "aucune table NetBIOS")
    }

    suite.add("Noms : aller-retour NetBIOS sur 127.0.0.1") {
        let responder = try NamesResponder { request in
            NamesFixture.nbstatResponse(id: UInt16(request[0]) << 8 | UInt16(request[1]))
        }
        defer { responder.stop() }
        let netbios = NamesNetBIOS(port: responder.port)
        let status = await netbios.status(for: IPv4Address(127, 0, 0, 1), timeout: .seconds(2))
        try expectEqual(status?.hostname, "DESKTOP-DANY", "nom de machine")
        try expectEqual(status?.domain, "WORKGROUP", "groupe de travail")
        try expectEqual(status?.mac, MACAddress("00:1a:2b:3c:4d:5e"), "adresse MAC")
        // Mauvais identifiant de transaction : réponse ignorée.
        let liar = try NamesResponder { _ in NamesFixture.nbstatResponse(id: 0) }
        defer { liar.stop() }
        let ignored = await NamesNetBIOS(port: liar.port).status(for: IPv4Address(127, 0, 0, 1), timeout: .milliseconds(300))
        try expect(ignored == nil, "réponse d’une autre transaction ignorée")
    }

    suite.add("Noms : chaîne de résolution (priorités et détails)") {
        let ip = IPv4Address(127, 0, 0, 1)
        let mdnsResponder = try NamesResponder { request in NamesFixture.mdnsReply(to: request, name: "Macmini-de-Dany") }
        defer { mdnsResponder.stop() }
        let netbiosResponder = try NamesResponder { request in
            NamesFixture.nbstatResponse(id: UInt16(request[0]) << 8 | UInt16(request[1]))
        }
        defer { netbiosResponder.stop() }
        let mdns = NamesMDNS(unicastPort: mdnsResponder.port, multicast: nil)
        let netbios = NamesNetBIOS(port: netbiosResponder.port)

        // DNS générique : mDNS l'emporte ; les détails gardent tout.
        let generic = NameResolverChain(reverseDNS: FixedNames(name: "ip-127-0-0-1.isp.net"), mdns: mdns, netbios: netbios)
        let details = await generic.details(for: ip, timeout: .seconds(2))
        try expectEqual(details.hostname, "Macmini-de-Dany.local", "nom retenu")
        try expectEqual(details.source, .mdns, "source")
        try expectEqual(details.displayName, "Macmini-de-Dany", "nom affiché")
        try expectEqual(details.dnsName, "ip-127-0-0-1.isp.net", "réponse DNS gardée")
        try expectEqual(details.netbiosName, "DESKTOP-DANY", "nom NetBIOS")
        try expectEqual(details.netbiosDomain, "WORKGROUP", "domaine NetBIOS")
        try expectEqual(details.netbiosMAC, MACAddress("00:1a:2b:3c:4d:5e"), "MAC NetBIOS")
        try expectEqual(await generic.name(for: ip, timeout: .seconds(2)), "Macmini-de-Dany.local", "protocole ScanNameResolving")

        // DNS parlant : prioritaire.
        let good = NameResolverChain(reverseDNS: FixedNames(name: "nas.maison.lan."), mdns: mdns, netbios: netbios)
        let goodDetails = await good.details(for: ip, timeout: .seconds(2))
        try expectEqual(goodDetails.hostname, "nas.maison.lan", "DNS prioritaire")
        try expectEqual(goodDetails.source, .dns, "source DNS")

        // Ni DNS ni mDNS : NetBIOS.
        let onlyNetBIOS = NameResolverChain(reverseDNS: FixedNames(name: nil), mdns: nil, netbios: netbios)
        try expectEqual(await onlyNetBIOS.details(for: ip, timeout: .seconds(2)).source, .netbios, "repli NetBIOS")

        // Rien d'autre qu'un nom générique : on le garde.
        let silent = try NamesResponder { _ in nil }
        defer { silent.stop() }
        let lastResort = NameResolverChain(reverseDNS: FixedNames(name: "ip-127-0-0-1.isp.net"),
                                           mdns: NamesMDNS(unicastPort: silent.port, multicast: nil),
                                           netbios: NamesNetBIOS(port: silent.port), maxTimeout: .milliseconds(300))
        let start = Date()
        let fallback = await lastResort.details(for: ip, timeout: .seconds(5))
        try expectEqual(fallback.hostname, "ip-127-0-0-1.isp.net", "nom générique en dernier recours")
        try expect(Date().timeIntervalSince(start) < 1.5, "délai global plafonné")

        // Rien du tout.
        let nothing = NameResolverChain(reverseDNS: nil, mdns: nil, netbios: nil)
        try expectEqual(await nothing.details(for: ip, timeout: .seconds(1)), NameDetails(), "aucun nom")
    }
}

// MARK: - Aides

private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}

/// Résolveur DNS factice.
private struct FixedNames: ScanNameResolving {
    let name: String?
    func name(for ip: IPv4Address, timeout: Duration) async -> String? { name }
}

/// Valeur protégée par un verrou.
private final class NamesBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

/// Faux répondeur UDP sur 127.0.0.1 : répond à chaque datagramme par `handler` (rien si `nil`).
private final class NamesResponder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let stopped = NamesBox(false)
    private let requests = NamesBox(0)
    private let done = DispatchSemaphore(value: 0)

    var requestCount: Int { requests.value }

    init(_ handler: @escaping @Sendable ([UInt8]) -> [UInt8]?) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TestFailure(message: "socket impossible", file: #fileID, line: #line) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw TestFailure(message: "bind impossible", file: #fileID, line: #line)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        self.fd = fd
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let socket = fd, stopped = stopped, requests = requests, done = done
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while !stopped.value {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, bytes.baseAddress, bytes.count, 0, $0, &fromLength) }
                    }
                }
                guard count > 0 else { continue }
                requests.mutate { $0 += 1 }
                guard let response = handler(Array(buffer[0..<count])) else { continue }
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, response, response.count, 0, $0, fromLength) }
                }
            }
            done.signal()
        }
    }

    func stop() {
        stopped.mutate { $0 = true }
        done.wait()
        close(fd)
    }
}

/// Réponses fixes (octets construits à la main).
private enum NamesFixture {
    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func labels(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        return bytes
    }

    /// Réponse mDNS : question (nom inverse en 12), PTR par pointeur C0 0C vers « <nom>.local »,
    /// puis A additionnel dont le nom pointe vers les données du PTR.
    static func mdnsResponse(id: UInt16, ip: IPv4Address, name: String, includeQuestion: Bool) -> [UInt8] {
        let reverse = labels(DNSLookup.reverseName(for: ip)) + [0]
        var bytes = be16(id) + [0x84, 0x00] + be16(includeQuestion ? 1 : 0) + be16(1) + be16(0) + be16(1)
        if includeQuestion {
            bytes += reverse + be16(12) + be16(1)
        }
        // PTR : nom par pointeur si la question est là, sinon en clair.
        bytes += includeQuestion ? [0xC0, 0x0C] : reverse
        let target = labels(name) + labels("local") + [0]
        bytes += be16(12) + [0x80, 0x01] + [0, 0, 0, 120] + be16(UInt16(target.count))
        let targetOffset = bytes.count
        bytes += target
        // A : nom compressé vers les données du PTR.
        let o = ip.octets
        bytes += [0xC0 | UInt8(targetOffset >> 8), UInt8(targetOffset & 0xFF)] + be16(1) + [0x80, 0x01] + [0, 0, 0, 120] + be16(4)
        bytes += [o.0, o.1, o.2, o.3]
        return bytes
    }

    /// Réponse avec seulement un enregistrement A (« <nom>.local » → ip).
    static func mdnsAOnly(ip: IPv4Address, name: String) -> [UInt8] {
        let o = ip.octets
        var bytes = be16(0) + [0x84, 0x00] + be16(0) + be16(1) + be16(0) + be16(0)
        bytes += labels(name) + labels("local") + [0] + be16(1) + [0x80, 0x01] + [0, 0, 0, 120] + be16(4)
        bytes += [o.0, o.1, o.2, o.3]
        return bytes
    }

    /// Réponse « legacy unicast » : même identifiant, question recopiée, PTR par pointeur.
    static func mdnsReply(to request: [UInt8], name: String) -> [UInt8]? {
        guard request.count > 16 else { return nil }
        let question = Array(request[12..<(request.count - 4)]) + be16(12) + be16(1)
        var bytes = Array(request[0..<2]) + [0x84, 0x00] + be16(1) + be16(1) + be16(0) + be16(0)
        bytes += question
        let target = labels(name) + labels("local") + [0]
        bytes += [0xC0, 0x0C] + be16(12) + be16(1) + [0, 0, 0, 10] + be16(UInt16(target.count)) + target
        return bytes
    }

    /// Réponse NBSTAT : DESKTOP-DANY<00>, WORKGROUP<00> (groupe), DESKTOP-DANY<20>, puis la MAC.
    static func nbstatResponse(id: UInt16, mac: [UInt8] = [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]) -> [UInt8] {
        func entry(_ name: String, _ suffix: UInt8, group: Bool) -> [UInt8] {
            let padded = Array(name.utf8) + [UInt8](repeating: 0x20, count: 15 - name.utf8.count)
            return padded + [suffix] + (group ? [0x84, 0x00] : [0x04, 0x00])
        }
        var rdata: [UInt8] = [3]
        rdata += entry("DESKTOP-DANY", 0x00, group: false)
        rdata += entry("WORKGROUP", 0x00, group: true)
        rdata += entry("DESKTOP-DANY", 0x20, group: false)
        rdata += mac + [UInt8](repeating: 0, count: 40)
        let name: [UInt8] = [0x20] + Array("CK".utf8) + Array(repeating: Array("AA".utf8), count: 15).flatMap { $0 } + [0]
        var bytes = be16(id) + [0x84, 0x00] + be16(0) + be16(1) + be16(0) + be16(0)
        bytes += name + be16(0x21) + be16(1) + [0, 0, 0, 0] + be16(UInt16(rdata.count)) + rdata
        return bytes
    }
}
