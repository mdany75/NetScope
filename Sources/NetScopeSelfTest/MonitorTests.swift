import Foundation
import NetScopeCore

// Tests du module Monitor (Surveillance) : machine d'états sur des séries fixes, historique,
// journal, analyses pures des réponses et encodage du modèle. Aucun accès réseau.

private let monCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    return calendar
}()

/// Mardi 3 novembre 2026 à l'heure donnée (heure de Montréal).
private func monDate(day: Int = 3, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    monCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
}

/// Applique une série de résultats ; renvoie le suivi final et tous les événements.
private func run(_ probe: MonProbe, _ series: [(MonResult, Bool)], from start: MonTracker = MonTracker())
    -> (tracker: MonTracker, events: [MonEvent], states: [MonState]) {
    var tracker = start
    var events: [MonEvent] = []
    var states: [MonState] = []
    for (result, dependencyDown) in series {
        let step = MonStateMachine.evaluate(probe: probe, tracker: tracker, result: result,
                                            dependencyDown: dependencyDown, calendar: monCalendar)
        tracker = step.tracker
        events += step.events
        states.append(tracker.state)
    }
    return (tracker, events, states)
}

func registerMonitorTests(_ suite: TestSuite) {
    let ping = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21",
                        thresholds: MonThresholds(latencyMs: 50, lossPercent: 5, failures: 3))

    suite.add("Surveillance : N échecs consécutifs avant la panne, une seule alerte") {
        let t = monDate(14)
        let ok = MonResult.success(t, latency: 2, loss: 0)
        let ko = MonResult.failure(t)
        let outcome = run(ping, [(ok, false), (ko, false), (ko, false), (ok, false), (ko, false), (ko, false), (ko, false), (ko, false)])
        try expectEqual(outcome.states, [.ok, .ok, .ok, .ok, .ok, .ok, .down, .down], "états")
        try expectEqual(outcome.events.map(\.kind), [.down], "une seule alerte de panne")
        try expect(outcome.events[0].message.contains("3 tentatives"), "message : \(outcome.events[0].message)")
        try expectEqual(outcome.tracker.consecutiveFailures, 4, "compteur")
        try expectEqual(outcome.tracker.alerted, .down, "panne signalée")
    }

    suite.add("Surveillance : retour à la normale après une panne") {
        let t = monDate(14)
        let ko = MonResult.failure(t)
        let ok = MonResult.success(t, latency: 1.1, loss: 0, value: "1,1 ms")
        let outcome = run(ping, [(ko, false), (ko, false), (ko, false), (ok, false), (ok, false)])
        try expectEqual(outcome.states, [.pending, .pending, .down, .ok, .ok], "états")
        try expectEqual(outcome.events.map(\.kind), [.down, .recovered], "panne puis retour")
        try expectEqual(outcome.tracker.alerted, nil, "plus d'alerte ouverte")
        try expectEqual(outcome.tracker.consecutiveFailures, 0, "compteur remis à zéro")
    }

    suite.add("Surveillance : seuils de latence et de perte") {
        let t = monDate(10)
        let slow = MonResult.success(t, latency: 63, loss: 0)
        let lossy = MonResult.success(t, latency: 2, loss: 33.3)
        let fine = MonResult.success(t, latency: 50, loss: 5) // égal au seuil : pas d'alerte
        let outcome = run(ping, [(fine, false), (slow, false), (lossy, false), (fine, false)])
        try expectEqual(outcome.states, [.ok, .warning, .warning, .ok], "états")
        try expectEqual(outcome.events.map(\.kind), [.warning, .recovered], "une alerte, un retour")
        try expect(outcome.events[0].message.contains("Latence 63\u{00A0}ms > 50\u{00A0}ms"), "message : \(outcome.events[0].message)")
        let warnings = MonStateMachine.warnings(probe: ping, result: lossy)
        try expectEqual(warnings.count, 1, "perte seule")
        try expect(warnings[0].hasPrefix("Perte 33,3\u{00A0}%"), "perte : \(warnings[0])")
    }

    suite.add("Surveillance : panne puis réponse lente (retour puis avertissement)") {
        let t = monDate(10)
        let ko = MonResult.failure(t)
        let slow = MonResult.success(t, latency: 80, loss: 0)
        let outcome = run(ping, [(ko, false), (ko, false), (ko, false), (slow, false)])
        try expectEqual(outcome.states.last, .warning, "en alerte")
        try expectEqual(outcome.events.map(\.kind), [.down, .recovered, .warning], "événements")
    }

    suite.add("Surveillance : dépendance en panne → échecs ignorés") {
        let t = monDate(14)
        let ko = MonResult.failure(t)
        let ok = MonResult.success(t, latency: 2, loss: 0)
        let outcome = run(ping, [(ko, true), (ko, true), (ko, true), (ko, true), (ok, false), (ko, false), (ko, false), (ko, false)])
        try expectEqual(outcome.states, [.ignored, .ignored, .ignored, .ignored, .ok, .ok, .ok, .down], "états")
        try expectEqual(outcome.events.map(\.kind), [.down], "aucune alerte pendant la dépendance")
        // Une réponse pendant que la dépendance est en panne reste une réponse.
        let alive = run(ping, [(ok, true)])
        try expectEqual(alive.states, [.ok], "réponse malgré la dépendance")
    }

    suite.add("Surveillance : plage horaire (alerte différée hors heures ouvrables)") {
        var office = ping
        office.schedule = .businessHours
        // Samedi 7 novembre 2026 : hors plage ; puis lundi 9 à 8 h : dans la plage.
        let saturday = MonResult.failure(monDate(day: 7, 10))
        let monday = MonResult.failure(monDate(day: 9, 8))
        let outcome = run(office, [(saturday, false), (saturday, false), (saturday, false), (saturday, false), (monday, false)])
        try expectEqual(outcome.states, [.pending, .pending, .down, .down, .down], "états")
        try expectEqual(outcome.events.map(\.kind), [.down], "alerte seulement lundi")
        try expect(MonSchedule.isBusinessHours(monDate(day: 3, 7), calendar: monCalendar), "mardi 7 h : ouvrable")
        try expect(!MonSchedule.isBusinessHours(monDate(day: 3, 18), calendar: monCalendar), "mardi 18 h : fermé")
        try expect(!MonSchedule.isBusinessHours(monDate(day: 8, 10), calendar: monCalendar), "dimanche : fermé")
        try expect(MonSchedule.offHours.allowsAlerts(at: monDate(day: 3, 22), calendar: monCalendar), "hors heures : 22 h")
        try expect(!MonSchedule.offHours.allowsAlerts(at: monDate(day: 3, 10), calendar: monCalendar), "hors heures : pas 10 h")
    }

    suite.add("Surveillance : condition du type (avertissement) et seuil d'un échec") {
        var http = MonProbe(name: "Certificat TLS", kind: .http, target: "https://10.182.122.1",
                            thresholds: MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1))
        http.certificateDays = 30
        let now = monDate(13)
        let expiry = monDate(day: 24, 13)
        let result = MonRunner.evaluateHTTP(http, status: 200, durationMs: 184, body: "", certificateExpiry: expiry, now: now)
        try expect(result.reachable, "répond")
        try expectEqual(result.value, "Expire dans 21\u{00A0}j (24 nov. 2026)", "valeur")
        try expect(result.problem?.contains("dans 21\u{00A0}jours") == true, "problème : \(result.problem ?? "-")")
        let outcome = run(http, [(result, false), (.failure(now), false)])
        try expectEqual(outcome.states, [.warning, .down], "un échec suffit")
        try expectEqual(outcome.events.map(\.kind), [.warning, .down], "événements")
    }

    suite.add("Surveillance : analyses HTTP, DNS et SNMP") {
        var http = MonProbe(name: "Imprimante", kind: .http, target: "https://10.182.122.111")
        http.keyword = "Brother"
        let now = monDate(12)
        try expectEqual(MonRunner.evaluateHTTP(http, status: 200, durationMs: 184, body: "<title>Brother DCP</title>",
                                               certificateExpiry: nil, now: now).value, "200 OK · 184\u{00A0}ms", "200 OK")
        let missing = MonRunner.evaluateHTTP(http, status: 200, durationMs: 10, body: "Accueil", certificateExpiry: nil, now: now)
        try expect(!missing.reachable && missing.error?.contains("absent") == true, "mot-clé absent = échec")
        let wrong = MonRunner.evaluateHTTP(http, status: 503, durationMs: 10, body: "Brother", certificateExpiry: nil, now: now)
        try expectEqual(wrong.error, "code 503 au lieu de 200", "mauvais code")

        var dns = MonProbe(name: "Intranet", kind: .dns, target: "intranet.local")
        dns.dnsExpected = "10.10.0.10"
        let good = MonRunner.evaluateDNS(dns, rcode: "NOERROR", addresses: ["10.10.0.10"], durationMs: 4, now: now)
        try expectEqual(good.value, "A 10.10.0.10 · 4,0\u{00A0}ms", "valeur DNS")
        try expect(good.problem == nil, "réponse attendue")
        let moved = MonRunner.evaluateDNS(dns, rcode: "NOERROR", addresses: ["10.10.0.99"], durationMs: 4, now: now)
        try expect(moved.reachable && moved.problem != nil, "réponse inattendue = avertissement")
        let nx = MonRunner.evaluateDNS(dns, rcode: "NXDOMAIN", addresses: [], durationMs: 4, now: now)
        try expect(!nx.reachable, "NXDOMAIN = échec")

        var snmp = MonProbe(name: "SW-CORE-01", kind: .snmp, target: "10.182.122.2")
        snmp.snmpOID = "1.3.6.1.4.1.9.9.13.1.3.1.3.1008"
        snmp.snmpComparison = .greater
        snmp.snmpLimit = 45
        snmp.snmpUnit = "°C"
        let cool = MonRunner.evaluateSNMP(snmp, value: .gauge32(41), now: now)
        try expectEqual(cool.value, "41\u{00A0}°C", "valeur SNMP")
        try expect(cool.problem == nil, "41 °C sous la limite")
        let hot = MonRunner.evaluateSNMP(snmp, value: .integer(46), now: now)
        try expect(hot.problem?.contains("46\u{00A0}°C > 45\u{00A0}°C") == true, "46 °C : \(hot.problem ?? "-")")
        var rssi = snmp
        rssi.snmpComparison = .less
        rssi.snmpLimit = -75
        rssi.snmpUnit = "dBm"
        try expect(MonRunner.evaluateSNMP(rssi, value: .octetString(Array("-78".utf8)), now: now).problem != nil, "RSSI -78 < -75")
        try expectEqual(MonProbe.hostAndPort("10.182.122.1:443")?.port, 443, "hôte:port")
        try expect(MonProbe.hostAndPort("10.182.122.1") == nil, "port manquant")
    }

    suite.add("Surveillance : port de switch et nouveaux appareils (inventaire)") {
        let now = monDate(11)
        func device(_ ip: String, _ mac: String, port: String) -> Device {
            Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), hostname: "WKS346", isOnline: true,
                   switchName: "SW-CORE-01", switchPort: port, firstSeen: now, lastSeen: now)
        }
        let first = MonInventoryChecks.switchPort(mac: "B0:7B:25:44:A1:6C", expected: nil,
                                                  devices: [device("10.182.122.117", "B0:7B:25:44:A1:6C", port: "Gi1/0/22")], now: now)
        try expectEqual(first.learnedLocation, "SW-CORE-01 · Gi1/0/22", "emplacement appris")
        try expectEqual(first.result.value, "SW-CORE-01 Gi1/0/22", "valeur")
        let movedAway = MonInventoryChecks.switchPort(mac: "b0-7b-25-44-a1-6c", expected: "SW-CORE-01 · Gi1/0/22",
                                                      devices: [device("10.182.122.117", "B0:7B:25:44:A1:6C", port: "Gi1/0/24")], now: now)
        try expect(movedAway.result.problem?.contains("Gi1/0/24 au lieu de SW-CORE-01 Gi1/0/22") == true,
                   "changement de port : \(movedAway.result.problem ?? "-")")

        let waiting = MonInventoryChecks.switchPort(mac: "B0:7B:25:44:A1:6C", expected: "SW-CORE-01 · Gi1/0/22", devices: [], now: now)
        try expect(waiting.result.reachable && waiting.result.problem == nil, "inventaire vide : aucune alerte")
        let empty = MonInventoryChecks.newDevices(range: "10.182.122.0/24", known: nil, devices: [], now: now)
        try expect(empty.knownMACs == nil, "pas de base apprise sans scan")
        try expect(waiting.noData && empty.noData, "inventaire vide : rien à évaluer")
        let absent = MonInventoryChecks.switchPort(mac: "B0:7B:25:44:A1:6C", expected: "SW-CORE-01 · Gi1/0/22",
                                                   devices: [device("10.182.122.9", "00:11:22:33:44:99", port: "1")], now: now)
        try expect(absent.noData, "appareil absent du scan : rien à évaluer")

        // Port de switch en alerte, puis inventaire vide (relancement ou scan) : aucun retour à la normale.
        var port = MonProbe(name: "Port de WKS346", kind: .switchPort, target: "B0:7B:25:44:A1:6C")
        port.expectedLocation = "SW-CORE-01 · Gi1/0/22"
        let alerted = MonStateMachine.evaluate(probe: port, tracker: MonTracker(), result: movedAway.result, dependencyDown: false)
        try expectEqual(alerted.tracker.state, .warning, "déplacement : en alerte")
        let after = MonStateMachine.step(probe: port, tracker: alerted.tracker, outcome: waiting, dependencyDown: false)
        try expect(after == nil, "sans donnée : le suivi ne bouge pas, aucun événement « rétablie »")
        let real = MonStateMachine.step(probe: port, tracker: alerted.tracker, outcome: movedAway, dependencyDown: false)
        try expect(real?.events.isEmpty == true, "toujours déplacé : pas de nouvelle alerte")

        // Scan en cours : l'inventaire se vide et se remplit, rien n'est évalué.
        let scanning = MonRunContext(pinger: nil, snmpCommunity: nil,
                                     devices: [device("10.182.122.117", "B0:7B:25:44:A1:6C", port: "Gi1/0/24")],
                                     inventoryReady: false, now: now)
        let during = await MonRunner.run(port, context: scanning)
        try expect(during.noData && during.result.value == "Scan en cours", "scan en cours : rien à évaluer")

        let a = device("10.182.122.10", "00:11:22:33:44:55", port: "1")
        let b = device("10.182.122.133", "D6:4E:81:7A:33:C0", port: "2")
        let outside = device("192.168.50.9", "00:11:22:33:44:66", port: "3")
        let base = MonInventoryChecks.newDevices(range: "10.182.122.0/24", known: nil, devices: [a, outside], now: now)
        try expectEqual(base.knownMACs, ["00:11:22:33:44:55"], "base apprise (plage seulement)")
        try expect(base.result.problem == nil, "pas d'alerte au premier passage")
        let next = MonInventoryChecks.newDevices(range: "10.182.122.0/24", known: base.knownMACs, devices: [a, b, outside], now: now)
        try expect(next.result.problem?.hasPrefix("Nouvel appareil 10.182.122.133") == true, "nouveau : \(next.result.problem ?? "-")")
        try expectEqual(next.knownMACs?.count, 2, "base enrichie")
        try expectEqual(next.result.value, "1 nouveau · 2 en ligne", "valeur")
    }

    suite.add("Surveillance : journal (création, résolution, accusé de réception, CSV)") {
        var probe = ping
        probe.name = "Ping passerelle"
        var journal = MonJournal()
        let t1 = monDate(10, 15, 2)
        let created = journal.record([MonEvent(.warning, "Latence moyenne 63 ms > 50 ms.")], probe: probe, date: t1)
        try expectEqual(created.count, 1, "une alerte")
        try expectEqual(journal.unreadCount, 1, "non lue")
        journal.record([MonEvent(.recovered, "revenu à la normale (1,1 ms)")], probe: probe, date: monDate(10, 17))
        try expect(journal.alerts[0].isResolved, "résolue")
        try expectEqual(journal.alerts[0].fullMessage, "Latence moyenne 63 ms > 50 ms, revenu à la normale (1,1 ms) à 10:17.", "message complet")
        try expectEqual(journal.unreadCount, 0, "une alerte résolue n'est plus « non lue »")
        try expectEqual(journal.unacknowledgedCount, 1, "mais reste à accuser")

        journal.record([MonEvent(.down, "192.168.50.21 ne répond plus.")], probe: probe, date: monDate(12, 28))
        try expectEqual(journal.unreadCount, 1, "panne non lue")
        try expectEqual(journal.count(.critical), 1, "filtre Critiques")
        try expectEqual(journal.count(.resolved), 1, "filtre Résolues")
        journal.acknowledge(journal.alerts[0].id, by: "Dany", at: monDate(12, 30))
        try expectEqual(journal.unreadCount, 0, "accusée")
        journal.acknowledgeAll(by: "Dany", at: monDate(12, 31))
        try expectEqual(journal.unacknowledgedCount, 0, "tout accusé")

        var news = MonProbe(name: "=Sonde", kind: .newDevices, target: "10.182.122.0/24")
        news.id = UUID()
        journal.record([MonEvent(.warning, "Nouvel appareil =cmd")], probe: news, date: monDate(13))
        try expectEqual(journal.alerts[0].severity, .info, "nouvel appareil = info")
        journal.record([MonEvent(.recovered, "revenu")], probe: news, date: monDate(13, 5))
        try expect(!journal.alerts[0].isResolved, "une information n'est pas « résolue »")

        // Sonde modifiée, suspendue ou supprimée : ses alertes ouvertes sont closes.
        var cam = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21")
        cam.id = UUID()
        var closing = MonJournal()
        closing.record([MonEvent(.down, "192.168.50.21 ne répond plus.")], probe: cam, date: monDate(9))
        try expectEqual(closing.openCount(probe: cam.id), 1, "une alerte ouverte")
        try expectEqual(closing.resolveOpen(probe: cam.id, reason: "sonde modifiée", date: monDate(9, 5)), 1, "close")
        try expectEqual(closing.unreadCount, 0, "plus de badge")
        try expect(closing.alerts[0].fullMessage.hasSuffix("sonde modifiée à 09:05."), "raison : \(closing.alerts[0].fullMessage)")

        let csv = journal.csv()
        try expect(csv.hasPrefix("horodatage;gravite;sonde;evenement"), "en-tête CSV")
        try expect(csv.contains(";'=Sonde;"), "formule neutralisée dans le CSV")
        try expect(csv.split(separator: "\n").count == 4, "3 entrées + en-tête")

        try expectEqual(MonJournal.timestamp(monDate(14, 30, 10), now: monDate(15), calendar: monCalendar),
                        "Aujourd’hui 14:30:10", "aujourd'hui")
        try expectEqual(MonJournal.timestamp(monDate(day: 2, 23, 0, 41), now: monDate(15), calendar: monCalendar),
                        "Hier 23:00:41", "hier")
    }

    suite.add("Surveillance : historique 24 h et disponibilité") {
        var history = MonHistory()
        let id = UUID()
        // 22 h : deux réussites ; 23 h : une panne déclarée ; minuit : un avertissement.
        history.record(probe: id, result: .success(monDate(day: 2, 22, 5)), state: .ok, calendar: monCalendar)
        history.record(probe: id, result: .success(monDate(day: 2, 22, 35)), state: .ok, calendar: monCalendar)
        history.record(probe: id, result: .failure(monDate(day: 2, 23, 10)), state: .down, calendar: monCalendar)
        history.record(probe: id, result: .success(monDate(day: 3, 0, 10), latency: 90), state: .warning, calendar: monCalendar)
        let slots = history.slots(probe: id, now: monDate(day: 3, 0, 30), calendar: monCalendar)
        try expectEqual(slots.count, 24, "24 cases")
        try expectEqual(Array(slots.suffix(3)), [.ok, .down, .warning], "trois dernières heures")
        try expectEqual(slots.first, MonSlot.none, "aucune donnée il y a 23 h")
        try expectEqual(history.availability(probe: id, now: monDate(day: 3, 0, 30), calendar: monCalendar), 75, "3 sur 4")
        // 30 h plus tard : la barre de 24 h est vide, mais les heures restent 7 jours (graphe de 7 j, note 78).
        history.record(probe: id, result: .success(monDate(day: 4, 6)), state: .ok, calendar: monCalendar)
        try expectEqual(history.slots(probe: id, now: monDate(day: 4, 6), calendar: monCalendar).filter { $0 != .none }.count, 1,
                        "une seule heure dans la barre de 24 h")
        try expectEqual(history.buckets[id.uuidString]?.count, 4, "heures gardées 7 jours")
        // 8 jours plus tard : les heures sont sorties, les jours restent (90 jours).
        history.record(probe: id, result: .success(monDate(day: 12, 6)), state: .ok, calendar: monCalendar)
        try expectEqual(history.buckets[id.uuidString]?.count, 1, "anciennes heures retirées")
        try expectEqual(history.days[id.uuidString]?.count, 4, "jours gardés 90 jours")
        history.prune(keeping: [], now: monDate(day: 12, 6), calendar: monCalendar)
        try expect(history.buckets.isEmpty && history.days.isEmpty && history.fine.isEmpty, "sonde supprimée")
    }

    suite.add("Surveillance : encodage et décodage du modèle (surveillance.json)") {
        var probe = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21", subtitle: "Hikvision · VLAN 40",
                             interval: 30, schedule: .businessHours, dependsOn: UUID(), sound: true)
        probe.fallbackPort = 554
        var snmp = MonProbe(name: "SW-CORE-01", kind: .snmp, target: "10.182.122.2", interval: 300)
        snmp.snmpOID = "1.3.6.1.2.1.1.3.0"
        snmp.snmpComparison = .notEqual
        snmp.snmpLimit = 0
        let date = monDate(14, 30, 10)
        var journal = MonJournal()
        journal.record([MonEvent(.down, "hors ligne")], probe: probe, date: date)
        var history = MonHistory()
        history.record(probe: probe.id, result: .failure(date), state: .down, calendar: monCalendar)
        let tracker = MonTracker(state: .down, consecutiveFailures: 3, since: date, alerted: .down,
                                 lastResult: MonResult(date: date, reachable: false, value: "Aucune réponse", error: "Aucune réponse"))
        let archive = MonArchive(probes: [probe, snmp], trackers: [probe.id.uuidString: tracker], history: history, journal: journal)
        let decoded = try MonArchive.decode(try archive.encoded())
        try expectEqual(decoded, archive, "aller-retour JSON")
        try expectEqual(decoded.probes[0].fallbackPort, 554, "condition propre au type")
        try expectEqual(decoded.probes[1].snmpComparison, .notEqual, "comparaison SNMP")

        // Champs facultatifs absents (ancienne version) : la sonde se lit quand même.
        let minimal = """
        {"id":"\(UUID().uuidString)","name":"Ping","kind":"ping","target":"10.0.0.1","subtitle":"","isEnabled":true,
         "interval":60,"thresholds":{"failures":2},"schedule":"always","notify":true,"sound":false}
        """
        let read = try JSONDecoder().decode(MonProbe.self, from: Data(minimal.utf8))
        try expectEqual(read.thresholds.failures, 2, "seuil lu")
        try expect(read.thresholds.latencyMs == nil && read.keyword == nil, "facultatifs absents")

        // Fichier d'une autre version : seuls les éléments illisibles sont écartés.
        let keep = UUID(), other = UUID()
        let future = """
        {"version":2,"probes":[
          {"id":"\(keep.uuidString)","name":"Ping","kind":"ping","target":"10.0.0.1","schedule":"nuits","interval":30},
          {"id":"\(other.uuidString)","name":"DHCP","kind":"dhcp","target":"en0"}],
         "trackers":{"\(keep.uuidString)":{"state":"ok","consecutiveFailures":0},"\(other.uuidString)":{"state":"inconnu","consecutiveFailures":0}},
         "journal":{"alerts":[
          {"id":"\(UUID().uuidString)","date":"2026-11-03T14:00:00Z","probeName":"Ping","severity":"critical","message":"panne"},
          {"id":"\(UUID().uuidString)","date":"2026-11-03T14:01:00Z","probeName":"DHCP","severity":"debug","message":"?"}]}}
        """
        let tolerant = try MonArchive.decode(Data(future.utf8))
        try expectEqual(tolerant.probes.map(\.id), [keep], "sonde de type inconnu écartée, l'autre gardée")
        try expectEqual(tolerant.probes[0].schedule, .always, "plage horaire inconnue : toujours")
        try expectEqual(tolerant.probes[0].interval, 30, "intervalle lu")
        try expectEqual(tolerant.trackers.count, 1, "suivi illisible écarté")
        try expectEqual(tolerant.journal.alerts.count, 1, "entrée de gravité inconnue écartée")
        try expectEqual(tolerant.skipped, 3, "trois éléments écartés")
        try expectEqual(tolerant.history, MonHistory(), "historique absent : vide")

        try expectEqual(MonProbe.intervalLabel(300), "5\u{00A0}min", "intervalle 5 min")
        try expectEqual(MonProbe.intervalMenuLabel(3600), "Toutes les heures", "toutes les heures")
    }
}
