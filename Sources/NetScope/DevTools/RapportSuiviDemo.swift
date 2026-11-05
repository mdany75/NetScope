import Foundation
import NetScopeCore

/// Note 42 : démonstration du rapport de suivi et des rapports planifiés (aucun réseau, rien sur le
/// disque). Le Siège a trois rapports passés ; le dernier (Audit réseau du 6 octobre 2026) est bâti
/// d'après l'état actuel de la démonstration pour donner, depuis : 3 appareils nouveaux, 1 disparu,
/// 2 changés, 2 problèmes réglés et 1 nouveau. Deux rapports planifiés : un suivi hebdomadaire du
/// Siège (brouillon de courriel) et un inventaire mensuel de l'Entrepôt Laval.
@MainActor
enum RapportSuiviDemo {
    private static let calendar = ReportScheduler.calendar()

    private static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date()
    }

    /// Date figée des libellés (« Prochain : lundi 9 novembre à 7 h 00 »).
    static let now = at(2026, 11, 4, 9, 30)

    static let auditID = UUID(uuidString: "5A7E0042-0001-4C1E-9A11-00000000B001")!
    static let interventionID = UUID(uuidString: "5A7E0042-0002-4C1E-9A11-00000000B002")!
    static let inventaireID = UUID(uuidString: "5A7E0042-0003-4C1E-9A11-00000000B003")!

    /// Apparus depuis le dernier rapport : le téléphone Android, le téléphone de conférence, la caméra Axis.
    static let newIPs: Set<String> = ["10.182.122.133", "10.182.122.123", "192.168.50.22"]

    // MARK: Historique

    static func history(forKey key: String, current: ReportSnapshot?) -> ReportHistory {
        guard key == SiteFiles.key(for: SitesDemo.siegeID) else { return ReportHistory() }
        let base = baseSnapshot(current)
        var intervention = base
        intervention.id = interventionID
        intervention.created = at(2026, 9, 22, 15, 40)
        intervention.reportDate = "2026-09-22"
        intervention.title = "Intervention — Siège (imprimantes)"
        intervention.fileName = "rapport-intervention-siege-2026-09-22.pdf"
        var inventory = base
        inventory.id = inventaireID
        inventory.created = at(2026, 8, 12, 11, 5)
        inventory.reportDate = "2026-08-12"
        inventory.title = "Inventaire simple — Siège"
        inventory.fileName = "rapport-inventaire-siege-2026-08-12.csv"
        inventory.format = .csv
        inventory.scheduleName = "Inventaire mensuel"
        return ReportHistory(snapshots: [base, intervention, inventory])
    }

    /// Dernier rapport du Siège, d'après l'état actuel.
    static func baseSnapshot(_ current: ReportSnapshot?) -> ReportSnapshot {
        var devices = (current?.devices ?? []).filter { !newIPs.contains($0.ip.description) }
        // Changés : le poste de comptabilité était sur un autre port, l'imprimante HP sur une autre IP.
        for index in devices.indices {
            switch devices[index].ip.description {
            case "10.182.122.117": devices[index].switchLocation = "SW-CORE-01 · Gi1/0/21"
            case "10.182.122.140": devices[index].ip = IPv4Address("10.182.122.139")!
            default: break
            }
        }
        // Disparu : un poste retiré depuis.
        devices.append(ReportSnapshotDevice(key: InventoryStore.key(mac: MACAddress("B0:7B:25:44:B3:52")!), ip: IPv4Address("10.182.122.152")!,
                                            mac: MACAddress("B0:7B:25:44:B3:52"), name: "WKS352", type: .poste, isOnline: true,
                                            switchLocation: "SW-CORE-01 · Gi1/0/26", vlan: 1, openPorts: [135, 445]))
        // Problèmes : ceux d'aujourd'hui sauf un (nouveau depuis), plus deux réglés depuis.
        var issues = current?.issues ?? []
        if let fresh = issues.firstIndex(where: { $0.category == .surveillance && $0.severity == .moyen })
            ?? issues.firstIndex(where: { $0.category == .surveillance }) ?? (issues.isEmpty ? nil : issues.indices.last) {
            issues.remove(at: fresh)
        }
        let keys = Set(issues.map(\.key))
        let solved = [
            ReportIssue(key: "wan|tunnel|Siège|VPN-LAVAL", category: .wan, title: "Tunnel VPN-LAVAL tombé", severity: .critique),
            ReportIssue(key: "port|SW-ETG2-01|1/21", category: .port, title: "Port 1/21 de SW-ETG2-01 en erreur (2418 erreurs)",
                        severity: .moyen),
        ].filter { !keys.contains($0.key) }
        return ReportSnapshot(id: auditID, siteKey: SiteFiles.key(for: SitesDemo.siegeID), siteName: "Siège",
                              created: at(2026, 10, 6, 10, 14), reportDate: "2026-10-06", title: "Audit réseau — Siège",
                              fileName: "rapport-audit-siege-2026-10-06.pdf", format: .pdf, scanDate: at(2026, 10, 6, 9, 52),
                              devices: devices.sorted { $0.key < $1.key }, issues: issues + solved)
    }

    // MARK: Rapports planifiés

    static var schedules: [ReportSchedule] {
        let siege = SiteFiles.key(for: SitesDemo.siegeID)
        let laval = SiteFiles.key(for: SitesDemo.lavalID)
        let weekly = ReportSchedule(
            id: UUID(uuidString: "5A7E0042-0010-4C1E-9A11-00000000C001")!, name: "Suivi hebdomadaire — Siège", siteKeys: [siege],
            cadence: .weekly, weekday: 2, hour: 7, minute: 0,
            config: ReportConfig(template: .audit, sections: [.resume, .suivi, .problemes], client: "Groupe Exemple",
                                 technician: "Dany Ménard", format: .pdf),
            fileNamePattern: "suivi-{site}-{date}", email: .draft, emailTo: "direction@client-exemple.ca",
            activeSince: at(2026, 10, 1, 8, 0), lastSlot: at(2026, 11, 2, 7, 0), lastProduced: at(2026, 11, 2, 7, 0),
            lastStatus: .ok, lastMessage: "Rapport produit.", lastFiles: ["suivi-siege-2026-11-02.pdf"])
        let monthly = ReportSchedule(
            id: UUID(uuidString: "5A7E0042-0011-4C1E-9A11-00000000C002")!, name: "Inventaire mensuel — Entrepôt Laval", siteKeys: [laval],
            cadence: .monthly, monthDay: 1, hour: 6, minute: 30,
            config: ReportConfig(template: .inventaire, technician: "Dany Ménard", format: .csv),
            folder: NSHomeDirectory() + "/Documents/Clients/Entrepôt Laval", activeSince: at(2026, 9, 1, 8, 0),
            lastSlot: at(2026, 11, 1, 6, 30), lastProduced: at(2026, 11, 2, 8, 41), lastStatus: .ok,
            lastMessage: "Rapport produit (échéance du dimanche 1er novembre à 6\u{00A0}h\u{00A0}30 rattrapée).",
            lastFiles: ["rapport-inventaire-entrepot-laval-2026-11-01.csv"])
        return [weekly, monthly]
    }
}
