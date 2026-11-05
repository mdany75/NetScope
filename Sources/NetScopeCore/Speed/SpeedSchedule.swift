import Foundation

// Note 78 (Speedtest) : sonde « débit Internet » planifiée, une fois par jour à l'heure choisie,
// réglée site par site. Le test tourne pour le site actif (celui où se trouve ce Mac) ; son
// résultat entre dans l'historique du Speedtest avec l'origine « planifié » et le site, ce qui
// donne la courbe par site sur 30 jours et l'alerte sous le seuil.
//
// Tout ce qui décide est ici, pur et testé sans réseau : échéance du jour, rattrapage, report
// (scan en cours, test déjà en cours, connexion absente ou limitée), seuil, courbe et résumé.

/// Réglage du test planifié d'un site.
public struct SpeedSchedule: Codable, Hashable, Sendable, Identifiable {
    /// Site concerné ; nil : ce Mac sans site (aucun site défini).
    public var siteID: UUID?
    public var isEnabled: Bool
    /// Heure du test, chaque jour.
    public var time: DayMinute
    /// Seuils d'alerte (Mb/s) ; nil : pas d'alerte dans ce sens.
    public var minDownMbps: Double?
    public var minUpMbps: Double?
    /// Activation (ou changement d'heure) : une échéance antérieure n'est pas rattrapée, pour ne
    /// pas lancer un test à la seconde où l'on coche la case.
    public var armedAt: Date?
    /// Dernier test planifié terminé (réussi ou non) : un seul par jour.
    public var lastRun: Date?
    public var lastStatus: SpeedScheduleStatus?

    public var id: String { SpeedSchedule.key(for: siteID) }

    public static func key(for siteID: UUID?) -> String { siteID?.uuidString ?? "sans-site" }

    public static let defaultTime = DayMinute(hour: 7)

    public init(siteID: UUID?, isEnabled: Bool = false, time: DayMinute = SpeedSchedule.defaultTime,
                minDownMbps: Double? = nil, minUpMbps: Double? = nil, armedAt: Date? = nil,
                lastRun: Date? = nil, lastStatus: SpeedScheduleStatus? = nil) {
        self.siteID = siteID
        self.isEnabled = isEnabled
        self.time = time
        self.minDownMbps = minDownMbps
        self.minUpMbps = minUpMbps
        self.armedAt = armedAt
        self.lastRun = lastRun
        self.lastStatus = lastStatus
    }

    /// Vrai si au moins un seuil est réglé.
    public var hasThreshold: Bool { minDownMbps != nil || minUpMbps != nil }
}

/// Résultat du dernier passage de la planification.
public enum SpeedScheduleStatus: Codable, Hashable, Sendable {
    /// Test réussi, au-dessus des seuils.
    case ok(downMbps: Double, upMbps: Double?)
    /// Test réussi, sous un seuil (alerte envoyée).
    case below(downMbps: Double, upMbps: Double?)
    /// Test en échec (serveur injoignable, interrompu…).
    case failed(String)
    /// Test reporté (scan en cours, connexion limitée…) : il sera retenté dans la journée.
    case postponed(String)
}

/// Raison de reporter un test planifié.
public enum SpeedScheduleBlocker: Equatable, Sendable {
    case scanning
    case testRunning
    case offline
    /// Partage de connexion, données mobiles ou mode données réduites : un test de débit
    /// consommerait des centaines de mégaoctets.
    case limitedConnection

    public var label: String {
        switch self {
        case .scanning: return "scan en cours"
        case .testRunning: return "un test de débit est déjà en cours"
        case .offline: return "pas de connexion"
        case .limitedConnection: return "connexion limitée (partage de connexion ou données réduites)"
        }
    }
}

/// Comparaison d'un résultat aux seuils du site.
public struct SpeedThresholdVerdict: Equatable, Sendable {
    public var downLow: Bool
    public var upLow: Bool

    public var isBelow: Bool { downLow || upLow }
}

/// Un point de la courbe : le test planifié d'une journée.
public struct SpeedDailyPoint: Identifiable, Hashable, Sendable {
    /// Début de la journée.
    public var day: Date
    /// Heure réelle du test.
    public var date: Date
    public var downMbps: Double
    public var upMbps: Double?
    public var latencyMs: Double?
    public var recordID: UUID

    public var id: Date { day }
}

/// Résumé des 30 jours d'un site.
public struct SpeedSiteSummary: Equatable, Sendable {
    public var count: Int
    public var averageDown: Double?
    public var averageUp: Double?
    public var minDown: Double?
    public var averageLatency: Double?
    /// Journées dont le test est sous un seuil réglé.
    public var daysBelow: Int
}

/// Décisions de la planification (fonctions pures).
public enum SpeedSchedulePlanner {
    /// Fenêtre de la courbe et du résumé.
    public static let windowDays = 30

    /// Échéance du jour de `date`, à l'heure du réglage.
    public static func slot(on date: Date, time: DayMinute, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start)
            ?? start.addingTimeInterval(Double(time.minutes) * 60)
    }

    /// Vrai si le test du jour doit partir : activé, heure passée, pas encore fait aujourd'hui,
    /// et échéance postérieure à l'activation. Un Mac en veille à l'heure prévue rattrape le
    /// test plus tard dans la même journée, jamais le lendemain.
    public static func isDue(_ schedule: SpeedSchedule, now: Date, calendar: Calendar = .current) -> Bool {
        guard schedule.isEnabled else { return false }
        let today = slot(on: now, time: schedule.time, calendar: calendar)
        guard now >= today else { return false }
        if let armedAt = schedule.armedAt, armedAt > today { return false }
        if let lastRun = schedule.lastRun, lastRun >= today { return false }
        return true
    }

    /// Prochain test prévu ; nil si la planification est désactivée. Un test dû renvoie `now`.
    public static func nextRun(_ schedule: SpeedSchedule, now: Date, calendar: Calendar = .current) -> Date? {
        guard schedule.isEnabled else { return nil }
        if isDue(schedule, now: now, calendar: calendar) { return now }
        let today = slot(on: now, time: schedule.time, calendar: calendar)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return slot(on: tomorrow, time: schedule.time, calendar: calendar)
    }

    /// Raison de reporter le test ; nil : il peut partir.
    public static func blocker(isScanning: Bool, testRunning: Bool, path: NetworkPathStatus?) -> SpeedScheduleBlocker? {
        if testRunning { return .testRunning }
        if isScanning { return .scanning }
        guard let path, path.isSatisfied else { return .offline }
        if path.isLimited { return .limitedConnection }
        return nil
    }

    /// Compare un résultat aux seuils du site.
    public static func verdict(downMbps: Double, upMbps: Double?, schedule: SpeedSchedule) -> SpeedThresholdVerdict {
        let downLow = schedule.minDownMbps.map { downMbps < $0 } ?? false
        let upLow = schedule.minUpMbps.flatMap { limit in upMbps.map { $0 < limit } } ?? false
        return SpeedThresholdVerdict(downLow: downLow, upLow: upLow)
    }

    /// Tests planifiés Internet d'un site sur les `days` derniers jours : un point par jour (le
    /// dernier test de la journée), du plus ancien au plus récent.
    public static func dailySeries(_ records: [SpeedTestRecord], siteID: UUID?, now: Date, days: Int = windowDays,
                                   calendar: Calendar = .current) -> [SpeedDailyPoint] {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        var byDay: [Date: SpeedTestRecord] = [:]
        for record in records where record.kind == .internet && record.isPlanned && record.siteID == siteID
            && record.date >= first && record.date <= now {
            let day = calendar.startOfDay(for: record.date)
            if let kept = byDay[day], kept.date >= record.date { continue }
            byDay[day] = record
        }
        return byDay.map { day, record in
            SpeedDailyPoint(day: day, date: record.date, downMbps: record.downMbps, upMbps: record.upMbps,
                            latencyMs: record.latencyMs, recordID: record.id)
        }
        .sorted { $0.day < $1.day }
    }

    /// Moyennes, minimum et journées sous le seuil.
    public static func summary(_ points: [SpeedDailyPoint], schedule: SpeedSchedule) -> SpeedSiteSummary {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let below = points.filter { verdict(downMbps: $0.downMbps, upMbps: $0.upMbps, schedule: schedule).isBelow }.count
        return SpeedSiteSummary(count: points.count, averageDown: mean(points.map(\.downMbps)),
                                averageUp: mean(points.compactMap(\.upMbps)), minDown: points.map(\.downMbps).min(),
                                averageLatency: mean(points.compactMap(\.latencyMs)), daysBelow: below)
    }

    /// Titre et détail de l'alerte (« Débit Internet sous le seuil : Siège »).
    public static func alertText(siteName: String, downMbps: Double, upMbps: Double?,
                                 schedule: SpeedSchedule) -> (title: String, detail: String) {
        let verdict = verdict(downMbps: downMbps, upMbps: upMbps, schedule: schedule)
        var parts: [String] = []
        if verdict.downLow, let limit = schedule.minDownMbps {
            parts.append("descente \(rate(downMbps)) Mb/s pour un seuil de \(rate(limit)) Mb/s")
        }
        if verdict.upLow, let limit = schedule.minUpMbps, let upMbps {
            parts.append("montée \(rate(upMbps)) Mb/s pour un seuil de \(rate(limit)) Mb/s")
        }
        let detail = parts.isEmpty ? "Débit mesuré\u{00A0}: \(rate(downMbps)) Mb/s."
            : "Test planifié\u{00A0}: " + parts.joined(separator: "\u{00A0}; ") + "."
        return ("Débit Internet sous le seuil\u{00A0}: \(siteName)", detail)
    }

    /// Débit lisible : entier au-delà de 100 Mb/s, une décimale (virgule) en dessous.
    public static func rate(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 100 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Réglages des tests planifiés, tous sites confondus.
public struct SpeedScheduleBook: Codable, Equatable, Sendable {
    public var version = 1
    public var schedules: [SpeedSchedule]

    public init(schedules: [SpeedSchedule] = []) {
        self.schedules = schedules
    }

    /// Réglage du site (désactivé par défaut s'il n'existe pas encore).
    public func schedule(for siteID: UUID?) -> SpeedSchedule {
        schedules.first { $0.siteID == siteID } ?? SpeedSchedule(siteID: siteID)
    }

    public mutating func set(_ schedule: SpeedSchedule) {
        if let index = schedules.firstIndex(where: { $0.siteID == schedule.siteID }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    /// Lecture tolérante : un fichier illisible donne une liste vide.
    public static func decode(_ data: Data) -> SpeedScheduleBook? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpeedScheduleBook.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Fichier des tests planifiés : ~/Library/Application Support/NetScope/speedtest-planifie.json.
public struct SpeedScheduleFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: SpeedScheduleFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SpeedScheduleFile(url: base.appendingPathComponent("NetScope", isDirectory: true)
            .appendingPathComponent("speedtest-planifie.json"))
    }

    public func load() -> SpeedScheduleBook {
        guard let data = try? Data(contentsOf: url) else { return SpeedScheduleBook() }
        return SpeedScheduleBook.decode(data) ?? SpeedScheduleBook()
    }

    public func save(_ book: SpeedScheduleBook) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try book.encoded().write(to: url, options: .atomic)
    }
}
