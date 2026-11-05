import Foundation
import NetScopeCore

// Note 42 : rapport de suivi (instantanés, comparaison avec le dernier rapport, section
// « Depuis le dernier rapport », historique par site) et rapports planifiés (échéances,
// rattrapage sans rafale, nommage daté, note sur l'âge du scan). Données fixes, fuseau fixe,
// aucun réseau ; un dossier temporaire pour l'historique et le fichier des planifiés.

private let f0 = Date(timeIntervalSince1970: 1_793_700_000)

private func fdev(_ ip: String, _ mac: String?, _ host: String, _ type: DeviceType, online: Bool = true, ports: [UInt16] = [],
                  sw: String? = nil, port: String? = nil, vlan: Int? = 1) -> Device {
    Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), hostname: host, isOnline: online, openPorts: ports,
           switchName: sw, switchPort: port, vlan: vlan, firstSeen: f0, lastSeen: f0, deviceType: type)
}

private func baseDevices() -> [Device] {
    [
        fdev("10.0.0.1", "04:D5:90:3A:7B:11", "FortiGate-60F", .routeur, ports: [443]),
        fdev("10.0.0.2", "70:0F:6A:91:4C:02", "SW-CORE-01", .switch, ports: [22, 443]),
        fdev("10.0.0.20", "B0:7B:25:44:A1:6C", "WKS346", .poste, sw: "SW-CORE-01", port: "Gi1/0/22"),
        fdev("10.0.0.21", "B0:7B:25:44:9F:20", "WKS341", .poste, sw: "SW-CORE-01", port: "Gi1/0/23"),
        fdev("10.0.0.30", "00:1A:2B:44:10:EE", "NPI7A4410", .imprimante, ports: [9100]),
        fdev("10.0.0.40", "BC:AD:28:6F:01:5A", "Caméra-Quai", .camera),
        fdev("10.0.0.50", "3A:1F:C7:02:9B:E4", "SRV-01", .poste),
    ]
}

private func currentDevices() -> [Device] {
    var devices = baseDevices().filter { $0.id != "10.0.0.40" }           // Caméra-Quai disparue
    devices[2].switchPort = "Gi1/0/24"                                     // WKS346 déplacé
    devices[3].ip = IPv4Address("10.0.0.22")!                              // WKS341 : nouvelle IP
    devices[5].deviceType = .serveur                                       // SRV-01 : type corrigé
    devices += [
        fdev("10.0.0.60", "AA:BB:CC:00:00:01", "iPhone-Marie", .telephone),
        fdev("10.0.0.61", "AA:BB:CC:00:00:02", "Yealink-T54W", .telephoneIP),
        fdev("10.0.0.62", nil, "10.0.0.62", .inconnu),
    ]
    return devices
}

private func snapshot(_ devices: [Device], issues: [ReportIssue], created: Date, day: String, site: String = "S1") -> ReportSnapshot {
    ReportSnapshot(siteKey: site, siteName: "Siège", created: created, reportDate: day, title: "Audit réseau — Siège",
                   fileName: "rapport-audit-siege-\(day).pdf", devices: ReportFollowUp.devices(devices), issues: issues)
}

private let wanIssue = ReportIssue(key: "wan|lien|Siège|wan2", category: .wan, title: "Lien WAN wan2 dégradé", severity: .moyen)
private let dhcpIssue = ReportIssue(key: "dhcp|etendue|Siège|VLAN 20", category: .dhcp, title: "Étendue DHCP VLAN 20 pleine", severity: .eleve)
private let telnetIssue = ReportIssue(key: "pb|telnet ouvert sur sw-core-01", category: .securite, title: "Telnet ouvert sur SW-CORE-01", severity: .eleve)
private let probeIssue = ReportIssue(key: "sonde|X", category: .surveillance, title: "Caméra-Quai hors ligne", severity: .eleve)

func registerReportFollowUpTests(_ suite: TestSuite) {
    suite.add("Rapport de suivi : nouveaux, disparus, changés (IP, nom, type, port), problèmes réglés et nouveaux") {
        let base = snapshot(baseDevices(), issues: [wanIssue, dhcpIssue, telnetIssue], created: f0, day: "2026-10-06")
        let current = snapshot(currentDevices(), issues: [telnetIssue, probeIssue], created: f0.addingTimeInterval(28 * 86_400), day: "2026-11-03")
        let diff = ReportFollowUp.compare(base: base, current: current)
        try expectEqual(diff.added.map(\.name).sorted(), ["10.0.0.62", "Yealink-T54W", "iPhone-Marie"], "3 nouveaux")
        try expectEqual(diff.removed.map(\.name), ["Caméra-Quai"], "1 disparu")
        try expect(diff.changed.contains { $0.name == "WKS341" && $0.before == "IP 10.0.0.21" && $0.after == "IP 10.0.0.22" }, "IP changée")
        try expect(diff.changed.contains { $0.name == "WKS346" && $0.after == "SW-CORE-01 · Gi1/0/24" }, "port changé")
        try expect(diff.changed.contains { $0.name == "SRV-01" && $0.before == "Type Poste de travail" && $0.after == "Type Serveur" }, "type changé")
        try expectEqual(diff.changedDeviceCount, 3, "3 appareils changés")
        try expectEqual(Set(diff.resolved.map(\.key)), [wanIssue.key, dhcpIssue.key], "2 réglés")
        try expectEqual(diff.newIssues.map(\.key), [probeIssue.key], "1 nouveau problème")
        try expectEqual(diff.persisting.map(\.key), [telnetIssue.key], "1 toujours là")
        try expectEqual(diff.baseDate, "2026-10-06", "base")

        // Changement de nom : même MAC, autre nom.
        var renamed = currentDevices()
        renamed[0].customName = "FG-SIEGE"
        let named = ReportFollowUp.compare(base: current, current: snapshot(renamed, issues: [], created: f0, day: "2026-11-04"))
        try expect(named.changed.contains { $0.before == "Nom FortiGate-60F" && $0.after == "Nom FG-SIEGE" }, "nom changé")
        try expect(named.added.isEmpty && named.removed.isEmpty, "rien d'autre")
    }

    suite.add("Rapport de suivi : clés stables des problèmes, catégories, ports en erreur et sondes du site") {
        try expectEqual(ReportFollowUp.normalizedKey("4 appareils hors ligne"), ReportFollowUp.normalizedKey("5 appareils hors ligne"), "compte ignoré")
        try expect(ReportFollowUp.normalizedKey("Conflit IP sur 10.0.0.5") != ReportFollowUp.normalizedKey("Conflit IP sur 10.0.0.6"), "IP gardée")
        try expectEqual(ReportFollowUp.category(of: "DHCP non autorisé sur 10.0.0.250"), .dhcp, "DHCP")
        try expectEqual(ReportFollowUp.category(of: "Canal 2,4 GHz encombré"), .wifi, "Wi-Fi")
        try expectEqual(ReportFollowUp.category(of: "Telnet ouvert sur SW"), .securite, "Telnet")
        try expectEqual(ReportFollowUp.category(of: "3 appareils hors ligne"), .appareil, "hors ligne")

        // Problèmes du rapport : Telnet du switch et appareil hors ligne, plus ceux de l'application.
        var devices = baseDevices()
        devices[1].openPorts = [23]
        devices[3].isOnline = false
        var input = ReportInput(devices: devices, now: f0)
        input.followUpIssues = [probeIssue, probeIssue]
        let issues = ReportFollowUp.issues(input)
        try expect(issues.contains { $0.category == .securite && $0.title.contains("Telnet") }, "Telnet suivi")
        try expect(issues.contains { $0.category == .appareil && $0.title.contains("WKS341") }, "hors ligne suivi")
        try expectEqual(issues.filter { $0.key == probeIssue.key }.count, 1, "clé unique")

        // Ports en erreur (même seuil que la face avant).
        let sw = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                                    interfaces: [SNMPInterface(index: 1, name: "Gi1/0/1", operStatus: .up, inErrors: 1284),
                                                 SNMPInterface(index: 2, name: "Gi1/0/2", operStatus: .up, inErrors: 12),
                                                 SNMPInterface(index: 3, name: "Gi1/0/3", operStatus: .down, inErrors: 5000),
                                                 SNMPInterface(index: 4, name: "Vlan1", operStatus: .up, inErrors: 9000)])
        let ports = ReportFollowUp.portErrorIssues([sw])
        try expectEqual(ports.map(\.key), ["port|SW-CORE-01|Gi1/0/1"], "seul le port actif en erreur")

        // Sondes : cible IP dans les plages du site, cible nommée pour le site actif seulement.
        let ranges = [try IPRange(parsing: "10.0.0.0/24")]
        try expectEqual(ReportFollowUp.targetAddress("https://10.0.0.5:8443/x"), IPv4Address("10.0.0.5"), "URL")
        try expectEqual(ReportFollowUp.targetAddress("10.0.0.5:443"), IPv4Address("10.0.0.5"), "port TCP")
        try expect(ReportFollowUp.targetAddress("B0:7B:25:44:A1:6C") == nil, "MAC : pas une IP")
        try expect(ReportFollowUp.probeBelongs(target: "10.0.0.9", ranges: ranges, isActiveSite: false), "IP du site")
        try expect(!ReportFollowUp.probeBelongs(target: "192.168.1.9", ranges: ranges, isActiveSite: true), "IP d'un autre réseau")
        try expect(ReportFollowUp.probeBelongs(target: "intranet.local", ranges: ranges, isActiveSite: true), "nom : site actif")
        try expect(!ReportFollowUp.probeBelongs(target: "intranet.local", ranges: ranges, isActiveSite: false), "nom : autre site")
        let monitor = ReportFollowUp.monitorIssue(probeID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Caméra-Quai", down: true)
        try expectEqual(monitor.title, "Caméra-Quai hors ligne", "titre de sonde")
        try expectEqual(monitor.category, .surveillance, "catégorie de sonde")
    }

    suite.add("Rapport de suivi : base (dernier, rapport choisi, date), section et historique par site") {
        let older = snapshot(baseDevices(), issues: [wanIssue], created: f0, day: "2026-09-22")
        let last = snapshot(baseDevices(), issues: [wanIssue, dhcpIssue], created: f0.addingTimeInterval(14 * 86_400), day: "2026-10-06")
        let history = [older, last]
        try expectEqual(ReportFollowUp.base(in: history, choice: .last)?.id, last.id, "dernier")
        try expectEqual(ReportFollowUp.base(in: history, choice: .report(older.id))?.id, older.id, "rapport choisi")
        try expectEqual(ReportFollowUp.base(in: history, choice: .report(UUID()))?.id, last.id, "rapport supprimé : dernier")
        try expectEqual(ReportFollowUp.base(in: history, choice: .date("2026-10-01"))?.id, older.id, "au plus tard le 1er octobre")
        try expect(ReportFollowUp.base(in: history, choice: .date("2026-09-01")) == nil, "rien avant")

        let current = snapshot(currentDevices(), issues: [probeIssue], created: f0.addingTimeInterval(42 * 86_400), day: "2026-11-03")
        if case .noBase(let reason) = ReportFollowUp.result(history: [], choice: .last, current: current) {
            try expect(reason.hasPrefix("Premier rapport de ce site"), "premier rapport")
        } else { try expect(false, "premier rapport : pas de base") }
        if case .noBase(let reason) = ReportFollowUp.result(history: history, choice: .date("2026-09-01"), current: current) {
            try expect(reason.contains("1 septembre 2026"), "date sans rapport : \(reason)")
        } else { try expect(false, "date sans rapport") }

        // Section du document : juste après le résumé, KPI et tableaux.
        var input = ReportInput(devices: currentDevices(), now: current.created)
        input.followUp = ReportFollowUp.result(history: history, choice: .last, current: current)
        let config = ReportConfig(template: .audit, sections: [.resume, .suivi, .problemes], site: "Siège", date: "2026-11-03")
        let document = ReportBuilder.build(config: config, input: input)
        try expectEqual(document.sections.map(\.heading), ["1. Résumé", "2. Depuis le dernier rapport", "3. Problèmes et recommandations"], "ordre")
        let section = document.section(.suivi)!
        guard case .paragraph(let text) = section.blocks[0] else { throw TestFailure(message: "paragraphe", file: #fileID, line: #line) }
        try expect(text.contains("du 6 octobre 2026 (il y a 28 jours)"), "base et âge : \(text)")
        try expect(text.contains("3 appareils nouveaux") && text.contains("2 problèmes réglés"), "résumé : \(text)")
        guard case .kpis(let kpis) = section.blocks[1] else { throw TestFailure(message: "KPI", file: #fileID, line: #line) }
        try expectEqual(kpis.map(\.value), ["+3", "−1", "3", "2", "1"], "KPI")
        try expectEqual(kpis[3].tone, .success, "réglés en vert")
        try expectEqual(section.tables.count, 2, "tableaux appareils et problèmes")
        try expectEqual(section.tables[0].rows.count, 3 + 1 + 3, "lignes d'appareils")
        try expectEqual(section.tables[1].rows.map { $0.cells[0].text }, ["Réglé", "Réglé", "Nouveau"], "lignes de problèmes")
        // Exports : la section suit dans le CSV, le JSON et le HTML.
        try expect(ReportExport.html(document, logoDataURL: nil).contains("Depuis le dernier rapport"), "HTML")
        try expect(ReportExport.csv(document).contains("Nouveau"), "CSV")

        // Sans changement.
        let same = ReportFollowUp.blocks(.compared(ReportFollowUp.compare(base: last, current: last)), now: last.created)
        guard case .paragraph(let unchanged) = same[0] else { throw TestFailure(message: "paragraphe", file: #fileID, line: #line) }
        try expect(unchanged.contains("Aucun changement"), "aucun changement")

        // Instantané d'un rapport : appareils et problèmes de l'entrée.
        var probe = ReportInput(devices: baseDevices(), scanDate: f0, now: f0)
        probe.followUpIssues = [probeIssue]
        let made = ReportSnapshot.make(input: probe, siteKey: "S1", siteName: "Siège", created: f0, reportDate: "2026-11-03",
                                       title: "Audit réseau — Siège", fileName: "a.pdf")
        try expectEqual(made.devices.count, 7, "appareils gardés")
        try expectEqual(made.scanDate, f0, "date du scan")
        try expect(made.issues.contains(probeIssue), "problème de sonde gardé")

        // Historique : plafond, doublon de fichier, retrait, lecture tolérante sur le disque.
        var book = ReportHistory()
        for i in 0..<(ReportHistory.maxSnapshots + 5) {
            var entry = snapshot([], issues: [], created: f0.addingTimeInterval(Double(i) * 3600), day: "2026-10-\(String(format: "%02d", i % 28 + 1))")
            entry.fileName = "rapport-\(i).pdf"
            book.add(entry)
        }
        try expectEqual(book.snapshots.count, ReportHistory.maxSnapshots, "plafond")
        try expect(book.snapshots.first!.created > book.snapshots.last!.created, "le plus récent d'abord")
        let dup = book.snapshots[0]
        var again = dup
        again.id = UUID()
        again.created = dup.created.addingTimeInterval(60)
        book.add(again)
        try expectEqual(book.snapshots.filter { $0.fileName == dup.fileName }.count, 1, "même fichier remplacé")
        try expectEqual(book.remove(again.id)?.id, again.id, "retrait")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-suivi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = ReportHistory(snapshots: history)
        try saved.save(forSite: "S1/../x", in: folder)
        try expect(ReportHistory.url(forSite: "S1/../x", in: folder).lastPathComponent == "S1____x.json", "nom de fichier sûr")
        let loaded = ReportHistory.load(forSite: "S1/../x", in: folder)
        try expectEqual(loaded.snapshots.map(\.id), [last.id, older.id], "relu")
        try expectEqual(loaded.snapshots[0].devices, last.devices, "appareils relus")
        // Une entrée abîmée n'empêche pas de lire les autres.
        let raw = """
        {"version":1,"snapshots":[{"id":"not-a-uuid"},{"id":"\(older.id.uuidString)","created":"2026-10-01T10:00:00Z","format":"docx",
        "devices":[{"key":"ip:10.0.0.1","ip":"10.0.0.1","type":"robot"}],"issues":[{"key":"k","category":"inconnue"}]}]}
        """
        try FileManager.default.createDirectory(at: ReportHistory.directory(in: folder), withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: ReportHistory.url(forSite: "S2", in: folder))
        let tolerant = ReportHistory.load(forSite: "S2", in: folder)
        try expectEqual(tolerant.snapshots.count, 1, "entrée abîmée écartée")
        try expectEqual(tolerant.snapshots[0].format, .pdf, "format inconnu : PDF")
        try expectEqual(tolerant.snapshots[0].devices.first?.type, .inconnu, "type inconnu")
        try expectEqual(tolerant.snapshots[0].issues.first?.category, .reseau, "catégorie inconnue")
        try expectEqual(tolerant.snapshots[0].reportDate, "2026-10-01", "date du rapport déduite")
    }

    suite.add("Rapports planifiés : échéances (jour, semaine, mois), rattrapage unique et sans rafale") {
        let cal = ReportScheduler.calendar(TimeZone(identifier: "America/Toronto")!)
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        // Mercredi 4 novembre 2026, 9 h 30.
        let now = at(2026, 11, 4, 9, 30)
        var daily = ReportSchedule(name: "Quotidien", siteKeys: ["S1"], cadence: .daily, hour: 7, minute: 0, activeSince: at(2026, 10, 1))
        try expectEqual(ReportScheduler.slot(onOrBefore: now, daily, calendar: cal), at(2026, 11, 4, 7), "jour : ce matin")
        try expectEqual(ReportScheduler.nextSlot(after: now, daily, calendar: cal), at(2026, 11, 5, 7), "jour : demain")
        try expectEqual(ReportScheduler.slot(onOrBefore: at(2026, 11, 4, 6), daily, calendar: cal), at(2026, 11, 3, 7), "avant l'heure : hier")

        let weekly = ReportSchedule(name: "Hebdo", siteKeys: ["S1"], cadence: .weekly, weekday: 2, hour: 7, minute: 0, activeSince: at(2026, 10, 1))
        try expectEqual(ReportScheduler.slot(onOrBefore: now, weekly, calendar: cal), at(2026, 11, 2, 7), "lundi dernier")
        try expectEqual(ReportScheduler.nextSlot(after: now, weekly, calendar: cal), at(2026, 11, 9, 7), "lundi prochain")

        var monthly = ReportSchedule(name: "Mensuel", siteKeys: ["S1"], cadence: .monthly, monthDay: 31, hour: 6, minute: 30, activeSince: at(2026, 1, 1))
        try expectEqual(ReportScheduler.slot(onOrBefore: now, monthly, calendar: cal), at(2026, 10, 31, 6, 30), "31 octobre")
        try expectEqual(ReportScheduler.nextSlot(after: now, monthly, calendar: cal), at(2026, 11, 30, 6, 30), "novembre : le 30")
        try expectEqual(ReportScheduler.nextSlot(after: at(2027, 2, 1), monthly, calendar: cal), at(2027, 2, 28, 6, 30), "février : le 28")
        monthly.monthDay = 1
        try expectEqual(ReportScheduler.slot(onOrBefore: now, monthly, calendar: cal), at(2026, 11, 1, 6, 30), "le 1er")
        // Heure qui n'existe pas (passage à l'heure d'été, 8 mars 2026 à 2 h 30) : une échéance quand même.
        let spring = ReportSchedule(name: "Nuit", siteKeys: ["S1"], cadence: .daily, hour: 2, minute: 30, activeSince: at(2026, 1, 1))
        try expect(ReportScheduler.nextSlot(after: at(2026, 3, 8, 0, 0), spring, calendar: cal) != nil, "heure d'été")

        // Dû : la dernière échéance seulement, une fois ; jamais avant la création ou la modification.
        try expectEqual(ReportScheduler.dueSlot(daily, now: now, calendar: cal), at(2026, 11, 4, 7), "dû ce matin")
        daily.lastSlot = at(2026, 10, 28, 7)           // Mac éteint une semaine : 7 échéances manquées
        try expectEqual(ReportScheduler.dueSlot(daily, now: now, calendar: cal), at(2026, 11, 4, 7), "une seule échéance rattrapée")
        try expect(ReportScheduler.isCatchUp(slot: at(2026, 11, 4, 7), now: now), "rattrapage")
        try expect(!ReportScheduler.isCatchUp(slot: at(2026, 11, 4, 9, 25), now: now), "à l'heure")
        daily.lastSlot = at(2026, 11, 4, 7)
        try expect(ReportScheduler.dueSlot(daily, now: now, calendar: cal) == nil, "déjà produit")
        daily.lastSlot = nil
        daily.activeSince = at(2026, 11, 4, 8)          // créé à 8 h : rien de ce matin
        try expect(ReportScheduler.dueSlot(daily, now: now, calendar: cal) == nil, "pas d'échéance avant la création")
        daily.isEnabled = false
        daily.activeSince = at(2026, 1, 1)
        try expect(ReportScheduler.dueSlot(daily, now: now, calendar: cal) == nil, "désactivé")
        var noSite = weekly
        noSite.siteKeys = []
        try expect(ReportScheduler.dueSlot(noSite, now: now, calendar: cal) == nil, "sans site")

        // Plusieurs en retard : la plus ancienne d'abord ; écart minimal entre deux productions.
        let pending = ReportScheduler.pending([monthly, weekly], now: now, calendar: cal)
        try expectEqual(pending.map(\.slot), [at(2026, 11, 1, 6, 30), at(2026, 11, 2, 7)], "ordre du rattrapage")
        try expect(ReportScheduler.canProduce(lastProduction: nil, now: now), "première")
        try expect(!ReportScheduler.canProduce(lastProduction: now.addingTimeInterval(-5), now: now), "pas de rafale")
        try expect(ReportScheduler.canProduce(lastProduction: now.addingTimeInterval(-ReportScheduler.spacing), now: now), "après l'écart")
    }

    suite.add("Rapports planifiés : notification « Rapport planifié produit » activée pour les réglages déjà enregistrés") {
        // Réglages écrits avant la note 42 (sans « knownKinds ») : le nouveau type est activé par défaut.
        let old = NotificationSettings.decoded(Data(#"{"enabledKinds":["probeDown"]}"#.utf8))
        try expect(old.isEnabled(.reportReady), "nouveau type activé")
        try expect(!old.isEnabled(.probeWarning), "choix existants gardés")
        // Désactivé par l'utilisateur après coup : reste désactivé.
        var settings = NotificationSettings()
        settings.set(.reportReady, enabled: false)
        try expect(!NotificationSettings.decoded(settings.encoded()).isEnabled(.reportReady), "choix respecté")
    }

    suite.add("Rapports planifiés : textes, nom de fichier daté, âge du scan et fichier tolérant") {
        let cal = ReportScheduler.calendar(TimeZone(identifier: "America/Toronto")!)
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let s = "\u{00A0}"
        try expectEqual(ReportScheduler.rhythmLabel(ReportSchedule(name: "a", siteKeys: [], cadence: .daily, hour: 7, minute: 0)),
                        "Chaque jour à 7\(s)h\(s)00", "jour")
        try expectEqual(ReportScheduler.rhythmLabel(ReportSchedule(name: "a", siteKeys: [], cadence: .weekly, weekday: 2, hour: 7, minute: 5)),
                        "Chaque lundi à 7\(s)h\(s)05", "semaine")
        try expectEqual(ReportScheduler.rhythmLabel(ReportSchedule(name: "a", siteKeys: [], cadence: .monthly, monthDay: 1, hour: 6, minute: 30)),
                        "Le 1er de chaque mois à 6\(s)h\(s)30", "mois")
        try expectEqual(ReportScheduler.rhythmLabel(ReportSchedule(name: "a", siteKeys: [], cadence: .monthly, monthDay: 31, hour: 18, minute: 0)),
                        "Le 31 de chaque mois (ou le dernier jour) à 18\(s)h\(s)00", "fin de mois")
        try expectEqual(ReportScheduler.dateLabel(at(2026, 11, 9, 7), now: at(2026, 11, 4), calendar: cal), "lundi 9 novembre à 7\(s)h\(s)00", "date")
        try expectEqual(ReportScheduler.dateLabel(at(2027, 1, 1, 6, 30), now: at(2026, 11, 4), calendar: cal), "vendredi 1er janvier 2027 à 6\(s)h\(s)30", "autre année")

        let config = ReportConfig(template: .audit, client: "Groupe Exemple", site: "Siège")
        let slot = at(2026, 11, 9, 7)
        try expectEqual(ReportScheduler.fileName(pattern: ReportSchedule.defaultPattern, siteName: "Siège social", config: config, slot: slot,
                                                 format: .pdf, calendar: cal), "rapport-audit-siege-social-2026-11-09.pdf", "nom par défaut")
        try expectEqual(ReportScheduler.fileName(pattern: "suivi {client} {heure}", siteName: "Siège", config: config, slot: slot,
                                                 format: .html, calendar: cal), "suivi groupe-exemple 07h00-2026-11-09.html", "date ajoutée")
        try expectEqual(ReportScheduler.fileName(pattern: "../{site}/:{date}", siteName: "Entrepôt Laval", config: config, slot: slot,
                                                 format: .csv, calendar: cal), "entrepot-laval--2026-11-09.csv", "jamais de chemin")
        try expectEqual(ReportScheduler.fileName(pattern: "  ", siteName: "", config: config, slot: slot, format: .json, calendar: cal),
                        "rapport-audit-site-2026-11-09.json", "motif vide")
        try expectEqual(ReportScheduler.fileName(pattern: "{SITE}-{inconnu}-{date}", siteName: "Siège", config: config, slot: slot,
                                                 format: .pdf, calendar: cal), "siege-inconnu-2026-11-09.pdf", "jeton inconnu gardé sans accolades")

        let now = at(2026, 11, 9, 7)
        let fresh = ReportScheduler.scanNote(scanDate: at(2026, 11, 6, 9, 12), now: now, calendar: cal)
        try expect(fresh.contains("aucun scan n’a été lancé"), "jamais de scan")
        try expect(fresh.contains("du 2026-11-06 9\(s)h\(s)12 (il y a 2 jours)"), "date et âge : \(fresh)")
        try expect(!fresh.contains("plus de 7 jours"), "récent")
        let stale = ReportScheduler.scanNote(scanDate: at(2026, 10, 20, 9), now: now, calendar: cal)
        try expect(stale.contains("plus de 7 jours"), "ancien")
        try expect(ReportScheduler.scanNote(scanDate: nil, now: now, calendar: cal).contains("Aucun scan enregistré"), "aucun scan")
        try expectEqual(ReportScheduler.ageLabel(now.addingTimeInterval(-300), now: now), "il y a 5\(s)min", "minutes")
        try expectEqual(ReportScheduler.ageLabel(now.addingTimeInterval(-5 * 3600), now: now), "il y a 5\(s)h", "heures")

        var document = ReportBuilder.build(config: ReportConfig(sections: [.resume], site: "Siège", date: "2026-11-09"),
                                           input: ReportInput(devices: baseDevices(), now: now))
        ReportScheduler.annotate(&document, note: fresh)
        if case .note(let text) = document.sections[0].blocks[0] { try expectEqual(text, fresh, "note en tête") } else { try expect(false, "note en tête") }

        // Fichier : aller-retour et lecture tolérante.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-planifies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let schedule = ReportSchedule(name: "Suivi hebdomadaire", siteKeys: ["S1", "S2"], cadence: .weekly, weekday: 2, hour: 7, minute: 0,
                                      config: ReportConfig(template: .audit, sections: [.resume, .suivi, .problemes], format: .pdf),
                                      folder: "/tmp/x", email: .draft, emailTo: "direction@exemple.ca", activeSince: at(2026, 11, 1),
                                      lastSlot: at(2026, 11, 2, 7), lastStatus: .ok, lastFiles: ["a.pdf"])
        try ReportScheduleBook(schedules: [schedule]).save(to: folder)
        let loaded = ReportScheduleBook.load(from: folder)
        try expectEqual(loaded.schedules, [schedule], "relu à l'identique")
        let raw = """
        {"version":1,"schedules":[{"id":"x"},{"id":"\(UUID().uuidString)","name":"Ancien","cadence":"annuel","hour":99,"email":"envoyer"}]}
        """
        try Data(raw.utf8).write(to: folder.appendingPathComponent("planifies.json"))
        let tolerant = ReportScheduleBook.load(from: folder)
        try expectEqual(tolerant.schedules.count, 1, "entrée abîmée écartée")
        try expectEqual(tolerant.schedules[0].cadence, .weekly, "rythme inconnu")
        try expectEqual(tolerant.schedules[0].hour, 23, "heure bornée")
        try expectEqual(tolerant.schedules[0].email, .none, "jamais d'envoi : valeur inconnue → rien")
    }
}
