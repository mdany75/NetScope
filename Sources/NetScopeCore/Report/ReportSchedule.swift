import Foundation

// Note 42 : rapports planifiés. Par site (un ou plusieurs : un fichier par site), un rythme (chaque
// jour, chaque semaine tel jour, chaque mois tel jour, à telle heure), les sections et le format,
// un dossier de destination et un nom de fichier daté. Ils sont produits quand l'app est ouverte ;
// une échéance manquée (Mac éteint, app fermée) est rattrapée UNE fois au lancement, sans rafale.
// Un rapport planifié ne lance JAMAIS de scan : il reprend le dernier scan du site et dit son âge.
// Rien n'est envoyé par courriel sans un choix explicite : un brouillon peut s'ouvrir dans Mail, ou (note 78)
// le rapport part par le serveur SMTP des Alertes si « Envoyer par courriel » est choisi pour ce rapport.
// Ce fichier ne fait que les calculs (échéances, rattrapage, nommage, textes) : aucun réseau.

/// Rythme d'un rapport planifié.
public enum ReportCadence: String, Codable, CaseIterable, Sendable, Identifiable {
    case daily, weekly, monthly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily: return "Chaque jour"
        case .weekly: return "Chaque semaine"
        case .monthly: return "Chaque mois"
        }
    }
}

/// Ce qui suit la production : rien, un brouillon de courriel ouvert dans Mail (jamais envoyé), ou
/// (note 78) l'envoi par le serveur SMTP des Alertes, seulement si l'utilisateur l'a choisi pour ce
/// rapport planifié.
public enum ReportScheduleEmail: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, draft, send

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Rien"
        case .draft: return "Préparer le courriel"
        case .send: return "Envoyer par courriel"
        }
    }
}

/// Issue de la dernière production.
public enum ReportScheduleStatus: String, Codable, Sendable {
    case ok, partial, failed
}

/// Un rapport planifié et l'état de sa dernière production.
public struct ReportSchedule: Codable, Hashable, Sendable, Identifiable {
    public static let defaultPattern = "rapport-{modele}-{site}-{date}"

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Sites du rapport (`SiteFiles.key`) : un fichier par site.
    public var siteKeys: [String]
    public var cadence: ReportCadence
    /// Jour de la semaine, comme `Calendar` : 1 dimanche, 2 lundi… 7 samedi.
    public var weekday: Int
    /// Jour du mois, 1 à 31 (ramené au dernier jour des mois plus courts).
    public var monthDay: Int
    public var hour: Int
    public var minute: Int
    /// Modèle, sections, client, technicien, masquage des MAC, signature et format.
    public var config: ReportConfig
    /// Dossier de destination ; nil : dossier des rapports de NetScope.
    public var folder: String?
    /// Nom de fichier, avec {site}, {modele}, {date}, {heure}, {client} ; toujours daté.
    public var fileNamePattern: String
    public var email: ReportScheduleEmail
    public var emailTo: String
    /// Note 78 : destinataires de l'envoi automatique, par site (clé : `SiteFiles.key`).
    public var mailRecipients: [String: [String]]
    /// Échéances antérieures ignorées : une création ou une modification ne rattrape rien du passé.
    public var activeSince: Date
    /// Échéance de la dernière production (pas l'heure réelle).
    public var lastSlot: Date?
    public var lastProduced: Date?
    public var lastStatus: ReportScheduleStatus?
    public var lastMessage: String?
    public var lastFiles: [String]

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, siteKeys: [String], cadence: ReportCadence = .weekly,
                weekday: Int = 2, monthDay: Int = 1, hour: Int = 7, minute: Int = 0, config: ReportConfig = ReportConfig(),
                folder: String? = nil, fileNamePattern: String = ReportSchedule.defaultPattern, email: ReportScheduleEmail = .none,
                emailTo: String = "", mailRecipients: [String: [String]] = [:], activeSince: Date = Date(), lastSlot: Date? = nil, lastProduced: Date? = nil,
                lastStatus: ReportScheduleStatus? = nil, lastMessage: String? = nil, lastFiles: [String] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.siteKeys = siteKeys
        self.cadence = cadence
        self.weekday = min(max(weekday, 1), 7)
        self.monthDay = min(max(monthDay, 1), 31)
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.config = config
        self.folder = folder
        self.fileNamePattern = fileNamePattern
        self.email = email
        self.emailTo = emailTo
        self.mailRecipients = mailRecipients
        self.activeSince = activeSince
        self.lastSlot = lastSlot
        self.lastProduced = lastProduced
        self.lastStatus = lastStatus
        self.lastMessage = lastMessage
        self.lastFiles = lastFiles
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, siteKeys, cadence, weekday, monthDay, hour, minute, config, folder, fileNamePattern, email,
             emailTo, mailRecipients, activeSince, lastSlot, lastProduced, lastStatus, lastMessage, lastFiles
    }

    /// Lecture tolérante : un champ absent ou d'une autre version prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Rapport planifié",
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true,
            siteKeys: (try? c.decodeIfPresent([String].self, forKey: .siteKeys)) ?? [],
            cadence: (try? c.decodeIfPresent(String.self, forKey: .cadence)).flatMap(ReportCadence.init(rawValue:)) ?? .weekly,
            weekday: (try? c.decodeIfPresent(Int.self, forKey: .weekday)) ?? 2,
            monthDay: (try? c.decodeIfPresent(Int.self, forKey: .monthDay)) ?? 1,
            hour: (try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? 7,
            minute: (try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? 0,
            config: (try? c.decodeIfPresent(ReportConfig.self, forKey: .config)) ?? ReportConfig(),
            folder: try? c.decodeIfPresent(String.self, forKey: .folder),
            fileNamePattern: (try? c.decodeIfPresent(String.self, forKey: .fileNamePattern)) ?? ReportSchedule.defaultPattern,
            email: (try? c.decodeIfPresent(String.self, forKey: .email)).flatMap(ReportScheduleEmail.init(rawValue:)) ?? .none,
            emailTo: (try? c.decodeIfPresent(String.self, forKey: .emailTo)) ?? "",
            mailRecipients: ((try? c.decodeIfPresent([String: [String]].self, forKey: .mailRecipients)) ?? nil) ?? [:],
            activeSince: (try? c.decodeIfPresent(Date.self, forKey: .activeSince)) ?? Date(),
            lastSlot: try? c.decodeIfPresent(Date.self, forKey: .lastSlot),
            lastProduced: try? c.decodeIfPresent(Date.self, forKey: .lastProduced),
            lastStatus: (try? c.decodeIfPresent(String.self, forKey: .lastStatus)).flatMap { $0.flatMap(ReportScheduleStatus.init(rawValue:)) },
            lastMessage: try? c.decodeIfPresent(String.self, forKey: .lastMessage),
            lastFiles: (try? c.decodeIfPresent([String].self, forKey: .lastFiles)) ?? [])
    }
}

/// Fichier des rapports planifiés (rapports/planifies.json).
public struct ReportScheduleBook: Codable, Hashable, Sendable {
    public var version = 1
    public var schedules: [ReportSchedule] = []

    public init(schedules: [ReportSchedule] = []) { self.schedules = schedules }

    enum CodingKeys: String, CodingKey { case version, schedules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        schedules = ((try? c.decodeIfPresent([ReportHistory.Lossy<ReportSchedule>].self, forKey: .schedules)) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(schedules, forKey: .schedules)
    }

    static let fileName = "planifies.json"

    public static func load(from directory: URL) -> ReportScheduleBook {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return ReportScheduleBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReportScheduleBook.self, from: data)) ?? ReportScheduleBook()
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

// MARK: - Moteur

public enum ReportScheduler {
    /// Écart minimal entre deux productions planifiées (rattrapage au lancement : une à la fois).
    public static let spacing: TimeInterval = 20
    /// Au-delà, la production est un rattrapage (« rattrapé au lancement »).
    public static let catchUpGrace: TimeInterval = 10 * 60
    /// Au-delà, le scan repris est signalé comme ancien.
    public static let staleScan: TimeInterval = 7 * 86_400

    static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre",
                         "novembre", "décembre"]

    /// Calendrier grégorien du fuseau local (ou de celui donné, pour les tests).
    public static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "fr_CA")
        return calendar
    }

    // MARK: Échéances

    /// Échéance du jour `day` (début de journée) si ce jour en a une, à l'heure du rapport.
    static func slot(on day: Date, _ schedule: ReportSchedule, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        switch schedule.cadence {
        case .daily:
            break
        case .weekly:
            guard parts.weekday == schedule.weekday else { return nil }
        case .monthly:
            guard let range = calendar.range(of: .day, in: .month, for: day) else { return nil }
            guard parts.day == min(schedule.monthDay, range.count) else { return nil }
        }
        return calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day)
    }

    /// Dernière échéance à `date` ou avant.
    public static func slot(onOrBefore date: Date, _ schedule: ReportSchedule, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: date)
        for back in 0...62 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let slot = slot(on: day, schedule, calendar: calendar) else { continue }
            if slot <= date { return slot }
        }
        return nil
    }

    /// Prochaine échéance strictement après `date`.
    public static func nextSlot(after date: Date, _ schedule: ReportSchedule, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: date)
        for ahead in 0...62 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: today),
                  let slot = slot(on: day, schedule, calendar: calendar) else { continue }
            if slot > date { return slot }
        }
        return nil
    }

    /// Échéance à produire maintenant, ou nil : la dernière échéance passée, si elle n'a pas déjà été
    /// produite et qu'elle suit la création (ou la dernière modification) du rapport planifié. Une seule
    /// échéance, même si plusieurs ont été manquées : jamais de rafale de rapports en retard.
    public static func dueSlot(_ schedule: ReportSchedule, now: Date, calendar: Calendar) -> Date? {
        guard schedule.isEnabled, !schedule.siteKeys.isEmpty,
              let slot = slot(onOrBefore: now, schedule, calendar: calendar) else { return nil }
        guard slot >= schedule.activeSince else { return nil }
        if let last = schedule.lastSlot, slot <= last { return nil }
        return slot
    }

    /// Rapports planifiés à produire, la plus ancienne échéance d'abord.
    public static func pending(_ schedules: [ReportSchedule], now: Date, calendar: Calendar) -> [(id: UUID, slot: Date)] {
        schedules.compactMap { schedule in dueSlot(schedule, now: now, calendar: calendar).map { (schedule.id, $0) } }
            .sorted { ($0.slot, $0.id.uuidString) < ($1.slot, $1.id.uuidString) }
    }

    /// Production en retard (Mac éteint, app fermée à l'échéance) : rattrapée au lancement.
    public static func isCatchUp(slot: Date, now: Date) -> Bool { now.timeIntervalSince(slot) > catchUpGrace }

    /// Prochaine production possible après la dernière (sans rafale).
    public static func canProduce(lastProduction: Date?, now: Date) -> Bool {
        guard let lastProduction else { return true }
        return now.timeIntervalSince(lastProduction) >= spacing || now < lastProduction
    }

    // MARK: Textes

    /// « 7 h 00 »
    public static func timeLabel(hour: Int, minute: Int) -> String {
        "\(hour)\u{00A0}h\u{00A0}" + String(format: "%02d", minute)
    }

    public static func weekdayName(_ weekday: Int) -> String { weekdays[min(max(weekday, 1), 7) - 1] }

    /// « Chaque jour à 7 h 00 », « Chaque lundi à 7 h 00 », « Le 1er de chaque mois à 6 h 30 »,
    /// « Le 31 de chaque mois (ou le dernier jour) à 7 h 00 ».
    public static func rhythmLabel(_ schedule: ReportSchedule) -> String {
        let time = timeLabel(hour: schedule.hour, minute: schedule.minute)
        switch schedule.cadence {
        case .daily: return "Chaque jour à \(time)"
        case .weekly: return "Chaque \(weekdayName(schedule.weekday)) à \(time)"
        case .monthly:
            let day = schedule.monthDay == 1 ? "1er" : "\(schedule.monthDay)"
            let last = schedule.monthDay > 28 ? " (ou le dernier jour)" : ""
            return "Le \(day) de chaque mois\(last) à \(time)"
        }
    }

    /// « lundi 9 novembre à 7 h 00 » ; l'année seulement si elle diffère de celle de `now`.
    public static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let year = calendar.component(.year, from: now)
        let day = p.day == 1 ? "1er" : "\(p.day ?? 0)"
        var text = "\(weekdayName(p.weekday ?? 1)) \(day) \(months[max(1, p.month ?? 1) - 1])"
        if p.year != year { text += " \(p.year ?? year)" }
        return text + " à " + timeLabel(hour: p.hour ?? 0, minute: p.minute ?? 0)
    }

    /// « 2026-11-02 9 h 12 »
    static func stamp(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.hour, .minute], from: date)
        return ReportText.isoDay(date, calendar: calendar) + " " + timeLabel(hour: p.hour ?? 0, minute: p.minute ?? 0)
    }

    /// « il y a 3 jours », « il y a 5 h », « il y a 12 min ».
    public static func ageLabel(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "à l’instant" }
        if minutes < 60 { return "il y a \(minutes)\u{00A0}min" }
        let hours = minutes / 60
        if hours < 48 { return "il y a \(hours)\u{00A0}h" }
        let days = hours / 24
        return "il y a \(days) jours"
    }

    /// Ce que le rapport planifié dit du scan qu'il reprend : sa date et son âge, et un
    /// avertissement s'il est ancien ou absent.
    public static func scanNote(scanDate: Date?, now: Date, calendar: Calendar) -> String {
        let intro = "Rapport planifié produit automatiquement le \(stamp(now, calendar: calendar))\u{00A0}; aucun scan n’a été lancé pour le produire."
        guard let scanDate else {
            return intro + " Aucun scan enregistré pour ce site\u{00A0}: lancer un scan du site dans le Scanner pour un rapport complet."
        }
        var text = intro + " Il reprend le dernier scan du site, du \(stamp(scanDate, calendar: calendar)) (\(ageLabel(scanDate, now: now)))."
        if now.timeIntervalSince(scanDate) > staleScan {
            text += " Ce scan date de plus de 7 jours\u{00A0}: relancer un scan du site pour un état à jour."
        }
        return text
    }

    /// Ajoute une note en tête de la première section du document.
    public static func annotate(_ document: inout ReportDocument, note: String) {
        guard !document.sections.isEmpty else {
            document.sections = [ReportSection(kind: .resume, heading: "Rapport planifié", blocks: [.note(note)])]
            return
        }
        document.sections[0].blocks.insert(.note(note), at: 0)
    }

    // MARK: Nom de fichier

    /// Nom de fichier daté d'un rapport planifié : {site}, {modele}, {date} (AAAA-MM-JJ), {heure}
    /// (HHhMM), {client} remplacés par des mots sûrs ; « {date} » ajouté s'il manque ; jamais de
    /// sous-dossier ni de caractère interdit. « rapport-audit-siege-2026-11-09.pdf »
    public static func fileName(pattern: String, siteName: String, config: ReportConfig, slot: Date, format: ReportFormat,
                                calendar: Calendar) -> String {
        var pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { pattern = ReportSchedule.defaultPattern }
        // Repères reconnus sans tenir compte de la casse : « {DATE} » compte comme « {date} ».
        if !pattern.lowercased().contains("{date}") { pattern += "-{date}" }
        let p = calendar.dateComponents([.hour, .minute], from: slot)
        let values: [String: String] = [
            "{site}": ReportText.slug(siteName.isEmpty ? "site" : siteName),
            "{modele}": config.template.rawValue,
            "{date}": ReportText.isoDay(slot, calendar: calendar),
            "{heure}": String(format: "%02dh%02d", p.hour ?? 0, p.minute ?? 0),
            "{client}": config.client.trimmingCharacters(in: .whitespaces).isEmpty ? "client" : ReportText.slug(config.client),
        ]
        // Parties littérales : sans séparateur de chemin, deux-points ni caractère de contrôle.
        var result = ""
        var rest = Substring(pattern)
        while !rest.isEmpty {
            if rest.first == "{", let close = rest.firstIndex(of: "}") {
                let token = String(rest[...close]).lowercased()
                if let value = values[token] {
                    result += value
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            let ch = rest.removeFirst()
            if ch == "/" || ch == ":" || ch == "\\" || ch.isNewline || ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                result += "-"
            } else if ch != "{" && ch != "}" {
                result.append(ch)
            }
        }
        while result.hasPrefix(".") || result.hasPrefix("-") || result.hasPrefix(" ") { result.removeFirst() }
        // Nom trop long : on coupe avant la date, jamais la date elle-même (deux échéances
        // donneraient sinon le même nom, et l'historique effacerait l'instantané précédent).
        if result.count > 120, let day = values["{date}"] {
            let cut = String(result.prefix(120))
            result = cut.contains(day) ? cut
                : String(result.prefix(120 - day.count - 1)).trimmingCharacters(in: CharacterSet(charactersIn: " -")) + "-" + day
        }
        result = result.trimmingCharacters(in: .whitespaces)
        if result.isEmpty { result = "rapport-" + ReportText.isoDay(slot, calendar: calendar) }
        return result + "." + format.fileExtension
    }
}
