import Foundation

// Note 29 : relecture automatique, sans relancer de scan, de la FortiGate du site actif
// (FortiSwitch, emplacements, ARP et DHCP), de ses bornes FortiAP et de ses switchs SNMP.
// Ce fichier : réglage par site, parties relues, état de chaque partie et conditions de pause.
// Aucun secret ici : seules des durées et des clés de site.

// MARK: - Intervalle

/// Intervalle de relecture d'un site, en minutes (0 : désactivé).
public enum AutoRefreshInterval: Int, CaseIterable, Codable, Sendable, Identifiable {
    case off = 0
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    /// Valeur d'un site jamais réglé. 5 min : assez souvent pour suivre un appareil qui change de
    /// port pendant une intervention, assez peu pour ne pas charger la FortiGate (une lecture GET
    /// toutes les 5 min, comme une sonde de la Surveillance), et seulement pour le site actif.
    public static let standard: AutoRefreshInterval = .five

    public var id: Int { rawValue }
    public var isOn: Bool { self != .off }
    public var seconds: TimeInterval { TimeInterval(rawValue) * 60 }

    /// « Désactivée », « 1 min », « 5 min ».
    public var label: String {
        self == .off ? "Désactivée" : "\(rawValue)\u{00A0}min"
    }

    /// Libellé des menus : « Toutes les minutes », « Toutes les 5 min ».
    public var menuLabel: String {
        switch self {
        case .off: return "Désactivée"
        case .one: return "Toutes les minutes"
        default: return "Toutes les \(rawValue)\u{00A0}min"
        }
    }

    /// Valeur enregistrée ; une valeur inconnue prend l'intervalle permis le plus proche
    /// (jamais plus court que demandé, sauf au-delà de 30 min).
    public init(minutes: Int) {
        if minutes <= 0 { self = .off; return }
        self = Self.allCases.first { $0.isOn && $0.rawValue >= minutes } ?? .thirty
    }
}

// MARK: - Réglage par site

/// Intervalle de chaque site (clé `SiteFiles.key`, « sans-site » quand aucun site n'est actif).
/// Enregistré dans les préférences : aucune donnée sensible.
public struct AutoRefreshSettings: Codable, Equatable, Sendable {
    public private(set) var intervals: [String: Int]

    public init(intervals: [String: Int] = [:]) {
        self.intervals = intervals
    }

    public func interval(forSiteKey key: String) -> AutoRefreshInterval {
        intervals[key].map(AutoRefreshInterval.init(minutes:)) ?? .standard
    }

    /// Vrai si le site a un réglage à lui (sinon : la valeur par défaut).
    public func isCustom(_ key: String) -> Bool { intervals[key] != nil }

    public mutating func set(_ interval: AutoRefreshInterval, forSiteKey key: String) {
        intervals[key] = interval.rawValue
    }

    /// Oublie les sites supprimés (la clé « sans-site » est toujours gardée).
    public mutating func prune(keeping keys: Set<String>) {
        intervals = intervals.filter { keys.contains($0.key) || $0.key == SiteFiles.noSiteKey }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Lecture tolérante : données illisibles → réglages par défaut.
    public static func decode(_ data: Data?) -> AutoRefreshSettings {
        guard let data, let value = try? JSONDecoder().decode(AutoRefreshSettings.self, from: data) else { return AutoRefreshSettings() }
        return value
    }

    enum CodingKeys: String, CodingKey { case intervals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = ((try? c.decodeIfPresent([String: Int].self, forKey: .intervals)) ?? nil) ?? [:]
        intervals = raw.mapValues { AutoRefreshInterval(minutes: $0).rawValue }
    }
}

// MARK: - Parties relues

/// Ce que la relecture automatique relit. FortiGate et bornes passent par la même FortiGate :
/// jamais deux lectures à la fois vers elle.
public enum AutoRefreshPart: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    /// FortiSwitch, ports, appareils détectés, table ARP et baux DHCP (emplacements des appareils).
    case fortiGate
    /// Bornes FortiAP, clients Wi-Fi, SSID.
    case wifi
    /// Switchs SNMP associés au site actif.
    case snmp

    public var label: String {
        switch self {
        case .fortiGate: return "FortiGate (FortiSwitch, ARP, DHCP)"
        case .wifi: return "Bornes FortiAP"
        case .snmp: return "Switchs SNMP"
        }
    }

    /// Partie lue par l'API REST de la FortiGate.
    public var usesFortiGate: Bool { self != .snmp }

    public static func < (a: AutoRefreshPart, b: AutoRefreshPart) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// État d'une partie pour le site actif.
public struct AutoRefreshTrack: Equatable, Sendable {
    /// Quelque chose à relire (FortiGate du site prête, switch SNMP avec sa communauté).
    public var available: Bool
    /// Raison qui demande une action (jeton absent, certificat à accepter) : aucun nouvel essai
    /// tant qu'elle n'est pas réglée.
    public var blockedReason: String?
    /// Dernière lecture réussie, quelle qu'en soit l'origine (relecture automatique, bouton,
    /// fin de scan, sonde de la Surveillance).
    public var lastRead: Date?
    /// Dernier essai de la relecture automatique.
    public var lastAttempt: Date?
    /// Échecs de suite (FortiGate ou switch injoignable, erreur de l'API) : délai croissant.
    public var failures: Int
    /// Lecture en cours, quelle qu'en soit l'origine.
    public var inFlight: Bool

    public init(available: Bool = true, blockedReason: String? = nil, lastRead: Date? = nil, lastAttempt: Date? = nil,
                failures: Int = 0, inFlight: Bool = false) {
        self.available = available
        self.blockedReason = blockedReason
        self.lastRead = lastRead
        self.lastAttempt = lastAttempt
        self.failures = failures
        self.inFlight = inFlight
    }

    /// Lecture réussie faite ailleurs (bouton, fin de scan, Surveillance) : la prochaine relecture
    /// part de là, et le délai croissant est oublié.
    public mutating func observeRead(at date: Date) {
        guard lastRead.map({ date > $0 }) ?? true else { return }
        lastRead = date
        failures = 0
    }

    public mutating func begin(at date: Date) {
        lastAttempt = date
        inFlight = true
    }

    public mutating func succeed(at date: Date) {
        inFlight = false
        failures = 0
        if lastRead.map({ date > $0 }) ?? true { lastRead = date }
    }

    public mutating func fail(at date: Date) {
        inFlight = false
        failures += 1
    }

    /// Lecture abandonnée (site changé, scan lancé) : ni réussite ni échec.
    public mutating func cancel() {
        inFlight = false
    }
}

// MARK: - Conditions et pauses

/// Ce qui empêche toute relecture, quel que soit l'intervalle.
public struct AutoRefreshConditions: Equatable, Sendable {
    /// Le site réglé est le site actif (les autres sites ne sont jamais relus).
    public var siteIsActive: Bool
    public var scanning: Bool
    public var asleep: Bool
    public var online: Bool
    /// Délai de grâce après le réveil ou le retour du réseau (DHCP, Wi-Fi à rejoindre).
    public var resumeAfter: Date?

    public init(siteIsActive: Bool = true, scanning: Bool = false, asleep: Bool = false, online: Bool = true,
                resumeAfter: Date? = nil) {
        self.siteIsActive = siteIsActive
        self.scanning = scanning
        self.asleep = asleep
        self.online = online
        self.resumeAfter = resumeAfter
    }
}

/// Raison d'une pause de la relecture automatique.
public enum AutoRefreshPause: Equatable, Sendable {
    case disabled
    case notActiveSite
    case scanning
    case asleep
    case offline
    /// Réveil ou retour du réseau : on laisse le temps au Mac de rejoindre le réseau.
    case resuming(until: Date)
    case nothingToRead
    case needsAttention(String)

    /// Texte court, après « Relu il y a 2 min · ».
    public var label: String {
        switch self {
        case .disabled: return "relecture automatique désactivée"
        case .notActiveSite: return "en pause\u{00A0}: ce site n’est pas le site actif"
        case .scanning: return "en pause pendant le scan"
        case .asleep: return "en pause\u{00A0}: Mac en veille"
        case .offline: return "en pause\u{00A0}: hors réseau"
        case .resuming: return "reprise dans un instant"
        case .nothingToRead: return "rien à relire automatiquement"
        case .needsAttention(let reason): return "en pause\u{00A0}: \(reason)"
        }
    }
}

/// Décision du planificateur à un instant donné.
public enum AutoRefreshDecision: Equatable, Sendable {
    /// Rien ne sera relu tant que la raison dure.
    case paused(AutoRefreshPause)
    /// Prochaine relecture à cette heure ; `retrying` : après un échec (délai croissant).
    case wait(until: Date, retrying: Bool, failures: Int)
    /// Relire ces parties maintenant.
    case read(Set<AutoRefreshPart>)

    public var nextDate: Date? {
        if case .wait(let date, _, _) = self { return date }
        if case .paused(.resuming(let date)) = self { return date }
        return nil
    }

    public var pause: AutoRefreshPause? {
        if case .paused(let reason) = self { return reason }
        return nil
    }
}
