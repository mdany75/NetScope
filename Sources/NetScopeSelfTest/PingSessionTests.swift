import Foundation
import NetScopeCore

// Note 78 (0.26.0) : ping continu — tableau compact au-delà de 9 cibles, seuil par cible, session
// enregistrée et rouverte, notification d'une cible qui tombe ou revient, journal horaire et
// rapport « pour le fournisseur Internet ». Données fixes, aucun réseau.

func registerPingSessionTests(_ suite: TestSuite) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    // 2027-01-15 00:00 à Toronto.
    let midnight = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 0))!
    let at = { (seconds: Double) in midnight.addingTimeInterval(seconds) }

    suite.add("Ping : disposition automatique (tableau compact au-delà de 9 cibles)") {
        try expect(!PingLayoutChoice.automatic.usesTable(targetCount: 9), "9 cibles : cartes")
        try expect(PingLayoutChoice.automatic.usesTable(targetCount: 10), "10 cibles : tableau")
        try expect(PingLayoutChoice.table.usesTable(targetCount: 1), "tableau imposé")
        try expect(!PingLayoutChoice.cards.usesTable(targetCount: 40), "cartes imposées")
        try expectEqual(PingThreshold.label(20), "20\u{00A0}ms", "libellé du seuil")
        try expectEqual(PingThreshold.label(2.5), "2,5\u{00A0}ms", "seuil décimal")
        try expectEqual(PingThreshold.clamped(0), 1, "seuil minimal")
        try expectEqual(PingThreshold.clamped(99_999), 5_000, "seuil maximal")
        try expect(PingThreshold.clamped(.nan) == nil, "seuil illisible")
    }

    suite.add("Ping : session enregistrée puis rouverte (cibles et réglages)") {
        let file = PingSessionFile(savedAt: at(0), interval: 0.5, payloadSize: 1472, soundOnLoss: false, notifyChanges: true,
                                   layout: .table, targets: [
                                       .init(input: "10.182.122.1", name: "FortiGate-60F", role: "Passerelle", thresholdMs: 15),
                                       .init(input: "8.8.8.8", thresholdMs: 40, isPaused: true),
                                   ])
        let back = try PingSessionFile.decode(try file.encoded())
        try expectEqual(back, file, "aller-retour fidèle")
        try expectEqual(back.summary, "2 cibles · \(PingFormat.duration(0.5)) · 1472 octets", "résumé")
        try expect(back.targets[1].isPaused, "pause gardée")
    }

    suite.add("Ping : session relue avec tolérance (valeurs hors bornes, doublons, cible illisible)") {
        let json = #"""
        {"version":1,"interval":4,"payloadSize":900,"layout":"inconnue",
         "targets":[{"input":" 10.0.0.1 ","thresholdMs":-4},{"input":"10.0.0.1"},{"name":"sans adresse"},{"input":""},
                    {"input":"routeur.local","name":"Routeur\nprincipal","thresholdMs":80}]}
        """#
        let file = try PingSessionFile.decode(Data(json.utf8))
        try expectEqual(file.interval, 5, "intervalle ramené au plus proche proposé")
        try expectEqual(file.payloadSize, 56, "taille ramenée à 56 octets")
        try expectEqual(file.layout, .automatic, "disposition inconnue : automatique")
        try expectEqual(file.targets.map(\.input), ["10.0.0.1", "routeur.local"], "doublon, vide et illisible retirés")
        try expectEqual(file.targets[0].thresholdMs, 1, "seuil négatif ramené")
        try expectEqual(file.targets[1].name, "Routeur principal", "nom sur une ligne")
        try expect(file.notifyChanges && file.soundOnLoss, "clés absentes : valeurs par défaut")

        try expectThrows(PingSessionError.unreadable, "pas du JSON") { _ = try PingSessionFile.decode(Data("pas du json".utf8)) }
        try expectThrows(PingSessionError.newerVersion(9), "version future") {
            _ = try PingSessionFile.decode(Data(#"{"version":9,"targets":[]}"#.utf8))
        }
        let many = PingSessionFile(targets: (1...80).map { .init(input: "10.0.1.\($0)") })
        try expectEqual(many.targets.count, PingSessionFile.maxTargets, "session plafonnée")
    }

    suite.add("Ping : notification quand une cible tombe ou revient") {
        let down = PingEvent(date: at(10), level: .coupure, subject: "8.8.8.8", message: "délai dépassé (3 paquets perdus)")
        let event = try required78(PingNotification.event(for: down, name: "Google DNS", address: "8.8.8.8"), "coupure")
        try expectEqual(event.kind, .pingTargetDown, "type : hors ligne")
        try expectEqual(event.severity, .critical, "critique")
        try expectEqual(event.title, "Google DNS (8.8.8.8) ne répond plus", "titre")
        try expectEqual(event.link, .screen("ping"), "ouvre le ping continu")
        let up = PingEvent(date: at(20), level: .retabli, subject: "8.8.8.8", message: "retour en ligne après 10 s (10 paquets perdus)")
        let back = try required78(PingNotification.event(for: up, name: "8.8.8.8", address: "8.8.8.8"), "retour")
        try expectEqual(back.kind, .pingTargetUp, "type : rétablie")
        try expectEqual(back.title, "8.8.8.8 répond de nouveau", "sans nom : l'adresse seule")
        try expect(PingNotification.event(for: PingEvent(level: .alerte, subject: "x", message: "1 paquet perdu"), name: "x", address: "x") == nil,
                   "perte isolée : pas de notification")
    }

    suite.add("Ping : journal horaire (perte, latence, gigue, lenteur)") {
        var log = PingLongLog()
        // 00 h : 10, 20, perdu, 30 ; seuil 25 → une réponse lente.
        let values: [Double?] = [10, 20, nil, 30]
        for (index, value) in values.enumerated() {
            log.record(PingSample(sequence: index + 1, date: at(Double(index) * 60), rttMs: value), thresholdMs: 25, calendar: calendar)
        }
        // 01 h : 40.
        log.record(PingSample(sequence: 5, date: at(3600 + 5), rttMs: 40), thresholdMs: 25, calendar: calendar)
        try expectEqual(log.buckets.count, 2, "deux heures")
        let first = log.buckets[0]
        try expectEqual(first.hourStart, midnight, "heure ronde")
        try expectEqual(first.sent, 4, "envoyés")
        try expectEqual(first.received, 3, "reçus")
        try expectEqual(first.lossPercent, 25, "25 % de perte")
        try expectEqual(first.average, 20, "moyenne")
        try expectEqual(first.slow, 1, "une réponse au-dessus de 25 ms")
        try expectEqual(first.jitter, 10, "gigue : (10 + 10) / 2")
        try expectEqual(log.buckets[1].jitter, 10, "la gigue continue d'une heure à l'autre (30 → 40)")
        // Mesure en retard pour 00 h : elle retrouve son heure.
        log.record(PingSample(sequence: 6, date: at(1800), rttMs: 12), thresholdMs: 25, calendar: calendar)
        try expectEqual(log.buckets[0].sent, 5, "mesure tardive rangée dans son heure")
        try expect(log.outages.isEmpty, "une perte isolée n'est pas une panne")
    }

    suite.add("Ping : pannes du journal (3 pertes de suite, fin à la première réponse)") {
        var log = PingLongLog()
        var sequence = 0
        func add(_ second: Double, _ value: Double?) {
            sequence += 1
            log.record(PingSample(sequence: sequence, date: at(second), rttMs: value), thresholdMs: 50, calendar: calendar)
        }
        add(0, 5); add(1, nil); add(2, nil)
        try expect(log.outages.isEmpty, "2 pertes : pas encore une panne")
        add(3, nil)
        try expectEqual(log.outages.count, 1, "3e perte : panne ouverte")
        try expectEqual(log.outages[0].start, at(1), "début au premier paquet perdu")
        try expect(log.outages[0].end == nil, "panne en cours")
        add(4, nil); add(5, nil)
        try expectEqual(log.outages[0].lostPackets, 5, "pertes comptées")
        add(6, 7)
        try expectEqual(log.outages[0].end, at(6), "fin à la première réponse")
        try expectEqual(log.outages[0].duration(until: at(100)), 5, "durée 5 s")
        add(7, nil); add(8, 6)
        try expectEqual(log.outages.count, 1, "perte isolée ensuite : rien de plus")
        log.reset()
        try expect(log.isEmpty && log.outages.isEmpty, "réinitialisé")
    }

    suite.add("Ping : rapport pour le fournisseur Internet (résumé, constats, pages)") {
        var bad = PingLongLog()
        var good = PingLongLog()
        var sequence = 0
        // 3 heures, une mesure par 10 s ; la 2e heure perd 1 paquet sur 10 et la latence triple.
        for second in stride(from: 0.0, to: 3 * 3600, by: 10) {
            sequence += 1
            let hour = Int(second / 3600)
            let lost = hour == 1 && sequence % 10 == 0
            bad.record(PingSample(sequence: sequence, date: at(second), rttMs: lost ? nil : (hour == 1 ? 60 : 20)),
                       thresholdMs: 40, calendar: calendar)
            good.record(PingSample(sequence: sequence, date: at(second), rttMs: 2), thresholdMs: 15, calendar: calendar)
        }
        // Panne de 60 s à 02:30.
        for offset in stride(from: 0.0, to: 60, by: 10) {
            sequence += 1
            bad.record(PingSample(sequence: sequence, date: at(9000 + offset + 1), rttMs: nil), thresholdMs: 40, calendar: calendar)
        }
        sequence += 1
        bad.record(PingSample(sequence: sequence, date: at(9061), rttMs: 21), thresholdMs: 40, calendar: calendar)

        let report = PingISPReport.make([
            .init(name: "Google DNS", address: "8.8.8.8", role: "Internet", thresholdMs: 40, log: bad),
            .init(name: "FortiGate-60F", address: "10.182.122.1", role: "Passerelle", thresholdMs: 15, log: good),
            .init(name: "Vide", address: "10.0.0.9", role: "", thresholdMs: 20, log: PingLongLog()),
        ], generatedAt: at(3 * 3600), calendar: calendar)
        try expectEqual(report.targets.count, 2, "cible sans mesure écartée")
        try expectEqual(report.periodStart, midnight, "période depuis la première heure")
        let internet = report.targets[0]
        try expectEqual(internet.hours.count, 3, "trois heures")
        try expectEqual(internet.outages.count, 1, "une panne")
        try expectEqual(internet.downtime, 60, "60 s de panne")
        try expect(internet.availability < 100 && internet.availability > 99, "disponibilité entre 99 et 100 %")
        try expect(internet.hours[1].lossPercent >= 9, "2e heure : ~10 % de perte")
        try expect(internet.findings.contains { $0.hasPrefix("1 panne") }, "constat : la panne")
        try expect(internet.findings.contains { $0.contains("Heure la plus touchée") && $0.contains("2027-01-15 1\u{00A0}h") },
                   "constat : l'heure la plus touchée")
        try expect(internet.findings.contains { $0.contains("au-dessus du seuil de 40\u{00A0}ms") }, "constat : réponses lentes")
        let gateway = report.targets[1]
        try expectEqual(gateway.findings, ["Aucune anomalie\u{00A0}: perte et latence normales sur la période."], "passerelle propre")
        try expectEqual(gateway.availability, 100, "disponibilité 100 %")

        try expectEqual(report.pages(), [.summary(targets: 0..<2), .hours(target: 0, rows: 0..<3), .hours(target: 1, rows: 0..<3)],
                        "une page de résumé, puis le détail de chaque cible")
        try expectEqual(report.pages(targetsPerSummary: 1, rowsPerPage: 2).count, 2 + 2 + 2, "découpage plus fin")
        let text = report.text(calendar: calendar)
        try expect(text.contains("Panne\u{00A0}: 2027-01-15 02:30:01 → 2027-01-15 02:31:01"), "panne datée dans le texte")
        try expectEqual(PingISPReport.make([], generatedAt: at(0)).pages(), [.summary(targets: 0..<0)], "rapport vide : une page")
    }
}
