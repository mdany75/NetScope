import Foundation
import NetScopeCore

/// Note 78 : démonstration de la Carte du réseau. Les liens LLDP viennent des relevés fictifs de
/// SwitchDemo (SW-CORE-01 ↔ SW-ETG2-01, FortiGate, borne) et de la FortiGate de démonstration
/// (FortiLink et ISL des FortiSwitch) : aucun réseau.
///
/// Captures : NETSCOPE_CARTE_VLAN=40 filtre la carte sur un VLAN ; NETSCOPE_CARTE_DEPLACES=1 place
/// quelques nœuds à la main (positions décalées de la disposition automatique, jamais écrites).
enum TopoDemo {
    static var showsMovedNodes: Bool {
        ProcessInfo.processInfo.environment["NETSCOPE_CARTE_DEPLACES"].map { !$0.isEmpty && $0 != "0" } ?? false
    }

    /// Décalages des nœuds placés à la main, par rapport à la disposition automatique.
    private static let offsets: [String: (dx: Double, dy: Double)] = [
        "sw:fsw-entrepot": (dx: 110, dy: -12),     // FortiSwitch de l'entrepôt, décalé à droite
        "internet": (dx: -230, dy: 0),             // Internet, à gauche de la passerelle
    ]

    /// Anneau de FortiSwitch : en plus des ISL vers FSW-ENTREPOT, un câble de secours relie
    /// FSW-QUAI (port26) à FSW-SERVEURS (port9) ; la carte le montre comme lien redondant. Ajouté aux
    /// relevés de la démonstration pour la carte seulement.
    static func withRing(_ snapshots: [SNMPSwitchSnapshot]) -> [SNMPSwitchSnapshot] {
        let ring: [String: (port: Int, peer: String, speed: UInt64)] = [
            "FSW-QUAI": (port: 26, peer: "FSW-SERVEURS", speed: 1000),
            "FSW-SERVEURS": (port: 9, peer: "FSW-QUAI", speed: 1000),
        ]
        guard snapshots.contains(where: { $0.displayName == "FSW-QUAI" }),
              snapshots.contains(where: { $0.displayName == "FSW-SERVEURS" }) else { return snapshots }
        return snapshots.map { snapshot in
            guard let link = ring[snapshot.displayName], !snapshot.neighbors.contains(where: { $0.ifIndex == link.port }) else { return snapshot }
            var copy = snapshot
            if let index = copy.interfaces.firstIndex(where: { $0.index == link.port }) {
                copy.interfaces[index].operStatus = .up
                copy.interfaces[index].speedMbps = link.speed
                copy.interfaces[index].alias = "ISL de secours vers \(link.peer)"
            }
            copy.pvid[link.port] = 1
            copy.neighbors.append(SNMPLLDPNeighbor(localPortNum: link.port, ifIndex: link.port, sysName: link.peer, portID: "ISL",
                                                   portDescr: "ISL", sysDescr: "Lien inter-switch (ISL)", capabilities: [.bridge]))
            return copy
        }
    }

    /// Positions des nœuds déplacés de la démonstration (vide sans NETSCOPE_CARTE_DEPLACES).
    static func movedPositions(_ layout: TopoGraph.Layout) -> [String: TopoGraph.Point] {
        guard showsMovedNodes else { return [:] }
        var result: [String: TopoGraph.Point] = [:]
        for (id, offset) in offsets {
            guard let point = layout.positions[id] else { continue }
            result[id] = TopoGraph.Point(x: point.x + offset.dx, y: point.y + offset.dy)
        }
        return result
    }
}
