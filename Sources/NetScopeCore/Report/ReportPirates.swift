import Foundation

// Notes 96 et 97 : section facultative « Pirates et conflits » des rapports par site. Elle reprend
// les relevés déjà faits (Test DHCP, conflits d'IP calculés, bornes classées) : rien n'est lu ni
// envoyé à la création du rapport.

extension ReportBuilder {
    static func pirateBlocks(dhcp: [RogueDHCPFinding], conflicts: [IPConflict], aps: [RogueAPFinding], masked: Bool) -> [ReportBlock] {
        func mac(_ m: MACAddress?) -> String {
            guard let m else { return "—" }
            return masked ? String(m.formatted(.upperColon).prefix(8)) + ":XX:XX:XX" : m.formatted(.upperColon)
        }
        let rogueDHCP = dhcp.filter(\.verdict.isRogue)
        let critical = conflicts.filter(\.kind.isCritical)
        let rogueAPs = aps.filter { $0.classification == .pirate }
        var blocks: [ReportBlock] = [
            .paragraph("Serveurs DHCP qui ont répondu au dernier Test DHCP, conflits d’adresses IP (table ARP, scans, FortiGate, Inventaire) et bornes Wi-Fi entendues par les FortiAP et par ce Mac."),
            .kpis([
                ReportKPI("\(rogueDHCP.count)", "serveur" + (rogueDHCP.count > 1 ? "s" : "") + " DHCP pirate" + (rogueDHCP.count > 1 ? "s" : ""),
                          tone: rogueDHCP.isEmpty ? .normal : .critical),
                ReportKPI("\(critical.count)", "conflit" + (critical.count > 1 ? "s" : "") + " d’adresse IP", tone: critical.isEmpty ? .normal : .critical),
                ReportKPI("\(conflicts.count - critical.count)", "MAC instable" + (conflicts.count - critical.count > 1 ? "s" : ""),
                          tone: conflicts.count == critical.count ? .normal : .warning),
                ReportKPI("\(rogueAPs.count)", "borne" + (rogueAPs.count > 1 ? "s" : "") + " pirate" + (rogueAPs.count > 1 ? "s" : ""),
                          tone: rogueAPs.isEmpty ? .normal : .critical),
            ]),
        ]
        // Serveurs DHCP.
        if dhcp.isEmpty {
            blocks.append(.note("Aucun Test DHCP enregistré\u{00A0}: Boîte à outils › Test DHCP, ou sonde «\u{00A0}Serveur DHCP pirate\u{00A0}» de la Surveillance."))
        } else {
            blocks.append(.table(ReportTable(columns: [
                ReportColumn("Serveur", weight: 0.9, mono: true), ReportColumn("MAC", weight: 1.1, mono: true),
                ReportColumn("Passerelle", weight: 0.9, mono: true), ReportColumn("Plage", weight: 1, mono: true),
                ReportColumn("DNS", weight: 1, mono: true), ReportColumn("Verdict", weight: 1.2),
            ], rows: dhcp.map { f in
                ReportRow([
                    ReportCell(f.server?.description ?? "—", bold: true), ReportCell(mac(f.mac), tone: .muted),
                    ReportCell(f.gateway?.description ?? "—"), ReportCell(f.pool),
                    ReportCell(f.dns.isEmpty ? "—" : f.dns.map(\.description).joined(separator: ", ")),
                    ReportCell(f.verdict.label, badge: f.verdict.isRogue ? .critical : (f.verdict == .nonVerifie ? .neutral : .success)),
                ])
            }, wraps: true)))
        }
        // Conflits d'IP.
        if conflicts.isEmpty {
            blocks.append(.note("Aucun conflit d’adresse IP relevé."))
        } else {
            blocks.append(.table(ReportTable(columns: [
                ReportColumn("Adresse", weight: 0.9, mono: true), ReportColumn("Type", weight: 1.2),
                ReportColumn("MAC", weight: 1.6, mono: true), ReportColumn("Détail", weight: 2.2),
            ], rows: conflicts.map { c in
                ReportRow([
                    ReportCell(c.ip?.description ?? c.ips.map(\.description).joined(separator: ", "), bold: true),
                    ReportCell(c.kind.label + (c.involvesGateway ? " (passerelle)" : ""), badge: c.kind.isCritical ? .critical : .warning),
                    ReportCell(c.macs.map(mac).joined(separator: ", "), tone: .muted),
                    ReportCell(masked ? c.kind.label : c.detail),
                ])
            }, wraps: true)))
        }
        // Bornes Wi-Fi : pirates et voisines (les connues sont comptées seulement).
        let shown = aps.filter { $0.classification != .connue }
        if aps.isEmpty {
            blocks.append(.note("Aucune borne lue\u{00A0}: lire la FortiGate (AP voisins) ou balayer depuis ce Mac (Wi-Fi › FortiAP › Pirates)."))
        } else {
            let known = aps.count - shown.count
            blocks.append(.paragraph("\(plural(aps.count, "borne entendue", "bornes entendues"))\u{00A0}: \(rogueAPs.count) pirate\(rogueAPs.count > 1 ? "s" : ""), \(shown.count - rogueAPs.count) voisine\(shown.count - rogueAPs.count > 1 ? "s" : ""), \(known) connue\(known > 1 ? "s" : "") (FortiAP du site)."))
            blocks.append(.table(ReportTable(columns: [
                ReportColumn("SSID", weight: 1.3), ReportColumn("BSSID", weight: 1.1, mono: true),
                ReportColumn("Canal", weight: 0.5, trailing: true), ReportColumn("Signal", weight: 0.6, trailing: true),
                ReportColumn("Classe", weight: 0.8), ReportColumn("Raison", weight: 1.8),
            ], rows: shown.map { f in
                ReportRow([
                    ReportCell(f.displaySSID, bold: f.classification == .pirate), ReportCell(mac(f.bssid), tone: .muted),
                    ReportCell(f.channel.map(String.init) ?? "—"), ReportCell(f.rssi.map { "\($0)\u{00A0}dBm" } ?? "—"),
                    ReportCell(f.classification == .pirate ? "Pirate" : "Voisine", badge: f.classification == .pirate ? .critical : .neutral),
                    ReportCell(f.reasonLabel + (f.wiredPlace.map { " · \($0)" } ?? "")),
                ])
            }, wraps: true)))
        }
        var advice: [String] = []
        for f in rogueDHCP {
            advice.append("Serveur DHCP pirate \(f.server?.description ?? f.offered.description)\u{00A0}: \(f.reason.lowercased())\u{00A0}; le débrancher ou désactiver son DHCP.")
        }
        if critical.contains(where: \.involvesGateway) {
            advice.append("La passerelle répond avec plusieurs MAC\u{00A0}: usurpation ARP possible, localiser la MAC inconnue sur les switchs et activer l’inspection ARP (DAI).")
        }
        for f in rogueAPs where f.reasons.contains(.sosie) {
            advice.append("Sosie de «\u{00A0}\(f.displaySSID)\u{00A0}» (\(mac(f.bssid)))\u{00A0}: localiser la borne par le signal et la retirer.")
        }
        for f in rogueAPs where f.reasons.contains(.filaire) {
            advice.append("Borne «\u{00A0}\(f.displaySSID)\u{00A0}» branchée sur le réseau" + (f.wiredPlace.map { " (\($0))" } ?? "") + "\u{00A0}: désactiver le port.")
        }
        if advice.isEmpty { advice.append("Aucun serveur DHCP pirate, conflit d’IP ni borne pirate relevé.") }
        blocks.append(.paragraph(advice.joined(separator: " ")))
        return blocks
    }
}
