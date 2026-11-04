import Foundation
import NetScopeCore

/// PoE de démonstration (note 12), cohérent avec SwitchDemo et le croquis Switch.dc.html :
/// SW-CORE-01 (Catalyst 9300-48P, watts par CISCO-POWER-ETHERNET-EXT-MIB) et SW-ETG2-01
/// (Aruba 2930F PoE+, watts par HP-ICF-POE-MIB). Aucun accès réseau.
enum PoEDemo {
    /// Watts consommés et classe des ports qui alimentent, par switch et ifIndex.
    private static let corePowered: [Int: (class: Int, mw: Int)] = [
        12: (4, 18_400),                               // FortiAP-231F (802.3at)
        13: (2, 5_400), 14: (2, 5_800), 15: (2, 6_200), 25: (2, 5_400), 26: (2, 5_800), 29: (2, 5_800), 31: (2, 6_200),
        33: (3, 6_800), 34: (3, 7_100),                // caméras quai et cour
    ]
    private static let etgPowered: [Int: (class: Int, mw: Int)] = [
        4: (3, 5_800), 5: (3, 6_200), 6: (3, 6_600),  // caméras de l'étage 2
        9: (3, 9_600),                                 // affichage dynamique du hall
        10: (2, 4_600), 15: (2, 4_100), 16: (2, 3_900), // téléphones IP Yealink (note 30)
    ]

    /// Ports PSE d'un relevé fictif : tous les ports cuivre du switch (les SFP+ n'en sont pas).
    static func details(for snapshot: SNMPSwitchSnapshot) -> [SNMPPoEPort] {
        let isCore = snapshot.system.name == "SW-CORE-01"
        let powered = isCore ? corePowered : etgPowered
        return snapshot.physicalPorts.filter { !$0.isModular }.enumerated().map { offset, iface in
            let port = offset + 1
            var row = SNMPPoEPort(group: 1, port: port, ifIndex: iface.index, adminEnabled: iface.adminUp,
                                  detection: iface.adminUp ? .searching : .disabled, powerClass: 0)
            if let power = powered[iface.index] {
                row.detection = .deliveringPower
                row.powerClass = power.class
                row.consumptionMW = power.mw
                row.priority = power.class == 4 ? .high : (power.class == 2 ? .critical : .low)
                row.wattsSource = isCore ? "Cisco" : "HPE"
                if isCore { row.allocatedMW = [0, 4_000, 7_000, 15_400, 30_000][power.class] }
            } else if isCore {
                row.consumptionMW = 0
                row.wattsSource = "Cisco"
            }
            return row
        }
    }

    /// Ajoute le détail PoE aux relevés fictifs (ports qui alimentent recalculés à partir de lui).
    static func apply(to snapshots: [SNMPSwitchSnapshot]) -> [SNMPSwitchSnapshot] {
        snapshots.map { snapshot in
            var result = snapshot
            result.poeDetails = details(for: snapshot)
            result.poePorts = Set(result.poeDetails!.filter(\.isDelivering).compactMap(\.ifIndex))
            return result
        }
    }

    /// Ce que l'Aruba annonce sur la prise du bureau 214 (port 1/22) : port PoE+ 802.3at, aucun
    /// courant fourni (un Mac ne consomme pas de PoE).
    static let macPower = PoEPowerInfo(sources: [.lldp8023], role: .pse, supported: true, enabled: true,
                                       pairsControllable: false, powerPairs: 1, powerClass: 0, standard: .at, powerType: 2,
                                       powerSource: "Principale", priority: .low, requestedW: 0, allocatedW: 0)
}
