import Foundation

// Note 78 (Surveillance, 0.27.0) : heures ouvrables propres à chaque site, fenêtres de maintenance
// planifiées (ponctuelles ou répétées) pendant lesquelles les alertes sont suspendues et notées au
// journal, et rappel d'une alerte qui n'est pas accusée après N minutes. Calculs purs, sans réseau ;
// enregistrés avec les sondes dans surveillance.json (jamais dans sites.json : aucun autre écran
// n'en a besoin).

// MARK: - Heures ouvrables

/// Heures d'ouverture d'un jour (en minutes depuis minuit ; fin exclue, 1 440 = minuit).
public struct MonDayHours: Codable, Equatable, Sendable {
    public var isOpen: Bool
    public var start: Int
    public var end: Int

    public init(isOpen: Bool, start: Int = 7 * 60, end: Int = 18 * 60) {
        self.isOpen = isOpen
        self.start = min(max(start, 0), 1_439)
        self.end = min(max(end, self.start + 15), 1_440)
    }

    public static let closed = MonDayHours(isOpen: false)

    /// Vrai si la minute du jour tombe dans les heures d'ouverture.
    public func contains(minute: Int) -> Bool { isOpen && minute >= start && minute < end }

    /// « 7 h – 18 h », « 8 h 30 – 12 h ».
    public var label: String { MonBusinessHours.time(start) + " – " + MonBusinessHours.time(end) }
}

/// Heures ouvrables d'un site : un horaire par jour de la semaine.
public struct MonBusinessHours: Codable, Equatable, Sendable {
    /// Sept jours, comme `Calendar.weekday - 1` : 0 dimanche, 1 lundi… 6 samedi.
    public var days: [MonDayHours]

    public init(days: [MonDayHours]) {
        var list = Array(days.prefix(7))
        while list.count < 7 { list.append(.closed) }
        self.days = list
    }

    /// Du lundi au vendredi, de 7 h à 18 h (l'ancien horaire fixe de la Surveillance).
    public static let standard = MonBusinessHours(days: (0..<7).map { index in
        (1...5).contains(index) ? MonDayHours(isOpen: true, start: 7 * 60, end: 18 * 60) : .closed
    })

    /// Vrai si la date tombe dans les heures ouvrables.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let index = ((parts.weekday ?? 1) - 1 + 7) % 7
        return days[index].contains(minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// Ordre d'affichage : lundi d'abord, comme au Québec.
    public static let displayOrder = [1, 2, 3, 4, 5, 6, 0]
    public static let shortNames = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
    public static let longNames = ["Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"]

    /// « lun.–ven. 7 h – 18 h », « lun.–ven. 7 h – 18 h ; sam. 9 h – 12 h », « Aucune heure ouvrable ».
    /// Les jours consécutifs au même horaire sont regroupés.
    public var summary: String {
        var groups: [(first: Int, last: Int, hours: MonDayHours)] = []
        for index in Self.displayOrder where days[index].isOpen {
            let position = Self.displayOrder.firstIndex(of: index) ?? 0
            if let last = groups.last, last.hours == days[index],
               Self.displayOrder.firstIndex(of: last.last).map({ $0 + 1 == position }) == true {
                groups[groups.count - 1].last = index
            } else {
                groups.append((index, index, days[index]))
            }
        }
        guard !groups.isEmpty else { return "Aucune heure ouvrable" }
        return groups.map { group in
            let names = group.first == group.last ? Self.shortNames[group.first]
                : Self.shortNames[group.first] + "–" + Self.shortNames[group.last]
            return names + " " + group.hours.label
        }.joined(separator: "\u{00A0}; ")
    }

    /// « 7 h », « 7 h 30 », « 24 h ».
    public static func time(_ minutes: Int) -> String {
        let hour = minutes / 60, minute = minutes % 60
        return minute == 0 ? "\(hour)\u{00A0}h" : "\(hour)\u{00A0}h\u{00A0}" + String(format: "%02d", minute)
    }

    /// Heures proposées par l'éditeur (par demi-heure).
    public static let choices: [Int] = Array(stride(from: 0, through: 1_440, by: 30))

    private enum CodingKeys: String, CodingKey { case days }

    /// Lecture tolérante : un horaire incomplet ou illisible redevient l'horaire standard.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? c.decodeIfPresent([MonDayHours].self, forKey: .days)) ?? nil
        if let list, list.count == 7 { self.init(days: list) } else { self = .standard }
    }
}

extension MonDayHours {
    private enum CodingKeys: String, CodingKey { case isOpen, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isOpen: (try? c.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? false,
                  start: (try? c.decodeIfPresent(Int.self, forKey: .start)) ?? 7 * 60,
                  end: (try? c.decodeIfPresent(Int.self, forKey: .end)) ?? 18 * 60)
    }
}

// MARK: - Fenêtres de maintenance

/// Répétition d'une fenêtre de maintenance.
public enum MonMaintenanceRepeat: String, Codable, CaseIterable, Sendable, Identifiable {
    case once, daily, weekly, monthly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .once: return "Une seule fois"
        case .daily: return "Chaque jour"
        case .weekly: return "Chaque semaine"
        case .monthly: return "Chaque mois"
        }
    }
}

/// Une fenêtre de maintenance : pendant chaque occurrence, les sondes visées continuent de tourner,
/// mais aucune alerte n'est créée ; ce qui se serait produit est noté au journal. Les vérifications
/// faites pendant la fenêtre ne comptent pas dans la disponibilité.
public struct MonMaintenanceWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Début de la première occurrence.
    public var start: Date
    /// Durée de chaque occurrence, en minutes (15 min à 7 jours).
    public var durationMinutes: Int
    public var repeats: MonMaintenanceRepeat
    /// Dernière occurrence possible (nil : sans fin).
    public var until: Date?
    /// Site visé (nil : tous les sites).
    public var siteID: UUID?
    /// Sondes visées (vide : toutes les sondes du site, ou de tous les sites).
    public var probeIDs: [UUID]
    public var note: String

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, start: Date, durationMinutes: Int = 120,
                repeats: MonMaintenanceRepeat = .once, until: Date? = nil, siteID: UUID? = nil, probeIDs: [UUID] = [],
                note: String = "") {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.start = start
        self.durationMinutes = min(max(durationMinutes, 15), 7 * 24 * 60)
        self.repeats = repeats
        self.until = until
        self.siteID = siteID
        self.probeIDs = probeIDs
        self.note = note
    }

    /// Durées proposées par l'éditeur (minutes).
    public static let durations = [30, 60, 120, 180, 240, 360, 480, 720, 1_440, 2_880]

    /// « 30 min », « 2 h », « 2 h 30 », « 1 j », « 2 j ».
    public static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)\u{00A0}j" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)\u{00A0}h" : "\(hours)\u{00A0}h\u{00A0}" + String(format: "%02d", rest)
    }

    /// Vrai si la fenêtre vise cette sonde (de ce site).
    public func applies(probe: UUID, site: UUID?) -> Bool {
        if !probeIDs.isEmpty { return probeIDs.contains(probe) }
        guard let siteID else { return true }
        return site == siteID
    }

    /// Début de l'occurrence numéro `k` (0 : la première), ou nil après `until`.
    func occurrenceStart(_ k: Int, calendar: Calendar) -> Date? {
        guard k >= 0 else { return nil }
        let date: Date?
        switch repeats {
        case .once: date = k == 0 ? start : nil
        case .daily: date = calendar.date(byAdding: .day, value: k, to: start)
        case .weekly: date = calendar.date(byAdding: .day, value: 7 * k, to: start)
        // Toujours compté depuis le début : un 31 devient le 30 en avril, puis redevient le 31 en mai.
        case .monthly: date = calendar.date(byAdding: .month, value: k, to: start)
        }
        guard let date else { return nil }
        if let until, date > until { return nil }
        return date
    }

    /// Numéro approximatif de l'occurrence en cours à cette date.
    private func approximateIndex(_ date: Date) -> Int {
        let elapsed = date.timeIntervalSince(start)
        let period: Double
        switch repeats {
        case .once: return 0
        case .daily: period = 86_400
        case .weekly: period = 7 * 86_400
        case .monthly: period = 30.436_875 * 86_400
        }
        return Int((elapsed / period).rounded(.down))
    }

    /// Occurrence en cours à cette date (début inclus, fin exclue), ou nil.
    public func occurrence(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isEnabled, date >= start else { return nil }
        let duration = TimeInterval(durationMinutes * 60)
        let guess = approximateIndex(date)
        // Une occurrence longue (plus d'un jour) peut chevaucher les suivantes : on remonte un peu.
        let back = repeats == .daily ? durationMinutes / 1_440 + 2 : 2
        for k in stride(from: guess + 1, through: max(0, guess - back), by: -1) {
            guard let begin = occurrenceStart(k, calendar: calendar) else { continue }
            if begin <= date, date < begin.addingTimeInterval(duration) { return DateInterval(start: begin, duration: duration) }
        }
        return nil
    }

    /// Prochaine occurrence qui commence après cette date (ou celle en cours), ou nil.
    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isEnabled else { return nil }
        if let current = occurrence(containing: date, calendar: calendar) { return current }
        let duration = TimeInterval(durationMinutes * 60)
        let guess = max(0, approximateIndex(date) - 1)
        for k in guess...(guess + 40) {
            guard let begin = occurrenceStart(k, calendar: calendar) else { return nil }
            if begin > date { return DateInterval(start: begin, duration: duration) }
        }
        return nil
    }

    /// Vrai si aucune occurrence ne viendra plus (fenêtre ponctuelle passée, fin dépassée).
    public func isOver(at date: Date, calendar: Calendar = .current) -> Bool {
        nextOccurrence(after: date, calendar: calendar) == nil
    }

    /// « Une seule fois, 2 h », « Chaque jour à 22 h 00, 2 h », « Chaque dimanche à 2 h 00, 3 h »,
    /// « Le 1er de chaque mois à 23 h 00, 4 h ».
    public func rhythmLabel(calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.weekday, .day, .hour, .minute], from: start)
        let time = MonBusinessHours.time((p.hour ?? 0) * 60 + (p.minute ?? 0))
        let length = Self.durationLabel(durationMinutes)
        switch repeats {
        case .once: return "Une seule fois, \(length)"
        case .daily: return "Chaque jour à \(time), \(length)"
        case .weekly:
            let day = MonBusinessHours.longNames[((p.weekday ?? 1) - 1 + 7) % 7].lowercased()
            return "Chaque \(day) à \(time), \(length)"
        case .monthly:
            let day = p.day == 1 ? "1er" : "\(p.day ?? 1)"
            return "Le \(day) de chaque mois à \(time), \(length)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, start, durationMinutes, repeats, until, siteID, probeIDs, note
    }

    /// Lecture tolérante : un champ absent ou inconnu prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Maintenance",
                  isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true,
                  start: try c.decode(Date.self, forKey: .start),
                  durationMinutes: (try? c.decodeIfPresent(Int.self, forKey: .durationMinutes)) ?? 120,
                  repeats: (try? c.decodeIfPresent(MonMaintenanceRepeat.self, forKey: .repeats)) ?? .once,
                  until: (try? c.decodeIfPresent(Date.self, forKey: .until)) ?? nil,
                  siteID: (try? c.decodeIfPresent(UUID.self, forKey: .siteID)) ?? nil,
                  probeIDs: (try? c.decodeIfPresent([UUID].self, forKey: .probeIDs)) ?? [],
                  note: (try? c.decodeIfPresent(String.self, forKey: .note)) ?? "")
    }
}

// MARK: - Planification de la Surveillance

/// Heures ouvrables par site, fenêtres de maintenance et rappel des alertes non accusées.
public struct MonPlanning: Codable, Equatable, Sendable {
    /// Horaire des sondes sans site (et des sites sans horaire propre).
    public var defaultHours: MonBusinessHours
    /// Horaire propre à un site (clé : identifiant du site).
    public var siteHours: [String: MonBusinessHours]
    public var windows: [MonMaintenanceWindow]
    /// Rappel d'une alerte (critique ou avertissement) toujours ouverte et non accusée après N
    /// minutes ; 0 : pas de rappel.
    public var reminderMinutes: Int
    /// Nombre maximal de rappels pour une même alerte.
    public var reminderLimit: Int

    public init(defaultHours: MonBusinessHours = .standard, siteHours: [String: MonBusinessHours] = [:],
                windows: [MonMaintenanceWindow] = [], reminderMinutes: Int = 0, reminderLimit: Int = 3) {
        self.defaultHours = defaultHours
        self.siteHours = siteHours
        self.windows = windows
        self.reminderMinutes = max(0, reminderMinutes)
        self.reminderLimit = min(max(reminderLimit, 1), 10)
    }

    /// Délais de rappel proposés (minutes ; 0 : désactivé).
    public static let reminderChoices = [0, 15, 30, 60, 120, 240]

    /// « Désactivé », « Après 30 min », « Après 2 h ».
    public static func reminderLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Désactivé" : "Après " + MonMaintenanceWindow.durationLabel(minutes)
    }

    public func hours(for site: UUID?) -> MonBusinessHours {
        site.flatMap { siteHours[$0.uuidString] } ?? defaultHours
    }

    public func hasOwnHours(_ site: UUID) -> Bool { siteHours[site.uuidString] != nil }

    /// Fenêtre de maintenance en cours pour cette sonde, ou nil.
    public func activeWindow(probe: UUID, site: UUID?, at date: Date, calendar: Calendar = .current) -> MonMaintenanceWindow? {
        windows.first { $0.applies(probe: probe, site: site) && $0.occurrence(containing: date, calendar: calendar) != nil }
    }

    /// Ce qui décide si une alerte peut partir pour cette sonde à cette date.
    public func gate(probe: UUID, site: UUID?, at date: Date, calendar: Calendar = .current) -> MonAlertGate {
        MonAlertGate(hours: hours(for: site), maintenance: activeWindow(probe: probe, site: site, at: date, calendar: calendar))
    }

    private enum CodingKeys: String, CodingKey { case defaultHours, siteHours, windows, reminderMinutes, reminderLimit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let windows = (try? c.decodeIfPresent([MonLossy<MonMaintenanceWindow>].self, forKey: .windows)) ?? nil
        self.init(defaultHours: ((try? c.decodeIfPresent(MonBusinessHours.self, forKey: .defaultHours)) ?? nil) ?? .standard,
                  siteHours: ((try? c.decodeIfPresent([String: MonBusinessHours].self, forKey: .siteHours)) ?? nil) ?? [:],
                  windows: (windows ?? []).compactMap(\.value),
                  reminderMinutes: ((try? c.decodeIfPresent(Int.self, forKey: .reminderMinutes)) ?? nil) ?? 0,
                  reminderLimit: ((try? c.decodeIfPresent(Int.self, forKey: .reminderLimit)) ?? nil) ?? 3)
    }
}

/// Contexte d'alerte d'une vérification : heures ouvrables du site et maintenance en cours.
public struct MonAlertGate: Equatable, Sendable {
    public var hours: MonBusinessHours
    public var maintenance: MonMaintenanceWindow?

    public init(hours: MonBusinessHours = .standard, maintenance: MonMaintenanceWindow? = nil) {
        self.hours = hours
        self.maintenance = maintenance
    }
}

// MARK: - Site d'une sonde

/// Site auquel une sonde appartient : celui choisi dans l'éditeur, sinon celui dont les plages
/// contiennent l'adresse de la cible (le site actif d'abord, plusieurs sites pouvant avoir les mêmes
/// plages), sinon le site actif (sonde vers Internet, ce Mac, la FortiGate du site).
public enum MonSiteResolver {
    /// Adresse IPv4 de la cible (« 10.0.0.1 », « 10.0.0.1:443 », « https://10.0.0.1/ »), ou nil.
    public static func address(of target: String) -> IPv4Address? {
        let text = target.trimmingCharacters(in: .whitespaces)
        if let ip = IPv4Address(text) { return ip }
        if let pair = MonProbe.hostAndPort(text), let ip = IPv4Address(pair.host) { return ip }
        if let host = URL(string: text)?.host, let ip = IPv4Address(host) { return ip }
        return nil
    }

    public static func site(for probe: MonProbe, sites: [Site], active: UUID?) -> UUID? {
        if let chosen = probe.siteID, sites.contains(where: { $0.id == chosen }) { return chosen }
        if let ip = address(of: probe.target) {
            let matching = sites.filter { $0.contains(ip) }
            if let active, matching.contains(where: { $0.id == active }) { return active }
            if let first = matching.first { return first.id }
        }
        return active
    }
}

// MARK: - Rappels

/// Rappel des alertes ouvertes qui ne sont pas accusées.
public enum MonReminder {
    /// Alertes à rappeler maintenant : critiques ou avertissements toujours ouverts, non accusés,
    /// créés (ou rappelés) il y a au moins `minutes`, et rappelés moins de `limit` fois.
    public static func due(_ journal: MonJournal, minutes: Int, limit: Int, now: Date) -> [MonAlert.ID] {
        guard minutes > 0 else { return [] }
        let delay = TimeInterval(minutes * 60)
        return journal.alerts.filter { alert in
            alert.isUnread && (alert.reminderCount ?? 0) < limit
                && now.timeIntervalSince(alert.remindedAt ?? alert.date) >= delay
        }.map(\.id)
    }

    /// Texte du rappel (« Toujours non accusée après 30 min : … »).
    public static func message(for alert: MonAlert, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(alert.date) / 60))
        let age = minutes < 60 ? "\(minutes)\u{00A0}min"
            : MonMaintenanceWindow.durationLabel(minutes - minutes % 15)
        return "Toujours non accusée après \(age)\u{00A0}: " + alert.message
    }
}
