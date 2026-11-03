import Foundation

/// Famille d'appareil, déduite des ports, du fabricant et des protocoles (ou choisie à la main).
public enum DeviceType: String, Codable, CaseIterable, Sendable {
    case poste, serveur, imprimante, camera, pointAcces, `switch`, routeur, telephone, iot, inconnu

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

    public init(ip: IPv4Address, mac: MACAddress? = nil, vendor: String? = nil, hostname: String? = nil,
                customName: String? = nil, isOnline: Bool = true, latencyMs: Double? = nil,
                openPorts: [UInt16] = [], switchName: String? = nil, switchPort: String? = nil,
                vlan: Int? = nil, firstSeen: Date = Date(), lastSeen: Date = Date(),
                rangeLabel: String? = nil, deviceType: DeviceType = .inconnu) {
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
    }

    /// Nom à afficher : nom personnalisé, sinon nom d'hôte, sinon l'adresse IP.
    public var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        if let name = hostname, !name.isEmpty { return name }
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

    /// Vrai si le texte (insensible à la casse et aux accents) apparaît dans l'IP, la MAC, les noms,
    /// le fabricant, l'emplacement de switch ou les ports ouverts.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        var fields = [ip.description, displayName, vendorLabel, deviceType.label]
        if let mac { fields += [mac.formatted(.colon), mac.formatted(.hyphen), mac.formatted(.cisco)] }
        fields += [hostname, customName, switchName, switchPort, rangeLabel].compactMap { $0 }
        if let vlan { fields.append("vlan \(vlan)") }
        fields += openPorts.map(String.init)
        return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
