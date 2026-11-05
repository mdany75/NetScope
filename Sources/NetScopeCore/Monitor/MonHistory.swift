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
    /// Note 78 : vérifications faites pendant une fenêtre de maintenance (hors disponibilité).
    public var maintenance: Int?
    /// Note 78 : latence mesurée (somme, nombre de mesures, minimum et maximum, en ms).
    public var latencySum: Double?
    public var latencyCount: Int?
    public var latencyMin: Double?
    public var latencyMax: Double?

    public init(hour: Date, total: Int = 0, failures: Int = 0, downs: Int = 0, warnings: Int = 0) {
        self.hour = hour
        self.total = total
        self.failures = failures
        self.downs = downs
        self.warnings = warnings
    }

    /// Couleur de la barre : hors ligne si une panne a été déclarée, seuil dépassé si un échec ou
    /// un avertissement a eu lieu, maintenance si toutes les vérifications ont eu lieu pendant une
    /// fenêtre de maintenance, disponible sinon.
    public var slot: MonSlot {
        if total == 0 { return (maintenance ?? 0) > 0 ? .maintenance : .none }
        if downs > 0 { return .down }
        if warnings > 0 || failures > 0 { return .warning }
        return .ok
    }

    /// Latence moyenne de l'heure (ms), ou nil.
    public var latencyAverage: Double? {
        guard let sum = latencySum, let count = latencyCount, count > 0 else { return nil }
        return sum / Double(count)
    }
}

/// Une case de la barre de disponibilité 24 h.
public enum MonSlot: String, Codable, Sendable {
    case none, ok, warning, down
    /// Note 78 : heure passée en fenêtre de maintenance.
    case maintenance
}

/// Dix minutes d'historique d'une sonde (graphe de latence sur 24 h).
public struct MonFineBucket: Codable, Equatable, Sendable {
    public static let span: TimeInterval = 600

    public var start: Date
    public var total: Int
    public var failures: Int
    public var maintenance: Int
    public var latencySum: Double
    public var latencyCount: Int
    public var latencyMin: Double?
    public var latencyMax: Double?

    public init(start: Date, total: Int = 0, failures: Int = 0, maintenance: Int = 0, latencySum: Double = 0,
                latencyCount: Int = 0, latencyMin: Double? = nil, latencyMax: Double? = nil) {
        self.start = start
        self.total = total
        self.failures = failures
        self.maintenance = maintenance
        self.latencySum = latencySum
        self.latencyCount = latencyCount
        self.latencyMin = latencyMin
        self.latencyMax = latencyMax
    }
}

/// Un jour d'historique d'une sonde (disponibilité sur 90 jours, rapports).
public struct MonDayBucket: Codable, Equatable, Sendable {
    /// Début du jour.
    public var day: Date
    public var total: Int
    public var failures: Int
    public var downs: Int
    public var warnings: Int
    public var maintenance: Int
    /// Durée estimée hors ligne (intervalle de la sonde pour chaque vérification en panne), en secondes.
    public var downSeconds: Double
    public var latencySum: Double
    public var latencyCount: Int

    public init(day: Date, total: Int = 0, failures: Int = 0, downs: Int = 0, warnings: Int = 0, maintenance: Int = 0,
                downSeconds: Double = 0, latencySum: Double = 0, latencyCount: Int = 0) {
        self.day = day
        self.total = total
        self.failures = failures
        self.downs = downs
        self.warnings = warnings
        self.maintenance = maintenance
        self.downSeconds = downSeconds
        self.latencySum = latencySum
        self.latencyCount = latencyCount
    }

    /// Disponibilité du jour (vérifications réussies / vérifications, hors maintenance), ou nil.
    public var availability: Double? {
        total > 0 ? Double(total - failures) / Double(total) * 100 : nil
    }
}

/// Un point du graphe de latence (case de 10 minutes sur 24 h, ou d'une heure sur 7 jours).
public struct MonLatencyPoint: Equatable, Sendable, Identifiable {
    public var start: Date
    public var average: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var checks: Int
    public var failures: Int
    public var maintenance: Bool

    public var id: Date { start }
}

/// Durée affichée par le graphe de latence.
public enum MonLatencyRange: String, CaseIterable, Sendable, Identifiable {
    case day, week

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: return "24\u{00A0}h"
        case .week: return "7\u{00A0}j"
        }
    }

    /// Largeur d'une case, en secondes.
    public var step: TimeInterval { self == .day ? MonFineBucket.span : 3_600 }
    public var count: Int { self == .day ? 144 : 168 }
}

/// Historique des sondes (clé : identifiant de la sonde) : par heure sur 7 jours (barre de 24 h,
/// graphe de 7 jours), par tranche de 10 minutes sur 24 h (graphe de latence) et par jour sur
/// 90 jours (disponibilité de longue durée, rapports ; note 62).
public struct MonHistory: Codable, Equatable, Sendable {
    /// Cases de la barre de disponibilité.
    public static let hours = 24
    /// Heures gardées (graphe de 7 jours).
    public static let hourlyRetention = 7 * 24
    /// Jours gardés (rapport de disponibilité).
    public static let dailyRetention = 90

    public var buckets: [String: [MonHourBucket]]
    public var fine: [String: [MonFineBucket]]
    public var days: [String: [MonDayBucket]]

    public init(buckets: [String: [MonHourBucket]] = [:], fine: [String: [MonFineBucket]] = [:],
                days: [String: [MonDayBucket]] = [:]) {
        self.buckets = buckets
        self.fine = fine
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case buckets, fine, days }

    /// Lecture tolérante : un fichier d'une version précédente n'a que les heures.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = ((try? c.decodeIfPresent([String: [MonHourBucket]].self, forKey: .buckets)) ?? nil) ?? [:]
        fine = ((try? c.decodeIfPresent([String: [MonFineBucket]].self, forKey: .fine)) ?? nil) ?? [:]
        days = ((try? c.decodeIfPresent([String: [MonDayBucket]].self, forKey: .days)) ?? nil) ?? [:]
    }

    /// Ajoute une vérification. `interval` : intervalle de la sonde (durée hors ligne estimée) ;
    /// `inMaintenance` : la vérification a eu lieu pendant une fenêtre de maintenance (elle ne compte
    /// pas dans la disponibilité, sa latence reste au graphe).
    public mutating func record(probe id: UUID, result: MonResult, state: MonState, interval: Int = 60,
                                inMaintenance: Bool = false, calendar: Calendar = .current) {
        guard state != .pending else { return }
        let key = id.uuidString
        let failed = !result.reachable && state != .ignored
        let latency = result.reachable ? result.latencyMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil

        // Heure.
        let hour = MonHistory.hourStart(result.date, calendar: calendar)
        var list = buckets[key] ?? []
        if list.last?.hour != hour { list.append(MonHourBucket(hour: hour)) }
        var bucket = list[list.count - 1]
        if inMaintenance {
            bucket.maintenance = (bucket.maintenance ?? 0) + 1
        } else {
            bucket.total += 1
            if failed { bucket.failures += 1 }
            if state == .down { bucket.downs += 1 }
            if state == .warning { bucket.warnings += 1 }
        }
        if let latency {
            bucket.latencySum = (bucket.latencySum ?? 0) + latency
            bucket.latencyCount = (bucket.latencyCount ?? 0) + 1
            bucket.latencyMin = min(bucket.latencyMin ?? latency, latency)
            bucket.latencyMax = max(bucket.latencyMax ?? latency, latency)
        }
        list[list.count - 1] = bucket
        buckets[key] = list

        // Dix minutes.
        let slot = MonHistory.fineStart(result.date)
        var fineList = fine[key] ?? []
        if fineList.last?.start != slot { fineList.append(MonFineBucket(start: slot)) }
        var piece = fineList[fineList.count - 1]
        piece.total += 1
        if failed { piece.failures += 1 }
        if inMaintenance { piece.maintenance += 1 }
        if let latency {
            piece.latencySum += latency
            piece.latencyCount += 1
            piece.latencyMin = min(piece.latencyMin ?? latency, latency)
            piece.latencyMax = max(piece.latencyMax ?? latency, latency)
        }
        fineList[fineList.count - 1] = piece
        fine[key] = fineList

        // Jour.
        let day = calendar.startOfDay(for: result.date)
        var dayList = days[key] ?? []
        if dayList.last?.day != day { dayList.append(MonDayBucket(day: day)) }
        var daily = dayList[dayList.count - 1]
        if inMaintenance {
            daily.maintenance += 1
        } else {
            daily.total += 1
            if failed { daily.failures += 1 }
            if state == .down {
                daily.downs += 1
                daily.downSeconds += Double(max(1, interval))
            }
            if state == .warning { daily.warnings += 1 }
        }
        if let latency {
            daily.latencySum += latency
            daily.latencyCount += 1
        }
        dayList[dayList.count - 1] = daily
        days[key] = dayList

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

    // MARK: Graphe de latence (note 78)

    /// Points du graphe : `range.count` cases régulières se terminant par la case en cours (cases
    /// vides comprises, pour montrer les trous).
    public func latencySeries(probe id: UUID, range: MonLatencyRange, now: Date, calendar: Calendar = .current) -> [MonLatencyPoint] {
        switch range {
        case .day:
            let current = MonHistory.fineStart(now)
            var byStart: [Date: MonFineBucket] = [:]
            for bucket in fine[id.uuidString] ?? [] { byStart[bucket.start] = bucket }
            return (0..<range.count).map { index in
                let start = current.addingTimeInterval(-Double(range.count - 1 - index) * MonFineBucket.span)
                guard let b = byStart[start] else {
                    return MonLatencyPoint(start: start, checks: 0, failures: 0, maintenance: false)
                }
                return MonLatencyPoint(start: start, average: b.latencyCount > 0 ? b.latencySum / Double(b.latencyCount) : nil,
                                       minimum: b.latencyMin, maximum: b.latencyMax, checks: b.total, failures: b.failures,
                                       maintenance: b.maintenance > 0)
            }
        case .week:
            let current = MonHistory.hourStart(now, calendar: calendar)
            var byHour: [Date: MonHourBucket] = [:]
            for bucket in buckets[id.uuidString] ?? [] { byHour[bucket.hour] = bucket }
            return (0..<range.count).map { index in
                let start = calendar.date(byAdding: .hour, value: index - (range.count - 1), to: current) ?? current
                guard let b = byHour[start] else {
                    return MonLatencyPoint(start: start, checks: 0, failures: 0, maintenance: false)
                }
                return MonLatencyPoint(start: start, average: b.latencyAverage, minimum: b.latencyMin, maximum: b.latencyMax,
                                       checks: b.total + (b.maintenance ?? 0), failures: b.failures,
                                       maintenance: (b.maintenance ?? 0) > 0)
            }
        }
    }

    /// Résumé d'une série : latence moyenne, 95e centile des moyennes, maximum, échecs.
    public static func latencySummary(_ points: [MonLatencyPoint]) -> (average: Double?, p95: Double?, maximum: Double?, failures: Int) {
        let averages = points.compactMap(\.average).sorted()
        let failures = points.reduce(0) { $0 + $1.failures }
        guard !averages.isEmpty else { return (nil, nil, nil, failures) }
        let average = averages.reduce(0, +) / Double(averages.count)
        let index = min(averages.count - 1, Int((Double(averages.count) * 0.95).rounded(.up)) - 1)
        return (average, averages[max(0, index)], points.compactMap(\.maximum).max(), failures)
    }

    // MARK: Disponibilité de longue durée (note 62)

    /// Disponibilité de chaque jour, du plus ancien au jour de `end` (nil : aucune vérification).
    public func dailyAvailability(probe id: UUID, days count: Int, end: Date, calendar: Calendar = .current) -> [(day: Date, percent: Double?)] {
        let last = calendar.startOfDay(for: end)
        var byDay: [Date: MonDayBucket] = [:]
        for bucket in days[id.uuidString] ?? [] { byDay[bucket.day] = bucket }
        return (0..<max(1, count)).map { index in
            let day = calendar.date(byAdding: .day, value: index - (count - 1), to: last) ?? last
            return (day, byDay[day]?.availability)
        }
    }

    /// Jours d'historique d'une sonde dans la période (du jour de `start` au jour de `end` inclus).
    public func dayBuckets(probe id: UUID, from start: Date, to end: Date, calendar: Calendar = .current) -> [MonDayBucket] {
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
        return (days[id.uuidString] ?? []).filter { $0.day >= first && $0.day <= last }
    }

    // MARK: Nettoyage

    /// Retire ce qui dépasse les durées gardées (7 jours par heure, 24 h par 10 minutes, 90 jours par jour).
    public mutating func prune(probe id: UUID, now: Date, calendar: Calendar = .current) {
        let key = id.uuidString
        if let list = buckets[key] {
            let oldest = calendar.date(byAdding: .hour, value: -(MonHistory.hourlyRetention - 1),
                                       to: MonHistory.hourStart(now, calendar: calendar)) ?? now
            buckets[key] = list.filter { $0.hour >= oldest }
        }
        if let list = fine[key] {
            let oldest = MonHistory.fineStart(now).addingTimeInterval(-Double(MonLatencyRange.day.count - 1) * MonFineBucket.span)
            fine[key] = list.filter { $0.start >= oldest }
        }
        if let list = days[key] {
            let oldest = calendar.date(byAdding: .day, value: -(MonHistory.dailyRetention - 1), to: calendar.startOfDay(for: now)) ?? now
            days[key] = list.filter { $0.day >= oldest }
        }
    }

    /// Ne garde que les sondes existantes, et les durées prévues pour chacune.
    public mutating func prune(keeping ids: Set<UUID>, now: Date, calendar: Calendar = .current) {
        let keys = Set(ids.map(\.uuidString))
        buckets = buckets.filter { keys.contains($0.key) }
        fine = fine.filter { keys.contains($0.key) }
        days = days.filter { keys.contains($0.key) }
        for id in ids { prune(probe: id, now: now, calendar: calendar) }
    }

    /// Efface tout l'historique d'une sonde (cible ou type changé, sonde supprimée).
    public mutating func remove(probe id: UUID) {
        buckets[id.uuidString] = nil
        fine[id.uuidString] = nil
        days[id.uuidString] = nil
    }

    public static func hourStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    /// Début de la tranche de 10 minutes (indépendant du fuseau).
    public static func fineStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / MonFineBucket.span).rounded(.down) * MonFineBucket.span)
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
    /// Note 78 : heures ouvrables par site, fenêtres de maintenance, rappels.
    public var planning: MonPlanning
    /// Éléments écartés à la lecture (sondes, suivis ou entrées illisibles) ; non enregistré.
    public var skipped = 0

    private enum CodingKeys: String, CodingKey { case version, probes, trackers, history, journal, planning }

    public init(probes: [MonProbe] = [], trackers: [String: MonTracker] = [:], history: MonHistory = MonHistory(),
                journal: MonJournal = MonJournal(), planning: MonPlanning = MonPlanning()) {
        version = MonArchive.currentVersion
        self.probes = probes
        self.trackers = trackers
        self.history = history
        self.journal = journal
        self.planning = planning
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
        planning = ((try? c.decodeIfPresent(MonPlanning.self, forKey: .planning)) ?? nil) ?? MonPlanning()
        skipped = (probeList.count - probes.count) + (trackerMap.count - trackers.count) + journal.skipped
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(probes, forKey: .probes)
        try c.encode(trackers, forKey: .trackers)
        try c.encode(history, forKey: .history)
        try c.encode(journal, forKey: .journal)
        try c.encode(planning, forKey: .planning)
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
