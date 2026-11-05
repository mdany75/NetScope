import Foundation
import NetScopeCore

/// Démonstration du Wake-on-LAN (note 78) : historique avec un réveil groupé (deux postes du
/// réseau local et un serveur d'un autre sous-réseau, par broadcast dirigé), suivi par ping
/// « réveillé en N s », et réveils simulés sans aucun paquet.
///
/// Captures : NETSCOPE_OUTIL_DEMO=wol ouvre l'outil ; NETSCOPE_WOL_SELECTION=1 choisit trois
/// postes dans le tableau (réveil groupé, diffusion dirigée vers 10.10.0.255).
@MainActor
enum WakeDemo {
    /// Postes choisis pour la capture du réveil groupé.
    static let selectedIPs = ["10.182.122.117", "10.182.122.146", "10.10.0.31"]

    static var preselect: Bool {
        ProcessInfo.processInfo.environment["NETSCOPE_WOL_SELECTION"] == "1"
    }

    /// Délai simulé avant le premier écho (stable d'une adresse à l'autre).
    static func simulatedDelay(for ip: IPv4Address) -> TimeInterval {
        TimeInterval(6 + Int(ip.value % 13))
    }

    /// Historique des réveils de démonstration (du plus récent au plus ancien).
    static func log(now: Date) -> [ToolWakeEntry] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            ToolWakeEntry(date: ago(3), name: "SRV-BACKUP", mac: "00:50:56:AA:10:31",
                          detail: "Paquet envoyé en broadcast dirigé 10.10.0.255 (10.10.0.0/24):9 · 10.10.0.31 réveillé en 41\u{00A0}s",
                          status: .awake),
            ToolWakeEntry(date: ago(3), name: "WKS341", mac: "B0:7B:25:44:9F:20",
                          detail: "Paquet envoyé en broadcast local 10.182.122.255:9 · aucune réponse au ping après 2\u{00A0}min (WoL désactivé dans le BIOS, ou broadcast dirigé bloqué par le routeur\u{00A0}?)",
                          status: .noReply),
            ToolWakeEntry(date: ago(3), name: "WKS346", mac: "B0:7B:25:44:A1:6C",
                          detail: "Paquet envoyé en broadcast local 10.182.122.255:9 · 10.182.122.117 réveillé en 18\u{00A0}s",
                          status: .awake),
            ToolWakeEntry(date: ago(60 * 15), name: "PF4L8M20", mac: "8C:16:45:2B:9E:03",
                          detail: "Paquet envoyé en broadcast local 10.182.122.255:9 · 10.182.122.113 réveillé en 27\u{00A0}s",
                          status: .awake),
        ]
    }
}
