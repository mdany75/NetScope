import Foundation

// Section facultative « Bilan de raccordement » des rapports (note 58) : bilans retenus par
// « Ajouter au rapport », chacun avec ses étapes et, s'il y en a un, la comparaison avec le bilan
// « avant ». Le même contenu sert à l'export PDF d'un seul bilan (document d'une section).

/// Un bilan retenu pour le rapport, avec le bilan de comparaison (avant/après) s'il existe.
public struct LinkCheckReportEntry: Hashable, Sendable {
    public var result: LinkCheckResult
    public var before: LinkCheckResult?

    public init(result: LinkCheckResult, before: LinkCheckResult? = nil) {
        self.result = result
        self.before = before
    }
}

extension LinkCheckStatus {
    var reportTone: ReportTone {
        switch self {
        case .ok: return .success
        case .warning: return .warning
        case .failure: return .critical
        case .skipped: return .neutral
        }
    }
}

extension LinkCheckDifference.Change {
    var reportTone: ReportTone {
        switch self {
        case .improved: return .success
        case .degraded: return .critical
        case .changed, .added, .removed: return .caution
        case .same: return .muted
        }
    }
}

extension ReportBuilder {
    static func linkCheckBlocks(_ entries: [LinkCheckReportEntry], masked: Bool) -> [ReportBlock] {
        guard !entries.isEmpty else {
            return [.note("Aucun bilan de raccordement retenu\u{00A0}: lancer le bilan dans Outils › Bilan de raccordement, puis «\u{00A0}Ajouter au rapport\u{00A0}».")]
        }
        func clean(_ text: String) -> String { masked ? maskMACs(text) : text }
        let sorted = entries.sorted { $0.result.date > $1.result.date }
        let failures = sorted.filter { $0.result.overall == .failure }.count
        let warnings = sorted.filter { $0.result.overall == .warning }.count
        var blocks: [ReportBlock] = [
            .paragraph("\(plural(sorted.count, "bilan de raccordement retenu", "bilans de raccordement retenus")). Chaque bilan vérifie depuis la prise\u{00A0}: le lien (vitesse, duplex), le switch et le port annoncés par LLDP ou CDP, le VLAN, le PoE, le DHCP (sans prendre de bail), la passerelle, le DNS et l’accès Internet."),
            .kpis([ReportKPI("\(sorted.count)", sorted.count > 1 ? "bilans" : "bilan"),
                   ReportKPI("\(sorted.count - failures - warnings)", "conformes", tone: .normal),
                   ReportKPI("\(warnings)", "avec avertissement", tone: warnings > 0 ? .warning : .normal),
                   ReportKPI("\(failures)", "en échec", tone: failures > 0 ? .critical : .normal)]),
        ]
        if sorted.count > 1 {
            let rows = sorted.map { e in
                ReportRow([ReportCell(e.result.location.isEmpty ? e.result.interfaceName : e.result.location, bold: true),
                           ReportCell(LinkCheckText.dateLabel(e.result.date), tone: .muted),
                           ReportCell(e.result.overall.label, badge: e.result.overall.reportTone),
                           ReportCell(clean(e.result.oneLine))])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Emplacement", weight: 1.3), ReportColumn("Date", weight: 1),
                                                       ReportColumn("Verdict", weight: 0.9), ReportColumn("Switch, port, VLAN, vitesse", weight: 2.6)],
                                             rows: rows, wraps: true)))
        }
        for entry in sorted { blocks += linkCheckDetail(entry, masked: masked) }
        return blocks
    }

    /// Détail d'un bilan : titre, étapes, comparaison avant/après.
    static func linkCheckDetail(_ entry: LinkCheckReportEntry, masked: Bool) -> [ReportBlock] {
        func clean(_ text: String) -> String { masked ? maskMACs(text) : text }
        let r = entry.result
        var title = r.location.isEmpty ? "Prise de \(r.interfaceName)" : r.location
        title += " — \(LinkCheckText.dateLabel(r.date)) · \(r.interfaceName)" + (r.interfaceKind.isEmpty ? "" : " (\(r.interfaceKind))")
        var blocks: [ReportBlock] = [.paragraph(clean(title + "\u{00A0}: " + r.headline.prefix(1).lowercased() + r.headline.dropFirst() + " (" + r.countsLabel + ")."))]
        var rows = r.steps.map { s in
            ReportRow([ReportCell(s.kind.title, bold: true), ReportCell(s.status.label, badge: s.status.reportTone),
                       ReportCell(clean(s.summary)), ReportCell(clean(s.explanation), tone: .muted)])
        }
        // Note 89 : test de câble (TDR) du port, demandé au switch.
        if let cable = r.cableTest {
            rows.append(ReportRow([ReportCell("Test de câble", bold: true), ReportCell(cable.status.label, badge: cable.status.reportTone),
                                   ReportCell(cable.headline),
                                   ReportCell("\(cable.portLabel) · \(LinkCheckText.dateLabel(cable.date)) · " + cable.pairs.map(\.summary).joined(separator: ", "), tone: .muted)]))
        }
        blocks.append(.table(ReportTable(columns: [ReportColumn("Étape", weight: 0.9), ReportColumn("État", weight: 0.9),
                                                   ReportColumn("Résultat", weight: 1.6), ReportColumn("Explication", weight: 3.2)],
                                         rows: rows, wraps: true)))
        if let before = entry.before {
            let diffs = LinkCheckComparison.compare(before, r).filter(\.change.isDifference)
            blocks.append(.paragraph("Comparaison avec le bilan «\u{00A0}avant\u{00A0}» du \(LinkCheckText.dateLabel(before.date))\u{00A0}: "
                                     + LinkCheckComparison.summary(diffs).lowercased() + "."))
            if !diffs.isEmpty {
                let diffRows = diffs.map { d in
                    ReportRow([ReportCell(d.step.title, bold: true), ReportCell(d.label), ReportCell(clean(d.before ?? "—"), tone: .muted),
                               ReportCell(clean(d.after ?? "—")), ReportCell(d.change.label, badge: d.change.reportTone)])
                }
                blocks.append(.table(ReportTable(columns: [ReportColumn("Étape", weight: 0.9), ReportColumn("Élément", weight: 1.2),
                                                           ReportColumn("Avant", weight: 1.6), ReportColumn("Après", weight: 1.6),
                                                           ReportColumn("Écart", weight: 0.9)],
                                                 rows: diffRows, wraps: true)))
            }
        }
        return blocks
    }

    /// Document d'un seul bilan (export PDF depuis l'outil).
    public static func linkCheckDocument(_ entry: LinkCheckReportEntry, client: String, technician: String, masked: Bool = false,
                                         generator: String = "NetScope") -> ReportDocument {
        let r = entry.result
        let day = ReportText.isoDay(r.date)
        let site = r.siteName.reportTrimmed
        let blocks = linkCheckDetail(entry, masked: masked)
        let section = ReportSection(kind: .raccordement, heading: "Bilan de raccordement", blocks: blocks)
        let problems = r.steps.filter { $0.status == .failure || $0.status == .warning }.map { s in
            ReportProblem(title: "\(s.kind.title)\u{00A0}: \(s.summary)", severity: s.status == .failure ? .eleve : .moyen,
                          recommendation: s.explanation)
        }
        return ReportDocument(title: "Bilan de raccordement — " + (r.location.isEmpty ? (site.isEmpty ? r.interfaceName : site) : r.location),
                              template: .intervention, client: client.reportTrimmed, site: site, technician: technician.reportTrimmed,
                              date: day, dateLabel: ReportText.longDate(day) ?? day,
                              reference: "BIL-" + day.replacingOccurrences(of: "-", with: "") + "-" + String(r.id.uuidString.prefix(4)),
                              generator: generator, signature: false, sections: [section], problems: problems)
    }
}
