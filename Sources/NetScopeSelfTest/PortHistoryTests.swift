import Foundation
import NetScopeCore

// Note 74 : historique du trafic des ports (débits, compteurs 32 bits qui bouclent, remises à zéro,
// regroupement, purge, fichier ancien) et note 78 : erreurs jugées par heure dans l'analyse
// complète. Compteurs et fichiers fixes : aucun trafic réseau.

func registerPortHistoryTests(_ suite: TestSuite) {
    let t0 = Date(timeIntervalSince1970: 1_780_000_200)   // aligné sur 5 min
    func reading(_ index: Int = 1, _ inOctets: UInt64, _ outOctets: UInt64, width: CounterWidth = .bits64,
                 errors: UInt64? = 0, speed: UInt64? = 1000, up: Bool = true) -> PortCounterReading {
        PortCounterReading(ifIndex: index, name: "Gi1/0/\(index)", alias: "Prise \(index)", speedMbps: speed, isUp: up,
                           inOctets: inOctets, outOctets: outOctets, width: width, inErrors: errors)
    }

    suite.add("Historique des ports : débit calculé entre deux relevés") {
        var history = PortTrafficHistory()
        try expectEqual(history.record(host: "10.0.0.2", name: "SW", at: t0, readings: [reading(1, 1_000, 2_000)]), 0, "premier relevé : la base")
        // 750 000 000 octets en 60 s = 100 Mb/s ; 75 000 000 = 10 Mb/s.
        try expectEqual(history.record(host: "10.0.0.2", name: "SW", at: t0 + 60, readings: [reading(1, 750_001_000, 75_002_000, errors: 4)]), 1, "un segment")
        let series = try unwrap(history.series("10.0.0.2", ifIndex: 1), "port suivi")
        try expectEqual(series.points.count, 1, "un point")
        try expectNear(series.points[0].inAverage, 100_000_000, "100 Mb/s en entrée")
        try expectNear(series.points[0].outAverage, 10_000_000, "10 Mb/s en sortie")
        try expectEqual(series.points[0].errors, 4, "nouvelles erreurs")
        let stats = series.stats(.hour, now: t0 + 60)
        try expectNear(stats.inAveragePercent ?? -1, 10, "10 % du lien de 1 Gb/s")
        try expectNear(stats.errorsPerHour ?? -1, 240, "4 erreurs en une minute = 240/h")
        // Relevé trop rapproché (panneau ouvert et relevé du switch presque en même temps) : ignoré.
        try expectEqual(history.record(host: "10.0.0.2", name: "SW", at: t0 + 65, readings: [reading(1, 800_000_000, 80_000_000)]), 0, "moins de 15 s")
        try expectEqual(history.series("10.0.0.2", ifIndex: 1)?.baseline?.at, t0 + 60, "la base reste l’ancienne")
    }

    suite.add("Historique des ports : compteur 32 bits qui boucle, remise à zéro, trou") {
        var history = PortTrafficHistory()
        // ifInOctets 32 bits d'un port 100 Mb/s : 4 294 960 000 puis 2 500 000 en 30 s.
        history.record(host: "sw", name: "", at: t0, readings: [reading(1, 4_294_960_000, 100, width: .bits32, speed: 100)])
        history.record(host: "sw", name: "", at: t0 + 30, readings: [reading(1, 2_500_000, 200, width: .bits32, speed: 100)])
        let wrapped = try unwrap(history.series("sw", ifIndex: 1)?.points.first, "point après le tour")
        try expectNear(wrapped.inBytes, 2_507_296, "4 294 967 295 − 4 294 960 000 + 2 500 000 + 1 octets")
        // Remise à zéro d'un compteur 64 bits (switch redémarré) : pas de point, la base repart.
        history.record(host: "sw", name: "", at: t0, readings: [reading(2, 9_000_000_000, 9_000_000_000)])
        history.record(host: "sw", name: "", at: t0 + 60, readings: [reading(2, 1_000, 2_000, errors: 0)])
        try expectEqual(history.series("sw", ifIndex: 2)?.points.count, 0, "compteur qui recule : aucun point")
        history.record(host: "sw", name: "", at: t0 + 120, readings: [reading(2, 7_501_000, 2_000)])
        try expectNear(history.series("sw", ifIndex: 2)?.points.first?.inAverage ?? -1, 1_000_000, "1 Mb/s depuis la remise à zéro")
        // Débit impossible (plus que le lien) : écarté.
        history.record(host: "sw", name: "", at: t0, readings: [reading(3, 0, 0, speed: 100)])
        history.record(host: "sw", name: "", at: t0 + 60, readings: [reading(3, 7_500_000_000, 0, speed: 100)])
        try expectEqual(history.series("sw", ifIndex: 3)?.points.count, 0, "1 Gb/s sur un lien de 100 Mb/s")
        // Plus d'une heure sans relevé : un trou, pas une moyenne étalée.
        history.record(host: "sw", name: "", at: t0, readings: [reading(4, 0, 0)])
        history.record(host: "sw", name: "", at: t0 + 7200, readings: [reading(4, 1_000_000, 0)])
        try expectEqual(history.series("sw", ifIndex: 4)?.points.count, 0, "deux heures d’écart")
        // Port inactif : base mise à jour, aucun point.
        history.record(host: "sw", name: "", at: t0, readings: [reading(5, 0, 0)])
        history.record(host: "sw", name: "", at: t0 + 60, readings: [reading(5, 10, 10, up: false)])
        try expectEqual(history.series("sw", ifIndex: 5)?.points.count, 0, "port inactif")
        try expectEqual(history.series("sw", ifIndex: 5)?.baseline?.at, t0 + 60, "base à jour")
        // Compteur d'erreurs remis à zéro : aucune « nouvelle erreur » négative ou absurde.
        history.record(host: "sw", name: "", at: t0, readings: [reading(6, 0, 0, errors: 5_000)])
        history.record(host: "sw", name: "", at: t0 + 60, readings: [reading(6, 1_000, 1_000, errors: 3)])
        try expectEqual(history.series("sw", ifIndex: 6)?.points.first?.errors, 0, "compteur d’erreurs remis à zéro")
    }

    suite.add("Historique des ports : relevés rapprochés regroupés à la minute") {
        var history = PortTrafficHistory()
        for k in 0...6 {   // toutes les 20 s pendant 2 minutes
            history.record(host: "sw", name: "", at: t0 + Double(k * 20), readings: [reading(1, UInt64(k) * 2_500_000, 0)])
        }
        let points = try unwrap(history.series("sw", ifIndex: 1)?.points, "points")
        try expectEqual(points.count, 2, "deux points d’une minute")
        try expectNear(points[0].covered, 60, "première minute")
        try expectNear(points[0].inAverage, 1_000_000, "1 Mb/s")
        try expectNear(points[0].inPeak, 1_000_000, "pointe")
    }

    suite.add("Historique des ports : regroupement à 5 min et à l’heure, purge après 90 jours") {
        let now = t0
        var points: [PortTrafficPoint] = []
        // 100 jours de points d'une minute… trop pour un test : trois paquets à des âges différents.
        func minutes(from start: Date, count: Int, mbps: Double, errors: UInt64 = 0) {
            for k in 0..<count {
                let a = start.addingTimeInterval(Double(k) * 60)
                points.append(PortTrafficPoint(start: a, end: a + 60, inBytes: mbps * 1e6 / 8 * 60, outBytes: 0, errors: errors))
            }
        }
        minutes(from: now - 100 * 86_400, count: 30, mbps: 5)          // trop vieux : oublié
        minutes(from: Date(timeIntervalSince1970: floor((now - 10 * 86_400).timeIntervalSince1970 / 3600) * 3600),
                count: 120, mbps: 10, errors: 1)                       // 2 h pile il y a 10 jours : à l'heure
        minutes(from: now - 2 * 86_400, count: 30, mbps: 20)           // 30 min il y a 2 jours : à 5 min
        minutes(from: now - 3600, count: 30, mbps: 40)                 // récent : tel quel
        var history = PortTrafficHistory(switches: ["sw": PortSwitchHistory(host: "sw", name: "SW", ports: [
            1: PortTrafficSeries(ifIndex: 1, name: "Gi1/0/1", speedMbps: 1000, points: points)])])
        let before = points.filter { $0.end > now - 90 * 86_400 }.reduce(0) { $0 + $1.inBytes }
        history.compact(now: now)
        let after = try unwrap(history.series("sw", ifIndex: 1)?.points, "points gardés")
        try expectEqual(after.count, 2 + 6 + 30, "2 heures + 6 tranches de 5 min + 30 minutes récentes")
        try expectNear(after.reduce(0) { $0 + $1.inBytes }, before, "octets conservés par le regroupement")
        try expectEqual(after[0].errors, 60, "erreurs additionnées dans l’heure")
        try expectNear(after[0].inAverage, 10_000_000, "débit moyen de l’heure")
        try expect(after.allSatisfy { $0.start > now - 90 * 86_400 }, "plus rien de 100 jours")
        // Deuxième passage : rien ne bouge (les tranches déjà faites ne se regroupent pas davantage).
        history.compact(now: now)
        try expectEqual(history.series("sw", ifIndex: 1)?.points.count, after.count, "stable")
        // Un port sans aucun point récent ni base est oublié, puis le switch vide.
        var stale = PortTrafficHistory(switches: ["vieux": PortSwitchHistory(host: "vieux", name: "", ports: [
            1: PortTrafficSeries(ifIndex: 1, name: "1", points: [PortTrafficPoint(start: now - 95 * 86_400, end: now - 95 * 86_400 + 60, inBytes: 1, outBytes: 1)])])])
        stale.compact(now: now)
        try expect(stale.switches.isEmpty, "switch oublié après 90 jours sans mesure")
    }

    suite.add("Historique des ports : courbe, débits moyen et max, pourcentage du lien") {
        // 2 h de points de 5 min : 100 Mb/s la première heure, rien entre 60 et 80 min, puis 300 Mb/s.
        var points: [PortTrafficPoint] = []
        for k in 0..<24 where !(12..<16).contains(k) {
            let a = t0 + Double(k * 300)
            let mbps: Double = k < 12 ? 100 : 300
            points.append(PortTrafficPoint(start: a, end: a + 300, inBytes: mbps * 1e6 / 8 * 300, outBytes: 1e6 / 8 * 300,
                                           inPeak: mbps * 1.5e6, errors: k == 20 ? 30 : 0))
        }
        let series = PortTrafficSeries(ifIndex: 1, name: "Gi1/0/1", speedMbps: 1000, points: points)
        let now = t0 + 7200
        let day = series.stats(.day, now: now)
        try expectNear(day.covered, 20 * 300, "100 min mesurées")
        try expectNear(day.inAverage, (12 * 100 + 8 * 300) * 1e6 / 20, "moyenne pondérée par la durée")
        try expectNear(day.inPeak, 450_000_000, "débit max mesuré")
        try expectNear(day.inPeakPercent ?? -1, 45, "45 % du lien au plus fort")
        try expectNear(day.errorsPerHour ?? -1, 18, "30 erreurs en 100 min")
        let hour = series.stats(.hour, now: now)
        try expectNear(hour.covered, 2400, "dernière heure : 40 min mesurées")
        try expectNear(hour.inAverage, 300_000_000, "300 Mb/s")
        let curve = series.curve(.hour, now: now)
        try expectEqual(curve.inValues.count, 60, "60 colonnes d’une minute")
        try expect(curve.inValues[5] == nil, "trou entre 60 et 80 min")
        try expectNear(curve.inValues[59] ?? -1, 300_000_000, "dernière minute")
        let dayCurve = series.curve(.day, now: now)
        try expectEqual(dayCurve.inValues.count, 144, "144 colonnes de 10 min")
        try expectEqual(dayCurve.inValues.compactMap { $0 }.count, 10, "10 colonnes mesurées sur 12")
    }

    suite.add("Historique des ports : ports les plus chargés et erreurs par heure") {
        func series(_ index: Int, speed: UInt64, mbps: Double, errors: UInt64) -> PortTrafficSeries {
            let points = (0..<12).map { k -> PortTrafficPoint in
                let a = t0 + Double(k * 300)
                return PortTrafficPoint(start: a, end: a + 300, inBytes: mbps * 1e6 / 8 * 300, outBytes: 0, errors: k == 0 ? errors : 0)
            }
            return PortTrafficSeries(ifIndex: index, name: "p\(index)", speedMbps: speed, points: points)
        }
        let history = PortSwitchHistory(host: "sw", name: "SW", ports: [
            1: series(1, speed: 1000, mbps: 400, errors: 0),   // 40 %
            2: series(2, speed: 100, mbps: 80, errors: 300),   // 80 %, 300 erreurs/h
            3: series(3, speed: 10_000, mbps: 900, errors: 2), // 9 %
        ])
        let now = t0 + 3600
        let top = PortHistoryRanking.busiest(PortHistoryRanking.summaries(history, range: .day, now: now))
        try expectEqual(top.map(\.ifIndex), [2, 1, 3], "classés par % du lien")
        try expectEqual(PortHistoryRanking.busiest(top, limit: 1).map(\.ifIndex), [2], "limite")
        let rates = PortHistoryRanking.errorRates(history, now: now)
        try expectNear(rates[2]?.perHour ?? -1, 300, "300 erreurs en une heure")
        try expectEqual(rates[2]?.level, 2, "alerte")
        try expectEqual(rates[3]?.level, 0, "2 erreurs/h : rien")
        try expectEqual(PortErrorRate.label(0.4), "0,4/h", "libellé décimal")
        try expectEqual(PortErrorRate.label(37.2), "37/h", "libellé entier")
        try expect(PortHistoryRanking.errorRates(history, now: t0 + 600).isEmpty, "moins de 15 min mesurées : pas de jugement")
    }

    suite.add("Historique des ports : fichier relu, fichier ancien, version future") {
        var history = PortTrafficHistory()
        history.record(host: "10.0.0.2", name: "SW-CORE", at: t0, readings: [reading(1, 0, 0), reading(2, 0, 0)])
        history.record(host: "10.0.0.2", name: "SW-CORE", at: t0 + 300, readings: [reading(1, 3_750_000_000, 37_500_000, errors: 7), reading(2, 123_400, 0)])
        let data = try unwrap(PortHistoryFile.encode(history, savedAt: t0 + 300), "encodage")
        let read = try unwrap(PortHistoryFile.decode(data, now: t0 + 300), "relecture")
        let point = try unwrap(read.series("10.0.0.2", ifIndex: 1)?.points.first, "point relu")
        try expectNear(point.inAverage, 100_000_000, "100 Mb/s relus")
        try expectNear(point.outAverage, 1_000_000, "1 Mb/s relu")
        try expectEqual(point.errors, 7, "erreurs relues")
        try expectEqual(point.start, t0, "début relu")
        try expectEqual(read.history("10.0.0.2")?.name, "SW-CORE", "nom du switch")
        try expectEqual(read.series("10.0.0.2", ifIndex: 1)?.baseline?.inOctets, 3_750_000_000, "base relue : le relevé suivant continue")
        try expect((read.series("10.0.0.2", ifIndex: 2)?.points.first?.inAverage ?? -1) > 0, "faible trafic (3,3 kb/s) gardé au dixième de kb/s")

        // Fichier écrit par une version précédente, il y a longtemps : champs facultatifs absents,
        // points à 5 valeurs, un point de 100 jours (oublié) et 12 points de 5 min il y a 10 jours
        // (regroupés à l'heure).
        let old = Date(timeIntervalSince1970: floor((t0 - 10 * 86_400).timeIntervalSince1970 / 3600) * 3600)
        let rows = (0..<12).map { k in k == 0 ? "[\(Int(old.timeIntervalSince1970)),300,300,8000,800]" : "[0,300,300,8000,800]" }
        let json = """
        {"version":1,"savedAt":\(Int((t0 - 9 * 86_400).timeIntervalSince1970)),"switches":[
          {"host":"10.0.0.9","name":"SW-ANCIEN","ports":[
            {"index":3,"name":"1/3","points":[[\(Int((t0 - 100 * 86_400).timeIntervalSince1970)),300,300,5000,5000]]},
            {"index":4,"name":"1/4","speed":1000,"points":[\(rows.joined(separator: ","))]}
          ]}
        ]}
        """
        let legacy = try unwrap(PortHistoryFile.decode(Data(json.utf8), now: t0), "fichier ancien relu")
        try expect(legacy.series("10.0.0.9", ifIndex: 3) == nil, "port de 100 jours oublié")
        let hourly = try unwrap(legacy.series("10.0.0.9", ifIndex: 4)?.points, "port gardé")
        try expectEqual(hourly.count, 1, "une heure (12 × 5 min regroupés)")
        try expectNear(hourly[0].inAverage, 8_000_000, "8 Mb/s en moyenne")
        try expectNear(hourly[0].covered, 3600, "une heure mesurée")
        try expect(PortHistoryFile.decode(Data(#"{"version":2,"savedAt":0,"switches":[]}"#.utf8)) == nil, "version future ignorée")
        try expect(PortHistoryFile.decode(Data("pas du JSON".utf8)) == nil, "fichier illisible")

        // Écriture et lecture sur le disque (dossier temporaire), fichier illisible mis de côté.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-ports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = SiteFiles(base: folder)
        let url = PortHistoryFile.url(in: files, siteKey: "site-a")
        try PortHistoryFile.save(history, to: url, now: t0 + 300)
        guard case .loaded(let loaded) = PortHistoryFile.load(from: url, now: t0 + 300) else {
            throw TestFailure(message: "fichier relu du disque", file: #fileID, line: #line)
        }
        try expectEqual(loaded.pointCount, history.pointCount, "mêmes points")
        try Data("{".utf8).write(to: url)
        guard case .unreadable = PortHistoryFile.load(from: url) else {
            throw TestFailure(message: "fichier abîmé reconnu", file: #fileID, line: #line)
        }
        try expect(PortHistoryFile.setAside(url, now: t0) != nil && !FileManager.default.fileExists(atPath: url.path), "mis de côté")
    }

    suite.add("Analyse complète : erreurs de port jugées par heure, plus le total depuis le démarrage") {
        var iface = SNMPInterface(index: 7, name: "1/7", operStatus: .up, speedMbps: 1000, inErrors: 48_211)
        var quiet = SNMPInterface(index: 8, name: "1/8", operStatus: .up, speedMbps: 1000, inErrors: 0)
        quiet.alias = "Bureau"
        iface.alias = "Salle"
        let snapshot = SNMPSwitchSnapshot(host: IPv4Address("10.182.122.3")!, system: SNMPSystemInfo(name: "SW-ETG2-01", descr: ""),
                                          interfaces: [iface, quiet])
        // Vieux total, aucune nouvelle erreur : rien.
        let none = NetworkAnalysis.portIssues([snapshot], site: "Siège", errorRates: ["10.182.122.3": [7: PortErrorRate(errors: 0, seconds: 86_400)]])
        try expect(none.isEmpty, "48 211 erreurs depuis le démarrage mais aucune nouvelle : pas signalé")
        try expect(NetworkAnalysis.portIssues([snapshot], site: "Siège", errorRates: [:]).isEmpty, "sans mesure dans le temps : pas signalé")
        let rising = NetworkAnalysis.portIssues([snapshot], site: "Siège",
                                                errorRates: ["10.182.122.3": [7: PortErrorRate(errors: 600, seconds: 7200)]],
                                                loads: ["10.182.122.3": [8: 91]])
        try expectEqual(rising.count, 2, "erreurs et saturation")
        let result = NetworkAnalysis.analyze(NetworkAnalysisInput(ports: rising, unknownDevices: [], now: t0))
        let errorFinding = try unwrap(result.findings.first { $0.title.hasPrefix("Port SW-ETG2-01 · 1/7 en erreur") }, "port en erreur")
        try expectEqual(errorFinding.severity, .warning, "300 erreurs/h : alerte")
        try expect(errorFinding.explanation.contains("600 nouvelles erreurs") && errorFinding.explanation.contains("2\u{00A0}h"),
                   "explication par heure : \(errorFinding.explanation)")
        try expect(result.findings.contains { $0.title.hasPrefix("Port SW-ETG2-01 · 1/8 saturé") }, "port saturé sur la dernière heure")
    }
}

private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — absent", file: file, line: line) }
    return value
}

private func expectNear(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.001,
                        file: String = #fileID, line: Int = #line) throws {
    let margin = max(abs(expected) * tolerance, 0.01)
    guard abs(actual - expected) <= margin else {
        throw TestFailure(message: "\(message) — obtenu : \(actual), attendu : \(expected)", file: file, line: line)
    }
}
