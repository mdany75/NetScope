import Foundation

/// Une heure d'historique d'une sonde.
public struct MonHourBucket: Codable, Equatable, Sendable {
    /// Début de l'heure.
    public var hour: Date
    public var total: Int
    /// Vérifications sans réponse (hors échecs ignorés).
    public var failures: Int
    /// Vérifications faites pendant une panne déclarée.
    public var downs: Int
    public var warnings: Int

    public init(hour: Date, total: Int = 0, failures: Int = 0, downs: Int = 0, warnings: Int = 0) {
        self.hour = hour
        self.total = total
        self.failures = failures
        self.downs = downs
        self.warnings = warnings
    }

    /// Couleur de la barre : hors ligne si une panne a été déclarée, seuil dépassé si un échec ou
    /// un avertissement a eu lieu, disponible sinon.
    public var slot: MonSlot {
        if total == 0 { return .none }
        if downs > 0 { return .down }
        if warnings > 0 || failures > 0 { return .warning }
        return .ok
    }
}

/// Une case de la barre de disponibilité 24 h.
public enum MonSlot: String, Codable, Sendable {
    case none, ok, warning, down
}

/// Historique 24 h de toutes les sondes, par heure (clé : identifiant de la sonde).
public struct MonHistory: Codable, Equatable, Sendable {
    public static let hours = 24

    public var buckets: [String: [MonHourBucket]]

    public init(buckets: [String: [MonHourBucket]] = [:]) {
        self.buckets = buckets
    }

    /// Ajoute une vérification.
    public mutating func record(probe id: UUID, result: MonResult, state: MonState, calendar: Calendar = .current) {
        guard state != .pending else { return }
        let hour = MonHistory.hourStart(result.date, calendar: calendar)
        var list = buckets[id.uuidString] ?? []
        if list.last?.hour != hour { list.append(MonHourBucket(hour: hour)) }
        var bucket = list[list.count - 1]
        bucket.total += 1
        if !result.reachable && state != .ignored { bucket.failures += 1 }
        if state == .down { bucket.downs += 1 }
        if state == .warning { bucket.warnings += 1 }
        list[list.count - 1] = bucket
        buckets[id.uuidString] = list
        prune(probe: id, now: result.date, calendar: calendar)
    }

    /// Les 24 cases, de la plus ancienne à l'heure en cours.
    public func slots(probe id: UUID, now: Date, calendar: Calendar = .current) -> [MonSlot] {
        let current = MonHistory.hourStart(now, calendar: calendar)
        var byHour: [Date: MonHourBucket] = [:]
        for bucket in buckets[id.uuidString] ?? [] { byHour[bucket.hour] = bucket }
        return (0..<MonHistory.hours).map { index in
            guard let hour = calendar.date(byAdding: .hour, value: index - (MonHistory.hours - 1), to: current) else { return .none }
            return byHour[hour]?.slot ?? .none
        }
    }

    /// Disponibilité sur 24 h (vérifications réussies / vérifications), en %, ou nil sans donnée.
    public func availability(probe id: UUID, now: Date, calendar: Calendar = .current) -> Double? {
        let oldest = calendar.date(byAdding: .hour, value: -(MonHistory.hours - 1), to: MonHistory.hourStart(now, calendar: calendar)) ?? now
        let recent = (buckets[id.uuidString] ?? []).filter { $0.hour >= oldest }
        let total = recent.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        let failures = recent.reduce(0) { $0 + $1.failures }
        return Double(total - failures) / Double(total) * 100
    }

    /// Retire les heures de plus de 24 h.
    public mutating func prune(probe id: UUID, now: Date, calendar: Calendar = .current) {
        guard let list = buckets[id.uuidString] else { return }
        let oldest = calendar.date(byAdding: .hour, value: -(MonHistory.hours - 1), to: MonHistory.hourStart(now, calendar: calendar)) ?? now
        buckets[id.uuidString] = list.filter { $0.hour >= oldest }
    }

    /// Ne garde que les sondes existantes, et 24 h pour chacune.
    public mutating func prune(keeping ids: Set<UUID>, now: Date, calendar: Calendar = .current) {
        let keys = Set(ids.map(\.uuidString))
        buckets = buckets.filter { keys.contains($0.key) }
        for id in ids { prune(probe: id, now: now, calendar: calendar) }
    }

    public static func hourStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }
}

/// Contenu de ~/Library/Application Support/NetScope/surveillance.json.
public struct MonArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var probes: [MonProbe]
    /// Suivi de chaque sonde (clé : identifiant).
    public var trackers: [String: MonTracker]
    public var history: MonHistory
    public var journal: MonJournal
    /// Éléments écartés à la lecture (sondes, suivis ou entrées illisibles) ; non enregistré.
    public var skipped = 0

    private enum CodingKeys: String, CodingKey { case version, probes, trackers, history, journal }

    public init(probes: [MonProbe] = [], trackers: [String: MonTracker] = [:], history: MonHistory = MonHistory(),
                journal: MonJournal = MonJournal()) {
        version = MonArchive.currentVersion
        self.probes = probes
        self.trackers = trackers
        self.history = history
        self.journal = journal
    }

    /// Lecture tolérante : une sonde, un suivi ou une entrée du journal illisible (valeur inconnue
    /// d'une autre version) est écarté seul ; le reste du fichier est gardé.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? MonArchive.currentVersion
        let probeList = (try? c.decodeIfPresent([MonLossy<MonProbe>].self, forKey: .probes)) ?? []
        probes = probeList.compactMap(\.value)
        let trackerMap = (try? c.decodeIfPresent([String: MonLossy<MonTracker>].self, forKey: .trackers)) ?? [:]
        trackers = trackerMap.compactMapValues(\.value)
        history = (try? c.decodeIfPresent(MonHistory.self, forKey: .history)) ?? MonHistory()
        journal = (try? c.decodeIfPresent(MonJournal.self, forKey: .journal)) ?? MonJournal()
        skipped = (probeList.count - probes.count) + (trackerMap.count - trackers.count) + journal.skipped
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(probes, forKey: .probes)
        try c.encode(trackers, forKey: .trackers)
        try c.encode(history, forKey: .history)
        try c.encode(journal, forKey: .journal)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MonArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MonArchive.self, from: data)
    }
}
