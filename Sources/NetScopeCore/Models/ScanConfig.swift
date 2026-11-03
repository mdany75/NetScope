import Foundation

/// Une plage enregistrée (« 10.182.122.0/24 · Bureau · VLAN 1 »).
public struct ScanRangeConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Texte saisi, lu par `IPRange(parsing:)`.
    public var text: String
    public var label: String
    public var vlan: Int?
    /// Plage cochée : comprise dans le prochain scan.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), text: String, label: String, vlan: Int? = nil, isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.label = label
        self.vlan = vlan
        self.isEnabled = isEnabled
    }

    /// Plage lue ; lève `IPRangeError` si le texte est invalide.
    public func parsed() throws -> IPRange {
        try IPRange(parsing: text)
    }

    /// « CIDR », « Début-fin », « Adresse » ou « Liste », d'après le texte.
    public var kindLabel: String {
        guard let range = try? parsed() else { return "Invalide" }
        if range.segments.count > 1 { return "Liste" }
        switch range.segments[0] {
        case .cidr: return "CIDR"
        case .span: return "Début-fin"
        case .single: return "Adresse"
        }
    }
}

/// Profil de scan : ce qui est sondé, et sur quels ports TCP.
public enum ScanProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case rapide, complet, portsCourants, personnalise

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rapide: return "Rapide"
        case .complet: return "Complet"
        case .portsCourants: return "Ports courants"
        case .personnalise: return "Personnalisé"
        }
    }

    public var summary: String {
        switch self {
        case .rapide: return "ARP + ping ICMP, résolution des noms"
        case .complet: return "Rapide + SNMP, LLDP/CDP, 1000 ports TCP"
        case .portsCourants: return "22, 80, 443, 445, 3389, 554, 9100…"
        case .personnalise: return "Délais, ports et sondes à votre choix"
        }
    }

    /// Ports courants du technicien : administration, web, partage, impression, vidéo.
    public static let commonPorts: [UInt16] = [
        21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 161, 389, 443, 445, 515, 554, 631, 993, 995,
        1433, 1883, 3306, 3389, 5000, 5001, 5900, 8000, 8080, 8443, 9100,
    ]

    /// Profil complet : ports 1 à 1024 et ports applicatifs courants au-delà (environ 1000 ports).
    public static let extendedPorts: [UInt16] = {
        let high: [UInt16] = [
            1080, 1194, 1433, 1521, 1701, 1723, 1812, 1883, 1900, 2049, 2082, 2083, 2222, 2375, 2376, 3000,
            3128, 3260, 3268, 3306, 3389, 3478, 4443, 4500, 4567, 5000, 5001, 5060, 5061, 5222, 5353, 5432,
            5555, 5601, 5900, 5901, 5985, 5986, 6379, 6443, 6881, 7070, 7443, 8000, 8008, 8009, 8080, 8081,
            8088, 8123, 8291, 8443, 8554, 8728, 8729, 8883, 8888, 9000, 9090, 9100, 9200, 9443, 10000, 10443,
            11211, 27017, 32400, 37777, 49152, 50000,
        ]
        return Array(Set((1...1024).map { UInt16($0) } + high)).sorted()
    }()

    /// Ports TCP sondés. `custom` sert au profil personnalisé ; le profil rapide ne sonde aucun port.
    public func ports(custom: [UInt16] = []) -> [UInt16] {
        switch self {
        case .rapide: return []
        case .complet: return ScanProfile.extendedPorts
        case .portsCourants: return ScanProfile.commonPorts
        case .personnalise: return Array(Set(custom)).sorted()
        }
    }

    /// Lit une liste de ports : « 22, 80, 8000-8010 ». Nil si un élément est invalide.
    public static func parsePorts(_ text: String) -> [UInt16]? {
        var result = Set<UInt16>()
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: ",; \t\n")).filter { !$0.isEmpty }
        for token in tokens {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let low = UInt16(bounds[0]), low > 0,
                  let high = UInt16(bounds.last!), high >= low else { return nil }
            for port in low...high { result.insert(port) }
        }
        return result.sorted()
    }
}
