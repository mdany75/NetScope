import Foundation

/// Rapport de plantage de NetScope écrit par macOS (~/Library/Logs/DiagnosticReports/NetScope-….ips).
public struct CrashReport: Equatable, Sendable, Identifiable {
    public var url: URL
    /// Heure du plantage (en-tête du rapport, sinon date du fichier).
    public var date: Date
    public var appVersion: String?
    public var osVersion: String?
    /// « EXC_BAD_ACCESS (SIGSEGV) », quand le rapport le donne.
    public var exception: String?

    public var id: URL { url }
    public var fileName: String { url.lastPathComponent }

    public init(url: URL, date: Date, appVersion: String? = nil, osVersion: String? = nil, exception: String? = nil) {
        self.url = url
        self.date = date
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.exception = exception
    }
}

/// Recherche des rapports de plantage de NetScope (note 35). Lecture seule, sans réseau.
public enum CrashReports {
    /// Dossier des rapports de l'utilisateur.
    public static var standardDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    /// Fenêtre retenue par défaut : 30 jours.
    public static let defaultWindow: TimeInterval = 30 * 86_400

    /// Vrai pour un rapport de l'app NetScope (« NetScope-2026-11-04-142231.ips »), pas pour ceux
    /// des outils voisins (« NetScopeSelfTest-… »).
    public static func isNetScopeReport(_ name: String, appName: String = "NetScope") -> Bool {
        guard name.hasSuffix(".ips") else { return false }
        guard name.hasPrefix(appName) else { return false }
        let rest = name.dropFirst(appName.count)
        return rest.first.map { "-_. ".contains($0) } ?? false
    }

    /// Rapports de NetScope plus récents que `since`, du plus récent au plus ancien.
    public static func find(in directory: URL = standardDirectory, appName: String = "NetScope",
                            since: Date, now: Date = Date()) -> [CrashReport] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var reports: [CrashReport] = []
        for name in names where isNetScopeReport(name, appName: appName) {
            let url = directory.appendingPathComponent(name)
            guard let report = read(url) else { continue }
            if report.date >= since, report.date <= now.addingTimeInterval(86_400) { reports.append(report) }
        }
        return reports.sorted { $0.date > $1.date }
    }

    /// Lit l'en-tête d'un rapport (.ips : une ligne JSON, puis le corps JSON).
    public static func read(_ url: URL) -> CrashReport? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let fileDate = attributes[.modificationDate] as? Date ?? Date.distantPast
        // Seul le début compte : un rapport peut peser plusieurs centaines de Ko.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64_000)) ?? Data()
        return parse(String(decoding: head, as: UTF8.self), url: url, fileDate: fileDate)
    }

    /// Analyse le texte d'un rapport ; sans en-tête lisible, la date du fichier est retenue.
    public static func parse(_ text: String, url: URL, fileDate: Date) -> CrashReport {
        var report = CrashReport(url: url, date: fileDate)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = lines.first, let header = json(String(first)) {
            if let stamp = header["timestamp"] as? String, let date = parseTimestamp(stamp) { report.date = date }
            report.appVersion = header["app_version"] as? String
            report.osVersion = header["os_version"] as? String
        }
        if lines.count > 1 {
            let body = String(lines[1])
            if let object = json(body), let exception = object["exception"] as? [String: Any] {
                report.exception = describe(exception)
            } else if let range = body.range(of: #""exception"\s*:\s*\{[^}]*\}"#, options: .regularExpression),
                      let object = json("{" + body[range] + "}"), let exception = object["exception"] as? [String: Any] {
                // Corps tronqué (64 Ko lus) : on retrouve au moins le bloc de l'exception.
                report.exception = describe(exception)
            }
        }
        return report
    }

    private static func describe(_ exception: [String: Any]) -> String? {
        guard let type = exception["type"] as? String else { return nil }
        if let signal = exception["signal"] as? String, !signal.isEmpty { return "\(type) (\(signal))" }
        return type
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// « 2026-11-04 14:22:31.00 -0500 » (format des rapports .ips).
    public static func parseTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSS Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
