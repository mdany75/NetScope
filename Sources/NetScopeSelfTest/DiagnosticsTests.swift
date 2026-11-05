import Foundation
import NetScopeCore

// Tests du journal de l'app et du diagnostic exporté (note 35) : masqueur de secrets, tampon
// circulaire, fichier tournant, rapports de plantage et contenu de l'archive. Aucun réseau :
// données fixes et dossiers temporaires.

private let hidden = SecretMasker.placeholder

private func temporaryFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("netscope-\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// Vérifie que `secret` a disparu du texte masqué et que `kept` (le contexte) est resté.
private func expectMasked(_ text: String, secret: String, kept: String? = nil,
                          file: String = #fileID, line: Int = #line) throws {
    let masked = SecretMasker.mask(text)
    try expect(!masked.contains(secret), "« \(secret) » doit être masqué dans « \(text) » — obtenu « \(masked) »", file: file, line: line)
    try expect(masked.contains(hidden), "le masque doit apparaître dans « \(masked) »", file: file, line: line)
    if let kept {
        try expect(masked.contains(kept), "« \(kept) » doit rester lisible dans « \(masked) »", file: file, line: line)
    }
}

private func expectUnchanged(_ text: String, file: String = #fileID, line: Int = #line) throws {
    try expectEqual(SecretMasker.mask(text), text, "rien à masquer dans « \(text) »", file: file, line: line)
}

func registerDiagnosticsTests(_ suite: TestSuite) {
    // MARK: Masqueur

    suite.add("Diagnostic : masqueur, jetons Bearer et en-têtes Authorization") {
        try expectMasked("Authorization: Bearer h8sd7f6g5h4j3k2l1qwe9rtz0x", secret: "h8sd7f6g5h4j3k2l1qwe9rtz0x", kept: "Authorization: Bearer ")
        try expectMasked("authorization:Basic dXNlcjpwYXNzd29yZA==", secret: "dXNlcjpwYXNzd29yZA", kept: "Basic ")
        try expectMasked("Proxy-Authorization: Digest abc123def", secret: "abc123def")
        try expectMasked("GET /api/v2/monitor/system/status avec Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-_x", secret: "eyJhbGciOiJIUzI1NiJ9")
        try expectMasked("Authorization: s3cr3tHeaderValue", secret: "s3cr3tHeaderValue")
        try expectMasked("en-têtes : [\"Authorization\": \"Bearer zzTOKENzz99\"]", secret: "zzTOKENzz99")
        // Plusieurs lignes : chaque en-tête est masqué.
        let headers = "Host: fw.exemple.local\nAuthorization: Bearer AAA111bbb222\nAccept: application/json"
        let masked = SecretMasker.mask(headers)
        try expect(!masked.contains("AAA111bbb222"), "jeton masqué dans les en-têtes")
        try expect(masked.contains("Host: fw.exemple.local") && masked.contains("Accept: application/json"), "autres en-têtes intacts")
    }

    suite.add("Diagnostic : masqueur, paramètres d'URL") {
        try expectMasked("https://10.0.0.1/api/v2/cmdb/system/interface?access_token=Qw3rTy12345&vdom=root",
                         secret: "Qw3rTy12345", kept: "&vdom=root")
        try expectMasked("https://api.exemple.com/v1?key=AIzaSyD-abc123&format=json", secret: "AIzaSyD-abc123", kept: "format=json")
        try expectMasked("/snmp?community=privee42", secret: "privee42")
        try expectMasked("https://h.local/x?a=1&password=hunter2#frag", secret: "hunter2", kept: "#frag")
        try expectMasked("https://h.local/cb?code=4/0AY0e-g7&state=xyz", secret: "4/0AY0e-g7", kept: "state=xyz")
        try expectMasked("webhook https://hooks.exemple.com/x?token=abcDEF123&sig=zzz999", secret: "abcDEF123")
        try expectMasked("ftp://admin:Pa55word!@192.168.1.20/configs", secret: "Pa55word!", kept: "ftp://admin:")
        try expectMasked("https://user:motdepasse@nas.local:5001/", secret: "motdepasse", kept: "@nas.local:5001")
    }

    suite.add("Diagnostic : masqueur, champs JSON") {
        try expectMasked(#"{"name":"fw-siege","token":"hk29sk3j4l5m6n7b8v9c0x1z2a3s4d","vdom":"root"}"#,
                         secret: "hk29sk3j4l5m6n7b8v9c0x1z2a3s4d", kept: #""vdom":"root""#)
        try expectMasked(#"{ "password" : "Ét3-très secret", "user": "admin" }"#, secret: "Ét3-très secret", kept: #""user": "admin""#)
        try expectMasked(#"{"snmp":{"community":"public2","version":"v2c"}}"#, secret: "public2", kept: "v2c")
        try expectMasked(#"{"access_token": "ya29.A0ARrdaM-x", "expires_in": 3599}"#, secret: "ya29.A0ARrdaM-x", kept: "3599")
        try expectMasked(#"{"apiKey":"k-9f8e7d"}"#, secret: "k-9f8e7d")
        try expectMasked(#"{"smtpPassword":"azerty","port":587}"#, secret: "azerty", kept: "587")
        try expectMasked(#"{"authPassword": "authpass1", "privPassword": "privpass2"}"#, secret: "authpass1")
        try expectMasked(#"{"authPassword": "authpass1", "privPassword": "privpass2"}"#, secret: "privpass2")
        try expectMasked(#"{"secret": 123456789}"#, secret: "123456789")
        // Guillemet échappé dans la valeur : tout disparaît.
        try expectMasked(#"{"password":"ab\"cd","x":1}"#, secret: "cd")
        // JSON échappé dans une chaîne (corps de réponse journalisé).
        try expectMasked(#"corps : "{\"token\":\"tok-ABC-123\",\"ok\":true}""#, secret: "tok-ABC-123")
    }

    suite.add("Diagnostic : masqueur, texte libre, mots de passe et clés d'API") {
        try expectMasked("Connexion SSH : mot de passe : Hiver2026! refusé", secret: "Hiver2026!", kept: "Connexion SSH")
        try expectMasked("Mot de passe\u{00A0}: «\u{00A0}abc def\u{00A0}»", secret: "abc def")
        try expectMasked("password=hunter2 user=bob", secret: "hunter2", kept: "user=bob")
        try expectMasked("smtpPassword: azerty123", secret: "azerty123")
        try expectMasked("X-API-Key: 0a1b2c3d4e5f", secret: "0a1b2c3d4e5f", kept: "X-API-Key")
        try expectMasked("api_key=sk_live_51Habc", secret: "sk_live_51Habc")
        try expectMasked("clé d’API : ZZ-998877", secret: "ZZ-998877")
        try expectMasked("jeton = 'abc-123'", secret: "abc-123")
        try expectMasked("client_secret: GOCSPX-abcdef", secret: "GOCSPX-abcdef")
        try expectMasked("passphrase=correct horse", secret: "correct")
        try expectMasked("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE KEY-----",
                         secret: "b3BlbnNzaC1rZXktdjEAAAA", kept: "BEGIN OPENSSH PRIVATE KEY")
    }

    suite.add("Diagnostic : masqueur, communautés SNMP") {
        try expectMasked("communauté : Priv3e", secret: "Priv3e")
        try expectMasked("SNMP v2c, community=monReseau", secret: "monReseau")
        try expectMasked("Communauté «\u{00A0}batiment-B\u{00A0}» refusée", secret: "batiment-B", kept: "refusée")
        try expectMasked("snmp-server community Sw1tchRO RO", secret: "Sw1tchRO", kept: " RO")
        try expectMasked("snmpwalk -v2c -c c0mmunaute 10.0.0.2 1.3.6.1.2.1.1", secret: "c0mmunaute", kept: "10.0.0.2")
        try expectMasked("snmpget -v3 -u admin -l authPriv -a SHA -A authPhrase1 -x AES -X privPhrase2 10.1.1.1",
                         secret: "authPhrase1", kept: "-u admin")
        try expectMasked("snmpget -v3 -u admin -l authPriv -a SHA -A authPhrase1 -x AES -X privPhrase2 10.1.1.1", secret: "privPhrase2")
    }

    suite.add("Diagnostic : masqueur, jetons isolés et faux positifs") {
        // Jeton FortiGate de 30 caractères posé seul.
        try expectMasked("Jeton refusé (HTTP 401) : 8f7Gh3kLm2Nq9Rt4Vw6Xy1Zb5Cd0E", secret: "8f7Gh3kLm2Nq9Rt4Vw6Xy1Zb5Cd0E", kept: "HTTP 401")
        // Rien de secret : messages ordinaires, adresses, MAC, UUID, empreintes, symboles Swift.
        try expectUnchanged("FortiGate fw-siege (10.182.122.1) : HTTP 403, droits insuffisants du profil d’administration")
        try expectUnchanged("SNMP : 10.0.0.2 ne répond pas (délai de 2 s, 2 essais)")
        try expectUnchanged("Adresse MAC 00:09:0F:AA:BB:CC, port 12")
        try expectUnchanged("Identifiant 6F1D3E2A-9B8C-4D7E-8F00-112233445566")
        try expectUnchanged("SHA-256 : 3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b")
        try expectUnchanged("0   NetScope  0x0000000102a4c3d0 $s8NetScope9AppStateC15detectInterfaceyyYaF + 120")
        try expectUnchanged("Les jetons sont gardés dans le Trousseau.")
        try expectUnchanged("Mot de passe de synchronisation enregistré dans le Trousseau.")
        try expectUnchanged("")
        // Idempotent : masquer deux fois donne le même texte.
        let once = SecretMasker.mask("token=abc password: x Authorization: Bearer zz")
        try expectEqual(SecretMasker.mask(once), once, "masquer deux fois ne change rien")
    }

    suite.add("Diagnostic : noms de champs secrets et adresses publiques abrégées") {
        for key in ["smtpPassword", "fortigate.jeton", "alertes.webhook.token", "snmp.communaute", "API_KEY", "githubToken"] {
            try expect(SecretMasker.isSecretKey(key), "« \(key) » est un champ secret")
        }
        for key in ["reglages.scan.threads", "tableau.journaux.tri", "sauvegarde.automatique", "langue"] {
            try expect(!SecretMasker.isSecretKey(key), "« \(key) » n’est pas un champ secret")
        }
        try expectEqual(SecretMasker.maskPublicIPv4("en0 : 192.168.1.20, WAN 203.0.113.45, DNS 8.8.8.8."),
                        "en0 : 192.168.1.20, WAN 203.0.x.x, DNS 8.8.x.x.", "adresses publiques abrégées")
        try expectEqual(SecretMasker.maskPublicIPv4("10.1.2.3 172.16.0.1 172.32.0.1 100.64.1.1 169.254.3.4 127.0.0.1"),
                        "10.1.2.3 172.16.0.1 172.32.x.x 100.64.1.1 169.254.3.4 127.0.0.1", "privées, CGNAT et lien local entières")
        try expectEqual(SecretMasker.maskPublicIPv4("version 1.2.3.4.5 et 999.1.1.1"), "version 1.2.3.4.5 et 999.1.1.1", "pas une adresse")
    }

    // MARK: Journal en mémoire

    suite.add("Diagnostic : tampon circulaire du journal") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let log = AppLog(capacity: 5)
        for index in 0..<12 {
            log.log(index % 3 == 0 ? .error : .info, "Test", "message \(index)", date: start.addingTimeInterval(Double(index)))
        }
        let entries = log.entries
        try expectEqual(entries.count, 5, "capacité respectée")
        try expectEqual(entries.map(\.message), (7..<12).map { "message \($0)" }, "les plus récentes, dans l'ordre")
        try expectEqual(log.count(atLeast: .error, since: start), 1, "une erreur parmi les 5 gardées (9)")
        try expectEqual(log.count(atLeast: .info, since: start.addingTimeInterval(10)), 2, "entrées depuis une date")
        log.clear()
        try expectEqual(log.entries.count, 0, "journal vidé")
        log.info("Test", "après")
        try expectEqual(log.entries.map(\.message), ["après"], "le tampon repart après l'effacement")
    }

    suite.add("Diagnostic : journal masqué avant mémorisation, sûr entre fils") {
        let log = AppLog(capacity: 2_000)
        let entry = log.error("FortiGate", "Réponse : {\"access_token\":\"zzSECRETzz1\"} et Authorization: Bearer q1w2e3r4")
        try expect(!entry.message.contains("zzSECRETzz1") && !entry.message.contains("q1w2e3r4"), "entrée masquée")
        try expect(!log.exportText().contains("zzSECRETzz1"), "export masqué")
        let path = log.error("Sites", "Enregistrement impossible de \(NSHomeDirectory())/Library/Application Support/NetScope/sites.json")
        try expect(path.message.contains("~/Library/Application Support") && !path.message.contains(NSHomeDirectory()),
                   "dossier de l'utilisateur abrégé en ~ (le nom du compte n'entre pas au journal)")
        let seen = LockedCounter()
        let token = log.addObserver { entry in if entry != nil { seen.increment() } }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<200 { log.warning("Fil \(worker)", "message \(index)") }
        }
        log.removeObserver(token)
        log.info("Test", "après retrait")
        try expectEqual(log.entryCount, 1_602, "toutes les entrées gardées")
        try expectEqual(seen.value, 1_600, "chaque entrée annoncée une fois aux observateurs, plus rien après le retrait")
        try expect(log.entries.allSatisfy { !$0.module.isEmpty }, "aucune entrée corrompue")
    }

    suite.add("Diagnostic : ligne du fichier, échappement et relecture") {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let entry = AppLogEntry(date: date, level: .warning, module: "Sauvegarde", message: "ligne 1\nligne 2\tavec \\ barre")
        let line = entry.fileLine
        try expect(!line.contains("\n"), "une seule ligne dans le fichier")
        guard let back = AppLogEntry(fileLine: line) else { throw TestFailure(message: "ligne relue", file: #fileID, line: #line) }
        try expectEqual(back.message, entry.message, "message rétabli")
        try expectEqual(back.level, .warning, "niveau rétabli")
        try expectEqual(back.module, "Sauvegarde", "module rétabli")
        try expect(abs(back.date.timeIntervalSince(date)) < 0.002, "date rétablie à la milliseconde")
        try expect(AppLogEntry(fileLine: "n'importe quoi") == nil, "ligne illisible ignorée")
    }

    // MARK: Fichier tournant

    suite.add("Diagnostic : fichier tournant borné à 3 fichiers") {
        let folder = temporaryFolder("journal")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = AppLogFile(directory: folder, maxBytes: 2_000, maxFiles: 3)
        let log = AppLog(capacity: 10_000, file: file)
        for index in 0..<400 { log.info("Rotation", "entrée numéro \(index) " + String(repeating: "x", count: 40)) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        try expectEqual(names, ["NetScope.1.log", "NetScope.2.log", "NetScope.log"], "trois fichiers au plus")
        try expect(file.totalBytes <= 3 * 2_000, "taille totale bornée — \(file.totalBytes) octets")
        for url in file.existingFiles {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            try expect(size <= 2_000, "\(url.lastPathComponent) sous la limite — \(size) octets")
        }
        let reread = file.readEntries()
        try expectEqual(reread.last?.message.hasPrefix("entrée numéro 399"), true, "la dernière entrée est dans le fichier courant")
        try expect(reread.count < 400 && reread.count > 20, "les plus vieilles entrées sont parties avec le plus vieux fichier")
        let numbers = reread.compactMap { Int($0.message.split(separator: " ")[2]) }
        try expectEqual(numbers, numbers.sorted(), "ordre chronologique d'un fichier à l'autre")
        // Un nouveau journal branché sur ces fichiers retrouve les entrées d'avant.
        let restarted = AppLog(capacity: 20)
        restarted.configure(file: file)
        try expectEqual(restarted.entries.count, 20, "dernières entrées rechargées au lancement")
        try expectEqual(restarted.entries.last?.message.hasPrefix("entrée numéro 399"), true, "jusqu'à la plus récente")
        restarted.clear()
        try expectEqual(file.existingFiles.count, 0, "« Effacer le journal » supprime les fichiers")
    }

    suite.add("Diagnostic : aucun secret n'atteint le fichier") {
        let folder = temporaryFolder("journal-secret")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = AppLogFile(directory: folder)
        let log = AppLog(file: file)
        log.error("SMTP", "AUTH refusé pour alertes@exemple.com, password=Hiver2026!")
        log.error("FortiGate", "GET https://fw/api/v2/monitor?access_token=Tok3nFG12345 : HTTP 401")
        let text = (try? String(contentsOf: file.url(0), encoding: .utf8)) ?? ""
        try expect(text.contains("AUTH refusé"), "message écrit")
        try expect(!text.contains("Hiver2026!") && !text.contains("Tok3nFG12345"), "secrets absents du fichier")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.url(0).path)[.posixPermissions] as? NSNumber)?.intValue
        try expectEqual(mode, 0o600, "fichier lisible par l'utilisateur seulement")
    }

    // MARK: Rapports de plantage

    suite.add("Diagnostic : rapports de plantage, nom, en-tête et fenêtre de 30 jours") {
        try expect(CrashReports.isNetScopeReport("NetScope-2026-11-04-142231.ips"), "rapport de NetScope")
        try expect(!CrashReports.isNetScopeReport("NetScopeSelfTest-2026-11-04-142231.ips"), "pas celui des tests")
        try expect(!CrashReports.isNetScopeReport("NetScope-2026-11-04-142231.crash"), "extension .ips seulement")
        try expect(!CrashReports.isNetScopeReport("Safari-2026-11-04.ips"), "autre app")

        let folder = temporaryFolder("plantages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let header = #"{"app_name":"NetScope","timestamp":"2026-11-04 14:22:31.00 -0500","app_version":"0.22.0","os_version":"macOS 26.1 (25B78)","name":"NetScope"}"#
        let body = #"{"exception" : {"codes":"0x1","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"threads":[]}"#
        try (header + "\n" + body).write(to: folder.appendingPathComponent("NetScope-2026-11-04-142231.ips"), atomically: true, encoding: .utf8)
        let old = #"{"app_name":"NetScope","timestamp":"2026-09-01 08:00:00.00 -0400","app_version":"0.18.0"}"#
        try (old + "\n{}").write(to: folder.appendingPathComponent("NetScope-2026-09-01-080000.ips"), atomically: true, encoding: .utf8)
        try "illisible".write(to: folder.appendingPathComponent("NetScope-sans-entete.ips"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appendingPathComponent("Mail-2026-11-04.ips"), atomically: true, encoding: .utf8)

        let now = CrashReports.parseTimestamp("2026-11-05 10:00:00.00 -0500")!
        let reports = CrashReports.find(in: folder, since: now.addingTimeInterval(-CrashReports.defaultWindow), now: now)
        try expectEqual(reports.map(\.fileName).filter { $0 != "NetScope-sans-entete.ips" }, ["NetScope-2026-11-04-142231.ips"],
                        "seuls les rapports de NetScope des 30 derniers jours")
        let first = reports.first { $0.fileName == "NetScope-2026-11-04-142231.ips" }
        try expectEqual(first?.appVersion, "0.22.0", "version lue")
        try expectEqual(first?.exception, "EXC_BAD_ACCESS (SIGSEGV)", "exception lue")
        try expectEqual(first?.date, CrashReports.parseTimestamp("2026-11-04 14:22:31.00 -0500"), "heure de l'en-tête")
        // Plus récent que le dernier vu : seul celui d'après.
        let unseen = CrashReports.find(in: folder, since: CrashReports.parseTimestamp("2026-11-04 15:00:00.00 -0500")!, now: now)
        try expect(!unseen.contains { $0.fileName == "NetScope-2026-11-04-142231.ips" }, "rapport déjà vu écarté")
        try expectEqual(CrashReports.find(in: folder.appendingPathComponent("absent"), since: .distantPast).count, 0, "dossier absent : aucun rapport")
    }

    // MARK: Archive

    suite.add("Diagnostic : contenu du zip, aucun secret connu dedans") {
        let secrets = ["Hk8s9d0fNq3wz1x7pQ5r2t4y6u8i0o", "Hiver2026!", "c0mmunauteSecrete", "sk_live_ABC987", "ghp_Zz11Yy22Xx33",
                       "privPhrase77", "motDePasseSMTP", "webhookTok99"]
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let log = AppLog(capacity: 100)
        // Entrées « brutes » telles qu'un module distrait pourrait les écrire.
        let raw = [
            AppLogEntry(date: date, level: .error, module: "FortiGate", message: "GET /api/v2/monitor?access_token=\(secrets[0]) : HTTP 403"),
            AppLogEntry(date: date, level: .error, module: "SSH", message: "mot de passe : \(secrets[1]) refusé"),
            AppLogEntry(date: date, level: .warning, module: "SNMP", message: "snmpwalk -v2c -c \(secrets[2]) 10.0.0.2"),
            AppLogEntry(date: date, level: .info, module: "Mises à jour", message: "Authorization: token \(secrets[4])"),
        ]
        log.seed(raw)
        let crash = #"{"app_name":"NetScope","timestamp":"2026-11-04 14:22:31.00 -0500"}"# + "\n"
            + #"{"exception":{"type":"EXC_CRASH"},"env":"API_KEY=\#(secrets[3])","asi":{"x":["snmp -X \#(secrets[5])"]}}"#
        let input = DiagnosticInput(
            generatedAt: date, appVersion: "0.23.0", build: "230", macOSVersion: "macOS 26.1 (25B78)", macModel: "Mac16,10",
            processorCount: 10, memoryBytes: 16 * 1_073_741_824, uptime: 3 * 86_400 + 7_200,
            interfaces: [.init(name: "en0", kind: "Wi-Fi", address: "10.182.122.135", netmask: "255.255.255.0", gateway: "10.182.122.1"),
                         .init(name: "utun4", kind: "VPN", address: "203.0.113.77", netmask: "255.255.255.255")],
            sites: [.init(name: "Siège social", ranges: ["10.182.122.0/24"], fortiGateCount: 1, switchCount: 2, isActive: true)],
            settings: ["reglages.scan.threads": "128", "alertes.smtp.password": secrets[6], "alertes.webhook.url": "https://hooks.exemple.com/x?token=\(secrets[7])",
                       "fortigate.jeton.fw1": secrets[0]],
            logEntries: log.entries + raw,
            crashReports: [.init(name: "NetScope-2026-11-04-142231.ips", data: Data(crash.utf8))])
        let data = DiagnosticBundle.archive(input)
        let entries = try BackupZip.entries(of: data)
        try expectEqual(entries.map(\.path).sorted(),
                        ["LISEZMOI.txt", "journal.txt", "plantages/NetScope-2026-11-04-142231.ips", "reglages.json", "sites.json", "systeme.txt"],
                        "fichiers de l'archive")
        // Recherche de chaque secret dans l'archive entière (octets bruts) et dans chaque fichier.
        let whole = String(decoding: data, as: UTF8.self)
        for secret in secrets {
            try expect(!whole.contains(secret), "le secret « \(secret) » ne doit pas être dans l'archive")
        }
        func text(_ path: String) -> String { String(decoding: entries.first { $0.path == path }?.data ?? Data(), as: UTF8.self) }
        let system = text("systeme.txt")
        try expect(system.contains("0.23.0") && system.contains("Mac16,10") && system.contains("macOS 26.1"), "résumé système")
        try expect(system.contains("10.182.122.135") && system.contains("203.0.x.x") && !system.contains("203.0.113.77"),
                   "adresse privée entière, publique abrégée")
        try expect(text("journal.txt").contains("HTTP 403") && text("journal.txt").contains("[FortiGate]"), "journal présent")
        let settings = text("reglages.json")
        try expect(settings.contains("reglages.scan.threads") && !settings.contains("alertes.smtp.password") && !settings.contains("fortigate.jeton"),
                   "réglages non secrets seulement")
        try expect(text("sites.json").contains("Siège social") && text("sites.json").contains("10.182.122.0/24"), "sites et plages")
        try expect(text("plantages/NetScope-2026-11-04-142231.ips").contains("EXC_CRASH"), "rapport de plantage joint")
        try expectEqual(DiagnosticBundle.suggestedFileName(CrashReports.parseTimestamp("2026-11-05 14:02:00.00 -0500")!).hasPrefix("NetScope-diagnostic-2026-11-05"),
                        true, "nom de fichier proposé")
    }

    suite.add("Diagnostic : rapports de plantage limités en nombre et en taille") {
        let big = Data(repeating: UInt8(ascii: "a"), count: DiagnosticBundle.maxCrashBytes + 5_000)
        let crashes = (0..<14).map { DiagnosticInput.CrashFile(name: "NetScope-\($0).ips", data: $0 == 0 ? big : Data("{}".utf8)) }
        let input = DiagnosticInput(appVersion: "0.23.0", build: "1", macOSVersion: "macOS", macModel: "Mac", crashReports: crashes)
        let entries = DiagnosticBundle.entries(input)
        let reports = entries.filter { $0.path.hasPrefix("plantages/") }
        try expectEqual(reports.count, DiagnosticBundle.maxCrashReports, "dix rapports au plus")
        let first = reports.first { $0.path == "plantages/NetScope-0.ips" }
        try expect((first?.data.count ?? 0) < DiagnosticBundle.maxCrashBytes + 200, "gros rapport tronqué")
    }
}

/// Compteur partagé entre fils (observateurs du journal).
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
