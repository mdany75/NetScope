import Foundation

// État des grands services en ligne (note 15) : catalogue, page d'état officielle de chaque
// service, test depuis ce réseau et bilan qui distingue « panne chez eux » et « problème chez nous ».
// Tout est Codable (services-en-ligne.json de l'application).

/// Format de la page d'état officielle d'un service.
public enum SvcFeedFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Atlassian Statuspage : /api/v2/summary.json (Cloudflare, GitHub, Zoom, Dropbox, Atlassian…).
    case statuspage
    /// Slack : slack-status.com/api/v2.0.0/current.
    case slack
    /// Apple System Status : JSON du site (system_status_*.js), parfois enveloppé dans jsonCallback(…).
    case apple
    /// AWS Health Dashboard : health.aws.amazon.com/public/currentevents (JSON, souvent en UTF-16).
    case awsHealth
    /// Azure Status : flux RSS des incidents en cours (azure.status.microsoft/…/status/feed/).
    case azureRSS
    /// Google Workspace et Google Cloud : incidents.json.
    case googleIncidents
    /// Microsoft 365 : page publique status.cloud.microsoft (lecture tolérante).
    case microsoft365
    /// Flux RSS ou Atom quelconque (éléments des dernières 24 h).
    case rss
    /// Aucune page lisible : seulement le test depuis ce réseau et le lien vers la page officielle.
    case none

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .statuspage: return "Statuspage (JSON)"
        case .slack: return "API Slack Status"
        case .apple: return "Apple System Status"
        case .awsHealth: return "AWS Health (JSON)"
        case .azureRSS: return "Azure Status (RSS)"
        case .googleIncidents: return "Google incidents.json"
        case .microsoft365: return "Microsoft 365 (page publique)"
        case .rss: return "Flux RSS ou Atom"
        case .none: return "Aucune (test réseau seulement)"
        }
    }
}

/// État d'un service, du meilleur au pire.
public enum SvcHealth: String, Codable, CaseIterable, Sendable, Comparable {
    case operational, maintenance, degraded, outage, unreachable, unknown

    /// Gravité, pour trier et comparer (inconnu juste après « OK »).
    public var rank: Int {
        switch self {
        case .operational: return 0
        case .unknown: return 1
        case .maintenance: return 2
        case .degraded: return 3
        case .unreachable: return 4
        case .outage: return 5
        }
    }

    public static func < (lhs: SvcHealth, rhs: SvcHealth) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .operational: return "OK"
        case .maintenance: return "Maintenance"
        case .degraded: return "Dégradé"
        case .outage: return "Panne chez eux"
        case .unreachable: return "Injoignable d’ici"
        case .unknown: return "Inconnu"
        }
    }

    /// Vrai si le service a un problème (de leur côté ou du nôtre).
    public var isProblem: Bool { rank >= SvcHealth.degraded.rank }
}

/// Un grand service en ligne du catalogue.
public struct SvcService: Codable, Identifiable, Hashable, Sendable {
    /// Identifiant stable (« microsoft365 », « github »), aussi cible des sondes de Surveillance.
    public var id: String
    public var name: String
    /// Famille affichée sous le nom (« Microsoft », « Développement »).
    public var category: String
    public var format: SvcFeedFormat
    /// Adresse lue (JSON ou RSS) ; nil : aucune page lisible.
    public var feedURL: String?
    /// Page officielle ouverte par « Page officielle » et base des liens relatifs.
    public var pageURL: String
    /// Adresses clés testées depuis ce réseau (https://…).
    public var endpoints: [String]
    /// Parties suivies affichées (« Outlook », « Teams »…), et filtre des incidents quand la page
    /// couvre bien plus que ce qui intéresse (vide : tout) ; appliqué par `SvcChecker.filtered`.
    public var components: [String]
    public var isEnabled: Bool
    /// Service ajouté par l'utilisateur (modifiable et supprimable).
    public var isCustom: Bool

    public init(id: String, name: String, category: String, format: SvcFeedFormat, feedURL: String?, pageURL: String,
                endpoints: [String], components: [String] = [], isEnabled: Bool = true, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.format = format
        self.feedURL = feedURL
        self.pageURL = pageURL
        self.endpoints = endpoints
        self.components = components
        self.isEnabled = isEnabled
        self.isCustom = isCustom
    }

    /// Hôtes des adresses clés (« outlook.office365.com »).
    public var endpointHosts: [String] {
        endpoints.compactMap { URL(string: $0)?.host }
    }
}

/// Partie d'un service et son état (composant Statuspage, service Microsoft Graph).
public struct SvcComponent: Codable, Hashable, Sendable {
    public var name: String
    public var health: SvcHealth

    public init(name: String, health: SvcHealth) {
        self.name = name
        self.health = health
    }
}

/// Incident publié par la page d'état d'un service.
public struct SvcIncident: Codable, Hashable, Identifiable, Sendable {
    /// Identifiant propre à la page d'état (stable d'une lecture à l'autre).
    public var id: String
    public var title: String
    /// Effet : dégradé, panne ou maintenance.
    public var impact: SvcHealth
    /// Statut publié, en français (« En cours d’analyse », « Résolu »).
    public var status: String
    /// Services ou composants touchés.
    public var affected: [String]
    public var started: Date?
    public var updated: Date?
    /// Lien vers l'incident sur la page officielle.
    public var url: String?
    /// Dernière mise à jour publiée (texte brut, abrégé).
    public var latestUpdate: String?
    public var isResolved: Bool

    public init(id: String, title: String, impact: SvcHealth, status: String, affected: [String] = [],
                started: Date? = nil, updated: Date? = nil, url: String? = nil, latestUpdate: String? = nil,
                isResolved: Bool = false) {
        self.id = id
        self.title = title
        self.impact = impact
        self.status = status
        self.affected = affected
        self.started = started
        self.updated = updated
        self.url = url
        self.latestUpdate = latestUpdate
        self.isResolved = isResolved
    }
}

/// Ce que dit la page d'état officielle.
public struct SvcFeedReport: Codable, Hashable, Sendable {
    public var health: SvcHealth
    /// Phrase de la page (« All Systems Operational ») ou résumé en français.
    public var description: String
    /// Incidents en cours (et, selon le format, récemment résolus : isResolved).
    public var incidents: [SvcIncident]
    public var components: [SvcComponent]

    public init(health: SvcHealth, description: String, incidents: [SvcIncident] = [], components: [SvcComponent] = []) {
        self.health = health
        self.description = description
        self.incidents = incidents
        self.components = components
    }

    public var activeIncidents: [SvcIncident] { incidents.filter { !$0.isResolved } }
}

/// Étape où le test depuis ce réseau a échoué.
public enum SvcFailure: String, Codable, Sendable {
    case dns, connect, tls, proxy, http, timeout

    /// Cause probable, de notre côté.
    public var cause: String {
        switch self {
        case .dns: return "résolution DNS impossible (serveur DNS ou filtrage DNS de ce réseau)"
        case .connect: return "connexion refusée ou sans réponse (pare-feu ou lien Internet)"
        case .tls: return "échec TLS (proxy ou inspection TLS du pare-feu)"
        case .proxy: return "le proxy demande une authentification (HTTP 407)"
        case .http: return "réponse HTTPS invalide"
        case .timeout: return "délai dépassé (pare-feu, proxy ou lien saturé)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .dns: return "Échec DNS"
        case .connect: return "Connexion refusée"
        case .tls: return "Échec TLS"
        case .proxy: return "Proxy 407"
        case .http: return "Réponse invalide"
        case .timeout: return "Délai dépassé"
        }
    }
}

/// Test d'une adresse clé depuis ce réseau : DNS, connexion TLS, réponse HTTPS.
public struct SvcEndpointResult: Codable, Hashable, Sendable {
    public var url: String
    public var host: String
    public var addresses: [String]
    public var dnsMs: Double?
    /// Connexion TCP et poignée de main TLS.
    public var tlsMs: Double?
    /// Premier octet de la réponse HTTPS.
    public var httpMs: Double?
    public var httpStatus: Int?
    /// Étape en échec (nil : réussite).
    public var failure: SvcFailure?
    public var detail: String?

    public init(url: String, host: String, addresses: [String] = [], dnsMs: Double? = nil, tlsMs: Double? = nil,
                httpMs: Double? = nil, httpStatus: Int? = nil, failure: SvcFailure? = nil, detail: String? = nil) {
        self.url = url
        self.host = host
        self.addresses = addresses
        self.dnsMs = dnsMs
        self.tlsMs = tlsMs
        self.httpMs = httpMs
        self.httpStatus = httpStatus
        self.failure = failure
        self.detail = detail
    }

    public var isReachable: Bool { failure == nil }

    /// « DNS 12 ms · TLS 38 ms · HTTPS 121 ms », ou l'échec.
    public var summary: String {
        if let failure {
            return failure.shortLabel + (detail.map { " · \($0)" } ?? "")
        }
        var parts: [String] = []
        if let dnsMs { parts.append("DNS \(ToolFormat.milliseconds(dnsMs))") }
        if let tlsMs { parts.append("TLS \(ToolFormat.milliseconds(tlsMs))") }
        if let httpMs { parts.append("HTTPS \(ToolFormat.milliseconds(httpMs))") }
        return parts.joined(separator: " · ")
    }
}

/// De quel côté est le problème.
public enum SvcSide: String, Codable, Sendable {
    case none, theirs, ours
}

/// Bilan d'un service : page d'état et test depuis ce réseau réunis.
public struct SvcVerdict: Codable, Hashable, Sendable {
    public var health: SvcHealth
    public var side: SvcSide
    /// Phrase courte (« Teams : retards dans la livraison des messages »).
    public var headline: String
    /// Explication (« La page d’état est normale, mais… »).
    public var detail: String?

    public init(health: SvcHealth, side: SvcSide, headline: String, detail: String? = nil) {
        self.health = health
        self.side = side
        self.headline = headline
        self.detail = detail
    }
}

/// Résultat complet de la vérification d'un service.
public struct SvcSnapshot: Codable, Hashable, Sendable {
    public var serviceID: String
    public var date: Date
    public var feed: SvcFeedReport?
    /// Page d'état illisible ou injoignable (nil : lue, ou aucune page).
    public var feedError: String?
    /// Source effectivement lue (« Microsoft Graph », « Statuspage (JSON) »).
    public var feedSource: String?
    public var endpoints: [SvcEndpointResult]
    public var verdict: SvcVerdict

    public init(serviceID: String, date: Date, feed: SvcFeedReport?, feedError: String?, feedSource: String? = nil,
                endpoints: [SvcEndpointResult], verdict: SvcVerdict) {
        self.serviceID = serviceID
        self.date = date
        self.feed = feed
        self.feedError = feedError
        self.feedSource = feedSource
        self.endpoints = endpoints
        self.verdict = verdict
    }

    /// Latence HTTPS médiane des adresses joignables (ms).
    public var latencyMs: Double? {
        let values = endpoints.compactMap { $0.isReachable ? $0.httpMs : nil }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    public var activeIncidents: [SvcIncident] { feed?.activeIncidents ?? [] }
}
