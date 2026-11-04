import Foundation

// Section facultative « WAN et VPN » des rapports (note 39) : liens WAN de chaque FortiGate
// (état, débit, latence, perte, SLA), tunnels VPN IPsec, constats et conseils.

extension WANLinkState {
    var reportTone: ReportTone {
        switch self {
        case .down: return .critical
        case .degraded: return .warning
        case .up: return .success
        case .unknown, .disabled: return .neutral
        }
    }
}

extension WANTunnelState {
    var reportTone: ReportTone {
        switch self {
        case .down: return .critical
        case .partial: return .warning
        case .up: return .success
        case .idle: return .neutral
        }
    }
}

extension ReportBuilder {
    static func wanBlocks(_ overview: WANOverview?, thresholds: WANThresholds) -> [ReportBlock] {
        guard let overview, !overview.sites.isEmpty else {
            return [.note("Aucune lecture du WAN\u{00A0}: configurer la FortiGate du site dans Réglages › Switchs, puis ouvrir l’outil «\u{00A0}WAN et VPN\u{00A0}» de la Boîte à outils.")]
        }
        let multi = overview.isMultiSite
        let sites = overview.sites.map(\.site)
        var text = sites.count > 1 ? "WAN et VPN des FortiGate des sites " + sites.joined(separator: ", ") : "WAN et VPN de la FortiGate du site " + sites[0]
        text += ", lus par l’API REST en lecture seule"
        if let date = overview.readAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_CA")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            text += " le \(f.string(from: date))"
        }
        text += ". Latence, gigue et perte viennent des sondes SD-WAN de la FortiGate (instantané au moment de la lecture)."
        var blocks: [ReportBlock] = [.paragraph(text)]

        let links = overview.links.filter { $0.state != .disabled }
        let linksUp = links.filter { $0.state == .up || $0.state == .degraded }.count
        let tunnels = overview.tunnels.filter { $0.state != .idle }
        let tunnelsUp = tunnels.filter { $0.state == .up }.count
        let degraded = links.filter { $0.state == .degraded }.count
        blocks.append(.kpis([
            ReportKPI("\(linksUp) / \(links.count)", "liens WAN actifs", tone: linksUp < links.count ? .critical : .normal),
            ReportKPI("\(degraded)", degraded > 1 ? "liens dégradés" : "lien dégradé", tone: degraded > 0 ? .warning : .normal),
            ReportKPI("\(tunnelsUp) / \(tunnels.count)", "tunnels IPsec montés", tone: tunnelsUp < tunnels.count ? .critical : .normal),
            ReportKPI("\(overview.sslUsers.count)", overview.sslUsers.count > 1 ? "utilisateurs VPN SSL" : "utilisateur VPN SSL"),
        ]))

        if !overview.links.isEmpty {
            let rows = overview.links.map { l -> ReportRow in
                var cells = [ReportCell(l.interface.displayName, bold: true)]
                if multi { cells.append(ReportCell(l.site, tone: .muted)) }
                cells += [ReportCell(l.interface.addressLabel, tone: .muted),
                          ReportCell(WANFormat.throughput(rx: l.interface.rxBps, tx: l.interface.txBps)),
                          ReportCell(WANFormat.ms(l.latencyMs)),
                          ReportCell(WANFormat.ms(l.jitterMs)),
                          ReportCell(WANFormat.loss(l.lossPercent), tone: (l.lossPercent ?? 0) > thresholds.lossPercent ? .warning : .normal),
                          ReportCell(l.slaLabel),
                          ReportCell(l.state.label, badge: l.state.reportTone)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Lien WAN", weight: 1.5)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Adresse", weight: 1.1), ReportColumn("Débit", weight: 1.5), ReportColumn("Latence", weight: 0.85, trailing: true),
                        ReportColumn("Gigue", weight: 0.6, trailing: true), ReportColumn("Perte", weight: 0.6, trailing: true),
                        ReportColumn("SLA", weight: 0.5, trailing: true), ReportColumn("État", weight: 0.8)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        if !overview.tunnels.isEmpty {
            let rows = overview.tunnels.map { t -> ReportRow in
                var cells = [ReportCell(t.tunnel.name, bold: true)]
                if multi { cells.append(ReportCell(t.site, tone: .muted)) }
                cells += [ReportCell(t.tunnel.peerLabel),
                          ReportCell(t.tunnel.phase2.isEmpty ? "—" : "\(t.tunnel.phase2Up)/\(t.tunnel.phase2.count)"),
                          ReportCell(WANFormat.bytes(t.tunnel.incomingBytes)),
                          ReportCell(WANFormat.bytes(t.tunnel.outgoingBytes)),
                          ReportCell(t.state == .up ? WANFormat.duration(since: t.tunnel.upSince, now: overview.readAt ?? Date()) : "—"),
                          ReportCell(t.state.label, badge: t.state.reportTone)]
                return ReportRow(cells)
            }
            var columns = [ReportColumn("Tunnel IPsec", weight: 1.2)]
            if multi { columns.append(ReportColumn("Site", weight: 0.9)) }
            columns += [ReportColumn("Vers", weight: 1.6), ReportColumn("Phases 2", weight: 0.7, trailing: true),
                        ReportColumn("Entrant", weight: 0.8, trailing: true), ReportColumn("Sortant", weight: 0.8, trailing: true),
                        ReportColumn("Depuis", weight: 0.8), ReportColumn("État", weight: 0.8)]
            blocks.append(.table(ReportTable(columns: columns, rows: rows, wraps: true)))
        }

        var advice: [ReportRow] = []
        for t in overview.alertingTunnels {
            guard let text = WANAnalysis.alertText(t) else { continue }
            advice.append(ReportRow([ReportCell(t.state == .down ? "Critique" : "Alerte", badge: t.state.reportTone),
                                     ReportCell(text + (multi ? " (\(t.site))" : "") + ".", bold: true),
                                     ReportCell(WANAnalysis.advice(t))]))
        }
        for l in overview.alertingLinks {
            guard let text = WANAnalysis.alertText(l) else { continue }
            advice.append(ReportRow([ReportCell(l.state == .down ? "Critique" : "Alerte", badge: l.state.reportTone),
                                     ReportCell(text + (multi ? " (\(l.site))" : "") + ".", bold: true),
                                     ReportCell(WANAnalysis.advice(l))]))
        }
        if advice.isEmpty {
            blocks.append(.note("Tous les liens WAN répondent sous les seuils et tous les tunnels IPsec sont montés."))
        } else {
            blocks.append(.table(ReportTable(columns: [ReportColumn("Gravité", weight: 0.8), ReportColumn("Constat", weight: 2.6),
                                                       ReportColumn("Conseil", weight: 3.0)], rows: advice, wraps: true)))
        }
        var note = "Seuils d’un lien dégradé\u{00A0}: \(thresholds.label), ou SLA de la FortiGate non respecté."
        if !overview.notes.isEmpty { note += " " + overview.notes.joined(separator: " ") }
        blocks.append(.note(note))
        return blocks
    }
}
