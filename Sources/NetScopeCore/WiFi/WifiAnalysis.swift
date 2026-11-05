import Foundation

// Analyse Wi-Fi indépendante de CoreWLAN : bandes, géométrie des canaux, qualité du signal,
// recommandations. L'application remplit `WifiNetwork` à partir de CoreWLAN.

public enum WifiBand: String, CaseIterable, Sendable, Codable, Identifiable {
    case ghz24, ghz5, ghz6

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ghz24: return "2,4 GHz"
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        }
    }

    /// Bande d'un canal quand CoreWLAN ne la donne pas (1–14 : 2,4 GHz, sinon 5 GHz).
    public static func guess(channel: Int) -> WifiBand {
        channel <= 14 ? .ghz24 : .ghz5
    }
}

public enum WifiSecurity: String, Sendable, Codable, CaseIterable {
    case open, owe, wep, wpaPersonal, wpa2Personal, wpa3Personal, wpa3Transition
    case wpaEnterprise, wpa2Enterprise, wpa3Enterprise, unknown

    public var label: String {
        switch self {
        case .open: return "Ouvert"
        case .owe: return "OWE (Enhanced Open)"
        case .wep: return "WEP"
        case .wpaPersonal: return "WPA-Personnel"
        case .wpa2Personal: return "WPA2-Personnel"
        case .wpa3Personal: return "WPA3-Personnel"
        case .wpa3Transition: return "WPA2/WPA3-Personnel"
        case .wpaEnterprise: return "WPA-Entreprise"
        case .wpa2Enterprise: return "WPA2-Entreprise"
        case .wpa3Enterprise: return "WPA3-Entreprise"
        case .unknown: return "Inconnue"
        }
    }

    /// Aucun chiffrement.
    public var isOpen: Bool { self == .open }
    /// Chiffrement faible ou obsolète.
    public var isWeak: Bool { self == .wep || self == .wpaPersonal || self == .wpaEnterprise }
    public var isWPA3: Bool { self == .wpa3Personal || self == .wpa3Enterprise || self == .wpa3Transition || self == .owe }
}

public struct WifiNetwork: Identifiable, Hashable, Sendable {
    public var id: String
    public var ssid: String?
    public var bssid: MACAddress?
    public var channel: Int
    public var band: WifiBand
    public var widthMHz: Int
    public var rssi: Int
    public var noise: Int?
    public var security: WifiSecurity
    /// Norme (« 802.11ax »), si connue.
    public var standard: String?
    public var isConnected: Bool
    /// Note 71 : éléments de la balise (nil sans autorisation de localisation ou sans données).
    public var beacon: WifiBeaconInfo?

    public init(id: String? = nil, ssid: String?, bssid: MACAddress?, channel: Int, band: WifiBand? = nil, widthMHz: Int = 20,
                rssi: Int, noise: Int? = nil, security: WifiSecurity = .unknown, standard: String? = nil, isConnected: Bool = false,
                beacon: WifiBeaconInfo? = nil) {
        let resolvedBand = band ?? WifiBand.guess(channel: channel)
        self.id = id ?? bssid?.description ?? "\(ssid ?? "?")-\(resolvedBand.rawValue)-\(channel)"
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.band = resolvedBand
        self.widthMHz = widthMHz
        self.rssi = rssi
        self.noise = noise
        self.security = security
        self.standard = standard
        self.isConnected = isConnected
        self.beacon = beacon
    }

    public var isHidden: Bool { (ssid ?? "").isEmpty }
    public var displaySSID: String { isHidden ? "(SSID caché)" : ssid! }
    public var snr: Int? { noise.map { rssi - $0 } }
}

// MARK: - Qualité du signal

public enum WifiQuality: Sendable {
    case bon, moyen, faible

    public init(rssi: Int) {
        if rssi >= -60 { self = .bon }
        else if rssi >= -70 { self = .moyen }
        else { self = .faible }
    }

    public var label: String {
        switch self {
        case .bon: return "Bon"
        case .moyen: return "Moyen"
        case .faible: return "Faible"
        }
    }

    public var longLabel: String {
        switch self {
        case .bon: return "Très bon signal"
        case .moyen: return "Signal moyen"
        case .faible: return "Signal faible"
        }
    }

    /// Remplissage d'une barre de signal (de −100 à −30 dBm), entre 4 et 100.
    public static func percent(rssi: Int) -> Int {
        max(4, min(100, Int((Double(rssi + 100) / 70 * 100).rounded())))
    }

    /// « −52 dBm », avec le vrai signe moins.
    public static func dbm(_ value: Int) -> String {
        (value < 0 ? "\u{2212}" : "") + "\(abs(value))\u{00A0}dBm"
    }
}

// MARK: - Géométrie des canaux

/// Position des réseaux sur l'axe d'un graphe de canaux (unités propres à chaque bande),
/// reprise du croquis : 2,4 GHz en numéros de canal, 5 GHz en rang dans la liste des canaux.
public enum WifiChannelLayout {
    public static let channels5: [Int] = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128,
                                          132, 136, 140, 144, 149, 153, 157, 161, 165]
    private static let starts5: [Int: [Int]] = [
        20: channels5,
        40: [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157],
        80: [36, 52, 100, 116, 132, 149],
        160: [36, 100],
    ]

    public static func axis(_ band: WifiBand) -> ClosedRange<Double> {
        switch band {
        case .ghz24: return -1...15
        case .ghz5: return -1...25
        case .ghz6: return -7...239
        }
    }

    /// Centre et demi-largeur du réseau, en unités de l'axe.
    public static func span(channel: Int, band: WifiBand, widthMHz: Int) -> (center: Double, half: Double) {
        let k = Double(max(20, widthMHz)) / 20
        switch band {
        case .ghz24:
            return (Double(channel), 2 * k)
        case .ghz5:
            let starts = starts5[max(20, widthMHz)] ?? channels5
            var start = starts[0]
            for s in starts where s <= channel { start = s }
            let rank = Double(channels5.firstIndex(of: start) ?? 0)
            return (rank + (k - 1) / 2, k / 2)
        case .ghz6:
            let block = 4 * Int(k)
            let start = ((channel - 1) / block) * block + 1
            return (Double(start) + 2 * (k - 1), 2 * k)
        }
    }

    public static func span(of network: WifiNetwork) -> (center: Double, half: Double) {
        span(channel: network.channel, band: network.band, widthMHz: network.widthMHz)
    }

    /// Graduations : (position, libellé).
    public static func ticks(_ band: WifiBand) -> [(position: Double, label: String)] {
        switch band {
        case .ghz24: return (1...13).map { (Double($0), String($0)) }
        case .ghz5: return channels5.enumerated().map { (Double($0.offset), String($0.element)) }
        case .ghz6: return stride(from: 1, through: 225, by: 16).map { (Double($0), String($0)) } + [(233, "233")]
        }
    }

    /// Plage des canaux DFS (52–144) sur l'axe 5 GHz.
    public static let dfsRange5: ClosedRange<Double> = 3.5...19.5

    public static func overlaps(_ a: WifiNetwork, _ b: WifiNetwork) -> Bool {
        guard a.band == b.band else { return false }
        let sa = span(of: a), sb = span(of: b)
        return abs(sa.center - sb.center) < sa.half + sb.half
    }
}

// MARK: - Recommandations

public struct WifiRecommendation: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case critique, alerte, conseil, info

        public var label: String {
            switch self {
            case .critique: return "Critique"
            case .alerte: return "Alerte"
            case .conseil: return "Conseil"
            case .info: return "Info"
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    /// Réseau à mettre en évidence, et bande à afficher.
    public var networkID: String?
    public var band: WifiBand?

    public init(id: String, severity: Severity, title: String, detail: String, networkID: String? = nil, band: WifiBand? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.networkID = networkID
        self.band = band
    }
}

public enum WifiAdvisor {
    /// Nombre de réseaux 2,4 GHz qui chevauchent chaque canal 1 à 13.
    public static func occupancy24(_ networks: [WifiNetwork]) -> [Int: Int] {
        let list = networks.filter { $0.band == .ghz24 }
        var result: [Int: Int] = [:]
        for channel in 1...13 {
            let probe = WifiNetwork(ssid: nil, bssid: nil, channel: channel, band: .ghz24, widthMHz: 20, rssi: -50)
            result[channel] = list.filter { WifiChannelLayout.overlaps(probe, $0) }.count
        }
        return result
    }

    /// Le moins encombré des canaux 1, 6 et 11 (à égalité, le plus bas).
    public static func bestChannel24(_ networks: [WifiNetwork]) -> Int {
        let occupancy = occupancy24(networks)
        return [1, 6, 11].min { (occupancy[$0] ?? 0, $0) < (occupancy[$1] ?? 0, $1) } ?? 1
    }

    /// Préfixe constructeur d'un BSSID, sans le bit « administré localement ».
    static func vendorKey(_ mac: MACAddress) -> UInt32 {
        mac.ouiValue & 0xFDFFFF
    }

    /// BSSID d'un SSID connu dont le préfixe constructeur diffère de celui du réseau habituel :
    /// peut-être un point d'accès non autorisé (« evil twin »).
    public static func suspiciousTwins(_ networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiNetwork] {
        var result: [WifiNetwork] = []
        let groups = Dictionary(grouping: networks.filter { !$0.isHidden && $0.bssid != nil }, by: { $0.ssid! })
        for (ssid, members) in groups where members.count >= 2 {
            let reference: UInt32
            if let connected, connected.ssid == ssid, let bssid = connected.bssid {
                reference = vendorKey(bssid)
            } else {
                let counts = Dictionary(grouping: members, by: { vendorKey($0.bssid!) }).mapValues(\.count)
                guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 2 else { continue }
                reference = top.key
            }
            result += members.filter { vendorKey($0.bssid!) != reference }
        }
        return result.sorted { $0.rssi > $1.rssi }
    }

    public static func recommendations(networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiRecommendation] {
        var result: [WifiRecommendation] = []

        for twin in suspiciousTwins(networks, connected: connected) {
            result.append(WifiRecommendation(
                id: "jumeau-\(twin.id)", severity: .critique,
                title: "AP non autorisé possible\u{00A0}: «\u{00A0}\(twin.displaySSID)\u{00A0}»",
                detail: "Le BSSID \(twin.bssid!.formatted(.upperColon)) diffuse le même nom que vos points d’accès, mais avec un préfixe constructeur inconnu (canal \(twin.channel), \(WifiQuality.dbm(twin.rssi))).",
                networkID: twin.id, band: twin.band))
        }

        let occupancy = occupancy24(networks)
        let used = Set(networks.filter { $0.band == .ghz24 }.map(\.channel))
        if let crowded = occupancy.filter({ used.contains($0.key) }).max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }),
           crowded.value >= 4 {
            let best = bestChannel24(networks)
            let focus = networks.filter { $0.band == .ghz24 && $0.channel == crowded.key }.max { $0.rssi < $1.rssi }
            result.append(WifiRecommendation(
                id: "encombre-24", severity: .alerte,
                title: "Canal \(crowded.key) (2,4\u{00A0}GHz) encombré",
                detail: "\(crowded.value) réseaux se partagent le canal \(crowded.key)\u{00A0}: temps d’antenne partagé, débit réduit.",
                networkID: focus?.id, band: .ghz24))
            if best != crowded.key {
                result.append(WifiRecommendation(
                    id: "deplacer-24", severity: .conseil,
                    title: "Préférer le canal \(best) en 2,4\u{00A0}GHz",
                    detail: "Le canal \(best) ne porte que \(occupancy[best] ?? 0) réseau(x) en chevauchement. Restez sur 1, 6 ou 11 pour éviter les chevauchements partiels.",
                    band: .ghz24))
            }
        }

        if let connected, connected.band == .ghz5 {
            let overlapping = networks.filter {
                $0.id != connected.id && $0.ssid != connected.ssid && $0.rssi >= -75 && WifiChannelLayout.overlaps($0, connected)
            }
            if !overlapping.isEmpty {
                result.append(WifiRecommendation(
                    id: "chevauchement-5", severity: .alerte,
                    title: "Chevauchement en 5\u{00A0}GHz (canal \(connected.channel), \(connected.widthMHz)\u{00A0}MHz)",
                    detail: "\(overlapping.count) réseau(x) voisin(s) occupent le même bloc de canaux que votre connexion. Une largeur de 40\u{00A0}MHz ou un autre bloc réduirait les interférences.",
                    networkID: connected.id, band: .ghz5))
            }
        }

        for network in networks.filter({ $0.security.isOpen }).sorted(by: { $0.rssi > $1.rssi }).prefix(3) {
            result.append(WifiRecommendation(
                id: "ouvert-\(network.id)", severity: .alerte,
                title: "Réseau ouvert détecté\u{00A0}: «\u{00A0}\(network.displaySSID)\u{00A0}»",
                detail: "Diffusé sans chiffrement (canal \(network.channel)). Préférez OWE (Enhanced Open) ou un portail captif isolé du réseau interne.",
                networkID: network.id, band: network.band))
        }

        for network in networks.filter({ $0.security == .wep }).prefix(2) {
            result.append(WifiRecommendation(
                id: "wep-\(network.id)", severity: .alerte,
                title: "Chiffrement WEP\u{00A0}: «\u{00A0}\(network.displaySSID)\u{00A0}»",
                detail: "Le WEP se casse en quelques minutes. Passez en WPA2 ou WPA3.",
                networkID: network.id, band: network.band))
        }

        if let connected {
            if connected.rssi < -70 {
                result.append(WifiRecommendation(
                    id: "signal-faible", severity: .alerte,
                    title: "Signal faible sur la connexion actuelle",
                    detail: "\(WifiQuality.dbm(connected.rssi))\u{00A0}: rapprochez-vous du point d’accès ou ajoutez-en un dans cette zone.",
                    networkID: connected.id, band: connected.band))
            } else if let snr = connected.snr, snr < 20 {
                result.append(WifiRecommendation(
                    id: "snr-faible", severity: .conseil,
                    title: "Rapport signal/bruit faible (\(snr)\u{00A0}dB)",
                    detail: "Le bruit ambiant est élevé. Un canal moins encombré améliorerait la stabilité.",
                    networkID: connected.id, band: connected.band))
            }
        }

        let hidden = networks.filter(\.isHidden)
        if let strongest = hidden.max(by: { $0.rssi < $1.rssi }) {
            let bssid = strongest.bssid.map { " (\($0.formatted(.upperColon)))" } ?? ""
            result.append(WifiRecommendation(
                id: "cache", severity: .info,
                title: hidden.count == 1 ? "SSID caché sur le canal \(strongest.channel)" : "\(hidden.count) SSID cachés",
                detail: "Le plus fort\(bssid) émet à \(WifiQuality.dbm(strongest.rssi)). Un SSID caché n’apporte aucune sécurité réelle.",
                networkID: strongest.id, band: strongest.band))
        }

        // Note 71 : constats tirés des balises (itinérance, charge, WPA3).
        result += WifiBeaconAdvisor.recommendations(networks: networks, connected: connected)

        return result.sorted { $0.severity < $1.severity }
    }
}
