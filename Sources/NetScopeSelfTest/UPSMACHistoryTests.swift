import Foundation
import NetScopeCore

// Notes 98 et 99 (1.2.0) : onduleurs par SNMP (réponses fixes, agent en mémoire) et historique
// des adresses MAC (observations fixes). Aucun accès réseau.

private func bind(_ oid: String, _ value: SNMPValue) -> SNMPVarBind { SNMPVarBind(oid: SNMPOID(oid)!, value: value) }
private func text(_ oid: String, _ value: String) -> SNMPVarBind { bind(oid, .octetString(Array(value.utf8))) }

/// APC Smart-UPS : UPS-MIB et PowerNet.
private func apcBinds(source: Int64 = 3, minutes: Int64 = 42, replace: Int64 = 1, replaced: String = "03/14/25",
                      alarms: [UInt32] = [], test: Int64 = 1) -> [SNMPVarBind] {
    var list = [
        text("1.3.6.1.2.1.33.1.1.1.0", "APC"),
        text("1.3.6.1.2.1.33.1.1.2.0", "Smart-UPS 1500"),
        bind("1.3.6.1.2.1.33.1.2.1.0", .integer(2)),
        bind("1.3.6.1.2.1.33.1.2.2.0", .integer(source == 5 ? 240 : 0)),
        bind("1.3.6.1.2.1.33.1.2.3.0", .integer(minutes)),
        bind("1.3.6.1.2.1.33.1.2.4.0", .integer(100)),
        bind("1.3.6.1.2.1.33.1.2.7.0", .integer(27)),
        bind("1.3.6.1.2.1.33.1.3.3.1.3.1", .integer(121)),
        bind("1.3.6.1.2.1.33.1.4.1.0", .integer(source)),
        bind("1.3.6.1.2.1.33.1.4.4.1.2.1", .integer(120)),
        bind("1.3.6.1.2.1.33.1.4.4.1.5.1", .integer(31)),
        bind("1.3.6.1.2.1.33.1.7.3.0", .integer(test)),
        text("1.3.6.1.4.1.318.1.1.1.2.1.3.0", replaced),
        bind("1.3.6.1.4.1.318.1.1.1.2.2.4.0", .integer(replace)),
        text("1.3.6.1.4.1.318.1.1.1.7.2.4.0", "10/01/2026"),
        // Bruit hors des sous-arbres lus.
        text("1.3.6.1.2.1.1.5.0", "UPS-SALLE-SERVEURS"),
    ]
    for (offset, alarm) in alarms.enumerated() {
        list.append(bind("1.3.6.1.2.1.33.1.6.2.1.2.\(offset + 1)", .oid(SNMPOID("1.3.6.1.2.1.33.1.6.3.\(alarm)")!)))
    }
    return list
}

private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }

func registerUPSMACHistoryTests(_ suite: TestSuite) {
    // MARK: Note 98

    suite.add("Onduleurs : UPS-MIB et PowerNet lus par un agent en mémoire") {
        let agent = SNMPTableAgent(apcBinds())
        let now = day("2026-11-06")
        let reading = try await UPSMIB.read(now: now) { pdu in agent.answer(pdu) }
        try expectEqual(reading.source, .mains, "secteur")
        try expectEqual(reading.batteryStatus, .normal, "batterie normale")
        try expectEqual(reading.runtimeMinutes, 42, "autonomie en minutes (RFC 1628)")
        try expectEqual(reading.loadPercent, 31, "charge")
        try expectEqual(reading.inputVoltage, 121, "tension d'entrée")
        try expectEqual(reading.temperature, 27, "température")
        try expectEqual(reading.lastTest, .passed, "dernier test")
        try expectEqual(reading.displayModel, "APC Smart-UPS 1500", "modèle")
        try expectEqual(reading.mibs, ["UPS-MIB", "APC PowerNet"], "MIB lues")
        try expectEqual(reading.batteryReplacedDate.map(UPSMIB.dateLabel), "14 mars 2025", "date de remplacement (mm/jj/aa)")
        try expectEqual(reading.lastTestDate.map(UPSMIB.dateLabel), "1 octobre 2026", "date du dernier test")
        try expect(!reading.batteryDue(now: now), "batterie récente")
        try expectEqual(reading.summary, "Secteur · batterie 100\u{00A0}% · autonomie 42\u{00A0}min · charge 31\u{00A0}%", "résumé")
        let none = SNMPTableAgent([text("1.3.6.1.2.1.1.1.0", "Linux")])
        do {
            _ = try await UPSMIB.read { pdu in none.answer(pdu) }
            throw TestFailure(message: "agent sans MIB d'onduleur accepté", file: #fileID, line: #line)
        } catch let error as UPSMIBError {
            try expectEqual(error, .noUPS, "erreur claire")
        }
    }

    suite.add("Onduleurs : MIB des fabricants seules (Eaton, CyberPower) et dates") {
        let eaton = try UPSMIB.reading([
            text("1.3.6.1.4.1.534.1.1.2.0", "Eaton 5PX 1500"),
            bind("1.3.6.1.4.1.534.1.2.1.0", .integer(1_800)),
            bind("1.3.6.1.4.1.534.1.2.4.0", .integer(87)),
            bind("1.3.6.1.4.1.534.1.2.5.0", .integer(8)),
            text("1.3.6.1.4.1.534.1.2.6.0", "2019-05-02"),
            bind("1.3.6.1.4.1.534.1.4.1.0", .integer(64)),
            bind("1.3.6.1.4.1.534.1.4.5.0", .integer(5)),
            bind("1.3.6.1.4.1.534.1.8.2.0", .integer(3)),
        ]).orThrow("Eaton")
        try expectEqual(eaton.manufacturer, "Eaton", "fabricant déduit de la MIB")
        try expectEqual(eaton.source, .battery, "sur batterie (xupsOutputSource)")
        try expectEqual(eaton.runtimeMinutes, 30, "secondes → minutes")
        try expectEqual(eaton.batteryStatus, .fault, "checkBattery")
        try expectEqual(eaton.lastTest, .failed, "test échoué")
        let cps = try UPSMIB.reading([
            bind("1.3.6.1.4.1.3808.1.1.1.4.1.1.0", .integer(2)),
            bind("1.3.6.1.4.1.3808.1.1.1.2.2.4.0", .timeTicks(360_000)),
            bind("1.3.6.1.4.1.3808.1.1.1.3.2.1.0", .integer(1_205)),
            bind("1.3.6.1.4.1.3808.1.1.1.2.2.5.0", .integer(2)),
        ]).orThrow("CyberPower")
        try expectEqual(cps.source, .mains, "en ligne")
        try expectEqual(cps.runtimeMinutes, 60, "TimeTicks → minutes")
        try expectEqual(cps.inputVoltage, 120.5, "dixièmes de volt")
        try expect(cps.replaceIndicator, "voyant de remplacement")
        try expectEqual(UPSMIB.reading([text("1.3.6.1.2.1.1.1.0", "Linux")]), nil, "aucune MIB d'onduleur")
        try expectEqual(UPSMIB.parseDate("13/45/22"), nil, "date invalide")
        try expectEqual(UPSMIB.minutes(65), "1\u{00A0}h\u{00A0}05", "heures")
    }

    suite.add("Onduleurs : sonde (batterie, autonomie, batterie à changer)") {
        let now = day("2026-11-06")
        let ok = try UPSMIB.reading(apcBinds(), now: now).orThrow("relevé")
        let fine = MonUPSChecks.evaluate(ok, minRuntime: 10, now: now)
        try expect(fine.reachable && fine.problem == nil, "secteur, autonomie suffisante : OK")
        let battery = try UPSMIB.reading(apcBinds(source: 5, minutes: 18, alarms: [2]), now: now).orThrow("relevé")
        let down = MonUPSChecks.evaluate(battery, minRuntime: 10, now: now)
        try expect(!down.reachable, "sur batterie : panne")
        try expectEqual(down.error, "Sur batterie depuis 4\u{00A0}min, autonomie 18\u{00A0}min", "message")
        let short = try UPSMIB.reading(apcBinds(minutes: 6), now: now).orThrow("relevé")
        try expect(MonUPSChecks.evaluate(short, minRuntime: 10, now: now).problem?.contains("Autonomie basse") == true, "autonomie basse")
        let old = try UPSMIB.reading(apcBinds(replaced: "01/10/21"), now: now).orThrow("relevé")
        try expect(old.batteryDueReason(now: now) == nil, "l'âge seul ne déclenche pas l'alerte")
        try expect(MonUPSChecks.evaluate(old, minRuntime: 10, now: now).problem == nil, "sonde : pas d'alerte sur l'âge seul")
        try expect(old.batteryAgeNote(now: now)?.contains("5\u{00A0}ans, à vérifier") == true, "âge noté dans la fiche")
        // Dates impossibles : valeur par défaut « 01/01/00 », date future, 31 février.
        try expect(UPSMIB.parseDate("01/01/00", now: now) == nil, "01/01/00 écartée")
        try expect(UPSMIB.parseDate("03/14/29", now: now) == nil, "date future écartée")
        try expect(UPSMIB.parseDate("02/31/24", now: now) == nil, "31 février écarté")
        try expect(UPSMIB.parseDate("01/02/00", now: now) != nil, "2 janvier 2000 accepté")
        // Autotest : sur batterie le temps du test, avec l'alarme 24 : pas de panne ni d'alerte.
        let selfTest = try UPSMIB.reading(apcBinds(source: 5, alarms: [2, 24], test: 5), now: now).orThrow("relevé")
        let testing = MonUPSChecks.evaluate(selfTest, minRuntime: 10, now: now)
        try expect(testing.reachable && testing.problem == nil, "autotest : ni panne ni alerte")
        try expect(testing.value.hasPrefix("Autotest en cours"), "autotest affiché")
        let alarmOnly = try UPSMIB.reading(apcBinds(source: 5, alarms: [24]), now: now).orThrow("relevé")
        try expect(MonUPSChecks.evaluate(alarmOnly, minRuntime: 10, now: now).reachable, "alarme « Test en cours » seule")
        let pending = try UPSMIB.reading(apcBinds(alarms: [24]), now: now).orThrow("relevé")
        try expect(MonUPSChecks.evaluate(pending, minRuntime: 10, now: now).problem == nil, "« Test en cours » n'est pas une alerte")
        let flagged = try UPSMIB.reading(apcBinds(replace: 2), now: now).orThrow("relevé")
        try expect(MonUPSChecks.evaluate(flagged, minRuntime: 10, now: now).problem?.contains("Batterie à changer") == true, "voyant")
        try expectEqual(MonProbe.defaultResourceLimit(.upsStatus), 10, "seuil proposé")
    }

    suite.add("Onduleurs : type détecté et section du rapport") {
        let classify = { (oid: String?, descr: String) in SNMPDiscovery.classify(sysObjectID: oid, sysDescr: descr, bridgePorts: nil) }
        try expectEqual(classify("1.3.6.1.4.1.318.1.3.27", "APC Web/SNMP Management Card"), .onduleur, "APC")
        try expectEqual(classify("1.3.6.1.4.1.534.6.6.7", "Eaton Network-M2"), .onduleur, "Eaton")
        try expectEqual(classify("1.3.6.1.4.1.3808.1.1.1", "CyberPower RMCARD205"), .onduleur, "CyberPower")
        try expectEqual(classify("1.3.6.1.4.1.8072.3.2.10", "Linux backup-groups 5.10"), .autre, "« groups » n'est pas un onduleur")
        try expect(classify("1.3.6.1.4.1.318.1.3.4.6", "APC Web/SNMP Management Card (MN:AP8941)") != .onduleur, "PDU de baie APC")
        try expect(classify("1.3.6.1.4.1.318.1.3.11", "APC Automatic Transfer Switch") != .onduleur, "ATS APC")
        try expect(classify("1.3.6.1.4.1.5528.100.20.10", "NetBotz 450") != .onduleur, "NetBotz")
        try expect(classify("1.3.6.1.4.1.534.6.6.7", "Eaton ePDU MA 1P") != .onduleur, "ePDU Eaton")
        try expectEqual(ScanDeviceClassifier.guess(ports: [80, 443], vendor: "American Power Conversion Corp", hostname: nil, mac: nil),
                        .onduleur, "carte réseau APC")
        try expectEqual(ScanDeviceClassifier.guess(ports: [], vendor: nil, hostname: nil, mac: nil, snmpKind: .onduleur), .onduleur, "SNMP")
        let now = day("2026-11-06")
        var input = ReportInput(devices: [])
        input.now = now
        input.upsUnits = [
            ReportUPS(name: "UPS baie réseau", ip: "10.182.122.5", reading: try UPSMIB.reading(apcBinds(), now: now).orThrow("relevé")),
            ReportUPS(name: "UPS salle serveurs", ip: "10.182.122.6",
                      reading: try UPSMIB.reading(apcBinds(source: 5, minutes: 12), now: now).orThrow("relevé")),
        ]
        let config = ReportConfig(sections: [.onduleurs, .imprimantes], client: "Client", site: "Siège", technician: "Dany", date: "2026-11-06")
        let document = ReportBuilder.build(config: config, input: input)
        try expectEqual(document.sections.map(\.kind), [.imprimantes, .onduleurs], "ordre des sections")
        let blocks = try document.sections.first { $0.kind == .onduleurs }.orThrow("section onduleurs").blocks
        guard case .table(let table)? = blocks.first(where: { if case .table = $0 { return true } else { return false } }) else {
            throw TestFailure(message: "tableau absent", file: #fileID, line: #line)
        }
        try expectEqual(table.rows.first?.cells.first?.text, "UPS salle serveurs", "sur batterie en tête")
        try expectEqual(table.rows.first?.cells[2].badge, .critical, "pastille rouge")
        var empty = ReportInput(devices: [])
        empty.now = now
        let none = ReportBuilder.build(config: config, input: empty).sections.first { $0.kind == .onduleurs }?.blocks.first
        guard case .note? = none else { throw TestFailure(message: "note attendue sans relevé", file: #fileID, line: #line) }
    }

    // MARK: Note 99

    suite.add("Historique MAC : fusion des relevés, chronologie et conservation") {
        let mac = MACAddress("94:DD:F8:18:15:7D")!
        let other = MACAddress("00:1A:2B:44:10:EE")!
        let d1 = day("2026-06-01"), d2 = day("2026-08-15"), d3 = day("2026-11-05")
        var history = MACHistory()
        let printer = Device(ip: IPv4Address("10.182.122.111")!, mac: mac, hostname: "BRN94DDF818157D", customName: "Imprimante accueil",
                             switchName: "SW-ETG2-01", switchPort: "1/14", vlan: 30)
        try expectEqual(history.record(MACHistory.observations(devices: [printer]), at: d1), 4, "IP, nom, port, VLAN")
        var moved = printer
        moved.ip = IPv4Address("10.182.122.140")!
        moved.switchPort = "1/18"
        history.record(MACHistory.observations(devices: [moved]), at: d2)
        history.record(MACHistory.observations(devices: [moved]), at: d3)
        // MAC nulle, de diffusion : écartées ; appareil hors ligne : rien.
        var offline = printer
        offline.mac = other
        offline.isOnline = false
        history.record(MACHistory.observations(devices: [offline]) + [MACObservation(mac: MACAddress("FF:FF:FF:FF:FF:FF")!, kind: .ip, value: "10.0.0.1", source: .scan)], at: d3)
        try expectEqual(history.macCount, 1, "une seule MAC retenue")
        let timeline = history.timeline(for: mac)
        try expectEqual(timeline.first?.lastSeen, d3, "la plus récente d'abord")
        let name = try timeline.first { $0.kind == .name }.orThrow("nom")
        try expect(name.firstSeen == d1 && name.lastSeen == d3 && name.count == 3, "période et nombre de relevés")
        let oldPort = try timeline.first { $0.value == "SW-ETG2-01 · 1/14" }.orThrow("ancien port")
        try expectEqual(oldPort.lastSeen, d1, "ancien port gardé avec sa date")
        try expectEqual(history.prune(retentionDays: 90, now: d3), 2, "IP et port de juin retirés après 90 jours")
        try expectEqual(history.timeline(for: mac).count, 4, "reste : nouvelle IP, nouveau port, nom, VLAN")
    }

    suite.add("Historique MAC : recherche par MAC, IP, nom et date ; sources et CSV") {
        let mac = MACAddress("94:DD:F8:18:15:7D")!
        let d1 = day("2026-06-01"), d2 = day("2026-08-15")
        var history = MACHistory()
        history.record([MACObservation(mac: mac, kind: .ip, value: "10.182.122.111", source: .scan),
                        MACObservation(mac: mac, kind: .name, value: "Imprimante accueil", source: .scan)], at: d1)
        history.record([MACObservation(mac: mac, kind: .ip, value: "10.182.122.140", source: .scan)], at: d2)
        try expectEqual(history.search("94dd.f818.157d").first?.mac, mac, "MAC au format Cisco")
        try expectEqual(history.search("15:7d").first?.mac, mac, "MAC partielle")
        try expectEqual(history.search("10.182.122.111").count, 1, "ancienne IP")
        try expectEqual(history.search("10.182.122.11").count, 0, "IP exacte seulement")
        try expect(history.search("10.10.20.5").isEmpty, "une IP n'est pas une MAC partielle")
        try expect(history.search("10.182.").count == 1, "préfixe d'IP")
        try expect(MACHistory.looksLikeIPv4("10.10.") && !MACHistory.looksLikeIPv4("94dd.f818"), "IP ou MAC Cisco")
        try expectEqual(history.search("imprimante ACCUEIL").first?.latestName, "Imprimante accueil", "nom, casse ignorée")
        let june = history.search("94:dd:f8:18:15:7d", on: day("2026-06-01")).first?.sightings.map(\.value) ?? []
        try expectEqual(june.sorted(), ["10.182.122.111", "Imprimante accueil"], "ce jour-là")
        try expect(history.search("10.182.122.140", on: day("2026-05-01")).isEmpty, "avant la première vue : rien")
        // Relevés des switchs : port d'accès, VLAN et ARP.
        let snapshot = SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-ETG2-01", descr: "", objectID: nil),
                                          interfaces: [SNMPInterface(index: 14, name: "1/14", descr: "", alias: "", type: 6, adminUp: true, operStatus: .up)],
                                          fdb: [SNMPFDBEntry(mac: mac, vlan: 30, bridgePort: 14, ifIndex: 14)], neighbors: [],
                                          arp: [mac: IPv4Address("10.182.122.140")!], polledAt: d2)
        let fromSwitch = MACHistory.observations(snapshots: [snapshot])
        try expectEqual(Set(fromSwitch.map(\.value)), ["SW-ETG2-01 · 1/14", "30", "10.182.122.140"], "port, VLAN, IP")
        let client = FortiWifiClient(site: "Siège", mac: mac, ip: IPv4Address("10.182.130.40")!, hostname: "iPhone-Dany", ssid: "Bureau", apName: "FAP-ETG2-NORD")
        try expectEqual(MACHistory.observations(wifiClients: [client]).first?.value, "FAP-ETG2-NORD (Bureau)", "borne et SSID")
        let csv = MACHistory.csv(history.timeline(for: mac))
        try expect(csv.hasPrefix("MAC;Nature;Valeur;Première vue;Dernière vue;Relevés;Sources\n"), "en-tête")
        try expect(csv.contains(mac.description + ";Adresse IP;10.182.122.140;2026-08-15T12:00:00Z"), "ligne IP")
        try expect(MACHistory.csv([MACSighting(mac: mac, kind: .name, value: "=CMD()", sources: [.scan], firstSeen: d1, lastSeen: d1)]).contains(";'=CMD();"),
                   "pas de formule")
        let data = try JSONEncoder().encode(history)
        try expectEqual(try JSONDecoder().decode(MACHistory.self, from: data), history, "aller-retour JSON")
        // Ancien fichier (première et dernière vue seulement) : une période.
        let legacy = #"{"sightings":{"k":{"mac":"94:DD:F8:18:15:7D","kind":"ip","value":"10.0.0.1","sources":["scan"],"firstSeen":0,"lastSeen":86400,"count":2}}}"#
        let decoded = try JSONDecoder().decode(MACHistory.self, from: Data(legacy.utf8))
        try expectEqual(decoded.sightings.values.first?.periods.count, 1, "ancien format : une période")
    }

    suite.add("Historique MAC : périodes (retour sur une ancienne IP, bornes alternées)") {
        let mac = MACAddress("94:DD:F8:18:15:7D")!
        let jan = day("2026-01-10"), feb = day("2026-02-10"), may = day("2026-05-10"), jun = day("2026-06-10")
        var history = MACHistory()
        func ip(_ value: String, _ date: Date) { history.record([MACObservation(mac: mac, kind: .ip, value: value, source: .scan)], at: date) }
        ip("10.0.0.1", jan); ip("10.0.0.2", feb); ip("10.0.0.2", may); ip("10.0.0.1", jun)
        let march = day("2026-03-15")
        let values = history.search(mac.description, on: march).first?.sightings.map(\.value) ?? []
        try expectEqual(values, ["10.0.0.2"], "en mars : B seulement, pas A")
        let a = try history.timeline(for: mac).first { $0.value == "10.0.0.1" }.orThrow("A")
        try expectEqual(a.periods.count, 2, "A : deux périodes")
        try expect(!a.covers(march) && a.covers(jan) && a.covers(jun), "A couvre janvier et juin seulement")
        // Même valeur revue sans autre entre-temps : la période est prolongée.
        ip("10.0.0.1", day("2026-06-20"))
        try expectEqual(history.timeline(for: mac).first { $0.value == "10.0.0.1" }?.periods.count, 2, "prolongée")
        // Conservation : les périodes expirées sont retirées, la valeur reste.
        history.prune(retentionDays: 60, now: day("2026-06-20"))
        try expectEqual(history.timeline(for: mac).first { $0.value == "10.0.0.1" }?.periods.count, 1, "période de janvier retirée")
    }
}

private extension Optional {
    func orThrow(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) : valeur absente", file: file, line: line) }
        return value
    }
}
