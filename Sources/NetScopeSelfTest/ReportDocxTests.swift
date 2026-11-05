import Foundation
import NetScopeCore

// Note 78 (Rapports) : export DOCX écrit à la main (archive valide, XML bien formé, relations et
// types de contenu complets, texte présent), section « Disponibilité » et ses graphes, courriel du
// rapport planifié (pièce jointe MIME, destinataires par site, désactivé par défaut). Aucun réseau.

private let docxCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    return calendar
}()

private func docxDate(_ day: Int, _ hour: Int = 12, month: Int = 11) -> Date {
    docxCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// Vrai si le XML est bien formé (analyseur de Foundation).
private func wellFormed(_ data: Data) -> Bool {
    XMLParser(data: data).parse()
}

/// Texte des éléments <w:t> d'un document WordprocessingML.
private final class WordText: NSObject, XMLParserDelegate {
    var text = ""
    private var inside = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "w:t" { inside = true }
        if name == "w:p" && !text.isEmpty { text += "\n" }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:t" { inside = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inside { text += string }
    }

    static func of(_ data: Data) -> String {
        let delegate = WordText()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.text
    }
}

private func sampleDocument() -> ReportDocument {
    let table = ReportTable(columns: [ReportColumn("Appareil", weight: 2), ReportColumn("Adresse", mono: true),
                                      ReportColumn("Gravité"), ReportColumn("Occupation", trailing: true)],
                            rows: [ReportRow([ReportCell("SW-CORE-01 <cœur> & « R&D »", bold: true), ReportCell("10.182.122.2"),
                                              ReportCell("Critique", badge: .critical), ReportCell("72 %", bar: 0.72)]),
                                   ReportRow([ReportCell("Sous-total"), ReportCell(""), ReportCell(""), ReportCell("1")], isTotal: true)])
    let chart = ReportUptimeChart(title: "Disponibilité par jour", axis: ["7 oct.", "21 oct.", "5 nov."],
                                  rows: [ReportUptimeRow(label: "Ping passerelle", values: [100, 99.5, nil, 90], total: "97,1 %", tone: .warning)])
    let sections = [
        ReportSection(kind: .resume, heading: "1. Résumé", blocks: [
            .paragraph("Scan réalisé le 3 novembre.\nDeuxième ligne."),
            .kpis([ReportKPI("23", "appareils"), ReportKPI("2", "critiques", tone: .critical)]),
            .bars(title: "Répartition", [ReportBar(label: "Poste", count: 5, fraction: 1, share: "22 %")]),
        ]),
        ReportSection(kind: .disponibilite, heading: "2. Disponibilité (Surveillance)", blocks: [.uptime(chart), .table(table),
                                                                                                    .note("Caractère interdit\u{0001} retiré."),
                                                                                                    .code(["show mac address-table", ""])]),
    ]
    return ReportDocument(title: "Rapport d’audit réseau — Siège", template: .audit, client: "Clinique Exemple", site: "Siège",
                          technician: "Dany Ménard", date: "2026-11-05", dateLabel: "5 novembre 2026", reference: "RPT-20261105-01",
                          generator: "NetScope 0.27.0", signature: true, sections: sections, problems: [])
}

/// PNG de 2 × 1 pixels (en-tête valide).
private let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 2, 0, 0, 0, 1, 8, 6, 0, 0, 0])

func registerReportDocxTests(_ suite: TestSuite) {
    suite.add("Rapports : DOCX écrit à la main, archive et XML valides") {
        let data = ReportDocx.make(sampleDocument(), logoPNG: tinyPNG, date: docxDate(5))
        try expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]), "signature ZIP")
        let entries = try BackupZip.entries(of: data)
        let paths = Set(entries.map(\.path))
        for part in ReportDocx.requiredParts { try expect(paths.contains(part), "partie \(part)") }
        try expectEqual(entries.first?.path, "[Content_Types].xml", "types de contenu en premier")
        try expect(paths.contains("word/media/logo.png"), "logo joint")
        for entry in entries where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
            try expect(wellFormed(entry.data), "XML bien formé : \(entry.path)")
        }
        func part(_ path: String) throws -> String {
            String(decoding: try entries.first { $0.path == path }.unwrap(path).data, as: UTF8.self)
        }
        // Chaque partie est déclarée dans [Content_Types].xml (par extension ou nommément).
        let types = try part("[Content_Types].xml")
        for path in paths where !path.hasSuffix(".rels") && !path.hasSuffix(".png") && path != "[Content_Types].xml" {
            try expect(types.contains("PartName=\"/\(path)\""), "type déclaré : \(path)")
        }
        try expect(types.contains("Extension=\"png\""), "type PNG")
        // Chaque relation vise une partie présente.
        let relations = try part("word/_rels/document.xml.rels")
        for target in ["styles.xml", "settings.xml", "footer1.xml", "media/logo.png"] {
            try expect(relations.contains("Target=\"\(target)\"") && paths.contains("word/" + target), "relation \(target)")
        }
        let packageRels = try part("_rels/.rels")
        try expect(packageRels.contains("Target=\"word/document.xml\""), "document principal")

        let document = try part("word/document.xml")
        let text = WordText.of(Data(document.utf8))
        try expect(text.contains("Rapport d’audit réseau — Siège"), "titre")
        try expect(text.contains("SW-CORE-01 <cœur> & « R&D »"), "texte échappé puis relu tel quel")
        try expect(text.contains("Caractère interdit retiré."), "caractère de contrôle retiré")
        try expect(text.contains("Ping passerelle") && text.contains("97,1 %"), "graphe de disponibilité")
        try expect(text.contains("Signature du client"), "signature")
        try expect(document.contains("<w:br/>"), "retour à la ligne gardé")
        try expect(document.contains("r:embed=\"rId4\""), "logo dans le document")
        try expect(document.contains("w:fill=\"22C55E\"") && document.contains("w:fill=\"E5E7EB\""), "cases vertes et grises")
        try expect(document.contains("<w:tblHeader/>"), "en-tête de tableau répété")
        let footer = try part("word/footer1.xml")
        try expect(footer.contains("NUMPAGES"), "numéro de page")
        let core = try part("docProps/core.xml")
        try expect(core.contains("<dc:creator>Dany Ménard</dc:creator>"), "auteur")

        // Sans logo : ni image ni relation d'image.
        let plain = try BackupZip.entries(of: ReportDocx.make(sampleDocument(), logoPNG: Data("pas une image".utf8), date: docxDate(5)))
        try expect(!plain.contains { $0.path.hasPrefix("word/media/") }, "logo illisible ignoré")
        let plainRels = String(decoding: try plain.first { $0.path == "word/_rels/document.xml.rels" }.unwrap("rels").data, as: UTF8.self)
        try expect(!plainRels.contains("image"), "aucune relation d'image")
        try expectEqual(ReportDocx.pngSize(tinyPNG)?.width, 2, "largeur du PNG")
        try expectEqual(ReportFormat.docx.fileExtension, "docx", "extension")
        try expectEqual(ReportConfig(client: "Clinique", date: "2026-11-05").fileName(for: .docx).hasSuffix(".docx"), true, "nom du fichier")
    }

    suite.add("Rapports : section Disponibilité d'après l'historique de la Surveillance") {
        var history = MonHistory()
        let gateway = MonProbe(name: "Ping passerelle", kind: .ping, target: "10.182.122.1", interval: 60)
        let camera = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21", interval: 300)
        let silent = MonProbe(name: "Nouvelle sonde", kind: .ping, target: "10.182.122.9")
        for day in 1...5 {
            for hour in [8, 12, 16] {
                history.record(probe: gateway.id, result: .success(docxDate(day, hour), latency: 1.5), state: .ok, interval: 60,
                               calendar: docxCalendar)
            }
        }
        history.record(probe: camera.id, result: .success(docxDate(4, 8), latency: 3), state: .ok, interval: 300, calendar: docxCalendar)
        history.record(probe: camera.id, result: .failure(docxDate(4, 9)), state: .down, interval: 300, calendar: docxCalendar)
        history.record(probe: camera.id, result: .failure(docxDate(4, 10)), state: .down, interval: 300, calendar: docxCalendar)
        history.record(probe: camera.id, result: .success(docxDate(5, 8), latency: 3), state: .ok, interval: 300, calendar: docxCalendar)
        var journal = MonJournal()
        journal.record([MonEvent(.down, "192.168.50.21 ne répond plus.")], probe: camera, date: docxDate(4, 9))
        let window = MonMaintenanceWindow(name: "Mises à jour FortiOS", start: docxDate(25, 2, month: 10), durationMinutes: 180, repeats: .weekly)
        let availability = ReportAvailability.make(probes: [gateway, camera, silent], history: history, journal: journal, days: 30,
                                                   now: docxDate(5, 18), planning: MonPlanning(windows: [window]), site: nil,
                                                   calendar: docxCalendar)
        try expectEqual(availability.probes.count, 3, "trois sondes")
        try expectEqual(availability.probes[0].percent, 100, "passerelle 100 %")
        try expectEqual(availability.probes[1].percent, 50, "caméra 2 sur 4")
        try expectEqual(availability.probes[1].downSeconds, 600, "10 min hors ligne")
        try expectEqual(availability.probes[1].incidents, 1, "une panne")
        try expectEqual(availability.probes[1].days.count, 30, "30 jours")
        try expectEqual(availability.probes[1].days.suffix(2).map { $0.map { ($0 * 10).rounded() / 10 } }, [33.3, 100], "deux derniers jours")
        try expectEqual(availability.probes[2].percent, nil, "sonde sans donnée")
        try expectEqual(availability.maintenance.count, 1, "fenêtre de maintenance citée")

        var input = ReportInput(devices: [], now: docxDate(5, 18))
        input.availability = availability
        var config = ReportConfig(client: "Clinique", site: "Siège", technician: "Dany", date: "2026-11-05")
        config.sections = [.disponibilite]
        let document = ReportBuilder.build(config: config, input: input)
        let section = try document.section(.disponibilite).unwrap("section")
        try expectEqual(section.heading, "1. Disponibilité (Surveillance)", "titre")
        let charts = section.blocks.compactMap { block -> ReportUptimeChart? in if case .uptime(let c) = block { return c }; return nil }
        try expectEqual(charts.count, 1, "un graphe")
        try expectEqual(charts[0].rows.map(\.total), ["100\u{00A0}%", "50,0\u{00A0}%", "—"], "totaux")
        try expectEqual(charts[0].axis, ["7 oct.", "21 oct.", "5 nov."], "axe")
        try expectEqual(ReportUptimeRow.tone(99.95), .success, "vert")
        try expectEqual(ReportUptimeRow.tone(97), .warning, "orange")
        try expectEqual(ReportUptimeRow.tone(nil), .neutral, "gris")
        // Graphe dans tous les formats : hauteur pour la pagination, HTML, JSON.
        let metrics = ReportPageMetrics()
        try expect(metrics.height(of: .uptime(charts[0])) > metrics.barTitleHeight, "hauteur du graphe")
        try expect(ReportPaginator.paginate(document).count == 1, "une page")
        let html = ReportExport.html(document)
        try expect(html.contains("class=\"uptime\"") && html.contains("Caméra-Quai"), "graphe HTML")
        let json = String(decoding: try ReportExport.json(document), as: UTF8.self)
        try expect(json.contains("\"disponibilites\"") && json.contains("\"sonde\" : \"Caméra-Quai\""), "graphe JSON")
        // Beaucoup de sondes : plusieurs graphes, chacun sur une page.
        var many = availability
        many.probes = Array(repeating: availability.probes[0], count: 30)
        let blocks = ReportBuilder.availabilityBlocks(many, calendar: docxCalendar)
        try expectEqual(blocks.filter { if case .uptime = $0 { return true }; return false }.count, 3, "30 sondes : 3 graphes")
        // Sans sonde : une note qui explique quoi faire.
        let empty = ReportBuilder.availabilityBlocks(nil)
        try expect(empty.count == 1, "note seule")
    }

    suite.add("Rapports : courriel du rapport planifié, pièce jointe et destinataires par site") {
        var smtp = AlertSMTPSettings()
        smtp.host = "smtp.exemple.ca"
        smtp.from = "netscope@exemple.ca"
        smtp.fromName = "NetScope"
        smtp.username = "netscope@exemple.ca"
        var schedule = ReportSchedule(name: "Suivi hebdomadaire", siteKeys: ["siege", "laval"])
        try expectEqual(schedule.email, .none, "désactivé par défaut")
        schedule.email = .send
        schedule.mailRecipients = ["siege": ["dg@clinique.ca", " DG@clinique.ca ", "ti@clinique.ca"], "laval": ["pas-une-adresse"]]
        try expectEqual(ReportMail.recipients(schedule, siteKey: "siege"), ["dg@clinique.ca", "ti@clinique.ca"], "sans doublon")
        try expect(ReportMail.problems(smtp: smtp, hasPassword: true, schedule: schedule, siteKey: "siege", siteName: "Siège").isEmpty, "prêt")
        let laval = ReportMail.problems(smtp: smtp, hasPassword: true, schedule: schedule, siteKey: "laval", siteName: "Laval")
        try expect(laval.contains { $0.contains("Destinataire invalide") } && laval.contains { $0.contains("Aucun destinataire") },
                   "Laval sans destinataire valide")
        try expect(ReportMail.problems(smtp: smtp, hasPassword: false, schedule: schedule, siteKey: "siege", siteName: "Siège")
                    .contains { $0.contains("Trousseau") }, "mot de passe manquant")

        let pdf = Data((0..<3_000).map { UInt8($0 % 251) })
        let message = ReportMail.message(scheduleName: "Suivi hebdomadaire", siteName: "Siège", fileName: "rapport-audit-siège-2026-11-09.pdf",
                                         data: pdf, recipients: ["dg@clinique.ca"], smtp: smtp, date: docxDate(9, 7), isTest: true,
                                         calendar: docxCalendar)
        try expect(message.subject.hasPrefix("[Essai] Suivi hebdomadaire — Siège"), "objet de l'essai")
        let raw = message.rendered(boundary: "LIMITE", timeZone: docxCalendar.timeZone)
        try expect(raw.contains("Content-Type: multipart/mixed; boundary=\"LIMITE-mixte\""), "multipart/mixed")
        try expect(raw.contains("Content-Type: application/pdf; name=\"rapport-audit-si_ge-2026-11-09.pdf\""), "type et nom ASCII")
        try expect(raw.contains("filename*=UTF-8''rapport-audit-si%C3%A8ge-2026-11-09.pdf"), "nom UTF-8 (RFC 2231)")
        try expect(raw.hasSuffix("--LIMITE-mixte--\r\n"), "fin du message")
        try expect(raw.unicodeScalars.allSatisfy { $0.isASCII }, "message 7 bits")
        try expect(raw.components(separatedBy: "\r\n").allSatisfy { $0.count <= 998 }, "lignes de 998 caractères au plus")
        // La pièce jointe relue est identique.
        let parts = raw.components(separatedBy: "--LIMITE-mixte")
        let attachment = try parts.first { $0.contains("Content-Disposition: attachment") }.unwrap("pièce jointe")
        let base64 = attachment.components(separatedBy: "\r\n\r\n").dropFirst().joined().replacingOccurrences(of: "\r\n", with: "")
        try expectEqual(Data(base64Encoded: base64), pdf, "pièce jointe intacte")
        // Courriel d'alerte ordinaire : inchangé (aucune pièce jointe, pas de multipart/mixed).
        let alert = AlertMailMessage(from: "a@b.ca", to: ["c@d.ca"], subject: "Test", textBody: "Bonjour")
        try expect(!alert.rendered(boundary: "X").contains("multipart/mixed"), "alerte sans pièce jointe")
        try expectEqual(AlertMailAttachment.contentType(forExtension: "DOCX"),
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "type DOCX")

        // Enregistrement : l'envoi et les destinataires sont relus ; un ancien fichier reste sans envoi.
        let book = ReportScheduleBook(schedules: [schedule])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(ReportScheduleBook.self, from: encoder.encode(book))
        try expectEqual(back.schedules.first?.email, .send, "envoi relu")
        try expectEqual(back.schedules.first?.mailRecipients["siege"]?.count, 3, "destinataires relus")
        let legacy = #"{"schedules":[{"id":"\#(UUID().uuidString)","name":"Ancien","email":"draft"}]}"#
        let old = try decoder.decode(ReportScheduleBook.self, from: Data(legacy.utf8))
        try expectEqual(old.schedules.first?.mailRecipients, [:], "aucun destinataire")
        let unknown = #"{"schedules":[{"id":"\#(UUID().uuidString)","name":"Futur","email":"teams"}]}"#
        try expectEqual(try decoder.decode(ReportScheduleBook.self, from: Data(unknown.utf8)).schedules.first?.email, ScheduleEmailNone.value,
                        "choix inconnu : rien n'est envoyé")
    }
}

/// `.none` d'un optionnel serait ambigu dans `expectEqual` : valeur nommée.
private enum ScheduleEmailNone {
    static let value = ReportScheduleEmail.none
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
