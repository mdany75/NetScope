import Foundation

// « Ouvrir une fiche » : suggestions en direct parmi les appareils connus (résultats du Scanner du
// site actif et des autres sites, fiches de l'Inventaire, appareils saisis à la main), par IP, nom,
// nom d'hôte, MAC ou fabricant. Recherche locale seulement.

/// Un appareil connu que le champ « Ouvrir une fiche » peut proposer.
public struct DeviceLookupCandidate: Identifiable, Hashable, Sendable {
    /// D'où vient l'appareil (l'ordre de `Origin.allCases` est celui de la priorité).
    public enum Origin: Int, Hashable, Sendable, CaseIterable, Comparable {
        /// Résultats du Scanner du site actif.
        case scanner
        /// Appareil saisi à la main dans l'écran Appareil.
        case manual
        /// Fiche d'inventaire (absente des résultats du Scanner).
        case inventory
        /// Résultats enregistrés d'un autre site.
        case otherSite

        public static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Identifiant unique dans la liste (choisi par l'écran : « scan|10.0.0.1 », « inv|site|clé »…).
    public var id: String
    public var origin: Origin
    /// Site de l'appareil (nil : site actif).
    public var siteKey: String?
    /// Nom du site à afficher (« Laval »), pour un autre site.
    public var siteName: String?
    public var ip: IPv4Address?
    public var mac: MACAddress?
    /// Nom donné par l'utilisateur (prioritaire à l'affichage).
    public var name: String?
    public var hostname: String?
    public var vendor: String?
    public var type: DeviceType
    public var isOnline: Bool?
    public var lastSeen: Date?

    public init(id: String, origin: Origin, siteKey: String? = nil, siteName: String? = nil, ip: IPv4Address?,
                mac: MACAddress? = nil, name: String? = nil, hostname: String? = nil, vendor: String? = nil,
                type: DeviceType = .inconnu, isOnline: Bool? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.origin = origin
        self.siteKey = siteKey
        self.siteName = siteName
        self.ip = ip
        self.mac = mac
        self.name = name
        self.hostname = hostname
        self.vendor = vendor
        self.type = type
        self.isOnline = isOnline
        self.lastSeen = lastSeen
    }

    /// Candidat tiré d'un appareil (Scanner, résultats d'un site, saisie à la main).
    public init(device: Device, origin: Origin, id: String? = nil, siteKey: String? = nil, siteName: String? = nil) {
        self.init(id: id ?? "\(origin.rawValue)|\(siteKey ?? "")|\(device.id)", origin: origin, siteKey: siteKey,
                  siteName: siteName, ip: device.ip, mac: device.mac, name: device.customName,
                  hostname: device.hostnameLabel, vendor: device.vendor, type: device.deviceType,
                  isOnline: device.isOnline, lastSeen: device.lastSeen)
    }

    /// Nom à afficher : nom donné, sinon nom d'hôte, sinon l'adresse.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let hostname, !hostname.isEmpty { return hostname }
        return ip?.description ?? mac?.formatted(.upperColon) ?? "Appareil"
    }

    /// Clé de doublon : même site et même MAC, sinon même site et même IP.
    var duplicateKey: String {
        let site = siteKey ?? ""
        if let mac { return site + "|mac|" + mac.description }
        return site + "|ip|" + (ip?.description ?? id)
    }
}

/// Champ qui a fait trouver une suggestion.
public enum DeviceLookupField: String, Sendable, Hashable {
    case ip, mac, name, hostname, vendor

    public var label: String {
        switch self {
        case .ip: return "IP"
        case .mac: return "MAC"
        case .name: return "Nom"
        case .hostname: return "Nom d’hôte"
        case .vendor: return "Fabricant"
        }
    }
}

/// Une suggestion classée.
public struct DeviceLookupMatch: Identifiable, Hashable, Sendable {
    public var candidate: DeviceLookupCandidate
    public var field: DeviceLookupField
    public var score: Int
    /// La saisie désigne exactement cet appareil (même IP, même MAC ou même nom).
    public var isExact: Bool

    public var id: String { candidate.id }
}

public enum DeviceLookup {
    /// Retire les doublons (même site, même MAC, sinon même IP) en gardant le premier selon la
    /// priorité des origines (Scanner, saisie, Inventaire, autre site), puis l'ordre reçu.
    public static func deduplicated(_ candidates: [DeviceLookupCandidate]) -> [DeviceLookupCandidate] {
        let ordered = candidates.enumerated().sorted {
            $0.element.origin != $1.element.origin ? $0.element.origin < $1.element.origin : $0.offset < $1.offset
        }
        var seenKeys = Set<String>()
        var seenIPs = Set<String>()
        var kept: [DeviceLookupCandidate] = []
        for (_, candidate) in ordered {
            let site = candidate.siteKey ?? ""
            let ipKey = candidate.ip.map { site + "|ip|" + $0.description }
            if seenKeys.contains(candidate.duplicateKey) { continue }
            // Sans MAC : un appareil de même IP dans le même site est le même.
            if candidate.mac == nil, let ipKey, seenIPs.contains(ipKey) { continue }
            seenKeys.insert(candidate.duplicateKey)
            if let ipKey { seenIPs.insert(ipKey) }
            kept.append(candidate)
        }
        return kept
    }

    /// Suggestions pour la saisie, les meilleures d'abord (au plus `limit`).
    ///
    /// Classement : IP, MAC ou nom identiques ; puis début d'IP (« 10.182 ») ; début de MAC (sans
    /// séparateurs, « 94ddf8 ») ; début de nom ou d'un mot du nom ; nom contenant la saisie ; fabricant.
    /// À score égal : appareils du Scanner, puis en ligne, puis par adresse.
    public static func suggestions(for text: String, in candidates: [DeviceLookupCandidate],
                                   limit: Int = 8) -> [DeviceLookupMatch] {
        let query = fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let hexQuery = macDigits(query)
        let parsedIP = IPv4Address(query)
        let parsedMAC = macFromQuery(query)
        var matches: [DeviceLookupMatch] = []
        for candidate in candidates {
            if let match = score(candidate, query: query, hexQuery: hexQuery, ip: parsedIP, mac: parsedMAC) {
                matches.append(match)
            }
        }
        matches.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.origin != b.candidate.origin { return a.candidate.origin < b.candidate.origin }
            let onlineA = a.candidate.isOnline == true, onlineB = b.candidate.isOnline == true
            if onlineA != onlineB { return onlineA }
            switch (a.candidate.ip, b.candidate.ip) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.candidate.displayName.localizedStandardCompare(b.candidate.displayName) == .orderedAscending
            }
        }
        return Array(matches.prefix(max(0, limit)))
    }

    /// Le premier appareil désigné exactement par la saisie (IP, MAC ou nom identiques), s'il y en a un seul
    /// au meilleur rang : ce que la touche Entrée ouvre sans autre choix.
    public static func exactMatch(for text: String, in candidates: [DeviceLookupCandidate]) -> DeviceLookupMatch? {
        let found = suggestions(for: text, in: candidates, limit: 2)
        guard let first = found.first, first.isExact else { return nil }
        return first
    }

    // MARK: Score

    private static func score(_ candidate: DeviceLookupCandidate, query: String, hexQuery: String?,
                              ip: IPv4Address?, mac: MACAddress?) -> DeviceLookupMatch? {
        var best: (DeviceLookupField, Int, Bool)?
        func consider(_ field: DeviceLookupField, _ value: Int, exact: Bool = false) {
            if best == nil || value > best!.1 { best = (field, value, exact) }
        }
        // Adresse IP.
        if let address = candidate.ip {
            let text = address.description
            if let ip, ip == address {
                consider(.ip, 1_000, exact: true)
            } else if text.hasPrefix(query) {
                // « 10.182.122.1 » avant « 10.182.122.100 » : plus la saisie couvre l'adresse, mieux c'est.
                consider(.ip, 700 + min(99, query.count * 99 / max(1, text.count)))
            } else if query.count >= 3, query.contains("."), text.contains(query) {
                consider(.ip, 450)
            }
        }
        // Adresse MAC (chiffres seulement, quelle que soit l'écriture).
        if let candidateMAC = candidate.mac {
            let digits = candidateMAC.formatted(.bare)
            if let mac, mac == candidateMAC {
                consider(.mac, 1_000, exact: true)
            } else if let hexQuery, hexQuery.count >= 4 {
                if digits.hasPrefix(hexQuery) { consider(.mac, 650) }
                else if hexQuery.count >= 6, digits.contains(hexQuery) { consider(.mac, 500) }
            }
        }
        // Noms.
        for (field, value) in [(DeviceLookupField.name, candidate.name), (.hostname, candidate.hostname)] {
            guard let value, !value.isEmpty else { continue }
            let folded = fold(value)
            if folded == query {
                consider(field, 900, exact: true)
            } else if folded.hasPrefix(query) {
                consider(field, 600)
            } else if words(folded).contains(where: { $0.hasPrefix(query) }) {
                consider(field, 550)
            } else if query.count >= 2, folded.contains(query) {
                consider(field, 400)
            }
        }
        // Fabricant.
        if let vendor = candidate.vendor, !vendor.isEmpty, query.count >= 2 {
            let folded = fold(vendor)
            if folded.hasPrefix(query) || words(folded).contains(where: { $0.hasPrefix(query) }) {
                consider(.vendor, 300)
            } else if query.count >= 3, folded.contains(query) {
                consider(.vendor, 200)
            }
        }
        guard let best else { return nil }
        return DeviceLookupMatch(candidate: candidate, field: best.0, score: best.1, isExact: best.2)
    }

    /// Minuscules, sans accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
    }

    /// Mots d'un nom (« SW-ETG2-01 » → sw, etg2, 01).
    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// Chiffres hexadécimaux d'une saisie qui ressemble à un morceau de MAC (séparateurs « : - . »
    /// retirés) ; nil si elle contient autre chose.
    static func macDigits(_ query: String) -> String? {
        let hex = Set("0123456789abcdef")
        let separators = Set(":-.")
        guard query.allSatisfy({ hex.contains($0) || separators.contains($0) }) else { return nil }
        // « 10.182 » est un début d'IP, pas de MAC.
        if query.allSatisfy({ $0.isNumber || $0 == "." }), query.contains(".") { return nil }
        let digits = query.filter(hex.contains)
        return digits.isEmpty ? nil : digits
    }

    private static func macFromQuery(_ query: String) -> MACAddress? {
        switch DeviceEntry.parse(query) {
        case .mac(let mac), .ambiguous(let mac, _): return mac
        default: return nil
        }
    }
}
