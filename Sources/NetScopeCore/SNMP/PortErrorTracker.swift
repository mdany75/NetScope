import Foundation

// Erreurs récentes des ports d'un switch : seules les erreurs en entrée (ifInErrors) qui
// augmentent entre deux relevés sont signalées, pas le total accumulé depuis le démarrage du
// switch (un vieux problème réglé depuis ne doit plus rester en rouge).
//
// Le suivi garde, par switch, les relevés des 30 dernières minutes (SNMP ou FortiGate) et compare
// le relevé le plus récent au plus ancien gardé. Rien n'est enregistré sur le disque : au
// lancement, la mesure repart de zéro (« mesure en cours » jusqu'au deuxième relevé).

/// Nouvelles erreurs d'un port sur la fenêtre de suivi.
public struct PortErrorDelta: Hashable, Sendable {
    public var ifIndex: Int
    /// Erreurs en entrée apparues depuis le plus ancien relevé gardé.
    public var newErrors: UInt64
    /// Durée couverte, en secondes (du plus ancien relevé gardé au plus récent).
    public var seconds: TimeInterval

    public init(ifIndex: Int, newErrors: UInt64, seconds: TimeInterval) {
        self.ifIndex = ifIndex
        self.newErrors = newErrors
        self.seconds = seconds
    }

    /// Port à signaler : au moins `PortErrorTracker.threshold` nouvelles erreurs.
    public var isAlert: Bool { newErrors >= PortErrorTracker.threshold }

    /// « 10 min », « 1 h 05 », « moins d’une minute »
    public var durationLabel: String { PortErrorTracker.durationLabel(seconds) }
}

/// Erreurs récentes d'un switch.
public struct SwitchRecentErrors: Hashable, Sendable {
    /// Faux tant qu'il n'y a qu'un relevé : aucune base de comparaison (« mesure en cours »).
    public var hasBaseline: Bool
    /// Durée couverte, en secondes.
    public var seconds: TimeInterval
    /// Nouvelles erreurs par ifIndex (ports présents dans les deux relevés).
    public var ports: [Int: PortErrorDelta]

    public init(hasBaseline: Bool, seconds: TimeInterval, ports: [Int: PortErrorDelta]) {
        self.hasBaseline = hasBaseline
        self.seconds = seconds
        self.ports = ports
    }

    public static let none = SwitchRecentErrors(hasBaseline: false, seconds: 0, ports: [:])

    /// Ports à signaler, du plus touché au moins touché.
    public var alerts: [PortErrorDelta] {
        ports.values.filter(\.isAlert).sorted { ($0.newErrors, $1.ifIndex) > ($1.newErrors, $0.ifIndex) }
    }

    public func isAlert(_ ifIndex: Int) -> Bool { ports[ifIndex]?.isAlert ?? false }
}

/// Suivi des compteurs d'erreurs des ports, par switch.
public struct PortErrorTracker: Sendable {
    /// Nouvelles erreurs à partir desquelles un port est signalé, sur la fenêtre de suivi.
    public static let threshold: UInt64 = 10
    /// Fenêtre de suivi : relevés gardés au plus 30 minutes.
    public static let window: TimeInterval = 30 * 60

    struct Sample: Sendable {
        var at: Date
        var counters: [Int: UInt64]
    }

    private var samples: [String: [Sample]] = [:]

    public init() {}

    /// Ajoute un relevé (ports actifs seulement). Un relevé déjà vu (même heure) ou plus ancien que
    /// le dernier est ignoré ; les relevés sortis de la fenêtre sont retirés.
    public mutating func record(_ snapshot: SNMPSwitchSnapshot) {
        let host = snapshot.host.description
        var counters: [Int: UInt64] = [:]
        for port in snapshot.physicalPorts where port.isUp {
            if let errors = port.inErrors { counters[port.index] = errors }
        }
        record(host: host, at: snapshot.polledAt, counters: counters)
    }

    /// Variante sans relevé complet (essais).
    public mutating func record(host: String, at date: Date, counters: [Int: UInt64]) {
        var list = samples[host] ?? []
        if let last = list.last, date <= last.at { return }
        list.append(Sample(at: date, counters: counters))
        list.removeAll { date.timeIntervalSince($0.at) > Self.window }
        samples[host] = list
    }

    /// Oublie un switch (retiré de la liste).
    public mutating func forget(_ host: String) { samples[host] = nil }

    /// Nouvelles erreurs du switch sur la fenêtre. Un compteur qui baisse (switch redémarré,
    /// compteurs remis à zéro) repart de sa nouvelle valeur : seule la hausse qui suit compte.
    public func recent(_ host: String) -> SwitchRecentErrors {
        guard let list = samples[host], let first = list.first, let last = list.last, list.count >= 2 else {
            return .none
        }
        let seconds = last.at.timeIntervalSince(first.at)
        var result: [Int: PortErrorDelta] = [:]
        for index in last.counters.keys {
            // Hausses successives d'un relevé à l'autre ; une baisse remet la base à la nouvelle valeur.
            var total: UInt64 = 0
            var previous: UInt64?
            var start: Date?
            for sample in list {
                guard let value = sample.counters[index] else { previous = nil; continue }
                if start == nil { start = sample.at }
                if let before = previous, value > before { total += value - before }
                previous = value
            }
            guard let since = start, since < last.at else { continue }
            result[index] = PortErrorDelta(ifIndex: index, newErrors: total, seconds: last.at.timeIntervalSince(since))
        }
        return SwitchRecentErrors(hasBaseline: true, seconds: seconds, ports: result)
    }

    /// « 10 min », « 1 h 05 », « moins d’une minute »
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "moins d’une minute" }
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        return String(format: "%d\u{00A0}h\u{00A0}%02d", minutes / 60, minutes % 60)
    }
}
