import Foundation

/// État d'une sonde.
public enum MonState: String, Codable, Sendable, CaseIterable {
    /// Aucune vérification encore.
    case pending
    case ok
    /// Seuil dépassé ou condition non remplie, mais la cible répond.
    case warning
    /// N échecs consécutifs (seuil « Échecs consécutifs »).
    case down
    /// Échec ignoré : la sonde dont elle dépend est en panne.
    case ignored

    public var label: String {
        switch self {
        case .pending: return "En attente"
        case .ok: return "OK"
        case .warning: return "En alerte"
        case .down: return "Hors ligne"
        case .ignored: return "Ignorée"
        }
    }
}

/// Résultat d'une vérification.
public struct MonResult: Codable, Equatable, Sendable {
    public var date: Date
    /// La cible a répondu comme attendu (sinon : un échec, compté vers la panne).
    public var reachable: Bool
    public var latencyMs: Double?
    public var lossPercent: Double?
    /// Dernière valeur à afficher (« 200 OK · 184 ms », « 41 °C »).
    public var value: String
    /// Condition propre au type non remplie (avertissement), même si la cible répond.
    public var problem: String?
    /// Raison de l'échec.
    public var error: String?

    public init(date: Date, reachable: Bool, latencyMs: Double? = nil, lossPercent: Double? = nil,
                value: String, problem: String? = nil, error: String? = nil) {
        self.date = date
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
        self.value = value
        self.problem = problem
        self.error = error
    }

    /// Réussite simple (tests, démonstration).
    public static func success(_ date: Date, latency: Double? = nil, loss: Double? = nil, value: String = "OK",
                               problem: String? = nil) -> MonResult {
        MonResult(date: date, reachable: true, latencyMs: latency, lossPercent: loss, value: value, problem: problem)
    }

    /// Échec simple (tests, démonstration).
    public static func failure(_ date: Date, error: String = "Aucune réponse") -> MonResult {
        MonResult(date: date, reachable: false, value: error, error: error)
    }
}

/// Suivi d'une sonde entre deux vérifications (enregistré avec elle).
public struct MonTracker: Codable, Equatable, Sendable {
    public var state: MonState
    public var consecutiveFailures: Int
    /// Début de l'état actuel.
    public var since: Date?
    /// État pour lequel une alerte a été créée (avertissement ou panne), nil après le retour à la normale.
    public var alerted: MonState?
    public var lastResult: MonResult?

    public init(state: MonState = .pending, consecutiveFailures: Int = 0, since: Date? = nil,
                alerted: MonState? = nil, lastResult: MonResult? = nil) {
        self.state = state
        self.consecutiveFailures = consecutiveFailures
        self.since = since
        self.alerted = alerted
        self.lastResult = lastResult
    }
}

/// Événement produit par la machine d'états : il crée ou résout une alerte.
public struct MonEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case down, warning, recovered }
    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Machine d'états des sondes, pure : (sonde, suivi, résultat, contexte) → (suivi, événements).
///
/// - un échec incrémente le compteur ; à N échecs consécutifs, la sonde passe « hors ligne » ;
///   sous N, elle garde son état ;
/// - une réponse remet le compteur à zéro ; latence ou perte au-delà du seuil, ou condition du type
///   non remplie : « en alerte » ; sinon « OK » ;
/// - si la sonde dont elle dépend est hors ligne, un échec est « ignoré » (rien n'est compté) ;
/// - une alerte n'est créée que dans la plage horaire de la sonde, une seule fois par état ; si la
///   panne commence hors plage, l'alerte part à la première vérification dans la plage ;
/// - le retour à « OK » après une alerte produit un événement « recovered » (alerte résolue).
public enum MonStateMachine {
    public static func evaluate(probe: MonProbe, tracker: MonTracker, result: MonResult,
                                dependencyDown: Bool, calendar: Calendar = .current) -> (tracker: MonTracker, events: [MonEvent]) {
        var next = tracker
        next.lastResult = result
        var events: [MonEvent] = []

        let newState: MonState
        var problems: [String] = []
        if !result.reachable {
            if dependencyDown {
                next.consecutiveFailures = 0
                newState = .ignored
            } else {
                next.consecutiveFailures += 1
                if next.consecutiveFailures >= probe.thresholds.failures {
                    newState = .down
                } else {
                    // Sous le seuil : on attend la confirmation.
                    newState = tracker.state == .down ? .down : tracker.state
                }
            }
        } else {
            next.consecutiveFailures = 0
            problems = warnings(probe: probe, result: result)
            newState = problems.isEmpty ? .ok : .warning
        }

        if newState != tracker.state { next.since = result.date }
        next.state = newState

        let allowed = probe.schedule.allowsAlerts(at: result.date, calendar: calendar)
        switch newState {
        case .down:
            if next.alerted != .down, allowed {
                let attempts = max(next.consecutiveFailures, probe.thresholds.failures)
                var message = "\(probe.target) ne répond plus depuis \(attempts) tentative\(attempts > 1 ? "s" : "")"
                if let error = result.error, !error.isEmpty { message += " (\(error))" }
                events.append(MonEvent(.down, message + "."))
                next.alerted = .down
            }
        case .warning:
            if next.alerted == .down {
                events.append(MonEvent(.recovered, "répond de nouveau (\(result.value))"))
                next.alerted = nil
            }
            if next.alerted != .warning, allowed {
                events.append(MonEvent(.warning, problems.joined(separator: " ; ") + "."))
                next.alerted = .warning
            }
        case .ok:
            if next.alerted != nil {
                events.append(MonEvent(.recovered, "revenu à la normale (\(result.value))"))
                next.alerted = nil
            }
        case .pending, .ignored:
            break
        }
        return (next, events)
    }

    /// Comme `evaluate`, pour le résultat d'un exécuteur : sans donnée (`noData`), nil (le suivi ne
    /// bouge pas, aucun événement, rien dans l'historique).
    public static func step(probe: MonProbe, tracker: MonTracker, outcome: MonRunOutcome, dependencyDown: Bool,
                            calendar: Calendar = .current) -> (tracker: MonTracker, events: [MonEvent])? {
        guard !outcome.noData else { return nil }
        return evaluate(probe: probe, tracker: tracker, result: outcome.result, dependencyDown: dependencyDown,
                        calendar: calendar)
    }

    /// Avertissements d'une réponse : seuils de latence et de perte, condition du type.
    public static func warnings(probe: MonProbe, result: MonResult) -> [String] {
        var list: [String] = []
        if let limit = probe.thresholds.latencyMs, let latency = result.latencyMs, latency > limit {
            list.append("Latence \(ToolFormat.milliseconds(latency)) > \(MonFormat.number(limit))\u{00A0}ms")
        }
        if let limit = probe.thresholds.lossPercent, let loss = result.lossPercent, loss > limit {
            list.append("Perte \(MonFormat.percent(loss)) > \(MonFormat.percent(limit))")
        }
        if let problem = result.problem, !problem.isEmpty { list.append(problem) }
        return list
    }
}
