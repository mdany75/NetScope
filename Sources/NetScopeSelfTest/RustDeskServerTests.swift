import Foundation
import NetScopeCore

// Note 6 (suite, 0.26.2) : tableau de bord du serveur RustDesk. Sorties fixes et réalistes du
// script de collecte (valeurs fictives) ; aucun ssh n'est lancé, aucun réseau.

func registerRustDeskServerTests(_ suite: TestSuite) {
    let readAt = Date(timeIntervalSince1970: 1_793_890_000) // 5 novembre 2026, vers 9 h 46 (UTC-5)

    /// Sortie complète d'un serveur Docker en network_mode: host, compte dans le groupe docker.
    let full = """
    Welcome to Ubuntu 26.04 LTS

    @@NETSCOPE META@@
    hote=rustdesk-01
    utilisateur=admin
    heure=1793890002
    systeme=Ubuntu 26.04 LTS
    client=nc

    @@NETSCOPE PROCESSUS@@
     259321    1873 hbbs            hbbs -r assistance.exemple.ca:21117 -k _
     259320    1902 hbbr            hbbr -k CleSecreteNePasAfficher

    @@NETSCOPE DOCKER@@
    hbbs\trustdesk/rustdesk-server:1.1.16\tUp 3 days
    hbbr\trustdesk/rustdesk-server:1.1.16\tUp 3 days

    @@NETSCOPE PAQUETS@@

    @@NETSCOPE DISQUE@@
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/sda2         61611820 21564137  36882651      37% /
    du=4120

    @@NETSCOPE SAUVEGARDE@@
    1793836800.0000000000\t1843\t/opt/rustdesk/backup/rustdesk-2026-11-05.tar.gz

    @@NETSCOPE POSTES@@
    ETAT ok
    31

    @@NETSCOPE HBBR_U@@
    203.0.113.77:52114: 1260s 182.40MB 9120kb/s 1185kb/s 2410kb/s
    198.51.100.24:61002: 95s 6.12MB 1650kb/s 540kb/s 380kb/s
    @@STATUT 0@@

    @@NETSCOPE HBBR_TB@@
    1024Mb/s
    @@STATUT 0@@

    @@NETSCOPE HBBR_SB@@
    16Mb/s
    @@STATUT 0@@

    @@NETSCOPE HBBS_AIDE@@
    relay-servers(rs) <separated by ,>
    reload-geo(rg)
    ip-blocker(ib) [<ip>|<number>] [-]
    ip-changes(ic) [<id>|<number>] [-]
    punch-requests(pr) [<number>] [-]
    always-use-relay(aur)
    test-geo(tg) <ip1> <ip2>
    @@STATUT 0@@

    @@NETSCOPE HBBS_RS@@
    assistance.exemple.ca:21117
    @@STATUT 0@@

    @@NETSCOPE HBBS_NOMBRE@@
    4

    @@NETSCOPE HBBS_PR@@
    2026-11-04T09:10:44Z 192.0.2.14 -> 263418095@198.51.100.24
    2026-11-05T14:24:50Z 192.0.2.14 -> 184352907@203.0.113.77
    2026-11-05T14:44:30Z 192.0.2.14 -> 263418095@198.51.100.24
    2026-11-05T14:45:01Z 10.182.122.135 -> 1027554318@203.0.113.90

    @@NETSCOPE FIN@@
    """.replacingOccurrences(of: "\\t", with: "\t")

    suite.add("Serveur RustDesk : liste blanche des commandes de console (lecture seule)") {
        for command in ["u", "tb", "sb"] {
            try expect(RustDeskConsoleCommand.isAllowed(port: 21117, command: command), "hbbr « \(command) » permis")
        }
        for command in ["h", "rs", "pr 0 1", "pr 120 100", "pr 0 50"] {
            try expect(RustDeskConsoleCommand.isAllowed(port: 21115, command: command), "hbbs « \(command) » permis")
        }
        let forbiddenRelay = ["ba 1.2.3.4", "br all", "Ba 1.2.3.4", "Br all", "b", "B", "dt 2", "t 30", "ls 10", "tb 10",
                              "sb 5", "u ", " u", "u;rm", "h", ""]
        for command in forbiddenRelay {
            try expect(!RustDeskConsoleCommand.isAllowed(port: 21117, command: command), "hbbr « \(command) » refusé")
        }
        let forbiddenID = ["pr -", "pr 0 -", "pr - 1", "pr", "pr 0", "pr 0 1 -", "pr -1 10", "pr 0 0", "pr 0 101", "pr 0 1x",
                           "pr ０ 1", "ib", "ib -", "ib 1.2.3.4 -", "ic", "ic -", "aur", "aur Y", "rg", "rs a.exemple.ca,b",
                           "rs ", "tg 1.1.1.1 2.2.2.2", "u"]
        for command in forbiddenID {
            try expect(!RustDeskConsoleCommand.isAllowed(port: 21115, command: command), "hbbs « \(command) » refusé")
        }
        try expect(!RustDeskConsoleCommand.isAllowed(port: 21116, command: "u"), "autre port refusé")
    }

    suite.add("Serveur RustDesk : le script ne fait que lire (commandes permises, ni sudo ni écriture)") {
        let script = RustDeskServerScript.text
        let calls = RustDeskServerScript.consoleCalls()
        try expect(calls.count >= 9, "appels de console trouvés (\(calls.count))")
        for call in calls {
            try expect(RustDeskConsoleCommand.isAllowed(port: call.port, command: call.command),
                       "commande du script permise : \(call.port) « \(call.command) »")
        }
        try expect(calls.contains { $0.port == 21117 && $0.command == "u" }, "hbbr u lu")
        try expect(calls.contains { $0.port == 21115 && $0.command.hasPrefix("pr ") }, "hbbs pr lu")
        let lower = script.lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
        for word in ["sudo", "su", "rm", "rmdir", "mv", "cp", "tee", "chmod", "chown", "kill", "pkill", "systemctl", "service",
                     "apt", "curl", "wget", "insert", "update", "delete", "drop", "crontab", "truncate", "mkfifo", "dd",
                     "reboot", "shutdown"] {
            try expect(!words.contains(word), "le script ne contient pas la commande « \(word) »")
        }
        for phrase in ["docker exec", "docker run", "docker stop", "docker restart", "docker rm", "docker compose",
                       "docker-compose", "id_ed25519", "> /"] {
            try expect(!lower.contains(phrase), "le script ne contient pas « \(phrase) »")
        }
        // Aucune commande interdite de console, sous aucune forme.
        for pattern in [#"\bpr\s+-"#, #"\bib\b"#, #"\bic\b"#, #"\baur\b"#, #"\brg\b"#, #"\bba\b"#, #"\bBa\b"#, #"\bbr\b"#, #"\bBr\b"#] {
            try expect(script.range(of: pattern, options: .regularExpression) == nil, "motif interdit absent : \(pattern)")
        }
        // Seules redirections d'écriture : /dev/null, &1, &3 (le canal TCP), jamais un fichier.
        var index = script.startIndex
        while let range = script.range(of: ">", range: index..<script.endIndex) {
            let after = String(script[range.upperBound...].prefix(24))
            let before = String(script[..<range.lowerBound].suffix(24))
            let safeTargets = ["/dev/null", "&1", "&3", "\"/dev/tcp/127.0.0.1/"]
            let ok: Bool = safeTargets.contains(where: { after.hasPrefix($0) }) || before.hasSuffix("<")
            try expect(ok, "redirection sûre près de « " + before + ">" + after + " »")
            index = range.upperBound
        }
        // Consoles jointes sur la boucle locale seulement.
        try expect(!script.contains("0.0.0.0") && script.components(separatedBy: "127.0.0.1").count >= 4, "127.0.0.1 seulement")
        // Le script se vérifie lui-même : la fonction console refuse ce qui n'est pas sur la liste.
        try expect(script.contains("*) return 64 ;;"), "liste blanche dans le script")
    }

    suite.add("Serveur RustDesk : le script est du sh valide (analyse seule, rien n'est exécuté)") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { throw TestSkipped(reason: "/bin/sh absent") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(RustDeskServerScript.text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expectEqual(process.terminationStatus, 0, "sh -n sans erreur : \(message)")
    }

    suite.add("Serveur RustDesk : arguments ssh en tableau, sans secret, destination après « -- »") {
        let account = try RustDeskServerAccount.parse("admin@assistance.exemple.ca:2222")
        try expectEqual(account.port, 2222, "port lu")
        let args = RustDeskServerSSH.arguments(account, hasSecret: true)
        try expect(args.contains("BatchMode=no"), "askpass permis avec un secret")
        try expect(args.contains("StrictHostKeyChecking=accept-new"), "clé changée refusée")
        try expect(args.contains("-T") && args.contains("RequestTTY=no"), "pas de terminal")
        let dash = try unwrap(args.firstIndex(of: "--"), "« -- » présent")
        try expectEqual(Array(args[(dash + 1)...]), ["admin@assistance.exemple.ca", RustDeskServerSSH.remoteCommand], "destination puis commande fixe")
        try expect(args[..<dash].contains("2222"), "port avant « -- »")
        let keysOnly = RustDeskServerSSH.arguments(RustDeskServerAccount(user: "admin", host: "10.0.0.5", keyPath: "~/.ssh/id_rd"), hasSecret: false)
        try expect(keysOnly.contains("BatchMode=yes"), "clés seulement sans secret")
        try expect(keysOnly.contains("IdentitiesOnly=yes") && keysOnly.contains { $0.hasSuffix("/.ssh/id_rd") }, "clé du carnet")
        try expect(!keysOnly.contains("-p"), "port 22 non écrit")
        let env = RustDeskServerSSH.environment(askpass: URL(fileURLWithPath: "/tmp/x/askpass.sh"))
        try expectEqual(env["SSH_ASKPASS_REQUIRE"], "force", "askpass forcé")
        try expect(env["NETSCOPE_SSH_SECRET"] == nil, "secret ajouté seulement au lancement")
        try expect(RustDeskServerSSH.askpassScript.contains("echo no"), "jamais le mot de passe à la question d'empreinte")
        // Valeurs refusées.
        for bad in ["-oProxyCommand=x@h", "admin@-oProxyCommand=x", "admin@hôte;rm", "assistance.exemple.ca", "admin@h:70000"] {
            try expect((try? RustDeskServerAccount.parse(bad)) == nil, "compte refusé : \(bad)")
        }
        // Commande à copier : aucune valeur de secret, le script complet, document sans substitution.
        let copy = RustDeskServerSSH.copyableCommand(account)
        try expect(copy.hasPrefix("ssh -T -p 2222 -- admin@assistance.exemple.ca "), "début de la commande : \(copy.prefix(80))")
        try expect(copy.contains("<<'NETSCOPE'\n") && copy.hasSuffix("\nNETSCOPE\n"), "document intégré")
        try expect(RustDeskServerSSH.displayCommand(account).hasSuffix("< collecte-rustdesk.sh"), "ligne affichée")
    }

    suite.add("Serveur RustDesk : compte repris d'une connexion SSH du carnet") {
        let ssh = RemoteConnection(name: "SRV-RUSTDESK", proto: .ssh, host: "10.20.0.5", port: 2200, username: "admin",
                                   proxyJump: "admin@10.20.0.1", identityFile: "~/.ssh/id_ed25519_rd")
        let account = try unwrap(RustDeskServerAccount(connection: ssh), "compte lu")
        try expectEqual(account.label, "admin@10.20.0.5:2200", "libellé")
        try expectEqual(account.jump, "admin@10.20.0.1", "rebond gardé")
        let args = RustDeskServerSSH.arguments(account, hasSecret: false)
        try expect(args.contains("-J") && args.contains("admin@10.20.0.1"), "-J transmis")
        try expect(RustDeskServerAccount(connection: RemoteConnection(name: "x", proto: .ssh, host: "10.0.0.1")) == nil, "sans utilisateur : refusé")
        try expect(RustDeskServerAccount(connection: RemoteConnection(name: "x", proto: .rdp, host: "10.0.0.1", username: "a")) == nil, "RDP refusé")
    }

    suite.add("Serveur RustDesk : lecture complète (sessions, demandes, processus, disque, postes)") {
        let status = RustDeskServerOutput.parse(full, readAt: readAt)
        try expect(status.complete, "fin reçue")
        try expectEqual(status.hostname, "rustdesk-01", "hôte")
        try expectEqual(status.tcpClient, "nc", "client TCP")
        try expectEqual(status.serverTime, Date(timeIntervalSince1970: 1_793_890_002), "heure du serveur")
        try expectEqual(status.hbbs?.seconds, 259_321, "hbbs depuis 3 j")
        try expectEqual(status.hbbr?.pid, 1902, "PID de hbbr")
        try expect(status.hbbr?.arguments.contains("CleSecrete") == false && status.hbbr?.arguments == "hbbr -k …", "valeur de -k masquée")
        try expectEqual(status.containers.count, 2, "conteneurs")
        try expectEqual(status.version, "1.1.16", "version de l'image")
        try expectEqual(status.disk?.availableKB, 36_882_651, "espace libre")
        try expectEqual(status.disk?.mount, "/", "point de montage")
        try expectEqual(status.disk?.dataKB, 4_120, "taille de data")
        try expectEqual(status.backups.first?.path, "/opt/rustdesk/backup/rustdesk-2026-11-05.tar.gz", "sauvegarde")
        try expectEqual(status.peers, .count(31), "31 postes")
        try expectEqual(status.relayConsole, .ok, "console hbbr")
        try expectEqual(status.relaySessions.count, 2, "deux sessions relayées")
        let first = status.relaySessions[0]
        try expectEqual(first.ip, "203.0.113.77", "IP")
        try expectEqual(first.port, 52_114, "port")
        try expectEqual(first.seconds, 1_260, "durée")
        try expectEqual(first.megabytes, 182.40, "volume")
        try expectEqual([first.maxKbps, first.averageKbps, first.currentKbps], [9_120, 1_185, 2_410], "débits max, moyen, actuel")
        try expectEqual(status.currentRelayKbps, 2_790, "débit relayé actuel")
        try expectEqual(status.totalBandwidth, "1024Mb/s", "tb")
        try expect(status.punchSupported, "pr connu")
        try expectEqual(status.relayServers, ["assistance.exemple.ca:21117"], "relais annoncés")
        try expectEqual(status.punchTotal, 4, "nombre de demandes")
        try expectEqual(status.punchRequests.map(\.targetID), ["1027554318", "263418095", "184352907", "263418095"], "plus récentes d'abord")
        try expectEqual(status.punchRequests.first?.fromIP, "10.182.122.135", "IP du technicien")
        let day = status.punchCount()
        try expectEqual(day.count, 3, "trois demandes en 24 h (celle d'hier soir est plus vieille)")
        try expect(!day.atLeast, "liste complète")
        try expect(status.notices.isEmpty, "aucun avertissement : \(status.notices.map(\.title))")
    }

    suite.add("Serveur RustDesk : rapprochements (poste du carnet, relais)") {
        let status = RustDeskServerOutput.parse(full, readAt: readAt)
        let book = ["184352907": "WKS-ACCUEIL-02", "263418095": "PORT-COMPTA-07"]
        let session = status.relaySessions[0]
        let request = try unwrap(RustDeskServerCorrelation.request(for: session, in: status.punchRequests, now: status.now), "demande trouvée")
        try expectEqual(request.targetID, "184352907", "demande à l'origine de la session")
        try expectEqual(RustDeskServerCorrelation.name(of: request.targetID, book: book), "WKS-ACCUEIL-02", "nom du carnet")
        let second = try unwrap(RustDeskServerCorrelation.request(for: status.relaySessions[1], in: status.punchRequests, now: status.now), "2e")
        try expectEqual(second.date, ISO8601DateFormatter().date(from: "2026-11-05T14:44:30Z"), "la plus proche, pas celle d'hier")
        let relayed = RustDeskServerCorrelation.relayedRequestIDs(sessions: status.relaySessions, requests: status.punchRequests, now: status.now)
        try expectEqual(relayed.count, 2, "deux demandes relayées")
        try expect(!relayed.contains(status.punchRequests[0].id), "la demande vers LAVAL n'est pas relayée")
        // Session sans demande voisine : aucun nom inventé.
        let lone = RustDeskRelaySession(address: "192.0.2.200:4000", seconds: 30, megabytes: 1, maxKbps: 1, averageKbps: 1, currentKbps: 1)
        try expect(RustDeskServerCorrelation.request(for: lone, in: status.punchRequests, now: status.now) == nil, "aucune correspondance")
    }

    suite.add("Serveur RustDesk : sorties dégradées (console fermée, hbbs ancien, permission, sqlite3 absent)") {
        let degraded = """
        @@NETSCOPE META@@
        hote=srv
        heure=pas-un-nombre
        client=bash
        @@NETSCOPE PROCESSUS@@
         12 99 hbbs hbbs
        @@NETSCOPE DOCKER@@
        IGNORE groupe-docker
        @@NETSCOPE DISQUE@@
        df: /opt/rustdesk/data: No such file or directory
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sda2 100 95 5 95% /
        du=
        @@NETSCOPE POSTES@@
        ETAT illisible
        @@NETSCOPE HBBR_U@@
        @@STATUT 1@@
        @@NETSCOPE HBBR_TB@@
        @@STATUT 1@@
        @@NETSCOPE HBBS_AIDE@@
        relay-servers(rs) <separated by ,>
        reload-geo(rg)
        @@STATUT 0@@
        @@NETSCOPE HBBS_NOMBRE@@
        0
        @@NETSCOPE HBBS_PR@@
        @@NETSCOPE FIN@@
        """
        let status = RustDeskServerOutput.parse(degraded, readAt: readAt)
        try expect(status.serverTime == nil, "heure illisible ignorée")
        try expect(status.hbbr == nil && status.hbbs != nil, "hbbr arrêté")
        try expectEqual(status.dockerSkipped, "groupe-docker", "docker ignoré")
        try expectEqual(status.peers, .unreadable, "base illisible sans sudo")
        try expectEqual(status.relayConsole, .unreachable(code: 1), "console hbbr fermée")
        try expect(status.relaySessions.isEmpty, "aucune session")
        try expect(status.totalBandwidth == nil, "tb inconnu")
        try expect(!status.punchSupported, "hbbs ancien")
        try expectEqual(status.disk?.usedFraction ?? 0, 0.95, "disque à 95 %")
        try expect(status.disk?.dataKB == nil, "du vide")
        let titles = status.notices.map(\.title)
        try expect(titles.contains("hbbr n’est pas en marche"), "hbbr arrêté signalé : \(titles)")
        try expect(titles.contains("Console hbbr non joignable"), "console hbbr signalée")
        try expect(titles.contains("hbbs ancien\u{00A0}: pas de liste des demandes"), "hbbs ancien signalé")
        try expect(titles.contains("Disque presque plein"), "disque signalé")

        // Rien du tout (connexion coupée tout de suite) : aucune erreur, état « incomplet ».
        let empty = RustDeskServerOutput.parse("", readAt: readAt)
        try expect(!empty.complete && empty.relayConsole == .unknown && empty.peers == .unknown, "sortie vide")
        try expect(empty.notices.contains { $0.title == "Lecture incomplète" }, "incomplet signalé")

        // Aucun client TCP, sqlite3 absent, permission refusée par sqlite3.
        let noClient = RustDeskServerOutput.parse("@@NETSCOPE META@@\n@@NETSCOPE HBBR_U@@\n@@STATUT 127@@\n@@NETSCOPE POSTES@@\nETAT sans-sqlite3\n", readAt: readAt)
        try expectEqual(noClient.relayConsole, .noClient, "aucun client TCP")
        try expectEqual(noClient.peers, .missingTool, "sqlite3 absent")
        let denied = RustDeskServerOutput.parse("@@NETSCOPE POSTES@@\nETAT ok\nError: unable to open database file\n", readAt: readAt)
        try expectEqual(denied.peers, .unreadable, "sqlite3 refusé")
    }

    suite.add("Serveur RustDesk : lignes malformées ignorées, texte du serveur nettoyé") {
        try expect(RustDeskRelaySession.parse("garbage") == nil, "ligne quelconque")
        try expect(RustDeskRelaySession.parse("1.2.3.4:5: 10s xMB 1kb/s 1kb/s 1kb/s") == nil, "volume illisible")
        try expect(RustDeskRelaySession.parse("1.2.3.4:5: 10s 1.00MB 1kb/s 1kb/s") == nil, "champ manquant")
        let v6 = try unwrap(RustDeskRelaySession.parse("::ffff:203.0.113.5:4100: 5s 0.10MB 10kb/s 8kb/s 7kb/s"), "IPv4 en IPv6")
        try expectEqual(v6.ip, "203.0.113.5", "préfixe ::ffff: retiré")
        try expect(RustDeskPunchRequest.parse("2026-11-05T14:45:01Z 1.2.3.4 => 1@2", id: 0) == nil, "flèche absente")
        try expect(RustDeskPunchRequest.parse("hier 1.2.3.4 -> 123456789@5.6.7.8", id: 0) == nil, "date illisible")
        let request = try unwrap(RustDeskPunchRequest.parse("2026-11-05T14:45:01Z 1.2.3.4:5000 -> 123456789@5.6.7.8:21116", id: 3), "avec ports")
        try expectEqual(request.fromIP, "1.2.3.4", "port retiré du demandeur")
        try expectEqual(request.targetIP, "5.6.7.8", "port retiré du poste")
        let hostile = RustDeskServerOutput.parse("@@NETSCOPE META@@\nhote=srv\u{1B}[2Jx\u{07}\n", readAt: readAt)
        try expect(!hostile.hostname.contains("\u{1B}") && !hostile.hostname.contains("\u{07}"), "caractères de contrôle retirés")
    }

    suite.add("Serveur RustDesk : erreurs ssh expliquées") {
        func kind(_ status: Int32, _ stderr: String, timedOut: Bool = false) -> RustDeskServerReadError.Kind? {
            if case .failure(let error) = RustDeskServerOutput.interpret(status: status, stdout: "", stderr: stderr, timedOut: timedOut,
                                                                         host: "srv", readAt: readAt) { return error.kind }
            return nil
        }
        try expectEqual(kind(255, "admin@srv: Permission denied (publickey,password)."), .authentication, "authentification")
        try expectEqual(kind(255, "ssh: connect to host srv port 22: Connection refused"), .unreachable, "refusée")
        try expectEqual(kind(255, "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"), .hostKey, "empreinte changée")
        try expectEqual(kind(255, "ssh: connect to host srv port 22: Operation timed out"), .timeout, "délai")
        try expectEqual(kind(0, "", timedOut: true), .timeout, "délai total")
        try expectEqual(kind(127, "fish: Unknown command: eval"), .script, "shell inattendu")
        // Lecture partielle coupée par le délai : l'état lu est gardé, marqué incomplet.
        if case .success(let partial) = RustDeskServerOutput.interpret(status: 15, stdout: "@@NETSCOPE META@@\nhote=srv\n", stderr: "",
                                                                       timedOut: true, host: "srv", readAt: readAt) {
            try expect(!partial.complete, "incomplet")
        } else {
            throw TestFailure(message: "lecture partielle perdue", file: #fileID, line: #line)
        }
    }

    suite.add("Serveur RustDesk : échantillons gardés trois jours, réglages relus") {
        let now = readAt
        var samples: [RustDeskServerSample] = []
        samples = RustDeskServerSamples.adding(RustDeskServerSample(date: now.addingTimeInterval(-4 * 86_400), sessions: 1, kbps: 1), to: samples, now: now)
        samples = RustDeskServerSamples.adding(RustDeskServerSample(date: now.addingTimeInterval(-3_600), sessions: 2, kbps: 900), to: samples, now: now)
        samples = RustDeskServerSamples.adding(RustDeskServerSample(date: now.addingTimeInterval(-60), sessions: 1, kbps: 300), to: samples, now: now)
        samples = RustDeskServerSamples.adding(RustDeskServerSample(date: now.addingTimeInterval(86_400), sessions: 9, kbps: 9), to: samples, now: now)
        try expectEqual(samples.map(\.sessions), [2, 1], "trop vieux et futur retirés, ordre chronologique")
        try expectEqual(RustDeskServerSamples.window(samples, hours: 0.5, now: now).count, 1, "fenêtre d'une demi-heure")
        let status = RustDeskServerOutput.parse(full, readAt: now)
        try expectEqual(RustDeskServerSamples.sample(from: status), RustDeskServerSample(date: now, sessions: 2, kbps: 2_790), "échantillon d'une lecture")
        try expect(RustDeskServerSamples.sample(from: RustDeskServerOutput.parse("", readAt: now)) == nil, "pas d'échantillon sans console")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-rd-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RustDeskDashboardStore(url: folder.appendingPathComponent("rustdesk-serveur.json"))
        let settings = RustDeskDashboardSettings(manualAccount: "admin@assistance.exemple.ca", refreshSeconds: 60)
        try store.save(RustDeskDashboardStore.Contents(settings: settings, samples: samples))
        let loaded = try unwrap(store.load(), "relu")
        try expectEqual(loaded.settings, settings, "réglages relus")
        try expectEqual(loaded.samples, samples, "échantillons relus")
        let text = try String(contentsOf: store.url, encoding: .utf8)
        try expect(!text.lowercased().contains("password") && !text.contains("secret"), "aucun secret dans le fichier")
        let old = try JSONDecoder().decode(RustDeskDashboardSettings.self, from: Data(#"{"refreshSeconds": 2}"#.utf8))
        try expectEqual(old.refreshSeconds, 10, "délai borné")
        try expect(!old.hasAccount, "sans compte")
    }

    suite.add("Serveur RustDesk : mise en forme (débits, durées, volumes)") {
        try expectEqual(RustDeskServerFormat.kbps(850), "850\u{00A0}kbit/s", "kbit/s")
        try expectEqual(RustDeskServerFormat.kbps(2_790), "2,8\u{00A0}Mbit/s", "Mbit/s")
        try expectEqual(RustDeskServerFormat.duration(42), "42\u{00A0}s", "secondes")
        try expectEqual(RustDeskServerFormat.duration(1_260), "21\u{00A0}min", "minutes")
        try expectEqual(RustDeskServerFormat.duration(3_900), "1\u{00A0}h\u{00A0}05", "heures")
        try expectEqual(RustDeskServerFormat.duration(259_321), "3\u{00A0}j", "jours")
        try expectEqual(RustDeskServerFormat.duration(273_600), "3\u{00A0}j\u{00A0}4\u{00A0}h", "jours et heures")
        try expectEqual(RustDeskServerFormat.megabytes(182.4), "182\u{00A0}Mo", "Mo")
        try expectEqual(RustDeskServerFormat.kilobytes(36_882_651), "35,2\u{00A0}Go", "Go")
        try expectEqual(RustDeskServerFormat.bytes(18_432), "18\u{00A0}ko", "ko")
        try expectEqual(RustDeskServerFormat.bytes(2_500_000), "2,4\u{00A0}Mo", "Mo")
        try expectEqual(RustDeskServerFormat.dockerStatus("Up 3 days"), "en marche depuis 3 jours", "docker en marche")
        try expectEqual(RustDeskServerFormat.dockerStatus("Up 45 seconds (healthy)"), "en marche depuis 45 secondes (sain)", "secondes")
        try expectEqual(RustDeskServerFormat.dockerStatus("Up About an hour"), "en marche depuis environ une heure", "environ une heure")
        try expectEqual(RustDeskServerFormat.dockerStatus("Exited (137) 2 hours ago"), "arrêté (137) il y a 2 heures", "arrêté")
    }
}

private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — valeur absente", file: file, line: line) }
    return value
}
