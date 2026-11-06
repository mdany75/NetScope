import Foundation

// Note 77 : contrôleurs UniFi Network, TP-Link Omada et Cisco Meraki, en lecture seule, comme la
// FortiGate. Un contrôleur appartient à un site (Réglages › Sites › Contrôleur). Ce fichier décrit
// la configuration (sans aucun secret : elle va dans sites.json, le CSV et les sauvegardes) et le
// modèle commun de ce qui est lu (switchs, bornes, clients), quelle que soit la marque.
// Le secret (clé d'API, mot de passe, client_secret) est au Trousseau, sous l'identifiant du
// contrôleur ; il n'est jamais dans ces modèles.

// MARK: - Marque

public enum ControllerKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case unifi, omada, meraki

    public var id: String { rawValue }

    /// « UniFi Network », « TP-Link Omada », « Cisco Meraki ».
    public var label: String {
        switch self {
        case .unifi: return "UniFi Network"
        case .omada: return "TP-Link Omada"
        case .meraki: return "Cisco Meraki"
        }
    }

    /// Nom court des puces (« via UniFi »).
    public var shortLabel: String {
        switch self {
        case .unifi: return "UniFi"
        case .omada: return "Omada"
        case .meraki: return "Meraki"
        }
    }

    /// Fabricant des équipements (colonne « Marque » des switchs).
    public var brand: String {
        switch self {
        case .unifi: return "Ubiquiti"
        case .omada: return "TP-Link"
        case .meraki: return "Cisco Meraki"
        }
    }

    /// Numéro d'entreprise (sysObjectID) : la marque est reconnue comme pour SNMP.
    public var objectID: String {
        switch self {
        case .unifi: return "1.3.6.1.4.1.41112"
        case .omada: return "1.3.6.1.4.1.11863"
        case .meraki: return "1.3.6.1.4.1.29671"
        }
    }

    /// Modes d'authentification possibles, le recommandé d'abord.
    public var authModes: [ControllerAuthMode] {
        switch self {
        case .unifi: return [.unifiAPIKey, .unifiLocalAccount]
        case .omada: return [.omadaOpenAPI, .omadaWebAccount]
        case .meraki: return [.merakiAPIKey]
        }
    }

    /// Port HTTPS habituel (Omada logiciel : 8043 ; OC200/OC300 : 443).
    public var defaultPort: Int {
        switch self {
        case .unifi, .meraki: return 443
        case .omada: return 8043
        }
    }

    /// Adresse fixe de l'API Meraki (nuage) : aucune adresse à saisir.
    public static let merakiHost = "api.meraki.com"
}

// MARK: - Authentification

public enum ControllerAuthMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// UniFi OS (UDM, UCG, Cloud Key Gen2+, UniFi OS Server) : clé d'API dans l'en-tête X-API-KEY.
    case unifiAPIKey
    /// Compte local du contrôleur (UniFi OS ou contrôleur classique) : identifiant et mot de passe.
    case unifiLocalAccount
    /// Omada Open API : client_id et client_secret (mode « client credentials »).
    case omadaOpenAPI
    /// API web du contrôleur Omada : identifiant et mot de passe d'un compte en lecture.
    case omadaWebAccount
    /// Clé d'API du tableau de bord Meraki.
    case merakiAPIKey

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unifiAPIKey: return "Clé d’API (UniFi OS)"
        case .unifiLocalAccount: return "Compte local"
        case .omadaOpenAPI: return "Open API (client_id et secret)"
        case .omadaWebAccount: return "Compte du contrôleur (API web)"
        case .merakiAPIKey: return "Clé d’API du tableau de bord"
        }
    }

    /// Libellé du champ non secret (identifiant, client_id) ; nil si le mode n'en a pas.
    public var accountLabel: String? {
        switch self {
        case .unifiLocalAccount, .omadaWebAccount: return "Identifiant"
        case .omadaOpenAPI: return "Client ID"
        case .unifiAPIKey, .merakiAPIKey: return nil
        }
    }

    /// Libellé du secret gardé au Trousseau.
    public var secretLabel: String {
        switch self {
        case .unifiAPIKey, .merakiAPIKey: return "Clé d’API"
        case .unifiLocalAccount, .omadaWebAccount: return "Mot de passe"
        case .omadaOpenAPI: return "Client secret"
        }
    }
}

// MARK: - État du dernier essai ou de la dernière lecture

public struct ControllerStatus: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ok, error, missingSecret, certificate, untested
    }

    public var kind: Kind
    /// Message sans secret.
    public var message: String
    public var date: Date?
    /// Nom et version du contrôleur (« UDM-Pro-Clinique », « 9.0.114 »).
    public var name: String?
    public var version: String?
    public var switchCount: Int?
    public var apCount: Int?
    public var clientCount: Int?

    public init(kind: Kind, message: String = "", date: Date? = nil, name: String? = nil, version: String? = nil,
                switchCount: Int? = nil, apCount: Int? = nil, clientCount: Int? = nil) {
        self.kind = kind
        self.message = message
        self.date = date
        self.name = name
        self.version = version
        self.switchCount = switchCount
        self.apCount = apCount
        self.clientCount = clientCount
    }

    public static func success(_ report: ControllerReport, date: Date) -> ControllerStatus {
        ControllerStatus(kind: .ok, date: date, name: report.controllerName, version: report.version,
                         switchCount: report.switches.count, apCount: report.aps.count, clientCount: report.clients.count)
    }

    enum CodingKeys: String, CodingKey { case kind, message, date, name, version, switchCount, apCount, clientCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil).flatMap(Kind.init(rawValue:)) ?? .untested
        message = ((try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil) ?? ""
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        switchCount = (try? c.decodeIfPresent(Int.self, forKey: .switchCount)) ?? nil
        apCount = (try? c.decodeIfPresent(Int.self, forKey: .apCount)) ?? nil
        clientCount = (try? c.decodeIfPresent(Int.self, forKey: .clientCount)) ?? nil
    }
}

// MARK: - Contrôleur d'un site

/// Contrôleur d'un site : marque, adresse, site ou réseau à lire, mode d'authentification et
/// identifiant non secret, empreinte acceptée. Le secret est au Trousseau (compte `keychainAccount`).
public struct SiteController: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ControllerKind
    /// Nom libre (« UDM Pro de la clinique ») ; vide : la marque et l'adresse.
    public var name: String
    /// Adresse IP ou nom (UniFi, Omada) ; ignorée pour Meraki (api.meraki.com).
    public var host: String
    public var port: Int
    /// UniFi seulement : UniFi OS (préfixe /proxy/network) ; faux pour un contrôleur classique
    /// (logiciel UniFi Network sur un serveur, Cloud Key de première génération).
    public var unifiOS: Bool
    public var authMode: ControllerAuthMode
    /// Identifiant (compte local) ou client_id (Omada Open API) ; jamais un secret.
    public var account: String
    /// UniFi : nom court du site (« default ») ; Omada : nom ou identifiant du site ;
    /// Meraki : identifiant ou nom du réseau.
    public var siteRef: String
    /// Omada : identifiant du contrôleur (omadacId, lu sur /api/info s'il est vide) ;
    /// Meraki : identifiant de l'organisation (la première si vide).
    public var orgRef: String
    public var pinnedFingerprint: String?
    public var isEnabled: Bool
    public var timeout: Double
    public var lastStatus: ControllerStatus?

    public init(id: UUID = UUID(), kind: ControllerKind, name: String = "", host: String = "", port: Int? = nil,
                unifiOS: Bool = true, authMode: ControllerAuthMode? = nil, account: String = "", siteRef: String = "",
                orgRef: String = "", pinnedFingerprint: String? = nil, isEnabled: Bool = true, timeout: Double = 10,
                lastStatus: ControllerStatus? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port ?? kind.defaultPort
        self.unifiOS = unifiOS
        let mode = authMode ?? kind.authModes[0]
        self.authMode = kind.authModes.contains(mode) ? mode : kind.authModes[0]
        self.account = account
        self.siteRef = siteRef
        self.orgRef = orgRef
        self.pinnedFingerprint = pinnedFingerprint
        self.isEnabled = isEnabled
        self.timeout = timeout
        self.lastStatus = lastStatus
    }

    /// Compte du Trousseau qui garde le secret de ce contrôleur.
    public var keychainAccount: String { id.uuidString }

    /// Adresse sans « https:// », sans chemin ni espace (« 10.1.0.1 », « unifi.exemple.ca »).
    public var cleanHost: String {
        if kind == .meraki { return ControllerKind.merakiHost }
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        // « hôte:8443 » : le port saisi avec l'adresse est ignoré ici (champ Port à part).
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }

    public var effectivePort: Int {
        if kind == .meraki { return 443 }
        return (1...65_535).contains(port) ? port : kind.defaultPort
    }

    /// Adresse lisible (nom ou IP, pas d'URL) ; Meraki : toujours valide.
    public var hasValidAddress: Bool {
        if kind == .meraki { return true }
        let h = cleanHost
        guard !h.isEmpty, h.count <= 253 else { return false }
        if IPv4Address(h) != nil { return true }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return h.unicodeScalars.allSatisfy { allowed.contains($0) } && !h.hasPrefix("-") && !h.hasPrefix(".")
            && h.rangeOfCharacter(from: .letters) != nil
    }

    /// Le certificat se vérifie par empreinte (contrôleur local, souvent autosigné) ; Meraki, nuage
    /// au certificat public, suit la vérification normale du système.
    public var usesPinning: Bool { kind != .meraki }

    /// Champs obligatoires remplis (sans le secret).
    public var isComplete: Bool {
        guard hasValidAddress else { return false }
        if authMode.accountLabel != nil, account.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    /// Nom à afficher : le nom libre, sinon « UniFi Network · 10.1.0.1 ».
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind == .meraki ? kind.label : "\(kind.label) · \(addressLabel)"
    }

    /// « 10.1.0.1 », « 10.1.0.1:8443 », « api.meraki.com ».
    public var addressLabel: String {
        effectivePort == 443 ? cleanHost : "\(cleanHost):\(effectivePort)"
    }

    /// Site ou réseau lu, tel qu'affiché (« site default », « réseau Bureau Montréal »).
    public var scopeLabel: String {
        let ref = siteRef.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .unifi: return "site «\u{00A0}\(ref.isEmpty ? "default" : ref)\u{00A0}»"
        case .omada: return ref.isEmpty ? "premier site" : "site «\u{00A0}\(ref)\u{00A0}»"
        case .meraki: return ref.isEmpty ? "premier réseau" : "réseau «\u{00A0}\(ref)\u{00A0}»"
        }
    }

    /// Même cible (adresse, port, site) : une empreinte n'est jamais gardée pour une autre adresse.
    public func sameTarget(as other: SiteController) -> Bool {
        kind == other.kind && cleanHost.lowercased() == other.cleanHost.lowercased() && effectivePort == other.effectivePort
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port, unifiOS, authMode, account, siteRef, orgRef, pinnedFingerprint, isEnabled, timeout, lastStatus
    }

    /// Lecture tolérante : champ absent ou mal typé → valeur par défaut ; marque inconnue → erreur
    /// (l'entrée est ignorée sans perdre les autres).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil, let kind = ControllerKind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "marque inconnue")
        }
        self.kind = kind
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil).flatMap(UUID.init(uuidString:)) ?? UUID()
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        host = ((try? c.decodeIfPresent(String.self, forKey: .host)) ?? nil) ?? ""
        port = ((try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil) ?? kind.defaultPort
        unifiOS = ((try? c.decodeIfPresent(Bool.self, forKey: .unifiOS)) ?? nil) ?? true
        let mode = ((try? c.decodeIfPresent(String.self, forKey: .authMode)) ?? nil).flatMap(ControllerAuthMode.init(rawValue:))
        authMode = mode.flatMap { kind.authModes.contains($0) ? $0 : nil } ?? kind.authModes[0]
        account = ((try? c.decodeIfPresent(String.self, forKey: .account)) ?? nil) ?? ""
        siteRef = ((try? c.decodeIfPresent(String.self, forKey: .siteRef)) ?? nil) ?? ""
        orgRef = ((try? c.decodeIfPresent(String.self, forKey: .orgRef)) ?? nil) ?? ""
        pinnedFingerprint = (try? c.decodeIfPresent(String.self, forKey: .pinnedFingerprint)) ?? nil
        isEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil) ?? true
        let t = ((try? c.decodeIfPresent(Double.self, forKey: .timeout)) ?? nil) ?? 10
        timeout = t.isFinite && t > 0 && t <= 120 ? t : 10
        lastStatus = (try? c.decodeIfPresent(ControllerStatus.self, forKey: .lastStatus)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(unifiOS, forKey: .unifiOS)
        try c.encode(authMode.rawValue, forKey: .authMode)
        try c.encode(account, forKey: .account)
        try c.encode(siteRef, forKey: .siteRef)
        try c.encode(orgRef, forKey: .orgRef)
        try c.encodeIfPresent(pinnedFingerprint, forKey: .pinnedFingerprint)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(timeout, forKey: .timeout)
        try c.encodeIfPresent(lastStatus, forKey: .lastStatus)
    }
}

// MARK: - Ce qui est lu (modèle commun)

/// Voisin vu sur un port (LLDP, ou borne rattachée par le contrôleur).
public struct ControllerNeighbor: Codable, Hashable, Sendable {
    public var name: String
    public var port: String?
    public var mac: MACAddress?
    public var ip: IPv4Address?
    /// Borne Wi-Fi (le port mène à une borne : itinérance plutôt que déplacement, note 84).
    public var isAccessPoint: Bool
    /// Switch ou routeur (lien entre équipements).
    public var isInfrastructure: Bool

    public init(name: String, port: String? = nil, mac: MACAddress? = nil, ip: IPv4Address? = nil,
                isAccessPoint: Bool = false, isInfrastructure: Bool = false) {
        self.name = name
        self.port = port
        self.mac = mac
        self.ip = ip
        self.isAccessPoint = isAccessPoint
        self.isInfrastructure = isInfrastructure
    }
}

/// Port d'un switch géré.
public struct ControllerPort: Codable, Hashable, Sendable {
    public var number: Int
    /// Nom donné sur le contrôleur (« Port 7 », « Caméra quai »), sinon « Port n ».
    public var name: String
    public var linkUp: Bool?
    public var enabled: Bool?
    public var speedMbps: UInt64?
    public var fullDuplex: Bool?
    public var poeCapable: Bool?
    public var poeEnabled: Bool?
    public var poePowerW: Double?
    public var poeClass: Int?
    public var nativeVLAN: Int?
    public var taggedVLANs: [Int]
    public var isUplink: Bool
    public var neighbor: ControllerNeighbor?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var rxErrors: UInt64?
    /// Erreurs ou avertissements signalés par le contrôleur (Meraki : « PoE overload »).
    public var alerts: [String]

    public init(number: Int, name: String? = nil, linkUp: Bool? = nil, enabled: Bool? = nil, speedMbps: UInt64? = nil,
                fullDuplex: Bool? = nil, poeCapable: Bool? = nil, poeEnabled: Bool? = nil, poePowerW: Double? = nil,
                poeClass: Int? = nil, nativeVLAN: Int? = nil, taggedVLANs: [Int] = [], isUplink: Bool = false,
                neighbor: ControllerNeighbor? = nil, rxBytes: UInt64? = nil, txBytes: UInt64? = nil, rxErrors: UInt64? = nil,
                alerts: [String] = []) {
        self.number = number
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? "Port \(number)" : trimmed
        self.linkUp = linkUp
        self.enabled = enabled
        self.speedMbps = speedMbps
        self.fullDuplex = fullDuplex
        self.poeCapable = poeCapable
        self.poeEnabled = poeEnabled
        self.poePowerW = poePowerW
        self.poeClass = poeClass
        self.nativeVLAN = nativeVLAN
        self.taggedVLANs = taggedVLANs
        self.isUplink = isUplink
        self.neighbor = neighbor
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxErrors = rxErrors
        self.alerts = alerts
    }

    /// Le port délivre du courant.
    public var deliversPoE: Bool { (poePowerW ?? 0) > 0.05 }
}

/// Switch géré par le contrôleur.
public struct ControllerSwitch: Codable, Hashable, Sendable, Identifiable {
    public var id: String { mac?.formatted(.upperColon) ?? serial.nonEmpty ?? name }
    public var mac: MACAddress?
    public var name: String
    /// Modèle lisible (« USW-Pro-24-PoE », « TL-SG3428MP », « MS120-8LP »).
    public var model: String
    public var firmware: String
    public var serial: String
    public var ip: IPv4Address?
    public var online: Bool?
    public var uptime: TimeInterval?
    public var poeBudgetW: Double?
    public var ports: [ControllerPort]

    public init(mac: MACAddress? = nil, name: String, model: String = "", firmware: String = "", serial: String = "",
                ip: IPv4Address? = nil, online: Bool? = nil, uptime: TimeInterval? = nil, poeBudgetW: Double? = nil,
                ports: [ControllerPort] = []) {
        self.mac = mac
        self.name = name
        self.model = model
        self.firmware = firmware
        self.serial = serial
        self.ip = ip
        self.online = online
        self.uptime = uptime
        self.poeBudgetW = poeBudgetW
        self.ports = ports
    }

    public var poeUsedW: Double? {
        let watts = ports.compactMap(\.poePowerW)
        return watts.isEmpty ? nil : watts.reduce(0, +)
    }

    public func port(_ number: Int) -> ControllerPort? { ports.first { $0.number == number } }
}

/// Radio d'une borne.
public struct ControllerRadio: Codable, Hashable, Sendable {
    public var band: WifiBand?
    public var channel: Int?
    public var widthMHz: Int?
    public var txPowerDBm: Int?
    public var clientCount: Int?
    /// Occupation du canal, en %.
    public var utilization: Double?

    public init(band: WifiBand? = nil, channel: Int? = nil, widthMHz: Int? = nil, txPowerDBm: Int? = nil,
                clientCount: Int? = nil, utilization: Double? = nil) {
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.txPowerDBm = txPowerDBm
        self.clientCount = clientCount
        self.utilization = utilization
    }

    /// « 5 GHz · canal 44 (80 MHz) ».
    public var label: String {
        var parts: [String] = []
        if let band { parts.append(band.label) }
        if let channel { parts.append("canal \(channel)" + (widthMHz.map { " (\($0)\u{00A0}MHz)" } ?? "")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Borne Wi-Fi gérée.
public struct ControllerAP: Codable, Hashable, Sendable, Identifiable {
    public var id: String { mac?.formatted(.upperColon) ?? serial.nonEmpty ?? name }
    public var mac: MACAddress?
    public var name: String
    public var model: String
    public var firmware: String
    public var serial: String
    public var ip: IPv4Address?
    public var online: Bool?
    public var uptime: TimeInterval?
    public var radios: [ControllerRadio]
    /// Clients annoncés par le contrôleur (sinon comptés dans la liste des clients).
    public var clientCount: Int?
    /// Switch et port où la borne est branchée, si le contrôleur le dit.
    public var uplinkSwitchMAC: MACAddress?
    public var uplinkSwitchName: String?
    public var uplinkPort: Int?
    /// SSID diffusés.
    public var ssids: [String]

    public init(mac: MACAddress? = nil, name: String, model: String = "", firmware: String = "", serial: String = "",
                ip: IPv4Address? = nil, online: Bool? = nil, uptime: TimeInterval? = nil, radios: [ControllerRadio] = [],
                clientCount: Int? = nil, uplinkSwitchMAC: MACAddress? = nil, uplinkSwitchName: String? = nil,
                uplinkPort: Int? = nil, ssids: [String] = []) {
        self.mac = mac
        self.name = name
        self.model = model
        self.firmware = firmware
        self.serial = serial
        self.ip = ip
        self.online = online
        self.uptime = uptime
        self.radios = radios
        self.clientCount = clientCount
        self.uplinkSwitchMAC = uplinkSwitchMAC
        self.uplinkSwitchName = uplinkSwitchName
        self.uplinkPort = uplinkPort
        self.ssids = ssids
    }

    /// « 1 · 44 · 37 » : canal de chaque radio, dans l'ordre des bandes.
    public var channelsLabel: String {
        let list = radios.sorted { ($0.band?.rawValue ?? "") < ($1.band?.rawValue ?? "") }.compactMap { $0.channel.map(String.init) }
        return list.isEmpty ? "—" : list.joined(separator: " · ")
    }
}

/// Client (filaire ou Wi-Fi) vu par le contrôleur.
public struct ControllerClient: Codable, Hashable, Sendable, Identifiable {
    public var id: String { mac.formatted(.upperColon) }
    public var mac: MACAddress
    public var ip: IPv4Address?
    public var hostname: String?
    public var isWired: Bool
    public var ssid: String?
    public var apMAC: MACAddress?
    public var apName: String?
    public var band: WifiBand?
    public var channel: Int?
    /// Signal en dBm (négatif), si le contrôleur le donne.
    public var rssi: Int?
    /// Signal en % (Omada), si le contrôleur le donne.
    public var signalPercent: Int?
    public var switchMAC: MACAddress?
    public var switchName: String?
    public var port: Int?
    public var vlan: Int?
    public var lastSeen: Date?
    public var manufacturer: String?
    public var os: String?
    /// Débit de la liaison Wi-Fi, en Mb/s.
    public var rateMbps: Double?

    public init(mac: MACAddress, ip: IPv4Address? = nil, hostname: String? = nil, isWired: Bool, ssid: String? = nil,
                apMAC: MACAddress? = nil, apName: String? = nil, band: WifiBand? = nil, channel: Int? = nil, rssi: Int? = nil,
                signalPercent: Int? = nil, switchMAC: MACAddress? = nil, switchName: String? = nil, port: Int? = nil,
                vlan: Int? = nil, lastSeen: Date? = nil, manufacturer: String? = nil, os: String? = nil, rateMbps: Double? = nil) {
        self.mac = mac
        self.ip = ip
        self.hostname = hostname
        self.isWired = isWired
        self.ssid = ssid
        self.apMAC = apMAC
        self.apName = apName
        self.band = band
        self.channel = channel
        self.rssi = rssi
        self.signalPercent = signalPercent
        self.switchMAC = switchMAC
        self.switchName = switchName
        self.port = port
        self.vlan = vlan
        self.lastSeen = lastSeen
        self.manufacturer = manufacturer
        self.os = os
        self.rateMbps = rateMbps
    }

    public var displayName: String { hostname ?? mac.formatted(.upperColon) }
}

/// Un appel à l'API et son résultat (diagnostic, sans secret) : même forme que pour la FortiGate.
public typealias ControllerCallRecord = FortiCallRecord

/// Tout ce qu'un contrôleur a renvoyé lors d'une lecture.
public struct ControllerReport: Codable, Hashable, Sendable {
    public var kind: ControllerKind
    /// Nom du contrôleur ou du réseau (« UDM-Pro-Clinique », « Omada · Bureau Québec »).
    public var controllerName: String
    public var version: String?
    /// Site ou réseau lu, tel que nommé sur le contrôleur.
    public var siteName: String?
    public var switches: [ControllerSwitch]
    public var aps: [ControllerAP]
    public var clients: [ControllerClient]
    public var calls: [ControllerCallRecord]
    /// Parties absentes ou refusées, expliquées (« Ports des switchs : droit manquant… »).
    public var notes: [String]
    public var readAt: Date

    public init(kind: ControllerKind, controllerName: String, version: String? = nil, siteName: String? = nil,
                switches: [ControllerSwitch] = [], aps: [ControllerAP] = [], clients: [ControllerClient] = [],
                calls: [ControllerCallRecord] = [], notes: [String] = [], readAt: Date = Date()) {
        self.kind = kind
        self.controllerName = controllerName
        self.version = version
        self.siteName = siteName
        self.switches = switches
        self.aps = aps
        self.clients = clients
        self.calls = calls
        self.notes = notes
        self.readAt = readAt
    }

    public var wiredClients: [ControllerClient] { clients.filter(\.isWired) }
    public var wirelessClients: [ControllerClient] { clients.filter { !$0.isWired } }

    /// Switch par MAC, sinon par nom.
    public func switchFor(mac: MACAddress?, name: String?) -> ControllerSwitch? {
        if let mac, let found = switches.first(where: { $0.mac == mac }) { return found }
        if let name = name?.lowercased(), !name.isEmpty { return switches.first { $0.name.lowercased() == name } }
        return nil
    }

    /// Borne d'un client Wi-Fi (par MAC, sinon par nom).
    public func ap(for client: ControllerClient) -> ControllerAP? {
        if let mac = client.apMAC, let found = aps.first(where: { $0.mac == mac }) { return found }
        if let name = client.apName?.lowercased(), !name.isEmpty { return aps.first { $0.name.lowercased() == name } }
        return nil
    }

    /// Clients Wi-Fi d'une borne.
    public func clients(of ap: ControllerAP) -> [ControllerClient] {
        wirelessClients.filter { client in
            if let mac = client.apMAC, let apMAC = ap.mac { return mac == apMAC }
            return client.apName?.lowercased() == ap.name.lowercased()
        }
    }

    /// Nombre de clients d'une borne : celui du contrôleur, sinon la liste.
    public func clientCount(of ap: ControllerAP) -> Int { ap.clientCount ?? clients(of: ap).count }
}

/// Lecture réussie d'un contrôleur d'un site.
public struct ControllerSiteReading: Hashable, Sendable, Identifiable {
    public var id: UUID { controllerID }
    public var controllerID: UUID
    public var siteID: UUID
    /// Nom du site NetScope (« Clinique Exemple ») : marque les switchs et les clients.
    public var siteName: String
    public var report: ControllerReport

    public init(controllerID: UUID, siteID: UUID, siteName: String, report: ControllerReport) {
        self.controllerID = controllerID
        self.siteID = siteID
        self.siteName = siteName
        self.report = report
    }
}

extension String {
    /// nil pour une chaîne vide ou faite d'espaces.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
