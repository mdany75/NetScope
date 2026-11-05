import Foundation

// Serveurs de test Internet (note 16) : Cloudflare, M-Lab (NDT7), LibreSpeed, Ookla (CLI
// officiel, s'il est installé) et serveurs personnalisés (compatibles LibreSpeed).

/// Origine d'un serveur de test.
public enum SpeedServerSource: String, Codable, CaseIterable, Sendable {
    case cloudflare, mlab, librespeed, ookla, custom

    public var label: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .mlab: return "M-Lab"
        case .librespeed: return "LibreSpeed"
        case .ookla: return "Ookla"
        case .custom: return "Personnalisé"
        }
    }

    /// Méthode de mesure.
    public var protocolLabel: String {
        switch self {
        case .cloudflare: return "HTTP multi-flux"
        case .mlab: return "NDT7 (WebSocket, 1 flux)"
        case .librespeed, .custom: return "HTTP multi-flux (LibreSpeed)"
        case .ookla: return "CLI officiel d’Ookla"
        }
    }

    /// Vrai si le nombre de flux parallèles se règle.
    public var supportsStreams: Bool {
        switch self {
        case .cloudflare, .librespeed, .custom: return true
        case .mlab, .ookla: return false
        }
    }
}

/// Un serveur de test.
public struct SpeedServer: Identifiable, Codable, Hashable, Sendable {
    /// Identifiant stable : « cloudflare », « mlab:yul04 », « librespeed:52 », « ookla:12345 »,
    /// « ookla:auto », « custom:https://vitesse.exemple.ca/ ».
    public var id: String
    public var source: SpeedServerSource
    /// Nom tel que donné par la source (« Montréal, Canada (Fibre Laurentides) »).
    public var name: String
    public var city: String?
    public var country: String?
    /// Opérateur ou hébergeur.
    public var sponsor: String?
    /// Hôte et port joints pour mesurer la latence (connexion TCP).
    public var host: String?
    public var port: Int?
    /// LibreSpeed et personnalisé : URL de base et chemins des points d'accès.
    public var baseURL: String?
    public var downloadPath: String?
    public var uploadPath: String?
    public var pingPath: String?
    public var ipPath: String?
    /// M-Lab : site (« yul04 »).
    public var site: String?
    /// Ookla : identifiant numérique du serveur (nil : choisi par Ookla).
    public var ooklaID: Int?
    /// Latence mesurée (ms), connexion TCP ; non enregistrée avec les favoris.
    public var latencyMs: Double?

    public init(id: String, source: SpeedServerSource, name: String, city: String? = nil, country: String? = nil,
                sponsor: String? = nil, host: String? = nil, port: Int? = nil, baseURL: String? = nil,
                downloadPath: String? = nil, uploadPath: String? = nil, pingPath: String? = nil,
                ipPath: String? = nil, site: String? = nil, ooklaID: Int? = nil, latencyMs: Double? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.city = city
        self.country = country
        self.sponsor = sponsor
        self.host = host
        self.port = port
        self.baseURL = baseURL
        self.downloadPath = downloadPath
        self.uploadPath = uploadPath
        self.pingPath = pingPath
        self.ipPath = ipPath
        self.site = site
        self.ooklaID = ooklaID
        self.latencyMs = latencyMs
    }

    /// Nœud anycast de Cloudflare : le plus proche est choisi par le réseau de Cloudflare.
    public static let cloudflare = SpeedServer(id: "cloudflare", source: .cloudflare, name: "Cloudflare (anycast)",
                                               sponsor: "Cloudflare", host: "speed.cloudflare.com", port: 443)

    /// Ookla, serveur choisi par le CLI lui-même.
    public static let ooklaAuto = SpeedServer(id: "ookla:auto", source: .ookla, name: "Serveur choisi par Ookla",
                                              sponsor: "Speedtest.net")

    /// « Montréal » (ville, sinon nom).
    public var place: String {
        if let city, !city.isEmpty { return city }
        return name
    }

    /// Titre d'une ligne de la liste : « Montréal · yul04 », « Montréal, Canada (Fibre Laurentides) ».
    public var title: String {
        switch source {
        case .mlab: return site.map { "\(place) · \($0)" } ?? place
        case .cloudflare: return "Nœud Cloudflare le plus proche"
        default: return name
        }
    }

    /// Libellé retenu dans l'historique : « M-Lab · Montréal (yul04) », « LibreSpeed · Québec · Fibre Laurentides ».
    public var historyLabel: String {
        switch source {
        case .cloudflare: return "Cloudflare"
        case .mlab: return "M-Lab · " + place + (site.map { " (\($0))" } ?? "")
        case .ookla:
            if ooklaID == nil { return "Ookla" }
            return (["Ookla", sponsor, city].compactMap { $0 }).joined(separator: " · ")
        case .librespeed, .custom:
            var parts = [source.label, place]
            if let sponsor, !sponsor.isEmpty, sponsor != place { parts.append(sponsor) }
            return parts.joined(separator: " · ")
        }
    }

    /// Copie sans les valeurs passagères (latence), pour l'enregistrement des favoris.
    public var stored: SpeedServer {
        var copy = self
        copy.latencyMs = nil
        return copy
    }
}

// MARK: - Serveur personnalisé

/// Erreurs de saisie d'un serveur personnalisé.
public enum SpeedServerError: Error, Equatable, LocalizedError {
    case emptyAddress
    case invalidAddress(String)
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAddress: return "Indiquez l’adresse du serveur (ex. https://vitesse.exemple.ca/)."
        case .invalidAddress(let text): return "Adresse de serveur invalide : « \(text) »."
        case .unsupportedScheme(let scheme): return "Protocole « \(scheme) » non pris en charge : utilisez https:// ou http://."
        }
    }
}

extension SpeedServer {
    /// Serveur personnalisé compatible LibreSpeed : « vitesse.exemple.ca », « https://hôte/backend ».
    /// Les points d'accès sont ceux de LibreSpeed (garbage.php, empty.php, getIP.php).
    public static func custom(address text: String, label: String? = nil) throws -> SpeedServer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeedServerError.emptyAddress }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme), let scheme = components.scheme?.lowercased() else {
            throw SpeedServerError.invalidAddress(trimmed)
        }
        guard scheme == "https" || scheme == "http" else { throw SpeedServerError.unsupportedScheme(scheme) }
        guard let host = components.host, (try? RemoteValidator.validateHost(host)) != nil,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw SpeedServerError.invalidAddress(trimmed)
        }
        components.scheme = scheme
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw SpeedServerError.invalidAddress(trimmed) }
        let base = url.absoluteString
        let name = label?.trimmingCharacters(in: .whitespaces).isEmpty == false ? label! : host
        return SpeedServer(id: "custom:" + base, source: .custom, name: name, host: host,
                           port: components.port ?? (scheme == "https" ? 443 : 80), baseURL: base,
                           downloadPath: LibreSpeedEndpoints.defaultDownload, uploadPath: LibreSpeedEndpoints.defaultUpload,
                           pingPath: LibreSpeedEndpoints.defaultPing, ipPath: LibreSpeedEndpoints.defaultIP)
    }
}

// MARK: - Choix automatique et classement

public enum SpeedServerPicker {
    /// Serveur automatique : la plus faible latence mesurée parmi les serveurs ouverts (Cloudflare,
    /// M-Lab, LibreSpeed) ; Ookla et les serveurs personnalisés ne sont pris que sur choix explicite.
    /// Sans aucune mesure : Cloudflare (anycast, déjà le nœud le plus proche).
    public static func automatic(_ servers: [SpeedServer]) -> SpeedServer {
        let open = servers.filter { [.cloudflare, .mlab, .librespeed].contains($0.source) }
        let measured = open.compactMap { server in server.latencyMs.map { (server, $0) } }
        if let best = measured.min(by: { $0.1 != $1.1 ? $0.1 < $1.1 : rank($0.0.source) < rank($1.0.source) }) {
            return best.0
        }
        return open.first { $0.source == .cloudflare } ?? .cloudflare
    }

    /// Tri de la liste : favoris d'abord, puis latence croissante (sans mesure à la fin), puis nom.
    public static func sorted(_ servers: [SpeedServer], favorites: Set<String> = []) -> [SpeedServer] {
        servers.sorted { lhs, rhs in
            let lf = favorites.contains(lhs.id), rf = favorites.contains(rhs.id)
            if lf != rf { return lf }
            switch (lhs.latencyMs, rhs.latencyMs) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if lhs.source != rhs.source { return rank(lhs.source) < rank(rhs.source) }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Ordre des sources à latence égale.
    static func rank(_ source: SpeedServerSource) -> Int {
        SpeedServerSource.allCases.firstIndex(of: source) ?? 99
    }

    /// Recherche multiple (sans accents ni casse) dans le nom, la ville, le pays, l'opérateur et la
    /// source (`ville:Montréal source:Ookla`).
    public static func matches(_ server: SpeedServer, query: String) -> Bool {
        server.matchesSearch(query)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
    }
}

// MARK: - Favoris et choix enregistrés

/// Choix du serveur, favoris et serveurs personnalisés, en JSON dans
/// ~/Library/Application Support/NetScope/speedtest-serveurs.json.
public struct SpeedServerPrefs: Codable, Equatable, Sendable {
    public var version = 1
    /// « auto » ou l'identifiant d'un serveur.
    public var selectedID: String
    /// Serveur choisi (pour le retrouver sans recharger la liste).
    public var selected: SpeedServer?
    public var favorites: [SpeedServer]
    public var custom: [SpeedServer]
    /// Note 79 : moteur Ookla (CLI Homebrew) proposé. Masqué par défaut (licence d'Ookla limitée à un
    /// usage personnel non commercial) ; réactivable dans Speedtest › Serveurs › Sources.
    public var ooklaEnabled: Bool

    public static let automaticID = "auto"

    public init(selectedID: String = SpeedServerPrefs.automaticID, selected: SpeedServer? = nil,
                favorites: [SpeedServer] = [], custom: [SpeedServer] = [], ooklaEnabled: Bool = false) {
        self.selectedID = selectedID
        self.selected = selected
        self.favorites = favorites
        self.custom = custom
        self.ooklaEnabled = ooklaEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case version, selectedID, selected, favorites, custom, ooklaEnabled
    }

    /// Fichier d'avant la 0.25.0 (sans « ooklaEnabled ») : Ookla reste proposé seulement si
    /// l'utilisateur l'avait déjà choisi ou mis en favori ; sinon il est masqué, comme au premier lancement.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selectedID = try container.decodeIfPresent(String.self, forKey: .selectedID) ?? SpeedServerPrefs.automaticID
        selected = try container.decodeIfPresent(SpeedServer.self, forKey: .selected)
        favorites = try container.decodeIfPresent([SpeedServer].self, forKey: .favorites) ?? []
        custom = try container.decodeIfPresent([SpeedServer].self, forKey: .custom) ?? []
        if let enabled = try container.decodeIfPresent(Bool.self, forKey: .ooklaEnabled) {
            ooklaEnabled = enabled
        } else {
            ooklaEnabled = selected?.source == .ookla || favorites.contains { $0.source == .ookla }
        }
    }

    /// Serveurs proposés : ceux d'Ookla seulement si le moteur est activé.
    public func allowed(_ servers: [SpeedServer]) -> [SpeedServer] {
        ooklaEnabled ? servers : servers.filter { $0.source != .ookla }
    }

    /// Le serveur peut servir au prochain test (un serveur Ookla, seulement moteur activé).
    public func allows(_ server: SpeedServer) -> Bool { ooklaEnabled || server.source != .ookla }

    /// Active ou masque le moteur Ookla ; masqué, un serveur Ookla choisi repasse en automatique
    /// (les favoris restent, cachés, pour le jour où on le réactive).
    public mutating func setOoklaEnabled(_ enabled: Bool) {
        ooklaEnabled = enabled
        if !enabled, selected?.source == .ookla || selectedID.hasPrefix("ookla") {
            selectedID = SpeedServerPrefs.automaticID
            selected = nil
        }
    }

    public var favoriteIDs: Set<String> { Set(favorites.map(\.id)) }

    /// Ajoute ou retire un favori.
    public mutating func toggleFavorite(_ server: SpeedServer) {
        if let index = favorites.firstIndex(where: { $0.id == server.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(server.stored)
        }
    }

    /// Ajoute un serveur personnalisé (sans doublon) et le met en favori.
    public mutating func addCustom(_ server: SpeedServer) {
        custom.removeAll { $0.id == server.id }
        custom.append(server.stored)
        if !favoriteIDs.contains(server.id) { favorites.append(server.stored) }
    }

    public mutating func removeCustom(id: String) {
        custom.removeAll { $0.id == id }
        favorites.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = SpeedServerPrefs.automaticID
            selected = nil
        }
    }
}

public struct SpeedServerPrefsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: SpeedServerPrefsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SpeedServerPrefsStore(url: base.appendingPathComponent("NetScope", isDirectory: true)
            .appendingPathComponent("speedtest-serveurs.json"))
    }

    public func load() -> SpeedServerPrefs {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(SpeedServerPrefs.self, from: data) else { return SpeedServerPrefs() }
        return prefs
    }

    public func save(_ prefs: SpeedServerPrefs) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var clean = prefs
        clean.selected = prefs.selected?.stored
        clean.favorites = prefs.favorites.map(\.stored)
        clean.custom = prefs.custom.map(\.stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(clean).write(to: url, options: .atomic)
    }
}
