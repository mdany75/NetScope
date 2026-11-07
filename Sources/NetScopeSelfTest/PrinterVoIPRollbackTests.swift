import Foundation
import NetScopeCore

// Notes 91, 92 et 93 (0.37.0) : consommables des imprimantes (réponses SNMP fixes, agent en
// mémoire), note MOS du modèle E (calcul pur), retour à une version précédente (plan,
// suspension, Release lue par un transport simulé). Aucun accès réseau, aucun téléchargement.

private func printerBinds(_ supplies: [(cls: Int64, type: Int64, descr: String, level: Int64, max: Int64)],
                          pages: [Int64] = [], errors: [UInt8]? = nil, alerts: [String] = [], status: Int64 = 3) -> [SNMPVarBind] {
    var binds: [SNMPVarBind] = []
    for (offset, supply) in supplies.enumerated() {
        let index = UInt32(offset + 1)
        let row = PrinterMIBOIDs.supplies
        binds.append(SNMPVarBind(oid: row.appending(4, 1, index), value: .integer(supply.cls)))
        binds.append(SNMPVarBind(oid: row.appending(5, 1, index), value: .integer(supply.type)))
        binds.append(SNMPVarBind(oid: row.appending(6, 1, index), value: .octetString(Array(supply.descr.utf8) + [0])))
        binds.append(SNMPVarBind(oid: row.appending(7, 1, index), value: .integer(13)))
        binds.append(SNMPVarBind(oid: row.appending(8, 1, index), value: .integer(supply.max)))
        binds.append(SNMPVarBind(oid: row.appending(9, 1, index), value: .integer(supply.level)))
    }
    for (offset, count) in pages.enumerated() {
        binds.append(SNMPVarBind(oid: PrinterMIBOIDs.lifeCount.appending(1, UInt32(offset + 1)), value: .counter32(UInt32(count))))
    }
    binds.append(SNMPVarBind(oid: PrinterMIBOIDs.hrPrinter.appending(1, 1), value: .integer(status)))
    if let errors { binds.append(SNMPVarBind(oid: PrinterMIBOIDs.hrPrinter.appending(2, 1), value: .octetString(errors))) }
    for (offset, alert) in alerts.enumerated() {
        binds.append(SNMPVarBind(oid: PrinterMIBOIDs.alertDescription.appending(1, UInt32(offset + 1)), value: .octetString(Array(alert.utf8))))
    }
    // Bruit hors des sous-arbres lus : ignoré.
    binds.append(SNMPVarBind(oid: "1.3.6.1.2.1.1.5.0", value: .octetString(Array("NPI7A4410".utf8))))
    return binds
}

private let colorLaser: [(cls: Int64, type: Int64, descr: String, level: Int64, max: Int64)] = [
    (3, 21, "Black Cartridge HP W2110A", 58, 100),
    (3, 21, "Cyan Cartridge HP W2111A", 9, 100),
    (3, 21, "Magenta Cartridge HP W2113A", 41, 100),
    (3, 21, "Yellow Cartridge HP W2112A", -3, -2),
    (3, 1, "Maintenance Kit", 7_200, 10_000),
    (4, 4, "Toner Collection Unit", 85, 100),
    (3, 9, "Imaging Drum", -2, 100),
]

private func stream(_ from: String, _ to: String, codec: String = "PCMU (G.711 µ-loi)", packets: Int = 1_000,
                    lost: Int = 0, jitter: Double = 2) -> RTPStreamSummary {
    let a = from.split(separator: ":"), b = to.split(separator: ":")
    return RTPStreamSummary(id: from + ">" + to, ssrc: UInt32(truncatingIfNeeded: from.hashValue), source: Endpoint(address: String(a[0]), port: UInt16(a[1])),
                            destination: Endpoint(address: String(b[0]), port: UInt16(b[1])), payloadType: 0, codec: codec,
                            clockRate: 8_000, packets: packets - lost, expected: packets, lost: lost, jitter: jitter,
                            maxDelta: 25, duration: 20, firstPacket: 1)
}

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

private extension Optional {
    func orThrow(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) : valeur absente", file: file, line: line) }
        return value
    }
}

func registerPrinterVoIPRollbackTests(_ suite: TestSuite) {
    // MARK: Note 91

    suite.add("Imprimantes : consommables lus dans la Printer-MIB (agent en mémoire)") {
        let agent = SNMPTableAgent(printerBinds(colorLaser, pages: [48_000, 213], errors: [0x24, 0x02], alerts: ["Cyan cartridge low", "Cyan cartridge low"]))
        let reading = try await PrinterMIB.read(now: Date(timeIntervalSince1970: 0)) { pdu in agent.answer(pdu) }
        try expectEqual(reading.supplies.count, 7, "sept consommables")
        try expectEqual(reading.supplies.map(\.kind), [.toner, .toner, .toner, .toner, .maintenance, .waste, .drum], "familles")
        try expectEqual(reading.supplies.compactMap(\.color), [.black, .cyan, .magenta, .yellow], "couleurs lues dans la description")
        try expectEqual(reading.supplies[1].displayName, "Toner cyan", "nom affiché")
        try expectEqual(reading.supplies[1].percent, 9, "niveau en %")
        try expectEqual(reading.supplies[4].percent, 72, "kit de maintenance 7 200 / 10 000")
        try expectEqual(reading.supplies[3].percent, nil, "niveau -3 : pourcentage inconnu")
        try expectEqual(reading.supplies[3].levelLabel, "il en reste", "niveau -3 : il en reste")
        try expectEqual(reading.supplies[6].levelLabel, "inconnu", "niveau -2 : inconnu")
        try expectEqual(reading.pageCount, 48_213, "compteurs des moteurs additionnés")
        try expectEqual(reading.state, .idle, "hrPrinterStatus 3")
        try expectEqual(reading.errors, [.lowToner, .jammed, .overduePreventMaint], "bits de hrPrinterDetectedErrorState")
        try expectEqual(reading.alerts, ["Cyan cartridge low"], "alertes sans doublon")
        try expectEqual(reading.lowest?.id, "1.2", "consommable le plus bas")
        try expectEqual(reading.lowSupplies(threshold: 15).map(\.id), ["1.2"], "sous 15 %")
        try expectEqual(reading.lowSupplies(threshold: 45).map(\.id), ["1.2", "1.3"], "sous 45 %, du plus bas au plus haut")
        try expectEqual(reading.blockingErrors, [.jammed], "bourrage bloquant")
        try expect(reading.summary.contains("Toner cyan 9\u{00A0}%"), "résumé : \(reading.summary)")
        try expect(reading.summary.contains("48\u{202F}213 pages"), "résumé avec le compteur")
    }

    suite.add("Imprimantes : agent sans Printer-MIB, drapeaux et classes") {
        let agent = SNMPTableAgent([SNMPVarBind(oid: "1.3.6.1.2.1.1.1.0", value: .octetString(Array("Linux".utf8)))])
        do {
            _ = try await PrinterMIB.read { pdu in agent.answer(pdu) }
            throw TestFailure(message: "agent sans consommable accepté", file: #fileID, line: #line)
        } catch let error as PrinterMIBError {
            try expectEqual(error, .noSupplies, "aucun consommable")
        }
        try expectEqual(PrinterErrorFlag.flags([0x40]), [.noPaper], "plus de papier")
        try expectEqual(PrinterErrorFlag.flags([0x00, 0x04]), [.inputTrayEmpty], "bac vide (second octet)")
        try expectEqual(PrinterErrorFlag.flags([]), [], "aucun octet")
        try expectEqual(PrinterSupplyKind.from(type: 5, description: "Ink"), .ink, "encre")
        try expectEqual(PrinterSupplyKind.from(type: 3, description: "Maintenance kit"), .maintenance, "description prioritaire")
        try expectEqual(PrinterSupplyKind.from(type: nil, description: "Tambour noir"), .drum, "tambour en français")
        // Classe 4 : bac de récupération même avec un type « autre ».
        let reading = PrinterMIB.reading(printerBinds([(4, 1, "Waste box", 10, 100)]))
        try expectEqual(reading.supplies.first?.kind, .waste, "classe 4")
        try expectEqual(PrinterMIB.grouped(1_234_567), "1\u{202F}234\u{202F}567", "milliers")
    }

    suite.add("Imprimantes : sonde « consommable bas » et section des rapports") {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = PrinterMIB.reading(printerBinds(colorLaser, pages: [48_213], errors: [0x20]))
        let warn = MonPrinterChecks.evaluate(low, threshold: 15, now: now)
        try expect(warn.reachable, "toner bas : joignable")
        try expect(warn.problem?.contains("Toner cyan 9\u{00A0}%") == true, "alerte : \(warn.problem ?? "nil")")
        try expect(warn.problem?.contains("seuil 15\u{00A0}%") == true, "seuil dans le message")
        let ok = MonPrinterChecks.evaluate(low, threshold: 5, now: now)
        try expectEqual(ok.problem, nil, "aucun consommable sous 5 %")
        let jammed = PrinterMIB.reading(printerBinds(colorLaser, errors: [0x04]))
        let down = MonPrinterChecks.evaluate(jammed, threshold: 15, now: now)
        try expect(!down.reachable, "bourrage : panne")
        try expect(down.error?.contains("Bourrage papier") == true, "raison de la panne")
        try expectEqual(MonProbe.defaultResourceLimit(.printerSupply), 15, "seuil par défaut")
        try expect(MonProbeKind.printerSupply.usesNetwork, "sonde réseau")

        let printers = [
            ReportPrinter(name: "Imprimante accueil", ip: "10.182.122.111",
                          reading: PrinterMIB.reading(printerBinds([(3, 3, "Black Toner", 80, 100)], pages: [100]))),
            ReportPrinter(name: "HP étage 2", ip: "10.182.122.140", reading: low),
        ]
        var input = ReportInput(devices: [])
        input.printers = printers
        let config = ReportConfig(sections: [.imprimantes, .voip], client: "Client", site: "Siège", technician: "Dany", date: "2026-11-06")
        let document = ReportBuilder.build(config: config, input: input)
        try expectEqual(document.sections.map(\.kind), [.voip, .imprimantes], "ordre des sections")
        let blocks = try document.sections.first { $0.kind == .imprimantes }.orThrow("section imprimantes").blocks
        guard case .table(let table)? = blocks.first(where: { if case .table = $0 { return true } else { return false } }) else {
            throw TestFailure(message: "tableau absent", file: #fileID, line: #line)
        }
        try expectEqual(table.rows.first?.cells.first?.text, "HP étage 2", "tri par niveau le plus bas")
        try expectEqual(table.rows.count, 8, "une ligne par consommable")
        let voip = try document.sections.first { $0.kind == .voip }.orThrow("section VoIP").blocks
        guard case .note? = voip.first else { throw TestFailure(message: "note attendue sans mesure", file: #fileID, line: #line) }
    }

    // MARK: Note 92

    suite.add("VoIP : note MOS du modèle E (G.107)") {
        try expect(approx(VoIPQuality.mos(r: 93.2), 4.41), "R 93,2 → MOS 4,41")
        try expectEqual(VoIPQuality.mos(r: -5), 1, "R négatif")
        try expectEqual(VoIPQuality.mos(r: 120), 4.5, "R au-delà de 100")
        try expect(approx(VoIPQuality.mos(r: 50), 2.58), "R 50 → 2,58")
        try expect(approx(VoIPQuality.delayImpairment(100), 2.4), "Id sous 177,3 ms")
        try expect(approx(VoIPQuality.delayImpairment(300), 7.2 + 0.11 * 122.7), "Id au-delà de 177,3 ms")
        try expect(approx(VoIPQuality.equipmentImpairment(lossPercent: 0, codec: .g729), 11), "G.729 sans perte : Ie")
        try expect(approx(VoIPQuality.equipmentImpairment(lossPercent: 5, codec: .g711), 95 * 5 / 30.1), "G.711 à 5 %")

        let clean = VoIPQuality.score(VoIPMeasures(jitterMs: 0, lossPercent: 0), codec: .g711)
        try expect(clean.mos > 4.3 && clean.grade == .excellent, "G.711 parfait : \(clean.mosLabel)")
        try expectEqual(clean.effectiveDelayMs, 20, "délai du codec seul")
        let lossy = VoIPQuality.score(VoIPMeasures(jitterMs: 10, lossPercent: 5), codec: .g711)
        try expect(lossy.mos < clean.mos && lossy.grade <= .fair, "pertes de 5 % : \(lossy.mosLabel)")
        let g729 = VoIPQuality.score(VoIPMeasures(jitterMs: 0, lossPercent: 0), codec: .g729)
        try expect(g729.mos < clean.mos, "G.729 sous G.711")
        let far = VoIPQuality.score(VoIPMeasures(oneWayDelayMs: 400, jitterMs: 30, lossPercent: 20), codec: .g711)
        try expectEqual(far.grade, .bad, "lien inutilisable")
        try expect(far.mos >= 1, "MOS jamais sous 1")
        try expectEqual(VoIPGrade.of(mos: 4.0), .good, "4,0 : bonne")
        try expectEqual(VoIPGrade.of(mos: 3.59), .poor, "3,59 : médiocre")
        try expectEqual(clean.mosLabel.contains(","), true, "virgule décimale")
        try expectEqual(VoIPCodecProfile.matching("PCMA (G.711 A-loi)").name, "G.711", "PCMA")
        try expectEqual(VoIPCodecProfile.matching("G729").name, "G.729", "G729")
        try expectEqual(VoIPCodecProfile.matching("opus").name, "Opus", "opus du SDP")
        try expectEqual(VoIPCodecProfile.matching("dynamique (101)").name, "G.711", "inconnu : G.711")
        let names = VoIPCodecProfile.all.map(\.name)
        try expectEqual(names, names.sorted { FrenchOrder.precedes($0, $1) }, "codecs en ordre alphabétique")
    }

    suite.add("VoIP : appels captés par sens et test simulé iperf3") {
        let streams = [
            stream("10.0.20.21:16384", "10.0.0.5:10000", lost: 30, jitter: 12),
            stream("10.0.0.5:10000", "10.0.20.21:16384"),
            stream("10.0.20.22:16390", "10.0.0.5:10002", codec: "G729"),
        ]
        let calls = VoIPCall.calls(from: streams)
        try expectEqual(calls.count, 2, "deux appels")
        try expect(calls[0].worst.mos <= calls[1].worst.mos, "du plus mauvais au meilleur")
        let both = try calls.first { $0.label.contains("10.0.20.21") }.orThrow("appel à deux sens")
        try expect(both.reverse != nil, "deux sens regroupés")
        let worstSide = min(both.forwardScore.mos, both.reverseScore?.mos ?? 5)
        try expectEqual(both.worst.mos, worstSide, "pire sens retenu")
        let lossySide = both.forward.lost > 0 ? both.forwardScore : try both.reverseScore.orThrow("sens inverse")
        try expectEqual(both.worst.mos, lossySide.mos, "le sens avec pertes est le pire")
        let single = try calls.first { $0.label.contains("10.0.20.22") }.orThrow("appel à un sens")
        try expectEqual(single.reverse, nil, "un seul sens capté")
        try expectEqual(single.forwardScore.codec, "G.729", "codec du flux")

        let udp = IperfResult(protocolName: "UDP", jitterMs: 4, lostPackets: 5, packets: 500, lostPercent: 1)
        let score = try VoIPQuality.score(iperf: udp, codec: .g711).orThrow("score UDP")
        try expect(approx(score.effectiveDelayMs, 28), "délai : 2 × gigue + codec")
        try expectEqual(VoIPQuality.score(iperf: IperfResult(protocolName: "TCP"), codec: .g711), nil, "TCP refusé")
        let noPercent = IperfResult(protocolName: "UDP", jitterMs: 4, lostPackets: 5, packets: 500)
        let recomputed = try VoIPQuality.score(iperf: noPercent).orThrow("score")
        try expect(approx(recomputed.mos, score.mos), "pertes recalculées")
        let options = VoIPQuality.syntheticOptions(host: "127.0.0.1", codec: .g711, calls: 4)
        let arguments = try options.arguments()
        try expect(arguments.contains("-u"), "UDP")
        try expect(arguments.contains("320K"), "4 appels G.711 : 320 kb/s (\(arguments))")
        try expectEqual(options.streams, 1, "un seul flux")

        var input = ReportInput(devices: [])
        input.voipCalls = calls
        input.voipTests = [VoIPSyntheticTest(target: "127.0.0.1:5201", codec: "G.711", calls: 4, jitterMs: 4, lossPercent: 1,
                                             score: score, date: Date(timeIntervalSince1970: 0))]
        let document = ReportBuilder.build(config: ReportConfig(sections: [.voip], site: "Siège", date: "2026-11-06"), input: input)
        let blocks = try document.sections.first.orThrow("section").blocks
        let tables = blocks.compactMap { block -> ReportTable? in if case .table(let t) = block { return t } else { return nil } }
        try expectEqual(tables.count, 2, "appels et test simulé")
        try expectEqual(tables[0].rows.count, 3, "une ligne par sens")
    }

    // MARK: Note 93

    suite.add("Retour arrière : plan, avertissements et suspension de la mise à jour") {
        let current = try UpdVersion("0.37.0").orThrow("version")
        let older = UpdRollback.plan(target: try UpdVersion("0.36.1").orThrow("v"), current: current)
        try expectEqual(older.direction, .older, "plus ancienne")
        try expect(older.title.contains("Revenir à NetScope 0.36.1"), "titre : \(older.title)")
        try expect(older.warnings.isEmpty, "0.36.1 lit le format 2")
        try expect(older.message.contains("Vérifier la signature Developer ID"), "vérification annoncée")
        try expect(older.message.contains(UpdSignature.expectedTeamID), "équipe annoncée")
        try expect(older.message.contains("suspendues"), "suspension annoncée")
        try expect(older.message.contains("données sont gardées"), "données gardées")

        let ancient = UpdRollback.plan(target: try UpdVersion("0.28.0").orThrow("v"), current: current, dataSchema: 2, syncEnabled: true)
        try expectEqual(ancient.warnings.count, 2, "format et synchronisation")
        try expect(ancient.warnings[0].contains("0.30.0"), "première version du format 2")
        let veryOld = UpdRollback.plan(target: try UpdVersion("0.17.0").orThrow("v"), current: current, dataSchema: 1)
        try expect(veryOld.warnings.contains { $0.contains("ne sait pas se mettre à jour") }, "pas de mise à jour avant 0.18")
        try expectEqual(UpdRollback.plan(target: current, current: current).direction, .same, "même version")
        try expect(!UpdRollback.plan(target: current, current: current).message.contains("suspendues"), "réinstallation : pas de suspension")
        try expectEqual(UpdRollback.minimumVersion(forSchema: 2).description, "0.30.0", "schéma 2")
        try expectEqual(UpdRollback.minimumVersion(forSchema: 1).description, "0.18.0", "schéma 1")

        var prefs = UpdPreferences()
        prefs.automaticInstall = true
        let held = UpdRollback.suspend(prefs, target: try UpdVersion("0.36.1").orThrow("v"), now: Date(timeIntervalSince1970: 0))
        try expect(!held.automaticCheck && !held.automaticInstall, "automatique coupé (lu aussi par l'ancienne version)")
        try expectEqual(held.rollbackHold?.version, "0.36.1", "suspension notée")
        try expect(!held.isCheckDue(now: Date(), atLaunch: true), "aucune vérification automatique")
        // Un second retour garde les réglages d'origine.
        let twice = UpdRollback.suspend(held, target: try UpdVersion("0.35.0").orThrow("v"))
        try expectEqual(twice.rollbackHold?.previousAutomaticInstall, true, "réglages d'origine gardés")
        let resumed = UpdRollback.resume(twice)
        try expect(resumed.automaticCheck && resumed.automaticInstall && resumed.rollbackHold == nil, "réactivé")
        try expect(resumed.isCheckDue(now: Date(), atLaunch: true), "vérification de nouveau due")

        let encoded = try JSONEncoder().encode(held)
        let decoded = try JSONDecoder().decode(UpdPreferences.self, from: encoded)
        try expectEqual(decoded.rollbackHold, held.rollbackHold, "suspension enregistrée")
        let legacy = try JSONDecoder().decode(UpdPreferences.self, from: Data("{\"automaticCheck\":true}".utf8))
        try expectEqual(legacy.rollbackHold, nil, "préférences d'avant la 0.37.0")

        let published = ["0.37.0", "0.36.1", "0.36.0", "0.37.1-beta.1", "0.20.0"].compactMap(UpdVersion.init)
        try expectEqual(UpdRollback.previousVersion(published: published, current: current)?.description, "0.36.1", "version précédente")
        try expectEqual(UpdRollback.previousVersion(published: [current], current: current), nil, "aucune plus ancienne")
    }

    suite.add("Retour arrière : Release d'une version lue sur GitHub (transport simulé)") {
        final class Box: @unchecked Sendable { var paths: [String] = [] }
        let box = Box()
        let checker = UpdateChecker(transport: { request in
            let path = request.url!.path
            box.paths.append(path)
            let ok = path.hasSuffix("/releases/tags/v0.36.1")
            let body = ok ? """
            {"tag_name":"v0.36.1","name":"NetScope 0.36.1","draft":false,"prerelease":false,
             "assets":[{"name":"NetScope.dmg","size":10,"browser_download_url":"https://github.com/mdany75/NetScope/releases/download/v0.36.1/NetScope.dmg"}]}
            """ : "{\"message\":\"Not Found\"}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!)
        })
        let release = try await checker.fetchRelease(version: try UpdVersion("0.36.1").orThrow("v"))
        try expectEqual(release.version?.description, "0.36.1", "version lue")
        try expect(release.diskImage != nil, "image disque")
        try expectEqual(box.paths, ["/repos/mdany75/NetScope/releases/tags/v0.36.1"], "requête de l'étiquette")
        do {
            _ = try await checker.fetchRelease(version: try UpdVersion("0.9.9").orThrow("v"))
            throw TestFailure(message: "404 accepté", file: #fileID, line: #line)
        } catch let error as UpdError {
            try expectEqual(error, .missingAsset(version: "v0.9.9"), "version sans Release")
        }
    }
}
