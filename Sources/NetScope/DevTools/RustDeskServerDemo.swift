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
        return RustDeskServerStatus(
            readAt: now, serverTime: now, hostname: "rustdesk-01", user: "admin", system: "Ubuntu 26.04 LTS", tcpClient: "nc",
            hbbs: RustDeskServerProcess(name: "hbbs", pid: 1873, seconds: uptime, arguments: "hbbs -r assistance.exemple.ca:21117 -k …"),
            hbbr: RustDeskServerProcess(name: "hbbr", pid: 1902, seconds: uptime - 1, arguments: "hbbr -k …"),
            containers: [
                RustDeskContainer(name: "hbbs", image: "rustdesk/rustdesk-server:1.1.16", status: "Up 3 days"),
                RustDeskContainer(name: "hbbr", image: "rustdesk/rustdesk-server:1.1.16", status: "Up 3 days"),
            ],
            disk: RustDeskDiskUsage(mount: "/", totalKB: 61_611_820, usedKB: 21_564_137, availableKB: 36_882_651, dataKB: 4_120),
            backups: [RustDeskBackupFile(path: "/opt/rustdesk/sauvegardes/rustdesk-data-quotidienne.tar.gz",
                                         date: now.addingTimeInterval(-7.75 * 3_600), bytes: 18_432)],
            peers: .count(31),
            relayConsole: .ok, relaySessions: sessions, totalBandwidth: "1024Mb/s", sessionBandwidth: "16Mb/s",
            idConsole: .ok, punchSupported: true, punchTotal: requests(now: now).count, punchRequests: requests(now: now),
            relayServers: ["assistance.exemple.ca:21117"], complete: true)
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
