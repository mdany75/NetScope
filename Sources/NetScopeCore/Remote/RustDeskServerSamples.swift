import Foundation

// Note 6 (suite, 0.26.2) : réglages du tableau de bord du serveur RustDesk et échantillons pris
// par NetScope pendant que le tableau de bord est ouvert (sessions relayées, débit), gardés
// quelques jours dans Application Support/NetScope/rustdesk-serveur.json. Aucun secret.

/// Réglages du tableau de bord.
public struct RustDeskDashboardSettings: Codable, Equatable, Sendable {
    /// Connexion SSH du carnet (Accès distant) ; prioritaire sur le compte saisi.
    public var connectionID: UUID?
    /// Compte saisi : « utilisateur@hôte[:port] ».
    public var manualAccount: String
    /// Rafraîchissement, en secondes, seulement pendant que le tableau de bord est affiché.
    public var refreshSeconds: Int

    public static let defaultRefresh = 30
    public static let refreshChoices = [15, 30, 60, 120, 300]

    public init(connectionID: UUID? = nil, manualAccount: String = "", refreshSeconds: Int = defaultRefresh) {
        self.connectionID = connectionID
        self.manualAccount = manualAccount
        self.refreshSeconds = refreshSeconds
    }

    private enum CodingKeys: String, CodingKey { case connectionID, manualAccount, refreshSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = (try? c.decodeIfPresent(UUID.self, forKey: .connectionID)) ?? nil
        manualAccount = ((try? c.decodeIfPresent(String.self, forKey: .manualAccount)) ?? nil) ?? ""
        refreshSeconds = Self.clampRefresh(((try? c.decodeIfPresent(Int.self, forKey: .refreshSeconds)) ?? nil) ?? Self.defaultRefresh)
    }

    /// 10 s à 1 h.
    public static func clampRefresh(_ value: Int) -> Int { min(max(value, 10), 3_600) }

    /// Un compte est choisi (carnet ou saisi).
    public var hasAccount: Bool {
        connectionID != nil || !manualAccount.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Compte lu, pour rattacher les échantillons : « carnet:<UUID> » ou « saisi:<utilisateur@hôte> »
    /// (nil sans compte).
    public var accountKey: String? {
        if let connectionID { return "carnet:" + connectionID.uuidString }
        let text = manualAccount.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : "saisi:" + text.lowercased()
    }

    /// « 30 s », « 2 min ».
    public static func refreshLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)\u{00A0}s" : "\(seconds / 60)\u{00A0}min"
    }
}

/// Échantillon : sessions relayées et débit relayé au moment d'une lecture.
public struct RustDeskServerSample: Codable, Equatable, Sendable {
    public var date: Date
    public var sessions: Int
    public var kbps: Int

    public init(date: Date, sessions: Int, kbps: Int) {
        self.date = date
        self.sessions = sessions
        self.kbps = kbps
    }
}

public enum RustDeskServerSamples {
    /// Gardés trois jours, 6 000 au plus.
    public static let retention: TimeInterval = 3 * 86_400
    public static let limit = 6_000

    /// Ajoute l'échantillon, retire les trop vieux (et ceux venus du futur), garde l'ordre chronologique.
    public static func adding(_ sample: RustDeskServerSample, to samples: [RustDeskServerSample], now: Date) -> [RustDeskServerSample] {
        let kept = (samples + [sample])
            .filter { $0.date >= now.addingTimeInterval(-retention) && $0.date <= now.addingTimeInterval(300) }
            .sorted { $0.date < $1.date }
        return Array(kept.suffix(limit))
    }

    /// Échantillons des `hours` dernières heures.
    public static func window(_ samples: [RustDeskServerSample], hours: Double, now: Date) -> [RustDeskServerSample] {
        let since = now.addingTimeInterval(-hours * 3_600)
        return samples.filter { $0.date >= since && $0.date <= now.addingTimeInterval(300) }
    }

    /// Échantillon d'un état lu.
    public static func sample(from status: RustDeskServerStatus) -> RustDeskServerSample? {
        guard status.relayConsole == .ok else { return nil }
        return RustDeskServerSample(date: status.readAt, sessions: status.relaySessions.count, kbps: status.currentRelayKbps)
    }
}

/// Fichier du tableau de bord (réglages et échantillons).
public struct RustDeskDashboardStore: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var settings: RustDeskDashboardSettings
        public var samples: [RustDeskServerSample]
        /// Compte des échantillons (`RustDeskDashboardSettings.accountKey`) : ceux d'un autre serveur
        /// sont écartés au chargement.
        public var samplesAccount: String?

        public init(settings: RustDeskDashboardSettings = RustDeskDashboardSettings(), samples: [RustDeskServerSample] = [],
                    samplesAccount: String? = nil) {
            self.settings = settings
            self.samples = samples
            self.samplesAccount = samplesAccount ?? settings.accountKey
        }

        /// Échantillons du compte réglé seulement (fichier ancien sans compte : écartés aussi).
        public var currentSamples: [RustDeskServerSample] {
            samplesAccount != nil && samplesAccount == settings.accountKey ? samples : []
        }

        private enum CodingKeys: String, CodingKey { case version, settings, samples, samplesAccount }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            settings = ((try? c.decodeIfPresent(RustDeskDashboardSettings.self, forKey: .settings)) ?? nil) ?? RustDeskDashboardSettings()
            samples = ((try? c.decodeIfPresent([RustDeskServerSample].self, forKey: .samples)) ?? nil) ?? []
            samplesAccount = (try? c.decodeIfPresent(String.self, forKey: .samplesAccount)) ?? nil
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: RustDeskDashboardStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RustDeskDashboardStore(url: base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("rustdesk-serveur.json"))
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
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
