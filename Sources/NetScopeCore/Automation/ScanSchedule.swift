import Foundation

// Note 63 : scans planifiés par site. Chaque scan planifié vise UN site (ses plages enregistrées et
// ses plages exclues), certains jours de la semaine, à une heure, avec un profil de scan. Il est lancé
// par l'app ouverte, ou par l'agent sans fenêtre (note 64) quand l'app est fermée ; jamais pendant un
// autre scan. Le résultat alimente les résultats du site, son inventaire (historique et adressage),
// l'alerte « nouvel appareil » (si elle est activée dans Réglages › Alertes) et les rapports planifiés,
// qui reprennent le dernier scan du site.
//
// Ce fichier ne fait que les calculs (échéances, heure d'été, rattrapage après la veille, textes) et
// la lecture ou l'écriture du fichier scans-planifies.json : aucun réseau.

/// Issue d'une exécution planifiée.
public enum ScanRunOutcome: String, Codable, Sendable, CaseIterable {
    case ok, partial, failed, skipped, missed

    public var label: String {
        switch self {
        case .ok: return "Terminé"
        case .partial: return "Partiel"
        case .failed: return "Échec"
        case .skipped: return "Reporté"
        case .missed: return "Manqué"
        }
    }
}

/// Qui a lancé le scan planifié.
public enum ScanRunHost: String, Codable, Sendable {
    case app, agent

    public var label: String { self == .app ? "App" : "Agent" }
}

/// Un scan planifié et l'état de sa dernière exécution.
public struct ScanSchedule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Site visé (`SiteFiles.key`).
    public var siteKey: String
    public var isEnabled: Bool
    /// Jours, comme `Calendar` : 1 dimanche, 2 lundi… 7 samedi (triés, sans doublon).
    public var weekdays: [Int]
    public var hour: Int
    public var minute: Int
    public var profile: ScanProfile
    /// Échéances antérieures ignorées : une création ou une modification ne rattrape rien du passé.
    public var activeSince: Date
    /// Échéance de la dernière exécution (ou de la dernière échéance manquée).
    public var lastSlot: Date?
    public var lastRun: Date?
    public var lastOutcome: ScanRunOutcome?
    public var lastMessage: String?

    public init(id: UUID = UUID(), siteKey: String, isEnabled: Bool = true, weekdays: [Int] = [2, 3, 4, 5, 6],
                hour: Int = 2, minute: Int = 0, profile: ScanProfile = .rapide, activeSince: Date = Date(),
                lastSlot: Date? = nil, lastRun: Date? = nil, lastOutcome: ScanRunOutcome? = nil, lastMessage: String? = nil) {
        self.id = id
        self.siteKey = siteKey
        self.isEnabled = isEnabled
        self.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.profile = profile
        self.activeSince = activeSince
        self.lastSlot = lastSlot
        self.lastRun = lastRun
        self.lastOutcome = lastOutcome
        self.lastMessage = lastMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, siteKey, isEnabled, weekdays, hour, minute, profile, activeSince, lastSlot, lastRun, lastOutcome, lastMessage
    }

    /// Lecture tolérante : un champ absent ou d'une autre version prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            siteKey: (try? c.decodeIfPresent(String.self, forKey: .siteKey)) ?? SiteFiles.noSiteKey,
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true,
            weekdays: (try? c.decodeIfPresent([Int].self, forKey: .weekdays)) ?? [2, 3, 4, 5, 6],
            hour: (try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? 2,
            minute: (try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? 0,
            profile: (try? c.decodeIfPresent(String.self, forKey: .profile)).flatMap { $0.flatMap(ScanProfile.init(rawValue:)) } ?? .rapide,
            activeSince: (try? c.decodeIfPresent(Date.self, forKey: .activeSince)) ?? Date(),
            lastSlot: (try? c.decodeIfPresent(Date.self, forKey: .lastSlot)) ?? nil,
            lastRun: (try? c.decodeIfPresent(Date.self, forKey: .lastRun)) ?? nil,
            lastOutcome: (try? c.decodeIfPresent(String.self, forKey: .lastOutcome)).flatMap { $0.flatMap(ScanRunOutcome.init(rawValue:)) },
            lastMessage: (try? c.decodeIfPresent(String.self, forKey: .lastMessage)) ?? nil)
    }
}

/// Une ligne du journal des exécutions planifiées.
public struct ScanRunEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var slot: Date?
    public var scheduleID: UUID?
    public var siteKey: String
    public var siteName: String
    public var host: ScanRunHost
    public var outcome: ScanRunOutcome
    public var online: Int
    public var newCount: Int
    public var duration: TimeInterval
    public var message: String

    public init(id: UUID = UUID(), date: Date, slot: Date? = nil, scheduleID: UUID? = nil, siteKey: String, siteName: String,
                host: ScanRunHost, outcome: ScanRunOutcome, online: Int = 0, newCount: Int = 0, duration: TimeInterval = 0,
                message: String) {
        self.id = id
        self.date = date
        self.slot = slot
        self.scheduleID = scheduleID
        self.siteKey = siteKey
        self.siteName = siteName
        self.host = host
        self.outcome = outcome
        self.online = online
        self.newCount = newCount
        self.duration = duration
        self.message = message
    }
}

/// Fichier scans-planifies.json : les scans planifiés et le journal de leurs exécutions.
public struct ScanScheduleBook: Codable, Hashable, Sendable {
    public static let fileName = "scans-planifies.json"
    public static let maxRuns = 300

    public var version = 1
    public var schedules: [ScanSchedule]
    /// Du plus récent au plus ancien.
    public var runs: [ScanRunEntry]

    public init(schedules: [ScanSchedule] = [], runs: [ScanRunEntry] = []) {
        self.schedules = schedules
        self.runs = runs
    }

    enum CodingKeys: String, CodingKey { case version, schedules, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        schedules = ((try? c.decodeIfPresent([SiteLenient<ScanSchedule>].self, forKey: .schedules)) ?? nil)?.compactMap(\.value) ?? []
        runs = ((try? c.decodeIfPresent([SiteLenient<ScanRunEntry>].self, forKey: .runs)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// Ajoute une exécution en tête du journal (plafonné).
    public mutating func record(_ entry: ScanRunEntry) {
        runs.insert(entry, at: 0)
        if runs.count > Self.maxRuns { runs.removeLast(runs.count - Self.maxRuns) }
    }

    /// Note l'issue d'une échéance sur le scan planifié et au journal.
    public mutating func finish(_ id: UUID, slot: Date, entry: ScanRunEntry) {
        if let index = schedules.firstIndex(where: { $0.id == id }) {
            schedules[index].lastSlot = max(slot, schedules[index].lastSlot ?? slot)
            schedules[index].lastRun = entry.date
            schedules[index].lastOutcome = entry.outcome
            schedules[index].lastMessage = entry.message
        }
        record(entry)
    }

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    public static func load(from directory: URL) -> ScanScheduleBook {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return ScanScheduleBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ScanScheduleBook.self, from: data)) ?? ScanScheduleBook()
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}

/// Ce qu'il faut faire d'un scan planifié maintenant.
public enum ScanScheduleDecision: Equatable, Sendable {
    /// Rien à faire.
    case idle
    /// Lancer le scan de cette échéance ; `catchUp` : en retard (Mac en veille, app fermée), rattrapé une fois.
    case run(slot: Date, catchUp: Bool)
    /// Échéance trop ancienne (Mac éteint toute la nuit, par exemple) : notée « manquée », sans scan.
    case missed(slot: Date)

    public var slot: Date? {
        switch self {
        case .idle: return nil
        case .run(let slot, _), .missed(let slot): return slot
        }
    }
}

/// Calculs des scans planifiés (fonctions pures, testées).
public enum ScanScheduler {
    /// Au-delà, l'exécution est un rattrapage (« rattrapé après la veille »).
    public static let lateGrace: TimeInterval = 10 * 60
    /// Au-delà, l'échéance n'est plus rattrapée : un scan de 2 h fait à 15 h ne dirait plus rien de la nuit.
    public static let catchUpWindow: TimeInterval = 6 * 3_600

    static let shortDays = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]

    /// Calendrier grégorien du fuseau local (ou de celui donné, pour les tests).
    public static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "fr_CA")
        return calendar
    }

    // MARK: Échéances

    /// Échéance du jour de `day`, si ce jour est coché. Heure d'été : une heure qui n'existe pas
    /// (2 h 30 le jour où l'on avance l'heure) devient la première heure qui existe après (3 h 00) ;
    /// une heure qui existe deux fois (1 h 30 le jour où l'on recule l'heure) ne compte qu'une fois,
    /// la première.
    public static func slot(on day: Date, _ schedule: ScanSchedule, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard schedule.weekdays.contains(calendar.component(.weekday, from: start)) else { return nil }
        let wanted = DateComponents(hour: schedule.hour, minute: schedule.minute, second: 0)
        guard let date = calendar.nextDate(after: start.addingTimeInterval(-1), matching: wanted, matchingPolicy: .nextTime,
                                           repeatedTimePolicy: .first, direction: .forward),
              calendar.isDate(date, inSameDayAs: start) else { return nil }
        return date
    }

    /// Dernière échéance à `date` ou avant (sur huit jours).
    public static func slot(onOrBefore date: Date, _ schedule: ScanSchedule, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: date)
        for back in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let slot = slot(on: day, schedule, calendar: calendar) else { continue }
            if slot <= date { return slot }
        }
        return nil
    }

    /// Prochaine échéance strictement après `date`.
    public static func nextSlot(after date: Date, _ schedule: ScanSchedule, calendar: Calendar) -> Date? {
        guard schedule.isEnabled else { return nil }
        let today = calendar.startOfDay(for: date)
        for ahead in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: today),
                  let slot = slot(on: day, schedule, calendar: calendar) else { continue }
            if slot > date { return slot }
        }
        return nil
    }

    /// Décision pour un scan planifié : seule la dernière échéance passée compte (jamais de rafale
    /// après une longue veille), si elle suit la création ou la modification et n'est pas déjà faite.
    public static func decision(_ schedule: ScanSchedule, now: Date, calendar: Calendar) -> ScanScheduleDecision {
        guard schedule.isEnabled, !schedule.weekdays.isEmpty,
              let slot = slot(onOrBefore: now, schedule, calendar: calendar),
              slot >= schedule.activeSince else { return .idle }
        if let last = schedule.lastSlot, slot <= last { return .idle }
        let late = now.timeIntervalSince(slot)
        if late > catchUpWindow { return .missed(slot: slot) }
        return .run(slot: slot, catchUp: late > lateGrace)
    }

    /// Scans planifiés à traiter, la plus ancienne échéance d'abord.
    public static func pending(_ schedules: [ScanSchedule], now: Date, calendar: Calendar) -> [(id: UUID, decision: ScanScheduleDecision)] {
        schedules.compactMap { schedule -> (id: UUID, decision: ScanScheduleDecision, slot: Date)? in
            let decision = decision(schedule, now: now, calendar: calendar)
            guard let slot = decision.slot else { return nil }
            return (schedule.id, decision, slot)
        }
        .sorted { ($0.slot, $0.id.uuidString) < ($1.slot, $1.id.uuidString) }
        .map { ($0.id, $0.decision) }
    }

    /// Prochaine exécution, tous scans planifiés confondus.
    public static func nextRun(_ schedules: [ScanSchedule], after date: Date, calendar: Calendar) -> (id: UUID, date: Date)? {
        schedules.compactMap { schedule in nextSlot(after: date, schedule, calendar: calendar).map { (schedule.id, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// Jamais deux scans à la fois : ni pendant un scan manuel, ni pendant un autre scan planifié.
    public static func canStart(scanRunning: Bool, scheduledRunning: Bool) -> Bool { !scanRunning && !scheduledRunning }

    // MARK: Textes

    /// « 2 h 00 »
    public static func timeLabel(hour: Int, minute: Int) -> String {
        "\(hour)\u{00A0}h\u{00A0}" + String(format: "%02d", minute)
    }

    /// « Chaque jour », « Du lundi au vendredi », « Fins de semaine », « lun., mer., ven. ».
    public static func daysLabel(_ weekdays: [Int]) -> String {
        let days = Array(Set(weekdays)).sorted()
        switch days {
        case [1, 2, 3, 4, 5, 6, 7]: return "Chaque jour"
        case [2, 3, 4, 5, 6]: return "Du lundi au vendredi"
        case [1, 7]: return "Fins de semaine"
        case []: return "Aucun jour"
        default:
            // Semaine à la française : lundi d'abord, dimanche à la fin.
            let ordered = days.filter { $0 != 1 } + days.filter { $0 == 1 }
            return ordered.map { shortDays[$0 - 1] }.joined(separator: " ")
        }
    }

    /// « Du lundi au vendredi à 2 h 00 »
    public static func rhythmLabel(_ schedule: ScanSchedule) -> String {
        daysLabel(schedule.weekdays) + " à " + timeLabel(hour: schedule.hour, minute: schedule.minute)
    }

    /// « aujourd’hui à 2 h 00 », « demain à 2 h 00 », « lun. 9 nov. à 2 h 00 ».
    public static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let time = timeLabel(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd’hui à " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain à " + time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier à " + time
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date) + " à " + time
    }

    /// Résumé d'une exécution : « 42 en ligne, 2 nouveaux, 1 min 12 s ».
    public static func summary(online: Int, new: Int, duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        let time = seconds >= 60 ? "\(seconds / 60)\u{00A0}min\u{00A0}\(seconds % 60)\u{00A0}s" : "\(seconds)\u{00A0}s"
        return "\(online) en ligne, \(new) nouveau\(new > 1 ? "x" : ""), \(time)"
    }
}
