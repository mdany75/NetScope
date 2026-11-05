import Foundation

// Note 78 (Carte du réseau) : filtre par VLAN. Les appareils finaux d'un autre VLAN sont retirés
// de la carte ; l'infrastructure (passerelle, switchs, points d'accès) reste dessinée, et celle qui
// ne porte pas le VLAN choisi est atténuée. Un équipement porte un VLAN s'il dessert un appareil
// de ce VLAN (lui ou un nœud en dessous), si le VLAN est vu sur un de ses liens LLDP, ou si c'est
// son propre VLAN (gestion).

public enum TopoVLANFilter: Hashable, Sendable {
    case all
    case vlan(Int)
    /// Appareils dont le VLAN n'est pas connu.
    case unknown

    public var isAll: Bool { self == .all }

    /// Valeur des captures (NETSCOPE_CARTE_VLAN=40, « inconnu ») ; nil si illisible.
    public init?(captureValue: String) {
        let value = captureValue.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value == "tous" { self = .all; return }
        if value == "inconnu" || value == "aucun" { self = .unknown; return }
        guard let number = Int(value), (1...4094).contains(number) else { return nil }
        self = .vlan(number)
    }

    /// Vrai si l'appareil final est gardé par ce filtre.
    public func keeps(_ device: Device) -> Bool {
        switch self {
        case .all: return true
        case .vlan(let vlan): return device.vlan == vlan
        case .unknown: return device.vlan == nil
        }
    }
}

public enum TopoVLAN {
    /// Un VLAN proposé par le filtre, avec le nombre d'appareils finaux.
    public struct Choice: Hashable, Sendable, Identifiable {
        public var filter: TopoVLANFilter
        public var deviceCount: Int
        public var id: String {
            switch filter {
            case .all: return "tous"
            case .vlan(let vlan): return "\(vlan)"
            case .unknown: return "inconnu"
            }
        }
    }

    /// Équipement d'infrastructure : toujours dessiné, quel que soit le filtre.
    public static func isInfrastructure(_ device: Device, gateway: IPv4Address?) -> Bool {
        if let gateway, device.ip == gateway { return true }
        return [.switch, .pointAcces, .routeur].contains(device.deviceType)
    }

    /// Appareils gardés par le filtre : l'infrastructure, et les appareils finaux du VLAN choisi.
    public static func filter(_ devices: [Device], _ filter: TopoVLANFilter, gateway: IPv4Address?) -> [Device] {
        guard !filter.isAll else { return devices }
        return devices.filter { isInfrastructure($0, gateway: gateway) || filter.keeps($0) }
    }

    /// VLAN proposés : ceux des appareils finaux (avec leur nombre) et ceux vus sur les liens LLDP,
    /// dans l'ordre des numéros ; « VLAN inconnu » à la fin s'il sert.
    public static func choices(_ devices: [Device], links: [TopoInfraLink] = [], gateway: IPv4Address?) -> [Choice] {
        var counts: [Int: Int] = [:]
        var unknown = 0
        for device in devices where !isInfrastructure(device, gateway: gateway) {
            if let vlan = device.vlan { counts[vlan, default: 0] += 1 } else { unknown += 1 }
        }
        for link in links { for vlan in link.vlans where counts[vlan] == nil { counts[vlan] = 0 } }
        var result = counts.keys.sorted().map { Choice(filter: .vlan($0), deviceCount: counts[$0] ?? 0) }
        if unknown > 0 { result.append(Choice(filter: .unknown, deviceCount: unknown)) }
        return result
    }
}

public extension TopoGraph {
    /// Nœuds qui portent le VLAN du filtre (tous avec `.all`). Internet et la passerelle en font
    /// toujours partie ; un nœud qui dessert un appareil du VLAN fait remonter toute sa branche.
    func nodesCarrying(_ filter: TopoVLANFilter, devices: [Device]) -> Set<String> {
        guard !filter.isAll else { return Set(nodes.map(\.id)) }
        let index = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parent = Dictionary(nodes.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        var result: Set<String> = [rootID, "passerelle"]
        func mark(_ id: String) {
            var current: String? = id
            while let step = current, result.insert(step).inserted {
                current = parent[step] ?? nil
            }
        }
        for node in nodes {
            let members = node.deviceIDs.compactMap { index[$0] }
            if node.kind == .groupe || node.kind == .appareil {
                // Appareils finaux : déjà filtrés, ils portent le VLAN.
                if members.contains(where: filter.keeps) { mark(node.id) }
            } else if case .vlan = filter, members.contains(where: filter.keeps) {
                // VLAN de gestion de l'équipement lui-même.
                mark(node.id)
            }
        }
        if case .vlan(let vlan) = filter {
            for link in infraLinks where link.vlans.contains(vlan) {
                mark(link.aID)
                mark(link.bID)
            }
        }
        return result
    }
}
