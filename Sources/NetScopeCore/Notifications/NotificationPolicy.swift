import Foundation

// Décision « faut-il notifier cet événement maintenant ? », sans UserNotifications : réglages
// (types activés, son, heures de silence, regroupement), réglages propres à la source (sonde) et
// état du regroupement. L'application ne fait que livrer ce qui est décidé ici.

/// Son des notifications.
public enum NotificationSound: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Jamais de son, même si la sonde en demande un.
    case off
    /// Événements critiques, et sondes qui demandent le son.
    case critical
    /// Toutes les notifications.
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Aucun"
        case .critical: return "Critiques"
        case .all: return "Tous"
        }
    }
}

/// Heure de la journée, en minutes depuis minuit (0 à 1 439).
public struct DayMinute: Codable, Hashable, Sendable, Comparable {
    public var minutes: Int

    public init(_ minutes: Int) {
        self.minutes = ((minutes % 1440) + 1440) % 1440
    }

    public init(hour: Int, minute: Int = 0) {
        self.init(hour * 60 + minute)
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }

    /// « 22:00 »
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    /// Lit « 22:00 » ou « 7:30 ».
    public init?(text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public static func of(_ date: Date, calendar: Calendar = .current) -> DayMinute {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return DayMinute(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    public static func < (lhs: DayMinute, rhs: DayMinute) -> Bool { lhs.minutes < rhs.minutes }
}

/// Période « Ne pas déranger » (de… à…), qui peut passer par-dessus minuit (22:00 à 07:00).
public struct QuietHours: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var start: DayMinute
    public var end: DayMinute

    public init(isEnabled: Bool = false, start: DayMinute = DayMinute(hour: 22), end: DayMinute = DayMinute(hour: 7)) {
        self.isEnabled = isEnabled
        self.start = start
        self.end = end
    }

    /// Vrai si `minute` tombe dans la période : début compris, fin exclue. Début = fin : période vide.
    public func contains(_ minute: DayMinute) -> Bool {
        guard isEnabled, start != end else { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        contains(DayMinute.of(date, calendar: calendar))
    }

    /// Durée de la période, en minutes (0 si désactivée ou vide).
    public var durationMinutes: Int {
        guard isEnabled, start != end else { return 0 }
        return (end.minutes - start.minutes + 1440) % 1440
    }
}

/// Réglages des notifications macOS (Réglages › Notifications).
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// Centre de notifications macOS : bannières et historique.
    public var bannersEnabled: Bool
    public var enabledKinds: Set<NetScopeEventKind>
    public var sound: NotificationSound
    public var quietHours: QuietHours
    /// Les événements critiques passent outre « Ne pas déranger ».
    public var criticalBypassQuietHours: Bool
    /// Regroupement : au-delà de `groupBurst` événements d'un même type en `groupWindow` secondes,
    /// une seule notification résume les suivants.
    public var grouping: Bool
    public var groupBurst: Int
    public var groupWindow: TimeInterval

    public static let defaultBurst = 3
    public static let defaultWindow: TimeInterval = 300

    public init(bannersEnabled: Bool = true,
                enabledKinds: Set<NetScopeEventKind> = Set(NetScopeEventKind.configurable.filter(\.enabledByDefault)),
                sound: NotificationSound = .critical, quietHours: QuietHours = QuietHours(),
                criticalBypassQuietHours: Bool = true, grouping: Bool = true,
                groupBurst: Int = NotificationSettings.defaultBurst, groupWindow: TimeInterval = NotificationSettings.defaultWindow) {
        self.bannersEnabled = bannersEnabled
        self.enabledKinds = enabledKinds
        self.sound = sound
        self.quietHours = quietHours
        self.criticalBypassQuietHours = criticalBypassQuietHours
        self.grouping = grouping
        self.groupBurst = groupBurst
        self.groupWindow = groupWindow
    }

    public func isEnabled(_ kind: NetScopeEventKind) -> Bool {
        kind == .test || enabledKinds.contains(kind)
    }

    public mutating func set(_ kind: NetScopeEventKind, enabled: Bool) {
        if enabled { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) }
    }

    // Lecture tolérante : clé absente → valeur par défaut ; type inconnu (version plus récente) ignoré.
    private enum CodingKeys: String, CodingKey {
        case bannersEnabled, enabledKinds, sound, quietHours, criticalBypassQuietHours, grouping, groupBurst, groupWindow
        /// Types connus de la version qui a écrit le fichier (un type plus récent prend sa valeur par défaut).
        case knownKinds
    }

    public init(from decoder: Decoder) throws {
        let defaults = NotificationSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bannersEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bannersEnabled)) ?? defaults.bannersEnabled
        if let raw = try? c.decodeIfPresent([String].self, forKey: .enabledKinds) {
            enabledKinds = Set(raw.compactMap(NetScopeEventKind.init(rawValue:)))
            // Type apparu depuis l'écriture du fichier : activé s'il l'est par défaut.
            let known = (try? c.decodeIfPresent([String].self, forKey: .knownKinds)).map { Set($0.compactMap(NetScopeEventKind.init(rawValue:))) }
                ?? Set(NetScopeEventKind.configurable).subtracting(NetScopeEventKind.introducedLater)
            // Note 78 : un type dédié (licence, WAN…) reprend l'état du type générique qui le portait.
            let saved = enabledKinds
            for kind in NetScopeEventKind.configurable where !known.contains(kind) {
                if kind.formerGeneric.map(saved.contains) ?? kind.enabledByDefault { enabledKinds.insert(kind) }
            }
        } else {
            enabledKinds = defaults.enabledKinds
        }
        sound = (try? c.decodeIfPresent(String.self, forKey: .sound)).flatMap { $0.flatMap(NotificationSound.init(rawValue:)) } ?? defaults.sound
        quietHours = (try? c.decodeIfPresent(QuietHours.self, forKey: .quietHours)) ?? defaults.quietHours
        criticalBypassQuietHours = (try? c.decodeIfPresent(Bool.self, forKey: .criticalBypassQuietHours)) ?? defaults.criticalBypassQuietHours
        grouping = (try? c.decodeIfPresent(Bool.self, forKey: .grouping)) ?? defaults.grouping
        groupBurst = max(1, (try? c.decodeIfPresent(Int.self, forKey: .groupBurst)) ?? defaults.groupBurst)
        groupWindow = min(max(10, (try? c.decodeIfPresent(TimeInterval.self, forKey: .groupWindow)) ?? defaults.groupWindow), 86_400)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bannersEnabled, forKey: .bannersEnabled)
        try c.encode(enabledKinds.map(\.rawValue).sorted(), forKey: .enabledKinds)
        try c.encode(NetScopeEventKind.configurable.map(\.rawValue).sorted(), forKey: .knownKinds)
        try c.encode(sound.rawValue, forKey: .sound)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(criticalBypassQuietHours, forKey: .criticalBypassQuietHours)
        try c.encode(grouping, forKey: .grouping)
        try c.encode(groupBurst, forKey: .groupBurst)
        try c.encode(groupWindow, forKey: .groupWindow)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Réglages enregistrés, ou valeurs par défaut si illisibles.
    public static func decoded(_ data: Data?) -> NotificationSettings {
        guard let data, let settings = try? JSONDecoder().decode(NotificationSettings.self, from: data) else {
            return NotificationSettings()
        }
        return settings
    }
}

/// Ce qu'il faut livrer.
public struct NotificationDelivery: Equatable, Sendable {
    /// Identifiant de la notification : le même remplace la précédente (résumé d'un regroupement).
    public var identifier: String
    public var title: String
    public var body: String
    /// Bannière du Centre de notifications ; faux : son seul (bip).
    public var banner: Bool
    public var sound: Bool
    /// Fil du Centre de notifications (les notifications d'un même fil sont empilées).
    public var thread: String
    /// Nombre d'événements résumés (1 : notification simple).
    public var groupedCount: Int
}

/// Décision pour un événement.
public enum NotificationDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case bannersDisabled, kindDisabled, quietHours, sourceDeclined, appActive

        public var label: String {
            switch self {
            case .bannersDisabled: return "notifications désactivées"
            case .kindDisabled: return "type désactivé"
            case .quietHours: return "ne pas déranger"
            case .sourceDeclined: return "désactivée sur la sonde"
            case .appActive: return "NetScope au premier plan"
            }
        }
    }

    case deliver(NotificationDelivery)
    case suppress(Reason)

    public var delivery: NotificationDelivery? {
        if case .deliver(let delivery) = self { return delivery }
        return nil
    }
}

/// Contexte du moment de la décision.
public struct NotificationContext: Sendable {
    public var now: Date
    /// NetScope est au premier plan (certains types, comme la fin de scan, ne sont alors pas notifiés).
    public var appIsActive: Bool
    public var calendar: Calendar

    public init(now: Date = Date(), appIsActive: Bool = false, calendar: Calendar = .current) {
        self.now = now
        self.appIsActive = appIsActive
        self.calendar = calendar
    }
}

/// Décide pour chaque événement. Garde l'état du regroupement : une instance par canal, utilisée
/// dans l'ordre des événements.
public struct NotificationPolicy: Sendable {
    private struct Burst: Sendable {
        var start: Date
        var count: Int
        var latestTitle: String
    }

    private var bursts: [NetScopeEventKind: Burst] = [:]

    public init() {}

    /// Types notifiés seulement quand NetScope n'est pas au premier plan.
    public static let onlyWhenInactive: Set<NetScopeEventKind> = [.scanFinished]

    /// Décision sans effet sur le regroupement (aperçu dans les réglages).
    public func preview(_ event: NetScopeEvent, settings: NotificationSettings, context: NotificationContext) -> NotificationDecision {
        var copy = self
        return copy.decide(event, settings: settings, context: context)
    }

    public mutating func decide(_ event: NetScopeEvent, settings: NotificationSettings, context: NotificationContext) -> NotificationDecision {
        // Une source qui refuse la bannière (sonde « sans notification ») ne sonne que si elle
        // demande elle-même le son : le réglage global ne la rend pas bruyante.
        let sound = Self.wantsSound(event, settings: settings) && (event.sourceAllowsBanner || event.sourceRequestsSound)
        // Notification de test : toujours livrée, avec le son choisi, pour vérifier l'autorisation.
        if event.kind == .test {
            return .deliver(NotificationDelivery(identifier: event.id, title: event.title, body: event.detail, banner: true,
                                                 sound: settings.sound != .off, thread: "test", groupedCount: 1))
        }
        guard settings.isEnabled(event.kind) else { return .suppress(.kindDisabled) }
        if context.appIsActive, Self.onlyWhenInactive.contains(event.kind) { return .suppress(.appActive) }
        let banner = settings.bannersEnabled && event.sourceAllowsBanner
        guard banner || sound else {
            return .suppress(settings.bannersEnabled ? .sourceDeclined : .bannersDisabled)
        }
        if settings.quietHours.contains(context.now, calendar: context.calendar),
           !(settings.criticalBypassQuietHours && event.severity == .critical) {
            return .suppress(.quietHours)
        }
        let thread = settings.grouping ? "type-" + event.kind.rawValue : (event.source ?? event.kind.rawValue)
        guard settings.grouping, banner else {
            return .deliver(NotificationDelivery(identifier: event.id, title: event.title, body: event.detail, banner: banner,
                                                 sound: sound, thread: thread, groupedCount: 1))
        }
        // Regroupement par type : les `groupBurst` premiers d'une fenêtre passent tels quels ; les
        // suivants remplacent une seule notification de résumé (même identifiant), sans son répété.
        var burst = bursts[event.kind] ?? Burst(start: event.date, count: 0, latestTitle: "")
        if context.now.timeIntervalSince(burst.start) >= settings.groupWindow || context.now < burst.start {
            burst = Burst(start: context.now, count: 0, latestTitle: "")
        }
        burst.count += 1
        burst.latestTitle = event.title
        bursts[event.kind] = burst
        let limit = max(1, settings.groupBurst)
        guard burst.count > limit else {
            return .deliver(NotificationDelivery(identifier: event.id, title: event.title, body: event.detail, banner: true,
                                                 sound: sound, thread: thread, groupedCount: 1))
        }
        let grouped = burst.count - limit
        let minutes = max(1, (settings.groupWindow / 60).clampedInt)
        let title = "\(event.kind.label)\u{00A0}: \(burst.count) événements en \(minutes)\u{00A0}min"
        let body = "Dernier\u{00A0}: \(event.title)" + (grouped > 1 ? " (et \(grouped - 1) autre\(grouped - 1 > 1 ? "s" : "") regroupé\(grouped - 1 > 1 ? "s" : ""))" : "")
        let identifier = "groupe-\(event.kind.rawValue)-\(Int(burst.start.timeIntervalSince1970))"
        return .deliver(NotificationDelivery(identifier: identifier, title: title, body: body, banner: true,
                                             sound: grouped == 1 && sound, thread: thread, groupedCount: grouped))
    }

    /// Son voulu pour cet événement, selon le réglage et la source.
    public static func wantsSound(_ event: NetScopeEvent, settings: NotificationSettings) -> Bool {
        switch settings.sound {
        case .off: return false
        case .all: return true
        case .critical: return event.severity == .critical || event.sourceRequestsSound
        }
    }
}
