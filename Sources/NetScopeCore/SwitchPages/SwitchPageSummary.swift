import Foundation

// Note 83 : tuiles de résumé, appareils par VLAN (onglet Appareils) et voisins LLDP (onglet
// Voisins et liens) de Switchs et ports, calculés sur les relevés déjà faits (rien n'est interrogé).

// MARK: - Appareils par VLAN

/// Un VLAN du switch : appareils en accès, ports d'accès et trunks qui le portent.
public struct SwitchVLANUsage: Identifiable, Hashable, Sendable {
    public var id: Int { vlan }
    public var vlan: Int
    /// Adresses MAC distinctes apprises sur des ports d'accès de ce VLAN.
    public var devices: Int
    /// Ports d'accès (non uplink) de ce VLAN, dans l'ordre des ifIndex.
    public var accessPorts: [String]
    /// Uplinks et trunks où des adresses de ce VLAN sont apprises.
    public var trunkPorts: [String]
}

public enum SwitchVLANSummary {
    /// VLAN du switch, du plus peuplé au moins peuplé (puis par numéro).
    public static func make(_ snapshot: SNMPSwitchSnapshot) -> [SwitchVLANUsage] {
        let uplinks = snapshot.locatedUplinks
        let order = Dictionary(uniqueKeysWithValues: snapshot.physicalPorts.enumerated().map { ($1.index, $0) })
        var macs: [Int: Set<MACAddress>] = [:]
        var access: [Int: Set<Int>] = [:]
        var trunks: [Int: Set<Int>] = [:]
        for entry in snapshot.fdb {
            guard let index = entry.ifIndex, let vlan = entry.vlan ?? snapshot.pvid[index] else { continue }
            if uplinks.contains(index) {
                trunks[vlan, default: []].insert(index)
            } else {
                macs[vlan, default: []].insert(entry.mac)
                access[vlan, default: []].insert(index)
            }
        }
        // Ports d'accès sans appareil appris : ils comptent quand même dans leur VLAN natif.
        for iface in snapshot.physicalPorts where !uplinks.contains(iface.index) && iface.isUp {
            if let vlan = snapshot.pvid[iface.index] { access[vlan, default: []].insert(iface.index) }
        }
        let vlans = Set(macs.keys).union(access.keys).union(trunks.keys)
        func names(_ indexes: Set<Int>?) -> [String] {
            (indexes ?? []).sorted { (order[$0] ?? $0) < (order[$1] ?? $1) }
                .map { snapshot.interface($0)?.name ?? "\($0)" }
        }
        return vlans.map { vlan in
            SwitchVLANUsage(vlan: vlan, devices: macs[vlan]?.count ?? 0, accessPorts: names(access[vlan]), trunkPorts: names(trunks[vlan]))
        }
        .sorted { ($0.devices, $1.vlan) > ($1.devices, $0.vlan) }
    }
}

// MARK: - Voisins et liens

/// Nature d'un voisin LLDP (ou d'un lien FortiLink / inter-switch d'un FortiSwitch).
public enum SwitchLinkKind: String, CaseIterable, Sendable {
    case interSwitch, fortiLink, bridge, router, accessPoint, phone, station, other

    public var label: String {
        switch self {
        case .interSwitch: return "Lien entre switchs"
        case .fortiLink: return "FortiLink"
        case .bridge: return "Switch non relevé"
        case .router: return "Routeur ou pare-feu"
        case .accessPoint: return "Point d’accès"
        case .phone: return "Téléphone IP"
        case .station: return "Poste"
        case .other: return "Équipement"
        }
    }

    /// Lien d'infrastructure (vers un switch, un routeur, la FortiGate).
    public var isInfrastructure: Bool {
        switch self {
        case .interSwitch, .fortiLink, .bridge, .router: return true
        case .accessPoint, .phone, .station, .other: return false
        }
    }
}

/// Un voisin vu par un switch, sur un de ses ports.
public struct SwitchNeighborRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var switchHost: String
    public var switchName: String
    public var ifIndex: Int?
    public var localPort: String
    public var neighborName: String
    public var neighborPort: String
    public var neighborPortDescr: String?
    public var capabilities: [String]
    public var platform: String?
    public var kind: SwitchLinkKind
    /// Le port local est un uplink (même règle que la localisation).
    public var isUplink: Bool
    public var speedMbps: UInt64?
    /// Switch relevé qui correspond au voisin (adresse du relevé), pour l'ouvrir d'un clic.
    public var neighborHost: String?
}

public enum SwitchNeighborRows {
    /// Nom court sans le domaine, en minuscules (« sw-core-01.siege.local » → « sw-core-01 »).
    static func short(_ name: String) -> String {
        name.lowercased().split(separator: ".").first.map(String.init) ?? name.lowercased()
    }

    /// Voisins de tous les switchs donnés : par switch (ordre donné), puis par port.
    public static func make(_ snapshots: [SNMPSwitchSnapshot]) -> [SwitchNeighborRow] {
        var byName: [String: String] = [:]
        for snapshot in snapshots { byName[short(snapshot.displayName)] = byName[short(snapshot.displayName)] ?? snapshot.id }
        var rows: [SwitchNeighborRow] = []
        for snapshot in snapshots {
            let uplinks = snapshot.locatedUplinks
            let order = Dictionary(uniqueKeysWithValues: snapshot.physicalPorts.enumerated().map { ($1.index, $0) })
            let neighbors = snapshot.neighbors.sorted {
                (order[$0.ifIndex ?? -1] ?? Int.max, $0.localPortNum) < (order[$1.ifIndex ?? -1] ?? Int.max, $1.localPortNum)
            }
            for neighbor in neighbors {
                let iface = neighbor.ifIndex.flatMap { snapshot.interface($0) }
                let known = byName[short(neighbor.sysName)].flatMap { $0 == snapshot.id ? nil : $0 }
                rows.append(SwitchNeighborRow(
                    id: "\(snapshot.id)|\(neighbor.ifIndex ?? -neighbor.localPortNum)|\(neighbor.sysName)|\(neighbor.portID)",
                    switchHost: snapshot.id, switchName: snapshot.displayName, ifIndex: neighbor.ifIndex,
                    localPort: iface?.name ?? "port \(neighbor.localPortNum)",
                    neighborName: neighbor.sysName, neighborPort: neighbor.portID,
                    neighborPortDescr: neighbor.portDescr == neighbor.portID ? nil : neighbor.portDescr,
                    capabilities: neighbor.capabilities?.labels ?? [], platform: neighbor.sysDescr,
                    kind: kind(neighbor, knownSwitch: known != nil),
                    isUplink: neighbor.ifIndex.map(uplinks.contains) ?? false,
                    speedMbps: iface.flatMap { $0.isUp ? $0.speedMbps : nil }, neighborHost: known))
            }
        }
        return rows
    }

    /// Nature du voisin : FortiLink, switch relevé, puis capacités LLDP annoncées.
    public static func kind(_ neighbor: SNMPLLDPNeighbor, knownSwitch: Bool) -> SwitchLinkKind {
        if neighbor.portID == "FortiLink" { return .fortiLink }
        if knownSwitch { return .interSwitch }
        guard let caps = neighbor.capabilities, !caps.isEmpty else { return .other }
        if caps.contains(.telephone) { return .phone }
        if caps.contains(.accessPoint) { return .accessPoint }
        if caps.contains(.router) { return .router }
        if caps.contains(.bridge) || caps.contains(.repeater) { return .bridge }
        if caps.contains(.station) { return .station }
        return .other
    }

    /// Liens entre deux switchs relevés, comptés une seule fois (A ↔ B vu des deux côtés).
    public static func interSwitchLinks(_ rows: [SwitchNeighborRow]) -> Int {
        var pairs: Set<String> = []
        for row in rows where row.kind == .interSwitch || row.kind == .fortiLink {
            let ends = [short(row.switchName), short(row.neighborName)].sorted()
            pairs.insert(ends.joined(separator: "↔"))
        }
        return pairs.count
    }
}

// MARK: - Tuiles de résumé

/// Résumé des switchs affichés (tuiles sous le bandeau du site).
public struct SwitchPageSummary: Hashable, Sendable {
    /// Switchs du site (relevés ou non).
    public var switches: Int
    /// Switchs relevés (en ligne).
    public var answered: Int
    public var viaController: Int
    public var ports: Int
    public var activePorts: Int
    /// Ports dont les erreurs augmentent : « SW-CORE-01 · Gi1/0/7 ».
    public var errorPorts: [String]
    public var poeUsedW: Int
    public var poeBudgetW: Int
    /// Ports qui délivrent du courant.
    public var poePorts: Int
    /// Adresses MAC distinctes apprises sur des ports d'accès.
    public var devices: Int
    public var vlans: Int
    public var neighbors: Int
    public var interSwitchLinks: Int

    /// Part du budget PoE utilisée (nil sans budget publié).
    public var poeFraction: Double? { poeBudgetW > 0 ? Double(poeUsedW) / Double(poeBudgetW) : nil }

    /// - `hosts` : nombre de switchs du site ; `recent` : erreurs récentes par adresse de switch.
    public static func make(_ snapshots: [SNMPSwitchSnapshot], hosts: Int,
                            recent: [String: SwitchRecentErrors] = [:]) -> SwitchPageSummary {
        var summary = SwitchPageSummary(switches: max(hosts, snapshots.count), answered: snapshots.count,
                                        viaController: snapshots.filter(\.isViaController).count,
                                        ports: 0, activePorts: 0, errorPorts: [], poeUsedW: 0, poeBudgetW: 0, poePorts: 0,
                                        devices: 0, vlans: 0, neighbors: 0, interSwitchLinks: 0)
        var macs: Set<MACAddress> = []
        var vlans: Set<Int> = []
        for snapshot in snapshots {
            let rows = SwitchPortRows.make(snapshot, recent: recent[snapshot.id] ?? .none)
            summary.ports += rows.count
            summary.activePorts += rows.filter(\.isUp).count
            summary.poePorts += rows.filter(\.poeDelivering).count
            summary.errorPorts += SwitchPortRows.errorPorts(rows).map { "\(snapshot.displayName) · \($0.name)" }
            if let budget = snapshot.poeBudgetW, budget > 0 {
                summary.poeBudgetW += budget
                summary.poeUsedW += snapshot.poeUsedW ?? 0
            }
            let uplinks = snapshot.locatedUplinks
            for entry in snapshot.fdb {
                guard let index = entry.ifIndex, !uplinks.contains(index) else { continue }
                macs.insert(entry.mac)
                if let vlan = entry.vlan ?? snapshot.pvid[index] { vlans.insert(vlan) }
            }
        }
        summary.devices = macs.count
        summary.vlans = vlans.count
        let neighbors = SwitchNeighborRows.make(snapshots)
        summary.neighbors = neighbors.count
        summary.interSwitchLinks = SwitchNeighborRows.interSwitchLinks(neighbors)
        return summary
    }
}
