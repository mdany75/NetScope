import Foundation

// Note 83 : onglet Ports de Switchs et ports. Une ligne par port physique du switch choisi (relevé
// SNMP ou FortiSwitch lu par la FortiGate), avec les filtres « Tous, Actifs, Inactifs, PoE,
// Uplinks, Erreurs » et la recherche du tableau. Les erreurs sont les erreurs RÉCENTES (celles qui
// augmentent, PortErrorTracker), jamais le vieux total depuis le démarrage du switch.

/// État d'un port pour le tableau des ports (même règle que la façade).
public enum SwitchPortStatus: Int, CaseIterable, Sendable, Comparable {
    case active, uplink, errors, inactive, disabled

    public static func < (a: SwitchPortStatus, b: SwitchPortStatus) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .active: return "Actif"
        case .uplink: return "Uplink"
        case .errors: return "Erreurs"
        case .inactive: return "Inactif"
        case .disabled: return "Désactivé"
        }
    }
}

/// Un port du switch dans l'onglet Ports.
public struct SwitchPortRow: Identifiable, Hashable, Sendable {
    public var id: Int { ifIndex }
    public var ifIndex: Int
    public var name: String
    public var alias: String
    public var status: SwitchPortStatus
    public var adminUp: Bool
    public var operStatus: SNMPOperStatus
    public var speedMbps: UInt64?
    public var isUplink: Bool
    /// VLAN natif ou d'accès (dot1qPvid, VLAN natif de la FortiGate).
    public var nativeVLAN: Int?
    /// VLAN vus sur le port (table MAC), triés.
    public var vlans: [Int]
    public var poeDelivering: Bool
    public var poeWatts: Double?
    public var poeFault: Bool
    /// Adresses MAC apprises sur le port (ordre du relevé).
    public var macs: [MACAddress]
    public var neighborName: String?
    public var neighborPort: String?
    /// Erreurs en entrée apparues sur la fenêtre de suivi ; nil tant qu'il n'y a pas de base.
    public var newErrors: UInt64?
    /// Durée couverte par `newErrors`, en secondes.
    public var errorSeconds: TimeInterval?
    /// Total depuis le démarrage du switch (ifInErrors).
    public var totalErrors: UInt64?
    public var lastChangeTicks: UInt32?

    public var isUp: Bool { adminUp && operStatus == .up }
    public var macCount: Int { macs.count }
    /// Port à signaler : ses erreurs augmentent (au moins `PortErrorTracker.threshold`).
    public var hasRecentErrors: Bool { (newErrors ?? 0) >= PortErrorTracker.threshold }

    /// « Accès 30 », « Trunk · natif 1 · 10,20,30 », « — ».
    public var vlanText: String {
        if isUplink {
            let list = vlans.isEmpty ? "" : " · " + vlans.map(String.init).joined(separator: ",")
            return "Trunk" + (nativeVLAN.map { " · natif \($0)" } ?? "") + list
        }
        return nativeVLAN.map { "Accès \($0)" } ?? (vlans.first.map { "Accès \($0)" } ?? "—")
    }

    /// Clé de tri du VLAN (absent en dernier).
    public var vlanSort: Int { nativeVLAN ?? vlans.first ?? Int.max }
}

/// Filtre de l'onglet Ports.
public enum SwitchPortFilter: String, CaseIterable, Sendable {
    case all, active, inactive, poe, uplinks, errors

    public var label: String {
        switch self {
        case .all: return "Tous"
        case .active: return "Actifs"
        case .inactive: return "Inactifs"
        case .poe: return "PoE"
        case .uplinks: return "Uplinks"
        case .errors: return "Erreurs"
        }
    }

    public func matches(_ row: SwitchPortRow) -> Bool {
        switch self {
        case .all: return true
        case .active: return row.isUp
        case .inactive: return !row.isUp
        case .poe: return row.poeDelivering
        case .uplinks: return row.isUplink
        case .errors: return row.hasRecentErrors
        }
    }

    /// Captures (NETSCOPE_SWITCH_PORTS) : « erreurs », « poe », « actifs »…
    public init?(capture text: String) {
        switch SearchText.fold(text.trimmingCharacters(in: .whitespaces)) {
        case "tous", "all": self = .all
        case "actifs", "actif", "active": self = .active
        case "inactifs", "inactif", "inactive": self = .inactive
        case "poe": self = .poe
        case "uplinks", "uplink", "trunk", "trunks": self = .uplinks
        case "erreurs", "erreur", "errors": self = .errors
        default: return nil
        }
    }
}

public enum SwitchPortRows {
    /// Lignes des ports physiques du switch, dans l'ordre des ifIndex.
    public static func make(_ snapshot: SNMPSwitchSnapshot, recent: SwitchRecentErrors = .none) -> [SwitchPortRow] {
        let uplinks = snapshot.locatedUplinks
        var macsByPort: [Int: [MACAddress]] = [:]
        var vlansByPort: [Int: Set<Int>] = [:]
        for entry in snapshot.fdb {
            guard let index = entry.ifIndex else { continue }
            macsByPort[index, default: []].append(entry.mac)
            if let vlan = entry.vlan { vlansByPort[index, default: []].insert(vlan) }
        }
        return snapshot.physicalPorts.map { iface in
            let isUplink = uplinks.contains(iface.index)
            let delta = recent.ports[iface.index]
            let status: SwitchPortStatus
            if !iface.adminUp { status = .disabled }
            else if iface.operStatus != .up { status = .inactive }
            else if recent.isAlert(iface.index) { status = .errors }
            else if isUplink { status = .uplink }
            else { status = .active }
            let poe = snapshot.poePort(iface.index)
            let neighbor = snapshot.neighbor(on: iface.index)
            return SwitchPortRow(
                ifIndex: iface.index, name: iface.name, alias: iface.alias, status: status,
                adminUp: iface.adminUp, operStatus: iface.operStatus, speedMbps: iface.speedMbps, isUplink: isUplink,
                nativeVLAN: snapshot.pvid[iface.index], vlans: (vlansByPort[iface.index] ?? []).sorted(),
                poeDelivering: poe?.isDelivering == true, poeWatts: poe?.isDelivering == true ? poe?.consumptionW : nil,
                poeFault: poe?.detection?.isFault == true,
                macs: macsByPort[iface.index] ?? [],
                neighborName: neighbor?.sysName, neighborPort: neighbor?.portID,
                newErrors: recent.hasBaseline ? (delta?.newErrors ?? 0) : nil,
                errorSeconds: delta?.seconds ?? (recent.hasBaseline ? recent.seconds : nil),
                totalErrors: iface.inErrors, lastChangeTicks: iface.lastChangeTicks)
        }
    }

    /// Nombre de ports par filtre (compteurs des boutons du filtre).
    public static func counts(_ rows: [SwitchPortRow]) -> [SwitchPortFilter: Int] {
        var result: [SwitchPortFilter: Int] = [:]
        for filter in SwitchPortFilter.allCases { result[filter] = rows.filter(filter.matches).count }
        return result
    }

    /// Lignes retenues par le filtre et le texte du champ « Filtrer » (tous les mots doivent se
    /// retrouver dans le port, sa description, son VLAN, son voisin ou son état).
    /// `keep` : port toujours gardé (port choisi depuis un autre onglet).
    public static func filter(_ rows: [SwitchPortRow], by filter: SwitchPortFilter, text: String = "",
                              keep: Int? = nil) -> [SwitchPortRow] {
        let words = SearchText.fold(text).split(whereSeparator: { $0 == " " }).map(String.init)
        return rows.filter { row in
            if row.ifIndex == keep { return true }
            guard filter.matches(row) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = SearchText.fold([row.name, row.alias, row.vlanText, row.status.label,
                                             row.neighborName ?? "", row.neighborPort ?? "",
                                             row.poeDelivering ? "poe" : ""].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Ports dont les erreurs augmentent, du plus touché au moins touché.
    public static func errorPorts(_ rows: [SwitchPortRow]) -> [SwitchPortRow] {
        rows.filter(\.hasRecentErrors).sorted { ($0.newErrors ?? 0, $1.ifIndex) > ($1.newErrors ?? 0, $0.ifIndex) }
    }
}
