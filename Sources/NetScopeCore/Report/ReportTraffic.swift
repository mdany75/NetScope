import Foundation

// Section facultative « Trafic et analyse » des rapports (note 54) : charge des liens WAN, plus
// gros consommateurs, applications, menaces, puis les points de l'analyse complète du réseau
// classés par gravité, avec l'action conseillée.

extension NetworkFindingSeverity {
    var reportTone: ReportTone {
        switch self {
        case .critical: return .critical
        case .warning: return .warning
        case .advice: return .caution
        case .ok: return .success
        }
    }
}

extension ReportBuilder {
    static func trafficBlocks(_ traffic: TrafficOverview?, analysis: NetworkAnalysisResult?, masked: Bool) -> [ReportBlock] {
        func clean(_ text: String) -> String { masked ? maskMACs(text) : text }
        guard let traffic, !traffic.isEmpty else {
            var blocks: [ReportBlock] = [.note("Aucun trafic lu\u{00A0}: configurer la FortiGate du site dans Réglages › Switchs (droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture), puis ouvrir l’écran Trafic.")]
            if let analysis { blocks += analysisBlocks(analysis, clean: clean) }
            return blocks
        }
        let multi = traffic.isMultiSite
        var text = "Trafic lu par FortiView sur "
        text += traffic.sites.count > 1 ? "les FortiGate des sites " + traffic.sites.joined(separator: ", ") : "la FortiGate du site " + (traffic.sites.first ?? "")
        text += ", \(traffic.period.span), par l’API REST en lecture seule"
        if let date = traffic.readAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_CA")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            text += " le \(f.string(from: date))"
        }
        text += "."
        var blocks: [ReportBlock] = [.paragraph(text)]

        let usages = TrafficAnalysis.linkUsage(traffic)
        let threats = TrafficAnalysis.threats(traffic)
        let blocked = threats.filter(\.isBlocked).count
        let unexpected = TrafficAnalysis.unexpectedApplications(traffic)
        let worst = usages.first
        blocks.append(.kpis([
            ReportKPI(worst?.percent.map(ResourceFormat.percent) ?? "—", "charge du lien le plus chargé",
                      tone: worst?.level == .critical ? .critical : (worst?.level == .warning ? .warning : .normal)),
            ReportKPI("\(traffic.entries(.sources).count)", "appareils actifs"),
            ReportKPI("\(unexpected.count)", unexpected.count > 1 ? "applications inattendues" : "application inattendue",
                      tone: unexpected.isEmpty ? .normal : .warning),
            ReportKPI("\(threats.count)", "menace" + (threats.count > 1 ? "s" : "") + (threats.isEmpty ? "" : ", \(blocked) bloquée\(blocked > 1 ? "s" : "")"),
                      tone: threats.contains { !$0.isBlocked } ? .critical : (threats.isEmpty ? .normal : .warning)),
        ]))

        if !usages.isEmpty {
            let rows = usages.map { usage -> ReportRow in
                var cells = [ReportCell(usage.link.label, bold: true)]
                if multi { cells.append(ReportCell(usage.link.site, tone: .muted)) }
                let tone: ReportTone = usage.level == .critical ? .critical : (usage.level == .warning ? .warning : .normal)
                cells += [ReportCell(TrafficFormat.rate(usage.link.rxBps)), ReportCell(TrafficFormat.rate(usage.link.txBps)),
                          ReportCell(usage.percent.map(ResourceFormat.percent) ?? "capacité inconnue", tone: usage.percent == nil ? .muted : tone,
                                     bar: usage.percent.map { min($0, 100) / 100 })]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Lien WAN", weight: 1.4)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Réception", weight: 0.9, trailing: true), ReportColumn("Émission", weight: 0.9, trailing: true),
                        ReportColumn("Charge", weight: 1.3)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows)))
        }

        let consumers = TrafficAnalysis.consumers(traffic, limit: 8)
        if !consumers.isEmpty {
            let rows = consumers.map { c -> ReportRow in
                var cells = [ReportCell(clean(c.entry.name), bold: true), ReportCell(c.entry.ip?.description ?? "—")]
                if multi { cells.append(ReportCell(c.entry.site, tone: .muted)) }
                cells += [ReportCell(traffic.period.isRealtime ? TrafficFormat.rate(c.entry.bandwidth) : TrafficFormat.bytes(c.entry.bytes)),
                          ReportCell(ResourceFormat.percent(c.sharePercent), bar: c.sharePercent / 100),
                          ReportCell(c.mainApplication ?? "—", tone: c.mainApplication == nil ? .muted : .normal)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Appareil", weight: 1.5), ReportColumn("Adresse", weight: 1, mono: true)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn(traffic.period.isRealtime ? "Débit" : "Volume", weight: 0.9, trailing: true),
                        ReportColumn("Part", weight: 1.1), ReportColumn("Application", weight: 1.2)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        let apps = TrafficAnalysis.sorted(traffic.entries(.applications), by: .bytes).prefix(8)
        if !apps.isEmpty {
            let total = Double(apps.reduce(UInt64(0)) { $0 &+ $1.bytes })
            let rows = apps.map { app -> ReportRow in
                let fraction = total > 0 ? Double(app.bytes) / total : 0
                var cells = [ReportCell(app.name, bold: true)]
                if multi { cells.append(ReportCell(app.site, tone: .muted)) }
                let risk = app.risk ?? 0
                cells += [ReportCell(app.category ?? "—", tone: .muted),
                          ReportCell(app.risk.map { TrafficFormat.risk($0) } ?? "—", tone: risk >= 4 ? .critical : (risk == 3 ? .warning : .normal)),
                          ReportCell(TrafficFormat.bytes(app.bytes)),
                          ReportCell(ResourceFormat.percent(fraction * 100), bar: fraction)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Application", weight: 1.5)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Catégorie", weight: 1.1), ReportColumn("Risque", weight: 1), ReportColumn("Volume", weight: 0.8, trailing: true),
                        ReportColumn("Part", weight: 1.1)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        if !threats.isEmpty {
            let rows = threats.prefix(10).map { t -> ReportRow in
                var cells = [ReportCell(t.name, bold: true), ReportCell(t.threatType ?? "—"),
                             ReportCell((t.threatLevel ?? .info).label, badge: (t.threatLevel ?? .info) <= .high ? .critical : .warning)]
                if multi { cells.append(ReportCell(t.site, tone: .muted)) }
                cells += [ReportCell(t.ip.map { ip in clean(t.hostname.map { "\($0) (\(ip))" } ?? ip.description) } ?? "—"),
                          ReportCell("\(t.incidents)"),
                          ReportCell(t.isBlocked ? "Bloquée" : "Non bloquée", badge: t.isBlocked ? .success : .critical)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Menace", weight: 1.6), ReportColumn("Type", weight: 0.9), ReportColumn("Niveau", weight: 0.8)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Appareil", weight: 1.5), ReportColumn("Événements", weight: 0.8, trailing: true),
                        ReportColumn("Action", weight: 0.9)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        if let analysis { blocks += analysisBlocks(analysis, clean: clean) }
        return blocks
    }

    /// Points de l'analyse complète, classés par gravité.
    static func analysisBlocks(_ analysis: NetworkAnalysisResult, clean: (String) -> String) -> [ReportBlock] {
        var blocks: [ReportBlock] = [.paragraph("Bilan de santé du réseau\u{00A0}: \(analysis.grade.lowercased()) (note \(analysis.score)/100) — \(analysis.summary)")]
        let rows = analysis.findings.filter { $0.severity != .ok }.map { f in
            ReportRow([ReportCell(f.severity.label, badge: f.severity.reportTone), ReportCell(f.area.label, tone: .muted),
                       ReportCell(clean(f.title), bold: true), ReportCell(clean(f.explanation)), ReportCell(f.action)])
        }
        if !rows.isEmpty {
            blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 0.7), ReportColumn("Domaine", weight: 0.7),
                                                       ReportColumn("Constat", weight: 1.5), ReportColumn("Explication", weight: 2.4),
                                                       ReportColumn("Action conseillée", weight: 2)],
                                             rows: rows, wraps: true)))
        }
        let missing = analysis.coverage.filter { !$0.analyzed }
        if !missing.isEmpty {
            blocks.append(.note("Non analysé\u{00A0}: " + missing.map { "\($0.part) (\($0.detail.trimmingCharacters(in: CharacterSet(charactersIn: "."))))" }.joined(separator: "\u{00A0}; ") + "."))
        }
        return blocks
    }
}
