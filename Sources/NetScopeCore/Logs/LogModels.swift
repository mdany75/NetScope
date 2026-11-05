import Foundation

// Note 43 : journaux reçus par NetScope (Syslog, traps SNMP) ou lus sur la FortiGate (API REST,
// lecture seule). Un message garde son site (celui du Mac au moment de la réception, ou celui de
// la FortiGate lue) : un site n'est jamais déduit de la seule adresse IP, plusieurs sites pouvant
// partager les mêmes plages.

/// Gravité d'un message, de la plus grave (0, urgence) à la moins grave (7, débogage), comme
/// Syslog (RFC 5424, section 6.2.1).
public enum LogSeverity: Int, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case emergency = 0, alert, critical, error, warning, notice, info, debug

    public var id: Int { rawValue }

    /// Libellé français (« Erreur »).
    public var label: String {
        switch self {
        case .emergency: return "Urgence"
        case .alert: return "Alerte"
        case .critical: return "Critique"
        case .error: return "Erreur"
        case .warning: return "Avertissement"
        case .notice: return "Notice"
        case .info: return "Information"
        case .debug: return "Débogage"
        }
    }

    /// Mot-clé Syslog (« err »).
    public var keyword: String {
        switch self {
        case .emergency: return "emerg"
        case .alert: return "alert"
        case .critical: return "crit"
        case .error: return "err"
        case .warning: return "warning"
        case .notice: return "notice"
        case .info: return "info"
        case .debug: return "debug"
        }
    }

    /// « ≥ Erreur » : cette gravité ou plus grave.
    public var atLeastLabel: String { "≥\u{00A0}" + label }

    /// Vrai si le message est au moins aussi grave que `minimum`.
    public func isAtLeast(_ minimum: LogSeverity) -> Bool { rawValue <= minimum.rawValue }

    /// Plus grave = plus petit (tri « les plus graves d'abord » en ordre croissant).
    public static func < (lhs: LogSeverity, rhs: LogSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Gravité écrite par un équipement : chiffre Syslog, mot-clé (« err », « warning »), niveau
    /// FortiOS (« notification », « information »), libellé français.
    public init?(text: String) {
        let t = SearchText.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let number = Int(t), let value = LogSeverity(rawValue: number) {
            self = value
            return
        }
        switch t {
        case "emerg", "emergency", "panic", "urgence": self = .emergency
        case "alert", "alerte": self = .alert
        case "crit", "critical", "critique": self = .critical
        case "err", "error", "erreur": self = .error
        case "warn", "warning", "avertissement": self = .warning
        case "notice", "notification": self = .notice
        case "info", "information", "informational": self = .info
        case "debug", "debogage": self = .debug
        default: return nil
        }
    }
}

/// D'où vient le message.
public enum LogSource: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Reçu par le récepteur Syslog de ce Mac (RFC 3164, RFC 5424, format clé=valeur de FortiOS).
    case syslog
    /// Trap SNMP v1 ou v2c (ou inform) reçue par ce Mac.
    case trap
    /// Journal d'événements lu sur la FortiGate par l'API REST (lecture seule).
    case fortigate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .syslog: return "Syslog"
        case .trap: return "Trap SNMP"
        case .fortigate: return "FortiGate"
        }
    }

    /// Valeurs reconnues par la recherche (« source:trap »).
    public var searchValues: [String] {
        switch self {
        case .syslog: return ["Syslog"]
        case .trap: return ["Trap SNMP", "trap", "snmp"]
        case .fortigate: return ["FortiGate", "API", "fgt"]
        }
    }
}

/// Un message du journal.
public struct LogMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Heure retenue : celle de l'équipement quand elle est sûre (5424, FortiGate), sinon l'heure de réception.
    public var date: Date
    /// Heure de réception par NetScope (nil pour un journal lu sur la FortiGate).
    public var received: Date?
    public var source: LogSource
    public var severity: LogSeverity
    /// Facilité Syslog (0 à 23).
    public var facility: Int?
    /// Adresse de l'émetteur (paquet reçu) ou de la FortiGate lue.
    public var host: String
    /// Nom donné par le message lui-même (HOSTNAME, devname, sysName).
    public var hostname: String?
    /// Programme ou étiquette (« sshd », « FortiOS · system », « SNMPv2c »).
    public var app: String?
    /// Identifiant de l'événement : logid FortiOS, nom ou OID de la trap, mnémonique Cisco.
    public var eventID: String?
    public var message: String
    /// Site du message (clé `SiteFiles.key`) et son nom au moment de la réception.
    public var siteKey: String
    public var siteName: String
    /// Champs lus (clé=valeur FortiOS, données structurées 5424, varbinds de la trap).
    public var fields: [String: String]
    /// Texte brut (tronqué), pour le détail et le diagnostic.
    public var raw: String

    public init(id: UUID = UUID(), date: Date, received: Date? = nil, source: LogSource, severity: LogSeverity,
                facility: Int? = nil, host: String, hostname: String? = nil, app: String? = nil, eventID: String? = nil,
                message: String, siteKey: String = "", siteName: String = "", fields: [String: String] = [:], raw: String = "") {
        self.id = id
        self.date = date
        self.received = received
        self.source = source
        self.severity = severity
        self.facility = facility
        self.host = host
        self.hostname = hostname
        self.app = app
        self.eventID = eventID
        self.message = message
        self.siteKey = siteKey
        self.siteName = siteName
        self.fields = fields
        self.raw = raw
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, received, source, severity, facility, host, hostname, app, eventID, message, siteKey, siteName, fields, raw
    }

    /// Lecture tolérante (journal enregistré par une autre version) : seuls la date, la source et
    /// l'adresse sont exigés, le reste prend une valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        received = try? c.decodeIfPresent(Date.self, forKey: .received)
        source = try c.decode(LogSource.self, forKey: .source)
        severity = (try? c.decodeIfPresent(LogSeverity.self, forKey: .severity)) ?? .info
        facility = try? c.decodeIfPresent(Int.self, forKey: .facility)
        host = try c.decode(String.self, forKey: .host)
        hostname = try? c.decodeIfPresent(String.self, forKey: .hostname)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        eventID = try? c.decodeIfPresent(String.self, forKey: .eventID)
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        siteKey = (try? c.decodeIfPresent(String.self, forKey: .siteKey)) ?? ""
        siteName = (try? c.decodeIfPresent(String.self, forKey: .siteName)) ?? ""
        fields = (try? c.decodeIfPresent([String: String].self, forKey: .fields)) ?? [:]
        raw = (try? c.decodeIfPresent(String.self, forKey: .raw)) ?? ""
    }

    /// Nom de l'appareil tel que le message le donne (son nom, sinon son adresse).
    public var deviceLabel: String {
        if let hostname, !hostname.isEmpty, hostname != "-" { return hostname }
        return host
    }

    /// Clé de `fields` qui garde l'heure déclarée par l'équipement quand elle a été écartée.
    public static let declaredDateField = "heure_declaree"
    /// Écart au-delà duquel l'heure déclarée n'est plus crue (horloge sans NTP, 1970 ou 2000 après un redémarrage).
    public static let clockSkewLimit: TimeInterval = 86_400

    /// Heure de référence pour la fenêtre des sondes : la réception, sinon l'heure retenue.
    public var arrival: Date { received ?? date }

    /// Le même message, daté de sa réception si l'horloge de l'équipement est décalée de plus d'un
    /// jour ; l'heure déclarée reste dans `fields` (ISO 8601). Sans effet sur un message lu sur la FortiGate.
    public func withTrustedClock() -> LogMessage {
        guard let received, abs(date.timeIntervalSince(received)) > Self.clockSkewLimit else { return self }
        var copy = self
        copy.fields[Self.declaredDateField] = LogFormat.iso(date)
        copy.date = received
        return copy
    }

    /// Le même message, rattaché à un site.
    public func attached(siteKey: String, siteName: String) -> LogMessage {
        var copy = self
        copy.siteKey = siteKey
        copy.siteName = siteName
        return copy
    }

    /// Longueurs maximales gardées (un message énorme ne doit pas gonfler le journal).
    public static let messageLimit = 2_048
    public static let rawLimit = 4_096

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

/// Facilités Syslog (RFC 5424, section 6.2.1).
public enum LogFacility {
    static let names = ["kern", "user", "mail", "daemon", "auth", "syslog", "lpr", "news", "uucp", "cron", "authpriv",
                        "ftp", "ntp", "audit", "alert", "clock", "local0", "local1", "local2", "local3", "local4",
                        "local5", "local6", "local7"]

    /// « local7 » ; nil hors de 0 à 23.
    public static func name(_ code: Int) -> String? {
        names.indices.contains(code) ? names[code] : nil
    }

    public static func code(_ name: String) -> Int? {
        names.firstIndex(of: name.lowercased())
    }
}

/// Mise en forme commune des journaux (typographie française).
public enum LogFormat {
    /// « 14:02:07 ».
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// « 4 nov. 14:02:07 » (jour abrégé à la française).
    public static func dayTime(_ date: Date, calendar: Calendar = .current) -> String {
        let months = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
        let c = calendar.dateComponents([.day, .month], from: date)
        let month = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(c.day ?? 1)\u{00A0}\(month) " + time(date, calendar: calendar)
    }

    /// « 2026-11-04 14:02:07 » (export CSV, sans ambiguïté).
    public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Écart signé lisible : « −2 min 10 s », « +45 s », « 0 s ».
    public static func offset(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "−" : (total > 0 ? "+" : "")
        let value = abs(total)
        let text: String
        if value >= 3600 {
            text = "\(value / 3600)\u{00A0}h\u{00A0}" + String(format: "%02d", value % 3600 / 60) + "\u{00A0}min"
        } else if value >= 60 {
            text = "\(value / 60)\u{00A0}min\u{00A0}" + String(format: "%02d", value % 60) + "\u{00A0}s"
        } else {
            text = "\(value)\u{00A0}s"
        }
        return sign + text
    }

    /// « 1 message », « 12 messages ».
    public static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value)\u{00A0}" + (value > 1 ? many : one)
    }
}
