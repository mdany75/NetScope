import Foundation

// Section facultative « Wi-Fi FortiAP » des rapports (note 27) : bornes gérées par les FortiGate,
// clients, SSID, chevauchements de canal, AP non autorisés et conseils.

extension WifiRecommendation.Severity {
    var reportTone: ReportTone {
        switch self {
        case .critique: return .critical
        case .alerte: return .warning
        case .conseil: return .caution
        case .info: return .neutral
        }
    }
}

extension ReportBuilder {
    static func fortiAPBlocks(_ overview: FortiWifiOverview?, thresholds: FortiWifiThresholds, masked: Bool) -> [ReportBlock] {
        guard let overview, !overview.aps.isEmpty else {
            return [.note("Aucune borne FortiAP lue\u{00A0}: configurer la FortiGate du site dans Réglages › Switchs, puis relire les bornes dans Wi-Fi › FortiAP.")]
        }
        let d = FortiWifiAnalysis.diagnose(overview, thresholds: thresholds, maskMACs: masked)
        let sites = overview.sites.filter { !$0.isEmpty }
        var text = "\(plural(overview.aps.count, "borne FortiAP gérée", "bornes FortiAP gérées"))"
        if !sites.isEmpty { text += " par " + (sites.count > 1 ? "les FortiGate des sites " + sites.joined(separator: ", ") : "la FortiGate du site " + sites[0]) }
        text += ", lues par l’API REST en lecture seule"
        if let date = overview.readAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_CA")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            text += " le \(f.string(from: date))"
        }
        text += ". \(plural(overview.clients.count, "client Wi-Fi associé", "clients Wi-Fi associés")), \(plural(overview.distinctSSIDs.count, "SSID diffusé", "SSID diffusés"))."
        var blocks: [ReportBlock] = [.paragraph(text)]
        blocks.append(.kpis([
            ReportKPI("\(overview.onlineAPs.count) / \(overview.aps.count)", "bornes en ligne", tone: overview.offlineAPs.isEmpty ? .normal : .critical),
            ReportKPI("\(overview.clients.count)", overview.clients.count > 1 ? "clients" : "client"),
            ReportKPI("\(d.weakClients.count)", "à signal faible", tone: d.weakClients.isEmpty ? .normal : .warning),
            ReportKPI("\(d.overlaps.count)", d.overlaps.count > 1 ? "chevauchements de canal" : "chevauchement de canal", tone: d.overlaps.isEmpty ? .normal : .warning),
            ReportKPI("\(d.unauthorized.count)", "AP non autorisé" + (d.unauthorized.count > 1 ? "s" : ""), tone: d.unauthorized.isEmpty ? .normal : .critical),
        ]))

        let multi = overview.isMultiSite
        let apRows = overview.aps.sorted { ($0.site, $0.name) < ($1.site, $1.name) }.map { ap -> ReportRow in
            let radios = ap.radios.filter(\.isServing).map { r in
                "\(r.band?.label ?? "?") c.\(r.channel ?? 0)" + (r.band == .ghz24 && r.effectiveWidth == 20 ? "" : "/\(r.effectiveWidth)")
            }.joined(separator: ", ")
            var cells = [ReportCell(ap.name, bold: true), ReportCell(ap.model.isEmpty ? "—" : ap.model, tone: .muted)]
            if multi { cells.append(ReportCell(ap.site, tone: .muted)) }
            cells += [ReportCell(ap.ip?.description ?? "—"),
                      ReportCell(ap.isOffline ? "Hors ligne" : "En ligne", badge: ap.isOffline ? .critical : .success),
                      ReportCell(radios.isEmpty ? "—" : radios),
                      ReportCell(ap.isOffline ? "—" : "\(ap.totalClients)"),
                      ReportCell(ap.firmwareShort.isEmpty ? "—" : ap.firmwareShort, tone: .muted)]
            return ReportRow(cells)
        }
        var apColumns = [ReportColumn("Borne", weight: 1.4), ReportColumn("Modèle", weight: 0.9)]
        if multi { apColumns.append(ReportColumn("Site", weight: 1)) }
        apColumns += [ReportColumn("Adresse IP", weight: 1.1, mono: true), ReportColumn("État", weight: 0.9),
                      ReportColumn("Radios (canal/largeur)", weight: 2), ReportColumn("Clients", weight: 0.7, trailing: true),
                      ReportColumn("Firmware", weight: 0.8)]
        blocks.append(.table(ReportTable(columns: apColumns, rows: apRows, wraps: true)))

        if !overview.ssids.isEmpty {
            let rows = overview.ssids.map { s in
                ReportRow([ReportCell(s.ssid, bold: true), ReportCell(s.securityLabel, badge: s.isOpen ? .warning : nil),
                           ReportCell(s.vlan.map(String.init) ?? "—"),
                           ReportCell("\(overview.clients.filter { $0.site == s.site && $0.ssid == s.ssid }.count)"),
                           ReportCell(multi ? s.site : s.name, tone: .muted)])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("SSID", weight: 1.5), ReportColumn("Sécurité", weight: 1.6),
                                                       ReportColumn("VLAN", weight: 0.6, trailing: true), ReportColumn("Clients", weight: 0.7, trailing: true),
                                                       ReportColumn(multi ? "Site" : "Interface", weight: 1.1)], rows: rows)))
        }

        if !d.weakClients.isEmpty {
            let rows = d.weakClients.prefix(15).map { c in
                ReportRow([ReportCell(c.hostname ?? ReportText.mac(c.mac, masked: masked), bold: true),
                           ReportCell(c.ip?.description ?? "—"), ReportCell(c.apName ?? "—"),
                           ReportCell([c.band?.label, c.channel.map { "c.\($0)" }].compactMap { $0 }.joined(separator: " ")),
                           ReportCell(c.rssi.map { "\($0)\u{00A0}dBm" } ?? "—", tone: .warning),
                           ReportCell(c.snr.map { "\($0)\u{00A0}dB" } ?? "—")])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Client à signal faible", weight: 1.6), ReportColumn("Adresse IP", weight: 1.1, mono: true),
                                                       ReportColumn("Borne", weight: 1.2), ReportColumn("Bande", weight: 1),
                                                       ReportColumn("RSSI", weight: 0.8, trailing: true), ReportColumn("SNR", weight: 0.7, trailing: true)],
                                             rows: Array(rows))))
        }

        let advice = d.advice.filter { $0.kind != .healthy }
        if !advice.isEmpty {
            let rows = advice.map { a in
                ReportRow([ReportCell(a.severity.label, badge: a.severity.reportTone), ReportCell(a.title, bold: true), ReportCell(a.detail)])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 0.8), ReportColumn("Constat", weight: 1.8),
                                                       ReportColumn("Conseil", weight: 3.6)], rows: rows, wraps: true)))
        } else {
            blocks.append(.note("Aucun chevauchement de canal, aucune borne hors ligne ou surchargée, aucun client sous les seuils."))
        }
        blocks.append(.note("Seuils\u{00A0}: signal faible sous \(thresholds.weakRSSI)\u{00A0}dBm ou \(thresholds.weakSNR)\u{00A0}dB de SNR\u{00A0}; borne surchargée au-delà de \(thresholds.maxClientsPerRadio) clients par radio ou \(Int(thresholds.maxChannelUtilization.rounded()))\u{00A0}% d’utilisation du canal."))
        return blocks
    }
}
