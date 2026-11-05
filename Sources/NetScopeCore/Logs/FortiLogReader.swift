import Foundation

// Note 43 : journaux d'événements de la FortiGate par l'API REST (GET seulement, même transport et
// même jeton que les autres lectures). Adresses : /api/v2/log/<emplacement>/event/<sous-type>, avec
// l'emplacement « memory » (journal en mémoire, toutes les FortiGate) ou « disk » (modèles avec
// disque, journalisation sur disque activée). Filtre de temps de FortiOS : paramètre « filter »
// sur `_metadata.timestamp` en millisecondes depuis 1970, répété pour une plage (« >= » et « < »),
// d'après l'article Fortinet « Technical Tip: Retrieve event logs using an API GET request with a
// time filter ». La gravité est filtrée ici, après la lecture (le champ « level » n'a pas de filtre
// documenté). Profil de l'administrateur API : droit « Log & Report » en lecture.

/// Emplacement des journaux lus.
public enum FortiLogStorage: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Mémoire d'abord, puis disque si la mémoire n'a rien (ou n'existe pas).
    case auto
    case memory
    case disk

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Automatique (mémoire, puis disque)"
        case .memory: return "Mémoire"
        case .disk: return "Disque"
        }
    }

    var order: [String] {
        switch self {
        case .auto: return ["memory", "disk"]
        case .memory: return ["memory"]
        case .disk: return ["disk"]
        }
    }
}

/// Adresses lues (toutes en GET).
public enum FortiLogPaths {
    /// Sous-types d'événements lus par défaut : système, VPN, authentification des utilisateurs, Wi-Fi.
    public static let defaultSubtypes = ["system", "vpn", "user", "wireless"]

    public static func path(storage: String, subtype: String) -> String {
        "/api/v2/log/\(storage)/event/\(subtype)"
    }

    /// Toutes les adresses possibles (tests : rien d'autre n'est demandé).
    public static let all: [String] = ["memory", "disk"].flatMap { storage in
        (defaultSubtypes + ["router", "switch-controller"]).map { path(storage: storage, subtype: $0) }
    }
}

/// Options de lecture.
public struct FortiLogReadOptions: Sendable, Equatable {
    public var since: Date
    public var until: Date?
    /// Gravité minimale gardée (filtrée après la lecture).
    public var minimumSeverity: LogSeverity
    public var storage: FortiLogStorage
    public var subtypes: [String]
    /// Lignes demandées par sous-type (FortiOS en renvoie au plus quelques centaines par appel).
    public var rows: Int

    public init(since: Date, until: Date? = nil, minimumSeverity: LogSeverity = .info, storage: FortiLogStorage = .auto,
                subtypes: [String] = FortiLogPaths.defaultSubtypes, rows: Int = 500) {
        self.since = since
        self.until = until
        self.minimumSeverity = minimumSeverity
        self.storage = storage
        self.subtypes = subtypes
        self.rows = max(1, min(rows, 2000))
    }

    /// Paramètres de la requête : lignes, puis filtre de temps (millisecondes).
    public var query: [URLQueryItem] {
        var items = [URLQueryItem(name: "rows", value: String(rows)), URLQueryItem(name: "start", value: "0")]
        items.append(URLQueryItem(name: "filter", value: "_metadata.timestamp>=\(Self.milliseconds(since))"))
        if let until { items.append(URLQueryItem(name: "filter", value: "_metadata.timestamp<\(Self.milliseconds(until))")) }
        return items
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// Résultat d'une lecture.
public struct FortiLogReadReport: Sendable {
    public var messages: [LogMessage]
    /// Emplacement qui a répondu (« memory », « disk »).
    public var storage: String?
    public var notes: [String]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(messages: [LogMessage] = [], storage: String? = nil, notes: [String] = [], calls: [FortiCallRecord] = [], readAt: Date) {
        self.messages = messages
        self.storage = storage
        self.notes = notes
        self.calls = calls
        self.readAt = readAt
    }
}

extension FortiGateReader {
    /// Lit les journaux d'événements. Un sous-type absent (404) ou refusé (403) est noté ; si tous
    /// sont refusés, l'erreur est levée (avec les appels faits, `FortiReadFailure`).
    public func readLogsKeepingCalls(_ options: FortiLogReadOptions, host: String, now: Date = Date()) async throws -> FortiLogReadReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readLogsAll(options, host: host, now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readLogsAll(_ options: FortiLogReadOptions, host: String, now: Date, calls: inout [FortiCallRecord]) async throws -> FortiLogReadReport {
        var report = FortiLogReadReport(readAt: now)
        var refused: FortiGateError?
        var answered = false
        for storage in options.storage.order {
            var found: [LogMessage] = []
            var storageAnswered = false
            for subtype in options.subtypes {
                let fetched = try await fetch(FortiLogPaths.path(storage: storage, subtype: subtype), query: options.query)
                calls.append(fetched.record)
                if let error = fetched.error {
                    if case .forbidden = error { refused = error }
                    continue
                }
                storageAnswered = true
                guard let body = fetched.response?.body else { continue }
                found += FortiLogParser.messages(body, host: host, subtype: subtype)
            }
            answered = answered || storageAnswered
            if !found.isEmpty || (storageAnswered && options.storage != .auto) {
                report.storage = storage
                report.messages = found
                break
            }
            if storageAnswered { report.storage = storage }
        }
        if !answered, let refused { throw refused }
        if !answered {
            report.notes.append("Aucun journal d’événements lisible sur cette FortiGate (adresses /api/v2/log/…/event absentes de cette version de FortiOS).")
        }
        let until = options.until ?? .distantFuture
        report.messages = report.messages
            .filter { $0.severity.isAtLeast(options.minimumSeverity) && $0.date >= options.since.addingTimeInterval(-1) && $0.date < until }
            .sorted { $0.date < $1.date }
        report.calls = calls
        return report
    }
}

/// Lecture tolérante des réponses de /api/v2/log/…/event/… (fonctions pures).
public enum FortiLogParser {
    /// Messages d'une réponse (`results` : tableau d'objets journaux).
    public static func messages(_ data: Data, host: String, subtype: String, calendar: Calendar = .current) -> [LogMessage] {
        let rows = FortiJSON.objects(FortiJSON.results(FortiJSON.parse(data)))
        return rows.compactMap { message($0, host: host, subtype: subtype, calendar: calendar) }
    }

    static func message(_ row: FortiObject, host: String, subtype: String, calendar: Calendar) -> LogMessage? {
        var fields: [String: String] = [:]
        for (key, value) in row.raw {
            if let text = FortiJSON.string(value) { fields[key] = text }
        }
        if let metadata = row.object("_metadata"), let stamp = metadata.double("timestamp") {
            fields["_metadata.timestamp"] = String(Int64(stamp))
        }
        let text = [fields["msg"], fields["logdesc"], fields["action"]].compactMap { $0 }.first { !$0.isEmpty }
        guard let text else { return nil }
        var detail = text
        if let desc = fields["logdesc"], !desc.isEmpty, let msg = fields["msg"], !msg.isEmpty, !msg.localizedCaseInsensitiveContains(desc) {
            detail = desc + "\u{00A0}: " + msg
        }
        var date = SyslogParser.fortinetDate(fields, calendar: calendar)
        if date == nil, let stamp = fields["_metadata.timestamp"].flatMap(Double.init) {
            var seconds = stamp
            while seconds > 1e11 { seconds /= 1000 }
            date = Date(timeIntervalSince1970: seconds)
        }
        guard let date else { return nil }
        let severity = fields["level"].flatMap(LogSeverity.init(text:)) ?? .info
        let kind = fields["subtype"] ?? subtype
        let raw = fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            return value.contains(" ") ? "\(key)=\"\(value)\"" : "\(key)=\(value)"
        }.joined(separator: " ")
        return LogMessage(date: date, received: nil, source: .fortigate, severity: severity, host: host,
                          hostname: fields["devname"], app: "FortiOS · " + kind, eventID: fields["logid"],
                          message: LogMessage.clip(detail, LogMessage.messageLimit), fields: fields,
                          raw: LogMessage.clip(raw, LogMessage.rawLimit))
    }
}

extension FortiGateError {
    /// Message propre aux journaux (droit « Log & Report »).
    public var logDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) aux journaux\u{00A0}: ajoutez le droit «\u{00A0}Log & Report\u{00A0}» en lecture au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
