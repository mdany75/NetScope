import Foundation

// Note 98 : section facultative « Onduleurs » des rapports par site. Elle reprend les relevés déjà
// faits (fiche de l'onduleur, sonde de Surveillance) : rien n'est lu à la création du rapport.

/// Onduleur du site avec son dernier relevé SNMP.
public struct ReportUPS: Hashable, Sendable {
    public var name: String
    public var ip: String
    public var reading: UPSReading

    public init(name: String, ip: String, reading: UPSReading) {
        self.name = name
        self.ip = ip
        self.reading = reading
    }
}

extension ReportBuilder {
    static func upsBlocks(_ units: [ReportUPS], minRuntime: Double, now: Date) -> [ReportBlock] {
        guard !units.isEmpty else {
            return [.note("Aucun onduleur relevé\u{00A0}: ouvrir la fiche d’un onduleur et cliquer «\u{00A0}Lire l’onduleur\u{00A0}», ou ajouter une sonde «\u{00A0}Onduleur (UPS)\u{00A0}» dans la Surveillance (SNMP, UPS-MIB).")]
        }
        // Les plus urgents d'abord : sur batterie, puis l'autonomie la plus courte.
        let sorted = units.sorted {
            ($0.reading.onBattery ? 0 : 1, $0.reading.runtimeMinutes ?? .infinity, $0.name.lowercased())
                < ($1.reading.onBattery ? 0 : 1, $1.reading.runtimeMinutes ?? .infinity, $1.name.lowercased())
        }
        let onBattery = sorted.filter(\.reading.onBattery)
        let shortRuntime = sorted.filter { ($0.reading.runtimeMinutes ?? .infinity) < minRuntime }
        let due = sorted.filter { $0.reading.batteryDue(now: now) }
        var blocks: [ReportBlock] = [
            .paragraph("\(plural(sorted.count, "onduleur relevé", "onduleurs relevés")) par SNMP (UPS-MIB et MIB du fabricant, lecture seule). Seuil d’autonomie\u{00A0}: \(UPSMIB.minutes(minRuntime))."),
            .kpis([
                ReportKPI("\(sorted.count)", sorted.count > 1 ? "onduleurs" : "onduleur"),
                ReportKPI("\(onBattery.count)", "sur batterie", tone: onBattery.isEmpty ? .normal : .critical),
                ReportKPI("\(shortRuntime.count)", "autonomie basse", tone: shortRuntime.isEmpty ? .normal : .warning),
                ReportKPI("\(due.count)", "batterie" + (due.count > 1 ? "s" : "") + " à changer", tone: due.isEmpty ? .normal : .warning),
            ]),
        ]
        let rows = sorted.map { unit -> ReportRow in
            let reading = unit.reading
            let dueReason = reading.batteryDueReason(now: now)
            let tone: ReportTone = reading.onBattery || reading.source == .off ? .critical
                : (dueReason != nil || (reading.runtimeMinutes ?? .infinity) < minRuntime) ? .warning : .success
            return ReportRow([
                ReportCell(unit.name, bold: true),
                ReportCell(unit.ip, tone: .muted),
                ReportCell(reading.source.label, badge: tone),
                ReportCell(reading.chargePercent.map(UPSMIB.percent) ?? "—", bar: reading.chargePercent.map { $0 / 100 }),
                ReportCell(reading.runtimeMinutes.map(UPSMIB.minutes) ?? "—",
                           tone: (reading.runtimeMinutes ?? .infinity) < minRuntime ? .warning : .normal),
                ReportCell(reading.loadPercent.map(UPSMIB.percent) ?? "—"),
                ReportCell(reading.batteryReplacedDate.map(UPSMIB.dateLabel) ?? "—", tone: dueReason != nil ? .warning : .normal),
            ])
        }
        blocks.append(.table(ReportTable(columns: [
            ReportColumn("Onduleur", weight: 1.3), ReportColumn("Adresse", weight: 0.9, mono: true),
            ReportColumn("Alimentation", weight: 1.1), ReportColumn("Batterie", weight: 1),
            ReportColumn("Autonomie", weight: 0.8, trailing: true), ReportColumn("Charge", weight: 0.7, trailing: true),
            ReportColumn("Batterie posée", weight: 1),
        ], rows: rows, wraps: true)))
        var advice: [String] = []
        for unit in onBattery { advice.append("\(unit.name)\u{00A0}: sur batterie au moment du relevé, vérifier l’alimentation secteur.") }
        for unit in shortRuntime where !unit.reading.onBattery {
            advice.append("\(unit.name)\u{00A0}: autonomie de \(unit.reading.runtimeMinutes.map(UPSMIB.minutes) ?? "—"), sous le seuil (réduire la charge ou ajouter une batterie).")
        }
        for unit in due {
            advice.append("\(unit.name)\u{00A0}: batterie à changer (\(unit.reading.batteryDueReason(now: now) ?? "")).")
        }
        if advice.isEmpty { advice.append("Tous les onduleurs relevés sont sur secteur, avec une autonomie suffisante et une batterie en bon état.") }
        blocks.append(.paragraph(advice.joined(separator: " ")))
        return blocks
    }
}
