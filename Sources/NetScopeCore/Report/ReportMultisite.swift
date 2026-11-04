import Foundation

// Rapport multisite (demande de Dany, 0.12.0) : plusieurs sites choisis dans les Rapports donnent
// UN document, avec une section par site et par partie (« Siège — 1. Résumé », « Entrepôt Laval —
// 1. Résumé »…), précédé d'un tableau des sites. Chaque site est bâti avec SES appareils et SON
// inventaire : rien n'est fusionné entre deux sites, même à adresse IP égale.

/// Données d'un site pour le rapport multisite.
public struct ReportSiteInput: Sendable {
    public var name: String
    public var input: ReportInput

    public init(name: String, input: ReportInput) {
        self.name = name
        self.input = input
    }
}

public extension ReportBuilder {
    /// Un seul site : le rapport ordinaire. Plusieurs : le tableau des sites, puis les sections de
    /// chaque site, dans l'ordre donné ; les problèmes portent le nom de leur site.
    static func buildMultisite(config: ReportConfig, sites: [ReportSiteInput], generator: String = "NetScope") -> ReportDocument {
        guard sites.count > 1 else {
            var single = config
            if let site = sites.first, single.site.reportTrimmed.isEmpty { single.site = site.name }
            return build(config: single, input: sites.first?.input ?? ReportInput(devices: []), generator: generator)
        }
        var sections: [ReportSection] = []
        var problems: [ReportProblem] = []
        var rows: [ReportRow] = []
        for site in sites {
            var siteConfig = config
            siteConfig.site = site.name
            let document = build(config: siteConfig, input: site.input, generator: generator)
            for section in document.sections {
                var copy = section
                copy.site = site.name
                copy.heading = "\(site.name) — \(section.heading)"
                sections.append(copy)
            }
            problems += document.problems.map { problem in
                var copy = problem
                copy.title = "\(site.name) — \(problem.title)"
                return copy
            }
            let devices = site.input.devices
            let critical = document.problems.filter { $0.severity == .critique }.count
            rows.append(ReportRow([
                ReportCell(site.name, bold: true),
                ReportCell("\(devices.count)"),
                ReportCell("\(devices.filter(\.isOnline).count)"),
                ReportCell("\(site.input.records.count)"),
                ReportCell("\(document.problems.count)", badge: critical > 0 ? .critical : nil),
                ReportCell(site.input.scanDate.map { ReportText.isoDay($0) } ?? "aucun scan", tone: site.input.scanDate == nil ? .muted : .normal),
            ]))
        }
        let names = sites.map(\.name)
        let intro = "Rapport multisite\u{00A0}: \(names.count) sites (" + names.joined(separator: ", ")
            + "). Chaque site a sa propre section, bâtie avec ses appareils et son inventaire\u{00A0}; deux sites ne sont jamais fusionnés, même à adresse IP égale."
        let table = ReportTable(columns: [ReportColumn("Site", weight: 2.4), ReportColumn("Appareils", trailing: true),
                                          ReportColumn("En ligne", trailing: true), ReportColumn("Fiches", trailing: true),
                                          ReportColumn("Problèmes", trailing: true), ReportColumn("Dernier scan", weight: 1.4, mono: true)],
                                rows: rows)
        sections.insert(ReportSection(kind: .resume, heading: "Sites du rapport", blocks: [.paragraph(intro), .table(table)]), at: 0)
        // Titre : « Rapport d'audit réseau — Siège, Entrepôt Laval » ; au-delà de deux sites,
        // « … — 5 sites » (la liste complète est dans « Sites du rapport »).
        var titled = config
        titled.site = names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) sites"
        return ReportDocument(title: titled.documentTitle, template: config.template, client: config.client.reportTrimmed,
                              site: names.joined(separator: ", "), technician: config.technician.reportTrimmed, date: config.date,
                              dateLabel: config.dateLabel, reference: config.reference, generator: generator,
                              signature: config.signature, sections: sections, problems: problems)
    }
}
