import Foundation

// Note 27 : Wi-Fi géré par la FortiGate (contrôleur des FortiAP). Modèles de la lecture, en
// lecture seule : bornes FortiAP et leurs radios, clients Wi-Fi, SSID diffusés (VAP), AP voisins
// et non autorisés. NetScope ne parle qu'à la FortiGate, jamais aux bornes elles-mêmes.

/// Radio d'une borne FortiAP (/monitor/wifi/managed_ap, champ « radio »).
public struct FortiAPRadio: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { radioID }
    /// Numéro de la radio sur la borne (1, 2, 3).
    public var radioID: Int
    public var band: WifiBand?
    /// Canal de fonctionnement (oper_chan) ; nil si la radio est éteinte ou en mode moniteur.
    public var channel: Int?
    /// Largeur du canal, en MHz (20, 40, 80, 160, 320).
    public var widthMHz: Int?
    /// Puissance d'émission en dBm (oper_txpower), si connue.
    public var txPowerDBm: Int?
    /// Puissance configurée en % (txpower), si c'est la seule donnée.
    public var txPowerPercent: Int?
    public var clientCount: Int?
    /// Utilisation du canal (0 à 100 %).
    public var channelUtilization: Double?
    /// Bruit de fond, en dBm.
    public var noiseDBm: Int?
    /// AP voisins qui brouillent ce canal, d'après la borne.
    public var interferingAPs: Int?
    /// Mode de la radio (« AP », « Monitor », « Disabled »).
    public var mode: String?
    /// Norme (« 802.11ax-5G »), telle que donnée.
    public var standard: String?

    public init(radioID: Int, band: WifiBand? = nil, channel: Int? = nil, widthMHz: Int? = nil, txPowerDBm: Int? = nil,
                txPowerPercent: Int? = nil, clientCount: Int? = nil, channelUtilization: Double? = nil, noiseDBm: Int? = nil,
                interferingAPs: Int? = nil, mode: String? = nil, standard: String? = nil) {
        self.radioID = radioID
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.txPowerDBm = txPowerDBm
        self.txPowerPercent = txPowerPercent
        self.clientCount = clientCount
        self.channelUtilization = channelUtilization
        self.noiseDBm = noiseDBm
        self.interferingAPs = interferingAPs
        self.mode = mode
        self.standard = standard
    }

    /// Radio qui sert des clients (ni éteinte, ni en mode moniteur seul).
    public var isServing: Bool {
        guard channel != nil else { return false }
        guard let mode = mode?.lowercased() else { return true }
        return !(mode.contains("disable") || mode.contains("monitor") || mode == "off" || mode.contains("sniff"))
    }

    /// Largeur retenue pour les calculs (20 MHz si inconnue).
    public var effectiveWidth: Int { max(20, widthMHz ?? 20) }

    /// « 5 GHz · canal 36 · 80 MHz ».
    public var label: String {
        var parts: [String] = []
        if let band { parts.append(band.label) }
        if let channel { parts.append("canal \(channel)") } else { parts.append("éteinte") }
        if let widthMHz, channel != nil { parts.append("\(widthMHz)\u{00A0}MHz") }
        return parts.joined(separator: " · ")
    }

    /// « 14 dBm » ou « 50 % ».
    public var powerLabel: String? {
        if let txPowerDBm { return "\(txPowerDBm)\u{00A0}dBm" }
        if let txPowerPercent { return "\(txPowerPercent)\u{00A0}%" }
        return nil
    }
}

/// Borne FortiAP gérée par la FortiGate.
public struct FortiManagedAP: Codable, Hashable, Sendable, Identifiable {
    public var id: String { site + "|" + (serial.isEmpty ? name : serial) }
    /// Site de la FortiGate qui gère la borne (rempli à la fusion de plusieurs sites).
    public var site: String
    /// Nom donné sur la FortiGate (« AP-ACCUEIL »), sinon le numéro de série.
    public var name: String
    /// Identifiant WTP (souvent le numéro de série).
    public var wtpID: String
    public var serial: String
    /// « FAP-231F ».
    public var model: String
    /// « v7.2.8 » ou la chaîne complète (« FP231F-v7.2.8-build0436 »).
    public var firmware: String
    public var ip: IPv4Address?
    /// Connectée et autorisée ; nil si inconnu.
    public var connected: Bool?
    /// État lu (« connected », « disconnected », « discovered »).
    public var state: String?
    /// Autorisation (« authorized », « discovered », « rejected »).
    public var admin: String?
    /// Durée de fonctionnement, en secondes.
    public var uptime: TimeInterval?
    /// Profil de borne (« FAP231F-default »).
    public var profile: String?
    /// Clients associés (somme des radios si absent).
    public var clientCount: Int?
    public var radios: [FortiAPRadio]
    /// Dernière fois vue par la FortiGate (borne hors ligne).
    public var lastSeen: Date?
    public var location: String?

    public init(site: String = "", name: String, wtpID: String = "", serial: String = "", model: String = "", firmware: String = "",
                ip: IPv4Address? = nil, connected: Bool? = nil, state: String? = nil, admin: String? = nil, uptime: TimeInterval? = nil,
                profile: String? = nil, clientCount: Int? = nil, radios: [FortiAPRadio] = [], lastSeen: Date? = nil, location: String? = nil) {
        self.site = site
        self.name = name.isEmpty ? (serial.isEmpty ? wtpID : serial) : name
        self.wtpID = wtpID.isEmpty ? serial : wtpID
        self.serial = serial
        self.model = model
        self.firmware = firmware
        self.ip = ip
        self.connected = connected
        self.state = state
        self.admin = admin
        self.uptime = uptime
        self.profile = profile
        self.clientCount = clientCount
        self.radios = radios
        self.lastSeen = lastSeen
        self.location = location
    }

    /// Hors ligne : déconnectée de la FortiGate (une borne à l'état inconnu n'est pas comptée).
    public var isOffline: Bool { connected == false }

    /// Clients de la borne (donnée de la borne, sinon somme des radios).
    public var totalClients: Int {
        if let clientCount { return clientCount }
        return radios.compactMap(\.clientCount).reduce(0, +)
    }

    /// Clés par lesquelles les clients désignent la borne (nom, identifiant WTP, série).
    public var keys: Set<String> {
        Set([name, wtpID, serial].map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    /// Version courte : « v7.2.8 » tiré de « FP231F-v7.2.8-build0436 ».
    public var firmwareShort: String {
        if let range = firmware.range(of: #"v\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(firmware[range]) }
        return firmware
    }

    public func radio(_ band: WifiBand) -> FortiAPRadio? { radios.first { $0.band == band && $0.isServing } }
}

/// Client Wi-Fi associé à une borne (/monitor/wifi/client).
public struct FortiWifiClient: Codable, Hashable, Sendable, Identifiable {
    public var id: String { site + "|" + mac.description }
    public var site: String
    public var mac: MACAddress
    public var ip: IPv4Address?
    public var hostname: String?
    public var ssid: String?
    /// Nom de la borne (résolu depuis l'identifiant WTP quand c'est possible).
    public var apName: String?
    /// Identifiant WTP ou série de la borne, tel que donné.
    public var apKey: String?
    public var radioID: Int?
    public var band: WifiBand?
    public var channel: Int?
    /// Signal reçu par la borne, en dBm (négatif).
    public var rssi: Int?
    public var noise: Int?
    /// Rapport signal/bruit, en dB (calculé avec le bruit s'il manque).
    public var snr: Int?
    /// Débit négocié, en Mb/s.
    public var rateMbps: Double?
    /// Durée d'association, en secondes.
    public var associatedFor: TimeInterval?
    /// Système (« iOS », « Windows ») ou fabricant.
    public var os: String?
    public var vlan: Int?
    public var manufacturer: String?

    public init(site: String = "", mac: MACAddress, ip: IPv4Address? = nil, hostname: String? = nil, ssid: String? = nil, apName: String? = nil,
                apKey: String? = nil, radioID: Int? = nil, band: WifiBand? = nil, channel: Int? = nil, rssi: Int? = nil, noise: Int? = nil,
                snr: Int? = nil, rateMbps: Double? = nil, associatedFor: TimeInterval? = nil, os: String? = nil, vlan: Int? = nil,
                manufacturer: String? = nil) {
        self.site = site
        self.mac = mac
        self.ip = ip
        self.hostname = hostname
        self.ssid = ssid
        self.apName = apName
        self.apKey = apKey
        self.radioID = radioID
        self.band = band
        self.channel = channel
        self.rssi = rssi
        self.noise = noise
        self.snr = snr ?? ((rssi != nil && noise != nil) ? rssi! - noise! : nil)
        self.rateMbps = rateMbps
        self.associatedFor = associatedFor
        self.os = os
        self.vlan = vlan
        self.manufacturer = manufacturer
    }

    /// Nom affiché : hôte, sinon la MAC.
    public var displayName: String { hostname ?? mac.formatted(.upperColon) }
}

/// SSID diffusé (/cmdb/wireless-controller/vap).
public struct FortiSSID: Codable, Hashable, Sendable, Identifiable {
    public var id: String { site + "|" + name }
    public var site: String
    /// Nom de l'interface VAP sur la FortiGate (« wifi-interne »).
    public var name: String
    /// SSID diffusé (« Groupe-Interne »).
    public var ssid: String
    /// Sécurité telle que FortiOS la nomme (« wpa2-only-enterprise », « open »).
    public var security: String?
    public var vlan: Int?
    /// SSID caché (broadcast-ssid disable).
    public var hidden: Bool?
    /// Pont local (local-bridging) : le trafic sort sur la borne.
    public var localBridging: Bool?
    public var maxClients: Int?
    /// Portail captif (« captive-portal », security-mode).
    public var captivePortal: Bool?

    public init(site: String = "", name: String, ssid: String, security: String? = nil, vlan: Int? = nil, hidden: Bool? = nil,
                localBridging: Bool? = nil, maxClients: Int? = nil, captivePortal: Bool? = nil) {
        self.site = site
        self.name = name
        self.ssid = ssid.isEmpty ? name : ssid
        self.security = security
        self.vlan = vlan
        self.hidden = hidden
        self.localBridging = localBridging
        self.maxClients = maxClients
        self.captivePortal = captivePortal
    }

    /// Réseau sans chiffrement (ouvert ou portail captif seul).
    public var isOpen: Bool {
        guard let s = security?.lowercased() else { return false }
        return s == "open" || s.hasPrefix("open") || s == "captive-portal" || s == "none"
    }

    /// « WPA2 Entreprise », « WPA3 Personnel », « Ouvert ».
    public var securityLabel: String {
        guard let raw = security?.lowercased(), !raw.isEmpty else { return "—" }
        if isOpen { return captivePortal == true || raw.contains("captive") ? "Ouvert · portail captif" : "Ouvert" }
        if raw.contains("owe") { return "OWE (Enhanced Open)" }
        if raw.contains("wep") { return "WEP" }
        let enterprise = raw.contains("enterprise") || raw.contains("radius") || raw.contains("1x")
        var version = "WPA"
        if raw.contains("wpa3") && raw.contains("wpa2") { version = "WPA2/WPA3" }
        else if raw.contains("wpa3") || raw.contains("sae") { version = "WPA3" }
        else if raw.contains("wpa2") { version = "WPA2" }
        return version + (enterprise ? " Entreprise" : " Personnel")
    }
}

/// AP voisin vu par les bornes (/monitor/wifi/rogue_ap ou interfering_ap).
public struct FortiRogueAP: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Signalé « rogue » par la FortiGate, ou branché sur le réseau câblé (on-wire).
        case rogue
        /// Accepté par l'administrateur.
        case accepted
        /// Neutralisé (suppressed).
        case suppressed
        /// Voisin non classé.
        case unclassified

        public var label: String {
            switch self {
            case .rogue: return "Non autorisé"
            case .accepted: return "Accepté"
            case .suppressed: return "Neutralisé"
            case .unclassified: return "Voisin"
            }
        }
    }

    public var id: String { site + "|" + (bssid?.description ?? ssid ?? "?") + "|\(channel ?? 0)" }
    public var site: String
    public var ssid: String?
    public var bssid: MACAddress?
    public var channel: Int?
    public var band: WifiBand?
    /// Signal le plus fort reçu par une borne, en dBm.
    public var rssi: Int?
    public var status: Status
    /// Vu sur le réseau câblé de la FortiGate (MAC voisine de la MAC sans fil).
    public var onWire: Bool
    /// Bornes qui l'entendent.
    public var seenBy: [String]
    public var security: String?
    public var vendor: String?
    public var lastSeen: Date?

    public init(site: String = "", ssid: String? = nil, bssid: MACAddress? = nil, channel: Int? = nil, band: WifiBand? = nil, rssi: Int? = nil,
                status: Status = .unclassified, onWire: Bool = false, seenBy: [String] = [], security: String? = nil, vendor: String? = nil,
                lastSeen: Date? = nil) {
        self.site = site
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.band = band
        self.rssi = rssi
        self.status = status
        self.onWire = onWire
        self.seenBy = seenBy
        self.security = security
        self.vendor = vendor
        self.lastSeen = lastSeen
    }

    /// À traiter : non autorisé ou branché sur le réseau câblé sans avoir été accepté.
    public var isUnauthorized: Bool { status == .rogue || (onWire && status != .accepted && status != .suppressed) }
}

/// Tout ce que la FortiGate a renvoyé sur le Wi-Fi lors d'une lecture.
public struct FortiWifiReport: Codable, Hashable, Sendable {
    public var aps: [FortiManagedAP]
    public var clients: [FortiWifiClient]
    public var ssids: [FortiSSID]
    public var rogues: [FortiRogueAP]
    public var calls: [FortiCallRecord]
    public var readAt: Date
    /// Le contrôleur Wi-Fi répond (managed_ap lisible) ; faux si l'adresse est absente (404).
    public var available: Bool
    /// Parties absentes ou refusées, expliquées (« Clients : droit manquant… »).
    public var notes: [String]

    public init(aps: [FortiManagedAP] = [], clients: [FortiWifiClient] = [], ssids: [FortiSSID] = [], rogues: [FortiRogueAP] = [],
                calls: [FortiCallRecord] = [], readAt: Date = Date(), available: Bool = true, notes: [String] = []) {
        self.aps = aps
        self.clients = clients
        self.ssids = ssids
        self.rogues = rogues
        self.calls = calls
        self.readAt = readAt
        self.available = available
        self.notes = notes
    }
}

/// Lecture Wi-Fi d'une FortiGate d'un site.
public struct FortiWifiSiteReport: Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: FortiWifiReport

    public init(controllerID: UUID, site: String, report: FortiWifiReport) {
        self.controllerID = controllerID
        self.site = site
        self.report = report
    }
}
