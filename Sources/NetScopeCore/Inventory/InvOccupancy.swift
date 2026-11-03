import Foundation

/// État d'une adresse dans la carte d'occupation d'un /24.
public enum InvCellState: String, Sendable, CaseIterable {
    case enLigne, horsLigne, libre, conflit, reseau

    public var label: String {
        switch self {
        case .enLigne: return "En ligne"
        case .horsLigne: return "Hors ligne (vu récemment)"
        case .libre: return "Libre"
        case .conflit: return "Conflit IP"
        case .reseau: return "Réseau / diffusion"
        }
    }
}

/// Carte d'occupation 16 × 16 d'un /24, calculée à partir des fiches d'inventaire.
public struct InvOccupancy: Sendable {
    public struct Cell: Hashable, Sendable, Identifiable {
        public var id: Int { index }
        public let index: Int
        public let ip: IPv4Address
        public let state: InvCellState
        /// Fiche la plus récente à cette adresse.
        public let recordKey: String?
    }

    public let network: Subnet
    public let cells: [Cell]

    /// - `recentWindow` : un appareil hors ligne vu depuis moins longtemps compte comme occupant.
    public init(network: IPv4Address, records: [InvRecord], now: Date = Date(), recentWindow: TimeInterval = 7 * 86_400) {
        let subnet = Subnet(address: network, prefix: 24)
        self.network = subnet
        var byIP: [UInt32: [InvRecord]] = [:]
        for record in records where subnet.contains(record.ip) {
            byIP[record.ip.value, default: []].append(record)
        }
        cells = (0..<256).map { index in
            let ip = IPv4Address(subnet.network.value + UInt32(index))
            if index == 0 || index == 255 {
                return Cell(index: index, ip: ip, state: .reseau, recordKey: nil)
            }
            let here = byIP[ip.value] ?? []
            let latest = here.max { $0.lastSeen < $1.lastSeen }
            let state: InvCellState
            if here.contains(where: \.hasConflict) || here.filter(\.isOnline).count > 1 {
                state = .conflit
            } else if here.contains(where: \.isOnline) {
                state = .enLigne
            } else if let latest, now.timeIntervalSince(latest.lastSeen) <= recentWindow {
                state = .horsLigne
            } else {
                state = .libre
            }
            return Cell(index: index, ip: ip, state: state, recordKey: (here.first(where: \.isOnline) ?? latest)?.key)
        }
    }

    public func count(_ state: InvCellState) -> Int { cells.filter { $0.state == state }.count }

    /// Adresses occupées (en ligne, hors ligne récents, conflits) sur les 254 utilisables.
    public var usedCount: Int { count(.enLigne) + count(.horsLigne) + count(.conflit) }
    public var usage: Double { Double(usedCount) / 254 }

    /// /24 distincts où se trouvent des fiches, triés.
    public static func networks(of records: [InvRecord]) -> [IPv4Address] {
        Set(records.map { $0.ip.value & 0xFFFF_FF00 }).sorted().map(IPv4Address.init)
    }
}
