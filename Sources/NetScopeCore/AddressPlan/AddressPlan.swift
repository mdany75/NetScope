import Foundation

// Note 78 (Historique et adressage) : plan d'adressage d'un site. Carte d'occupation d'un bloc de
// /24 à /16, découpé en pages de /24 ; croisement des fiches d'inventaire (scan), des étendues,
// réservations et baux DHCP lus sur la FortiGate (DHCPScopeStore) et des plages exclues (note 82) ;
// « prochaine IP libre hors étendue DHCP » par sous-réseau. Fonctions pures, aucun réseau.
//
// État d'une adresse, du plus fort au plus faible : réseau ou diffusion du bloc ; conflit, en
// ligne, hors ligne vu récemment (fiches) ; bail DHCP actif sans fiche ; réservation DHCP (ou
// passerelle d'une étendue) ; plage exclue du scan (état inconnu) ; libre dans une étendue DHCP ;
// libre. Seule une adresse « libre » (hors étendue, jamais .0 ni .255) est proposée pour une IP fixe.

/// État d'une adresse du plan.
public enum AddressPlanState: String, Sendable, CaseIterable {
    case enLigne, horsLigne, conflit, bail, reservee, exclue, libreDHCP, libre, reseau

    public var label: String {
        switch self {
        case .enLigne: return "En ligne"
        case .horsLigne: return "Hors ligne (vu récemment)"
        case .conflit: return "Conflit IP"
        case .bail: return "Bail DHCP (pas vu au scan)"
        case .reservee: return "Réservée"
        case .exclue: return "Exclue du scan"
        case .libreDHCP: return "Libre dans l’étendue DHCP"
        case .libre: return "Libre"
        case .reseau: return "Réseau / diffusion"
        }
    }

    /// Libellé court de la légende.
    public var shortLabel: String {
        switch self {
        case .enLigne: return "En ligne"
        case .horsLigne: return "Hors ligne"
        case .conflit: return "Conflit"
        case .bail: return "Bail DHCP"
        case .reservee: return "Réservée"
        case .exclue: return "Exclue"
        case .libreDHCP: return "Libre (DHCP)"
        case .libre: return "Libre"
        case .reseau: return "Réseau"
        }
    }

    /// Adresse prise (comptée dans l'occupation).
    public var isUsed: Bool {
        switch self {
        case .enLigne, .horsLigne, .conflit, .bail, .reservee: return true
        case .exclue, .libreDHCP, .libre, .reseau: return false
        }
    }
}

/// Une adresse du plan, avec ce qu'on sait d'elle.
public struct AddressPlanCell: Hashable, Sendable, Identifiable {
    public var id: UInt32 { ip.value }
    public let ip: IPv4Address
    public let state: AddressPlanState
    /// Fiche la plus utile à cette adresse (en ligne, sinon la plus récente).
    public let recordKey: String?
    /// Dans la plage distribuable d'une étendue DHCP.
    public let inPool: Bool
    /// Nom de l'étendue qui couvre l'adresse (« VLAN 20 · Voix »).
    public let scopeName: String?
    public let lease: DHCPLeaseEntry?
    public let reservation: DHCPReservation?
    /// Passerelle d'une étendue DHCP.
    public let isGateway: Bool
    /// Plage exclue du site qui couvre l'adresse.
    public let exclusion: ExcludedRange?
}

/// Résumé d'une page (/24) du bloc.
public struct AddressPlanPage: Hashable, Sendable, Identifiable {
    public var id: UInt32 { base.value }
    public let base: IPv4Address
    public let counts: [AddressPlanState: Int]
    /// Adresses attribuables (hors réseau et diffusion du bloc).
    public let hosts: Int

    public func count(_ state: AddressPlanState) -> Int { counts[state] ?? 0 }
    public var used: Int { AddressPlanState.allCases.filter(\.isUsed).reduce(0) { $0 + count($1) } }
    public var usage: Double { hosts == 0 ? 0 : Double(used) / Double(hosts) }
    /// Une page sans rien de connu (ni fiche, ni DHCP, ni exclusion).
    public var isEmpty: Bool { used == 0 && count(.libreDHCP) == 0 && count(.exclue) == 0 }
    /// « 10.182.122.0/24 ».
    public var label: String { "\(base)/24" }
    /// « .122 » : troisième octet, pour la carte des pages.
    public var shortLabel: String { ".\(base.octets.2)" }
}

/// Étendue DHCP vue par le plan : plage distribuable, réservations, passerelle, baux actifs.
public struct AddressPlanDHCP: Sendable {
    public struct Scope: Sendable {
        public var name: String
        public var subnet: Subnet?
        public var vlan: Int?
        public var pool: DHCPAddressPool
        public var reservations: [DHCPReservation]
        public var gateway: IPv4Address?
        public var enabled: Bool
    }

    public var scopes: [Scope]
    /// Baux actifs, par adresse.
    public var leases: [UInt32: DHCPLeaseEntry]

    public init(scopes: [Scope] = [], leases: [UInt32: DHCPLeaseEntry] = [:]) {
        self.scopes = scopes
        self.leases = leases
    }

    public static let none = AddressPlanDHCP()

    /// Étendues d'une ou plusieurs lectures de FortiGate (baux actifs à `now` seulement). Une
    /// étendue désactivée garde ses réservations et sa passerelle, mais ne distribue rien.
    public init(reports: [DHCPScopeReadReport], now: Date = Date()) {
        var scopes: [Scope] = []
        var leases: [UInt32: DHCPLeaseEntry] = [:]
        for report in reports {
            for server in report.servers {
                let info = report.interfaces[server.interface]
                let vlan = info?.vlan ?? FortiParse.vlanID(fromName: server.interface)
                var name = vlan.map { "VLAN \($0)" } ?? server.interface
                if let alias = info?.alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty, alias.lowercased() != name.lowercased() {
                    name += " · " + alias
                }
                var subnet: Subnet?
                if let gateway = server.gateway, let prefix = server.netmask?.prefixLength {
                    subnet = Subnet(address: gateway, prefix: prefix)
                }
                scopes.append(Scope(name: name, subnet: subnet, vlan: vlan,
                                    pool: server.enabled ? DHCPScopeAnalysis.pool(of: server) : DHCPAddressPool(),
                                    reservations: server.reservations.filter(\.holdsAddress), gateway: server.gateway,
                                    enabled: server.enabled))
            }
            for lease in report.leases where lease.isActive(at: now) {
                if leases[lease.ip.value] == nil { leases[lease.ip.value] = lease }
            }
        }
        self.scopes = scopes
        self.leases = leases
    }

    func scope(containing ip: IPv4Address) -> Scope? {
        scopes.first { $0.pool.contains(ip) } ?? scopes.first { $0.subnet?.contains(ip) == true }
    }
}

/// Plan d'adressage d'un bloc (/16 à /24).
public struct AddressPlan: Sendable {
    public static let minPrefix = 16

    public let block: Subnet
    public let pages: [AddressPlanPage]
    private let byIP: [UInt32: [InvRecord]]
    private let dhcp: AddressPlanDHCP
    private let reservations: [UInt32: DHCPReservation]
    private let gateways: Set<UInt32>
    /// Adresses de réseau et de diffusion du bloc et des sous-réseaux connus qu'il contient.
    private let boundaries: Set<UInt32>
    private let exclusions: AddressExclusions
    private let now: Date
    private let recentWindow: TimeInterval

    /// - `block` : ramené entre /16 et /24 (un /25 devient son /24, un /12 son premier /16).
    /// - `subnets` : sous-réseaux connus (plages, étendues) ; leurs adresses de réseau et de
    ///   diffusion ne sont jamais libres, même dans un bloc plus grand.
    /// - `recentWindow` : un appareil hors ligne vu depuis moins longtemps occupe encore l'adresse.
    public init(block wanted: Subnet, records: [InvRecord], dhcp: AddressPlanDHCP = .none, exclusions: AddressExclusions = .none,
                subnets: [Subnet] = [], now: Date = Date(), recentWindow: TimeInterval = 7 * 86_400) {
        let prefix = min(24, max(Self.minPrefix, wanted.prefix))
        let block = Subnet(address: wanted.network, prefix: prefix)
        self.block = block
        var byIP: [UInt32: [InvRecord]] = [:]
        for record in records where block.contains(record.ip) {
            byIP[record.ip.value, default: []].append(record)
        }
        self.byIP = byIP
        self.dhcp = dhcp
        var reservations: [UInt32: DHCPReservation] = [:]
        var gateways = Set<UInt32>()
        for scope in dhcp.scopes {
            for reservation in scope.reservations where block.contains(reservation.ip) {
                if reservations[reservation.ip.value] == nil { reservations[reservation.ip.value] = reservation }
            }
            if let gateway = scope.gateway, block.contains(gateway) { gateways.insert(gateway.value) }
        }
        self.reservations = reservations
        self.gateways = gateways
        var boundaries = Set<UInt32>()
        for subnet in subnets + [block] where subnet.prefix <= 30 {
            if block.contains(subnet.network) { boundaries.insert(subnet.network.value) }
            if block.contains(subnet.broadcast) { boundaries.insert(subnet.broadcast.value) }
        }
        self.boundaries = boundaries
        self.exclusions = exclusions
        self.now = now
        self.recentWindow = recentWindow

        // Résumé de chaque page : un passage sur toutes les adresses du bloc (65 536 au plus).
        var pages: [AddressPlanPage] = []
        let first = block.network.value
        let pageCount = 1 << (24 - prefix)
        pages.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            let base = first + UInt32(index) << 8
            var counts: [AddressPlanState: Int] = [:]
            var hosts = 0
            for offset in 0..<UInt32(256) {
                let state = Self.state(at: IPv4Address(base + offset), boundaries: boundaries, byIP: byIP, dhcp: dhcp,
                                       reservations: reservations, gateways: gateways, exclusions: exclusions,
                                       now: now, recentWindow: recentWindow)
                counts[state, default: 0] += 1
                if state != .reseau { hosts += 1 }
            }
            pages.append(AddressPlanPage(base: IPv4Address(base), counts: counts, hosts: hosts))
        }
        self.pages = pages
    }

    // MARK: Lecture

    /// Nombre de pages (/24) du bloc.
    public var pageCount: Int { pages.count }

    public func count(_ state: AddressPlanState) -> Int { pages.reduce(0) { $0 + $1.count(state) } }
    public var used: Int { pages.reduce(0) { $0 + $1.used } }
    public var hosts: Int { pages.reduce(0) { $0 + $1.hosts } }
    public var usage: Double { hosts == 0 ? 0 : Double(used) / Double(hosts) }

    /// Page qui contient l'adresse (nil hors du bloc).
    public func page(containing address: IPv4Address) -> AddressPlanPage? {
        guard block.contains(address) else { return nil }
        return pages[Int((address.value - block.network.value) >> 8)]
    }

    /// Page à montrer d'abord : celle qui contient `preferred`, sinon la première occupée.
    public func defaultPage(preferring preferred: IPv4Address? = nil) -> AddressPlanPage {
        if let preferred, let page = page(containing: preferred) { return page }
        return pages.first { $0.used > 0 } ?? pages.first { !$0.isEmpty } ?? pages[0]
    }

    /// Les 256 adresses d'une page.
    public func cells(page base: IPv4Address) -> [AddressPlanCell] {
        let start = base.value & 0xFFFF_FF00
        return (0..<UInt32(256)).map { cell(IPv4Address(start + $0)) }
    }

    /// Détail d'une adresse.
    public func cell(_ ip: IPv4Address) -> AddressPlanCell {
        let state = Self.state(at: ip, boundaries: boundaries, byIP: byIP, dhcp: dhcp, reservations: reservations, gateways: gateways,
                               exclusions: exclusions, now: now, recentWindow: recentWindow)
        let here = byIP[ip.value] ?? []
        let record = here.first(where: \.isOnline) ?? here.max { $0.lastSeen < $1.lastSeen }
        let scope = dhcp.scope(containing: ip)
        return AddressPlanCell(ip: ip, state: state, recordKey: record?.key, inPool: scope?.pool.contains(ip) ?? false,
                               scopeName: scope?.name, lease: dhcp.leases[ip.value], reservation: reservations[ip.value],
                               isGateway: gateways.contains(ip.value), exclusion: exclusions.reason(for: ip))
    }

    /// Adresses libres hors étendue DHCP (candidates pour une IP fixe) d'un sous-réseau du bloc
    /// (tout le bloc par défaut), dans l'ordre. Jamais .0 ni .255 (refusées par certains appareils
    /// même dans un /23 ou plus grand).
    public func freeAddresses(in subnet: Subnet? = nil, limit: Int = .max) -> [IPv4Address] {
        let area = subnet ?? block
        let low = max(area.network.value, block.network.value)
        let high = min(area.broadcast.value, block.broadcast.value)
        guard low <= high, limit > 0 else { return [] }
        var result: [IPv4Address] = []
        var value = low
        while true {
            let last = value & 0xFF
            if last != 0, last != 255, value != area.network.value, value != area.broadcast.value {
                let ip = IPv4Address(value)
                if Self.state(at: ip, boundaries: boundaries, byIP: byIP, dhcp: dhcp, reservations: reservations, gateways: gateways,
                              exclusions: exclusions, now: now, recentWindow: recentWindow) == .libre {
                    result.append(ip)
                    if result.count >= limit { break }
                }
            }
            if value == high { break }
            value += 1
        }
        return result
    }

    /// Prochaine IP libre hors étendue DHCP (nil : aucune).
    public func nextFree(in subnet: Subnet? = nil) -> IPv4Address? { freeAddresses(in: subnet, limit: 1).first }

    // MARK: Calcul d'une adresse

    static func state(at ip: IPv4Address, boundaries: Set<UInt32>, byIP: [UInt32: [InvRecord]], dhcp: AddressPlanDHCP,
                      reservations: [UInt32: DHCPReservation], gateways: Set<UInt32>, exclusions: AddressExclusions,
                      now: Date, recentWindow: TimeInterval) -> AddressPlanState {
        if boundaries.contains(ip.value) { return .reseau }
        let here = byIP[ip.value] ?? []
        if !here.isEmpty {
            if here.contains(where: \.hasConflict) || here.filter(\.isOnline).count > 1 { return .conflit }
            if here.contains(where: \.isOnline) { return .enLigne }
            if let latest = here.max(by: { $0.lastSeen < $1.lastSeen }), now.timeIntervalSince(latest.lastSeen) <= recentWindow {
                return .horsLigne
            }
        }
        if dhcp.leases[ip.value] != nil { return .bail }
        if reservations[ip.value] != nil || gateways.contains(ip.value) { return .reservee }
        if !exclusions.isEmpty, exclusions.contains(ip) { return .exclue }
        if dhcp.scopes.contains(where: { $0.pool.contains(ip) }) { return .libreDHCP }
        return .libre
    }
}

// MARK: - Sous-réseaux d'un site

/// Sous-réseau connu d'un site : plage du Scanner, étendue DHCP (passerelle et masque) ou /24 où
/// l'inventaire a des fiches.
public struct AddressPlanSubnet: Hashable, Sendable, Identifiable {
    public var id: String { subnet.description }
    public var subnet: Subnet
    /// Libellés (plage du site, étendue DHCP), sans doublon.
    public var labels: [String]
    public var vlan: Int?
    /// Étendue DHCP qui le couvre (« VLAN 20 · Voix »).
    public var dhcpName: String?
    /// Plages distribuables de l'étendue (« 10.0.0.100 – 10.0.0.199 »).
    public var dhcpRanges: [DHCPAddressRange]

    public init(subnet: Subnet, labels: [String] = [], vlan: Int? = nil, dhcpName: String? = nil, dhcpRanges: [DHCPAddressRange] = []) {
        self.subnet = subnet
        self.labels = labels
        self.vlan = vlan
        self.dhcpName = dhcpName
        self.dhcpRanges = dhcpRanges
    }

    /// « Bureau · VLAN 1 ».
    public var label: String {
        var parts = labels
        if let vlan, !parts.contains(where: { $0.contains("VLAN \(vlan)") }) { parts.append("VLAN \(vlan)") }
        return parts.joined(separator: " · ")
    }

    /// « 10.0.0.100 – 199 » (abrégé quand les trois premiers octets sont communs).
    public var dhcpRangesLabel: String {
        guard !dhcpRanges.isEmpty else { return "—" }
        return dhcpRanges.map { r in
            let a = r.start.octets, b = r.end.octets
            if r.start == r.end { return r.start.description }
            if a.0 == b.0 && a.1 == b.1 && a.2 == b.2 { return "\(r.start) – \(b.3)" }
            return r.description
        }.joined(separator: ", ")
    }

    /// Sous-réseaux d'un site, triés : plages du Scanner (CIDR de /16 à /30 ; un intervalle donne
    /// le /24 de son début), étendues DHCP, puis les /24 des fiches qui ne sont dans aucun.
    public static func list(ranges: [ScanRangeConfig], dhcp: [DHCPScopeReadReport], records: [InvRecord]) -> [AddressPlanSubnet] {
        var result: [AddressPlanSubnet] = []
        func merge(_ subnet: Subnet, label: String?, vlan: Int?, dhcpName: String? = nil, dhcpRanges: [DHCPAddressRange] = []) {
            guard (AddressPlan.minPrefix...30).contains(subnet.prefix) else { return }
            if let index = result.firstIndex(where: { $0.subnet == subnet }) {
                if let label, !label.isEmpty, !result[index].labels.contains(label) { result[index].labels.append(label) }
                if result[index].vlan == nil { result[index].vlan = vlan }
                if result[index].dhcpName == nil, let dhcpName {
                    result[index].dhcpName = dhcpName
                    result[index].dhcpRanges = dhcpRanges
                }
            } else {
                result.append(AddressPlanSubnet(subnet: subnet, labels: label.map { $0.isEmpty ? [] : [$0] } ?? [], vlan: vlan,
                                                dhcpName: dhcpName, dhcpRanges: dhcpRanges))
            }
        }
        for config in ranges {
            guard let range = try? config.parsed() else { continue }
            let label = config.label.trimmingCharacters(in: .whitespaces)
            for segment in range.segments {
                switch segment {
                case .cidr(let subnet): merge(subnet, label: label, vlan: config.vlan)
                case .span(let a, _), .single(let a): merge(Subnet(address: a, prefix: 24), label: label, vlan: config.vlan)
                }
            }
        }
        let plan = AddressPlanDHCP(reports: dhcp)
        for scope in plan.scopes {
            let subnet = scope.subnet ?? scope.pool.intervals.first.map { Subnet(address: $0.start, prefix: 24) }
            guard let subnet else { continue }
            merge(subnet, label: nil, vlan: scope.vlan, dhcpName: scope.name + (scope.enabled ? "" : " (désactivée)"),
                  dhcpRanges: scope.pool.intervals)
        }
        // Fiche sans adresse (0.0.0.0, ajoutée à la main) : aucun sous-réseau.
        for record in records where record.ip.octets.0 != 0 {
            let page = Subnet(address: record.ip, prefix: 24)
            if !result.contains(where: { $0.subnet.contains(record.ip) }) { merge(page, label: nil, vlan: nil) }
        }
        return result.sorted { ($0.subnet.network, $0.subnet.prefix) < ($1.subnet.network, $1.subnet.prefix) }
    }

    /// Plus petit sous-réseau connu de /16 à /23 qui contient ce /24 (bloc proposé pour la carte).
    public static func enclosingBlock(of page: IPv4Address, in subnets: [AddressPlanSubnet]) -> Subnet? {
        subnets.map(\.subnet).filter { (AddressPlan.minPrefix...23).contains($0.prefix) && $0.contains(page) }
            .max { $0.prefix < $1.prefix }
    }
}
