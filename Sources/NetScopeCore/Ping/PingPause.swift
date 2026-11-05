import Foundation

// Pause d'une cible du ping continu (0.21.0, note 11) : une cible en pause n'envoie plus rien,
// ses statistiques restent figées et l'export CSV ne compte aucune perte pendant la pause.

/// Périodes de pause d'une cible : la dernière reste ouverte tant que la cible est en pause.
public struct PingPausePeriods: Equatable, Sendable {
    /// Une période de pause ; `end` nil : pause en cours.
    public struct Period: Equatable, Sendable {
        public let start: Date
        public var end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }

        /// Vrai si `date` tombe dans la période (début compris, fin exclue).
        public func contains(_ date: Date) -> Bool {
            date >= start && end.map { date < $0 } ?? true
        }
    }

    public private(set) var periods: [Period] = []

    public init() {}

    public var isPaused: Bool { periods.last.map { $0.end == nil } ?? false }

    /// Début de la pause en cours.
    public var pausedSince: Date? { isPaused ? periods.last?.start : nil }

    /// Met en pause ; faux si la cible l'était déjà (rien à noter au journal).
    @discardableResult
    public mutating func pause(at date: Date) -> Bool {
        guard !isPaused else { return false }
        periods.append(Period(start: date))
        return true
    }

    /// Reprend ; faux si la cible n'était pas en pause.
    @discardableResult
    public mutating func resume(at date: Date) -> Bool {
        guard isPaused, let index = periods.indices.last else { return false }
        periods[index].end = max(date, periods[index].start)
        return true
    }

    /// Bascule pause / reprise ; rend le nouvel état (vrai : en pause).
    @discardableResult
    public mutating func toggle(at date: Date) -> Bool {
        if isPaused { resume(at: date) } else { pause(at: date) }
        return isPaused
    }

    /// Vrai si une mesure envoyée à `date` tombe dans une pause.
    public func covers(_ date: Date) -> Bool {
        periods.contains { $0.contains(date) }
    }

    /// Durée totale en pause jusqu'à `now`.
    public func pausedDuration(until now: Date) -> TimeInterval {
        periods.reduce(0) { total, period in
            total + max(0, min(period.end ?? now, now).timeIntervalSince(period.start))
        }
    }

    /// Réinitialisation des statistiques : on oublie les pauses passées, mais une pause en cours
    /// continue, avec son début réel (le journal annonce la vraie durée à la reprise ; les mesures
    /// antérieures sont de toute façon effacées). `date` est gardé pour la compatibilité des appels.
    public mutating func reset(at date: Date) {
        let open = isPaused ? periods.last?.start : nil
        periods.removeAll()
        if let open { periods.append(Period(start: min(open, date))) }
    }

    /// Les mesures hors des pauses (une mesure arrivée en retard pendant une pause est ignorée).
    public func excluding(_ samples: [PingSample]) -> [PingSample] {
        guard !periods.isEmpty else { return samples }
        return samples.filter { !covers($0.date) }
    }

    /// Une cible envoie-t-elle des paquets ? Ni la pause globale ni sa propre pause.
    public static func isSending(globalPaused: Bool, targetPaused: Bool) -> Bool {
        !globalPaused && !targetPaused
    }

    /// Message du journal (« mise en pause » / « reprise »), avec la durée de la pause à la reprise.
    public static func journalMessage(paused: Bool, duration: TimeInterval? = nil) -> String {
        if paused { return "mise en pause" }
        guard let duration, duration >= 1 else { return "reprise" }
        return "reprise après \(PingFormat.duration(duration)) de pause"
    }
}

/// Export CSV du ping continu : séparateur « ; », virgule décimale (Excel en français), une
/// ligne par mesure, sans les mesures tombées pendant une pause de la cible.
public enum PingCSV {
    /// Une cible exportée.
    public struct Target: Sendable {
        public var name: String
        public var address: String
        public var samples: [PingSample]
        public var pauses: PingPausePeriods

        public init(name: String, address: String, samples: [PingSample], pauses: PingPausePeriods = PingPausePeriods()) {
            self.name = name
            self.address = address
            self.samples = samples
            self.pauses = pauses
        }
    }

    public static let header = "horodatage;cible;adresse;seq;rtt_ms;perdu;raison"

    public static func make(_ targets: [Target]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [header]
        for target in targets {
            for sample in target.pauses.excluding(target.samples) {
                let rtt = sample.rttMs.map { PingFormat.decimal($0, digits: 3) } ?? ""
                lines.append([iso.string(from: sample.date), field(target.name), field(target.address),
                              "\(sample.sequence)", rtt, sample.isLost ? "1" : "0",
                              field(sample.failure?.label ?? "")].joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nombre de mesures exportées (hors pauses).
    public static func count(_ targets: [Target]) -> Int {
        targets.reduce(0) { $0 + $1.pauses.excluding($1.samples).count }
    }

    /// Champ texte sûr : ni séparateur ni saut de ligne, et pas de formule interprétée par le tableur.
    public static func field(_ text: String) -> String {
        var clean = text.replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if let first = clean.first, "=+-@".contains(first) { clean = "'" + clean }
        return clean
    }
}
