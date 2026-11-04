import Foundation
import Network
import NetScopeCore

// Tests du module Speedtest (calculs, iperf3, historique) et du module Accès distant
// (validation, échappement, .rdp, commandes). Seule la sonde TCP touche le réseau, vers 127.0.0.1.

func registerSpeedRemoteTests(_ suite: TestSuite) {
    suite.add("Speed : débit, médiane, gigue, centile") {
        try expectEqual(SpeedMath.megabitsPerSecond(bytes: 125_000_000, seconds: 1), 1000, "125 Mo en 1 s = 1000 Mb/s")
        try expectEqual(SpeedMath.megabitsPerSecond(bytes: 0, seconds: 1), 0, "aucun octet")
        try expectEqual(SpeedMath.megabitsPerSecond(bytes: 10, seconds: 0), 0, "durée nulle")
        try expectEqual(SpeedMath.median([6, 9, 5, 7, 40]), 7, "médiane impaire (valeur aberrante ignorée)")
        try expectEqual(SpeedMath.median([4, 8, 6, 2]), 5, "médiane paire")
        try expectEqual(SpeedMath.median([]), nil, "médiane vide")
        try expectEqual(SpeedMath.jitter([10, 12, 11, 15]), (2 + 1 + 4) / 3.0, "gigue : moyenne des écarts consécutifs")
        try expectEqual(SpeedMath.jitter([10]), nil, "gigue : une seule mesure")
        try expectEqual(SpeedMath.percentile([1, 2, 3, 4, 5], 0.5), 3, "centile 50")
        try expectEqual(SpeedMath.percentile([0, 10], 0.9), 9, "centile interpolé")
        try expectEqual(SpeedMath.bufferbloatGrade(idle: 6, loaded: 9), "A+", "bufferbloat faible")
        try expectEqual(SpeedMath.bufferbloatGrade(idle: 6, loaded: 18), "A", "bufferbloat +12 ms")
        try expectEqual(SpeedMath.bufferbloatGrade(idle: 8, loaded: 42), "B", "bufferbloat +34 ms")
        try expectEqual(SpeedMath.gaugeScale(for: 912), 1000, "jauge 1000")
        try expectEqual(SpeedMath.gaugeScale(for: 1200), 2500, "jauge 2500")
        try expectEqual(SpeedMath.planRatio(measured: 912, plan: 1000), 0.912, "part du forfait")
        try expectEqual(SpeedMath.planRatio(measured: 912, plan: 0), nil, "forfait inconnu")
    }

    suite.add("Speed : débit instantané et en régime établi") {
        // 1 s de montée à 100 Mb/s, puis 800 Mb/s (100 Mo/s) pendant 4 s.
        var samples = [SpeedSample(time: 0, totalBytes: 0)]
        var total: Int64 = 0
        var time = 0.0
        while time < 5 - 1e-9 {
            time += 0.25
            total += time <= 2 ? 3_125_000 : 25_000_000
            samples.append(SpeedSample(time: time, totalBytes: total))
        }
        let instant = SpeedMath.instantRate(samples, window: 1)
        try expect(abs(instant - 800) < 0.001, "instantané sur la dernière seconde : \(instant)")
        let steady = SpeedMath.steadyRate(samples, warmup: 2)
        try expect(abs(steady - 800) < 0.001, "régime établi après 2 s : \(steady)")
        let whole = SpeedMath.steadyRate(Array(samples.prefix(4)), warmup: 2)
        try expect(abs(whole - 100) < 0.001, "phase courte : toute la durée (\(whole))")
        try expectEqual(SpeedMath.steadyRate([]), 0, "aucun échantillon")
    }

    suite.add("Speed : réponse /meta et en-têtes de Cloudflare") {
        let json = #"{"hostname":"speed.cloudflare.com","clientIp":"203.0.113.24","httpProtocol":"HTTP/2","asn":577,"asOrganization":"Bell Canada","colo":"YUL","country":"CA","city":"Montreal"}"#
        let info = try unwrap(SpeedServerInfo(metaJSON: Data(json.utf8)), "meta lisible")
        try expectEqual(info.colo, "YUL", "nœud")
        try expectEqual(info.clientIP, "203.0.113.24", "IP publique")
        try expectEqual(info.providerLabel, "AS577 · Bell Canada", "fournisseur")
        try expectEqual(info.label, "Cloudflare · YUL · Montreal", "libellé du serveur")
        try expectEqual(SpeedServerInfo(metaJSON: Data("pas du json".utf8)), nil, "meta illisible")
        let headers = SpeedServerInfo(headers: ["CF-Ray": "8d1f2a3b4c5d6e7f-YYZ", "cf-meta-ip": "203.0.113.24", "cf-meta-asn": "812"])
        try expectEqual(headers?.colo, "YYZ", "nœud lu dans cf-ray")
        try expectEqual(headers?.asn, 812, "ASN des en-têtes")
        try expectEqual(SpeedServerInfo.serverTimingDuration("cfRequestDuration;dur=12.5"), 12.5, "Server-Timing")
        try expectEqual(SpeedServerInfo.serverTimingDuration(nil), nil, "Server-Timing absent")
        let config = SpeedTestConfig(streams: 8)
        try expectEqual(config.downloadURL(bytes: 0).absoluteString, "https://speed.cloudflare.com/__down?bytes=0", "URL de latence")
        try expectEqual(config.uploadURL.absoluteString, "https://speed.cloudflare.com/__up", "URL de téléversement")
        try expectEqual(SpeedTestConfig(streams: 99).streams, 16, "flux plafonnés")
    }

    suite.add("iperf3 : options et ligne de commande") {
        var options = IperfOptions(host: "10.10.0.20", duration: 10, streams: 4)
        try expectEqual(try options.arguments(), ["-c", "10.10.0.20", "-p", "5201", "-t", "10", "-P", "4", "--connect-timeout", "5000", "-J"], "TCP normal")
        options.transport = .udp
        options.direction = .bidir
        try expectEqual(try options.arguments(), ["-c", "10.10.0.20", "-p", "5201", "-t", "10", "-P", "4", "-u", "-b", "1G", "--bidir", "--connect-timeout", "5000", "-J"], "UDP bidirectionnel")
        options = IperfOptions(host: "nas.local", direction: .reverse)
        try expectEqual(options.commandLine, "iperf3 -c nas.local -p 5201 -t 10 -P 4 -R --connect-timeout 5000 -J", "commande affichée")
        try expectThrows(IperfError.invalidHost("-oProxy"), "hôte commençant par un tiret") {
            _ = try IperfOptions(host: "-oProxy").arguments()
        }
        try expectThrows(IperfError.invalidHost("a;rm -rf"), "hôte avec ;") {
            _ = try IperfOptions(host: "a;rm -rf").arguments()
        }
        try expectThrows(IperfError.invalidOptions("Port invalide : 0."), "port 0") {
            _ = try IperfOptions(host: "10.0.0.1", port: 0).arguments()
        }
        try expectEqual(IperfLocator.find(paths: ["/nexiste/pas/iperf3"]), nil, "iperf3 absent")
        try expectEqual(IperfError.notInstalled.errorDescription, "iperf3 non installé (brew install iperf3)", "message d'absence")
    }

    suite.add("iperf3 : lecture du JSON TCP (intervalles, retransmissions)") {
        let result = try IperfParser.parse(Data(iperfTCPFixture.utf8))
        try expectEqual(result.version, "iperf 3.17.1", "version")
        try expectEqual(result.protocolName, "TCP", "protocole")
        try expectEqual(result.streams, 4, "flux")
        try expectEqual(result.remoteHost, "10.10.0.20", "serveur")
        try expectEqual(result.intervals.count, 3, "intervalles (l'omis est ignoré)")
        try expectEqual(result.intervals[0].retransmits, 12, "retransmissions du 1er intervalle")
        try expect(abs(result.intervals[1].megabitsPerSecond - 941.2) < 0.01, "débit du 2e intervalle")
        try expectEqual(result.retransmits, 15, "retransmissions totales")
        try expect(abs(result.megabitsPerSecond - 938.5) < 0.01, "débit reçu retenu : \(result.megabitsPerSecond)")
        try expect(!result.isUDP && !result.reverse, "TCP, sens normal")
    }

    suite.add("iperf3 : JSON UDP, bidirectionnel et erreur") {
        let udp = try IperfParser.parse(Data(iperfUDPFixture.utf8))
        try expect(udp.isUDP, "UDP")
        try expectEqual(udp.jitterMs, 0.042, "gigue")
        try expectEqual(udp.lostPackets, 17, "paquets perdus")
        try expectEqual(udp.packets, 85_000, "paquets")
        try expect(abs(udp.megabitsPerSecond - 999.1) < 0.01, "débit UDP")
        try expectEqual(udp.intervals.first?.packets, 8_500, "paquets par intervalle")
        let bidir = try IperfParser.parse(Data(iperfBidirFixture.utf8))
        try expect(bidir.bidirectional, "bidirectionnel")
        try expect(abs((bidir.intervals.first?.reverseMegabitsPerSecond ?? 0) - 610) < 0.01, "sens inverse par intervalle")
        try expect(abs((bidir.reverseMegabitsPerSecond ?? 0) - 605) < 0.01, "sens inverse total")
        try expectThrows(IperfError.server("unable to connect to server: Connection refused"), "erreur iperf3") {
            _ = try IperfParser.parse(Data(#"{"start":{},"intervals":[],"end":{},"error":"unable to connect to server: Connection refused"}"#.utf8))
        }
        try expectThrows(IperfError.invalidJSON, "JSON illisible") {
            _ = try IperfParser.parse(Data("iperf3: error".utf8))
        }
    }

    suite.add("Speed : historique JSON, 90 jours, CSV") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeedHistoryStore(url: directory.appendingPathComponent("speedtest.json"))
        try expectEqual(store.load().records, [], "historique vide")
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let recent = SpeedTestRecord(date: now.addingTimeInterval(-3_600), kind: .internet, server: "Cloudflare · YUL",
                                     interfaceName: "en7", interfaceKind: "Ethernet", downMbps: 912.4, upMbps: 487,
                                     latencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4, streams: 8)
        let old = SpeedTestRecord(date: now.addingTimeInterval(-100 * 86_400), kind: .lan, server: "NAS; 10.10.0.20",
                                  interfaceName: "en0", interfaceKind: "Wi-Fi", downMbps: 612)
        try store.save(SpeedHistoryStore.Content(records: [old, recent], planDownMbps: 1000, planUpMbps: 500))
        let loaded = store.load(now: now)
        try expectEqual(loaded.records, [recent], "plus de 90 jours : retiré")
        try expectEqual(loaded.planDownMbps, 1000, "forfait conservé")
        let csv = SpeedHistoryStore.csv([recent, old])
        let lines = csv.components(separatedBy: "\r\n")
        try expect(lines[0].hasPrefix("Date;Type;Origine;Serveur"), "en-tête CSV")
        try expect(lines[1].contains(";Internet;manuel;Cloudflare · YUL;en7 · Ethernet;912,4;487,0;6,0;18,0;1,4;8"), "ligne CSV : \(lines[1])")
        try expect(lines[2].contains("\"NAS; 10.10.0.20\""), "champ avec « ; » entre guillemets")
    }

    suite.add("Accès : validation des hôtes, utilisateurs, ports série") {
        for host in ["10.182.122.2", "sw-core-01.corp.local", "fe80::1", "NAS_SYNO"] {
            try expectEqual(try RemoteValidator.validateHost(host), host, "hôte valide \(host)")
        }
        try expectEqual(try RemoteValidator.validateHost("  10.0.0.1 "), "10.0.0.1", "espaces retirés")
        for host in ["-oProxyCommand=sh", "a b", "10.0.0.1;reboot", "$(id)", "`id`", "a'b", "a\"b", "host\nx", "..", ".hidden", "a|b", "a&b", "10.0.0.1:22", "nas:5201", "fe80:::1"] {
            try expectThrows(RemoteValidationError.invalidHost(host.trimmingCharacters(in: .whitespaces)), "hôte refusé \(host)") {
                try RemoteValidator.validateHost(host)
            }
        }
        try expectThrows(RemoteValidationError.emptyHost, "hôte vide") { try RemoteValidator.validateHost("  ") }
        try expectEqual(try RemoteValidator.validateUser("netadmin"), "netadmin", "utilisateur simple")
        try expectEqual(try RemoteValidator.validateUser("d.menard@corp.local"), "d.menard@corp.local", "utilisateur UPN")
        try expectEqual(try RemoteValidator.validateUser(""), "", "utilisateur vide permis")
        try expectEqual(try RemoteValidator.validateUser("CORP\\dmenard", allowDomain: true), "CORP\\dmenard", "domaine Windows en RDP")
        try expectThrows(RemoteValidationError.invalidUser("CORP\\dmenard"), "domaine refusé hors RDP") {
            try RemoteValidator.validateUser("CORP\\dmenard")
        }
        for user in ["-oX", "root;id", "a b", "x'y", "$USER"] {
            try expectThrows(RemoteValidationError.invalidUser(user), "utilisateur refusé \(user)") {
                try RemoteValidator.validateUser(user)
            }
        }
        try expectEqual(try RemoteValidator.validateSerialDevice("/dev/cu.usbserial-A10K"), "/dev/cu.usbserial-A10K", "port série")
        for path in ["/dev/disk0", "/dev/cu.", "/dev/cu.a;b", "/tmp/cu.x", "/dev/cu.../x"] {
            try expectThrows(RemoteValidationError.invalidSerialDevice(path), "série refusée \(path)") {
                try RemoteValidator.validateSerialDevice(path)
            }
        }
        try expectThrows(RemoteValidationError.invalidPort(70_000), "port hors limites") { try RemoteValidator.validatePort(70_000) }
    }

    suite.add("Accès : échappement shell et AppleScript") {
        try expectEqual(RemoteShell.quote("10.182.122.2"), "10.182.122.2", "mot sûr inchangé")
        try expectEqual(RemoteShell.quote("a b"), "'a b'", "espace : entre apostrophes")
        try expectEqual(RemoteShell.quote("it's"), "'it'\\''s'", "apostrophe échappée")
        try expectEqual(RemoteShell.quote("$(rm -rf ~)"), "'$(rm -rf ~)'", "substitution neutralisée")
        try expectEqual(RemoteShell.quote(""), "''", "mot vide")
        try expectEqual(RemoteShell.command(["echo", "a;b", "c"]), "echo 'a;b' c", "commande")
        try expectEqual(RemoteShell.appleScriptString("say \"hi\" \\ x"), "\"say \\\"hi\\\" \\\\ x\"", "AppleScript")
        try expectEqual(RemoteShell.appleScriptString("a\nb"), "\"a b\"", "retour à la ligne neutralisé")
    }

    suite.add("Accès : commandes SSH, Telnet, série et URL VNC") {
        let ssh = RemoteConnection(name: "SW-CORE-01", proto: .ssh, host: "10.182.122.2", username: "netadmin")
        try expectEqual(try RemoteLauncher.plan(for: ssh), .terminal(command: "ssh -- netadmin@10.182.122.2"), "SSH port 22")
        var custom = ssh
        custom.port = 2222
        custom.username = ""
        try expectEqual(RemoteLauncher.sshCommand(try custom.validated()), "ssh -p 2222 -- 10.182.122.2", "SSH port 2222")
        let telnet = RemoteConnection(name: "SW-ETG2-01", proto: .telnet, host: "10.182.122.3", username: "manager")
        try expectEqual(try RemoteLauncher.plan(for: telnet, telnetPath: "/opt/homebrew/bin/telnet"),
                        .terminal(command: "/opt/homebrew/bin/telnet -l manager 10.182.122.3 23"), "Telnet Homebrew")
        try expectEqual(try RemoteLauncher.plan(for: telnet, telnetPath: nil), .terminal(command: "nc 10.182.122.3 23"), "Telnet par nc")
        let serial = RemoteConnection(name: "USB-série", proto: .serie, host: "/dev/cu.usbserial-A10K", port: 9600)
        try expectEqual(try RemoteLauncher.plan(for: serial), .terminal(command: "screen /dev/cu.usbserial-A10K 9600"), "screen")
        try expectEqual(serial.address, "cu.usbserial-A10K · 9600 8N1", "adresse série")
        var badBaud = serial
        badBaud.port = 1234
        try expectThrows(RemoteValidationError.invalidBaud(1234), "débit série invalide") { _ = try RemoteLauncher.plan(for: badBaud) }
        let vnc = RemoteConnection(name: "Mac", proto: .vnc, host: "10.182.122.135", username: "dany")
        try expectEqual(try RemoteLauncher.plan(for: vnc), .url(URL(string: "vnc://dany@10.182.122.135")!), "VNC")
        var vncPort = vnc
        vncPort.port = 5901
        try expectEqual(try RemoteLauncher.vncURL(for: vncPort).absoluteString, "vnc://dany@10.182.122.135:5901", "VNC port")
        let evil = RemoteConnection(name: "x", proto: .ssh, host: "10.0.0.1 -oProxyCommand=id", username: "a")
        try expectThrows(RemoteValidationError.invalidHost("10.0.0.1 -oProxyCommand=id"), "injection refusée au lancement") {
            _ = try RemoteLauncher.plan(for: evil)
        }
        let script = RemoteLauncher.commandFile(command: "ssh -- 10.0.0.1", title: "Poste d'accueil")
        try expect(script.hasPrefix("#!/bin/zsh\nrm -f -- \"$0\"\n"), "script .command qui s'efface")
        try expect(script.contains("'Poste d'\\''accueil'"), "titre échappé")
        try expect(script.hasSuffix("ssh -- 10.0.0.1\n"), "commande en dernier")
    }

    suite.add("Accès : génération du fichier .rdp") {
        let rdp = RemoteConnection(name: "SRV-FICHIERS (Windows)", proto: .rdp, host: "10.10.0.12", username: "CORP\\dmenard")
        guard case .rdpFile(let contents, let fileName) = try RemoteLauncher.plan(for: rdp) else {
            throw TestFailure(message: "plan RDP attendu", file: #fileID, line: #line)
        }
        try expectEqual(fileName, "SRV-FICHIERS-Windows.rdp", "nom de fichier assaini")
        let lines = contents.components(separatedBy: "\r\n")
        try expectEqual(lines[0], "full address:s:10.10.0.12:3389", "adresse complète")
        try expectEqual(lines[1], "username:s:CORP\\dmenard", "utilisateur avec domaine")
        try expect(lines.contains("prompt for credentials:i:1"), "identifiants demandés à l'ouverture")
        try expect(contents.hasSuffix("\r\n") && !contents.contains("\n\n"), "fins de ligne CRLF")
        let ipv6 = RemoteConnection(name: "v6", proto: .rdp, host: "fe80::10", port: 3390)
        try expect(RemoteLauncher.rdpFile(for: ipv6).hasPrefix("full address:s:[fe80::10]:3390\r\n"), "IPv6 entre crochets")
        try expect(!RemoteLauncher.rdpFile(for: ipv6).contains("username"), "sans utilisateur")
        try expectEqual(RemoteLauncher.rdpFileName(for: RemoteConnection(name: "Électricité ;", proto: .rdp, host: "a")), "Electricite.rdp", "accents et ponctuation")
        let url = try RemoteLauncher.writeTemporary(contents, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: url) }
        try expectEqual(try String(contentsOf: url, encoding: .utf8), contents, "fichier temporaire écrit")
    }

    suite.add("Accès : connexions enregistrées, recherche, import du scan") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteConnectionStore(url: directory.appendingPathComponent("connexions.json"))
        try expectEqual(store.load(), nil, "aucun fichier")
        let core = RemoteConnection(name: "SW-CORE-01", proto: .ssh, host: "10.182.122.2", username: "netadmin",
                                    folder: "Siège › Réseau", isFavorite: true, note: "Cisco Catalyst 9300",
                                    createdAt: Date(timeIntervalSince1970: 1_793_000_000))
        try store.save([core])
        try expectEqual(store.load(), [core], "aller-retour JSON")
        try expect(core.matches("cisco 9300"), "recherche : note")
        try expect(core.matches("ssh 10.182"), "recherche : protocole et IP")
        try expect(!core.matches("rdp"), "recherche : absent")
        let copy = core.duplicated()
        try expect(copy.id != core.id && copy.name == "SW-CORE-01 (copie)" && !copy.isFavorite, "duplication")
        try expectThrows(RemoteValidationError.emptyName, "nom vide") {
            _ = try RemoteConnection(name: "  ", proto: .ssh, host: "10.0.0.1").validated()
        }
        let devices = [
            Device(ip: IPv4Address("10.182.122.117")!, hostname: "WKS346", openPorts: [135, 445, 3389]),
            Device(ip: IPv4Address("10.182.122.2")!, hostname: "SW-CORE-01", openPorts: [22, 161, 443]),
            Device(ip: IPv4Address("10.182.122.3")!, hostname: "SW-ETG2-01", openPorts: [23, 80]),
            Device(ip: IPv4Address("10.182.122.135")!, hostname: "Macmini", openPorts: [5900]),
            Device(ip: IPv4Address("10.182.122.111")!, hostname: "Imprimante", openPorts: [80, 9100]),
        ]
        let candidates = RemoteImport.candidates(from: devices, existing: [core])
        try expectEqual(candidates.map(\.ip), ["10.182.122.2", "10.182.122.3", "10.182.122.117", "10.182.122.135"], "appareils retenus, triés")
        try expectEqual(candidates.map(\.proto), [.ssh, .telnet, .rdp, .vnc], "protocoles proposés")
        try expectEqual(candidates.map(\.alreadySaved), [true, false, false, false], "déjà enregistrée")
        let imported = candidates[2].connection()
        try expectEqual(imported.folder, "Importés du scan", "dossier d'import")
        try expectEqual(imported.port, 3389, "port RDP")
    }

    suite.add("Accès : sonde TCP vers 127.0.0.1") {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = OnceBox()
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: DispatchQueue(label: "netscope.selftest.listener"))
        defer { listener.cancel() }
        try await ready.wait(seconds: 3)
        guard let port = listener.port?.rawValue else { throw TestSkipped(reason: "écouteur local indisponible") }
        let open = await RemoteProbe.tcp(host: "127.0.0.1", port: Int(port), timeout: 2)
        try expect(open, "port ouvert joignable")
        listener.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closed = await RemoteProbe.tcp(host: "127.0.0.1", port: Int(port), timeout: 1)
        try expect(!closed, "port fermé non joignable")
        let invalid = await RemoteProbe.tcp(host: "127.0.0.1;id", port: 22)
        try expect(!invalid, "hôte invalide refusé sans connexion")
    }
}

/// Signal à usage unique, attendu avec une limite de temps.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func signal() {
        lock.lock()
        done = true
        lock.unlock()
    }

    private var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func wait(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestSkipped(reason: "écouteur local non prêt")
    }
}

private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}

// MARK: - Sorties iperf3 fixes (abrégées, structure de iperf 3.17)

private let iperfTCPFixture = #"""
{
  "start": {
    "connected": [{"socket": 5, "local_host": "10.182.122.135", "local_port": 50544, "remote_host": "10.10.0.20", "remote_port": 5201}],
    "version": "iperf 3.17.1",
    "system_info": "Darwin Macmini-de-Dany 25.2.0",
    "test_start": {"protocol": "TCP", "num_streams": 4, "blksize": 131072, "omit": 0, "duration": 3, "bytes": 0, "blocks": 0, "reverse": 0, "tos": 0, "target_bitrate": 0, "bidir": 0}
  },
  "intervals": [
    {"streams": [], "sum": {"start": 0, "end": 1.000131, "seconds": 1.000131, "bytes": 114819072, "bits_per_second": 918400000.0, "retransmits": 12, "omitted": false, "sender": true}},
    {"streams": [], "sum": {"start": 1.000131, "end": 2.000222, "seconds": 1.000091, "bytes": 117653504, "bits_per_second": 941200000.0, "retransmits": 0, "omitted": false, "sender": true}},
    {"streams": [], "sum": {"start": 2.000222, "end": 3.000301, "seconds": 1.000079, "bytes": 117522432, "bits_per_second": 940100000.0, "retransmits": 3, "omitted": false, "sender": true}},
    {"streams": [], "sum": {"start": 3.000301, "end": 3.1, "seconds": 0.1, "bytes": 1000, "bits_per_second": 80000.0, "retransmits": 0, "omitted": true, "sender": true}}
  ],
  "end": {
    "streams": [],
    "sum_sent": {"start": 0, "end": 3.000301, "seconds": 3.000301, "bytes": 349995008, "bits_per_second": 933250000.0, "retransmits": 15, "sender": true},
    "sum_received": {"start": 0, "end": 3.0021, "seconds": 3.0021, "bytes": 352187392, "bits_per_second": 938500000.0, "sender": true},
    "cpu_utilization_percent": {"host_total": 12.4, "remote_total": 8.1}
  }
}
"""#

private let iperfUDPFixture = #"""
{
  "start": {"connected": [{"local_host": "10.182.122.135", "remote_host": "10.10.0.20", "remote_port": 5201}], "version": "iperf 3.17.1",
            "test_start": {"protocol": "UDP", "num_streams": 1, "duration": 10, "reverse": 0, "bidir": 0}},
  "intervals": [
    {"streams": [], "sum": {"start": 0, "end": 1.0, "seconds": 1.0, "bytes": 124950000, "bits_per_second": 999600000.0, "packets": 8500, "omitted": false, "sender": true}}
  ],
  "end": {"streams": [],
          "sum": {"start": 0, "end": 10.0, "seconds": 10.0, "bytes": 1248875000, "bits_per_second": 999100000.0, "jitter_ms": 0.042, "lost_packets": 17, "packets": 85000, "lost_percent": 0.02, "sender": true}}
}
"""#

private let iperfBidirFixture = #"""
{
  "start": {"connected": [], "version": "iperf 3.17.1", "test_start": {"protocol": "TCP", "num_streams": 1, "duration": 1, "reverse": 0, "bidir": 1}},
  "intervals": [
    {"streams": [], "sum": {"start": 0, "end": 1, "seconds": 1, "bytes": 117000000, "bits_per_second": 936000000.0, "retransmits": 0, "omitted": false, "sender": true},
     "sum_bidir_reverse": {"start": 0, "end": 1, "seconds": 1, "bytes": 76250000, "bits_per_second": 610000000.0, "omitted": false, "sender": false}}
  ],
  "end": {"sum_sent": {"bytes": 117000000, "bits_per_second": 936000000.0, "retransmits": 0},
          "sum_received": {"bytes": 116500000, "bits_per_second": 932000000.0},
          "sum_sent_bidir_reverse": {"bytes": 76000000, "bits_per_second": 608000000.0},
          "sum_received_bidir_reverse": {"bytes": 75600000, "bits_per_second": 605000000.0}}
}
"""#
