import Foundation

/// Gravité d'une entrée du journal.
public enum MonSeverity: String, Codable, Sendable, CaseIterable {
    case critical, warning, info, success

    public var label: String {
        switch self {
        case .critical: return "Critique"
        case .warning: return "Alerte"
        case .info: return "Info"
        case .success: return "Réussi"
        }
    }
}

/// Une entrée du journal des alertes.
public struct MonAlert: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var probeID: UUID?
    public var probeName: String
    public var severity: MonSeverity
    public var message: String
    public var resolvedAt: Date?
    /// Précision ajoutée au retour à la normale (« revenu à la normale (1,1 ms) »).
    public var resolution: String?
    public var acknowledgedAt: Date?
    public var acknowledgedBy: String?

    public init(id: UUID = UUID(), date: Date, probeID: UUID?, probeName: String, severity: MonSeverity,
                message: String, resolvedAt: Date? = nil, resolution: String? = nil,
                acknowledgedAt: Date? = nil, acknowledgedBy: String? = nil) {
        self.id = id
        self.date = date
        self.probeID = probeID
        self.probeName = probeName
        self.severity = severity
        self.message = message
        self.resolvedAt = resolvedAt
        self.resolution = resolution
        self.acknowledgedAt = acknowledgedAt
        self.acknowledgedBy = acknowledgedBy
    }

    public var isResolved: Bool { resolvedAt != nil }
    public var isAcknowledged: Bool { acknowledgedAt != nil }
    /// Alerte encore active et pas encore vue (badge de la barre latérale).
    public var isUnread: Bool { !isResolved && !isAcknowledged && (severity == .critical || severity == .warning) }

    /// Message complet, avec le retour à la normale s'il y a lieu.
    public var fullMessage: String {
        guard let resolution else { return message }
        let base = message.hasSuffix(".") ? String(message.dropLast()) : message
        return base + ", " + resolution + "."
    }
}

/// Filtres du journal.
public enum MonJournalFilter: String, CaseIterable, Sendable {
    case all, critical, resolved

    public var label: String {
        switch self {
        case .all: return "Toutes"
        case .critical: return "Critiques"
        case .resolved: return "Résolues"
        }
    }

    public func matches(_ alert: MonAlert) -> Bool {
        switch self {
        case .all: return true
        case .critical: return alert.severity == .critical
        case .resolved: return alert.isResolved
        }
    }
}

/// Journal des alertes, le plus récent en premier.
public struct MonJournal: Codable, Equatable, Sendable {
    public static let limit = 500

    public var alerts: [MonAlert]

    public init(alerts: [MonAlert] = []) {
        self.alerts = alerts
    }

    /// Alertes actives non accusées (badge de la barre latérale).
    public var unreadCount: Int { alerts.filter(\.isUnread).count }
    /// Entrées non accusées, résolues ou non (« 5 non accusées »).
    public var unacknowledgedCount: Int { alerts.filter { !$0.isAcknowledged }.count }

    public func count(_ filter: MonJournalFilter) -> Int { alerts.filter(filter.matches).count }
    public func filtered(_ filter: MonJournalFilter) -> [MonAlert] { alerts.filter(filter.matches) }

    /// Inscrit les événements d'une sonde ; renvoie les nouvelles alertes (à notifier).
    @discardableResult
    public mutating func record(_ events: [MonEvent], probe: MonProbe, date: Date) -> [MonAlert] {
        var created: [MonAlert] = []
        for event in events {
            switch event.kind {
            case .down, .warning:
                let severity: MonSeverity = event.kind == .down ? .critical : (probe.kind == .newDevices ? .info : .warning)
                let alert = MonAlert(date: date, probeID: probe.id, probeName: probe.name, severity: severity, message: event.message)
                alerts.insert(alert, at: 0)
                created.append(alert)
            case .recovered:
                // Résout les alertes ouvertes de la sonde (les notes d'information restent telles quelles).
                for index in alerts.indices where alerts[index].probeID == probe.id && !alerts[index].isResolved
                    && (alerts[index].severity == .critical || alerts[index].severity == .warning) {
                    alerts[index].resolvedAt = date
                    alerts[index].resolution = event.message + " à " + MonJournal.clock(date, seconds: false)
                }
            }
        }
        trim()
        return created
    }

    /// Ajoute une entrée libre (test manuel, information).
    public mutating func add(_ alert: MonAlert) {
        alerts.insert(alert, at: 0)
        trim()
    }

    public mutating func acknowledge(_ id: MonAlert.ID, by user: String, at date: Date) {
        guard let index = alerts.firstIndex(where: { $0.id == id }), !alerts[index].isAcknowledged else { return }
        alerts[index].acknowledgedAt = date
        alerts[index].acknowledgedBy = user
    }

    public mutating func acknowledgeAll(by user: String, at date: Date) {
        for index in alerts.indices where !alerts[index].isAcknowledged {
            alerts[index].acknowledgedAt = date
            alerts[index].acknowledgedBy = user
        }
    }

    /// Sonde supprimée : ses entrées restent au journal, sans lien vers elle.
    public mutating func detach(probe id: UUID) {
        for index in alerts.indices where alerts[index].probeID == id { alerts[index].probeID = nil }
    }

    public mutating func trim() {
        if alerts.count > MonJournal.limit { alerts.removeLast(alerts.count - MonJournal.limit) }
    }

    // MARK: Export

    /// Journal en CSV (séparateur « ; », comme Excel en français).
    public func csv() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        var lines = ["horodatage;gravite;sonde;evenement;resolue_le;accuse_par;accuse_le"]
        for alert in alerts {
            let fields = [formatter.string(from: alert.date), alert.severity.label, alert.probeName, alert.fullMessage,
                          alert.resolvedAt.map(formatter.string) ?? "", alert.acknowledgedBy ?? "",
                          alert.acknowledgedAt.map(formatter.string) ?? ""]
            lines.append(fields.map(MonJournal.csvField).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ text: String) -> String {
        var value = text
        // Une cellule qui commence par = + - @ serait lue comme une formule par un tableur.
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Dates

    /// « 14:30:10 » ou « 14:30 ».
    public static func clock(_ date: Date, seconds: Bool = true, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let base = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return seconds ? base + String(format: ":%02d", parts.second ?? 0) : base
    }

    /// « Aujourd'hui 14:30:10 », « Hier 23:00:41 », « 28 oct. 09:12:00 ».
    public static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Aujourd’hui " + clock(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Hier " + clock(date, calendar: calendar)
        }
        return dayFormatter.string(from: date) + " " + clock(date, calendar: calendar)
    }

    /// « 24 nov. 2026 ».
    public static func longDate(_ date: Date) -> String { yearFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}
