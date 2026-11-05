import Foundation
import NetScopeCore

// Note 78 (Surveillance) : heures ouvrables par site, fenêtres de maintenance (ponctuelles et
// répétées), alertes suspendues et notées, rappel des alertes non accusées, historique de latence
// et de disponibilité de longue durée. Dates fixes, aucun réseau.

private let planCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    return calendar
}()

/// Novembre 2026 (heure de Montréal) ; le 2 est un lundi.
private func planDate(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
    planCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

func registerMonPlanningTests(_ suite: TestSuite) {
    suite.add("Surveillance : heures ouvrables par jour, résumé et horaire standard") {
        let standard = MonBusinessHours.standard
        try expect(standard.contains(planDate(2, 7), calendar: planCalendar), "lundi 7 h : ouvert")
        try expect(!standard.contains(planDate(2, 18), calendar: planCalendar), "lundi 18 h : fermé (fin exclue)")
        try expect(!standard.contains(planDate(7, 10), calendar: planCalendar), "samedi : fermé")
        try expectEqual(standard.summary, "lun.–ven. 7\u{00A0}h – 18\u{00A0}h", "résumé standard")
        // Même résultat que l'ancien horaire fixe, heure par heure sur une semaine.
        for day in 1...7 {
            for hour in 0..<24 {
                let date = planDate(day, hour, 30)
                try expectEqual(MonSchedule.businessHours.allowsAlerts(at: date, hours: .standard, calendar: planCalendar),
                                MonSchedule.isBusinessHours(date, calendar: planCalendar), "horaire standard \(day) \(hour) h")
            }
        }
        // Clinique : lun.–jeu. 8 h – 20 h, ven. 8 h – 16 h 30, sam. 9 h – 12 h.
        var clinic = MonBusinessHours.standard
        for index in 1...4 { clinic.days[index] = MonDayHours(isOpen: true, start: 8 * 60, end: 20 * 60) }
        clinic.days[5] = MonDayHours(isOpen: true, start: 8 * 60, end: 16 * 60 + 30)
        clinic.days[6] = MonDayHours(isOpen: true, start: 9 * 60, end: 12 * 60)
        try expectEqual(clinic.summary,
                        "lun.–jeu. 8\u{00A0}h – 20\u{00A0}h\u{00A0}; ven. 8\u{00A0}h – 16\u{00A0}h\u{00A0}30\u{00A0}; sam. 9\u{00A0}h – 12\u{00A0}h",
                        "jours regroupés")
        try expect(clinic.contains(planDate(5, 19, 59), calendar: planCalendar), "jeudi 19 h 59 : ouvert")
        try expect(!clinic.contains(planDate(6, 16, 30), calendar: planCalendar), "vendredi 16 h 30 : fermé")
        try expect(clinic.contains(planDate(7, 11), calendar: planCalendar), "samedi 11 h : ouvert")
        try expect(MonSchedule.offHours.allowsAlerts(at: planDate(7, 13), hours: clinic, calendar: planCalendar), "hors heures : samedi 13 h")
        try expectEqual(MonBusinessHours(days: (0..<7).map { _ in .closed }).summary, "Aucune heure ouvrable", "aucun jour")
        // Lecture tolérante : un horaire tronqué redevient l'horaire standard.
        let broken = try JSONDecoder().decode(MonBusinessHours.self, from: Data(#"{"days":[{"isOpen":true}]}"#.utf8))
        try expectEqual(broken, .standard, "horaire illisible")
    }

    suite.add("Surveillance : heures ouvrables propres au site de la sonde") {
        let siege = Site(name: "Siège", ranges: [ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau")])
        let laval = Site(name: "Entrepôt Laval", ranges: [ScanRangeConfig(text: "10.93.226.0/24", label: "Entrepôt")])
        var probe = MonProbe(name: "Imprimante", kind: .http, target: "https://10.93.226.40", schedule: .businessHours)
        try expectEqual(MonSiteResolver.site(for: probe, sites: [siege, laval], active: siege.id), laval.id, "site d'après la cible")
        probe.target = "8.8.8.8"
        try expectEqual(MonSiteResolver.site(for: probe, sites: [siege, laval], active: siege.id), siege.id, "Internet : site actif")
        probe.siteID = laval.id
        try expectEqual(MonSiteResolver.site(for: probe, sites: [siege, laval], active: siege.id), laval.id, "site choisi")
        try expectEqual(MonSiteResolver.address(of: "10.0.0.1:443")?.description, "10.0.0.1", "adresse d'une cible TCP")

        // L'entrepôt ouvre le samedi : une panne du samedi y crée une alerte, pas au siège.
        var planning = MonPlanning()
        var warehouse = MonBusinessHours.standard
        warehouse.days[6] = MonDayHours(isOpen: true, start: 6 * 60, end: 14 * 60)
        planning.siteHours[laval.id.uuidString] = warehouse
        let saturday = planDate(7, 10)
        let down = MonProbe(name: "Caméra", kind: .ping, target: "10.93.226.21", thresholds: MonThresholds(failures: 1),
                            schedule: .businessHours)
        let atLaval = MonStateMachine.evaluate(probe: down, tracker: MonTracker(), result: .failure(saturday), dependencyDown: false,
                                               calendar: planCalendar, gate: planning.gate(probe: down.id, site: laval.id, at: saturday, calendar: planCalendar))
        try expectEqual(atLaval.events.map(\.kind), [.down], "alerte à l'entrepôt le samedi")
        let atSiege = MonStateMachine.evaluate(probe: down, tracker: MonTracker(), result: .failure(saturday), dependencyDown: false,
                                               calendar: planCalendar, gate: planning.gate(probe: down.id, site: siege.id, at: saturday, calendar: planCalendar))
        try expect(atSiege.events.isEmpty, "aucune alerte au siège le samedi")
        try expectEqual(MonSchedule.businessHours.label(hours: warehouse),
                        "Heures ouvrables du site (lun.–ven. 7\u{00A0}h – 18\u{00A0}h\u{00A0}; sam. 6\u{00A0}h – 14\u{00A0}h)", "libellé")
    }

    suite.add("Surveillance : fenêtres de maintenance ponctuelles et répétées") {
        // Ponctuelle : lundi 2 novembre, 22 h à minuit.
        let once = MonMaintenanceWindow(name: "Remplacement du switch", start: planDate(2, 22), durationMinutes: 120)
        try expect(once.occurrence(containing: planDate(2, 23, 59), calendar: planCalendar) != nil, "pendant")
        try expect(once.occurrence(containing: planDate(3, 0), calendar: planCalendar) == nil, "fin exclue")
        try expect(once.occurrence(containing: planDate(2, 21, 59), calendar: planCalendar) == nil, "avant")
        try expect(once.isOver(at: planDate(3, 1), calendar: planCalendar), "terminée")

        // Chaque dimanche 2 h, 3 h (mises à jour FortiOS), sur un changement d'heure (1er novembre 2026).
        let weekly = MonMaintenanceWindow(name: "Mises à jour FortiOS", start: planDate(25, 2, month: 10), durationMinutes: 180,
                                          repeats: .weekly)
        try expect(weekly.occurrence(containing: planDate(1, 4), calendar: planCalendar) != nil, "dimanche du changement d'heure")
        try expect(weekly.occurrence(containing: planDate(8, 2, 30), calendar: planCalendar) != nil, "dimanche suivant")
        try expect(weekly.occurrence(containing: planDate(9, 2, 30), calendar: planCalendar) == nil, "lundi : non")
        try expectEqual(weekly.nextOccurrence(after: planDate(9, 12), calendar: planCalendar)?.start, planDate(15, 2), "prochaine")
        try expectEqual(weekly.rhythmLabel(calendar: planCalendar), "Chaque dimanche à 2\u{00A0}h, 3\u{00A0}h", "rythme")

        // Chaque jour 23 h, 2 h : déborde sur le lendemain.
        let daily = MonMaintenanceWindow(name: "Sauvegarde", start: planDate(2, 23), durationMinutes: 120, repeats: .daily,
                                         until: planDate(5, 23))
        try expect(daily.occurrence(containing: planDate(4, 0, 30), calendar: planCalendar) != nil, "après minuit")
        try expect(daily.occurrence(containing: planDate(6, 0, 30), calendar: planCalendar) != nil, "dernière occurrence (le 5)")
        try expect(daily.occurrence(containing: planDate(6, 23, 30), calendar: planCalendar) == nil, "après la fin")

        // Chaque mois le 31 : ramené au 30 en novembre, sans dériver ensuite.
        let monthly = MonMaintenanceWindow(name: "Fin de mois", start: planDate(31, 22, month: 10), durationMinutes: 60, repeats: .monthly)
        try expectEqual(monthly.nextOccurrence(after: planDate(1, 0), calendar: planCalendar)?.start, planDate(30, 22), "30 novembre")
        try expectEqual(monthly.nextOccurrence(after: planDate(1, 0, month: 12), calendar: planCalendar)?.start, planDate(31, 22, month: 12),
                        "31 décembre")

        // Portée : un site, ou des sondes précises.
        let siteA = UUID(), siteB = UUID(), probe = UUID()
        let scoped = MonMaintenanceWindow(name: "Site A", start: planDate(2, 22), siteID: siteA)
        try expect(scoped.applies(probe: probe, site: siteA) && !scoped.applies(probe: probe, site: siteB), "portée site")
        let precise = MonMaintenanceWindow(name: "Une sonde", start: planDate(2, 22), probeIDs: [probe])
        try expect(precise.applies(probe: probe, site: siteB) && !precise.applies(probe: UUID(), site: siteB), "portée sonde")
        var off = once
        off.isEnabled = false
        try expect(off.occurrence(containing: planDate(2, 23), calendar: planCalendar) == nil, "fenêtre désactivée")
    }

    suite.add("Surveillance : alerte suspendue et notée pendant la maintenance, puis envoyée si le problème dure") {
        let probe = MonProbe(name: "SW-CORE-01", kind: .ping, target: "10.182.122.2", thresholds: MonThresholds(failures: 2))
        let window = MonMaintenanceWindow(name: "Remplacement du switch", start: planDate(3, 22), durationMinutes: 60)
        let planning = MonPlanning(windows: [window])
        var tracker = MonTracker()
        var journal = MonJournal()
        var kinds: [MonEvent.Kind] = []
        var created: [MonAlert] = []
        for minute in stride(from: 0, through: 75, by: 5) {
            let date = planDate(3, 22).addingTimeInterval(Double(minute * 60))
            let gate = planning.gate(probe: probe.id, site: nil, at: date, calendar: planCalendar)
            let step = MonStateMachine.evaluate(probe: probe, tracker: tracker, result: .failure(date), dependencyDown: false,
                                                calendar: planCalendar, gate: gate)
            tracker = step.tracker
            kinds += step.events.map(\.kind)
            created += journal.record(step.events, probe: probe, date: date)
        }
        try expectEqual(kinds, [.suppressed, .down], "notée une fois pendant la fenêtre, alerte à la sortie")
        try expectEqual(created.count, 1, "seule l'alerte de 23 h est à notifier")
        try expectEqual(created.first?.date, planDate(3, 23), "alerte à la première vérification après la fenêtre")
        let note = try journal.alerts.first { $0.severity == .info }.unwrap("note de maintenance")
        try expect(note.message.contains("Remplacement du switch") && note.isAcknowledged && !note.isUnread, "note sans action requise")
        try expectEqual(journal.unreadCount, 1, "une alerte non lue")

        // Problème réglé pendant la fenêtre : aucune alerte ensuite.
        var calm = MonTracker()
        var events: [MonEvent] = []
        for (minute, ok) in [(0, false), (5, false), (10, true), (70, true)] {
            let date = planDate(3, 22).addingTimeInterval(Double(minute * 60))
            let result: MonResult = ok ? .success(date, latency: 1) : .failure(date)
            let step = MonStateMachine.evaluate(probe: probe, tracker: calm, result: result, dependencyDown: false, calendar: planCalendar,
                                                gate: planning.gate(probe: probe.id, site: nil, at: date, calendar: planCalendar))
            calm = step.tracker
            events += step.events
        }
        try expectEqual(events.map(\.kind), [.suppressed], "réglé pendant la maintenance : seulement la note")
        try expectEqual(calm.state, .ok, "revenu")
    }

    suite.add("Surveillance : rappel d'une alerte non accusée après N minutes, au plus N fois") {
        var journal = MonJournal()
        let probe = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21")
        let alert = journal.record([MonEvent(.down, "192.168.50.21 ne répond plus.")], probe: probe, date: planDate(3, 12))[0]
        journal.add(MonAlert(date: planDate(3, 12), probeID: nil, probeName: "Note", severity: .info, message: "Information"))
        try expect(MonReminder.due(journal, minutes: 30, limit: 2, now: planDate(3, 12, 29)).isEmpty, "trop tôt")
        try expectEqual(MonReminder.due(journal, minutes: 30, limit: 2, now: planDate(3, 12, 30)), [alert.id], "30 min")
        try expect(MonReminder.due(journal, minutes: 0, limit: 2, now: planDate(3, 18)).isEmpty, "rappel désactivé")
        journal.markReminded(alert.id, at: planDate(3, 12, 30))
        try expect(MonReminder.due(journal, minutes: 30, limit: 2, now: planDate(3, 12, 45)).isEmpty, "compté depuis le dernier rappel")
        try expectEqual(MonReminder.due(journal, minutes: 30, limit: 2, now: planDate(3, 13)).count, 1, "deuxième rappel")
        journal.markReminded(alert.id, at: planDate(3, 13))
        try expect(MonReminder.due(journal, minutes: 30, limit: 2, now: planDate(3, 15)).isEmpty, "limite atteinte")
        try expectEqual(journal.alerts.first { $0.id == alert.id }?.reminderCount, 2, "deux rappels")
        try expect(MonReminder.message(for: alert, now: planDate(3, 12, 30)).hasPrefix("Toujours non accusée après 30\u{00A0}min"), "texte")
        // Accusée : plus de rappel.
        var acked = journal
        acked.acknowledge(alert.id, by: "Dany", at: planDate(3, 13, 5))
        try expect(MonReminder.due(acked, minutes: 30, limit: 9, now: planDate(3, 18)).isEmpty, "accusée")
    }

    suite.add("Surveillance : latence sur 24 h et 7 j, disponibilité par jour, maintenance hors disponibilité") {
        var history = MonHistory()
        let id = UUID()
        // Lundi 2 novembre : 4 vérifications réussies (2, 4, 6, 8 ms), une panne déclarée de 5 min.
        for (minute, latency) in [(0, 2.0), (5, 4.0), (10, 6.0), (15, 8.0)] {
            history.record(probe: id, result: .success(planDate(2, 9, minute), latency: latency), state: .ok, interval: 300,
                           calendar: planCalendar)
        }
        history.record(probe: id, result: .failure(planDate(2, 9, 20)), state: .down, interval: 300, calendar: planCalendar)
        // Pendant une maintenance : un échec qui ne compte pas.
        history.record(probe: id, result: .failure(planDate(2, 23, 10)), state: .down, interval: 300, inMaintenance: true,
                       calendar: planCalendar)
        // Mardi : tout va bien.
        history.record(probe: id, result: .success(planDate(3, 9), latency: 3), state: .ok, interval: 300, calendar: planCalendar)

        let day = history.latencySeries(probe: id, range: .day, now: planDate(3, 9, 5), calendar: planCalendar)
        try expectEqual(day.count, 144, "144 cases de 10 min")
        try expectEqual(day.last?.average, 3, "dernière case")
        let week = history.latencySeries(probe: id, range: .week, now: planDate(3, 9, 5), calendar: planCalendar)
        try expectEqual(week.count, 168, "168 heures")
        let nine = try week.first { $0.start == planDate(2, 9) }.unwrap("lundi 9 h")
        try expectEqual(nine.average, 5, "moyenne de l'heure")
        try expectEqual(nine.maximum, 8, "maximum de l'heure")
        try expectEqual(nine.failures, 1, "un échec")
        try expect(week.first { $0.start == planDate(2, 23) }?.maintenance == true, "heure en maintenance")
        try expectEqual(history.slots(probe: id, now: planDate(3, 0, 30), calendar: planCalendar).last, MonSlot.none, "minuit vide")
        try expectEqual(history.slots(probe: id, now: planDate(2, 23, 30), calendar: planCalendar).last, MonSlot.maintenance,
                        "case de maintenance")
        let summary = MonHistory.latencySummary(week)
        try expectEqual(summary.maximum, 8, "maximum")
        try expectEqual(summary.failures, 1, "échecs hors maintenance")

        let daily = history.dailyAvailability(probe: id, days: 3, end: planDate(3, 12), calendar: planCalendar)
        try expectEqual(daily.map(\.percent), [nil, 80, 100], "dimanche sans donnée, lundi 4 sur 5, mardi 100 %")
        let monday = try history.dayBuckets(probe: id, from: planDate(2, 0), to: planDate(2, 23), calendar: planCalendar).first.unwrap("lundi")
        try expectEqual(monday.downSeconds, 300, "5 min hors ligne (la maintenance ne compte pas)")
        try expectEqual(monday.maintenance, 1, "une vérification en maintenance")
        try expectEqual(monday.latencyCount, 4, "quatre mesures")

        // Lecture d'un historique d'une version précédente (heures seulement).
        let old = #"{"buckets":{"\#(id.uuidString)":[{"hour":"2026-11-02T14:00:00Z","total":2,"failures":0,"downs":0,"warnings":0}]}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MonHistory.self, from: Data(old.utf8))
        try expectEqual(back.buckets[id.uuidString]?.count, 1, "heures relues")
        try expect(back.fine.isEmpty && back.days.isEmpty, "nouveaux historiques vides")
    }

    suite.add("Surveillance : planification enregistrée avec les sondes, lecture tolérante") {
        let site = UUID()
        var hours = MonBusinessHours.standard
        hours.days[6] = MonDayHours(isOpen: true, start: 9 * 60, end: 12 * 60)
        var probe = MonProbe(name: "Ping", kind: .ping, target: "10.0.0.1")
        probe.siteID = site
        let planning = MonPlanning(siteHours: [site.uuidString: hours],
                                   windows: [MonMaintenanceWindow(name: "Nuit", start: planDate(2, 23), repeats: .daily, siteID: site)],
                                   reminderMinutes: 30, reminderLimit: 2)
        let archive = MonArchive(probes: [probe], planning: planning)
        let back = try MonArchive.decode(archive.encoded())
        try expectEqual(back.planning, planning, "planification relue")
        try expectEqual(back.probes.first?.siteID, site, "site de la sonde relu")
        try expectEqual(back.planning.hours(for: site), hours, "horaire du site")
        try expectEqual(back.planning.hours(for: UUID()), .standard, "autre site : horaire par défaut")
        // Fichier d'une version précédente (sans planification) : valeurs par défaut.
        let legacy = try MonArchive.decode(Data(#"{"version":1,"probes":[]}"#.utf8))
        try expectEqual(legacy.planning, MonPlanning(), "planification absente")
        // Fenêtre illisible (répétition inconnue) : lue comme ponctuelle ; fenêtre sans date : écartée seule.
        let mixed = #"{"windows":[{"id":"\#(UUID().uuidString)","name":"A","start":"2026-11-02T03:00:00Z","repeats":"yearly"},{"id":"\#(UUID().uuidString)","name":"B"}],"reminderMinutes":15}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tolerant = try decoder.decode(MonPlanning.self, from: Data(mixed.utf8))
        try expectEqual(tolerant.windows.map(\.name), ["A"], "fenêtre sans date écartée")
        try expectEqual(tolerant.windows.first?.repeats, .once, "répétition inconnue")
        try expectEqual(tolerant.reminderMinutes, 15, "rappel relu")
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
