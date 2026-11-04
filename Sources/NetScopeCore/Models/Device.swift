import Foundation

/// Famille d'appareil, déduite des ports, du fabricant et des protocoles (ou choisie à la main).
public enum DeviceType: String, Codable, CaseIterable, Sendable {
    case poste, serveur, imprimante, camera, pointAcces, `switch`, routeur, telephone, console, domotique, iot, inconnu

    public var label: String {
        switch self {
        case .poste: return "Poste de travail"
        case .serveur: return "Serveur"
        case .imprimante: return "Imprimante"
        case .camera: return "Caméra IP"
        case .pointAcces: return "Point d’accès"
        case .switch: return "Switch"
        case .routeur: return "Routeur / pare-feu"
        case .telephone: return "Téléphone"
        case .console: return "Console de jeu"
        case .domotique: return "Domotique"
        case .iot: return "Objet connecté"
        case .inconnu: return "Inconnu"
        }
    }
}

/// Un appareil vu sur le réseau. L'identifiant est l'adresse IP (texte).
public struct Device: Identifiable, Codable, Hashable, Sendable {
    public var id: String { ip.description }

    public var ip: IPv4Address
    public var mac: MACAddress?
    public var vendor: String?
    public var hostname: String?
    /// Nom donné par l'utilisateur (prioritaire à l'affichage).
    public var customName: String?
    public var isOnline: Bool
    public var latencyMs: Double?
    public var openPorts: [UInt16]
    public var switchName: String?
    public var switchPort: String?
    public var vlan: Int?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Libellé de la plage où l'appareil a été trouvé (« Bureau »).
    public var rangeLabel: String?
    public var deviceType: DeviceType
    /// Origine du nom d'hôte (DNS inverse, mDNS, NetBIOS, SNMP) ; nil si inconnue.
    public var nameSource: NameDetails.Source?
    /// Groupe de travail ou domaine NetBIOS (« WORKGROUP »).
    public var nameDomain: String?
    /// Nature de l'appareil d'après la découverte SNMP (switch, routeur, imprimante…), si elle a répondu.
    public var snmpKind: SNMPDeviceKind?

    public init(ip: IPv4Address, mac: MACAddress? = nil, vendor: String? = nil, hostname: String? = nil,
                customName: String? = nil, isOnline: Bool = true, latencyMs: Double? = nil,
                openPorts: [UInt16] = [], switchName: String? = nil, switchPort: String? = nil,
                vlan: Int? = nil, firstSeen: Date = Date(), lastSeen: Date = Date(),
                rangeLabel: String? = nil, deviceType: DeviceType = .inconnu,
                nameSource: NameDetails.Source? = nil, nameDomain: String? = nil, snmpKind: SNMPDeviceKind? = nil) {
        self.ip = ip
        self.mac = mac
        self.vendor = vendor
        self.hostname = hostname
        self.customName = customName
        self.isOnline = isOnline
        self.latencyMs = latencyMs
        self.openPorts = openPorts
        self.switchName = switchName
        self.switchPort = switchPort
        self.vlan = vlan
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.rangeLabel = rangeLabel
        self.deviceType = deviceType
        self.nameSource = nameSource
        self.nameDomain = nameDomain
        self.snmpKind = snmpKind
    }

    /// Nom d'hôte à afficher, sans le suffixe « .local » de mDNS.
    public var hostnameLabel: String? {
        guard let hostname, !hostname.isEmpty else { return nil }
        return NamesFormat.display(hostname)
    }

    /// Origine du nom à afficher : « mDNS », « NetBIOS · groupe WORKGROUP », « SNMP (sysName) »…
    public var nameSourceLabel: String? {
        guard hostname != nil, let nameSource else { return nil }
        if nameSource == .netbios, let nameDomain, !nameDomain.isEmpty { return "\(nameSource.label) · groupe \(nameDomain)" }
        return nameSource.label
    }

    /// Nom à afficher : nom personnalisé, sinon nom d'hôte, sinon l'adresse IP.
    public var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        if let name = hostnameLabel { return name }
        return ip.description
    }

    /// Fabricant à afficher : celui fourni, sinon la table OUI intégrée.
    public var vendorLabel: String {
        if let vendor, !vendor.isEmpty { return vendor }
        guard let mac else { return OUIDatabase.unknownLabel }
        return OUIDatabase.builtIn.label(for: mac)
    }

    /// « SW-ETG2-01 · 1/14 » si l'emplacement physique est connu.
    public var switchLocation: String? {
        switch (switchName, switchPort) {
        case let (name?, port?): return "\(name) · \(port)"
        case let (name?, nil): return name
        case let (nil, port?): return port
        default: return nil
        }
    }

    /// Recherche multiple (moteur commun `SearchQuery`, champs du Scanner) : un mot seul est
    /// cherché, sans casse ni accents, dans l'IP, la MAC, les noms, le fabricant, l'emplacement
    /// de switch ou les ports ouverts ; « switch:SW-ETG2 type:imprimante », « -mot »… affinent.
    public func matches(_ query: String) -> Bool {
        matchesSearch(query)
    }
}
