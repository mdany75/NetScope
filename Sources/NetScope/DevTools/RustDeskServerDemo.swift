import Foundation
import NetScopeCore

/// Note 6 (suite, 0.26.2) : serveur RustDesk fictif du tableau de bord (assistance.exemple.ca).
/// Adresses de documentation seulement (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) et postes
/// du carnet de démonstration ; aucun ssh n'est lancé.
enum RustDeskServerDemo {
    static let settings = RustDeskDashboardSettings(manualAccount: "admin@assistance.exemple.ca", refreshSeconds: 30)

    /// Technicien à distance (domicile) et Mac du technicien au siège.
    static let technicianHome = "198.51.100.37"
    static let technicianOffice = "10.182.122.135"

    /// État lu « maintenant » : deux sessions relayées, une quinzaine de demandes sur la journée,
    /// hbbs et hbbr en marche depuis 3 jours, 31 postes enregistrés.
    static func status(now: Date) -> RustDeskServerStatus {
        let uptime = 3 * 86_400 + 4 * 3_600 + 12 * 60
        let sessions = [
            RustDeskRelaySession(address: "203.0.113.58:52114", seconds: 21 * 60 + 14, megabytes: 182.4,
                                 maxKbps: 9_120, averageKbps: 1_185, currentKbps: 2_410),
            RustDeskRelaySession(address: "\(technicianHome):61002", seconds: 95, megabytes: 6.12,
                                 maxKbps: 1_650, averageKbps: 540, currentKbps: 380),
        ]
        var status = RustDeskServerStatus(
            readAt: now, serverTime: now, hostname: "rustdesk-01", user: "admin", system: "Ubuntu 26.04 LTS", tcpClient: "nc",
            hbbs: RustDeskServerProcess(name: "hbbs", pid: 1873, seconds: uptime, arguments: "hbbs -r assistance.exemple.ca:21117 -k …"),
            hbbr: RustDeskServerProcess(name: "hbbr", pid: 1902, seconds: uptime - 1, arguments: "hbbr -k …"),
            containers: [
                RustDeskContainer(name: "hbbs", image: "rustdesk/rustdesk-server:latest", status: "Up 3 days"),
                RustDeskContainer(name: "hbbr", image: "rustdesk/rustdesk-server:latest", status: "Up 3 days"),
            ],
            disk: RustDeskDiskUsage(mount: "/", totalKB: 61_611_820, usedKB: 21_564_137, availableKB: 36_882_651, dataKB: 4_120),
            backups: [RustDeskBackupFile(path: "/opt/rustdesk/sauvegardes/rustdesk-data-quotidienne.tar.gz",
                                         date: now.addingTimeInterval(-7.75 * 3_600), bytes: 18_432)],
            peers: .count(31),
            relayConsole: .ok, relaySessions: sessions, totalBandwidth: "1024Mb/s", sessionBandwidth: "16Mb/s",
            idConsole: .ok, punchSupported: true, punchTotal: requests(now: now).count, punchRequests: requests(now: now),
            relayServers: ["assistance.exemple.ca:21117"], complete: true)
        status.health = RustDeskServerHealth(uptimeSeconds: 41 * 86_400 + 6 * 3_600, load: [0.18, 0.22, 0.19], cpus: 2,
                                             cpuPercent: 6.4, memoryTotalKB: 4_014_080, memoryAvailableKB: 2_861_220)
        status.publicKey = .key(demoKey)
        status.containerDetails = detail(now: now).containers
        status.images = detail(now: now).images
        return status
    }

    // MARK: Note 87 (0.33.0)

    /// Clé publique FICTIVE (« for-demo-only-not-a-real-key-000 » en base 64).
    static let demoKey = "Zm9yLWRlbW8tb25seS1ub3QtYS1yZWFsLWtleS0wMDA="
    static let localDigest = "sha256:0d1e2m3o4d5e6m7o8d9e0d1e2m3o4d5e6m7o8d9e0d1e2m3o4d5e6m7o8d9e0d1e"
    static let hubDigest = "sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0"

    /// Lecture détaillée (sudo) : 7 mises à jour dont 3 de sécurité, redémarrage requis, hbbs 1.1.14,
    /// hbbr redémarré deux fois.
    static func detail(now: Date) -> RustDeskServerReading {
        let started = now.addingTimeInterval(-Double(3 * 86_400 + 4 * 3_600 + 12 * 60))
        return RustDeskServerReading(
            readAt: now.addingTimeInterval(-3 * 3_600), sudo: "ok",
            updates: RustDeskSystemUpdates(manager: "apt",
                                           packages: ["libssl3t64", "openssh-client", "openssh-server", "openssl", "python3-urllib3", "snapd", "tzdata"],
                                           security: ["libssl3t64", "openssh-server", "openssl"], rebootRequired: true,
                                           rebootPackages: ["linux-image-6.17.0-8-generic"], listsDate: now.addingTimeInterval(-9 * 3_600)),
            hbbsVersion: "1.1.14",
            containers: [
                RustDeskContainerDetail(name: "hbbs", restartCount: 0, startedAt: started, image: "rustdesk/rustdesk-server:latest", imageID: "sha256:4b1d"),
                RustDeskContainerDetail(name: "hbbr", restartCount: 2, startedAt: started.addingTimeInterval(1), image: "rustdesk/rustdesk-server:latest", imageID: "sha256:4b1d"),
            ],
            images: [RustDeskImageDigest(imageID: "sha256:4b1d", repoDigests: ["rustdesk/rustdesk-server@" + localDigest])],
            publicKey: .key(demoKey))
    }

    /// Suivi : noms et notes, historique de deux mois, versions publiées, dernière copie il y a 9 jours.
    /// Identifiant du Mac qui exécute la mise à jour planifiée en démonstration (« ce Mac »).
    static let demoMachineID = "00000000-0000-4000-8000-000000000088"

    static func watch(now: Date) -> RustDeskWatchStore.Contents {
        var contents = RustDeskWatchStore.Contents()
        contents.notes = [
            "731905246": RustDeskIDNote(name: "Kiosque entrepôt", note: "Écran tactile du quai 3 · redémarrer après 22 h", updatedAt: now),
            "1027554318": RustDeskIDNote(name: "", note: "Poste de Sophie, télétravail le vendredi", updatedAt: now),
        ]
        contents.technicians = [technicianHome: "Marc (domicile)", technicianOffice: "Mac du siège"]
        var history = requests(now: now).map(RustDeskArchivedRequest.init)
        let ids = [("184352907", "10.182.122.146"), ("263418095", "203.0.113.58"), ("1027554318", "203.0.113.90"), ("731905246", "192.0.2.61")]
        for day in 3..<62 where day % 7 != 5 && day % 7 != 6 {
            for index in 0..<(2 + day % 4) {
                let pick = ids[(day + index) % ids.count]
                history.append(RustDeskArchivedRequest(date: now.addingTimeInterval(-Double(day * 86_400 + index * 4_700 + 3_600)),
                                                       fromIP: index % 3 == 0 ? technicianHome : technicianOffice,
                                                       targetID: pick.0, targetIP: pick.1))
            }
        }
        // Rafale d'une IP inconnue (essais d'ID au hasard), il y a deux jours.
        for index in 0..<11 {
            history.append(RustDeskArchivedRequest(date: now.addingTimeInterval(-2 * 86_400 + Double(index * 20)), fromIP: "203.0.113.201",
                                                   targetID: String(418_220_977 + index * 7_919), targetIP: "192.0.2.88"))
        }
        contents.history = history.sorted { $0.date < $1.date }
        contents.knownKey = demoKey
        contents.backups = [now.addingTimeInterval(-9 * 86_400), now.addingTimeInterval(-40 * 86_400)]
        contents.published = RustDeskPublishedVersions(checkedAt: now.addingTimeInterval(-3 * 3_600), server: "1.1.15", hubDigest: hubDigest, client: "1.4.4")
        // Note 88 (0.33.1) : mise à jour planifiée et actions passées (valeurs fictives).
        var schedule = RustDeskUpdateSchedule()
        schedule.enabled = true
        schedule.weekday = 1
        schedule.hour = 3
        schedule.target = .both
        schedule.scope = .security
        schedule.runnerID = demoMachineID
        schedule.runnerName = "Mac du siège"
        contents.schedule = schedule
        let mac = "Mac du siège"
        // Dernière échéance (dimanche 3 h) : actions planifiées faites quelques minutes après.
        let sunday = schedule.lastSlot(atOrBefore: now, calendar: .current) ?? now.addingTimeInterval(-4 * 86_400)
        contents.actions = [
            RustDeskActionRecord(date: sunday.addingTimeInterval(9 * 60), kind: .updateSystem, target: "Sécurité seulement", outcome: .ok,
                                 summary: "Mises à jour de sécurité installées (unattended-upgrade).", origin: mac + " (agent, planifiée)", slot: sunday),
            RustDeskActionRecord(date: sunday.addingTimeInterval(4 * 60), kind: .updateRustDesk, target: "hbbs et hbbr (Docker)", outcome: .ok,
                                 summary: "Déjà à jour\u{00A0}: aucune nouvelle image, rien n’est redémarré.", origin: mac + " (agent, planifiée)", slot: sunday),
            RustDeskActionRecord(date: sunday.addingTimeInterval(-2 * 86_400 + 14 * 3_600 + 22 * 60), kind: .disconnect, target: "198.51.100.37:60412 (Kiosque entrepôt)",
                                 outcome: .ok, summary: "Connexion relayée de 198.51.100.37:60412 fermée (1 connexion(s)). Le poste peut se reconnecter.",
                                 origin: mac),
            RustDeskActionRecord(date: sunday.addingTimeInterval(-7 * 86_400 + 60), kind: .updateRustDesk, target: "hbbs et hbbr (Docker)", outcome: .postponed,
                                 summary: "Reportée\u{00A0}: session relayée en cours.", origin: mac + " (agent, planifiée)", slot: sunday.addingTimeInterval(-7 * 86_400)),
            RustDeskActionRecord(date: sunday.addingTimeInterval(-7 * 86_400 + 16 * 60), kind: .updateRustDesk, target: "hbbs et hbbr (Docker)", outcome: .ok,
                                 summary: "RustDesk Server 1.1.12 → 1.1.14.", origin: mac + " (agent, planifiée)", slot: sunday.addingTimeInterval(-7 * 86_400)),
        ]
        contents.actions = RustDeskActionRecord.union(contents.actions, [])
        return contents
    }

    /// Refus de la FortiGate du siège (filtre géographique) vers 21116.
    static func denied(now: Date) -> [RustDeskDeniedAttempt] {
        var list: [RustDeskDeniedAttempt] = []
        for index in 0..<14 {
            let seconds = Double(index) * 2_400 + 600
            let port = index % 3 == 0 ? 21_117 : 21_116
            list.append(RustDeskDeniedAttempt(date: now.addingTimeInterval(-seconds), sourceIP: "198.51.100.211",
                                              port: port, country: "Pays filtré", site: "Siège"))
        }
        return list
    }

    /// Adresses WAN fictives des FortiGate.
    static let wanAddresses: [(site: String, ip: String)] = [("Siège", "203.0.113.58"), ("Laval", "203.0.113.90")]

    /// Site ouvert en démonstration.
    static let activeSite = "Siège"

    static let candidates = [
        RustDeskAssociationCandidate(ip: "10.182.122.113", mac: "3C:52:82:4A:19:E7", name: "Portable Marc",
                                     reason: "session relayée (21117) sur la FortiGate de Siège", relay: true, site: "Siège"),
        RustDeskAssociationCandidate(ip: "10.182.122.152", mac: "F4:39:09:11:7C:2A", name: "POSTE-COMPTA-03",
                                     reason: "session FortiGate de Siège vers le serveur", site: "Siège"),
        RustDeskAssociationCandidate(ip: "10.182.122.187", mac: nil, name: "10.182.122.187",
                                     reason: "session FortiGate de Siège vers le serveur", site: "Siège"),
    ]

    /// Journaux de hbbs et hbbr (texte fictif dans le format du serveur).
    static func logs(now: Date) -> [RustDeskLogLine] {
        let rows: [(Double, String, String, String)] = [
            (871, "hbbs", "INFO", "[src/rendezvous_server.rs:1205] punch hole request from 10.182.122.135 to 184352907"),
            (522, "hbbs", "WARN", "[src/rendezvous_server.rs:732] Punch hole request from 203.0.113.201 to unknown id 418220977"),
            (311, "hbbs", "INFO", "[src/rendezvous_server.rs:1205] punch hole request from 10.182.122.135 to 1027554318"),
            (262, "hbbr", "INFO", "[src/relay_server.rs:460] New relay request 5f1c from 198.51.100.37:61002"),
            (262, "hbbr", "INFO", "[src/relay_server.rs:478] Relayrequest 5f1c paired, 203.0.113.58:52114"),
            (24, "hbbs", "INFO", "[src/rendezvous_server.rs:1205] punch hole request from 10.182.122.135 to 184352907"),
            (22, "hbbr", "INFO", "[src/relay_server.rs:460] New relay request 9a07 from 203.0.113.58:52114"),
            (12, "hbbs", "INFO", "[src/peer.rs:101] update_pk 263418095 203.0.113.58:21116"),
            (2.2, "hbbs", "INFO", "[src/rendezvous_server.rs:1205] punch hole request from 198.51.100.37 to 1027554318"),
        ]
        return rows.enumerated().map { index, row in
            RustDeskLogLine(id: index, service: row.1, date: now.addingTimeInterval(-row.0 * 60), level: row.2, text: row.2 + " " + row.3)
        }
    }

    /// Serveur injoignable par SSH (capture « rustdesk-serveur-erreur »).
    static let unreachable = RustDeskServerReadError(kind: .timeout, detail: "Aucune réponse de assistance.exemple.ca dans le délai.")

    /// hbbs ancien (sans « pr »), console hbbr fermée, compte hors du groupe docker et base des
    /// postes lisible par root seulement (capture « rustdesk-serveur-ancien »).
    static func degraded(now: Date) -> RustDeskServerStatus {
        var status = status(now: now)
        status.containers = []
        status.dockerSkipped = "groupe-docker"
        status.peers = .unreadable
        status.relayConsole = .unreachable(code: 1)
        status.relaySessions = []
        status.totalBandwidth = nil
        status.sessionBandwidth = nil
        status.punchSupported = false
        status.punchRequests = []
        status.punchTotal = 0
        status.backups = []
        return status
    }

    /// Console de hbbs muette (demandes inconnues, pas « hbbs sans pr ») et processus invisibles
    /// pour ps (/proc monté avec hidepid, compte hors du groupe docker) alors que la console de
    /// hbbr répond : hbbr reste « En marche » (capture « rustdesk-serveur-console »).
    static func consoleSilent(now: Date) -> RustDeskServerStatus {
        var status = status(now: now)
        status.hbbs = nil
        status.hbbr = nil
        status.containers = []
        status.dockerSkipped = "groupe-docker"
        status.idConsole = .unreachable(code: 1)
        status.punchSupported = false
        status.punchRequests = []
        status.punchTotal = 0
        status.relayServers = []
        return status
    }

    /// Serveur SSH inconnu : empreinte à accepter (capture « rustdesk-serveur-empreinte »).
    static let unknownHostKey = RustDeskServerReadError(
        kind: .unknownHostKey,
        detail: "Empreinte présentée par assistance.exemple.ca\u{00A0}: SHA256:q3VtXyZ0Lm8RkPbT2wHc9JdNfE4sAaU7iGoY1xKvB5M",
        fingerprint: "SHA256:q3VtXyZ0Lm8RkPbT2wHc9JdNfE4sAaU7iGoY1xKvB5M")

    /// Demandes de connexion (« pr ») : celles de la journée, puis celles des deux jours d'avant.
    static func requests(now: Date) -> [RustDeskPunchRequest] {
        let wks = "184352907", compta = "263418095", laval = "1027554318"
        // (minutes avant maintenant, IP du technicien, ID visé, IP du poste)
        var rows: [(Double, String, String, String)] = [
            (2.2, technicianHome, laval, "203.0.113.90"),
            (22, technicianHome, compta, "203.0.113.58"),
            (24, technicianOffice, wks, "10.182.122.146"),
            (75, technicianOffice, wks, "10.182.122.146"),
            (192, technicianOffice, "731905246", "192.0.2.61"),
            (205, technicianOffice, "731905246", "192.0.2.61"),
            (262, technicianHome, compta, "203.0.113.58"),
            (311, technicianOffice, laval, "203.0.113.90"),
            (383, technicianOffice, wks, "10.182.122.146"),
            (457, technicianOffice, compta, "203.0.113.58"),
            (522, "203.0.113.201", "418220977", "192.0.2.88"),
            (604, technicianOffice, wks, "10.182.122.146"),
            (691, technicianHome, laval, "203.0.113.90"),
            (783, technicianHome, compta, "203.0.113.58"),
            (871, technicianHome, wks, "10.182.122.146"),
        ]
        // Les deux jours d'avant (hors des dernières 24 h).
        let older: [(String, String)] = [(wks, "10.182.122.146"), (compta, "203.0.113.58"), (laval, "203.0.113.90")]
        for index in 0..<32 {
            let pick = older[index % older.count]
            rows.append((Double(25 * 60 + index * 85), index % 4 == 0 ? technicianHome : technicianOffice, pick.0, pick.1))
        }
        return rows.enumerated().map { index, row in
            RustDeskPunchRequest(id: index, date: now.addingTimeInterval(-row.0 * 60), fromIP: row.1, targetID: row.2, targetIP: row.3)
        }
    }

    /// Échantillons pris pendant que le tableau de bord était ouvert : les six dernières heures, une
    /// mesure par minute, avec une heure sans mesure (tableau de bord fermé).
    static func samples(now: Date) -> [RustDeskServerSample] {
        var result: [RustDeskServerSample] = []
        for minute in stride(from: 360, through: 0, by: -1) {
            // Tableau de bord fermé entre 3 h 10 et 2 h 05 avant maintenant.
            if (125...190).contains(minute) { continue }
            let date = now.addingTimeInterval(-Double(minute) * 60)
            let sessions: Int
            switch minute {
            case 0...2: sessions = 2
            case 3...22: sessions = 1
            case 255...275: sessions = 1
            case 300...318: sessions = 2
            case 319...330: sessions = 1
            default: sessions = 0
            }
            let wave = (sin(Double(minute) / 17) + 1) / 2 * 0.7 + (sin(Double(minute) / 4.3) + 1) / 2 * 0.3
            let kbps = sessions == 0 ? 0 : Int(Double(sessions) * (900 + 1_500 * wave))
            result.append(RustDeskServerSample(date: date, sessions: sessions, kbps: minute == 0 ? 2_790 : kbps))
        }
        return result
    }
}
