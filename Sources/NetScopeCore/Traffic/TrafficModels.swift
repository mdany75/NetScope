import Foundation

// Note 54 : trafic lu par FortiView sur la FortiGate de chaque site (API REST de FortiOS, lecture
// seule). Modèles purs, sans réseau : vues (sources, destinations, applications…), périodes,
// lignes agrégées, sessions, liens WAN et relevé d'une FortiGate.

/// Période demandée à FortiView.
public enum TrafficPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case realtime
    case fiveMinutes = "5min"
    case hour = "1h"
    case day = "24h"
    case week = "7j"

    public var id: String { rawValue }

    /// Libellé du contrôle segmenté.
    public var label: String {
        switch self {
        case .realtime: return "Temps réel"
        case .fiveMinutes: return "5\u{00A0}min"
        case .hour: return "1\u{00A0}h"
        case .day: return "24\u{00A0}h"
        case .week: return "7\u{00A0}j"
        }
    }

    /// « en temps réel », « sur les 24 dernières heures ».
    public var span: String {
        switch self {
        case .realtime: return "en temps réel"
        case .fiveMinutes: return "sur les 5 dernières minutes"
        case .hour: return "sur la dernière heure"
        case .day: return "sur les 24 dernières heures"
        case .week: return "sur les 7 derniers jours"
        }
    }

    /// Durée couverte (nil : sessions en cours).
    public var seconds: TimeInterval? {
        switch self {
        case .realtime: return nil
        case .fiveMinutes: return 300
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }

    public var isRealtime: Bool { self == .realtime }
}

/// Vue FortiView (onglet de l'écran Trafic).
public enum TrafficView: String, CaseIterable, Codable, Sendable, Identifiable {
    case sources, destinations, applications, webCategories, interfaces, policies, sessions, threats

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sources: return "Sources"
        case .destinations: return "Destinations"
        case .applications: return "Applications"
        case .webCategories: return "Catégories web"
        case .interfaces: return "Interfaces"
        case .policies: return "Politiques"
        case .sessions: return "Sessions"
        case .threats: return "Menaces"
        }
    }

    public var symbol: String {
        switch self {
        case .sources: return "desktopcomputer"
        case .destinations: return "globe"
        case .applications: return "app.badge"
        case .webCategories: return "list.bullet.rectangle"
        case .interfaces: return "point.3.connected.trianglepath.dotted"
        case .policies: return "checklist"
        case .sessions: return "arrow.left.arrow.right"
        case .threats: return "exclamationmark.shield"
        }
    }

    /// Valeurs de « report_by » essayées dans l'ordre (les noms changent d'une version de FortiOS à
    /// l'autre) ; vide pour les sessions, lues par /monitor/firewall/session.
    public var reportBy: [String] {
        switch self {
        case .sources: return ["source"]
        case .destinations: return ["destination"]
        case .applications: return ["application"]
        case .webCategories: return ["web-category", "category", "website"]
        case .interfaces: return ["interface", "srcintf", "dstintf"]
        case .policies: return ["policy"]
        case .threats: return ["threat"]
        case .sessions: return []
        }
    }

    /// Vues lues par FortiView (toutes sauf les sessions).
    public static let fortiView: [TrafficView] = allCases.filter { $0 != .sessions }
}

/// Critère de tri des tableaux et des requêtes FortiView (« sort_by »).
public enum TrafficSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case bandwidth, bytes, sessions

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bandwidth: return "Débit"
        case .bytes: return "Octets"
        case .sessions: return "Sessions"
        }
    }

    /// Valeur envoyée à FortiView : le débit n'a de sens qu'en temps réel.
    public func apiValue(for period: TrafficPeriod) -> String {
        switch self {
        case .bandwidth: return period.isRealtime ? "bandwidth" : "bytes"
        case .bytes: return "bytes"
        case .sessions: return "sessions"
        }
    }
}

/// Niveau d'une menace (FortiGuard : critique, élevé, moyen, faible, info).
public enum TrafficThreatLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case critical = 0, high, medium, low, info

    public var label: String {
        switch self {
        case .critical: return "Critique"
        case .high: return "Élevé"
        case .medium: return "Moyen"
        case .low: return "Faible"
        case .info: return "Info"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Texte ou nombre de FortiOS : « critical », « high », 4 (échelle 0-4 ou 1-5), « 50 » (score).
    public static func parse(_ value: Any?) -> TrafficThreatLevel? {
        if let text = FortiJSON.string(value)?.lowercased() {
            if text.hasPrefix("crit") { return .critical }
            if text.hasPrefix("high") || text.hasPrefix("élev") || text.hasPrefix("elev") { return .high }
            if text.hasPrefix("med") || text.hasPrefix("moy") { return .medium }
            if text.hasPrefix("low") || text.hasPrefix("faib") { return .low }
            if text.hasPrefix("info") || text.hasPrefix("notice") { return .info }
        }
        guard let number = FortiJSON.int(value) else { return nil }
        // Score de menace (crscore : 5, 10, 30, 50) ou niveau 0-4.
        switch number {
        case 50...: return .critical
        case 30..<50: return .high
        case 10..<30: return .medium
        case 5..<10: return .low
        case 4: return .critical
        case 3: return .high
        case 2: return .medium
        case 1: return .low
        default: return .info
        }
    }
}

/// Une ligne agrégée d'une vue FortiView (une source, une application, une menace…).
public struct TrafficEntry: Codable, Hashable, Sendable, Identifiable {
    public var site: String
    public var view: TrafficView
    /// Clé de regroupement dans la vue (adresse, nom d'application, identifiant de politique…).
    public var key: String
    /// Nom affiché.
    public var name: String
    public var ip: IPv4Address?
    public var mac: MACAddress?
    public var hostname: String?
    public var user: String?
    public var interface: String?
    public var country: String?
    /// Catégorie d'application ou catégorie web.
    public var category: String?
    public var sentBytes: UInt64
    public var receivedBytes: UInt64
    /// Débit en bits par seconde (temps réel) ; 0 si inconnu.
    public var bandwidth: Double
    public var sessions: Int
    /// Menaces : nombre d'événements.
    public var incidents: Int
    /// Menaces : événements bloqués.
    public var blocked: Int
    public var threatLevel: TrafficThreatLevel?
    /// Menaces : type (« IPS », « Antivirus », « Filtrage web », « Botnet »).
    public var threatType: String?
    /// Application : risque 1 (faible) à 5 (critique).
    public var risk: Int?
    public var policyID: Int?
    /// Action (« bloqué », « autorisé ») quand FortiView la donne.
    public var action: String?

    public init(site: String, view: TrafficView, key: String, name: String, ip: IPv4Address? = nil, mac: MACAddress? = nil,
                hostname: String? = nil, user: String? = nil, interface: String? = nil, country: String? = nil,
                category: String? = nil, sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0, bandwidth: Double = 0,
                sessions: Int = 0, incidents: Int = 0, blocked: Int = 0, threatLevel: TrafficThreatLevel? = nil,
                threatType: String? = nil, risk: Int? = nil, policyID: Int? = nil, action: String? = nil) {
        self.site = site
        self.view = view
        self.key = key
        self.name = name
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.user = user
        self.interface = interface
        self.country = country
        self.category = category
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
        self.bandwidth = bandwidth
        self.sessions = sessions
        self.incidents = incidents
        self.blocked = blocked
        self.threatLevel = threatLevel
        self.threatType = threatType
        self.risk = risk
        self.policyID = policyID
        self.action = action
    }

    /// « Siège|sources|10.182.122.117 » : jamais deux sites confondus.
    public var id: String { "\(site)|\(view.rawValue)|\(key)" }

    public var bytes: UInt64 { sentBytes.addingReportingOverflow(receivedBytes).overflow ? .max : sentBytes + receivedBytes }

    /// Menace entièrement bloquée (aucun événement laissé passer).
    public var isBlocked: Bool {
        if incidents > 0, blocked >= incidents { return true }
        guard let action = action?.lowercased() else { return false }
        return ["block", "blocked", "bloqué", "bloque", "dropped", "deny", "denied", "reset", "quarantine"].contains { action.contains($0) }
    }
}

/// Session en cours (tableau « Sessions »).
public struct TrafficSession: Codable, Hashable, Sendable, Identifiable {
    public var site: String
    public var source: IPv4Address?
    public var sourcePort: Int?
    public var destination: IPv4Address?
    public var destinationPort: Int?
    /// « TCP », « UDP », « ICMP ».
    public var proto: String
    public var application: String?
    public var sourceInterface: String?
    public var destinationInterface: String?
    public var policyID: Int?
    public var sentBytes: UInt64
    public var receivedBytes: UInt64
    /// Durée en secondes.
    public var duration: Int?
    public var country: String?
    public var user: String?
    /// Numéro de session de FortiOS (sinon un numéro d'ordre).
    public var serial: String

    public init(site: String, source: IPv4Address?, sourcePort: Int? = nil, destination: IPv4Address?, destinationPort: Int? = nil,
                proto: String, application: String? = nil, sourceInterface: String? = nil, destinationInterface: String? = nil,
                policyID: Int? = nil, sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0, duration: Int? = nil,
                country: String? = nil, user: String? = nil, serial: String) {
        self.site = site
        self.source = source
        self.sourcePort = sourcePort
        self.destination = destination
        self.destinationPort = destinationPort
        self.proto = proto
        self.application = application
        self.sourceInterface = sourceInterface
        self.destinationInterface = destinationInterface
        self.policyID = policyID
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
        self.duration = duration
        self.country = country
        self.user = user
        self.serial = serial
    }

    public var id: String { "\(site)|\(serial)" }
    public var bytes: UInt64 { sentBytes.addingReportingOverflow(receivedBytes).overflow ? .max : sentBytes + receivedBytes }
}

/// Lien (interface) de la FortiGate, avec sa capacité pour calculer la charge.
public struct TrafficLink: Codable, Hashable, Sendable, Identifiable {
    public var site: String
    public var name: String
    public var alias: String?
    /// « wan », « lan », « dmz », « sd-wan » ; nil si inconnu.
    public var role: String?
    public var linkUp: Bool?
    /// Vitesse du port, en Mb/s.
    public var speedMbps: UInt64?
    /// Débits déclarés sur la FortiGate (estimated-upstream/downstream-bandwidth), en kb/s.
    public var upstreamKbps: UInt64?
    public var downstreamKbps: UInt64?
    /// Débits mesurés (bits par seconde), tirés de la vue Interfaces de FortiView.
    public var txBps: Double
    public var rxBps: Double

    public init(site: String, name: String, alias: String? = nil, role: String? = nil, linkUp: Bool? = nil, speedMbps: UInt64? = nil,
                upstreamKbps: UInt64? = nil, downstreamKbps: UInt64? = nil, txBps: Double = 0, rxBps: Double = 0) {
        self.site = site
        self.name = name
        self.alias = alias
        self.role = role
        self.linkUp = linkUp
        self.speedMbps = speedMbps
        self.upstreamKbps = upstreamKbps
        self.downstreamKbps = downstreamKbps
        self.txBps = txBps
        self.rxBps = rxBps
    }

    public var id: String { "\(site)|\(name)" }

    /// Lien vers Internet : rôle « wan », ou nom « wan1 », « wan2 », « internet ».
    public var isWAN: Bool {
        if let role = role?.lowercased() { return role == "wan" }
        let lower = name.lowercased()
        return lower.hasPrefix("wan") || lower.contains("internet") || lower == "virtual-wan-link"
    }

    /// Capacité descendante (bits par seconde) : débit déclaré, sinon la vitesse du port.
    public var downCapacity: Double? {
        if let kbps = downstreamKbps, kbps > 0 { return Double(kbps) * 1000 }
        return speedMbps.map { Double($0) * 1_000_000 }
    }

    public var upCapacity: Double? {
        if let kbps = upstreamKbps, kbps > 0 { return Double(kbps) * 1000 }
        return speedMbps.map { Double($0) * 1_000_000 }
    }

    /// Charge (0-100+) dans le sens le plus chargé ; nil sans capacité connue.
    public var utilization: Double? {
        let down = downCapacity.map { rxBps / $0 * 100 }
        let up = upCapacity.map { txBps / $0 * 100 }
        switch (down, up) {
        case let (d?, u?): return max(d, u)
        case let (d?, nil): return d
        case let (nil, u?): return u
        default: return nil
        }
    }

    /// « wan1 · Vidéotron 500/50 ».
    public var label: String {
        if let alias, !alias.isEmpty, alias != name { return "\(name) · \(alias)" }
        return name
    }
}

/// État d'une vue après lecture.
public enum TrafficViewStatus: String, Codable, Sendable {
    case ok
    /// Réponse vide (historique non journalisé, aucune menace).
    case empty
    /// Adresse ou « report_by » absent de cette version de FortiOS.
    case absent
    /// Droit manquant (HTTP 403).
    case refused
    case failed
}

/// Relevé du trafic d'une FortiGate (une période).
public struct TrafficReadReport: Codable, Hashable, Sendable {
    public var period: TrafficPeriod
    public var entries: [TrafficEntry]
    public var sessions: [TrafficSession]
    public var links: [TrafficLink]
    public var statuses: [TrafficView: TrafficViewStatus]
    /// Adresse FortiView qui a répondu (realtime-statistics, historical-statistics ou statistics).
    public var endpoint: String?
    public var notes: [String]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(period: TrafficPeriod, entries: [TrafficEntry] = [], sessions: [TrafficSession] = [], links: [TrafficLink] = [],
                statuses: [TrafficView: TrafficViewStatus] = [:], endpoint: String? = nil, notes: [String] = [],
                calls: [FortiCallRecord] = [], readAt: Date) {
        self.period = period
        self.entries = entries
        self.sessions = sessions
        self.links = links
        self.statuses = statuses
        self.endpoint = endpoint
        self.notes = notes
        self.calls = calls
        self.readAt = readAt
    }

    public func entries(_ view: TrafficView) -> [TrafficEntry] { entries.filter { $0.view == view } }

    /// Relevé renommé d'après le site (les lignes portent le nom du site).
    public func relabeled(site: String) -> TrafficReadReport {
        var copy = self
        copy.entries = entries.map { var e = $0; e.site = site; return e }
        copy.sessions = sessions.map { var s = $0; s.site = site; return s }
        copy.links = links.map { var l = $0; l.site = site; return l }
        return copy
    }
}

/// Relevé réussi d'une FortiGate d'un site.
public struct TrafficSiteReport: Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: TrafficReadReport

    public init(controllerID: UUID, site: String, report: TrafficReadReport) {
        self.controllerID = controllerID
        self.site = site
        self.report = report.relabeled(site: site)
    }
}

/// Trafic de un ou plusieurs sites réunis (lignes jamais fusionnées d'un site à l'autre).
public struct TrafficOverview: Hashable, Sendable {
    public var entries: [TrafficEntry]
    public var sessions: [TrafficSession]
    public var links: [TrafficLink]
    public var sites: [String]
    public var period: TrafficPeriod
    public var readAt: Date?
    public var notes: [String]
    /// Vues refusées ou absentes sur au moins un site.
    public var statuses: [TrafficView: TrafficViewStatus]

    public init(entries: [TrafficEntry] = [], sessions: [TrafficSession] = [], links: [TrafficLink] = [], sites: [String] = [],
                period: TrafficPeriod = .realtime, readAt: Date? = nil, notes: [String] = [],
                statuses: [TrafficView: TrafficViewStatus] = [:]) {
        self.entries = entries
        self.sessions = sessions
        self.links = links
        self.sites = sites
        self.period = period
        self.readAt = readAt
        self.notes = notes
        self.statuses = statuses
    }

    public var isEmpty: Bool { entries.isEmpty && sessions.isEmpty && links.isEmpty }
    public var isMultiSite: Bool { sites.count > 1 }
    public func entries(_ view: TrafficView) -> [TrafficEntry] { entries.filter { $0.view == view } }
    public var wanLinks: [TrafficLink] { links.filter(\.isWAN) }
}

/// Seuils du trafic (sondes, analyse complète).
public struct TrafficThresholds: Codable, Hashable, Sendable {
    /// Charge d'un lien WAN qui déclenche l'alerte, puis le critique (%).
    public var linkWarningPercent: Double
    public var linkCriticalPercent: Double
    /// Un appareil « consomme trop » au-delà de ce débit (Mb/s)…
    public var deviceMbps: Double
    /// … ou de cette part du trafic Internet du site (%).
    public var deviceSharePercent: Double
    /// Pays attendus (noms ou codes ISO, pliés) : le trafic vers d'autres pays est signalé.
    public var expectedCountries: [String]

    public init(linkWarningPercent: Double = 80, linkCriticalPercent: Double = 95, deviceMbps: Double = 50,
                deviceSharePercent: Double = 40, expectedCountries: [String] = TrafficThresholds.defaultCountries) {
        self.linkWarningPercent = linkWarningPercent
        self.linkCriticalPercent = max(linkWarningPercent, linkCriticalPercent)
        self.deviceMbps = deviceMbps
        self.deviceSharePercent = deviceSharePercent
        self.expectedCountries = expectedCountries
    }

    public static let defaultCountries = ["Canada", "CA", "United States", "États-Unis", "US", "Reserved", "Réservé", "Private", "Privé"]
    public static let standard = TrafficThresholds()
}
