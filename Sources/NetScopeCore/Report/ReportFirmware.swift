import Foundation

// Note 41 : firmware et licences du parc Fortinet dans les rapports. Drapeau « firmware à jour »
// des switchs relevés (enfin rempli d'après les versions disponibles lues par la FortiGate),
// problèmes (mise à jour disponible, licence bientôt expirée) et section facultative « Firmware et
// licences ».

extension FirmwareStatus {
    var reportTone: ReportTone {
        switch self {
        case .upToDate: return .success
        case .updateAvailable: return .warning
        case .unknown: return .neutral
        }
    }
}

extension LicenseLevel {
    var reportTone: ReportTone {
        switch self {
        case .expired, .critical: return .critical
        case .warning: return .warning
        case .ok: return .success
        case .unknown, .notLicensed: return .neutral
        }
    }
}

public enum ReportFirmware {
    /// Remplit le drapeau « firmware à mettre à jour » (et la version si elle manque) des switchs
    /// relevés qui correspondent, par leur nom ou leur numéro de série, à un équipement du parc.
    public static func flag(_ switches: [ReportSwitch], with overview: FirmwareOverview?) -> [ReportSwitch] {
        guard let overview, !overview.devices.isEmpty else { return switches }
        return switches.map { sw in
            let name = sw.name.lowercased()
            guard let device = overview.devices.first(where: { d in
                d.name.lowercased() == name || (!d.serial.isEmpty && name.contains(d.serial.lowercased()))
            }) else { return sw }
            var copy = sw
            if copy.firmware == nil { copy.firmware = device.versionLabel }
            if device.status == .updateAvailable { copy.firmwareOutdated = true }
            return copy
        }
    }

    /// Problèmes du rapport : équipements à mettre à jour, licences expirées ou sous le seuil.
    public static func problems(_ overview: FirmwareOverview?) -> [ReportProblem] {
        guard let overview else { return [] }
        var result: [ReportProblem] = []
        let multi = overview.isMultiSite
        for usage in overview.alertingLicenses {
            guard let text = FirmwareAnalysis.alertText(usage) else { continue }
            let severity: ReportSeverity = usage.level == .expired ? .eleve : (usage.level == .critical ? .moyen : .faible)
            result.append(ReportProblem(title: text + (multi ? " (\(usage.site))" : ""), severity: severity,
                                        recommendation: FirmwareAnalysis.advice(usage), key: "licence|\(usage.site)|\(usage.license.key)"))
        }
        for device in overview.outdated {
            result.append(ReportProblem(title: "Firmware \(device.name) \(device.versionLabel)", severity: .faible,
                                        recommendation: "Version \(device.availableLabel) disponible (\(device.source?.label ?? "FortiGuard")). "
                                            + FirmwareAnalysis.advice(device),
                                        key: "firmware|\(device.name)"))
        }
        return result
    }
}

extension ReportBuilder {
    static func firmwareBlocks(_ overview: FirmwareOverview?) -> [ReportBlock] {
        guard let overview, !overview.sites.isEmpty else {
            return [.note("Aucune lecture du firmware ni des licences\u{00A0}: configurer la FortiGate du site dans Réglages › Switchs, puis ouvrir l’outil «\u{00A0}Firmware et licences\u{00A0}» de la Boîte à outils.")]
        }
        let multi = overview.isMultiSite
        let sites = overview.sites.map(\.site)
        var text = sites.count > 1 ? "Firmware et licences des FortiGate des sites " + sites.joined(separator: ", ")
            : "Firmware et licences de la FortiGate du site " + sites[0]
        text += " et des FortiSwitch et FortiAP qu’elle gère, lus par l’API REST en lecture seule"
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = "yyyy-MM-dd"
        if let date = overview.readAt {
            let g = DateFormatter()
            g.locale = Locale(identifier: "fr_CA")
            g.dateFormat = "yyyy-MM-dd HH:mm"
            text += " le \(g.string(from: date))"
        }
        text += ". Les versions disponibles viennent de FortiGuard (FortiOS) et des listes recommandées par la FortiGate (FortiSwitch, FortiAP)\u{00A0}; NetScope ne lance aucune mise à jour."
        var blocks: [ReportBlock] = [.paragraph(text)]

        let devices = overview.devices
        let upToDate = devices.filter { $0.status == .upToDate }.count
        let outdated = overview.outdated.count
        let alerting = overview.alertingLicenses
        let nearest = overview.licenses.filter { $0.level != .notLicensed && $0.daysLeft != nil }.min { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        blocks.append(.kpis([
            ReportKPI("\(upToDate) / \(devices.count)", "équipements à jour"),
            ReportKPI("\(outdated)", outdated > 1 ? "mises à jour disponibles" : "mise à jour disponible", tone: outdated > 0 ? .warning : .normal),
            ReportKPI("\(alerting.count)", alerting.count > 1 ? "licences en alerte" : "licence en alerte",
                      tone: alerting.contains { $0.level >= .critical } ? .critical : (alerting.isEmpty ? .normal : .warning)),
            ReportKPI(nearest.map(\.daysLabel) ?? "—", "avant la prochaine expiration"),
        ]))

        if !devices.isEmpty {
            let rows = devices.map { d -> ReportRow in
                var cells = [ReportCell(d.name, bold: true)]
                if multi { cells.append(ReportCell(d.site, tone: .muted)) }
                cells += [ReportCell(d.model.isEmpty ? d.kind.label : d.model, tone: .muted),
                          ReportCell(d.serial.isEmpty ? "—" : d.serial, tone: .muted),
                          ReportCell(d.versionLabel, tone: d.status == .updateAvailable ? .warning : .normal),
                          ReportCell(d.availableLabel),
                          ReportCell(d.status == .updateAvailable ? "À mettre à jour" : d.status.label, badge: d.status.reportTone)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Équipement", weight: 1.6)]
            if multi { columns.append(ReportColumn("Site", weight: 1.0)) }
            columns += [ReportColumn("Modèle", weight: 1.3), ReportColumn("N° de série", weight: 1.6),
                        ReportColumn("Version", weight: 0.8, mono: true), ReportColumn("Disponible", weight: 0.9, mono: true),
                        ReportColumn("État", weight: 1.2)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        if !overview.licenses.isEmpty {
            let rows = overview.licenses.map { u -> ReportRow in
                var cells = [ReportCell(u.license.label, bold: true)]
                if multi { cells.append(ReportCell(u.site, tone: .muted)) }
                cells += [ReportCell(u.license.expires.map { f.string(from: $0) } ?? "—", tone: .muted),
                          ReportCell(u.daysLabel, tone: u.level.reportTone == .critical ? .critical : (u.level == .warning ? .warning : .normal)),
                          ReportCell(u.level.label, badge: u.level.reportTone)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Licence", weight: 1.8)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Expiration", weight: 0.9, mono: true), ReportColumn("Jours restants", weight: 0.9, trailing: true),
                        ReportColumn("État", weight: 1.0)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        var advice: [ReportRow] = []
        for u in alerting {
            guard let text = FirmwareAnalysis.alertText(u) else { continue }
            advice.append(ReportRow([ReportCell(u.level >= .critical ? "Critique" : "Alerte", badge: u.level.reportTone),
                                     ReportCell(text + (multi ? " (\(u.site))" : "") + ".", bold: true),
                                     ReportCell(FirmwareAnalysis.advice(u))]))
        }
        for d in overview.outdated {
            guard let text = FirmwareAnalysis.alertText(d) else { continue }
            advice.append(ReportRow([ReportCell("À planifier", badge: .warning),
                                     ReportCell(text + (multi ? " (\(d.site))" : "") + ".", bold: true),
                                     ReportCell(FirmwareAnalysis.advice(d))]))
        }
        if advice.isEmpty {
            blocks.append(.note("Tous les équipements lus sont à jour et aucune licence n’expire dans les \(overview.thresholds.warningDays)\u{00A0}prochains jours."))
        } else {
            blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 0.8), ReportColumn("Constat", weight: 2.6),
                                                       ReportColumn("Conseil", weight: 3.0)], rows: advice, wraps: true)))
        }
        var note = "Licences\u{00A0}: orange à \(overview.thresholds.warningDays)\u{00A0}jours de l’expiration, rouge à \(overview.thresholds.criticalDays)\u{00A0}jours."
        let branches = devices.compactMap { d in d.newerBranch.map { "\(d.name)\u{00A0}: branche \($0.branch) disponible (\($0.short))" } }
        if !branches.isEmpty { note += " Changement de branche à planifier séparément\u{00A0}: " + branches.joined(separator: "\u{00A0}; ") + "." }
        if !overview.notes.isEmpty { note += " " + overview.notes.joined(separator: " ") }
        blocks.append(.note(note))
        return blocks
    }
}
