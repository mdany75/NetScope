import Foundation

// Section facultative « Vitesse des disques » des rapports : dernier test de chaque emplacement
// (disques, partages réseau, dossiers nuage), avec le bilan en clair.

extension DiskVerdict.Tone {
    var reportTone: ReportTone {
        switch self {
        case .success: return .success
        case .accent, .neutral: return .neutral
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

extension DiskLimit {
    var reportTone: ReportTone {
        switch self {
        case .disque, .inconnu: return .neutral
        case .serveur, .internet: return .caution
        case .reseau, .latence, .service: return .warning
        }
    }
}

extension ReportBuilder {
    static func diskBlocks(_ records: [DiskTestRecord]) -> [ReportBlock] {
        guard !records.isEmpty else {
            return [.note("Aucun test de vitesse des disques\u{00A0}: lancer l’outil Vitesse des disques de la Boîte à outils, puis l’ajouter au rapport.")]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let kinds = Set(records.map(\.kind))
        var text = "\(plural(records.count, "emplacement mesuré", "emplacements mesurés")) depuis le poste du technicien"
        let names = DiskLocationKind.allCases.filter { kinds.contains($0) }.map { $0.label.lowercased() }
        if !names.isEmpty { text += " (" + names.joined(separator: ", ") + ")" }
        text += ". Débits séquentiels par blocs de 1\u{00A0}Mio, cache du système contourné."
        var blocks: [ReportBlock] = [.paragraph(text)]

        let fastest = records.compactMap { record in record.readMBps.map { (record, $0) } }.max { $0.1 < $1.1 }
        let network = records.filter { $0.kind == .reseau }
        let cloud = records.filter { $0.kind == .nuage }
        var kpis = [ReportKPI("\(records.count)", records.count > 1 ? "emplacements" : "emplacement")]
        if let fastest { kpis.append(ReportKPI(DiskFormat.rateWithUnit(fastest.1), "meilleure lecture (\(fastest.0.locationName))")) }
        if let share = network.first, let best = [share.writeMBps, share.readMBps].compactMap({ $0 }).max() {
            kpis.append(ReportKPI(DiskFormat.bits(DiskMath.megabits(fromMegabytes: best)), "partage \(share.locationName)",
                                  tone: share.limit.reportTone))
        }
        if let first = cloud.first {
            let value = first.uploadSeconds.map(DiskFormat.duration) ?? (first.cloudStatus?.label ?? "—")
            kpis.append(ReportKPI(value, "jusqu’à «\u{00A0}envoyé\u{00A0}» (\(first.locationName))", tone: first.limit.reportTone))
        }
        blocks.append(.kpis(kpis))

        let rows = records.map { record -> ReportRow in
            let random = record.randomReadIOPS.map { DiskFormat.iops($0) } ?? "—"
            let latency = record.randomReadP95Ms.map(DiskFormat.latency) ?? "—"
            return ReportRow([
                ReportCell(record.locationName, bold: true),
                ReportCell(record.kind.label + (record.detail.isEmpty ? "" : " · " + record.detail), tone: .muted),
                ReportCell(record.writeMBps.map(DiskFormat.rateWithUnit) ?? "—"),
                ReportCell(record.kind == .nuage ? (record.uploadSeconds.map { "envoi " + DiskFormat.duration($0) } ?? (record.cloudStatus?.label ?? "—"))
                                                 : (record.readMBps.map(DiskFormat.rateWithUnit) ?? "—")),
                ReportCell(random),
                ReportCell(latency),
                ReportCell(record.limit.label, badge: record.limit.reportTone),
            ])
        }
        blocks.append(.table(ReportTable(columns: [ReportColumn("Emplacement", weight: 1.5), ReportColumn("Type", weight: 1.8),
                                                   ReportColumn("Écriture", weight: 1, trailing: true),
                                                   ReportColumn("Lecture", weight: 1, trailing: true),
                                                   ReportColumn("IOPS 4\u{00A0}Kio", weight: 0.9, trailing: true),
                                                   ReportColumn("p95 4\u{00A0}Kio", weight: 0.9, trailing: true),
                                                   ReportColumn("Limite", weight: 1)],
                                         rows: rows, wraps: true)))
        let verdicts = records.map { record in
            ReportRow([ReportCell(record.locationName, bold: true), ReportCell(formatter.string(from: record.date), tone: .muted),
                       ReportCell(record.verdict)])
        }
        blocks.append(.table(ReportTable(columns: [ReportColumn("Emplacement", weight: 1.4), ReportColumn("Date", weight: 1.2),
                                                   ReportColumn("Bilan", weight: 4)],
                                         rows: verdicts, wraps: true)))
        blocks.append(.note("Fichier d’essai écrit dans un dossier «\u{00A0}NetScope-test\u{00A0}» puis supprimé. Dossiers nuage\u{00A0}: écriture dans la copie locale, puis temps jusqu’à «\u{00A0}envoyé\u{00A0}» quand le service le signale."))
        return blocks
    }
}
