import Darwin
import Foundation
@testable import NetScopeCore

// Tests du module Scan. Aucun accès réseau, sauf vers 127.0.0.1 (ping et port d'écoute local).

func registerScanTests(_ suite: TestSuite) {
    suite.add("Table ARP : tampon sysctl construit à la main") {
        var buffer: [UInt8] = []
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO | RTF_UP, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 1)),
            ScanTestBuffers.link(name: "en0", mac: [0x04, 0xD5, 0x90, 0x3A, 0x7B, 0x11]),
        ])
        // Entrée incomplète (aucune adresse matérielle) : ignorée.
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 9)),
            ScanTestBuffers.link(name: "en0", mac: []),
        ])
        // Diffusion : ignorée.
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 255)),
            ScanTestBuffers.link(name: "en0", mac: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        // Nom d'interface vide, MAC aléatoire.
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 100)),
            ScanTestBuffers.link(name: "", mac: [0x3A, 0x1F, 0xC7, 0x02, 0x9B, 0xE4]),
        ])
        let table = ARPTable.parse(buffer)
        try expectEqual(table.count, 2, "deux entrées complètes")
        try expectEqual(table[IPv4Address(10, 182, 122, 1)], MACAddress("04:d5:90:3a:7b:11"), "passerelle")
        try expectEqual(table[IPv4Address(10, 182, 122, 100)], MACAddress("3a:1f:c7:02:9b:e4"), "MAC aléatoire")
        try expect(table[IPv4Address(10, 182, 122, 9)] == nil, "entrée incomplète ignorée")
        // Tampon tronqué : aucune lecture hors limites.
        try expectEqual(ARPTable.parse(Array(buffer.prefix(buffer.count - 10))).count, 1, "dernier message (tronqué) ignoré")
        try expectEqual(ARPTable.parse([]).count, 0, "tampon vide")
        try expectEqual(ScanRouting.headerSize, 92, "taille de rt_msghdr")
    }

    suite.add("Table ARP : sortie de « arp -an »") {
        let output = """
        ? (10.182.122.1) at 4:d5:90:3a:7b:11 on en0 ifscope [ethernet]
        ? (10.182.122.9) at (incomplete) on en0 ifscope [ethernet]
        ? (10.182.122.111) at 94:dd:f8:18:15:7d on en0 ifscope [ethernet]
        ? (10.182.122.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        """
        let table = ARPTable.parseCommandOutput(output)
        try expectEqual(table.count, 2, "entrées retenues")
        try expectEqual(table[IPv4Address("10.182.122.1")!], MACAddress("04:d5:90:3a:7b:11"), "octets sans zéro")
        try expectEqual(table[IPv4Address("10.182.122.111")!]?.formatted(.upperColon), "94:DD:F8:18:15:7D", "imprimante")
    }

    suite.add("Passerelle, DNS et plage suggérée (lecture locale)") {
        var buffer: [UInt8] = []
        // Route propre à une interface (RTF_IFSCOPE), puis route générale : la générale l'emporte.
        buffer += ScanTestBuffers.message(flags: RTF_UP | RTF_GATEWAY | RTF_IFSCOPE, addrs: RTA_DST | RTA_GATEWAY | RTA_NETMASK, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(0, 0, 0, 0)),
            ScanTestBuffers.inet(IPv4Address(192, 168, 1, 1)),
            [0, 0, 0, 0],
        ])
        buffer += ScanTestBuffers.message(flags: RTF_UP | RTF_GATEWAY, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(10, 0, 0, 0)),
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 254)),
        ])
        buffer += ScanTestBuffers.message(flags: RTF_UP | RTF_GATEWAY, addrs: RTA_DST | RTA_GATEWAY | RTA_NETMASK, sockaddrs: [
            ScanTestBuffers.inet(IPv4Address(0, 0, 0, 0)),
            ScanTestBuffers.inet(IPv4Address(10, 182, 122, 1)),
            [0, 0, 0, 0],
        ])
        try expectEqual(ScanNetwork.parseDefaultGateway(buffer), IPv4Address(10, 182, 122, 1), "route par défaut")
        try expectEqual(ScanNetwork.parseDefaultGateway(Array(buffer.prefix(ScanTestBuffers.lastLength(buffer)))),
                        IPv4Address(192, 168, 1, 1), "repli sur la route d'interface")
        try expectEqual(ScanNetwork.parseRouteGetOutput("   route to: default\ndestination: default\n    gateway: 10.182.122.1\n  interface: en0\n"),
                        IPv4Address("10.182.122.1"), "route -n get default")
        try expectEqual(ScanNetwork.parseResolvConf("# commentaire\nnameserver 10.182.122.1\nnameserver fe80::1%en0\nnameserver 8.8.8.8\nsearch local\n"),
                        [IPv4Address("10.182.122.1")!, IPv4Address("8.8.8.8")!], "resolv.conf")
        let wifi = LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!, netmask: IPv4Address("255.255.255.0")!, kind: .wifi)
        try expectEqual(ScanNetwork.suggestedSubnet(for: wifi).description, "10.182.122.0/24", "réseau /24")
        let large = LocalInterface(name: "en1", address: IPv4Address("10.20.30.40")!, netmask: IPv4Address("255.0.0.0")!)
        try expectEqual(ScanNetwork.suggestedSubnet(for: large).description, "10.20.30.0/24", "réseau /8 ramené à son /24")
    }

    suite.add("Concurrence plafonnée") {
        let gauge = ScanTestGauge()
        await ScanConcurrency.forEach(Array(0..<60), limit: 6) { _ in
            await gauge.enter()
            try? await Task.sleep(nanoseconds: 3_000_000)
            await gauge.leave()
        }
        let (peak, total) = await gauge.snapshot()
        try expectEqual(total, 60, "tous les travaux exécutés")
        try expect(peak <= 6, "jamais plus de 6 à la fois (\(peak))")
        try expect(peak >= 2, "travaux réellement concurrents (\(peak))")
        let doubled = await ScanConcurrency.compactMap(Array(1...20), limit: 3) { $0 % 2 == 0 ? $0 * 10 : nil }
        try expectEqual(doubled.sorted(), [20, 40, 60, 80, 100, 120, 140, 160, 180, 200], "compactMap")
    }

    suite.add("Paquet ICMP : construction, somme de contrôle, lecture") {
        let request = ICMPPinger.echoRequest(identifier: 0xBEEF, sequence: 0x0102, timestamp: 42)
        try expectEqual(request.count, 24, "8 octets d'en-tête + 16 de charge utile")
        try expectEqual(request[0], 8, "type 8 (requête d'écho)")
        try expectEqual(ICMPPinger.checksum(request), 0, "somme de contrôle valide")
        var reply = request
        reply[0] = 0
        // Avec un en-tête IP de 20 octets, comme le fournit macOS.
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        let parsed = ICMPPinger.parseEchoReply(ipHeader + reply)
        try expectEqual(parsed?.sequence, 0x0102, "séquence lue")
        try expectEqual(parsed?.payloadIdentifier, 0xBEEF, "identifiant de la charge utile")
        try expect(ICMPPinger.parseEchoReply(reply) != nil, "sans en-tête IP")
        try expect(ICMPPinger.parseEchoReply(request) == nil, "une requête n'est pas une réponse")
        var foreign = reply
        foreign[8] = 0x00
        try expect(ICMPPinger.parseEchoReply(foreign) == nil, "charge utile étrangère ignorée")
    }

    suite.add("Ping ICMP vers 127.0.0.1") {
        let pinger: ICMPPinger
        do { pinger = try ICMPPinger() } catch { throw TestSkipped(reason: "socket ICMP indisponible : \(error.localizedDescription)") }
        let loopback = IPv4Address(127, 0, 0, 1)
        guard let rtt = await pinger.ping(loopback, timeout: .seconds(2)) else {
            throw TestFailure(message: "aucune réponse de 127.0.0.1", file: #fileID, line: #line)
        }
        try expect(rtt >= 0 && rtt < 1000, "RTT plausible (\(rtt) ms)")
        // Plusieurs sondes simultanées sur le même socket.
        let results = await withTaskGroup(of: Double?.self) { group -> [Double?] in
            for _ in 0..<20 { group.addTask { await pinger.ping(loopback, timeout: .seconds(2)) } }
            var all: [Double?] = []
            for await value in group { all.append(value) }
            return all
        }
        try expectEqual(results.compactMap { $0 }.count, 20, "20 réponses sur 20")
        try expectEqual(pinger.inFlight, 0, "aucune sonde en attente")
    }

    suite.add("PortProber vers un port d'écoute local") {
        let listener = try ScanTestListener()
        defer { listener.close() }
        let closed = try ScanTestListener.freePort()
        let open = await PortProber().openPorts(IPv4Address(127, 0, 0, 1), ports: [closed, listener.port, listener.port],
                                                timeout: .seconds(2), concurrency: 4)
        try expectEqual(open, [listener.port], "seul le port d'écoute est ouvert")
        let refused = await PortProber.isOpen(IPv4Address(127, 0, 0, 1), port: closed, timeout: .seconds(2))
        try expect(!refused, "port fermé")
    }

    suite.add("ScanEngine : plages, ARP, détails (sondes simulées)") {
        let bureau = ScanTarget(label: "Bureau", vlan: 1, range: try IPRange(parsing: "10.0.0.1-10"))
        let serveurs = ScanTarget(label: "Serveurs", vlan: 100, range: try IPRange(parsing: "10.0.0.8-12"))
        let pinger = ScanFakePinger(replies: [IPv4Address("10.0.0.1")!: 0.8, IPv4Address("10.0.0.5")!: 4.1,
                                              IPv4Address("10.0.0.11")!: 2.0])
        let arp = ScanFakeARP(table: [
            IPv4Address("10.0.0.1")!: MACAddress("04:d5:90:3a:7b:11")!,
            IPv4Address("10.0.0.7")!: MACAddress("94:dd:f8:18:15:7d")!,   // ne répond pas au ping
            IPv4Address("192.168.9.9")!: MACAddress("70:0f:6a:91:4c:02")!, // hors plage
        ])
        let ports = ScanFakePorts(open: [IPv4Address("10.0.0.5")!: [80, 443, 9100], IPv4Address("10.0.0.11")!: [53, 88, 389, 445]])
        let names = ScanFakeNames(names: [IPv4Address("10.0.0.11")!: "srv-ad-01.bureau.local"])
        let engine = ScanEngine(pinger: pinger, arp: arp, ports: ports, names: names)
        var found: [IPv4Address: Device] = [:]
        var lastProgress: [UUID: ScanRangeProgress] = [:]
        var phases: [ScanPhase] = []
        var summary: ScanSummary?
        for await event in engine.scan([bureau, serveurs], options: ScanOptions(profile: .portsCourants, concurrency: 4)) {
            switch event {
            case .started(let ranges): try expectEqual(ranges.map(\.total), [10, 2], "adresses dédoublonnées")
            case .phase(let phase): phases.append(phase)
            case .deviceFound(let device, _), .deviceUpdated(let device, _): found[device.ip] = device
            case .rangeProgress(let progress): lastProgress[progress.rangeID] = progress
            case .finished(let result): summary = result
            }
        }
        try expectEqual(phases, [.ping, .arp, .details], "étapes")
        try expectEqual(Set(found.keys), Set(["10.0.0.1", "10.0.0.5", "10.0.0.7", "10.0.0.11"].map { IPv4Address($0)! }), "hôtes trouvés")
        try expectEqual(summary?.devices.count, 4, "bilan")
        try expectEqual(summary?.scannedAddresses, 12, "adresses sondées")
        try expectEqual(lastProgress[bureau.id]?.done, 10, "Bureau terminée")
        try expectEqual(lastProgress[bureau.id]?.online, 3, "Bureau : 2 au ping + 1 par ARP")
        try expectEqual(lastProgress[serveurs.id]?.online, 1, "Serveurs : 1 en ligne")
        let arpOnly = found[IPv4Address("10.0.0.7")!]
        try expect(arpOnly?.isOnline == true && arpOnly?.latencyMs == nil, "hôte vu par ARP seulement : en ligne, sans latence")
        try expectEqual(arpOnly?.vendor, "Brother", "fabricant par OUI")
        try expectEqual(arpOnly?.deviceType, .imprimante, "type d'après le fabricant")
        try expectEqual(found[IPv4Address("10.0.0.1")!]?.mac, MACAddress("04:d5:90:3a:7b:11"), "MAC ajoutée à un hôte du ping")
        try expectEqual(found[IPv4Address("10.0.0.5")!]?.openPorts, [80, 443, 9100], "ports ouverts")
        try expectEqual(found[IPv4Address("10.0.0.5")!]?.deviceType, .imprimante, "9100 : imprimante")
        let server = found[IPv4Address("10.0.0.11")!]
        try expectEqual(server?.hostname, "srv-ad-01.bureau.local", "nom résolu")
        try expectEqual(server?.rangeLabel, "Serveurs", "plage")
        try expectEqual(server?.vlan, 100, "VLAN de la plage")
        try expectEqual(server?.deviceType, .serveur, "contrôleur de domaine")
        try expectEqual(server?.latencyMs, 2.0, "latence")
    }

    suite.add("ScanEngine : annulation propre") {
        let engine = ScanEngine(pinger: ScanFakePinger(replies: [:], delay: 50_000_000), arp: ScanFakeARP(table: [:]),
                                ports: ScanNoPorts(), names: ScanNoNames())
        let target = ScanTarget(label: "Grande", range: try IPRange(parsing: "10.1.0.0/22"))
        let started = Date()
        let consumer = Task { () -> Int in
            var progressEvents = 0
            for await event in engine.scan([target], options: ScanOptions(concurrency: 8)) {
                if case .rangeProgress = event { progressEvents += 1 }
            }
            return progressEvents
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()
        _ = await consumer.value
        try expect(Date().timeIntervalSince(started) < 2, "arrêt rapide (sans attendre les 1022 adresses)")
    }

    suite.add("Type d'appareil deviné") {
        try expectEqual(ScanDeviceClassifier.guess(ports: [80, 631], vendor: nil, hostname: nil, mac: nil), .imprimante, "IPP")
        try expectEqual(ScanDeviceClassifier.guess(ports: [80, 554], vendor: nil, hostname: nil, mac: nil), .camera, "RTSP")
        try expectEqual(ScanDeviceClassifier.guess(ports: [135, 445, 3389], vendor: "Dell", hostname: "WKS346", mac: nil), .poste, "RDP")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22, 161, 443], vendor: "Cisco", hostname: nil, mac: nil), .switch, "SNMP + Cisco")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22, 443, 541], vendor: "Fortinet", hostname: "FortiGate-60F", mac: nil), .routeur, "pare-feu")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22, 443], vendor: "Fortinet", hostname: "FortiAP-231F", mac: nil), .pointAcces, "borne")
        try expectEqual(ScanDeviceClassifier.guess(ports: [], vendor: nil, hostname: "Android_89UM1WTN", mac: nil), .telephone, "téléphone")
        try expectEqual(ScanDeviceClassifier.guess(ports: [], vendor: nil, hostname: nil, mac: nil), .inconnu, "rien")
    }

    suite.add("Export CSV et paquet Wake-on-LAN") {
        let device = Device(ip: IPv4Address("10.182.122.111")!, mac: MACAddress("94:dd:f8:18:15:7d"),
                            hostname: "Brother; DCP \"L2640DW\"", customName: "Imprimante accueil", latencyMs: 4.1,
                            openPorts: [80, 9100], vlan: 30, firstSeen: Date(timeIntervalSince1970: 0),
                            lastSeen: Date(timeIntervalSince1970: 60), deviceType: .imprimante)
        let lines = ScanCSV.make([device]).components(separatedBy: "\r\n")
        try expectEqual(lines.count, 3, "en-tête, une ligne, fin de ligne finale")
        try expect(lines[0].hasPrefix("Statut;IP;Nom personnalisé"), "en-tête")
        try expect(lines[1].contains(";\"Brother; DCP \"\"L2640DW\"\"\";"), "guillemets et point-virgule échappés")
        try expect(lines[1].contains(";4,1;80 9100;"), "latence à la française, ports")
        try expect(lines[1].contains("94:DD:F8:18:15:7D"), "MAC")
        try expectEqual(Array(ScanCSV.data([]).prefix(3)), [0xEF, 0xBB, 0xBF], "BOM UTF-8")
        try expectEqual(ScanCSV.escape("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"", "formule neutralisée")
        try expectEqual(ScanCSV.escape("@SUM(A1)"), "'@SUM(A1)", "formule @ neutralisée")
        try expectEqual(ScanCSV.escape("10.0.0.1"), "10.0.0.1", "valeur ordinaire intacte")
        let packet = ScanWakeOnLAN.magicPacket(for: MACAddress("94:dd:f8:18:15:7d")!)
        try expectEqual(packet.count, 102, "102 octets")
        try expectEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6), "synchronisation")
        try expectEqual(Array(packet[96..<102]), [0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D], "16e répétition")
        try expectEqual(ScanReverseDNS.clean("srv-ad-01.bureau.local.", for: IPv4Address("10.0.0.1")!), "srv-ad-01.bureau.local", "point final retiré")
        try expectEqual(ScanReverseDNS.clean("10.0.0.1", for: IPv4Address("10.0.0.1")!), nil, "l'adresse n'est pas un nom")
    }
}

// MARK: - Outils de test

enum ScanTestBuffers {
    /// rt_msghdr suivi des sockaddr (arrondies à 4 octets), longueur totale renseignée.
    static func message(flags: Int32, addrs: Int32, sockaddrs: [[UInt8]]) -> [UInt8] {
        var header = rt_msghdr()
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_index = 4
        header.rtm_flags = flags
        header.rtm_addrs = addrs
        var body: [UInt8] = []
        for raw in sockaddrs {
            body += raw
            body += [UInt8](repeating: 0, count: ScanRouting.roundUp(raw.isEmpty ? 0 : Int(raw[0])) - raw.count)
        }
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        return withUnsafeBytes(of: header) { Array($0) } + body
    }

    /// sockaddr_in (16 octets), comme sockaddr_inarp.
    static func inet(_ ip: IPv4Address) -> [UInt8] {
        let o = ip.octets
        return [16, UInt8(AF_INET), 0, 0, o.0, o.1, o.2, o.3] + [UInt8](repeating: 0, count: 8)
    }

    /// sockaddr_dl : nom d'interface puis adresse matérielle (au moins 20 octets).
    static func link(name: String, mac: [UInt8]) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var raw: [UInt8] = [0, UInt8(AF_LINK), 4, 0, 6, UInt8(nameBytes.count), UInt8(mac.count), 0] + nameBytes + mac
        if raw.count < 20 { raw += [UInt8](repeating: 0, count: 20 - raw.count) }
        raw[0] = UInt8(raw.count)
        return raw
    }

    /// Longueur du tampon sans son dernier message.
    static func lastLength(_ buffer: [UInt8]) -> Int {
        var offset = 0
        var previous = 0
        while offset < buffer.count {
            previous = offset
            offset += Int(ScanRouting.readUInt16(buffer, offset))
        }
        return previous
    }
}

actor ScanTestGauge {
    private var current = 0
    private var peak = 0
    private var total = 0

    func enter() {
        current += 1
        total += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
    func snapshot() -> (Int, Int) { (peak, total) }
}

struct ScanFakePinger: ScanPinging {
    let replies: [IPv4Address: Double]
    var delay: UInt64 = 1_000_000

    func ping(_ ip: IPv4Address, timeout: Duration) async -> Double? {
        try? await Task.sleep(nanoseconds: delay)
        return replies[ip]
    }
}

struct ScanFakeARP: ScanARPReading {
    let table: [IPv4Address: MACAddress]
    func read() -> [IPv4Address: MACAddress] { table }
}

struct ScanFakePorts: ScanPortProbing {
    let open: [IPv4Address: [UInt16]]
    func openPorts(_ ip: IPv4Address, ports: [UInt16], timeout: Duration, concurrency: Int) async -> [UInt16] {
        (open[ip] ?? []).filter(ports.contains)
    }
}

struct ScanFakeNames: ScanNameResolving {
    let names: [IPv4Address: String]
    func name(for ip: IPv4Address, timeout: Duration) async -> String? { names[ip] }
}

/// Port TCP d'écoute sur 127.0.0.1 (port choisi par le système).
final class ScanTestListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let (fd, port) = try ScanTestListener.bind(listen: true)
        self.fd = fd
        self.port = port
    }

    func close() { Darwin.close(fd) }

    /// Port libre : ouvert puis refermé aussitôt.
    static func freePort() throws -> UInt16 {
        let (fd, port) = try bind(listen: false)
        Darwin.close(fd)
        return port
    }

    private static func bind(listen shouldListen: Bool) throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw TestSkipped(reason: "socket TCP indisponible") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = IPv4Address(127, 0, 0, 1).value.bigEndian
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Bool in
                Darwin.bind(fd, raw, length) == 0 && getsockname(fd, raw, &length) == 0
            }
        }
        guard bound, !shouldListen || Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw TestSkipped(reason: "écoute locale impossible")
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
