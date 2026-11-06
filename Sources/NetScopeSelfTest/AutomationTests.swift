import Foundation
import NetScopeCore

// Notes 63 et 64 (0.31.0) : scans planifiés par site (échéances, heure d'été, rattrapage après la
// veille), fusion d'un scan dans les fichiers d'un site, coordination de l'app et de l'agent, sondes
// en arrière-plan. Aucun réseau : dossiers temporaires et dates fixes.

private let torontoCalendar = ScanScheduler.calendar(TimeZone(identifier: "America/Toronto")!)

/// 2026-mm-jj h:mi, heure de Toronto.
private func tor(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    torontoCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-auto-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func registerAutomationTests(_ suite: TestSuite) {
    suite.add("Scans planifiés : échéances par jour de semaine, prochaine exécution et textes") {
        // Lundi 2 novembre 2026 → vendredi 6 novembre.
        let schedule = ScanSchedule(siteKey: "site", weekdays: [2, 4, 6], hour: 2, minute: 0, activeSince: tor(1, 1))
        try expectEqual(ScanScheduler.slot(on: tor(11, 2), schedule, calendar: torontoCalendar), tor(11, 2, 2), "lundi coché")
        try expect(ScanScheduler.slot(on: tor(11, 3), schedule, calendar: torontoCalendar) == nil, "mardi non coché")
        try expectEqual(ScanScheduler.nextSlot(after: tor(11, 2, 2), schedule, calendar: torontoCalendar), tor(11, 4, 2), "après lundi 2 h : mercredi")
        try expectEqual(ScanScheduler.nextSlot(after: tor(11, 6, 3), schedule, calendar: torontoCalendar), tor(11, 9, 2), "après vendredi : lundi suivant")
        try expectEqual(ScanScheduler.slot(onOrBefore: tor(11, 3, 12), schedule, calendar: torontoCalendar), tor(11, 2, 2), "dernière échéance")
        try expectEqual(ScanScheduler.daysLabel([2, 3, 4, 5, 6]), "Du lundi au vendredi", "semaine")
        try expectEqual(ScanScheduler.daysLabel([1, 2, 3, 4, 5, 6, 7]), "Chaque jour", "tous les jours")
        try expectEqual(ScanScheduler.daysLabel([1, 2, 4]), "lun. mer. dim.", "dimanche à la fin")
        try expectEqual(ScanScheduler.rhythmLabel(schedule), "lun. mer. ven. à 2\u{00A0}h\u{00A0}00", "rythme")
        try expectEqual(ScanScheduler.dateLabel(tor(11, 3, 2), now: tor(11, 2, 14), calendar: torontoCalendar), "demain à 2\u{00A0}h\u{00A0}00", "demain")
        var paused = schedule
        paused.isEnabled = false
        try expect(ScanScheduler.nextSlot(after: tor(11, 2), paused, calendar: torontoCalendar) == nil, "en pause : aucune prochaine")
        let empty = ScanSchedule(siteKey: "site", weekdays: [9, 0])
        try expect(empty.weekdays.isEmpty, "jours invalides écartés")
        try expectEqual(ScanScheduler.decision(empty, now: tor(11, 2, 3), calendar: torontoCalendar), .idle, "aucun jour : rien")
    }

    suite.add("Scans planifiés : heure d’été (heure absente et heure doublée)") {
        let daily = Array(1...7)
        // 8 mars 2026 : 2 h → 3 h. 2 h 30 n'existe pas : première heure qui existe après (3 h 00), même jour.
        let spring = ScanSchedule(siteKey: "site", weekdays: daily, hour: 2, minute: 30, activeSince: tor(1, 1))
        let slot = try ScanScheduler.slot(on: tor(3, 8, 12), spring, calendar: torontoCalendar).required("échéance du 8 mars")
        try expect(torontoCalendar.isDate(slot, inSameDayAs: tor(3, 8, 12)), "même jour")
        try expectEqual(torontoCalendar.component(.hour, from: slot), 3, "3 h")
        try expectEqual(ScanScheduler.slot(on: tor(3, 9), spring, calendar: torontoCalendar), tor(3, 9, 2, 30), "lendemain : 2 h 30")
        // 1er novembre 2026 : 2 h → 1 h. 1 h 30 existe deux fois : une seule échéance, la première (HAE, 5 h 30 UTC).
        let autumn = ScanSchedule(siteKey: "site", weekdays: daily, hour: 1, minute: 30, activeSince: tor(1, 1))
        let first = try ScanScheduler.slot(on: tor(11, 1, 12), autumn, calendar: torontoCalendar).required("échéance du 1er novembre")
        try expectEqual(first, Date(timeIntervalSince1970: 1_793_511_000), "1 h 30 HAE (05:30 UTC)")
        var done = autumn
        done.lastSlot = first
        // Une heure plus tard, 1 h 30 « revient » (HNE) : pas de second scan.
        try expectEqual(ScanScheduler.decision(done, now: first.addingTimeInterval(3_600 + 60), calendar: torontoCalendar), .idle,
                        "heure doublée : un seul scan")
        try expectEqual(ScanScheduler.nextSlot(after: first, autumn, calendar: torontoCalendar), tor(11, 2, 1, 30), "suivante : le 2")
    }

    suite.add("Scans planifiés : rattrapage unique après la veille, échéance manquée, jamais deux scans") {
        let schedule = ScanSchedule(siteKey: "site", weekdays: Array(1...7), hour: 2, minute: 0, activeSince: tor(11, 1),
                                    lastSlot: tor(11, 2, 2))
        try expectEqual(ScanScheduler.decision(schedule, now: tor(11, 3, 1, 59), calendar: torontoCalendar), .idle, "avant l’heure")
        try expectEqual(ScanScheduler.decision(schedule, now: tor(11, 3, 2, 5), calendar: torontoCalendar),
                        .run(slot: tor(11, 3, 2), catchUp: false), "à l’heure")
        try expectEqual(ScanScheduler.decision(schedule, now: tor(11, 3, 4, 20), calendar: torontoCalendar),
                        .run(slot: tor(11, 3, 2), catchUp: true), "réveil à 4 h 20 : rattrapé")
        try expectEqual(ScanScheduler.decision(schedule, now: tor(11, 3, 9), calendar: torontoCalendar),
                        .missed(slot: tor(11, 3, 2)), "réveil à 9 h : manqué, pas de scan")
        // Trois nuits de veille : seule la dernière échéance compte (pas de rafale).
        try expectEqual(ScanScheduler.decision(schedule, now: tor(11, 6, 2, 30), calendar: torontoCalendar),
                        .run(slot: tor(11, 6, 2), catchUp: true), "trois nuits : une seule exécution")
        var finished = schedule
        finished.lastSlot = tor(11, 6, 2)
        try expectEqual(ScanScheduler.decision(finished, now: tor(11, 6, 2, 31), calendar: torontoCalendar), .idle, "faite : rien")
        // Créé (ou modifié) après l'échéance : rien n'est rattrapé.
        let fresh = ScanSchedule(siteKey: "site", weekdays: Array(1...7), hour: 2, minute: 0, activeSince: tor(11, 3, 2, 10))
        try expectEqual(ScanScheduler.decision(fresh, now: tor(11, 3, 2, 15), calendar: torontoCalendar), .idle, "créé après : rien")
        let other = ScanSchedule(siteKey: "autre", weekdays: Array(1...7), hour: 1, minute: 0, activeSince: tor(11, 1))
        let pending = ScanScheduler.pending([schedule, other], now: tor(11, 3, 2, 30), calendar: torontoCalendar)
        try expectEqual(pending.map(\.id), [other.id, schedule.id], "la plus ancienne échéance d’abord")
        try expectEqual(ScanScheduler.nextRun([schedule, other], after: tor(11, 3, 2, 30), calendar: torontoCalendar)?.date, tor(11, 4, 1),
                        "prochaine, tous sites confondus")
        try expect(ScanScheduler.canStart(scanRunning: false, scheduledRunning: false), "libre")
        try expect(!ScanScheduler.canStart(scanRunning: true, scheduledRunning: false), "scan manuel en cours")
        try expect(!ScanScheduler.canStart(scanRunning: false, scheduledRunning: true), "autre scan planifié en cours")
    }

    suite.add("Scans planifiés : fichier, journal plafonné, lecture tolérante") {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schedule = ScanSchedule(siteKey: "site", profile: .complet, activeSince: tor(11, 1))
        var book = ScanScheduleBook(schedules: [schedule])
        for index in 0..<(ScanScheduleBook.maxRuns + 5) {
            book.record(ScanRunEntry(date: tor(11, 1).addingTimeInterval(Double(index)), siteKey: "site", siteName: "Site",
                                     host: .agent, outcome: .ok, message: "n° \(index)"))
        }
        try expectEqual(book.runs.count, ScanScheduleBook.maxRuns, "journal plafonné")
        try expectEqual(book.runs.first?.message, "n° \(ScanScheduleBook.maxRuns + 4)", "plus récent en tête")
        let entry = ScanRunEntry(date: tor(11, 3, 2, 3), slot: tor(11, 3, 2), scheduleID: schedule.id, siteKey: "site", siteName: "Site",
                                 host: .app, outcome: .ok, online: 12, newCount: 1, duration: 63, message: "ok")
        book.finish(schedule.id, slot: tor(11, 3, 2), entry: entry)
        try book.save(to: directory)
        let loaded = ScanScheduleBook.load(from: directory)
        try expectEqual(loaded.schedules.first?.lastSlot, tor(11, 3, 2), "échéance notée")
        try expectEqual(loaded.schedules.first?.profile, .complet, "profil relu")
        try expectEqual(loaded.schedules.first?.lastOutcome, .ok, "issue relue")
        try expectEqual(loaded.runs.first?.host, .app, "hôte relu")
        // Un scan planifié illisible n'empêche pas de lire les autres.
        let text = #"{"version":1,"schedules":[{"id":"pas-un-uuid"},{"id":"\#(UUID().uuidString)","siteKey":"x","profile":"inconnu"}],"runs":[]}"#
        try Data(text.utf8).write(to: ScanScheduleBook.url(in: directory))
        let lenient = ScanScheduleBook.load(from: directory)
        try expectEqual(lenient.schedules.count, 1, "entrée illisible écartée")
        try expectEqual(lenient.schedules.first?.profile, .rapide, "profil inconnu : Rapide")
        try expectEqual(ScanScheduler.summary(online: 42, new: 2, duration: 75), "42 en ligne, 2 nouveaux, 1\u{00A0}min\u{00A0}15\u{00A0}s", "résumé")
    }

    suite.add("Scan d’un site sans interface : fusion, nouveaux appareils, hors ligne, plages exclues, fichiers") {
        let range = try IPRange(parsing: "10.9.0.0/24")
        let exclusions = AddressExclusions([ExcludedRange(text: "10.9.0.200-10.9.0.210")])
        let mac = MACAddress("00:11:22:33:44:55")!
        let start = tor(11, 3, 2)
        // Premier scan : rien n'est « nouveau ».
        let first = SiteScanMerge.merge(previous: SiteResults(), found: [Device(ip: IPv4Address("10.9.0.1")!, mac: mac, hostname: "routeur")],
                                        ranges: [range], exclusions: exclusions, startedAt: start, finishedAt: start)
        try expect(first.newDevices.isEmpty, "premier scan : aucun nouveau")
        var previous = first.results
        previous.devices.append(Device(ip: IPv4Address("10.9.0.20")!, isOnline: true))
        previous.devices.append(Device(ip: IPv4Address("10.9.0.205")!, isOnline: true))
        previous.devices.append(Device(ip: IPv4Address("10.8.0.5")!, isOnline: true))
        let found = [Device(ip: IPv4Address("10.9.0.1")!, hostname: nil), Device(ip: IPv4Address("10.9.0.30")!, hostname: "imprimante")]
        let second = SiteScanMerge.merge(previous: previous, found: found, ranges: [range], exclusions: exclusions,
                                         startedAt: start, finishedAt: start.addingTimeInterval(40))
        let byIP = Dictionary(uniqueKeysWithValues: second.results.devices.map { ($0.ip.description, $0) })
        try expectEqual(second.newDevices.map(\.ip.description), ["10.9.0.30"], "nouvel appareil")
        try expectEqual(byIP["10.9.0.1"]?.mac, mac, "MAC gardée")
        try expectEqual(byIP["10.9.0.1"]?.hostname, "routeur", "nom gardé")
        try expectEqual(byIP["10.9.0.20"]?.isOnline, false, "absent de la plage : hors ligne")
        try expectEqual(byIP["10.9.0.205"]?.isOnline, true, "plage exclue : état gardé")
        try expectEqual(byIP["10.8.0.5"]?.isOnline, true, "hors des plages : état gardé")
        try expectEqual(second.results.newIDs, ["10.9.0.30"], "nouveautés du site")
        try expectEqual(second.results.lastScanRanges, ["10.9.0.0/24"], "plages du scan")

        // Écriture dans les fichiers du site (résultats et inventaire), puis relecture.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SiteFiles(base: directory)
        files.saveResults(previous, for: "site")
        let capture = SiteScanCapture(key: "site", devices: found, ranges: [range], exclusions: exclusions,
                                      begin: start, end: start.addingTimeInterval(40), cancelled: false)
        let report = SiteScanRunner.commit(capture, files: files)
        try expectEqual(report.outcome, .ok, "bilan")
        try expectEqual(report.newDevices.count, 1, "un nouveau")
        try expectEqual(files.loadResults(for: "site")?.finishedAt, start.addingTimeInterval(40), "résultats écrits")
        try expect(files.inventoryCount(for: "site") >= 2, "inventaire alimenté")
        // Inventaire illisible : jamais écrasé, bilan partiel.
        try Data("abîmé".utf8).write(to: files.inventoryURL(for: "site"))
        let partial = SiteScanRunner.commit(capture, files: files)
        try expectEqual(partial.outcome, .partial, "inventaire illisible : partiel")
        try expectEqual(try String(contentsOf: files.inventoryURL(for: "site"), encoding: .utf8), "abîmé", "inventaire illisible gardé")
        // Site sans plage active : échec sans scan.
        let site = Site(name: "Vide", ranges: [ScanRangeConfig(text: "10.1.0.0/24", label: "", isEnabled: false)])
        let failed = await SiteScanRunner.run(SiteScanRequest(site: site, profile: .rapide), files: files, pinger: nil)
        try expectEqual(failed.outcome, .failed, "aucune plage : échec")
    }

    suite.add("Agent : présence de l’app, verrou partagé, réglages et journal") {
        let now = tor(11, 5, 10)
        let presence = AppPresence(pid: 4242, date: now.addingTimeInterval(-30), version: "0.31.0")
        try expect(AppPresence.isActive(presence, now: now, alive: { _ in true }), "app ouverte")
        try expect(!AppPresence.isActive(presence, now: now, alive: { _ in false }), "processus disparu")
        try expect(!AppPresence.isActive(presence, now: now.addingTimeInterval(AppPresence.staleAfter), alive: { _ in true }), "présence périmée")
        try expect(!AppPresence.isActive(nil, now: now), "aucune présence")
        try expect(AppPresence.processAlive(getpid()), "ce processus est vivant")

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AutomationFiles(base: directory)
        AppPresence(pid: getpid(), date: now, version: "test").save(files)
        try expectEqual(AppPresence.load(files)?.pid, getpid(), "présence relue")
        AppPresence.clear(files, pid: getpid() + 1)
        try expect(AppPresence.load(files) != nil, "autre pid : présence gardée")
        AppPresence.clear(files, pid: getpid())
        try expect(AppPresence.load(files) == nil, "présence effacée à la fermeture")

        // Verrou : pris une fois, refusé à un second demandeur tant qu'il est tenu.
        let inner = AutomationLock.with(files.lockURL) { () -> Int? in
            AutomationLock.with(files.lockURL, timeout: 0.2) { 1 }
        }
        try expect(inner != nil, "verrou pris")
        try expect(inner! == nil, "second demandeur refusé pendant l’écriture")
        try expectEqual(AutomationLock.with(files.lockURL, timeout: 0.2) { 2 }, 2, "verrou rendu")

        try expectEqual(AgentSettings.load(files), AgentSettings(), "réglages par défaut")
        try AgentSettings(monitor: true, syslog: false, scans: true).save(files)
        try expectEqual(AgentSettings.load(files).syslog, false, "réglages relus")
        var journal = AgentJournal()
        for index in 0..<(AgentJournal.maxEntries + 3) { journal.add(AgentJournalEntry(date: now, text: "\(index)")) }
        try expectEqual(journal.entries.count, AgentJournal.maxEntries, "journal plafonné")
        let status = AgentStatus(pid: 1, version: "0.31.0", startedAt: now, heartbeat: now, mode: .active)
        try expect(status.isResponding(now: now.addingTimeInterval(10)), "agent qui répond")
        try expect(!status.isResponding(now: now.addingTimeInterval(AgentStatus.staleAfter + 1)), "agent muet")
    }

    suite.add("Agent : sondes réseau en arrière-plan (panne, alerte, retour à la normale)") {
        let probe = MonProbe(name: "Passerelle", kind: .ping, target: "10.9.0.1", interval: 60)
        try expect(MonBackground.supports(probe), "ping repris par l’agent")
        try expect(!MonBackground.supports(MonProbe(name: "Switch", kind: .snmp, target: "10.9.0.2", interval: 60)), "SNMP : attend l’app")
        var archive = MonArchive(probes: [probe])
        var alerts: [MonAlert] = []
        var date = tor(11, 5, 10)
        for _ in 0..<probe.thresholds.failures {
            let outcome = MonRunOutcome(result: .failure(date))
            alerts += MonBackground.apply(outcome, probe: probe.id, archive: &archive, site: nil).alerts
            date = date.addingTimeInterval(60)
        }
        try expectEqual(archive.trackers[probe.id.uuidString]?.state, .down, "panne après les échecs")
        try expect(!alerts.isEmpty, "alerte créée")
        try expectEqual(archive.journal.openCount(probe: probe.id), 1, "alerte ouverte au journal")
        let back = MonBackground.apply(MonRunOutcome(result: MonResult(date: date, reachable: true, latencyMs: 2, lossPercent: 0, value: "2 ms")),
                                       probe: probe.id, archive: &archive, site: nil)
        try expect(back.recovered, "retour à la normale")
        try expectEqual(archive.trackers[probe.id.uuidString]?.state, .ok, "sonde rétablie")
        let ignored = MonBackground.apply(MonRunOutcome(result: .failure(date)), probe: UUID(), archive: &archive, site: nil)
        try expect(ignored.alerts.isEmpty && !ignored.recovered, "sonde supprimée : rien")
    }
}

private extension Optional {
    func required(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : valeur absente", file: file, line: line) }
        return value
    }
}
