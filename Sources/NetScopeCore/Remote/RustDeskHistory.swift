import Foundation

/// Note 6 : connexion RustDesk lancée depuis NetScope. RustDesk ne dit pas à NetScope quand la
/// session se termine : seule l'heure de lancement est connue (jamais de durée inventée).
public struct RustDeskLaunch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// Connexion du carnet (nil : ID collé sans l'enregistrer).
    public var connectionID: UUID?
    /// Nom du poste au moment du lancement.
    public var name: String
    /// ID RustDesk ou adresse IP directe.
    public var target: String
    public var endUser: String
    public var site: String

    public init(id: UUID = UUID(), date: Date = Date(), connectionID: UUID? = nil, name: String, target: String,
                endUser: String = "", site: String = "") {
        self.id = id
        self.date = date
        self.connectionID = connectionID
        self.name = name
        self.target = target
        self.endUser = endUser
        self.site = site
    }

    /// « 123 456 789 » ou l'adresse IP.
    public var targetLabel: String {
        RustDeskID.parse(target).map { RustDeskID.grouped($0) } ?? target
    }
}

/// Historique des lancements, le plus récent d'abord, borné.
public enum RustDeskHistory {
    public static let limit = 300

    /// Ajoute un lancement en tête et garde les `limit` plus récents.
    public static func adding(_ launch: RustDeskLaunch, to history: [RustDeskLaunch], limit: Int = limit) -> [RustDeskLaunch] {
        Array(([launch] + history).sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Lancements d'une connexion du carnet.
    public static func launches(of connectionID: UUID, in history: [RustDeskLaunch]) -> [RustDeskLaunch] {
        history.filter { $0.connectionID == connectionID }
    }
}

/// Fichier JSON de l'historique et des réglages RustDesk (Application Support/NetScope/rustdesk.json).
/// Aucun secret : les mots de passe permanents restent au Trousseau.
public struct RustDeskStore: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var settings: RustDeskServerSettings
        public var history: [RustDeskLaunch]

        public init(settings: RustDeskServerSettings = RustDeskServerSettings(), history: [RustDeskLaunch] = []) {
            self.settings = settings
            self.history = history
        }

        private enum CodingKeys: String, CodingKey { case version, settings, history }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            settings = ((try? c.decodeIfPresent(RustDeskServerSettings.self, forKey: .settings)) ?? nil) ?? RustDeskServerSettings()
            history = ((try? c.decodeIfPresent([RustDeskLaunch].self, forKey: .history)) ?? nil) ?? []
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: RustDeskStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RustDeskStore(url: base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("rustdesk.json"))
    }

    public func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Contents.self, from: data)
    }

    public func save(_ contents: Contents) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
