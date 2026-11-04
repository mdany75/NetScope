import Foundation

// Section facultative « Étendues DHCP » des rapports (note 37) : occupation de chaque étendue lue
// sur la FortiGate (ou estimée sans elle), étendues presque pleines et conseils.

extension DHCPScopeLevel {
    var reportTone: ReportTone {
        switch self {
        case .critical: return .critical
        case .warning: return .warning
        case .ok: return .success
        case .inactive: return .neutral
        }
    }
}

extension ReportBuilder {
    static func dhcpScopeBlocks(_ overview: DHCPScopeOverview?, thresholds: DHCPScopeThresholds) -> [ReportBlock] {
        guard let overview, !overview.scopes.isEmpty else {
            return [.note("Aucune étendue DHCP lue\u{00A0}: configurer la FortiGate du site dans Réglages › Switchs, puis ouvrir l’outil «\u{00A0}Étendues DHCP\u{00A0}» de la Boîte à outils (ou lancer un Test DHCP pour une estimation).")]
        }
        let scopes = DHCPScopeAnalysis.relevel(overview.scopes, thresholds: thresholds)
        let active = scopes.filter { $0.level != .inactive }
        let alerting = active.filter { $0.level >= .warning }.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
        let sites = overview.sites.filter { !$0.isEmpty }
        var text: String
        if overview.isEstimate {
            text = "Estimation sans FortiGate\u{00A0}: \(plural(scopes.count, "sous-réseau offert", "sous-réseaux offerts")) par le Test DHCP, adresses utilisées comptées d’après les appareils vus en ligne par le scan. Les plages réelles ne sont pas connues\u{00A0}: les taux sont indicatifs."
        } else {
            text = "\(plural(scopes.count, "étendue DHCP", "étendues DHCP")) "
            text += sites.isEmpty ? "lue\(scopes.count > 1 ? "s" : "") sur la FortiGate" : (sites.count > 1 ? "des FortiGate des sites " + sites.joined(separator: ", ") : "de la FortiGate du site " + sites[0])
            text += ", par l’API REST en lecture seule"
            if let date = overview.readAt {
                let f = DateFormatter()
                f.locale = Locale(identifier: "fr_CA")
                f.dateFormat = "yyyy-MM-dd HH:mm"
                text += " le \(f.string(from: date))"
            }
            text += ". Une adresse réservée compte comme utilisée, qu’elle ait un bail ou non."
        }
        var blocks: [ReportBlock] = [.paragraph(text)]
        let pool = active.reduce(0) { $0 + $1.poolSize }
        let used = active.reduce(0) { $0 + $1.used }
        let critical = alerting.filter { $0.level == .critical }.count
        blocks.append(.kpis([
            ReportKPI("\(active.count)", active.count > 1 ? "étendues actives" : "étendue active"),
            ReportKPI("\(used) / \(pool)", "adresses utilisées"),
            ReportKPI("\(max(0, pool - used))", "adresses libres"),
            ReportKPI("\(alerting.count)", "presque pleine" + (alerting.count > 1 ? "s" : "") + (critical > 0 ? ", dont \(critical) critique" + (critical > 1 ? "s" : "") : ""),
                      tone: critical > 0 ? .critical : (alerting.isEmpty ? .normal : .warning)),
        ]))

        let multi = overview.isMultiSite
        let rows = scopes.map { s -> ReportRow in
            var cells = [ReportCell(s.alias.flatMap { $0.isEmpty ? nil : $0 } ?? s.shortName, bold: true)]
            if multi { cells.append(ReportCell(s.site, tone: .muted)) }
            let state: String
            switch s.level {
            case _ where s.isEstimate: state = "Estimation"
            case .warning: state = "Alerte"
            default: state = s.level.label
            }
            cells += [ReportCell(s.interfaceLabel, tone: .muted),
                      ReportCell(s.compactRangesLabel),
                      ReportCell(s.level == .inactive ? "—" : s.usedLabel),
                      ReportCell(s.level == .inactive ? "désactivée" : s.percentLabel, tone: s.level >= .warning ? s.level.reportTone : (s.level == .inactive ? .muted : .normal),
                                 bar: s.level == .inactive ? nil : s.percent / 100),
                      ReportCell(s.isEstimate ? "—" : "\(s.reservationsInPool)"),
                      ReportCell(state, badge: s.isEstimate ? .neutral : s.level.reportTone)]
            return ReportRow(cells)
        }
        var columns = [ReportColumn("Étendue", weight: 1)]
        if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
        columns += [ReportColumn("Interface", weight: 0.8), ReportColumn("Plage", weight: 1.8),
                    ReportColumn("Utilisées", weight: 0.8, trailing: true), ReportColumn("Taux", weight: 1.3),
                    ReportColumn("Réserv.", weight: 0.6, trailing: true), ReportColumn("État", weight: 0.8)]
        blocks.append(.table(ReportTable(columns: columns, rows: rows)))

        if alerting.isEmpty {
            blocks.append(.note("Aucune étendue au-delà de \(MonFormat.percent(thresholds.warningPercent)) d’occupation\u{00A0}: assez d’adresses libres pour les nouveaux appareils."))
        } else {
            let advice = alerting.map { s in
                ReportRow([ReportCell(s.level == .critical ? "Critique" : "Alerte", badge: s.level.reportTone),
                           ReportCell((DHCPScopeAnalysis.alertText(s) ?? s.displayName) + (multi ? " (\(s.site))" : "") + ".", bold: true),
                           ReportCell(DHCPScopeAnalysis.advice(s))])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 0.8), ReportColumn("Constat", weight: 2.6),
                                                       ReportColumn("Conseil", weight: 3.0)], rows: advice, wraps: true)))
        }
        let expiring = active.reduce(0) { $0 + $1.expiringSoon }
        var note = "Seuils\u{00A0}: avertissement à \(MonFormat.percent(thresholds.warningPercent)), critique à \(MonFormat.percent(thresholds.criticalPercent)) d’occupation ou dès qu’il ne reste aucune adresse libre."
        if !overview.isEstimate, expiring > 0 {
            note += " \(plural(expiring, "bail expire", "baux expirent")) dans moins de \(thresholds.expiringMinutes)\u{00A0}min."
        }
        blocks.append(.note(note))
        return blocks
    }
}
