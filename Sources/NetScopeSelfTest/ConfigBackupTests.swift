import Foundation
import NetScopeCore

// Note 40 (0.31.0) : sauvegarde des configurations. Tout est vérifié sans réseau : comparaison
// (Myers), secrets masqués, sortie SSH recopiée, réponses fixes de l'API FortiGate, dossier
// temporaire pour l'historique. Aucun ssh n'est lancé.

private struct FixedFortiTransport: FortiTransport {
    let response: FortiHTTPResponse
    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        guard path == ConfigBackupFortiGate.path, query.contains(URLQueryItem(name: "scope", value: "global")) else {
            return FortiHTTPResponse(status: 404, body: Data())
        }
        return response
    }
}

func registerConfigBackupTests(_ suite: TestSuite) {
    suite.add("Configurations : comparaison ligne à ligne (ajouts, retraits, numéros)") {
        let old = "a\nb\nc\nd\ne\n"
        let new = "a\nB\nc\nd\ne\nf\n"
        let diff = ConfigDiff.make(old: old, new: new, masked: false)
        try expectEqual(diff.added, 2, "B et f ajoutées")
        try expectEqual(diff.removed, 1, "b retirée")
        try expect(!diff.approximate, "recherche fine")
        let removed = diff.lines.first { $0.kind == .removed }
        try expectEqual(removed?.text, "b", "ligne retirée")
        try expectEqual(removed?.oldNumber, 2, "numéro avant")
        let last = diff.lines.last { !$0.text.isEmpty }
        try expectEqual(last?.kind, .added, "f ajoutée à la fin")
        try expectEqual(last?.newNumber, 6, "numéro après")
        // Reconstruire les deux textes depuis la comparaison.
        let rebuiltOld = diff.lines.filter { $0.kind != .added }.map(\.text)
        let rebuiltNew = diff.lines.filter { $0.kind != .removed }.map(\.text)
        try expectEqual(rebuiltOld, ConfigText.lines(old), "texte avant reconstruit")
        try expectEqual(rebuiltNew, ConfigText.lines(new), "texte après reconstruit")
        try expect(ConfigDiff.make(old: old, new: old).isIdentical, "identiques")
        try expectEqual(ConfigDiff.make(old: "", new: "x\ny", masked: false).added, 2, "depuis un texte vide")
    }

    suite.add("Configurations : comparaison de textes mélangés, reconstruction exacte") {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<40 {
            let a = (0..<Int.random(in: 0...40, using: &generator)).map { _ in String("abcde".randomElement(using: &generator)!) }
            let b = (0..<Int.random(in: 0...40, using: &generator)).map { _ in String("abcde".randomElement(using: &generator)!) }
            let diff = ConfigDiff.make(oldLines: a, newLines: b)
            try expectEqual(diff.lines.filter { $0.kind != .added }.map(\.text), a, "avant, essai \(round)")
            try expectEqual(diff.lines.filter { $0.kind != .removed }.map(\.text), b, "après, essai \(round)")
            try expect(diff.added - diff.removed == b.count - a.count, "bilan, essai \(round)")
        }
        // Au-delà du plafond de modifications : approximative, mais toujours exacte.
        let a = (0..<200).map { "x\($0)" }, b = (0..<200).map { "y\($0)" }
        let rough = ConfigDiff.make(oldLines: a, newLines: b, maxEdits: 10)
        try expect(rough.approximate, "plafond atteint")
        try expectEqual(rough.removed, 200, "tout retiré")
        try expectEqual(rough.added, 200, "tout ajouté")
    }

    suite.add("Configurations : blocs avec contexte et lignes sautées") {
        let old = (1...30).map { "ligne \($0)" }
        var new = old
        new[4] = "ligne cinq"
        new[24] = "ligne vingt-cinq"
        let hunks = ConfigDiff.make(oldLines: old, newLines: new).hunks(context: 2)
        try expectEqual(hunks.count, 2, "deux blocs séparés")
        try expectEqual(hunks[0].skippedBefore, 2, "deux lignes sautées avant le premier")
        try expectEqual(hunks[0].header, "@@ -3,5 +3,5 @@", "en-tête du premier bloc")
        try expect(hunks[1].skippedBefore > 0, "lignes sautées entre les blocs")
        let close = new.enumerated().map { $0.offset == 6 ? "ligne sept" : $0.element }
        try expectEqual(ConfigDiff.make(oldLines: old, newLines: close).hunks(context: 2).count, 2, "toujours deux blocs")
        var near = old
        near[4] = "x"; near[7] = "y"
        try expectEqual(ConfigDiff.make(oldLines: old, newLines: near).hunks(context: 2).count, 1, "changements proches : un bloc")
    }

    suite.add("Configurations : secrets masqués et lignes datées ignorées") {
        try expectEqual(ConfigText.masked("    set password ENC SH2abcdefXYZ=="), "    set password ENC •••", "ENC de FortiOS")
        try expectEqual(ConfigText.masked("enable secret 9 $9$abc$def"), "enable secret 9 •••", "secret Cisco")
        try expectEqual(ConfigText.masked("username admin privilege 15 password 7 0822455D0A16"), "username admin privilege 15 password 7 •••", "mot de passe type 7")
        try expectEqual(ConfigText.masked("snmp-server community public RO"), "snmp-server community ••• RO", "communauté SNMP")
        try expectEqual(ConfigText.masked("set authentication-password=Secret123 name=x"), "set authentication-password=••• name=x", "MikroTik")
        try expectEqual(ConfigText.masked("hostname SW-CORE-01"), "hostname SW-CORE-01", "ligne ordinaire inchangée")
        // FortiOS rechiffre les secrets à chaque sauvegarde ; Cisco date la dernière modification.
        let a = "#config-version=FGT60F\n#conf_file_ver=111\nconfig system admin\n    set password ENC AAAA\nend\n"
        let b = "#config-version=FGT60F\n#conf_file_ver=222\nconfig system admin\n    set password ENC BBBB\nend\n"
        try expect(ConfigText.sameConfiguration(a, b), "même configuration FortiGate")
        let c1 = "!\n! Last configuration change at 09:10:44 EST Thu Nov 5 2026\nhostname A\nend\n"
        let c2 = "!\n! Last configuration change at 11:00:00 EST Thu Nov 5 2026\nhostname A\nend\n"
        try expect(ConfigText.sameConfiguration(c1, c2), "même configuration Cisco")
        try expect(!ConfigText.sameConfiguration(c1, c2.replacingOccurrences(of: "hostname A", with: "hostname B")), "changement réel vu")
        try expect(ConfigText.isVolatile("# nov/05/2026 14:02:11 by RouterOS 7.15"), "en-tête MikroTik")
    }

    suite.add("Configurations : commandes en lecture seule seulement") {
        for kind in ConfigDeviceKind.allCases {
            try expect(ConfigBackupCommands.allReadOnly(kind), "commandes de \(kind.label)")
        }
        try expectEqual(ConfigDeviceKind.cisco.sshCommands, ["terminal length 0", "show running-config", "exit"], "Cisco")
        try expectEqual(ConfigDeviceKind.aruba.sshCommands, ["show running-config"], "Aruba")
        try expectEqual(ConfigDeviceKind.fortiswitch.sshCommands, ["show full-configuration"], "FortiSwitch")
        try expectEqual(ConfigDeviceKind.mikrotik.sshCommands, ["/export"], "MikroTik")
        for bad in ["configure terminal", "write memory", "copy running-config tftp://10.0.0.1/x", "reload",
                    "show running-config ; reload", "show running-config | redirect flash:x", "/export file=sauvegarde",
                    "/system reset-configuration", "execute backup config tftp x 10.0.0.1", "conf t", "", "erase startup-config",
                    "show running-config\nreload"] {
            try expect(!ConfigBackupCommands.isReadOnly(bad), "refusée\u{00A0}: \(bad)")
        }
        try expect(ConfigBackupCommands.isReadOnly("SHOW   running-config"), "majuscules et espaces")
    }

    suite.add("Configurations : arguments de ssh (exec, shell de Cisco, aucun secret)") {
        let target = ConfigSSHTarget(user: "netadmin", host: "10.182.122.3", port: 2222, keyPath: "")
        let aruba = ConfigBackupSSH.arguments(target, kind: .aruba)
        try expectEqual(Array(aruba.suffix(3)), ["--", "netadmin@10.182.122.3", "show running-config"], "commande après la destination")
        try expect(aruba.contains("StrictHostKeyChecking=ask"), "serveur inconnu demandé")
        try expect(aruba.contains("2222"), "port")
        try expect(ConfigBackupSSH.input(for: .aruba) == nil, "rien sur l'entrée")
        let cisco = ConfigBackupSSH.arguments(ConfigSSHTarget(user: "netadmin", host: "10.182.122.2"), kind: .cisco, acceptNewHostKey: true)
        try expectEqual(cisco.last, "netadmin@10.182.122.2", "Cisco : pas de commande exec")
        try expect(cisco.contains("StrictHostKeyChecking=accept-new"), "empreinte acceptée")
        try expect(!cisco.contains("-p"), "port 22 par défaut")
        let probe = ConfigBackupSSH.hostKeyProbeArguments(ConfigSSHTarget(user: "netadmin", host: "10.182.122.2", port: 2222),
                                                          knownHosts: "/tmp/kh")
        try expect(probe.contains("UserKnownHostsFile=/tmp/kh") && probe.contains("PreferredAuthentications=none")
                   && probe.contains("PasswordAuthentication=no") && probe.contains("BatchMode=yes"), "relevé de clé sans authentification")
        try expectEqual(Array(probe.suffix(3)), ["--", "netadmin@10.182.122.2", "true"], "relevé : destination après --")
        try expect(probe.contains("2222"), "relevé : port")
        let keygen = "256 SHA256:AbC+/12 10.182.122.2 (ED25519)\n3072 SHA256:XyZ 10.182.122.2 (RSA)\n"
        try expectEqual(ConfigBackupSSH.fingerprints(inKeygenOutput: keygen), ["SHA256:AbC+/12", "SHA256:XyZ"], "empreintes de ssh-keygen -l")
        let input = ConfigBackupSSH.input(for: .cisco).map { String(decoding: $0, as: UTF8.self) }
        try expectEqual(input, "terminal length 0\nshow running-config\nexit\n", "commandes de Cisco sur l'entrée")
        try expect(!ConfigSSHTarget(user: "-oProxyCommand=x", host: "h").isValid, "utilisateur qui serait une option")
        try expect(!ConfigSSHTarget(user: "a", host: "h;reboot").isValid, "hôte avec « ; »")
        try expect(ConfigSSHTarget(user: "admin", host: "sw.siege.local").isValid, "nom d'hôte")
    }

    suite.add("Configurations : sortie SSH nettoyée et erreurs expliquées") {
        let raw = "\r\nSW-CORE-01#terminal length 0\r\nSW-CORE-01#show running-config\r\nBuilding configuration...\r\n\r\nCurrent configuration : 120 bytes\r\n!\r\nhostname SW-CORE-01\r\n!\r\nend\r\n\r\nSW-CORE-01#exit\r\n"
        let ok = ConfigBackupSSH.interpret(status: 0, stdout: raw, stderr: "", timedOut: false, host: "10.182.122.2", kind: .cisco)
        guard case .success(let text) = ok else { throw TestFailure(message: "Cisco attendu en succès", file: #fileID, line: #line) }
        try expect(text.hasPrefix("Building configuration..."), "début de la configuration")
        try expect(text.hasSuffix("end\n"), "fin à « end »")
        try expect(!text.contains("SW-CORE-01#"), "invites retirées")
        try expect(!text.contains("\r"), "retours chariot retirés")

        let ansi = "\u{1B}[2Jconfig system global\n    set hostname \"S248\"\nend\nS248EPTF18001234 # "
        if case .success(let fs) = ConfigBackupSSH.interpret(status: 0, stdout: ansi, stderr: "", timedOut: false, host: "h", kind: .fortiswitch) {
            try expect(fs.hasPrefix("config system global"), "séquence ANSI retirée")
            try expect(!fs.contains("S248EPTF18001234 #"), "invite finale retirée")
        } else { throw TestFailure(message: "FortiSwitch attendu en succès", file: #fileID, line: #line) }

        func kind(_ status: Int32, _ out: String, _ err: String, timedOut: Bool = false, _ k: ConfigDeviceKind = .aruba) -> ConfigBackupError.Kind? {
            if case .failure(let e) = ConfigBackupSSH.interpret(status: status, stdout: out, stderr: err, timedOut: timedOut, host: "h", kind: k) { return e.kind }
            return nil
        }
        try expectEqual(kind(255, "", "netadmin@h: Permission denied (publickey,password)."), .authentication, "mot de passe refusé")
        try expectEqual(kind(255, "", "Host key verification failed.\nED25519 key fingerprint is SHA256:abc."), .unknownHostKey, "serveur inconnu")
        try expectEqual(kind(255, "", "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"), .hostKey, "clé changée")
        try expectEqual(kind(255, "", "ssh: connect to host h port 22: Operation timed out"), .timeout, "délai")
        try expectEqual(kind(255, "", "ssh: connect to host h port 22: Connection refused"), .unreachable, "refusé")
        try expectEqual(kind(0, "", ""), .emptyOutput, "sortie vide")
        try expectEqual(kind(0, "        ^\n% Invalid input detected at '^' marker.\n", "", .cisco), .commandRejected, "commande refusée")
        try expectEqual(kind(0, "bad command name export (line 1 column 2)\n", "", .mikrotik), .commandRejected, "MikroTik")
        try expectEqual(kind(-1, "hostname x\npartiel\n", "", timedOut: true), .timeout, "configuration tronquée non gardée")
    }

    suite.add("Configurations : API FortiGate (succès, profil du jeton refusé, version sans GET)") {
        let config = "#config-version=FGT60F-7.4.4-FW-build2662:opmode=0:vdom=0\nconfig system global\n    set hostname \"FGT\"\nend\n"
        let ok = await ConfigBackupFortiGate.fetch(transport: FixedFortiTransport(response: FortiHTTPResponse(status: 200, body: Data(config.utf8))), token: "jeton")
        guard case .success(let text) = ok else { throw TestFailure(message: "succès attendu", file: #fileID, line: #line) }
        try expect(text.contains("set hostname \"FGT\""), "configuration reçue")
        func kind(_ status: Int, _ body: String) async -> ConfigBackupError.Kind? {
            let result = await ConfigBackupFortiGate.fetch(transport: FixedFortiTransport(response: FortiHTTPResponse(status: status, body: Data(body.utf8))), token: "abcd1234")
            if case .failure(let e) = result { return e.kind }
            return nil
        }
        try expectEqual(await kind(403, "{\"http_status\":403}"), .forbidden, "403")
        try expectEqual(await kind(401, ""), .forbidden, "401")
        try expectEqual(await kind(200, "{\"http_status\":403,\"status\":\"error\"}"), .forbidden, "403 dans le JSON")
        try expectEqual(await kind(405, ""), .apiUnsupported, "405")
        try expectEqual(await kind(200, ""), .emptyOutput, "vide")
        try expectEqual(await kind(200, "<html>login</html>"), .api, "page HTML")
        try expectEqual(await kind(500, ""), .api, "erreur du serveur")
        let refused = ConfigBackupFortiGate.interpret(FortiHTTPResponse(status: 200, body: Data("{\"status\":\"error\",\"token\":\"abcd1234\"}".utf8)), token: "abcd1234")
        if case .failure(let e) = refused { try expect(!e.detail.contains("abcd1234"), "jeton jamais affiché") } else { throw TestFailure(message: "échec attendu", file: #fileID, line: #line) }
        try expect(ConfigBackupError(kind: .forbidden, detail: "").advice.contains("sysgrp"), "marche à suivre du profil")
    }

    suite.add("Configurations : historique sur le disque (versions, inchangée, élagage, réglages)") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ConfigBackupArchive(siteFolder: root, timeZone: TimeZone(identifier: "UTC")!)
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try expectEqual(archive.fileName(for: t0), "2026-10-26_07-33-20.conf", "nom daté")
        try expectEqual(archive.date(fromFileName: "2026-10-26_07-33-20-2.conf"), t0, "date relue (doublon)")
        let first = try archive.save("hostname A\n", for: "SW-CORE-01", at: t0, keep: 3)
        guard case .saved(_, nil, false) = first else { throw TestFailure(message: "première version", file: #fileID, line: #line) }
        let same = try archive.save("hostname A\n\n", for: "SW-CORE-01", at: t0.addingTimeInterval(60), keep: 3)
        guard case .unchanged = same else { throw TestFailure(message: "inchangée attendue", file: #fileID, line: #line) }
        let changed = try archive.save("hostname B\n", for: "SW-CORE-01", at: t0.addingTimeInterval(120), keep: 3)
        guard case .saved(_, _?, true) = changed else { throw TestFailure(message: "changée attendue", file: #fileID, line: #line) }
        for step in 3...6 { try archive.save("hostname \(step)\n", for: "SW-CORE-01", at: t0.addingTimeInterval(Double(step) * 60), keep: 3) }
        let versions = archive.versions(of: "SW-CORE-01")
        try expectEqual(versions.count, 3, "trois versions gardées")
        try expectEqual(versions.first.flatMap(archive.read), "hostname 6\n", "la plus récente d'abord")
        let path = versions[0].url.path
        try expect(path.hasSuffix("/configurations/SW-CORE-01/" + archive.fileName(for: t0.addingTimeInterval(360))), "chemin sites/<site>/configurations/<équipement>/<date>.conf")
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        try expectEqual(mode, 0o600, "fichier privé")
        try expectEqual(archive.prune("SW-CORE-01", keep: 1).count, 2, "élagage à une version")
        // Même seconde : second fichier, pas d'écrasement.
        try archive.save("x\n", for: "dup", at: t0, keep: 5)
        try archive.save("y\n", for: "dup", at: t0, keep: 5)
        try expectEqual(archive.versions(of: "dup").count, 2, "deux fichiers à la même seconde")

        var settings = ConfigBackupSettings(keep: 9999)
        try expectEqual(settings.keep, 500, "plafond des versions")
        settings.equipment["SW-ETG2-01"] = .init(kind: .aruba, credentialID: UUID())
        settings.pendingChanges["SW-CORE-01"] = t0
        try archive.saveSettings(settings)
        try expectEqual(archive.loadSettings(), settings, "réglages relus")
        let json = try String(contentsOf: archive.settingsURL, encoding: .utf8)
        try expect(!json.lowercased().contains("password"), "aucun secret dans les réglages")
    }

    suite.add("Configurations : noms de dossier sûrs et type détecté") {
        try expectEqual(ConfigEquipment.folderName(name: "FortiGate Siège", host: "10.182.122.1"), "FortiGate-Siege", "accents et espaces")
        try expectEqual(ConfigEquipment.folderName(name: "../../etc", host: "h"), "etc", "jamais de remontée")
        try expectEqual(ConfigEquipment.folderName(name: "", host: "10.0.0.2"), "10.0.0.2", "adresse sans nom")
        try expectEqual(ConfigEquipment.folderName(name: "///", host: ""), "equipement", "rien d'utilisable")
        try expectEqual(ConfigDeviceKind.detect(descr: "Cisco Catalyst 9300-48P, IOS XE Software, Version 17.9.4a"), .cisco, "Cisco")
        try expectEqual(ConfigDeviceKind.detect(descr: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch"), .aruba, "Aruba")
        try expectEqual(ConfigDeviceKind.detect(descr: "HP J9773A 2530-24G-PoEP Switch"), .aruba, "HP ProCurve")
        try expectEqual(ConfigDeviceKind.detect(descr: "FortiSwitch-248E-FPOE v7.4.3"), .fortiswitch, "FortiSwitch")
        try expectEqual(ConfigDeviceKind.detect(descr: "RouterOS CRS326-24G-2S+"), .mikrotik, "MikroTik")
        try expectEqual(ConfigDeviceKind.detect(descr: "Linux 5.10"), nil, "inconnu")
        try expectEqual(SwitchPageTab(capture: "sauvegardes"), .configurations, "onglet des captures")
        try expectEqual(SwitchPageTab.configurations.title(badge: 2), "Configurations (2 modifiées)", "compteur")
    }
}
