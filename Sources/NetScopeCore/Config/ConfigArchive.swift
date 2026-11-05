import Foundation

// Note 56 : fichier d'export de la configuration (.netscope-config), un seul fichier.
//
// Contenu : une archive .zip (BackupZip) avec « configuration.json » (manifeste versionné : parties
// incluses, fichiers, préférences, comptes du Trousseau), « fichiers/… » (les JSON du dossier de
// données), « preferences.plist » et, dans un export chiffré seulement, « secrets.json ».
// Dès qu'un secret est inclus, le chiffrement par mot de passe est OBLIGATOIRE : l'archive est
// alors scellée exactement comme une sauvegarde chiffrée de la note 38 (BackupCrypto : PBKDF2 puis
// AES-GCM 256, en-tête en clair authentifié). Sans secret, le mot de passe reste possible.
// L'import lit aussi une sauvegarde de NetScope (.zip, dossier ou .netscope-backup).

/// Un fichier JSON du dossier de données.
public struct ConfigFile: Codable, Hashable, Sendable {
    public var path: String
    public var data: Data
    /// Date de modification (fichier sur le disque) ; nil si inconnue.
    public var modified: Date?

    public init(path: String, data: Data, modified: Date? = nil) {
        self.path = path
        self.data = data
        self.modified = modified
    }
}

/// État de la configuration de ce Mac (ou d'un export) : fichiers, préférences, secrets.
public struct ConfigSnapshot: Sendable {
    public var files: [ConfigFile]
    /// Clé → valeur en liste de propriétés (`ConfigPlist`).
    public var preferences: [String: Data]
    /// Secrets lus au Trousseau (export, synchronisation) ; vide pour un aperçu d'import.
    public var secrets: [BackupSecret]
    /// Comptes du Trousseau présents sur ce Mac (noms seulement, sans lire les valeurs).
    public var secretNames: [BackupKeychainItem]

    public init(files: [ConfigFile] = [], preferences: [String: Data] = [:], secrets: [BackupSecret] = [],
                secretNames: [BackupKeychainItem] = []) {
        self.files = files
        self.preferences = preferences
        self.secrets = secrets
        self.secretNames = secretNames
    }

    /// Lit le dossier de données (fichiers JSON, avec leur date) et convertit les préférences.
    public static func read(dataDirectory: URL, preferences: [String: Any], secrets: [BackupSecret] = [],
                            secretNames: [BackupKeychainItem] = []) -> ConfigSnapshot {
        var files: [ConfigFile] = []
        for path in BackupEngine.dataFiles(in: dataDirectory).files {
            let url = dataDirectory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append(ConfigFile(path: path, data: data, modified: modified))
        }
        var converted: [String: Data] = [:]
        for (key, value) in preferences {
            if let data = ConfigPlist.encode(value) { converted[key] = data }
        }
        let names = secretNames.isEmpty ? secrets.map(\.item) : secretNames
        return ConfigSnapshot(files: files, preferences: converted, secrets: secrets, secretNames: names)
    }

    public func file(_ path: String) -> ConfigFile? { files.first { $0.path == path } }

    /// Données d'une liste à identifiants (fichier ou préférence Data).
    public func collectionData(_ collection: ConfigCollection) -> Data? {
        switch collection.kind {
        case .fichier: return file(collection.key)?.data
        case .preference: return preferences[collection.key].flatMap(ConfigPlist.decode) as? Data
        default: return nil
        }
    }

    /// Date de la liste (fichier) ; nil pour une préférence.
    public func collectionModified(_ collection: ConfigCollection) -> Date? {
        collection.kind == .fichier ? file(collection.key)?.modified : nil
    }
}

/// Ce qu'une partie contient (feuille d'export, aperçu).
public struct ConfigPartContents: Identifiable, Hashable, Sendable {
    public var part: ConfigPart
    public var files: [String]
    public var preferences: [String]
    public var secrets: [BackupKeychainItem]
    public var bytes: Int

    public var id: String { part.id }
    public var isEmpty: Bool { files.isEmpty && preferences.isEmpty && secrets.isEmpty }

    /// « 3 fichiers · 12 réglages · 4 secrets ».
    public var summary: String {
        var parts: [String] = []
        if !files.isEmpty { parts.append("\(files.count) fichier\(files.count > 1 ? "s" : "")") }
        if !preferences.isEmpty { parts.append("\(preferences.count) réglage\(preferences.count > 1 ? "s" : "")") }
        if !secrets.isEmpty { parts.append("\(secrets.count) secret\(secrets.count > 1 ? "s" : "")") }
        return parts.isEmpty ? "Rien sur ce Mac" : parts.joined(separator: " · ")
    }
}

/// Manifeste d'un export (« configuration.json »), versionné.
public struct ConfigManifest: Codable, Equatable, Sendable {
    public static let formatName = "netscope-configuration"
    public static let currentVersion = 1

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int
        public var crc32: UInt32
        public var modified: Date?
    }

    public struct Part: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var files: [File]
        public var preferences: [String]
        public var secrets: [BackupKeychainItem]

        public init(id: String, title: String, files: [File], preferences: [String], secrets: [BackupKeychainItem]) {
            self.id = id
            self.title = title
            self.files = files
            self.preferences = preferences
            self.secrets = secrets
        }
    }

    public var format = ConfigManifest.formatName
    public var version = ConfigManifest.currentVersion
    public var createdAt: Date
    /// Nom du Mac qui a exporté (« MacBook Pro de Dany »).
    public var deviceName: String
    public var appVersion: String
    public var appBuild: String
    public var parts: [Part]
    public var encrypted: Bool
    /// « sauvegarde » quand l'import lit une sauvegarde de NetScope plutôt qu'un export.
    public var origin: String?

    public init(createdAt: Date, deviceName: String, appVersion: String, appBuild: String, parts: [Part], encrypted: Bool,
                origin: String? = nil) {
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.parts = parts
        self.encrypted = encrypted
        self.origin = origin
    }

    public var fileCount: Int { parts.reduce(0) { $0 + $1.files.count } }
    public var preferenceCount: Int { parts.reduce(0) { $0 + $1.preferences.count } }
    public var secretCount: Int { parts.reduce(0) { $0 + $1.secrets.count } }
}

/// Export lu, vérifié, prêt pour l'aperçu.
public struct ConfigPackage: Sendable {
    public var manifest: ConfigManifest
    public var files: [ConfigFile]
    public var preferences: [String: Data]
    public var secrets: [BackupSecret]
    public var encryption: BackupEncryptedHeader?

    public init(manifest: ConfigManifest, files: [ConfigFile], preferences: [String: Data], secrets: [BackupSecret],
                encryption: BackupEncryptedHeader? = nil) {
        self.manifest = manifest
        self.files = files
        self.preferences = preferences
        self.secrets = secrets
        self.encryption = encryption
    }

    /// L'export vu comme un état (pour l'aperçu, qui le compare à celui de ce Mac).
    public var snapshot: ConfigSnapshot {
        ConfigSnapshot(files: files, preferences: preferences, secrets: secrets, secretNames: secrets.map(\.item))
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case nothingSelected
    /// Un secret est inclus : un mot de passe est obligatoire.
    case passwordRequired
    case notAConfiguration(String)
    case newerVersion(Int)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .nothingSelected: return "Cochez au moins une partie de la configuration."
        case .passwordRequired: return "Des jetons ou des secrets sont inclus\u{00A0}: choisissez un mot de passe pour chiffrer l’export."
        case .notAConfiguration(let name): return "«\u{00A0}\(name)\u{00A0}» n’est ni une configuration ni une sauvegarde de NetScope."
        case .newerVersion(let version): return "Configuration exportée par une version plus récente de NetScope (format \(version))\u{00A0}: mettez NetScope à jour pour l’importer."
        case .corrupted(let why): return "Configuration endommagée\u{00A0}: \(why)."
        }
    }
}

public enum ConfigArchive {
    public static let fileExtension = "netscope-config"
    public static let manifestName = "configuration.json"
    public static let preferencesName = "preferences.plist"
    public static let filesFolder = "fichiers"
    public static let secretsName = "secrets.json"

    /// « NetScope-configuration-2026-11-04.netscope-config ».
    public static func suggestedName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "NetScope-configuration-\(formatter.string(from: date)).\(fileExtension)"
    }

    // MARK: Contenu par partie

    /// Ce que chaque partie du registre contient dans cet état (toutes les parties, même vides).
    public static func contents(of snapshot: ConfigSnapshot, registry: ConfigPartRegistry = .standard) -> [ConfigPartContents] {
        var byPart: [String: ConfigPartContents] = [:]
        for part in registry.parts { byPart[part.id] = ConfigPartContents(part: part, files: [], preferences: [], secrets: [], bytes: 0) }
        for file in snapshot.files.sorted(by: { $0.path < $1.path }) {
            guard let part = registry.part(forFile: file.path) else { continue }
            byPart[part.id]?.files.append(file.path)
            byPart[part.id]?.bytes += file.data.count
        }
        for key in snapshot.preferences.keys.sorted() {
            guard let part = registry.part(forPreference: key) else { continue }
            byPart[part.id]?.preferences.append(key)
            byPart[part.id]?.bytes += snapshot.preferences[key]?.count ?? 0
        }
        for item in snapshot.secretNames.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            guard let part = registry.part(forSecret: item.service, account: item.account) else { continue }
            byPart[part.id]?.secrets.append(item)
        }
        return registry.parts.compactMap { byPart[$0.id] }
    }

    /// Vrai si les parties choisies contiennent au moins un secret (mot de passe obligatoire).
    public static func includesSecrets(_ snapshot: ConfigSnapshot, parts: Set<String>, registry: ConfigPartRegistry = .standard) -> Bool {
        snapshot.secretNames.contains { item in
            registry.part(forSecret: item.service, account: item.account).map { parts.contains($0.id) } ?? false
        }
    }

    // MARK: Export

    /// Fichier d'export des parties choisies. Un secret inclus sans mot de passe : `passwordRequired`
    /// (jamais de secret dans un fichier en clair).
    public static func export(_ snapshot: ConfigSnapshot, parts selected: Set<String>, password: String?,
                              registry: ConfigPartRegistry = .standard, date: Date = Date(), deviceName: String,
                              appVersion: String, appBuild: String, iterations: Int = BackupCrypto.defaultIterations) throws -> Data {
        let chosen = registry.parts.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { throw ConfigError.nothingSelected }
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        var entries: [BackupZip.Entry] = []
        var partsManifest: [ConfigManifest.Part] = chosen.map { .init(id: $0.id, title: $0.title, files: [], preferences: [], secrets: []) }
        func index(_ id: String) -> Int? { partsManifest.firstIndex { $0.id == id } }

        for file in snapshot.files.sorted(by: { $0.path < $1.path }) {
            guard let part = registry.part(forFile: file.path), let i = index(part.id) else { continue }
            entries.append(BackupZip.Entry(path: filesFolder + "/" + file.path, data: file.data))
            partsManifest[i].files.append(.init(path: file.path, bytes: file.data.count, crc32: CRC32.checksum(file.data), modified: file.modified))
        }
        var preferences: [String: Any] = [:]
        for key in snapshot.preferences.keys.sorted() {
            guard let part = registry.part(forPreference: key), let i = index(part.id),
                  let data = snapshot.preferences[key], let value = ConfigPlist.decode(data) else { continue }
            preferences[key] = value
            partsManifest[i].preferences.append(key)
        }
        var secrets: [BackupSecret] = []
        for secret in snapshot.secrets.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            guard let part = registry.part(forSecret: secret.service, account: secret.account), let i = index(part.id) else { continue }
            secrets.append(secret)
            partsManifest[i].secrets.append(secret.item)
        }
        if !secrets.isEmpty, password == nil { throw ConfigError.passwordRequired }

        if !preferences.isEmpty {
            entries.append(BackupZip.Entry(path: preferencesName,
                                           data: try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)))
        }
        let manifest = ConfigManifest(createdAt: date, deviceName: deviceName, appVersion: appVersion, appBuild: appBuild,
                                      parts: partsManifest, encrypted: password != nil)
        entries.insert(BackupZip.Entry(path: manifestName, data: try BackupEngine.encoder().encode(manifest)), at: 0)
        if !secrets.isEmpty {
            entries.append(BackupZip.Entry(path: secretsName, data: try BackupEngine.encoder().encode(secrets)))
        }
        let archive = BackupZip.archive(entries, date: date)
        guard let password else { return archive }
        return try BackupCrypto.seal(archive, password: password, iterations: iterations, createdAt: date, kind: .manuelle,
                                     appVersion: appVersion, appBuild: appBuild, fileCount: manifest.fileCount,
                                     preferenceCount: manifest.preferenceCount, secretCount: secrets.count)
    }

    // MARK: Lecture

    public static func isEncrypted(_ data: Data) -> Bool { BackupCrypto.isEncrypted(data) }

    /// En-tête en clair d'un export chiffré (sans mot de passe).
    public static func header(of data: Data) -> BackupEncryptedHeader? { try? BackupCrypto.header(of: data).header }

    /// Lit un fichier : export de configuration (chiffré ou non), ou sauvegarde de NetScope
    /// (archive, dossier, archive chiffrée), convertie partie par partie.
    public static func read(_ url: URL, password: String?, registry: ConfigPartRegistry = .standard) throws -> ConfigPackage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ConfigError.notAConfiguration(url.lastPathComponent)
        }
        if isDirectory.boolValue {
            return try fromBackup(BackupEngine.read(url), registry: registry)
        }
        return try read(Data(contentsOf: url), name: url.lastPathComponent, password: password, registry: registry)
    }

    public static func read(_ data: Data, name: String, password: String?, registry: ConfigPartRegistry = .standard) throws -> ConfigPackage {
        var header: BackupEncryptedHeader?
        var plaintext = data
        if BackupCrypto.isEncrypted(data) {
            guard let password, !password.isEmpty else { throw BackupCryptoError.passwordRequired }
            let opened = try BackupCrypto.open(data, password: password)
            header = opened.header
            plaintext = opened.plaintext
        }
        let entries: [BackupZip.Entry]
        do {
            entries = try BackupZip.entries(of: plaintext)
        } catch {
            if header != nil { throw BackupCryptoError.tampered }
            throw ConfigError.notAConfiguration(name)
        }
        guard let manifestData = entries.first(where: { $0.path == manifestName })?.data else {
            if entries.contains(where: { $0.path == BackupEngine.manifestName }) {
                return try fromBackup(backupContents(entries, header: header, name: name), registry: registry)
            }
            throw ConfigError.notAConfiguration(name)
        }
        let manifest: ConfigManifest
        do {
            manifest = try BackupEngine.decoder().decode(ConfigManifest.self, from: manifestData)
        } catch {
            throw ConfigError.corrupted("manifeste illisible")
        }
        guard manifest.format == ConfigManifest.formatName else { throw ConfigError.notAConfiguration(name) }
        guard manifest.version <= ConfigManifest.currentVersion else { throw ConfigError.newerVersion(manifest.version) }
        if header != nil, !manifest.encrypted { throw BackupCryptoError.tampered }

        var files: [ConfigFile] = []
        for part in manifest.parts {
            for file in part.files {
                guard BackupEngine.isSafeRelativePath(file.path) else { throw ConfigError.corrupted("chemin «\u{00A0}\(file.path)\u{00A0}» refusé") }
                guard let entry = entries.first(where: { $0.path == filesFolder + "/" + file.path }) else {
                    throw ConfigError.corrupted("«\u{00A0}\(file.path)\u{00A0}» manquant")
                }
                guard CRC32.checksum(entry.data) == file.crc32 else { throw ConfigError.corrupted("«\u{00A0}\(file.path)\u{00A0}» modifié") }
                files.append(ConfigFile(path: file.path, data: entry.data, modified: file.modified))
            }
        }
        var preferences: [String: Data] = [:]
        let wanted = Set(manifest.parts.flatMap(\.preferences))
        if let data = entries.first(where: { $0.path == preferencesName })?.data,
           let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in dictionary where wanted.contains(key) && registry.part(forPreference: key) != nil {
                if let encoded = ConfigPlist.encode(value) { preferences[key] = encoded }
            }
        }
        var secrets: [BackupSecret] = []
        if let data = entries.first(where: { $0.path == secretsName })?.data {
            // Un secret hors de la partie chiffrée n'est jamais accepté.
            guard header != nil else { throw ConfigError.corrupted("secrets dans un fichier non chiffré refusés") }
            guard let decoded = try? BackupEngine.decoder().decode([BackupSecret].self, from: data) else { throw BackupCryptoError.tampered }
            secrets = decoded
        }
        if let header {
            guard secrets.map(\.item) == manifest.parts.flatMap(\.secrets).sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }),
                  secrets.count == header.secretCount else { throw BackupCryptoError.tampered }
        }
        guard secrets.allSatisfy({ BackupKeychainScan.isOwnService($0.service) && !ConfigSecrets.neverCopied.contains($0.service) }) else {
            throw ConfigError.corrupted("secret d’un autre service refusé")
        }
        return ConfigPackage(manifest: manifest, files: files, preferences: preferences, secrets: secrets, encryption: header)
    }

    /// Entrées d'une sauvegarde (archive déjà ouverte) → contenu vérifié par BackupEngine.
    private static func backupContents(_ entries: [BackupZip.Entry], header: BackupEncryptedHeader?, name: String) throws -> BackupContents {
        // BackupEngine lit un fichier : l'archive (déjà déchiffrée) passe par un fichier temporaire.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-config-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try BackupZip.archive(entries).write(to: temporary, options: .atomic)
        var contents = try BackupEngine.read(temporary)
        if header != nil, let data = entries.first(where: { $0.path == BackupEngine.secretsName })?.data {
            guard let decoded = try? BackupEngine.decoder().decode([BackupSecret].self, from: data) else { throw BackupCryptoError.tampered }
            guard decoded.map(\.item) == (contents.manifest.secrets ?? []) else { throw BackupCryptoError.tampered }
            contents.secrets = decoded
        }
        contents.encryption = header
        return contents
    }

    /// Sauvegarde de NetScope vue comme un export de toutes les parties.
    static func fromBackup(_ contents: BackupContents, registry: ConfigPartRegistry) throws -> ConfigPackage {
        var preferences: [String: Data] = [:]
        if let raw = contents.preferences,
           let dictionary = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] {
            for (key, value) in dictionary where registry.part(forPreference: key) != nil {
                if let encoded = ConfigPlist.encode(value) { preferences[key] = encoded }
            }
        }
        let files = contents.files.map { ConfigFile(path: $0.path, data: $0.data, modified: contents.manifest.createdAt) }
            .filter { registry.part(forFile: $0.path) != nil }
        let secrets = contents.secrets.filter { registry.part(forSecret: $0.service, account: $0.account) != nil }
        let snapshot = ConfigSnapshot(files: files, preferences: preferences, secrets: secrets, secretNames: secrets.map(\.item))
        let parts = Self.contents(of: snapshot, registry: registry).filter { !$0.isEmpty }.map { contentsOfPart in
            ConfigManifest.Part(id: contentsOfPart.part.id, title: contentsOfPart.part.title,
                                files: contentsOfPart.files.compactMap { path in
                                    snapshot.file(path).map { .init(path: path, bytes: $0.data.count, crc32: CRC32.checksum($0.data), modified: $0.modified) }
                                },
                                preferences: contentsOfPart.preferences, secrets: contentsOfPart.secrets)
        }
        let manifest = ConfigManifest(createdAt: contents.manifest.createdAt, deviceName: "", appVersion: contents.manifest.appVersion,
                                      appBuild: contents.manifest.appBuild, parts: parts, encrypted: contents.encryption != nil,
                                      origin: "sauvegarde")
        return ConfigPackage(manifest: manifest, files: files, preferences: preferences, secrets: secrets, encryption: contents.encryption)
    }
}
