import Foundation

// Section « Santé courriel » des rapports : pour chaque domaine vérifié dans la Boîte à outils,
// la note, le tableau des vérifications et les recommandations.

extension MailStatus {
    var reportTone: ReportTone {
        switch self {
        case .ok: return .success
        case .info: return .neutral
        case .warning: return .warning
        case .error: return .critical
        }
    }
}

extension ReportBuilder {
    static func mailHealthBlocks(_ summaries: [MailHealthSummary]) -> [ReportBlock] {
        guard !summaries.isEmpty else {
            return [.note("Aucun bilan de santé courriel\u{00A0}: lancer l’outil Santé courriel de la Boîte à outils, puis l’ajouter au rapport.")]
        }
        var blocks: [ReportBlock] = []
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "fr_CA")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        for summary in summaries {
            let errors = summary.count(.error), warnings = summary.count(.warning)
            var text = "Domaine \(summary.domain), vérifié le \(dateFormatter.string(from: summary.date))\u{00A0}: note \(summary.score)/100 (\(summary.grade.label.lowercased()))."
            if errors + warnings == 0 {
                text += " Aucun point bloquant."
            } else {
                text += " " + [errors > 0 ? plural(errors, "erreur", "erreurs") : nil,
                               warnings > 0 ? plural(warnings, "avertissement", "avertissements") : nil]
                    .compactMap { $0 }.joined(separator: " et ") + "."
            }
            blocks.append(.paragraph(text))
            let spf = summary.checks.first { $0.category == .spf }
            let dmarc = summary.checks.first { $0.category == .dmarc }
            let lists = summary.checks.first { $0.category == .blacklist }
            blocks.append(.kpis([
                ReportKPI("\(summary.score)/100", "note de santé", tone: summary.grade.status.reportTone),
                ReportKPI(spf?.result.components(separatedBy: " · ").first ?? "—", "SPF", tone: spf?.status.reportTone ?? .normal),
                ReportKPI(dmarc?.result.components(separatedBy: " · ").first ?? "—", "DMARC", tone: dmarc?.status.reportTone ?? .normal),
                ReportKPI(lists.map { $0.status == .ok ? "Aucune" : ($0.status == .info ? "—" : "Inscrit") } ?? "—", "listes noires",
                          tone: lists?.status.reportTone ?? .normal),
            ]))
            let rows = summary.checks.map { check in
                ReportRow([ReportCell(check.title, bold: true),
                           ReportCell(check.status.label, badge: check.status.reportTone),
                           ReportCell(check.result),
                           ReportCell(check.pointsLabel, tone: .muted)])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Vérification", weight: 1.1), ReportColumn("État", weight: 1.1),
                                                       ReportColumn("Résultat", weight: 3.4), ReportColumn("Points", weight: 0.8, trailing: true)],
                                             rows: rows, wraps: true)))
            if !summary.recommendations.isEmpty {
                let recs = summary.recommendations.prefix(10).map { finding in
                    ReportRow([ReportCell(finding.status.label, badge: finding.status.reportTone),
                               ReportCell(finding.title, bold: true),
                               ReportCell(finding.fix ?? "")])
                }
                blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 1.1), ReportColumn("Constat", weight: 2.2),
                                                           ReportColumn("Recommandation", weight: 3.6)],
                                                 rows: recs, wraps: true)))
            }
        }
        blocks.append(.note("Vérifications DNS faites depuis le poste du technicien\u{00A0}; sélecteurs DKIM courants seulement (un sélecteur propre au domaine peut exister)."))
        return blocks
    }
}
