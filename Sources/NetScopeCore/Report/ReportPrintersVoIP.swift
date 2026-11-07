import Foundation

// Sections facultatives des rapports par site : « Imprimantes et consommables » (note 91) et
// « Qualité VoIP » (note 92). Elles reprennent les relevés déjà faits (fiche de l'imprimante,
// sonde de Surveillance, capture de paquets, test simulé) : rien n'est lu à la création du rapport.

/// Imprimante du site avec son dernier relevé SNMP.
public struct ReportPrinter: Hashable, Sendable {
    public var name: String
    public var ip: String
    public var model: String?
    public var reading: PrinterReading

    public init(name: String, ip: String, model: String? = nil, reading: PrinterReading) {
        self.name = name
        self.ip = ip
        self.model = model
        self.reading = reading
    }
}

extension ReportBuilder {
    static func printerBlocks(_ printers: [ReportPrinter], threshold: Double) -> [ReportBlock] {
        guard !printers.isEmpty else {
            return [.note("Aucune imprimante relevée\u{00A0}: ouvrir la fiche d’une imprimante et cliquer «\u{00A0}Lire les consommables\u{00A0}», ou ajouter une sonde «\u{00A0}Consommable bas\u{00A0}» dans la Surveillance (SNMP, Printer-MIB).")]
        }
        // Tri par niveau le plus bas : ce qu'il faut commander d'abord.
        let sorted = printers.sorted {
            ($0.reading.lowest?.percent ?? 101, $0.name.lowercased()) < ($1.reading.lowest?.percent ?? 101, $1.name.lowercased())
        }
        let low = sorted.filter { !$0.reading.lowSupplies(threshold: threshold).isEmpty }
        let blocked = sorted.filter { !$0.reading.blockingErrors.isEmpty }
        let pages = sorted.compactMap(\.reading.pageCount).reduce(0, +)
        var blocks: [ReportBlock] = [
            .paragraph("\(plural(sorted.count, "imprimante relevée", "imprimantes relevées")) par SNMP (Printer-MIB, lecture seule). Seuil d’alerte\u{00A0}: \(Int(threshold.rounded()))\u{00A0}% restant."),
            .kpis([
                ReportKPI("\(sorted.count)", sorted.count > 1 ? "imprimantes" : "imprimante"),
                ReportKPI("\(low.count)", "avec un consommable bas", tone: low.isEmpty ? .normal : .warning),
                ReportKPI("\(blocked.count)", "bloquée" + (blocked.count > 1 ? "s" : ""), tone: blocked.isEmpty ? .normal : .critical),
                ReportKPI(PrinterMIB.grouped(pages), "pages imprimées (compteurs)"),
            ]),
        ]
        var rows: [ReportRow] = []
        for printer in sorted {
            let supplies = printer.reading.supplies.sorted { ($0.percent ?? 101) < ($1.percent ?? 101) }
            for (index, supply) in supplies.enumerated() {
                let isLow = supply.isLow(threshold: threshold)
                rows.append(ReportRow([
                    ReportCell(index == 0 ? printer.name : "", bold: index == 0),
                    ReportCell(index == 0 ? printer.ip : "", tone: .muted),
                    ReportCell(supply.displayName),
                    ReportCell(supply.levelLabel, tone: isLow ? .warning : .normal, bar: supply.percent.map { $0 / 100 }),
                    ReportCell(index == 0 ? (printer.reading.pageCount.map(PrinterMIB.grouped) ?? "—") : ""),
                    ReportCell(index == 0 ? stateLabel(printer.reading) : "",
                               badge: index == 0 ? stateTone(printer.reading, threshold: threshold) : nil),
                ]))
            }
        }
        blocks.append(.table(ReportTable(columns: [
            ReportColumn("Imprimante", weight: 1.3), ReportColumn("Adresse", weight: 0.9, mono: true),
            ReportColumn("Consommable", weight: 1.3), ReportColumn("Niveau", weight: 1.2),
            ReportColumn("Pages", weight: 0.7, trailing: true), ReportColumn("État", weight: 1),
        ], rows: rows, wraps: true)))
        var advice: [String] = []
        for printer in low {
            let items = printer.reading.lowSupplies(threshold: threshold).map { "\($0.displayName) (\($0.levelLabel))" }
            advice.append("\(printer.name)\u{00A0}: commander \(items.joined(separator: ", ")).")
        }
        for printer in blocked {
            advice.append("\(printer.name)\u{00A0}: \(printer.reading.blockingErrors.map(\.label).joined(separator: ", ").lowercased()).")
        }
        // Alertes publiées par l'imprimante (prtAlertDescription).
        for printer in sorted where !printer.reading.alerts.isEmpty {
            advice.append("\(printer.name), alertes\u{00A0}: \(printer.reading.alerts.prefix(4).joined(separator: "\u{00A0}; ")).")
        }
        if low.isEmpty { advice.insert("Aucun consommable sous le seuil.", at: 0) }
        blocks.append(.paragraph(advice.joined(separator: " ")))
        return blocks
    }

    private static func stateLabel(_ reading: PrinterReading) -> String {
        if let first = reading.blockingErrors.first { return first.label }
        if let first = reading.errors.first { return first.label }
        return reading.state?.label ?? "Prête"
    }

    private static func stateTone(_ reading: PrinterReading, threshold: Double) -> ReportTone {
        if !reading.blockingErrors.isEmpty { return .critical }
        if !reading.lowSupplies(threshold: threshold).isEmpty || !reading.errors.isEmpty { return .warning }
        return .success
    }

    static func voipTone(_ grade: VoIPGrade) -> ReportTone {
        switch grade {
        case .excellent, .good: return .success
        case .fair: return .caution
        case .poor: return .warning
        case .bad: return .critical
        }
    }

    static func voipBlocks(calls: [VoIPCall], tests: [VoIPSyntheticTest]) -> [ReportBlock] {
        guard !calls.isEmpty || !tests.isEmpty else {
            return [.note("Aucune mesure VoIP\u{00A0}: capturer des appels (Boîte à outils › Capture de paquets) ou lancer le test VoIP simulé (Speedtest › Réseau local, iperf3 en UDP).")]
        }
        var blocks: [ReportBlock] = [
            .paragraph("Note MOS de 1 à 5 calculée par le modèle E simplifié (ITU-T G.107) à partir de la gigue, des pertes et du délai, avec le codec. Au-dessus de 4\u{00A0}: bonne qualité\u{00A0}; sous 3,6\u{00A0}: des utilisateurs se plaignent."),
        ]
        if !calls.isEmpty {
            let worst = calls.map(\.worst.mos).min() ?? 0
            let bad = calls.filter { $0.worst.grade <= .poor }.count
            blocks.append(.kpis([
                ReportKPI("\(calls.count)", calls.count > 1 ? "appels captés" : "appel capté"),
                ReportKPI(VoIPQuality.decimal(worst, digits: 2), "note MOS la plus basse", tone: voipTone(VoIPGrade.of(mos: worst))),
                ReportKPI("\(bad)", "appel" + (bad > 1 ? "s" : "") + " médiocre" + (bad > 1 ? "s" : "") + " ou pire", tone: bad > 0 ? .warning : .normal),
            ]))
            var rows: [ReportRow] = []
            for call in calls {
                let directions: [(RTPStreamSummary, VoIPScore)] = [(call.forward, call.forwardScore)]
                    + (call.reverse.map { [($0, call.reverseScore ?? call.forwardScore)] } ?? [])
                for (stream, score) in directions {
                    rows.append(ReportRow([
                        ReportCell(stream.label),
                        ReportCell(stream.codec, tone: .muted),
                        ReportCell(VoIPQuality.decimal(stream.jitter, digits: 1) + "\u{00A0}ms"),
                        ReportCell(VoIPQuality.decimal(stream.lossRatio * 100, digits: 1) + "\u{00A0}%"),
                        ReportCell(score.mosLabel, bold: true),
                        ReportCell(score.grade.label, badge: voipTone(score.grade)),
                    ]))
                }
            }
            blocks.append(.table(ReportTable(columns: [
                ReportColumn("Sens", weight: 2.2, mono: true), ReportColumn("Codec", weight: 1.2),
                ReportColumn("Gigue", weight: 0.7, trailing: true), ReportColumn("Pertes", weight: 0.7, trailing: true),
                ReportColumn("MOS", weight: 0.6, trailing: true), ReportColumn("Qualité", weight: 0.9),
            ], rows: rows, wraps: true)))
            blocks.append(.note("Le délai dans un sens ne se mesure pas depuis un seul point de capture\u{00A0}: il compte pour 0, seuls la mémoire tampon de gigue et le codec s’ajoutent."))
        }
        if !tests.isEmpty {
            let rows = tests.map { test in
                ReportRow([
                    ReportCell(test.target, bold: true),
                    ReportCell("\(test.codec) × \(test.calls)", tone: .muted),
                    ReportCell(VoIPQuality.decimal(test.jitterMs, digits: 1) + "\u{00A0}ms"),
                    ReportCell(VoIPQuality.decimal(test.lossPercent, digits: 2) + "\u{00A0}%"),
                    ReportCell(test.score.mosLabel, bold: true),
                    ReportCell(test.score.grade.label, badge: voipTone(test.score.grade)),
                ])
            }
            blocks.append(.paragraph("Test simulé (iperf3 en UDP au débit des appels, sans appel réel)\u{00A0}: note attendue d’un lien avant d’installer des téléphones."))
            blocks.append(.table(ReportTable(columns: [
                ReportColumn("Serveur", weight: 1.6, mono: true), ReportColumn("Codec", weight: 1),
                ReportColumn("Gigue", weight: 0.7, trailing: true), ReportColumn("Pertes", weight: 0.7, trailing: true),
                ReportColumn("MOS", weight: 0.6, trailing: true), ReportColumn("Qualité", weight: 0.9),
            ], rows: rows)))
        }
        return blocks
    }
}
