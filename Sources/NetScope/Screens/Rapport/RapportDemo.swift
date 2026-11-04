import Foundation
import NetScopeCore

/// Données de démonstration de l'écran Rapports, d'après le croquis Rapport.dc.html
/// (renderVals : problèmes, radios Wi-Fi, annexe, rapports récents). Aucun accès réseau.
@MainActor
enum RapportDemo {
    /// Réglages du croquis (state) : site « Siège », technicien, date du 2026-11-03.
    static let config = ReportConfig(template: .audit, client: "", site: "Siège", technician: "Dany Ménard", date: "2026-11-03")

    static let recents: [ReportRecent] = [
        ReportRecent(title: "Audit réseau — Siège", fileName: "rapport-audit-siege-2026-10-06.pdf", format: .pdf,
                     date: "2026-10-06", pages: 6, technician: "Dany Ménard"),
        ReportRecent(title: "Intervention — Siège (imprimantes)", fileName: "rapport-intervention-siege-2026-09-22.pdf", format: .pdf,
                     date: "2026-09-22", pages: 3, technician: "Dany Ménard"),
        ReportRecent(title: "Inventaire simple — Siège", fileName: "rapport-inventaire-siege-2026-08-12.csv", format: .csv,
                     date: "2026-08-12", rows: 188, technician: ""),
    ]

    /// Ajoute ce que le scan de démonstration ne fournit pas : DHCP non autorisé (note 2, pas encore
    /// réalisé), radios de la borne, offres DHCP de l'annexe.
    static func complete(_ input: inout ReportInput) {
        input.extraProblems = [
            ReportProblem(title: "DHCP non autorisé sur 10.182.122.250", severity: .critique,
                          recommendation: "Localisé sur SW-ETG2-01 port 1/7. Débrancher l’appareil, puis activer DHCP snooping sur les VLAN 1 et 20."),
            ReportProblem(title: "Canal 2,4 GHz encombré", severity: .moyen,
                          recommendation: "Passer FortiAP-231F sur le canal 1 ou 11 et réduire la puissance 2,4 GHz."),
        ]
        input.radios = ["10.182.122.102": ReportRadio(channel24: 6, channel5: 36, congested24: true)]
        input.wifiNote = "La borne FortiAP-231F (VLAN 20) partage le canal 6 avec 11 réseaux voisins détectés."
        if !input.annex.isEmpty { input.annex.append(ReportRawLine("")) }
        input.annex += [
            ReportRawLine("DHCPOFFER  10.182.122.1    -> FortiGate-60F (autorisé)"),
            ReportRawLine("DHCPOFFER  10.182.122.250  -> SW-ETG2-01 1/7 (NON AUTORISÉ)"),
        ]
    }
}
