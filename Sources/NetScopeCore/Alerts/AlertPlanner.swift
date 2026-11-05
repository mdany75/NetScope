import Foundation

// Règles d'envoi des alertes, sans réseau ni horloge propre (la date est passée en paramètre) :
// interrupteur général, types d'événements choisis, gravité minimale, sondes exclues, heures de
// silence, anti-rafale (au plus une alerte par type d'événement et par objet dans l'intervalle)
// et regroupement (les événements d'une même fenêtre partent en un seul résumé).

/// Pourquoi un événement n'est pas envoyé.
public enum AlertSkipReason: String, Sendable, Equatable {
    case alertsDisabled, kindDisabled, belowSeverity, probeExcluded, quietHours, throttled, noOpenAlert, noChannel

    public var label: String {
        switch self {
        case .alertsDisabled: return "alertes désactivées"
        case .kindDisabled: return "type d’événement non choisi"
        case .belowSeverity: return "sous la gravité minimale"
        case .probeExcluded: return "sonde exclue des alertes"
        case .quietHours: return "heures de silence"
        case .throttled: return "anti-rafale"
        case .noOpenAlert: return "panne non signalée"
        case .noChannel: return "aucun canal activé"
        }
    }
}

/// Décision prise pour un événement.
public enum AlertDecision: Equatable, Sendable {
    case queued
    case skipped(AlertSkipReason)
}

/// Lot d'événements envoyé en un seul message sur chaque canal.
public struct AlertBatch: Sendable, Equatable {
    public var events: [AlertEvent]
    /// Répétitions retenues par l'anti-rafale depuis le dernier envoi (rappelées dans le message).
    public var suppressedCount: Int
    public var createdAt: Date
    public var isTest: Bool

    public init(events: [AlertEvent], suppressedCount: Int = 0, createdAt: Date, isTest: Bool = false) {
        self.events = events
        self.suppressedCount = suppressedCount
        self.createdAt = createdAt
        self.isTest = isTest
    }

    public var severity: AlertSeverity { events.map(\.severity).max() ?? .info }

    /// « Caméra-Quai hors ligne » ou « 3 alertes NetScope ».
    public var title: String {
        if events.count == 1 { return events[0].title }
        return "\(events.count) alertes NetScope"
    }

    /// « 2 critiques, 1 info ».
    public var breakdown: String {
        AlertSeverity.allCases.reversed().compactMap { severity -> String? in
            let count = events.filter { $0.severity == severity }.count
            guard count > 0 else { return nil }
            let word: String
            switch severity {
            case .critical: word = count > 1 ? "critiques" : "critique"
            case .warning: word = count > 1 ? "alertes" : "alerte"
            case .info: word = "info"
            }
            return "\(count)\u{00A0}\(word)"
        }.joined(separator: ", ")
    }

    /// Sujet du courriel (« [NetScope] Critique · Caméra-Quai hors ligne »).
    public var subject: String {
        let prefix = isTest ? "[NetScope] Essai" : "[NetScope] \(severity.label)"
        if events.count == 1 { return "\(prefix) · \(events[0].title)" }
        return "\(prefix) · \(events.count) alertes (\(breakdown))"
    }

    /// Lot d'essai (bouton « Envoyer un test »).
    public static func test(now: Date, origin: String) -> AlertBatch {
        let event = AlertEvent(kind: .test, severity: .info, title: "Message d’essai de NetScope",
                               message: "Ce canal d’alerte fonctionne. Aucune action n’est requise.",
                               subject: "test", occurredAt: now,
                               details: [AlertDetail("Envoyé depuis", origin), AlertDetail("Réglage", "Réglages › Alertes")])
        return AlertBatch(events: [event], createdAt: now, isTest: true)
    }
}

/// État de l'anti-rafale et du regroupement. Valeur pure : l'application la garde et l'appelle.
public struct AlertPlanner: Sendable, Equatable {
    /// Événements en attente du regroupement.
    public private(set) var pending: [AlertEvent] = []
    /// Dernier envoi accepté par clé (type + objet).
    public private(set) var lastQueued: [String: Date] = [:]
    /// Répétitions retenues par clé depuis le dernier envoi.
    public private(set) var suppressed: [String: Int] = [:]
    /// Objets dont la panne a été signalée (un rétablissement n'est envoyé que pour eux).
    public private(set) var openDowns: Set<String> = []
    /// Gravité de la panne signalée de chaque objet (reportée sur son rétablissement).
    private var openSeverities: [String: AlertSeverity] = [:]

    public init() {}

    /// Soumet un événement ; renvoie la décision. `hasChannel` : au moins un canal activé.
    public mutating func submit(_ event: AlertEvent, settings: AlertSettings, hasChannel: Bool = true,
                                now: Date, calendar: Calendar = .current) -> AlertDecision {
        let rules = settings.rules
        guard settings.isEnabled else { return .skipped(.alertsDisabled) }
        guard hasChannel else { return .skipped(.noChannel) }
        guard rules.kinds.contains(event.kind) else { return .skipped(.kindDisabled) }
        if let probe = event.probeID, rules.excludedProbes.contains(probe) { return .skipped(.probeExcluded) }

        // Rétablissement : seulement si la panne (ou l'alerte) de cet objet a été signalée.
        var event = event
        if event.kind == .probeRecovered {
            guard openDowns.remove(event.subject) != nil else { return .skipped(.noOpenAlert) }
            event.closedSeverity = openSeverities.removeValue(forKey: event.subject)
        } else if event.severity < rules.minimumSeverity {
            return .skipped(.belowSeverity)
        }
        if rules.quietHours.contains(now, calendar: calendar),
           !(rules.quietHours.criticalBypass && event.severity == .critical) {
            return .skipped(.quietHours)
        }
        let key = event.throttleKey
        if rules.throttleMinutes > 0, let last = lastQueued[key],
           now.timeIntervalSince(last) < TimeInterval(rules.throttleMinutes * 60) {
            suppressed[key, default: 0] += 1
            return .skipped(.throttled)
        }
        lastQueued[key] = now
        if event.kind.opensIncident {
            openDowns.insert(event.subject)
            // Panne puis alerte du même objet : la plus grave des deux est retenue.
            openSeverities[event.subject] = max(openSeverities[event.subject] ?? event.severity, event.severity)
        }
        pending.append(event)
        return .queued
    }

    /// Date à laquelle le lot en attente doit partir (nil : rien en attente).
    public func nextFlush(rules: AlertRules) -> Date? {
        guard let first = pending.map(\.occurredAt).min() else { return nil }
        return first.addingTimeInterval(TimeInterval(max(0, rules.groupingSeconds)))
    }

    /// Vide la file si la fenêtre de regroupement est écoulée (ou si `force`) et renvoie le lot.
    public mutating func flush(now: Date, rules: AlertRules, force: Bool = false) -> AlertBatch? {
        guard !pending.isEmpty, let due = nextFlush(rules: rules) else { return nil }
        guard force || now >= due else { return nil }
        let events = pending.sorted { ($0.severity, $1.occurredAt) > ($1.severity, $0.occurredAt) }
        let keys = Set(events.map(\.throttleKey))
        let count = keys.reduce(0) { $0 + (suppressed[$1] ?? 0) }
        for key in keys { suppressed[key] = nil }
        pending = []
        return AlertBatch(events: events, suppressedCount: count, createdAt: now)
    }

    /// Applique de nouvelles règles sans perdre l'état : la file en attente garde les événements
    /// encore choisis et les pannes déjà signalées restent ouvertes (leur rétablissement partira).
    /// L'anti-rafale n'est oublié que si son intervalle change.
    public mutating func applyRules(_ rules: AlertRules, previous: AlertRules) {
        pending.removeAll { event in
            if !rules.kinds.contains(event.kind) { return true }
            if let probe = event.probeID, rules.excludedProbes.contains(probe) { return true }
            return event.kind != .probeRecovered && event.severity < rules.minimumSeverity
        }
        if rules.throttleMinutes != previous.throttleMinutes {
            lastQueued = [:]
            suppressed = [:]
        }
    }

    /// Oublie tout (à la coupure de l'interrupteur général).
    public mutating func reset() {
        self = AlertPlanner()
    }
}

// MARK: - Secrets hors du journal

/// Retire tout secret connu d'un texte destiné au journal : valeurs exactes, leurs formes base64
/// et encodées pour une URL, et toute adresse https:// complète (chemin masqué).
public enum AlertRedactor {
    public static let mask = "••••"

    public static func redact(_ text: String, secrets: [String]) -> String {
        var output = text
        for secret in secrets where secret.count >= 3 {
            var forms = [secret, Data(secret.utf8).base64EncodedString()]
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.append(encoded) }
            for form in forms where !form.isEmpty {
                output = output.replacingOccurrences(of: form, with: mask)
            }
        }
        return maskURLs(output)
    }

    /// « https://hooks.slack.com/services/T0/B0/xyz » → « https://hooks.slack.com/•••• ».
    public static func maskURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(https?://[^/\\s\"'<>]+)/[^\\s\"'<>]*", options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1/\(mask)")
    }

    /// Adresse de webhook affichée : hôte et quatre derniers caractères (« hooks.slack.com/…/a1B2 »).
    public static func maskedWebhook(_ address: String) -> String {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), let host = url.host else {
            return address.isEmpty ? "" : mask
        }
        let tail = String(address.trimmingCharacters(in: .whitespaces).suffix(4))
        return "\(host)/…\(tail)"
    }
}
