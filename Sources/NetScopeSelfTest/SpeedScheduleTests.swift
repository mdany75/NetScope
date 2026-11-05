import Foundation
@testable import NetScopeCore

// Note 78 (Speedtest) : débit Internet planifié par site. Aucun test de débit n'est lancé : les
// résultats sont des enregistrements fabriqués ici.

func registerSpeedScheduleTests(_ suite: TestSuite) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
    let siege = UUID(uuidString: "5A7E0028-0001-4C1E-9A11-00000000A001")!
    let laval = UUID(uuidString: "5A7E0028-0002-4C1E-9A11-00000000A002")!

    suite.add("Débit planifié : une fois par jour à l'heure choisie, rattrapage dans la journée") {
        var schedule = SpeedSchedule(siteID: siege, isEnabled: true, time: DayMinute(hour: 7, minute: 30),
                                     armedAt: at("2026-11-01 12:00"))
        try expect(!SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-05 07:29"), calendar: calendar), "avant l'heure")
        try expect(SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-05 07:30"), calendar: calendar), "à l'heure")
        try expect(SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-05 13:10"), calendar: calendar), "Mac réveillé plus tard : rattrapé")
        schedule.lastRun = at("2026-11-05 07:31")
        try expect(!SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-05 18:00"), calendar: calendar), "déjà fait aujourd'hui")
        try expectEqual(SpeedSchedulePlanner.nextRun(schedule, now: at("2026-11-05 18:00"), calendar: calendar),
                        at("2026-11-06 07:30"), "prochain : demain 7 h 30")
        try expect(SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-06 07:30"), calendar: calendar), "le lendemain")
        try expectEqual(SpeedSchedulePlanner.nextRun(schedule, now: at("2026-11-06 06:00"), calendar: calendar),
                        at("2026-11-06 07:30"), "plus tard aujourd'hui")
        schedule.isEnabled = false
        try expect(!SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-07 09:00"), calendar: calendar), "désactivé")
        try expectEqual(SpeedSchedulePlanner.nextRun(schedule, now: at("2026-11-07 09:00"), calendar: calendar), nil, "pas de prochain test")
    }

    suite.add("Débit planifié : pas de test à la seconde où on l'active") {
        let schedule = SpeedSchedule(siteID: laval, isEnabled: true, time: DayMinute(hour: 7), armedAt: at("2026-11-05 10:00"))
        try expect(!SpeedSchedulePlanner.isDue(schedule, now: at("2026-11-05 10:01"), calendar: calendar), "échéance d'avant l'activation")
        try expectEqual(SpeedSchedulePlanner.nextRun(schedule, now: at("2026-11-05 10:01"), calendar: calendar),
                        at("2026-11-06 07:00"), "premier test demain")
        let later = SpeedSchedule(siteID: laval, isEnabled: true, time: DayMinute(hour: 16), armedAt: at("2026-11-05 10:00"))
        try expect(SpeedSchedulePlanner.isDue(later, now: at("2026-11-05 16:00"), calendar: calendar), "heure encore à venir : aujourd'hui")
        // Passage à l'heure d'hiver (1er novembre 2026 à Toronto) : l'heure reste 7 h locales.
        try expectEqual(SpeedSchedulePlanner.slot(on: at("2026-11-01 12:00"), time: DayMinute(hour: 7), calendar: calendar),
                        at("2026-11-01 07:00"), "jour du changement d'heure")
    }

    suite.add("Débit planifié : report pendant un scan, un test en cours ou une connexion limitée") {
        let ok = NetworkPathStatus(isSatisfied: true)
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: false, testRunning: false, path: ok), nil, "peut partir")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: true, testRunning: false, path: ok), .scanning, "scan")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: true, testRunning: true, path: ok), .testRunning, "test en cours")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: false, testRunning: false,
                                                     path: NetworkPathStatus(isSatisfied: true, isExpensive: true)),
                        .limitedConnection, "partage de connexion")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: false, testRunning: false,
                                                     path: NetworkPathStatus(isSatisfied: true, isConstrained: true)),
                        .limitedConnection, "données réduites")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: false, testRunning: false, path: nil), .offline, "état inconnu")
        try expectEqual(SpeedSchedulePlanner.blocker(isScanning: false, testRunning: false,
                                                     path: NetworkPathStatus(isSatisfied: false)), .offline, "hors ligne")
    }

    suite.add("Débit planifié : seuil d'alerte et texte de l'alerte") {
        let schedule = SpeedSchedule(siteID: siege, isEnabled: true, minDownMbps: 300, minUpMbps: 100)
        try expect(!SpeedSchedulePlanner.verdict(downMbps: 912, upMbps: 487, schedule: schedule).isBelow, "au-dessus")
        let down = SpeedSchedulePlanner.verdict(downMbps: 212, upMbps: 487, schedule: schedule)
        try expect(down.downLow && !down.upLow, "descente sous le seuil")
        try expect(SpeedSchedulePlanner.verdict(downMbps: 912, upMbps: 42.5, schedule: schedule).upLow, "montée sous le seuil")
        try expect(!SpeedSchedulePlanner.verdict(downMbps: 912, upMbps: nil, schedule: schedule).upLow, "montée non mesurée")
        try expect(!SpeedSchedulePlanner.verdict(downMbps: 1, upMbps: 1, schedule: SpeedSchedule(siteID: nil)).isBelow, "sans seuil")
        let text = SpeedSchedulePlanner.alertText(siteName: "Siège", downMbps: 212, upMbps: 42.5, schedule: schedule)
        try expectEqual(text.title, "Débit Internet sous le seuil\u{00A0}: Siège", "titre")
        try expectEqual(text.detail, "Test planifié\u{00A0}: descente 212 Mb/s pour un seuil de 300 Mb/s\u{00A0}; montée 42,5 Mb/s pour un seuil de 100 Mb/s.", "détail")
    }

    suite.add("Débit planifié : courbe par site sur 30 jours et résumé") {
        let now = at("2026-11-05 12:00")
        func record(_ date: String, _ down: Double, site: UUID?, planned: Bool = true, kind: SpeedTestKind = .internet) -> SpeedTestRecord {
            SpeedTestRecord(date: at(date), kind: kind, origin: planned ? SpeedTestRecord.plannedOrigin : "manuel",
                            server: "Cloudflare", interfaceName: "en7", interfaceKind: "Ethernet", downMbps: down,
                            upMbps: down / 2, latencyMs: 6, siteID: site, siteName: site == siege ? "Siège" : "Laval")
        }
        let records = [
            record("2026-11-05 07:00", 900, site: siege),
            record("2026-11-04 07:00", 250, site: siege),
            record("2026-11-04 15:00", 880, site: siege),           // deuxième test du jour : le dernier compte
            record("2026-11-03 07:00", 870, site: siege, planned: false), // manuel : hors courbe
            record("2026-11-03 07:00", 120, site: laval),            // autre site
            record("2026-10-07 07:00", 860, site: siege),            // 29 jours avant : dans la fenêtre
            record("2026-10-06 07:00", 10, site: siege),             // 30 jours avant : hors fenêtre
            record("2026-11-02 07:00", 800, site: siege, kind: .lan),
        ]
        let points = SpeedSchedulePlanner.dailySeries(records, siteID: siege, now: now, calendar: calendar)
        try expectEqual(points.map(\.downMbps), [860, 880, 900], "un point par jour, du plus ancien au plus récent")
        try expectEqual(points.map(\.day), [at("2026-10-07 00:00"), at("2026-11-04 00:00"), at("2026-11-05 00:00")], "jours")
        try expectEqual(SpeedSchedulePlanner.dailySeries(records, siteID: laval, now: now, calendar: calendar).count, 1, "Laval")
        let schedule = SpeedSchedule(siteID: siege, minDownMbps: 870)
        let summary = SpeedSchedulePlanner.summary(points, schedule: schedule)
        try expectEqual(summary.count, 3, "trois jours")
        try expectEqual(summary.averageDown, (860 + 880 + 900) / 3, "moyenne")
        try expectEqual(summary.minDown, 860, "minimum")
        try expectEqual(summary.daysBelow, 1, "un jour sous 870 Mb/s")
        try expectEqual(SpeedSchedulePlanner.summary([], schedule: schedule).averageDown, nil, "aucun test")
    }

    suite.add("Débit planifié : réglages par site et fichier") {
        var book = SpeedScheduleBook()
        try expect(!book.schedule(for: siege).isEnabled, "désactivé par défaut")
        try expectEqual(book.schedule(for: siege).time, DayMinute(hour: 7), "7 h par défaut")
        book.set(SpeedSchedule(siteID: siege, isEnabled: true, time: DayMinute(hour: 6, minute: 45), minDownMbps: 300,
                               lastRun: at("2026-11-05 06:45"), lastStatus: .below(downMbps: 212, upMbps: 480)))
        book.set(SpeedSchedule(siteID: nil, isEnabled: true))
        book.set(SpeedSchedule(siteID: siege, isEnabled: false, time: DayMinute(hour: 6, minute: 45)))
        try expectEqual(book.schedules.count, 2, "un réglage par site")
        try expect(!book.schedule(for: siege).isEnabled, "remplacé")
        try expectEqual(SpeedSchedule(siteID: nil).id, "sans-site", "clé sans site")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SpeedScheduleFile(url: folder.appendingPathComponent("speedtest-planifie.json"))
        try expectEqual(file.load(), SpeedScheduleBook(), "fichier absent")
        var saved = SpeedScheduleBook()
        saved.set(SpeedSchedule(siteID: laval, isEnabled: true, minDownMbps: 150, minUpMbps: 50, armedAt: at("2026-11-01 08:00"),
                                lastRun: at("2026-11-05 07:00"), lastStatus: .ok(downMbps: 480.5, upMbps: nil)))
        try file.save(saved)
        try expectEqual(file.load(), saved, "relu à l'identique")
        try Data("pas du JSON".utf8).write(to: file.url)
        try expectEqual(file.load(), SpeedScheduleBook(), "illisible : vide")

        // Les anciens tests (sans site) se relisent toujours.
        let old = #"{"id":"7C1A1C49-3C14-4F0B-8F3B-3D1F7B0B5E01","date":"2026-11-01T12:00:00Z","kind":"internet","origin":"manuel","server":"Cloudflare","interfaceName":"en0","interfaceKind":"Wi-Fi","downMbps":500,"streams":4}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SpeedTestRecord.self, from: Data(old.utf8))
        try expect(record.siteID == nil && !record.isPlanned, "ancien test relu sans site")
    }
}
