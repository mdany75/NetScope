import Foundation

// Historique des tests de vitesse des disques, par emplacement :
// ~/Library/Application Support/NetScope/disques.json ; export CSV.

/// Un test terminé.
public struct DiskTestRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    /// Chemin de l'emplacement (clé du regroupement par emplacement).
    public var locationID: String
    public var locationName: String
    public var kind: DiskLocationKind
    /// « APFS », « SMB · nas.bureau.local/Projets », « OneDrive ».
    public var detail: String
    public var sizeBytes: Int64
    public var passes: Int
    public var writeMBps: Double?
    public var readMBps: Double?
    public var randomReadIOPS: Double?
    public var randomWriteIOPS: Double?
    public var randomReadMeanMs: Double?
    public var randomReadP95Ms: Double?
    public var cloudStatus: DiskCloudStatus?
    public var uploadSeconds: Double?
    public var uploadMbps: Double?
    public var network: DiskNetworkContext?
    public var limit: DiskLimit
    public var verdict: String

    public init(id: UUID = UUID(), date: Date = Date(), location: DiskLocation, result: DiskBenchmarkResult,
                network: DiskNetworkContext? = nil, verdict: DiskVerdict) {
        self.id = id
        self.date = date
        locationID = location.id
        locationName = location.name
        kind = location.kind
        detail = location.kind == .reseau || location.kind == .nuage
            ? location.detail.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
            : location.fileSystem
        sizeBytes = result.sizeBytes
        passes = result.passes
        writeMBps = result.writeMBps
        readMBps = result.readMBps
        randomReadIOPS = result.randomRead?.iops
        randomWriteIOPS = result.randomWrite?.iops
        randomReadMeanMs = result.randomRead?.meanMs
        randomReadP95Ms = result.randomRead?.p95Ms
        cloudStatus = result.cloudStatus
        uploadSeconds = result.uploadSeconds
        uploadMbps = result.uploadMbps
        self.network = network
        limit = verdict.limit
        self.verdict = verdict.title
    }
}

public struct DiskHistoryStore: Sendable {
    public let url: URL
    public static let maxRecords = 300

    public init(url: URL) { self.url = url }

    /// ~/Library/Application Support/NetScope
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NetScope", isDirectory: true)
    }

    public static var standard: DiskHistoryStore {
        DiskHistoryStore(url: supportDirectory.appendingPathComponent("disques.json"))
    }

    public struct Content: Codable, Sendable {
        public var records: [DiskTestRecord]
        /// Dernier emplacement mesuré.
        public var lastLocation: String?
        public var config: DiskBenchmarkConfig?

        public init(records: [DiskTestRecord] = [], lastLocation: String? = nil, config: DiskBenchmarkConfig? = nil) {
            self.records = records
            self.lastLocation = lastLocation
            self.config = config
        }
    }

    public func load() -> Content {
        guard let data = try? Data(contentsOf: url) else { return Content() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Content.self, from: data)) ?? Content()
    }

    public func save(_ content: Content) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var content = content
        content.records = Self.pruned(content.records)
        try encoder.encode(content).write(to: url, options: .atomic)
    }

    /// Plus récents d'abord, au plus `maxRecords`.
    public static func pruned(_ records: [DiskTestRecord]) -> [DiskTestRecord] {
        Array(records.sorted { $0.date > $1.date }.prefix(maxRecords))
    }

    /// Tests d'un emplacement, plus récents d'abord.
    public static func records(_ records: [DiskTestRecord], for locationID: String) -> [DiskTestRecord] {
        records.filter { $0.locationID == locationID }.sorted { $0.date > $1.date }
    }

    /// Dernier test de chaque emplacement (pour un rapport), plus récents d'abord.
    public static func latestPerLocation(_ records: [DiskTestRecord], limit: Int = 8) -> [DiskTestRecord] {
        var seen: Set<String> = []
        return records.sorted { $0.date > $1.date }.filter { seen.insert($0.locationID).inserted }.prefix(limit).map { $0 }
    }

    /// CSV séparé par des points-virgules (Excel en français), nombres à virgule décimale.
    public static func csv(_ records: [DiskTestRecord]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func number(_ value: Double?, _ digits: Int = 1) -> String {
            value.map { DiskFormat.number($0, digits: digits) } ?? ""
        }
        func field(_ text: String) -> String {
            guard text.contains(";") || text.contains("\"") || text.contains("\n") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["Date;Emplacement;Type;Détail;Chemin;Taille (Mio);Passes;Écriture (Mo/s);Lecture (Mo/s);IOPS 4K lecture;IOPS 4K écriture;Latence 4K moy. (ms);Latence 4K p95 (ms);Lien (Mbit/s);Latence serveur (ms);Envoi nuage;Envoi (s);Envoi (Mbit/s);Limite;Bilan"]
        for r in records {
            lines.append([
                formatter.string(from: r.date), field(r.locationName), r.kind.label, field(r.detail), field(r.locationID),
                String(r.sizeBytes >> 20), String(r.passes), number(r.writeMBps), number(r.readMBps),
                number(r.randomReadIOPS, 0), number(r.randomWriteIOPS, 0), number(r.randomReadMeanMs, 3), number(r.randomReadP95Ms, 3),
                number(r.network?.linkMbps, 0), number(r.network?.serverLatencyMs, 1), r.cloudStatus?.label ?? "",
                number(r.uploadSeconds, 0), number(r.uploadMbps, 1), r.limit.label, field(r.verdict),
            ].joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
