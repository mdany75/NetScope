import Foundation

/// Type de test de débit.
public enum SpeedTestKind: String, Codable, CaseIterable, Sendable {
    case internet, lan

    public var label: String {
        switch self {
        case .internet: return "Internet"
        case .lan: return "iperf3"
        }
    }
}

/// Un test enregistré dans l'historique.
public struct SpeedTestRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: SpeedTestKind
    /// « manuel » ou « planifié ».
    public var origin: String
    /// Serveur : « Cloudflare · YUL Montréal », « NAS 10.10.0.20 ».
    public var server: String
    /// Interface BSD (« en0 ») et son type (« Wi-Fi »).
    public var interfaceName: String
    public var interfaceKind: String
    public var downMbps: Double
    public var upMbps: Double?
    public var latencyMs: Double?
    public var loadedLatencyMs: Double?
    public var jitterMs: Double?
    public var streams: Int
    /// Source du serveur (test Internet) ; nil pour les anciens tests (Cloudflare) et iperf3.
    public var serverSource: SpeedServerSource?
    /// Identifiant du serveur (`SpeedServer.id`), pour comparer par serveur.
    public var serverID: String?
    /// Note 78 : site actif au moment du test (courbe par site du débit planifié) ; nil pour
    /// les anciens tests et sans site.
    public var siteID: UUID?
    public var siteName: String?

    /// Origine d'un test lancé par la planification (Speedtest › Planifié).
    public static let plannedOrigin = "planifié"
    public var isPlanned: Bool { origin == SpeedTestRecord.plannedOrigin }

    public init(id: UUID = UUID(), date: Date = Date(), kind: SpeedTestKind, origin: String = "manuel",
                server: String, interfaceName: String, interfaceKind: String, downMbps: Double,
                upMbps: Double? = nil, latencyMs: Double? = nil, loadedLatencyMs: Double? = nil,
                jitterMs: Double? = nil, streams: Int = 1, serverSource: SpeedServerSource? = nil,
                serverID: String? = nil, siteID: UUID? = nil, siteName: String? = nil) {
        self.siteID = siteID
        self.siteName = siteName
        self.serverSource = serverSource
        self.serverID = serverID
        self.id = id
        self.date = date
        self.kind = kind
        self.origin = origin
        self.server = server
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.latencyMs = latencyMs
        self.loadedLatencyMs = loadedLatencyMs
        self.jitterMs = jitterMs
        self.streams = streams
    }

    /// « en0 · Wi-Fi »
    public var interfaceLabel: String {
        interfaceKind.isEmpty ? interfaceName : "\(interfaceName) · \(interfaceKind)"
    }

    /// Source affichée : celle enregistrée, sinon Cloudflare pour un ancien test Internet, iperf3 en local.
    public var sourceLabel: String {
        if let serverSource { return serverSource.label }
        return kind == .lan ? "iperf3" : "Cloudflare"
    }

    /// Clé de regroupement par serveur : l'identifiant s'il existe, sinon le libellé.
    public var serverKey: String { serverID ?? "\(kind.rawValue):\(server)" }
}

/// Moyennes des tests d'un même serveur (comparaison par serveur).
public struct SpeedServerStats: Identifiable, Hashable, Sendable {
    public var id: String
    public var server: String
    public var source: String
    public var kind: SpeedTestKind
    public var count: Int
    public var averageDown: Double
    public var averageUp: Double?
    public var averageLatency: Double?
    public var bestDown: Double
    public var lastDate: Date

    /// Regroupe par serveur ; tri par nombre de tests puis par date du dernier test.
    public static func compute(_ records: [SpeedTestRecord], kind: SpeedTestKind? = .internet) -> [SpeedServerStats] {
        let filtered = records.filter { kind == nil || $0.kind == kind }
        let groups = Dictionary(grouping: filtered, by: \.serverKey)
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return groups.compactMap { key, items -> SpeedServerStats? in
            guard let latest = items.max(by: { $0.date < $1.date }) else { return nil }
            return SpeedServerStats(id: key, server: latest.server, source: latest.sourceLabel, kind: latest.kind,
                                    count: items.count, averageDown: mean(items.map(\.downMbps)) ?? 0,
                                    averageUp: mean(items.compactMap(\.upMbps)), averageLatency: mean(items.compactMap(\.latencyMs)),
                                    bestDown: items.map(\.downMbps).max() ?? 0, lastDate: latest.date)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastDate > $1.lastDate }
    }
}

/// Historique des tests, en JSON dans ~/Library/Application Support/NetScope/speedtest.json.
/// Les résultats sont conservés 90 jours.
public struct SpeedHistoryStore: Sendable {
    public static let retentionDays = 90

    private struct File: Codable {
        var version = 1
        var records: [SpeedTestRecord]
        var planDownMbps: Double?
        var planUpMbps: Double?
    }

    public struct Content: Equatable, Sendable {
        public var records: [SpeedTestRecord]
        public var planDownMbps: Double?
        public var planUpMbps: Double?

        public init(records: [SpeedTestRecord] = [], planDownMbps: Double? = nil, planUpMbps: Double? = nil) {
            self.records = records
            self.planDownMbps = planDownMbps
            self.planUpMbps = planUpMbps
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: SpeedHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SpeedHistoryStore(url: base.appendingPathComponent("NetScope", isDirectory: true)
            .appendingPathComponent("speedtest.json"))
    }

    public func load(now: Date = Date()) -> Content {
        guard let data = try? Data(contentsOf: url),
              let file = try? SpeedHistoryStore.decoder.decode(File.self, from: data) else { return Content() }
        return Content(records: SpeedHistoryStore.pruned(file.records, now: now),
                       planDownMbps: file.planDownMbps, planUpMbps: file.planUpMbps)
    }

    public func save(_ content: Content) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = File(records: content.records, planDownMbps: content.planDownMbps, planUpMbps: content.planUpMbps)
        try SpeedHistoryStore.encoder.encode(file).write(to: url, options: .atomic)
    }

    /// Plus récents d'abord, sans les tests de plus de 90 jours.
    public static func pruned(_ records: [SpeedTestRecord], now: Date = Date()) -> [SpeedTestRecord] {
        let limit = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return records.filter { $0.date >= limit }.sorted { $0.date > $1.date }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Export CSV

    /// Export CSV (séparateur « ; », décimales à la virgule, comme Excel en français).
    public static func csv(_ records: [SpeedTestRecord]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func number(_ value: Double?, _ digits: Int = 1) -> String {
            guard let value else { return "" }
            return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
        }
        func field(_ text: String) -> String {
            guard text.contains(";") || text.contains("\"") || text.contains("\n") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["Date;Type;Origine;Serveur;Interface;Descente (Mb/s);Montée (Mb/s);Latence (ms);Latence en charge (ms);Gigue (ms);Flux;Source;Site"]
        for record in records {
            lines.append([
                formatter.string(from: record.date), record.kind.label, field(record.origin), field(record.server),
                field(record.interfaceLabel), number(record.downMbps), number(record.upMbps),
                number(record.latencyMs), number(record.loadedLatencyMs), number(record.jitterMs), String(record.streams),
                field(record.sourceLabel), field(record.siteName ?? ""),
            ].joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
