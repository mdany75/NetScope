import Foundation

// Section facultative « Diagnostic Wi-Fi » des rapports (note 47) : diagnostics des clients, bornes
// et SSID retenus par « Ajouter au rapport du site », avec leur verdict, la cause la plus probable,
// les preuves et les actions suggérées.

extension WifiVerdict {
    var reportTone: ReportTone {
        switch self {
        case .problem: return .critical
        case .watch: return .warning
        case .ok: return .success
        case .notMeasured: return .neutral
        }
    }
}

extension ReportBuilder {
    static func wifiDiagnosisBlocks(_ results: [WifiDiagnosisResult], masked: Bool) -> [ReportBlock] {
        guard !results.isEmpty else {
            return [.note("Aucun diagnostic Wi-Fi retenu\u{00A0}: lancer «\u{00A0}Diagnostiquer\u{00A0}» sur un client, une borne ou un SSID (Wi-Fi › FortiAP), puis «\u{00A0}Ajouter au rapport du site\u{00A0}».")]
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func name(_ r: WifiDiagnosisResult) -> String {
            guard masked, case .client(let mac, let name) = r.subject, name.uppercased() == mac.uppercased() else { return r.subject.name }
            return String(mac.prefix(8)) + ":xx:xx:xx"
        }
        let sorted = results.sorted { ($0.overall, $0.date) > ($1.overall, $1.date) }
        let problems = sorted.filter { $0.overall == .problem }.count
        let watches = sorted.filter { $0.overall == .watch }.count
        var blocks: [ReportBlock] = [
            .paragraph("\(plural(sorted.count, "diagnostic Wi-Fi retenu", "diagnostics Wi-Fi retenus")) pour ce rapport. Chaque cause possible (signal, canal, interférences, charge, client, authentification, DHCP, réseau au-delà du Wi-Fi) a été vérifiée d’après la lecture de la FortiGate, en lecture seule\u{00A0}: rien n’a été modifié."),
            .kpis([ReportKPI("\(sorted.count)", sorted.count > 1 ? "diagnostics" : "diagnostic"),
                   ReportKPI("\(problems)", "avec un problème", tone: problems > 0 ? .critical : .normal),
                   ReportKPI("\(watches)", "à surveiller", tone: watches > 0 ? .warning : .normal),
                   ReportKPI("\(sorted.count - problems - watches)", "sans problème", tone: .normal)]),
        ]
        let rows = sorted.map { r in
            ReportRow([ReportCell(name(r), bold: true), ReportCell(r.subject.kindLabel, tone: .muted), ReportCell(f.string(from: r.date), tone: .muted),
                       ReportCell(r.overall.label, badge: r.overall.reportTone),
                       ReportCell(r.primary.map { $0.title } ?? "—")])
        }
        blocks.append(.table(ReportTable(columns: [ReportColumn("Sujet", weight: 1.4), ReportColumn("Type", weight: 0.6), ReportColumn("Date", weight: 1.1),
                                                   ReportColumn("Verdict", weight: 0.9), ReportColumn("Cause la plus probable", weight: 2.2)],
                                         rows: rows, wraps: true)))
        for r in sorted {
            var text = "\(r.subject.kindLabel) \(name(r))"
            if !r.context.isEmpty { text += " (\(r.context))" }
            text += "\u{00A0}: \(r.headline.prefix(1).lowercased() + r.headline.dropFirst())"
            blocks.append(.paragraph(text))
            let shown = r.causes.filter { $0.verdict >= .watch }
            if !shown.isEmpty {
                let causeRows = shown.map { c in
                    ReportRow([ReportCell(c.verdict.label, badge: c.verdict.reportTone), ReportCell(c.title, bold: true),
                               ReportCell(([c.summary] + c.evidence.prefix(3)).joined(separator: " · "))])
                }
                blocks.append(.table(ReportTable(columns: [ReportColumn("Verdict", weight: 0.8), ReportColumn("Cause", weight: 1.4), ReportColumn("Constat et mesures", weight: 3.8)],
                                                 rows: causeRows, wraps: true)))
            }
            if !r.actions.isEmpty {
                blocks.append(.paragraph("Actions suggérées\u{00A0}: " + r.actions.prefix(6).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")))
            }
            let okCount = r.oks.count
            let unchecked = r.unchecked.map(\.title)
            var note = "\(plural(okCount, "cause vérifiée sans problème", "causes vérifiées sans problème"))"
            if !unchecked.isEmpty { note += "\u{00A0}; non vérifié\u{00A0}: " + unchecked.joined(separator: ", ").lowercased() }
            blocks.append(.note(note + "."))
        }
        return blocks
    }
}
