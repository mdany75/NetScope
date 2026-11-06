import Foundation
import NetScopeCore

// Note 87 (0.33.0) : serveur RustDesk en lecture — santé, clé, mises à jour, versions, journaux,
// sauvegarde chiffrée, historique, rapport, tentatives suspectes, association, alertes. Textes
// fixes et valeurs fictives seulement ; aucun ssh, aucun accès en ligne.

func registerRustDeskServerWatchTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    suite.add("Serveur RustDesk : santé, clé publique, conteneurs et images lus dans la sortie") {
        let output = """
        @@NETSCOPE META@@
        hote=rustdesk-01
        @@NETSCOPE SANTE@@
        uptime=3542400.17
        charge=0.18 0.22 0.19
        cpus=2
        MemTotal:4014080
        MemAvailable:2861220
        cpu1=cpu  1000 0 500 8000 100 0 0 0 0 0
        cpu2=cpu  1030 0 510 8150 10 0 0 0 0 0
        @@NETSCOPE CLE@@
        cle=Zm9yLWRlbW8tb25seS1ub3QtYS1yZWFsLWtleS0wMDA=
        @@NETSCOPE INSPECT@@
        /hbbs|0|2026-11-03T08:12:44.123456789Z|rustdesk/rustdesk-server:latest|sha256:4b1d
        /hbbr|2|2026-11-03T08:12:45Z|rustdesk/rustdesk-server:latest|sha256:4b1d
        @@NETSCOPE IMAGES@@
        sha256:4b1d|rustdesk/rustdesk-server@sha256:aaaa1111 autre/image@sha256:bbbb
        @@NETSCOPE FIN@@
        """
        let status = RustDeskServerOutput.parse(output, readAt: now)
        let health = try unwrap(status.health, "santé lue")
        try expectEqual(health.uptimeSeconds, 3_542_400, "durée de fonctionnement")
        try expectEqual(health.cpus, 2, "cœurs")
        try expectEqual(health.load, [0.18, 0.22, 0.19], "charge")
        // Δtotal = 30 + 10 + 150 - 90 = 100 ; Δinactif = 150 - 90 = 60 → 40 % occupé.
        try expectEqual(health.cpuPercent.map { Int($0.rounded()) }, 40, "processeur")
        try expectEqual(health.memoryUsedFraction.map { Int(($0 * 100).rounded()) }, 29, "mémoire")
        try expectEqual(status.publicKey, .key("Zm9yLWRlbW8tb25seS1ub3QtYS1yZWFsLWtleS0wMDA="), "clé publique")
        try expectEqual(status.containerDetails.map(\.name), ["hbbs", "hbbr"], "conteneurs inspectés")
        try expectEqual(status.containerDetails.map(\.restartCount), [0, 2], "redémarrages")
        try expect(status.containerDetails[0].startedAt != nil, "date à nanosecondes lue")
        try expectEqual(status.images.first?.digest(), "sha256:aaaa1111", "empreinte du dépôt rustdesk-server")
        try expectEqual(RustDeskServerOutput.parse("@@NETSCOPE CLE@@\nETAT illisible\n", readAt: now).publicKey, .unreadable, "clé illisible")
        try expectEqual(RustDeskServerOutput.parse("@@NETSCOPE CLE@@\ncle=pas une clé; rm\n", readAt: now).publicKey, .unknown, "clé suspecte écartée")
    }

    suite.add("Serveur RustDesk : mises à jour apt et dnf, redémarrage requis, version de hbbs") {
        let apt = """
        @@NETSCOPE ACCES@@
        SUDO ok
        @@NETSCOPE MAJ@@
        GESTIONNAIRE apt
        listes=1793990000
        openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
        openssh-server/noble-security 1:9.6p1-3ubuntu13.6 amd64 [upgradable from: 1:9.6p1-3ubuntu13.5]
        tzdata/noble-updates 2026b-0ubuntu0.24.04 all [upgradable from: 2026a-0ubuntu0.24.04]
        @@NETSCOPE REDEMARRAGE@@
        requis
        linux-image-6.17.0-8-generic
        @@NETSCOPE VERSION@@
        hbbs 1.1.14
        @@NETSCOPE FIN@@
        """
        let detail = RustDeskServerReading.parse(apt, readAt: now)
        try expectEqual(detail.sudo, "ok", "sudo accepté")
        let updates = try unwrap(detail.updates, "mises à jour lues")
        try expectEqual(updates.packages, ["openssl", "openssh-server", "tzdata"], "paquets")
        try expectEqual(updates.security, ["openssl", "openssh-server"], "sécurité")
        try expect(updates.rebootRequired, "redémarrage requis")
        try expectEqual(updates.rebootPackages, ["linux-image-6.17.0-8-generic"], "paquet qui le demande")
        try expect(updates.listsDate != nil, "date des listes")
        try expectEqual(detail.hbbsVersion, "1.1.14", "hbbs --version")

        let dnf = """
        @@NETSCOPE MAJ@@
        GESTIONNAIRE dnf
        openssl.x86_64          1:3.2.2-1.fc41      updates
        kernel.x86_64           6.12.4-200.fc41     updates
        SECURITE
        FEDORA-2026-1234 Important/Sec. openssl-1:3.2.2-1.fc41.x86_64
        FEDORA-2026-9999 Moderate/Sec. absent-1.0-1.fc41.x86_64
        @@NETSCOPE REDEMARRAGE@@
        non
        """
        let other = try unwrap(RustDeskServerReading.parse(dnf, readAt: now).updates, "dnf lu")
        try expectEqual(other.packages, ["openssl", "kernel"], "paquets dnf")
        try expectEqual(other.security, ["openssl"], "sécurité dnf (seulement les paquets à mettre à jour)")
        try expect(!other.rebootRequired, "pas de redémarrage")
    }

    suite.add("Serveur RustDesk : versions publiées (Docker Hub, GitHub) et ce qu'il y a à faire") {
        try expectEqual(RustDeskVersionCheck.compare("1.1.9", "1.1.14"), .orderedAscending, "1.1.9 < 1.1.14")
        try expectEqual(RustDeskVersionCheck.compare("v1.4.3", "1.4.3"), .orderedSame, "préfixe v")
        try expectEqual(RustDeskVersionCheck.compare("1.2", "1.1.99"), .orderedDescending, "1.2 > 1.1.99")
        try expect(RustDeskVersionCheck.compare("latest", "1.0") == nil, "étiquette sans numéro")
        try expectEqual(RustDeskVersionCheck.gitHubTag(Data(#"{"tag_name":"1.1.15","name":"x"}"#.utf8)), "1.1.15", "GitHub")
        try expectEqual(RustDeskVersionCheck.dockerHubDigest(Data(#"{"name":"latest","digest":"sha256:abc123"}"#.utf8)), "sha256:abc123", "Docker Hub")
        try expect(RustDeskVersionCheck.dockerHubDigest(Data("pas du json".utf8)) == nil, "réponse illisible")
        try expect(RustDeskVersionCheck.isDue(lastCheck: nil, now: now), "jamais vérifié")
        try expect(!RustDeskVersionCheck.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now), "une fois par jour")
        try expect(RustDeskVersionCheck.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now), "plus d'un jour")

        let published = RustDeskPublishedVersions(checkedAt: now, server: "1.1.15", hubDigest: "sha256:new", client: "1.4.4")
        let updates = RustDeskSystemUpdates(manager: "apt", packages: ["openssl", "tzdata"], security: ["openssl"], rebootRequired: true)
        let findings = RustDeskUpdateAssessment.findings(installed: "1.1.14", localDigests: ["sha256:old"], published: published,
                                                         updates: updates, clientVersion: "1.4.2")
        try expectEqual(findings.map(\.title), ["RustDesk Server 1.1.15 disponible", "1 correctif de sécurité à installer",
                                                "Redémarrage requis", "Client RustDesk 1.4.4 disponible"], "constats")
        let digestOnly = RustDeskUpdateAssessment.findings(installed: nil, localDigests: ["sha256:old"], published: published,
                                                           updates: nil, clientVersion: nil)
        try expectEqual(digestOnly.map(\.title), ["Nouvelle image «\u{00A0}latest\u{00A0}» sur Docker Hub"], "image latest changée")
        let upToDate = RustDeskUpdateAssessment.findings(installed: "1.1.15", localDigests: ["sha256:new"], published: published,
                                                         updates: RustDeskSystemUpdates(manager: "apt"), clientVersion: "1.4.4")
        try expect(upToDate.isEmpty, "tout est à jour")
    }

    suite.add("Serveur RustDesk : scripts à la demande en lecture seule (sudo par l'entrée, jamais en argument)") {
        for script in [RustDeskServerDetailScript.details, RustDeskServerDetailScript.logs, RustDeskServerDetailScript.backup] {
            for word in RustDeskServerDetailScript.forbiddenWords {
                try expect(!script.contains(word), "le script ne contient pas « \(word) »")
            }
            // Aucune redirection vers un fichier : seulement /dev/null et 2>&1.
            let redirections = script.replacingOccurrences(of: "2>/dev/null", with: "").replacingOccurrences(of: ">/dev/null", with: "")
                .replacingOccurrences(of: "</dev/null", with: "").replacingOccurrences(of: "2>&1", with: "")
            try expect(!redirections.contains(">"), "aucune écriture sur le serveur")
            try expect(script.contains("sudo -k -S -p ''"), "sudo redemandé à chaque commande, sans invite")
            try expect(script.contains("NETSCOPE_MDP=\n"), "mot de passe oublié à la fin")
        }
        try expect(!RustDeskServerDetailScript.details.contains("id_ed25519 "), "clé privée jamais lue par les détails")
        try expect(RustDeskServerDetailScript.remoteCommand.contains("read -r NETSCOPE_MDP"), "mot de passe lu sur l'entrée")
        let account = RustDeskServerAccount(user: "admin", host: "assistance.exemple.ca")
        let args = RustDeskServerSSH.arguments(account, command: RustDeskServerDetailScript.remoteCommand)
        try expectEqual(args.last, RustDeskServerDetailScript.remoteCommand, "commande distante fixe")
        try expect(!args.joined(separator: " ").contains("MotDePasse"), "aucun secret dans les arguments")
    }

    suite.add("Serveur RustDesk : journaux de hbbs et hbbr, recherche et filtre par ID") {
        let output = """
        @@NETSCOPE JOURNAL_hbbs@@
        2026-11-06T13:02:11.123456789Z [2026-11-06 13:02:11.123 +00:00] INFO [src/rendezvous_server.rs:1205] punch hole request from 10.0.0.5 to 184352907
        2026-11-06T13:05:00Z [2026-11-06 13:05:00.000 +00:00] WARN [src/peer.rs:10] update_pk 263 418 095
        @@NETSCOPE JOURNAL_hbbr@@
        2026-11-06T13:03:00Z [2026-11-06 13:03:00.000 +00:00] INFO [src/relay_server.rs:460] New relay request 5f1c
        @@NETSCOPE FIN@@
        """
        let lines = RustDeskLogLine.parse(output)
        try expectEqual(lines.map(\.service), ["hbbs", "hbbr", "hbbs"], "triées par date")
        try expectEqual(lines.map(\.level), ["INFO", "INFO", "WARN"], "niveaux")
        try expectEqual(RustDeskLogLine.filter(lines, search: "", id: "184 352 907").count, 1, "filtre par ID")
        try expectEqual(RustDeskLogLine.filter(lines, search: "", id: "263418095").count, 1, "ID écrit avec espaces dans le journal")
        try expectEqual(RustDeskLogLine.filter(lines, search: "RELAY", id: "").map(\.service), ["hbbr"], "recherche sans casse")
    }

    suite.add("Serveur RustDesk : copie du dossier de données décodée et chiffrée (AES-GCM)") {
        let gzip = Data([0x1f, 0x8b, 0x08, 0x00] + Array(repeating: UInt8(7), count: 40))
        let output = "@@NETSCOPE DOSSIER@@\n/opt/rustdesk/data\n@@NETSCOPE ARCHIVE@@\n" + gzip.base64EncodedString(options: .lineLength64Characters) + "\n@@NETSCOPE FIN@@\n"
        let archive = try unwrap(RustDeskBackupArchive.decode(output), "archive décodée")
        try expectEqual(archive.folder, "/opt/rustdesk/data", "dossier")
        try expectEqual(archive.archive, gzip, "contenu")
        try expect(RustDeskBackupArchive.decode("@@NETSCOPE ARCHIVE@@\nbm9uLWd6aXA=\n") == nil, "pas un tar.gz : refusé")
        let key = RustDeskBackupCrypto.newKey()
        let sealed = try RustDeskBackupCrypto.seal(gzip, key: key)
        try expect(sealed.range(of: gzip) == nil, "chiffré")
        try expectEqual(try RustDeskBackupCrypto.open(sealed, key: key), gzip, "relu avec la clé")
        try expect((try? RustDeskBackupCrypto.open(sealed, key: RustDeskBackupCrypto.newKey())) == nil, "autre clé refusée")
        try expect(RustDeskBackupCrypto.fileName(now).hasSuffix(".tar.gz.chiffre"), "nom du fichier")
        try expect(RustDeskServerAlerts.backupDue(last: nil, now: now), "aucune copie : à faire")
        try expect(!RustDeskServerAlerts.backupDue(last: now.addingTimeInterval(-86_400), now: now), "copie d'hier : récente")
        try expect(RustDeskServerAlerts.backupDue(last: now.addingTimeInterval(-8 * 86_400), now: now), "8 jours : à refaire")
    }

    suite.add("Serveur RustDesk : historique jour après jour, rapport mensuel et CSV") {
        func request(_ minutes: Double, _ from: String, _ id: String) -> RustDeskPunchRequest {
            RustDeskPunchRequest(id: 0, date: now.addingTimeInterval(-minutes * 60), fromIP: from, targetID: id, targetIP: "192.0.2.1")
        }
        var history = RustDeskRequestArchive.merge([], adding: [request(10, "198.51.100.1", "184352907"), request(20, "198.51.100.2", "184352907")], now: now)
        // hbbs redémarré : la même demande relue n'est pas doublée, la nouvelle s'ajoute.
        history = RustDeskRequestArchive.merge(history, adding: [request(10, "198.51.100.1", "184352907"), request(5, "198.51.100.1", "263418095")], now: now)
        try expectEqual(history.count, 3, "sans doublon")
        try expect(history.map(\.date) == history.map(\.date).sorted(), "ordre chronologique")
        let old = RustDeskArchivedRequest(date: now.addingTimeInterval(-500 * 86_400), fromIP: "x", targetID: "1", targetIP: "y")
        try expectEqual(RustDeskRequestArchive.merge([old], adding: [], now: now).count, 0, "plus de 400 jours : retirée")

        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone(identifier: "America/Toronto")!, from: now)
        var toronto = calendar
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        let report = RustDeskMonthlyReport.build(history, year: parts.year!, month: parts.month!, calendar: toronto,
                                                 name: { $0 == "184352907" ? "Poste; réception" : nil },
                                                 technician: { $0 == "198.51.100.1" ? "Marc" : nil })
        try expectEqual(report.total, 3, "trois demandes")
        try expectEqual(report.stations.first?.targetID, "184352907", "poste le plus demandé d'abord")
        try expectEqual(report.stations.first?.technicians, 2, "deux techniciens")
        try expectEqual(report.technicians.first?.label, "Marc", "nom du technicien")
        let csv = report.csv()
        try expect(csv.contains("\"Poste; réception\";184352907;2;2;"), "cellule avec « ; » entre guillemets")
        try expect(csv.contains("Marc;198.51.100.1;2;2;"), "ligne du technicien")
        try expectEqual(RustDeskMonthlyReport.months(history, calendar: toronto).count, 1, "un mois")
    }

    suite.add("Serveur RustDesk : tentatives suspectes (hors carnet, rafale, refus de la FortiGate)") {
        var requests: [RustDeskArchivedRequest] = []
        for index in 0..<9 {
            requests.append(RustDeskArchivedRequest(date: now.addingTimeInterval(-3_600 + Double(index * 20)), fromIP: "203.0.113.201",
                                                    targetID: String(400_000_000 + index), targetIP: "192.0.2.88"))
        }
        requests.append(RustDeskArchivedRequest(date: now.addingTimeInterval(-600), fromIP: "198.51.100.37", targetID: "184352907", targetIP: "10.0.0.5"))
        var message = LogMessage(date: now.addingTimeInterval(-300), source: .syslog, severity: .warning, host: "192.0.2.1",
                                 message: "trafic refusé", siteKey: "siege", siteName: "Siège")
        message.fields = ["dstport": "21116", "action": "deny", "srcip": "198.51.100.211", "srccountry": "Pays filtré"]
        var other = message
        other.fields["dstport"] = "443"
        let denied = [message, other].compactMap { RustDeskDeniedAttempt.from($0) }
        try expectEqual(denied.count, 1, "seul le port RustDesk compte")
        let events = RustDeskSuspicion.evaluate(requests: requests, known: ["184352907"], denied: denied, since: now.addingTimeInterval(-86_400))
        try expectEqual(events.first?.kind, .burst, "rafale d'abord")
        try expectEqual(events.first?.key, "203.0.113.201", "IP de la rafale")
        try expect(events.contains { $0.kind == .firewallDenied && $0.key == "198.51.100.211" && $0.detail.contains("Pays filtré") }, "refus FortiGate")
        try expect(events.first?.detail.contains("dont 9 hors carnet") == true, "ID hors carnet comptés dans la rafale")
        try expectEqual(events.filter { $0.kind == .unknownID }.count, 0, "pas une ligne par ID de la rafale")
        let alone = RustDeskSuspicion.evaluate(requests: [RustDeskArchivedRequest(date: now, fromIP: "198.51.100.37", targetID: "555666777", targetIP: "x")],
                                               known: [], denied: [], since: now.addingTimeInterval(-60))
        try expectEqual(alone.map(\.kind), [.unknownID], "ID hors carnet isolé")
        try expect(!events.contains { $0.key == "184352907" }, "ID connu : rien")
    }

    suite.add("Serveur RustDesk : site probable et association proposée (l'IP seule ne tranche jamais)") {
        let wan: [(site: String, ip: String)] = [("Siège", "203.0.113.58"), ("Laval", "203.0.113.90"), ("A", "203.0.113.7"), ("B", "203.0.113.7")]
        try expectEqual(RustDeskSiteHint.site(for: "203.0.113.58", wan: wan), "Siège", "WAN connu")
        try expect(RustDeskSiteHint.site(for: "203.0.113.7", wan: wan) == nil, "IP partagée par deux sites : aucun site")
        try expect(RustDeskSiteHint.isPrivate("10.1.2.3") && RustDeskSiteHint.isPrivate("172.20.0.1") && !RustDeskSiteHint.isPrivate("203.0.113.58"), "adresses privées")
        let server = "192.0.2.10"
        let sessions = [
            TrafficSession(site: "Siège", source: IPv4Address("10.182.122.113"), destination: IPv4Address(server), destinationPort: 21117, proto: "TCP", serial: "1"),
            TrafficSession(site: "Siège", source: IPv4Address("10.182.122.152"), destination: IPv4Address(server), destinationPort: 21116, proto: "UDP", serial: "2"),
            TrafficSession(site: "Siège", source: IPv4Address("10.182.122.160"), destination: IPv4Address("192.0.2.99"), destinationPort: 21116, proto: "UDP", serial: "3"),
            TrafficSession(site: "Laval", source: IPv4Address("10.20.0.5"), destination: IPv4Address(server), destinationPort: 21116, proto: "UDP", serial: "4"),
        ]
        let found = RustDeskAssociation.candidates(targetIP: "203.0.113.58", serverIPs: [server], wan: wan, sessions: sessions) { ip, site in
            site == "Siège" && ip == "10.182.122.113" ? ("3C:52:82:4A:19:E7", "Portable Marc") : nil
        }
        try expectEqual(found.map(\.ip), ["10.182.122.113", "10.182.122.152"], "postes du site qui parlent au serveur, relais d'abord")
        try expect(found[0].relay && found[0].mac != nil, "session relayée, MAC trouvée")
        try expect(found[1].mac == nil, "sans fiche : pas de MAC inventée")
        try expect(RustDeskAssociation.candidates(targetIP: "203.0.113.7", serverIPs: [server], wan: wan, sessions: sessions) { _, _ in nil }.isEmpty,
                   "site ambigu : aucune proposition")
        let local = RustDeskAssociation.candidates(targetIP: "10.182.122.146", serverIPs: [server], wan: wan, sessions: []) { ip, site in
            site == nil ? ("00:11:22:33:44:55", "Poste réception") : nil
        }
        try expectEqual(local.map(\.name), ["Poste réception"], "IP privée : poste du dernier scan")
    }

    suite.add("Serveur RustDesk : noms et notes par ID, fichier du suivi tolérant") {
        let notes = ["184352907": RustDeskIDNote(name: "Kiosque", note: "quai 3", updatedAt: now)]
        try expectEqual(RustDeskNames.resolve("184 352 907", notes: notes, book: ["184352907": "WKS"], inventory: [:])?.name, "Kiosque", "nom donné d'abord")
        try expectEqual(RustDeskNames.resolve("263418095", notes: notes, book: [:], inventory: ["263418095": "Portable Marc"])?.source, .inventory, "fiche d'inventaire")
        try expect(RustDeskNames.resolve("192.168.1.10", notes: ["192168110": RustDeskIDNote(name: "x")], book: [:], inventory: [:]) == nil,
                   "une IP n'est jamais prise pour un ID")
        let decoded = try JSONDecoder().decode(RustDeskWatchStore.Contents.self, from: Data(#"{"version":1,"monitoredPorts":[21116,0,99999],"inconnu":true}"#.utf8))
        try expectEqual(decoded.monitoredPorts, [21116], "ports invalides écartés")
        try expect(decoded.notes.isEmpty && decoded.history.isEmpty, "champs absents : valeurs par défaut")
        var contents = RustDeskWatchStore.Contents()
        contents.observeKey("CLE1", now: now)
        try expectEqual(contents.knownKey, "CLE1", "première clé retenue")
        contents.observeKey("CLE2", now: now)
        try expectEqual(contents.knownKey, "CLE1", "clé connue gardée")
        try expect(contents.keyChangedAt != nil, "changement noté")
        try expectEqual(RustDeskServerAlerts.ports("21115, 21116 21117;21116 abc"), [21115, 21116, 21117], "ports saisis")
    }

    suite.add("Serveur RustDesk : sonde de Surveillance (hbbs, hbbr, disque, clé changée)") {
        var status = RustDeskServerStatus(readAt: now, hbbs: RustDeskServerProcess(name: "hbbs", pid: 1, seconds: 10, arguments: ""),
                                          hbbr: RustDeskServerProcess(name: "hbbr", pid: 2, seconds: 10, arguments: ""),
                                          disk: RustDeskDiskUsage(mount: "/", totalKB: 100, usedKB: 50, availableKB: 50))
        status.publicKey = .key("CLE1")
        var probe = MonProbe(name: "Serveur RustDesk", kind: .rustdeskServer, target: "admin@assistance.exemple.ca", interval: 300)
        let first = MonRustDeskChecks.evaluate(.success(status), probe: probe, now: now)
        try expect(first.result.problem == nil, "tout va bien")
        try expectEqual(first.knownThreats, ["cle:CLE1"], "clé retenue au premier passage")
        probe.knownThreats = first.knownThreats
        status.hbbr = nil
        status.disk = RustDeskDiskUsage(mount: "/", totalKB: 100, usedKB: 95, availableKB: 5)
        status.publicKey = .key("CLE2")
        let second = MonRustDeskChecks.evaluate(.success(status), probe: probe, now: now)
        try expectEqual(second.result.problem, "hbbr arrêté, disque à 95\u{00A0}%, clé publique changée", "trois problèmes")
        let failed = MonRustDeskChecks.evaluate(.failure(RustDeskServerReadError(kind: .timeout, detail: "")), probe: probe, now: now)
        try expect(!failed.result.reachable, "lecture impossible : panne")
        try expect(MonBackground.supportedKinds.contains(.rustdeskServer), "exécutée aussi par l'agent")
    }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        try expect(false, message)
        throw CocoaError(.featureUnsupported)
    }
    return value
}
