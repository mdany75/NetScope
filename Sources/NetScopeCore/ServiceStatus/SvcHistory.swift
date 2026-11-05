import Foundation

/// Événement de l'historique des services : incident apparu ou résolu, service injoignable ou de retour.
public struct SvcHistoryEvent: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case incident, resolved, unreachable, reachable
        /// Bloqué ici par le filtrage (note 53).
        case blocked
    }

    public var id: UUID
    public var date: Date
    public var serviceID: String
    public var serviceName: String
    public var kind: Kind
    public var health: SvcHealth
    public var title: String
    public var url: String?

    public init(id: UUID = UUID(), date: Date, serviceID: String, serviceName: String, kind: Kind, health: SvcHealth,
                title: String, url: String? = nil) {
        self.id = id
        self.date = date
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.kind = kind
        self.health = health
        self.title = title
        self.url = url
    }

    public var kindLabel: String {
        switch kind {
        case .incident: return "Incident"
        case .resolved: return "Résolu"
        case .unreachable: return "Injoignable d’ici"
        case .reachable: return "De nouveau joignable"
        case .blocked: return "Bloqué ici"
        }
    }
}

/// Historique des services : incidents vus (pour ne notifier qu'une fois) et événements des 30 derniers jours.
public struct SvcHistory: Codable, Equatable, Sendable {
    public static let maxEvents = 300
    public static let retention: TimeInterval = 30 * 86_400

    public var events: [SvcHistoryEvent] = []
    /// Incidents en cours déjà vus : « service|incident » → titre.
    public var openIncidents: [String: String] = [:]
    /// Dernier état connu de chaque service.
    public var lastHealth: [String: SvcHealth] = [:]

    public init() {}

    /// Intègre une vérification ; renvoie les incidents apparus depuis la précédente (à notifier).
    @discardableResult
    public mutating func record(_ snapshot: SvcSnapshot, service: SvcService) -> [SvcIncident] {
        let date = snapshot.date
        var fresh: [SvcIncident] = []
        // Incidents : seulement si la page a été lue (sinon on ne sait rien de leur fin).
        if let feed = snapshot.feed {
            let active = feed.activeIncidents
            let activeKeys = Set(active.map { key(service.id, $0.id) })
            for incident in active where openIncidents[key(service.id, incident.id)] == nil {
                openIncidents[key(service.id, incident.id)] = incident.title
                fresh.append(incident)
                events.insert(SvcHistoryEvent(date: incident.started ?? date, serviceID: service.id, serviceName: service.name,
                                              kind: .incident, health: incident.impact, title: incident.title, url: incident.url), at: 0)
            }
            let prefix = service.id + "|"
            for (stored, title) in openIncidents where stored.hasPrefix(prefix) && !activeKeys.contains(stored) {
                openIncidents[stored] = nil
                let resolvedURL = feed.incidents.first { key(service.id, $0.id) == stored }?.url
                events.insert(SvcHistoryEvent(date: date, serviceID: service.id, serviceName: service.name, kind: .resolved,
                                              health: .operational, title: title, url: resolvedURL), at: 0)
            }
        }
        // Accès depuis ce réseau : perdu ou retrouvé.
        let previous = lastHealth[service.id]
        let current = snapshot.verdict.health
        if current == .unreachable, previous != nil, previous != .unreachable {
            events.insert(SvcHistoryEvent(date: date, serviceID: service.id, serviceName: service.name, kind: .unreachable,
                                          health: .unreachable, title: snapshot.verdict.headline), at: 0)
        } else if current == .blocked, previous != nil, previous != .blocked {
            events.insert(SvcHistoryEvent(date: date, serviceID: service.id, serviceName: service.name, kind: .blocked,
                                          health: .blocked, title: snapshot.verdict.headline), at: 0)
        } else if previous == .unreachable || previous == .blocked, current != previous {
            events.insert(SvcHistoryEvent(date: date, serviceID: service.id, serviceName: service.name, kind: .reachable,
                                          health: current, title: previous == .blocked ? "Plus bloqué depuis ce réseau"
                                                                                       : "Joignable de nouveau depuis ce réseau"), at: 0)
        }
        lastHealth[service.id] = current
        events.sort { $0.date > $1.date }
        prune(now: date)
        return fresh
    }

    /// Oublie un service retiré du catalogue (ses événements passés restent).
    public mutating func forget(serviceID: String) {
        let prefix = serviceID + "|"
        openIncidents = openIncidents.filter { !$0.key.hasPrefix(prefix) }
        lastHealth[serviceID] = nil
    }

    public mutating func prune(now: Date) {
        events.removeAll { now.timeIntervalSince($0.date) > Self.retention }
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    private func key(_ service: String, _ incident: String) -> String { service + "|" + incident }
}

/// Sonde de Surveillance « Service en ligne » : la cible est un service du catalogue.
public enum SvcMonitorCheck {
    public static func run(_ probe: MonProbe, target: String, context: MonRunContext) async -> MonResult {
        let catalog = context.onlineServices.isEmpty ? SvcCatalog.builtIn : context.onlineServices
        guard let service = SvcCatalog.find(target, in: catalog) else {
            return .failure(context.now, error: "Service inconnu\u{00A0}: \(target) (nom du catalogue attendu, ex. Microsoft 365)")
        }
        let checker = SvcChecker(fetcher: SvcNetworkFetcher(), prober: SvcNetworkProber(), graph: context.onlineServiceGraph)
        let snapshot = await checker.check(service, now: context.now)
        return evaluate(snapshot)
    }

    /// Résultat de Surveillance d'une vérification (pur, testé) : panne chez eux ou injoignable
    /// d'ici comptent comme échecs ; un service dégradé est un avertissement.
    public static func evaluate(_ snapshot: SvcSnapshot) -> MonResult {
        let verdict = snapshot.verdict
        let latency = snapshot.latencyMs
        let suffix = latency.map { " · \(ToolFormat.milliseconds($0))" } ?? ""
        switch verdict.health {
        case .outage:
            return MonResult(date: snapshot.date, reachable: false, latencyMs: latency, value: "Panne chez eux",
                             error: "panne chez eux\u{00A0}: \(verdict.headline)")
        case .unreachable:
            return MonResult(date: snapshot.date, reachable: false, value: "Injoignable d’ici",
                             error: verdict.headline.prefix(1).lowercased() + verdict.headline.dropFirst())
        case .blocked:
            // Bloqué par le filtrage de ce réseau : un échec pour la sonde, mais expliqué comme tel.
            return MonResult(date: snapshot.date, reachable: false, value: "Bloqué ici",
                             error: verdict.headline.prefix(1).lowercased() + verdict.headline.dropFirst())
        case .degraded:
            return MonResult(date: snapshot.date, reachable: true, latencyMs: latency, value: "Dégradé" + suffix,
                             problem: (verdict.side == .ours ? "Problème chez nous\u{00A0}: " : "Service dégradé\u{00A0}: ") + verdict.headline)
        case .maintenance:
            return MonResult(date: snapshot.date, reachable: true, latencyMs: latency, value: "Maintenance" + suffix)
        case .operational, .unknown:
            return MonResult(date: snapshot.date, reachable: true, latencyMs: latency,
                             value: (verdict.health == .unknown ? "Inconnu" : "OK") + suffix)
        }
    }
}
