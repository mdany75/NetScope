import Foundation

// Emplacements ajoutés (note 55), tous sites confondus (chacun porte la clé de son site) :
// ~/Library/Application Support/NetScope/disques-emplacements.json. Aucun mot de passe ici : ils
// sont au Trousseau (service com.danymenard.netscope.partages, compte = UUID de l'emplacement).

public struct DiskShareStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: DiskShareStore {
        DiskShareStore(url: DiskHistoryStore.supportDirectory.appendingPathComponent("disques-emplacements.json"))
    }

    public struct Content: Codable, Sendable, Equatable {
        public var version: Int
        public var locations: [DiskShareLocation]

        public init(version: Int = 1, locations: [DiskShareLocation] = []) {
            self.version = version
            self.locations = locations
        }
    }

    /// Emplacements enregistrés ; fichier absent ou illisible : aucun.
    public func load() -> [DiskShareLocation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Content.self, from: data))?.locations ?? []
    }

    public func save(_ locations: [DiskShareLocation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Content(locations: locations)).write(to: url, options: .atomic)
    }

    /// Ajoute ou remplace (même identifiant).
    public static func upsert(_ location: DiskShareLocation, in list: [DiskShareLocation]) -> [DiskShareLocation] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == location.id }) {
            list[index] = location
        } else {
            list.append(location)
        }
        return list
    }

    public static func remove(_ id: UUID, from list: [DiskShareLocation]) -> [DiskShareLocation] {
        list.filter { $0.id != id }
    }

    /// Même partage déjà enregistré dans ce site (autre identifiant) : évite les doublons.
    public static func duplicate(of location: DiskShareLocation, in list: [DiskShareLocation]) -> DiskShareLocation? {
        list.first { other in
            other.id != location.id && other.siteKey == location.siteKey && other.kind == location.kind
                && (location.kind == .dossier
                    ? (other.trimmedShare as NSString).standardizingPath == (location.trimmedShare as NSString).standardizingPath
                    : !other.hostAliases.isDisjoint(with: location.hostAliases)
                        && DiskShareCatalog.normalizedShare(other.share) == DiskShareCatalog.normalizedShare(location.share)
                        && other.trimmedUser.lowercased() == location.trimmedUser.lowercased())
        }
    }
}
