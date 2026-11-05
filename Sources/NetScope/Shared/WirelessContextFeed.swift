import Foundation
import NetScopeCore

/// Note 84 : ce que l'application sait déjà du Wi-Fi du site actif (clients des bornes FortiAP lus
/// sur la FortiGate, voisins LLDP des switchs relevés, interface Wi-Fi de ce Mac), réuni pour
/// classer les appareils Wi-Fi ou filaires (`InvWireless`). Rien n'est lu sur le réseau ici : seules
/// les dernières lectures en mémoire servent.
@MainActor
enum WirelessContextFeed {
    /// Contexte du site actif, pour la fusion d'un scan, la sonde « Port de switch » et la carte
    /// d'occupation.
    static func current(devices: [Device], records: [InvRecord] = [], interface: LocalInterface?) -> InvWirelessContext {
        let overview = FortiAPStore.shared.overview
        let neighbors = InvWirelessContext.accessPointPorts(in: SwitchStore.shared.orderedSnapshots)
        let local: Set<IPv4Address> = interface.map { $0.kind == .wifi ? [$0.address] : [] } ?? []
        return InvWirelessContext(overview: overview.isEmpty ? nil : overview, devices: devices, records: records,
                                  neighborPorts: neighbors, localWifiIPs: local)
    }

    /// Contexte d'un site affiché (carte d'occupation) : celui du site actif, ou, pour un autre
    /// site, ses lectures Wi-Fi gardées en mémoire et ses fiches.
    static func forSite(_ key: String, records: [InvRecord], state: AppState) -> InvWirelessContext {
        let sites = SiteModel.shared
        if key == sites.activeKey { return current(devices: state.devices, records: records, interface: state.activeInterface) }
        let reports = FortiAPStore.shared.reports(forKey: key)
        let overview = reports.isEmpty ? nil : FortiWifiMerge.overview(reports)
        return InvWirelessContext(overview: overview, devices: [], records: records)
    }
}
