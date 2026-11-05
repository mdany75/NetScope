import Foundation

// Note 71 : éléments d'information des balises Wi-Fi (IEEE 802.11-2020, 802.11ax, 802.11be).
// Parseur pur : l'application lui passe `CWNetwork.informationElementData` ; aucun accès au réseau.
// Les octets tronqués ou incohérents ne font jamais planter : l'élément fautif est ignoré
// et `isTruncated` le signale.

// MARK: - Génération Wi-Fi

public enum WifiGeneration: Int, Sendable, Codable, CaseIterable, Comparable {
    /// 802.11a/b/g : aucun élément HT.
    case legacy = 0
    case wifi4 = 4
    case wifi5 = 5
    case wifi6 = 6
    case wifi6E = 60
    case wifi7 = 7

    /// Rang dans l'ordre chronologique (6E entre 6 et 7).
    public var rank: Int {
        switch self {
        case .legacy: return 0
        case .wifi4: return 1
        case .wifi5: return 2
        case .wifi6: return 3
        case .wifi6E: return 4
        case .wifi7: return 5
        }
    }

    public static func < (lhs: WifiGeneration, rhs: WifiGeneration) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .legacy: return "Antérieur"
        case .wifi4: return "Wi-Fi 4"
        case .wifi5: return "Wi-Fi 5"
        case .wifi6: return "Wi-Fi 6"
        case .wifi6E: return "Wi-Fi 6E"
        case .wifi7: return "Wi-Fi 7"
        }
    }

    /// Norme IEEE correspondante.
    public var standard: String {
        switch self {
        case .legacy: return "802.11a/b/g"
        case .wifi4: return "802.11n"
        case .wifi5: return "802.11ac"
        case .wifi6, .wifi6E: return "802.11ax"
        case .wifi7: return "802.11be"
        }
    }

    /// Le Wi-Fi 6 et les suivants exigent WPA3 pour leur certification.
    public var requiresWPA3Support: Bool { self >= .wifi6 }
}

// MARK: - Éléments décodés

/// Protection des trames de gestion (802.11w).
public enum WifiPMF: Int, Sendable, Codable, Comparable {
    case absent = 0, optional = 1, required = 2

    public var label: String {
        switch self {
        case .absent: return "Non"
        case .optional: return "Facultatif"
        case .required: return "Obligatoire"
        }
    }

    public static func < (lhs: WifiPMF, rhs: WifiPMF) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Charge de la cellule (élément BSS Load, aussi appelé QBSS).
public struct WifiBSSLoad: Hashable, Sendable, Codable {
    /// Nombre de clients associés à ce BSSID.
    public var stationCount: Int
    /// Utilisation du canal, de 0 à 255 (temps où le canal est occupé, vu par la borne).
    public var channelUtilization: Int
    /// Capacité d'admission restante (unités de 32 µs par seconde), si annoncée.
    public var availableCapacity: Int?

    public init(stationCount: Int, channelUtilization: Int, availableCapacity: Int? = nil) {
        self.stationCount = stationCount
        self.channelUtilization = channelUtilization
        self.availableCapacity = availableCapacity
    }

    /// Utilisation du canal en pourcentage (arrondi).
    public var utilizationPercent: Int {
        Int((Double(max(0, min(255, channelUtilization))) * 100 / 255).rounded())
    }
}

/// Domaine de mobilité 802.11r (Fast BSS Transition).
public struct WifiMobilityDomain: Hashable, Sendable, Codable {
    public var mdid: UInt16
    /// Transition par le système de distribution (sinon par les airs).
    public var overDS: Bool
    public var resourceRequest: Bool

    public init(mdid: UInt16, overDS: Bool, resourceRequest: Bool = false) {
        self.mdid = mdid
        self.overDS = overDS
        self.resourceRequest = resourceRequest
    }

    /// « 4CE3 ».
    public var mdidText: String { String(format: "%04X", mdid) }
}

/// Élément RSN (ou WPA1 propriétaire) : suites de chiffrement et d'authentification.
public struct WifiRSNInfo: Hashable, Sendable, Codable {
    public var version: Int
    /// Suite de groupe (OUI sur 3 octets puis type), nil si absente.
    public var groupCipher: UInt32?
    public var pairwiseCiphers: [UInt32]
    public var akmSuites: [UInt32]
    /// Capacités RSN (absentes dans les éléments courts).
    public var capabilities: UInt16?

    public init(version: Int = 1, groupCipher: UInt32? = nil, pairwiseCiphers: [UInt32] = [], akmSuites: [UInt32] = [],
                capabilities: UInt16? = nil) {
        self.version = version
        self.groupCipher = groupCipher
        self.pairwiseCiphers = pairwiseCiphers
        self.akmSuites = akmSuites
        self.capabilities = capabilities
    }

    public var pmf: WifiPMF {
        guard let capabilities else { return .absent }
        if capabilities & 0x0040 != 0 { return .required }
        if capabilities & 0x0080 != 0 { return .optional }
        return .absent
    }

    /// Types d'AKM de l'OUI IEEE (00-0F-AC).
    var ieeeAKMs: Set<UInt8> {
        Set(akmSuites.filter { $0 >> 8 == 0x000FAC }.map { UInt8($0 & 0xFF) })
    }

    public var hasSAE: Bool { !ieeeAKMs.isDisjoint(with: [8, 9, 24, 25]) }
    public var hasPSK: Bool { !ieeeAKMs.isDisjoint(with: [2, 4, 6]) }
    public var hasOWE: Bool { ieeeAKMs.contains(18) }
    public var hasEnterprise: Bool { !ieeeAKMs.isDisjoint(with: [1, 3, 5, 11, 12, 13, 22, 23]) }
    /// Suite B 192 bits (WPA3-Entreprise 192 bits).
    public var hasSuiteB192: Bool { !ieeeAKMs.isDisjoint(with: [12, 13]) }
    /// AKM de transition rapide (802.11r) : FT-802.1X, FT-PSK, FT-SAE…
    public var hasFT: Bool { !ieeeAKMs.isDisjoint(with: [3, 4, 9, 13, 19, 25]) }

    public var akmLabels: [String] { akmSuites.map(WifiSuites.akmLabel) }
    public var pairwiseLabels: [String] { pairwiseCiphers.map(WifiSuites.cipherLabel) }
    public var groupLabel: String? { groupCipher.map(WifiSuites.cipherLabel) }
}

/// Noms lisibles des suites (IEEE 802.11-2020, tableau 9-151 et 9-149).
public enum WifiSuites {
    public static func akmLabel(_ suite: UInt32) -> String {
        let oui = suite >> 8, type = suite & 0xFF
        if oui == 0x0050F2 {
            switch type {
            case 1: return "WPA 802.1X"
            case 2: return "WPA PSK"
            default: return "WPA type \(type)"
            }
        }
        guard oui == 0x000FAC else { return String(format: "%06X-%d", oui, type) }
        switch type {
        case 1: return "802.1X"
        case 2: return "PSK"
        case 3: return "FT-802.1X"
        case 4: return "FT-PSK"
        case 5: return "802.1X-SHA256"
        case 6: return "PSK-SHA256"
        case 8: return "SAE"
        case 9: return "FT-SAE"
        case 11: return "802.1X Suite B"
        case 12: return "802.1X Suite B 192 bits"
        case 13: return "FT-802.1X-SHA384"
        case 18: return "OWE"
        case 19: return "FT-PSK-SHA384"
        case 20: return "PSK-SHA384"
        case 22: return "FILS-SHA256"
        case 23: return "FILS-SHA384"
        case 24: return "SAE (clé étendue)"
        case 25: return "FT-SAE (clé étendue)"
        default: return "AKM \(type)"
        }
    }

    public static func cipherLabel(_ suite: UInt32) -> String {
        let oui = suite >> 8, type = suite & 0xFF
        guard oui == 0x000FAC || oui == 0x0050F2 else { return String(format: "%06X-%d", oui, type) }
        switch type {
        case 0: return "Groupe"
        case 1: return "WEP-40"
        case 2: return "TKIP"
        case 4: return "CCMP-128"
        case 5: return "WEP-104"
        case 6: return "BIP-CMAC-128"
        case 8: return "GCMP-128"
        case 9: return "GCMP-256"
        case 10: return "CCMP-256"
        case 11: return "BIP-GMAC-128"
        case 12: return "BIP-GMAC-256"
        case 13: return "BIP-CMAC-256"
        default: return "Chiffre \(type)"
        }
    }
}

/// Constructeur qui a donné le nom de la borne dans son élément propriétaire.
public enum WifiAPNameSource: String, Sendable, Codable {
    case cisco, aruba, fortinet

    public var label: String {
        switch self {
        case .cisco: return "Cisco (élément Aironet)"
        case .aruba: return "Aruba (élément propriétaire)"
        case .fortinet: return "Fortinet (élément propriétaire)"
        }
    }
}

/// Tout ce qu'une balise apprend d'un BSSID.
public struct WifiBeaconInfo: Hashable, Sendable, Codable {
    public var ssid: String?
    /// Canal annoncé (DS Parameter Set, sinon canal primaire HT ou 6 GHz).
    public var channel: Int?
    public var countryCode: String?
    public var dtimPeriod: Int?

    public var hasHT = false
    public var hasVHT = false
    public var hasHE = false
    public var hasEHT = false
    /// L'élément HE Operation porte les informations 6 GHz.
    public var he6GHz = false
    /// Largeur maximale annoncée (MHz), nil si aucun élément ne la donne.
    public var channelWidthMHz: Int?
    /// Flux spatiaux maximaux annoncés (HT, VHT, HE).
    public var spatialStreams: Int?

    public var bssLoad: WifiBSSLoad?
    /// Élément RM Enabled Capabilities présent (802.11k).
    public var radioMeasurement = false
    /// Neighbor Report annoncé dans RM Enabled Capabilities.
    public var neighborReport = false
    /// BSS Transition (802.11v) annoncé dans Extended Capabilities.
    public var bssTransition = false
    public var mobilityDomain: WifiMobilityDomain?

    public var rsn: WifiRSNInfo?
    /// Ancien élément WPA (Microsoft, 00-50-F2 type 1).
    public var wpa: WifiRSNInfo?
    /// Élément de transition OWE (Wi-Fi Alliance) : réseau ouvert jumelé à un BSSID OWE.
    public var oweTransition = false
    public var hotspot20 = false

    public var apName: String?
    public var apNameSource: WifiAPNameSource?
    public var apModel: String?
    public var apSerial: String?
    /// Clients selon l'élément Cisco (en plus de BSS Load).
    public var ciscoClientCount: Int?

    public var wpsDeviceName: String?
    public var wpsManufacturer: String?
    public var wpsModel: String?

    /// Nombre d'éléments lus.
    public var elementCount = 0
    /// Identifiants des éléments présents (255 : extension, codée 255×256 + identifiant étendu).
    public var elementIDs: [Int] = []
    /// Données coupées au milieu d'un élément, ou élément trop court pour son contenu.
    public var isTruncated = false
    /// Les 12 octets des champs fixes (horodatage, intervalle, capacités) précédaient les éléments.
    public var hadFixedFields = false

    public init() {}

    // MARK: Dérivés

    /// 802.11k : Neighbor Report annoncé.
    public var supports11k: Bool { neighborReport }
    /// 802.11v : BSS Transition Management.
    public var supports11v: Bool { bssTransition }
    /// 802.11r : élément Mobility Domain (ou AKM FT).
    public var supports11r: Bool { mobilityDomain != nil || (rsn?.hasFT ?? false) }

    /// Fonctions d'itinérance absentes (« 802.11k », « 802.11v », « 802.11r »).
    public var missingRoaming: [String] {
        var result: [String] = []
        if !supports11k { result.append("802.11k") }
        if !supports11v { result.append("802.11v") }
        if !supports11r { result.append("802.11r") }
        return result
    }

    /// « k · v · r » avec un tiret pour chaque fonction absente.
    public var roamingSummary: String {
        [supports11k ? "k" : "–", supports11v ? "v" : "–", supports11r ? "r" : "–"].joined(separator: " ")
    }

    public var roamingCount: Int { [supports11k, supports11v, supports11r].filter { $0 }.count }

    /// Génération, compte tenu de la bande (le Wi-Fi 6 en 6 GHz est du Wi-Fi 6E).
    public func generation(band: WifiBand? = nil) -> WifiGeneration {
        if hasEHT { return .wifi7 }
        if hasHE { return (he6GHz || band == .ghz6) ? .wifi6E : .wifi6 }
        if hasVHT { return .wifi5 }
        if hasHT { return .wifi4 }
        return .legacy
    }

    public var pmf: WifiPMF { rsn?.pmf ?? .absent }

    /// Sécurité annoncée, d'après RSN puis WPA ; nil sans l'un ni l'autre (ouvert ou WEP :
    /// le bit Privacy des champs fixes n'est pas toujours fourni).
    public var security: WifiSecurity? {
        if let rsn {
            if rsn.hasEnterprise {
                if rsn.hasSuiteB192 { return .wpa3Enterprise }
                // WPA3-Entreprise : PMF obligatoire et plus d'AKM 802.1X SHA-1 (1) ; FT-802.1X (3) reste permis.
                if rsn.pmf == .required, !rsn.ieeeAKMs.contains(1) { return .wpa3Enterprise }
                return .wpa2Enterprise
            }
            if rsn.hasSAE { return rsn.hasPSK ? .wpa3Transition : .wpa3Personal }
            if rsn.hasPSK { return .wpa2Personal }
            if rsn.hasOWE { return .owe }
            return .unknown
        }
        if let wpa {
            let types = Set(wpa.akmSuites.map { $0 & 0xFF })
            return types.contains(1) ? .wpaEnterprise : .wpaPersonal
        }
        return nil
    }

    /// Nom de la borne : élément propriétaire, sinon nil (le nom WPS désigne souvent un modèle).
    public var displayAPName: String? { apName }
}

// MARK: - Parseur

public enum WifiBeaconParser {
    /// Un élément brut : identifiant (et identifiant étendu pour 255), contenu.
    public struct Element: Hashable, Sendable {
        public var id: UInt8
        public var extID: UInt8?
        public var body: [UInt8]
    }

    public static func parse(_ data: Data) -> WifiBeaconInfo {
        parse([UInt8](data))
    }

    /// Décode une suite d'éléments ; accepte aussi une balise précédée de ses 12 octets fixes.
    public static func parse(_ bytes: [UInt8]) -> WifiBeaconInfo {
        var (elements, truncated) = split(bytes)
        var fixed = false
        // Champs fixes devant les éléments : le découpage à 12 tombe juste (et commence par le SSID).
        if bytes.count >= 14, truncated || elements.first?.id != 0 {
            let (shifted, shiftedTruncated) = split(Array(bytes[12...]))
            if !shiftedTruncated, shifted.first?.id == 0 {
                elements = shifted
                truncated = false
                fixed = true
            }
        }
        var info = WifiBeaconInfo()
        info.isTruncated = truncated
        info.hadFixedFields = fixed
        info.elementCount = elements.count
        var widths: [Int] = []
        var streams: [Int] = []
        for element in elements {
            info.elementIDs.append(element.extID.map { 255 * 256 + Int($0) } ?? Int(element.id))
            var reader = ByteReader(element.body)
            switch (element.id, element.extID) {
            case (0, _):
                // SSID : un SSID vide ou tout à zéro est un SSID caché.
                if !element.body.isEmpty, element.body.contains(where: { $0 != 0 }) {
                    info.ssid = String(decoding: element.body, as: UTF8.self)
                }
            case (3, _):
                if let channel = reader.u8() { info.channel = Int(channel) } else { info.isTruncated = true }
            case (5, _):
                if element.body.count >= 2 { info.dtimPeriod = Int(element.body[1]) } else { info.isTruncated = true }
            case (7, _):
                if element.body.count >= 2 {
                    let code = String(decoding: element.body[0..<2], as: UTF8.self)
                    if code.allSatisfy({ $0.isLetter && $0.isASCII }) { info.countryCode = code.uppercased() }
                } else { info.isTruncated = true }
            case (11, _):
                if let stations = reader.u16le(), let utilization = reader.u8() {
                    info.bssLoad = WifiBSSLoad(stationCount: Int(stations), channelUtilization: Int(utilization),
                                               availableCapacity: reader.u16le().map(Int.init))
                } else { info.isTruncated = true }
            case (45, _):
                info.hasHT = true
                // Cap. HT (2), A-MPDU (1), puis masque des MCS reçus : un octet par flux.
                if element.body.count >= 7 {
                    let mask = element.body[3..<7]
                    if let last = mask.lastIndex(where: { $0 != 0 }) { streams.append(last - 3 + 1) }
                } else { info.isTruncated = true }
            case (61, _):
                info.hasHT = true
                if element.body.count >= 2 {
                    if info.channel == nil { info.channel = Int(element.body[0]) }
                    widths.append(element.body[1] & 0x04 != 0 ? 40 : 20)
                } else { info.isTruncated = true }
            case (48, _):
                if let rsn = parseRSN(&reader) { info.rsn = rsn } else { info.isTruncated = true }
            case (54, _):
                if let mdid = reader.u16le() {
                    let caps = reader.u8() ?? 0
                    info.mobilityDomain = WifiMobilityDomain(mdid: mdid, overDS: caps & 0x01 != 0, resourceRequest: caps & 0x02 != 0)
                } else { info.isTruncated = true }
            case (70, _):
                info.radioMeasurement = true
                if let first = element.body.first { info.neighborReport = first & 0x02 != 0 } else { info.isTruncated = true }
            case (127, _):
                // Bit 19 : BSS Transition.
                if element.body.count >= 3 { info.bssTransition = element.body[2] & 0x08 != 0 }
            case (133, _):
                parseCiscoCCX(element.body, into: &info)
            case (191, _):
                info.hasVHT = true
                if element.body.count >= 6 {
                    if let n = streamsFromMap(UInt16(element.body[4]) | UInt16(element.body[5]) << 8) { streams.append(n) }
                } else { info.isTruncated = true }
            case (192, _):
                info.hasVHT = true
                if element.body.count >= 3 {
                    if let width = vhtWidth(code: element.body[0], seg0: element.body[1], seg1: element.body[2]) { widths.append(width) }
                } else { info.isTruncated = true }
            case (221, _):
                parseVendor(element.body, into: &info)
            case (255, 35?):
                info.hasHE = true
                // Identifiant étendu retiré : MAC (6), PHY (11), puis carte des MCS reçus ≤ 80 MHz.
                if element.body.count >= 19 {
                    if let n = streamsFromMap(UInt16(element.body[17]) | UInt16(element.body[18]) << 8) { streams.append(n) }
                } else { info.isTruncated = true }
            case (255, 36?):
                info.hasHE = true
                parseHEOperation(element.body, into: &info, widths: &widths)
            case (255, 108?):
                info.hasEHT = true
            case (255, 106?):
                info.hasEHT = true
                parseEHTOperation(element.body, into: &info, widths: &widths)
            default:
                break
            }
        }
        info.channelWidthMHz = widths.max()
        info.spatialStreams = streams.max()
        return info
    }

    /// Découpe en éléments ; s'arrête au premier élément qui déborde.
    public static func split(_ bytes: [UInt8]) -> (elements: [Element], truncated: Bool) {
        var elements: [Element] = []
        var index = 0
        while index < bytes.count {
            guard index + 2 <= bytes.count else { return (elements, true) }
            let id = bytes[index], length = Int(bytes[index + 1])
            let start = index + 2, end = start + length
            guard end <= bytes.count else { return (elements, true) }
            var body = Array(bytes[start..<end])
            var extID: UInt8?
            if id == 255 {
                guard !body.isEmpty else { index = end; continue }
                extID = body.removeFirst()
            }
            elements.append(Element(id: id, extID: extID, body: body))
            index = end
        }
        return (elements, false)
    }

    // MARK: Éléments particuliers

    static func parseRSN(_ reader: inout ByteReader, wpa: Bool = false) -> WifiRSNInfo? {
        guard let version = reader.u16le() else { return nil }
        var info = WifiRSNInfo(version: Int(version))
        // Chaque champ est facultatif à partir de la fin : un élément court reste valable.
        guard !reader.isAtEnd else { return info }
        guard let group = reader.u32be() else { return nil }
        info.groupCipher = group
        guard !reader.isAtEnd else { return info }
        guard let pairwiseCount = reader.u16le(), let pairwise = reader.suites(Int(pairwiseCount)) else { return nil }
        info.pairwiseCiphers = pairwise
        guard !reader.isAtEnd else { return info }
        guard let akmCount = reader.u16le(), let akms = reader.suites(Int(akmCount)) else { return nil }
        info.akmSuites = akms
        if !wpa, let caps = reader.u16le() { info.capabilities = caps }
        return info
    }

    static func vhtWidth(code: UInt8, seg0: UInt8, seg1: UInt8) -> Int? {
        switch code {
        case 0: return nil // 20 ou 40 MHz : donné par HT Operation.
        case 1: return 80 + (seg1 != 0 && abs(Int(seg1) - Int(seg0)) >= 8 ? 80 : 0)
        case 2, 3: return 160
        default: return nil
        }
    }

    /// Nombre de flux d'une carte des MCS (2 bits par flux, 3 : non pris en charge).
    static func streamsFromMap(_ map: UInt16) -> Int? {
        var count = 0
        for stream in 0..<8 where (map >> (2 * stream)) & 0x3 != 0x3 { count = stream + 1 }
        return count == 0 ? nil : count
    }

    static func parseHEOperation(_ body: [UInt8], into info: inout WifiBeaconInfo, widths: inout [Int]) {
        guard body.count >= 6 else { info.isTruncated = true; return }
        let params = UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16
        var offset = 6
        if params & (1 << 14) != 0 {
            guard body.count >= offset + 3 else { info.isTruncated = true; return }
            if let width = vhtWidth(code: body[offset], seg0: body[offset + 1], seg1: body[offset + 2]) { widths.append(width) }
            offset += 3
        }
        if params & (1 << 15) != 0 { offset += 1 }
        if params & (1 << 17) != 0 {
            info.he6GHz = true
            guard body.count >= offset + 4 else { info.isTruncated = true; return }
            if info.channel == nil { info.channel = Int(body[offset]) }
            // 0 : 20, 1 : 40, 2 : 80, 3 : 160 ou 80+80 MHz (compté comme 160).
            switch body[offset + 1] & 0x03 {
            case 0: widths.append(20)
            case 1: widths.append(40)
            case 2: widths.append(80)
            default: widths.append(160)
            }
        }
    }

    static func parseEHTOperation(_ body: [UInt8], into info: inout WifiBeaconInfo, widths: inout [Int]) {
        guard body.count >= 5 else { info.isTruncated = true; return }
        guard body[0] & 0x01 != 0 else { return }
        guard body.count >= 8 else { info.isTruncated = true; return }
        switch body[5] & 0x07 {
        case 0: widths.append(20)
        case 1: widths.append(40)
        case 2: widths.append(80)
        case 3: widths.append(160)
        case 4: widths.append(320)
        default: break
        }
    }

    /// Élément Cisco 133 (CCX1 CKIP + nom) : 10 octets, nom sur 16, nombre de clients.
    static func parseCiscoCCX(_ body: [UInt8], into info: inout WifiBeaconInfo) {
        guard body.count >= 26 else { info.isTruncated = true; return }
        if let name = cleanName(body[10..<26]) {
            info.apName = name
            info.apNameSource = .cisco
        }
        if body.count >= 27 { info.ciscoClientCount = Int(body[26]) }
    }

    static func parseVendor(_ body: [UInt8], into info: inout WifiBeaconInfo) {
        guard body.count >= 4 else { info.isTruncated = true; return }
        let oui = UInt32(body[0]) << 16 | UInt32(body[1]) << 8 | UInt32(body[2])
        let rest = Array(body[3...])
        switch oui {
        case 0x0050F2: // Microsoft : WPA (1), WMM (2), WPS (4).
            switch rest[0] {
            case 1:
                var reader = ByteReader(Array(rest[1...]))
                if let wpa = parseRSN(&reader, wpa: true) { info.wpa = wpa } else { info.isTruncated = true }
            case 4:
                parseWPS(Array(rest[1...]), into: &info)
            default: break
            }
        case 0x506F9A: // Wi-Fi Alliance.
            switch rest[0] {
            case 0x10: info.hotspot20 = true
            case 0x1C: info.oweTransition = true
            default: break
            }
        case 0x000B86: // Aruba (HPE) : sous-type 3 « AP Name », un octet, puis le nom.
            var start: Int?
            if rest.count >= 3, rest[0] == 3 { start = 2 }
            else if rest.count >= 4, rest[0] == 1, rest[1] == 3 { start = 3 }
            if let start, let name = cleanName(rest[start...]) {
                info.apName = name
                info.apNameSource = .aruba
            }
        case 0x00090F: // Fortinet : type 10 (petit-boutiste sur 2 octets), puis TLV nom, modèle, série.
            guard rest.count >= 2, UInt16(rest[0]) | UInt16(rest[1]) << 8 == 10 else { return }
            var index = 2
            while index + 2 <= rest.count {
                let type = rest[index], length = Int(rest[index + 1])
                let start = index + 2, end = start + length
                guard end <= rest.count else { info.isTruncated = true; return }
                let value = cleanName(rest[start..<end])
                switch type {
                case 1:
                    if let value { info.apName = value; info.apNameSource = .fortinet }
                case 2: info.apModel = value
                case 3: info.apSerial = value
                default: break
                }
                index = end
            }
        default:
            break
        }
    }

    /// Attributs WPS (gros-boutistes, 2 + 2 octets) : nom, fabricant, modèle.
    static func parseWPS(_ body: [UInt8], into info: inout WifiBeaconInfo) {
        var index = 0
        while index + 4 <= body.count {
            let type = UInt16(body[index]) << 8 | UInt16(body[index + 1])
            let length = Int(UInt16(body[index + 2]) << 8 | UInt16(body[index + 3]))
            let start = index + 4, end = start + length
            guard end <= body.count else { info.isTruncated = true; return }
            let value = cleanName(body[start..<end])
            switch type {
            case 0x1011: info.wpsDeviceName = value
            case 0x1021: info.wpsManufacturer = value
            case 0x1023: info.wpsModel = value
            default: break
            }
            index = end
        }
    }

    /// Texte lisible : jusqu'au premier octet nul, caractères de contrôle retirés, 64 au plus.
    static func cleanName<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        let raw = Array(bytes.prefix { $0 != 0 })
        let text = String(decoding: raw, as: UTF8.self)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\u{FFFD}" }
        let cleaned = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(64))
    }
}

/// Lecture bornée : chaque lecture hors limites renvoie nil au lieu de planter.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16le() -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// Suite (OUI + type) sur 4 octets, lue dans l'ordre des octets.
    mutating func u32be() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func suites(_ count: Int) -> [UInt32]? {
        guard count >= 0, offset + 4 * count <= bytes.count else { return nil }
        return (0..<count).map { _ in u32be()! }
    }
}
