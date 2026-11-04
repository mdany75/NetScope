import Foundation

// Note 37 : occupation des étendues DHCP. Modèle des étendues lues sur la FortiGate (configuration
// cmdb system.dhcp/server et baux monitor/system/dhcp), de leur occupation calculée et de
// l'estimation faite sans FortiGate (Test DHCP et scan). Rien ici n'accède au réseau.

/// Plage d'adresses contiguës, bornes comprises (« 10.0.0.100 – 10.0.0.199 »).
public struct DHCPAddressRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: IPv4Address
    public var end: IPv4Address

    /// Plage dans l'ordre (les bornes inversées sont remises à l'endroit).
    public init(start: IPv4Address, end: IPv4Address) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// Nombre d'adresses de la plage.
    public var count: Int { Int(end.value - start.value) + 1 }

    public func contains(_ ip: IPv4Address) -> Bool { ip >= start && ip <= end }

    /// « 10.0.0.100 – 10.0.0.199 », « 10.0.0.5 » pour une adresse seule.
    public var description: String { start == end ? start.description : "\(start) – \(end)" }
}

/// Ensemble d'adresses fait de plages disjointes et triées : union des plages de l'étendue moins
/// ses exclusions. Calcul par intervalles (jamais d'énumération de toutes les adresses).
public struct DHCPAddressPool: Hashable, Sendable {
    /// Intervalles fusionnés, triés, sans chevauchement.
    public private(set) var intervals: [DHCPAddressRange]

    public init(_ ranges: [DHCPAddressRange] = []) {
        intervals = Self.merge(ranges)
    }

    /// Nombre total d'adresses.
    public var count: Int { intervals.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { intervals.isEmpty }

    public func contains(_ ip: IPv4Address) -> Bool {
        // Recherche dichotomique dans les intervalles triés.
        var low = 0, high = intervals.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = intervals[mid]
            if ip < r.start { high = mid - 1 } else if ip > r.end { low = mid + 1 } else { return true }
        }
        return false
    }

    /// Retire une plage (exclusion, adresse de la passerelle).
    public mutating func subtract(_ range: DHCPAddressRange) {
        var result: [DHCPAddressRange] = []
        for r in intervals {
            if range.end < r.start || range.start > r.end {
                result.append(r)
                continue
            }
            if range.start > r.start, let before = range.start.previous {
                result.append(DHCPAddressRange(start: r.start, end: before))
            }
            if range.end < r.end, let after = range.end.next {
                result.append(DHCPAddressRange(start: after, end: r.end))
            }
        }
        intervals = result
    }

    static func merge(_ ranges: [DHCPAddressRange]) -> [DHCPAddressRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var result: [DHCPAddressRange] = []
        for r in sorted {
            // Plages qui se touchent ou se chevauchent : une seule.
            if var last = result.last, last.end.value == .max || r.start.value <= last.end.value + 1 {
                if r.end > last.end { last.end = r.end }
                result[result.count - 1] = last
            } else {
                result.append(r)
            }
        }
        return result
    }
}

/// Réservation d'une étendue (« reserved-address ») : une adresse gardée pour une MAC.
public struct DHCPReservation: Hashable, Codable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var description: String?
    /// « assign », « reserved » (adresse gardée) ou « block » (MAC refusée, sans adresse utile).
    public var action: String?

    public init(ip: IPv4Address, mac: MACAddress? = nil, description: String? = nil, action: String? = nil) {
        self.ip = ip
        self.mac = mac
        self.description = description
        self.action = action
    }

    /// Une réservation « block » refuse une MAC : elle ne garde aucune adresse.
    public var holdsAddress: Bool { action?.lowercased() != "block" }
}

/// Serveur DHCP de la FortiGate (une entrée de cmdb system.dhcp/server) : une étendue.
public struct DHCPServerConfig: Hashable, Codable, Sendable, Identifiable {
    /// Identifiant de l'entrée (« id », « q_origin_key ») ; sert à rattacher les baux (« server_mkey »).
    public var id: Int
    public var interface: String
    public var enabled: Bool
    public var ranges: [DHCPAddressRange]
    public var exclusions: [DHCPAddressRange]
    public var reservations: [DHCPReservation]
    /// Durée du bail, en secondes ; 0 : illimitée ; nil : inconnue.
    public var leaseTime: Int?
    public var gateway: IPv4Address?
    public var netmask: IPv4Address?
    /// « regular » ou « ipsec » (serveur des clients VPN).
    public var serverType: String?

    public init(id: Int, interface: String, enabled: Bool = true, ranges: [DHCPAddressRange] = [],
                exclusions: [DHCPAddressRange] = [], reservations: [DHCPReservation] = [], leaseTime: Int? = nil,
                gateway: IPv4Address? = nil, netmask: IPv4Address? = nil, serverType: String? = nil) {
        self.id = id
        self.interface = interface
        self.enabled = enabled
        self.ranges = ranges
        self.exclusions = exclusions
        self.reservations = reservations
        self.leaseTime = leaseTime
        self.gateway = gateway
        self.netmask = netmask
        self.serverType = serverType
    }
}

/// Bail lu dans monitor/system/dhcp, avec le serveur qui l'a donné quand la version le dit.
public struct DHCPLeaseEntry: Hashable, Codable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var hostname: String?
    public var interface: String?
    public var expires: Date?
    public var reserved: Bool
    /// Serveur DHCP d'origine (« server_mkey ») ; nil dans les versions qui ne le donnent pas.
    public var serverID: Int?
    /// « leased », « expired », « released »… (nil : inconnu, considéré actif).
    public var status: String?

    public init(ip: IPv4Address, mac: MACAddress? = nil, hostname: String? = nil, interface: String? = nil,
                expires: Date? = nil, reserved: Bool = false, serverID: Int? = nil, status: String? = nil) {
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.interface = interface
        self.expires = expires
        self.reserved = reserved
        self.serverID = serverID
        self.status = status
    }

    /// Bail encore valable à cette date (ni expiré, ni libéré).
    public func isActive(at now: Date) -> Bool {
        if let status = status?.lowercased(), ["expired", "released", "free", "declined", "abandoned"].contains(status) { return false }
        if let expires, expires <= now { return false }
        return true
    }
}

/// Interface de la FortiGate (cmdb system/interface) : VLAN et nom lisible.
public struct DHCPInterfaceInfo: Hashable, Codable, Sendable {
    public var vlan: Int?
    public var alias: String?

    public init(vlan: Int? = nil, alias: String? = nil) {
        self.vlan = vlan
        self.alias = alias
    }
}

/// Lecture des étendues DHCP d'une FortiGate.
public struct DHCPScopeReadReport: Codable, Hashable, Sendable {
    public var servers: [DHCPServerConfig]
    public var leases: [DHCPLeaseEntry]
    /// Interfaces par nom (VLAN, alias) ; vide si la lecture des interfaces est refusée.
    public var interfaces: [String: DHCPInterfaceInfo]
    /// Faux : aucun serveur DHCP lisible (adresse absente de cette version de FortiOS).
    public var available: Bool
    /// Baux lus (faux : monitor/system/dhcp refusé ou absent, l'occupation ne compte que les réservations).
    public var leasesRead: Bool
    /// Parties absentes ou refusées, expliquées en clair.
    public var notes: [String]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(servers: [DHCPServerConfig] = [], leases: [DHCPLeaseEntry] = [], interfaces: [String: DHCPInterfaceInfo] = [:],
                available: Bool = true, leasesRead: Bool = true, notes: [String] = [], calls: [FortiCallRecord] = [],
                readAt: Date = Date()) {
        self.servers = servers
        self.leases = leases
        self.interfaces = interfaces
        self.available = available
        self.leasesRead = leasesRead
        self.notes = notes
        self.calls = calls
        self.readAt = readAt
    }
}

/// Lecture d'un site (une FortiGate).
public struct DHCPScopeSiteReport: Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: DHCPScopeReadReport

    public init(controllerID: UUID, site: String, report: DHCPScopeReadReport) {
        self.controllerID = controllerID
        self.site = site
        self.report = report
    }
}

/// Seuils d'occupation (réglables) et délai « expire bientôt ».
public struct DHCPScopeThresholds: Codable, Equatable, Hashable, Sendable {
    /// Avertissement à partir de ce taux (%).
    public var warningPercent: Double
    /// Critique à partir de ce taux (%).
    public var criticalPercent: Double
    /// Un bail « expire bientôt » s'il expire dans moins de ce nombre de minutes.
    public var expiringMinutes: Int

    public init(warningPercent: Double = 80, criticalPercent: Double = 95, expiringMinutes: Int = 60) {
        let w = min(max(warningPercent, 1), 100)
        self.warningPercent = w
        self.criticalPercent = min(max(criticalPercent, w), 100)
        self.expiringMinutes = max(1, expiringMinutes)
    }

    public static let standard = DHCPScopeThresholds()

    private enum Keys: String, CodingKey { case warningPercent, criticalPercent, expiringMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(warningPercent: (try? c.decodeIfPresent(Double.self, forKey: .warningPercent)) ?? 80,
                  criticalPercent: (try? c.decodeIfPresent(Double.self, forKey: .criticalPercent)) ?? 95,
                  expiringMinutes: (try? c.decodeIfPresent(Int.self, forKey: .expiringMinutes)) ?? 60)
    }
}

/// Niveau d'une étendue.
public enum DHCPScopeLevel: Int, Codable, Comparable, Sendable {
    /// Désactivée sur la FortiGate, ou plage vide : jamais d'alerte.
    case inactive
    case ok
    case warning
    case critical

    public static func < (lhs: DHCPScopeLevel, rhs: DHCPScopeLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .inactive: return "Inactive"
        case .ok: return "OK"
        case .warning: return "Presque pleine"
        case .critical: return "Critique"
        }
    }
}

/// Adresse occupée d'une étendue (détail) : bail, réservation, ou appareil vu en ligne (estimation).
public struct DHCPScopeEntry: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// Bail dynamique actif.
        case lease
        /// Réservation avec un bail actif.
        case reservationInUse
        /// Réservation sans bail actif (l'adresse reste gardée).
        case reservationIdle
        /// Réservation hors de la plage (ne prend aucune adresse de la plage).
        case reservationOutside
        /// Bail actif hors de la plage actuelle (plage réduite depuis, ou adresse fixe).
        case outsideLease
        /// Appareil vu en ligne par le scan (estimation sans FortiGate).
        case seenOnline

        public var label: String {
            switch self {
            case .lease: return "Bail"
            case .reservationInUse: return "Réservation"
            case .reservationIdle: return "Réservée, libre"
            case .reservationOutside: return "Réservation hors plage"
            case .outsideLease: return "Bail hors plage"
            case .seenOnline: return "Vu en ligne"
            }
        }
    }

    public var ip: IPv4Address
    public var mac: MACAddress?
    public var hostname: String?
    public var kind: Kind
    public var expires: Date?
    /// Bail dynamique qui expire avant le délai des seuils.
    public var expiringSoon: Bool

    public init(ip: IPv4Address, mac: MACAddress? = nil, hostname: String? = nil, kind: Kind, expires: Date? = nil,
                expiringSoon: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.kind = kind
        self.expires = expires
        self.expiringSoon = expiringSoon
    }

    public var id: String { "\(ip)|\(kind.rawValue)|\(mac?.description ?? "")" }
}

/// Occupation calculée d'une étendue.
public struct DHCPScopeUsage: Hashable, Sendable, Identifiable {
    public var id: String
    public var site: String
    public var serverID: Int?
    public var interface: String
    public var alias: String?
    public var vlan: Int?
    public var subnet: Subnet?
    public var ranges: [DHCPAddressRange]
    public var exclusions: [DHCPAddressRange]
    public var gateway: IPv4Address?
    public var leaseTime: Int?
    public var enabled: Bool
    /// Adresses distribuables : plages moins exclusions (et moins la passerelle si elle y est).
    public var poolSize: Int
    /// Baux dynamiques actifs dans la plage (hors réservations).
    public var activeLeases: Int
    /// Réservations dont l'adresse est dans la plage (elles prennent une adresse, bail ou non).
    public var reservationsInPool: Int
    /// Réservations hors plage (sans effet sur l'occupation).
    public var reservationsOutside: Int
    /// Réservations dont l'appareil a un bail actif.
    public var reservationsInUse: Int
    /// Baux actifs hors de la plage (non comptés).
    public var outsideLeases: Int
    /// Adresses utilisées : baux dynamiques plus réservations de la plage.
    public var used: Int
    public var expiringSoon: Int
    /// Estimation sans FortiGate (Test DHCP et scan) : plage supposée, appareils vus en ligne.
    public var isEstimate: Bool
    /// Baux non lus (403) : seules les réservations sont comptées.
    public var leasesUnknown: Bool
    public var level: DHCPScopeLevel
    public var entries: [DHCPScopeEntry]
    /// Remarques propres à l'étendue (estimation, baux non lus…).
    public var notes: [String]

    public init(id: String, site: String, serverID: Int?, interface: String, alias: String?, vlan: Int?, subnet: Subnet?,
                ranges: [DHCPAddressRange], exclusions: [DHCPAddressRange], gateway: IPv4Address?, leaseTime: Int?,
                enabled: Bool, poolSize: Int, activeLeases: Int, reservationsInPool: Int, reservationsOutside: Int,
                reservationsInUse: Int, outsideLeases: Int, used: Int, expiringSoon: Int, isEstimate: Bool,
                leasesUnknown: Bool, level: DHCPScopeLevel, entries: [DHCPScopeEntry], notes: [String]) {
        self.id = id
        self.site = site
        self.serverID = serverID
        self.interface = interface
        self.alias = alias
        self.vlan = vlan
        self.subnet = subnet
        self.ranges = ranges
        self.exclusions = exclusions
        self.gateway = gateway
        self.leaseTime = leaseTime
        self.enabled = enabled
        self.poolSize = poolSize
        self.activeLeases = activeLeases
        self.reservationsInPool = reservationsInPool
        self.reservationsOutside = reservationsOutside
        self.reservationsInUse = reservationsInUse
        self.outsideLeases = outsideLeases
        self.used = used
        self.expiringSoon = expiringSoon
        self.isEstimate = isEstimate
        self.leasesUnknown = leasesUnknown
        self.level = level
        self.entries = entries
        self.notes = notes
    }

    /// Adresses libres (jamais négatif).
    public var free: Int { max(0, poolSize - used) }

    /// Taux d'occupation, de 0 à 100 (0 pour une plage vide).
    public var percent: Double {
        guard poolSize > 0 else { return 0 }
        return min(100, Double(used) / Double(poolSize) * 100)
    }

    /// Taux arrondi à l'entier inférieur sauf au-delà de 99 % (« 96 % », jamais « 100 % » s'il reste une adresse).
    public var percentLabel: String {
        let p = percent
        let rounded = p >= 100 ? 100 : (free > 0 ? min(99, Int(p.rounded())) : 100)
        return "\(rounded)\u{00A0}%"
    }

    /// Nom court : « VLAN 20 », sinon l'interface (« internal »).
    public var shortName: String {
        if let vlan { return "VLAN \(vlan)" }
        return interface
    }

    /// Nom affiché : « VLAN 20 · Voix », « internal · Bureau », « Invités ».
    public var displayName: String {
        let alias = self.alias?.trimmingCharacters(in: .whitespaces)
        if let alias, !alias.isEmpty, alias.lowercased() != shortName.lowercased() { return "\(shortName) · \(alias)" }
        return shortName
    }

    /// Nom de l'étendue dans une phrase d'alerte : « VLAN 20 », « Invités » (alias si pas de VLAN).
    public var alertName: String {
        if vlan != nil { return shortName }
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty { return alias }
        return interface
    }

    /// « 10.0.0.100 – 10.0.0.199 », plusieurs plages séparées par une virgule.
    public var rangesLabel: String {
        ranges.isEmpty ? "—" : ranges.map(\.description).joined(separator: ", ")
    }

    /// Plages abrégées pour un tableau étroit : « 10.0.0.100 – 199 » quand les trois premiers
    /// octets sont les mêmes.
    public var compactRangesLabel: String {
        guard !ranges.isEmpty else { return "—" }
        return ranges.map { r in
            let a = r.start.octets, b = r.end.octets
            if r.start == r.end { return r.start.description }
            if a.0 == b.0 && a.1 == b.1 && a.2 == b.2 { return "\(r.start) – \(b.3)" }
            return r.description
        }.joined(separator: ", ")
    }

    /// Interface et VLAN : « vlan20 » (VLAN déjà dans le nom), « voix · VLAN 20 », « internal ».
    public var interfaceLabel: String {
        guard let vlan else { return interface }
        return FortiParse.vlanID(fromName: interface) == vlan ? interface : "\(interface) · VLAN \(vlan)"
    }

    /// « 96 / 100 »
    public var usedLabel: String { "\(used) / \(poolSize)" }
}

/// Ensemble des étendues lues (tous les sites choisis) ou estimées.
public struct DHCPScopeOverview: Hashable, Sendable {
    public var scopes: [DHCPScopeUsage]
    public var sites: [String]
    public var readAt: Date?
    /// Vrai : estimation sans FortiGate (Test DHCP et scan).
    public var isEstimate: Bool
    /// Remarques de lecture de toutes les FortiGate (404, 403 expliqués).
    public var notes: [String]

    public init(scopes: [DHCPScopeUsage] = [], sites: [String] = [], readAt: Date? = nil, isEstimate: Bool = false,
                notes: [String] = []) {
        self.scopes = scopes
        self.sites = sites
        self.readAt = readAt
        self.isEstimate = isEstimate
        self.notes = notes
    }

    public var isMultiSite: Bool { Set(scopes.map(\.site)).count > 1 }
    public var activeScopes: [DHCPScopeUsage] { scopes.filter { $0.level != .inactive } }
    /// Étendues au-delà d'un seuil, la plus pleine d'abord.
    public var alerting: [DHCPScopeUsage] {
        scopes.filter { $0.level >= .warning }.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
    }
    public var worstLevel: DHCPScopeLevel { activeScopes.map(\.level).max() ?? .inactive }
}
