import Foundation

// Sauvegarde et restauration de NetScope (Réglages › Export et sauvegarde) : tous les fichiers
// JSON de ~/Library/Application Support/NetScope (plages, inventaire, Surveillance, services en
// ligne, disques, identifiants SSH/WMI sans secret…) et les préférences de l'app, dans une archive
// .zip ou un dossier daté, avec un manifeste JSON versionné. Les secrets du Trousseau ne sont
// jamais copiés : le manifeste nomme seulement les comptes à ressaisir après une restauration.

/// Origine d'une sauvegarde.
public enum BackupKind: String, Codable, CaseIterable, Sendable {
    case automatique, manuelle, securite

    public var label: String {
        switch self {
        case .automatique: return "Automatique"
        case .manuelle: return "Manuelle"
        case .securite: return "Sécurité"
        }
    }

    /// Suffixe du nom de fichier.
    var suffix: String {
        switch self {
        case .automatique: return "auto"
        case .manuelle: return "manuelle"
        case .securite: return "securite"
        }
    }
}

/// Forme d'une sauvegarde sur le disque.
public enum BackupFormat: String, Codable, CaseIterable, Sendable {
    case zip, dossier

    public var label: String { self == .zip ? "Archive .zip" : "Dossier daté" }
}

/// Compte du Trousseau à ressaisir après une restauration (le secret lui-même n'est jamais copié).
public struct BackupKeychainItem: Codable, Hashable, Sendable {
    public var service: String
    public var account: String
    public var usage: String

    public init(service: String, account: String, usage: String) {
        self.service = service
        self.account = account
        self.usage = usage
    }
}

/// Manifeste d'une sauvegarde (manifeste.json), versionné.
public struct BackupManifest: Codable, Equatable, Sendable {
    public static let formatName = "netscope-sauvegarde"
    public static let currentVersion = 1

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int
        public var crc32: UInt32

        public init(path: String, bytes: Int, crc32: UInt32) {
            self.path = path
            self.bytes = bytes
            self.crc32 = crc32
        }
    }

    public var format = BackupManifest.formatName
    public var version = BackupManifest.currentVersion
    public var createdAt: Date
    public var kind: BackupKind
    public var appVersion: String
    public var appBuild: String
    public var files: [File]
    /// Fichier des préférences (« preferences.plist »), nil si aucune.
    public var preferencesFile: String?
    public var preferenceCount: Int
    /// Préférences écartées parce que leur nom évoque un secret (jamais copiées).
    public var excludedPreferenceKeys: [String]
    /// Fichiers de données non copiés (base des fabricants, fichiers illisibles…).
    public var skippedFiles: [String]
    /// Comptes du Trousseau à ressaisir : noms seulement.
    public var keychain: [BackupKeychainItem]
    public var note: String

    public init(createdAt: Date, kind: BackupKind, appVersion: String, appBuild: String, files: [File],
                preferencesFile: String?, preferenceCount: Int, excludedPreferenceKeys: [String], skippedFiles: [String],
                keychain: [BackupKeychainItem], note: String) {
        self.createdAt = createdAt
        self.kind = kind
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.files = files
        self.preferencesFile = preferencesFile
        self.preferenceCount = preferenceCount
        self.excludedPreferenceKeys = excludedPreferenceKeys
        self.skippedFiles = skippedFiles
        self.keychain = keychain
        self.note = note
    }

    /// « 9 fichiers · 42 préférences ».
    public var summary: String {
        let files = "\(self.files.count) fichier\(self.files.count > 1 ? "s" : "")"
        let prefs = "\(preferenceCount) préférence\(preferenceCount > 1 ? "s" : "")"
        return "\(files) · \(prefs)"
    }

    /// Noms courts des fichiers (« etat, inventaire, surveillance »).
    public var contentLabel: String {
        files.map { BackupEngine.label(for: $0.path) }.joined(separator: ", ")
    }
}

/// Ce qu'on sauvegarde.
public struct BackupSource: Sendable {
    public var dataDirectory: URL
    /// Préférences de l'app (domaine UserDefaults), au format liste de propriétés.
    public var preferences: Data?
    public var keychain: [BackupKeychainItem]
    public var appVersion: String
    public var appBuild: String

    public init(dataDirectory: URL, preferences: Data?, keychain: [BackupKeychainItem], appVersion: String, appBuild: String) {
        self.dataDirectory = dataDirectory
        self.preferences = preferences
        self.keychain = keychain
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}

/// Une sauvegarde trouvée dans le dossier.
public struct BackupInfo: Identifiable, Hashable, Sendable {
    public var url: URL
    public var format: BackupFormat
    public var manifest: BackupManifest
    /// Taille sur le disque (archive, ou total du dossier).
    public var bytes: Int64

    public init(url: URL, format: BackupFormat, manifest: BackupManifest, bytes: Int64) {
        self.url = url
        self.format = format
        self.manifest = manifest
        self.bytes = bytes
    }

    public var id: String { url.path }
    public var date: Date { manifest.createdAt }

    public static func == (lhs: BackupInfo, rhs: BackupInfo) -> Bool { lhs.url == rhs.url && lhs.bytes == rhs.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Contenu lu d'une sauvegarde, prêt à restaurer.
public struct BackupContents: Sendable {
    public var manifest: BackupManifest
    public var files: [BackupZip.Entry]
    public var preferences: Data?
}

public enum BackupError: Error, LocalizedError, Equatable {
    case notABackup(String)
    case newerVersion(Int)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notABackup(let name): return "« \(name) » n’est pas une sauvegarde NetScope (manifeste absent)."
        case .newerVersion(let version): return "Sauvegarde faite par une version plus récente de NetScope (format \(version)) : mettez NetScope à jour pour la restaurer."
        case .corrupted(let why): return "Sauvegarde endommagée : \(why)."
        }
    }
}

public enum BackupEngine {
    public static let manifestName = "manifeste.json"
    public static let preferencesName = "preferences.plist"
    public static let filesFolder = "fichiers"
    public static let namePrefix = "NetScope-sauvegarde-"
    /// Taille maximale d'un fichier de données copié (garde-fou).
    public static let maxFileBytes = 64 * 1_048_576

    /// Fragments de noms de préférences qui évoquent un secret : ces préférences ne sont jamais copiées.
    public static let secretKeyFragments = ["password", "motdepasse", "mot-de-passe", "passphrase", "secret", "token",
                                            "jeton", "communaute", "community", "apikey", "api-key", "credential"]

    // MARK: Recensement

    /// Fichiers JSON du dossier de données (sous-dossiers compris), chemins relatifs triés.
    /// Les fichiers cachés et les autres extensions (oui.tsv, fichiers d'essai) sont laissés.
    public static func dataFiles(in directory: URL) -> (files: [String], skipped: [String]) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles]) else { return ([], []) }
        var files: [String] = []
        var skipped: [String] = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
            while relative.hasPrefix("/") { relative.removeFirst() }
            if url.pathExtension.lowercased() == "json", (values?.fileSize ?? 0) <= maxFileBytes {
                files.append(relative)
            } else {
                skipped.append(relative)
            }
        }
        return (files.sorted(), skipped.sorted())
    }

    /// Préférences sans les clés qui évoquent un secret.
    public static func filterPreferences(_ preferences: [String: Any]) -> (kept: [String: Any], excluded: [String]) {
        var kept: [String: Any] = [:]
        var excluded: [String] = []
        for (key, value) in preferences {
            let lower = key.lowercased()
            if secretKeyFragments.contains(where: lower.contains) {
                excluded.append(key)
            } else {
                kept[key] = value
            }
        }
        return (kept, excluded.sorted())
    }

    /// Libellé lisible d'un fichier de données.
    public static func label(for path: String) -> String {
        let name = (path as NSString).deletingPathExtension
        // Note 28 : un dossier par site (inventaire et résultats propres au site).
        let parts = name.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == SiteFiles.folderName {
            let who = parts[1] == SiteFiles.noSiteKey ? "plages libres" : "site"
            switch parts[2] {
            case "inventory": return "inventaire (\(who))"
            case "resultats": return "résultats du scan (\(who))"
            case "notes-appareils": return "notes des appareils (\(who))"
            default: break
            }
        }
        switch name {
        case "sites": return "sites"
        case "inventory": return "inventaire"
        case "inventory.avant-sites": return "inventaire d’avant les sites (copie de sécurité)"
        case "etat": return "plages et noms"
        case "inventaire": return "inventaire"
        case "surveillance": return "Surveillance"
        case "outils": return "Boîte à outils"
        case "services-en-ligne": return "services en ligne"
        case "notes-appareils": return "notes des appareils"
        case "notes-appareils.avant-sites": return "notes des appareils d’avant les sites (copie de sécurité)"
        case "disques": return "historique des disques"
        case "identifiants": return "identifiants SSH/WMI"
        default: return name
        }
    }

    // MARK: Création

    /// Nom d'une sauvegarde : « NetScope-sauvegarde-2026-11-04-080000-auto(.zip) ».
    public static func name(for date: Date, kind: BackupKind, format: BackupFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = namePrefix + formatter.string(from: date) + "-" + kind.suffix
        return format == .zip ? base + ".zip" : base
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Crée une sauvegarde dans `folder`.
    @discardableResult
    public static func create(_ source: BackupSource, in folder: URL, format: BackupFormat, kind: BackupKind,
                              date: Date = Date()) throws -> BackupInfo {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let (paths, skippedPaths) = dataFiles(in: source.dataDirectory)
        var entries: [BackupZip.Entry] = []
        var files: [BackupManifest.File] = []
        var skipped = skippedPaths
        for path in paths {
            guard let data = try? Data(contentsOf: source.dataDirectory.appendingPathComponent(path)) else {
                skipped.append(path)
                continue
            }
            entries.append(BackupZip.Entry(path: filesFolder + "/" + path, data: data))
            files.append(BackupManifest.File(path: path, bytes: data.count, crc32: CRC32.checksum(data)))
        }

        var preferenceCount = 0
        var excluded: [String] = []
        var preferencesFile: String?
        if let raw = source.preferences,
           let dictionary = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] {
            let filtered = filterPreferences(dictionary)
            excluded = filtered.excluded
            preferenceCount = filtered.kept.count
            if !filtered.kept.isEmpty {
                let data = try PropertyListSerialization.data(fromPropertyList: filtered.kept, format: .xml, options: 0)
                entries.append(BackupZip.Entry(path: preferencesName, data: data))
                preferencesFile = preferencesName
            }
        }

        let manifest = BackupManifest(createdAt: date, kind: kind, appVersion: source.appVersion, appBuild: source.appBuild,
                                      files: files, preferencesFile: preferencesFile, preferenceCount: preferenceCount,
                                      excludedPreferenceKeys: excluded, skippedFiles: skipped.sorted(),
                                      keychain: source.keychain.sorted { ($0.service, $0.account) < ($1.service, $1.account) },
                                      note: "Les secrets du Trousseau macOS ne sont jamais copiés : ressaisissez-les après une restauration sur un autre Mac.")
        let manifestData = try encoder().encode(manifest)
        entries.insert(BackupZip.Entry(path: manifestName, data: manifestData), at: 0)

        var target = folder.appendingPathComponent(name(for: date, kind: kind, format: format))
        var counter = 2
        while manager.fileExists(atPath: target.path) {
            let base = (name(for: date, kind: kind, format: .dossier)) + "-\(counter)"
            target = folder.appendingPathComponent(format == .zip ? base + ".zip" : base)
            counter += 1
        }
        switch format {
        case .zip:
            try BackupZip.archive(entries, date: date).write(to: target, options: .atomic)
        case .dossier:
            // Écrit dans un dossier temporaire voisin, puis renommé : jamais de sauvegarde à moitié faite.
            let staging = folder.appendingPathComponent(".en-cours-\(UUID().uuidString)", isDirectory: true)
            do {
                for entry in entries {
                    let url = staging.appendingPathComponent(entry.path)
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try entry.data.write(to: url, options: .atomic)
                }
                try manager.moveItem(at: staging, to: target)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
        }
        return BackupInfo(url: target, format: format, manifest: manifest, bytes: size(of: target))
    }

    // MARK: Liste et rotation

    /// Sauvegardes du dossier (archives et dossiers), de la plus récente à la plus ancienne.
    public static func list(in folder: URL) -> [BackupInfo] {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles]) else { return [] }
        var result: [BackupInfo] = []
        for url in items where url.lastPathComponent.hasPrefix(namePrefix) {
            if let info = try? info(at: url) { result.append(info) }
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Manifeste et taille d'une sauvegarde.
    public static func info(at url: URL) throws -> BackupInfo {
        let contents = try read(url, manifestOnly: true)
        let format: BackupFormat = url.pathExtension.lowercased() == "zip" ? .zip : .dossier
        return BackupInfo(url: url, format: format, manifest: contents.manifest, bytes: size(of: url))
    }

    /// Garde les `keep` sauvegardes automatiques et manuelles les plus récentes (0 : toutes) et les
    /// `keepSafety` dernières sauvegardes de sécurité ; supprime les autres. Renvoie les supprimées.
    @discardableResult
    public static func rotate(in folder: URL, keep: Int, keepSafety: Int = 3,
                              remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) rethrows -> [URL] {
        let all = list(in: folder)
        var removed: [URL] = []
        let regular = all.filter { $0.manifest.kind != .securite }
        let safety = all.filter { $0.manifest.kind == .securite }
        if keep > 0 {
            for info in regular.dropFirst(keep) {
                try remove(info.url)
                removed.append(info.url)
            }
        }
        for info in safety.dropFirst(max(1, keepSafety)) {
            try remove(info.url)
            removed.append(info.url)
        }
        return removed
    }

    // MARK: Lecture et restauration

    /// Lit une sauvegarde (archive ou dossier) et vérifie son manifeste.
    public static func read(_ url: URL, manifestOnly: Bool = false) throws -> BackupContents {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw BackupError.notABackup(url.lastPathComponent) }
        var entries: [BackupZip.Entry] = []
        if isDirectory.boolValue {
            let manifestURL = url.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else { throw BackupError.notABackup(url.lastPathComponent) }
            entries.append(BackupZip.Entry(path: manifestName, data: data))
            if !manifestOnly {
                let (paths, _) = dataFiles(in: url.appendingPathComponent(filesFolder))
                for path in paths {
                    entries.append(BackupZip.Entry(path: filesFolder + "/" + path,
                                                   data: try Data(contentsOf: url.appendingPathComponent(filesFolder).appendingPathComponent(path))))
                }
                if let prefs = try? Data(contentsOf: url.appendingPathComponent(preferencesName)) {
                    entries.append(BackupZip.Entry(path: preferencesName, data: prefs))
                }
            }
        } else {
            do {
                entries = try BackupZip.entries(of: try Data(contentsOf: url))
            } catch let error as BackupZip.ZipError {
                throw BackupError.corrupted(error.localizedDescription)
            }
        }
        guard let manifestData = entries.first(where: { $0.path == manifestName })?.data else {
            throw BackupError.notABackup(url.lastPathComponent)
        }
        let manifest: BackupManifest
        do {
            manifest = try decoder().decode(BackupManifest.self, from: manifestData)
        } catch {
            throw BackupError.corrupted("manifeste illisible")
        }
        guard manifest.format == BackupManifest.formatName else { throw BackupError.notABackup(url.lastPathComponent) }
        guard manifest.version <= BackupManifest.currentVersion else { throw BackupError.newerVersion(manifest.version) }
        if manifestOnly { return BackupContents(manifest: manifest, files: [], preferences: nil) }

        var files: [BackupZip.Entry] = []
        for file in manifest.files {
            guard let entry = entries.first(where: { $0.path == filesFolder + "/" + file.path }) else {
                throw BackupError.corrupted("« \(file.path) » manquant")
            }
            guard CRC32.checksum(entry.data) == file.crc32 else { throw BackupError.corrupted("« \(file.path) » modifié") }
            guard isSafeRelativePath(file.path) else { throw BackupError.corrupted("chemin « \(file.path) » refusé") }
            files.append(BackupZip.Entry(path: file.path, data: entry.data))
        }
        let preferences = manifest.preferencesFile.flatMap { name in entries.first { $0.path == name }?.data }
        return BackupContents(manifest: manifest, files: files, preferences: preferences)
    }

    /// Chemin relatif sans « .. » ni racine (rien n'est écrit hors du dossier de données), fichier
    /// JSON seulement (la règle même de `dataFiles`), sans composant vide ni caché : une sauvegarde
    /// fabriquée ne peut pas remplacer « ssh_known_hosts », « oui.tsv » ou un autre fichier de l'app.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.lowercased().hasSuffix(".json") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && $0 != ".." }
    }

    /// Remet les fichiers de la sauvegarde dans le dossier de données : chaque fichier est remplacé,
    /// les fichiers JSON absents de la sauvegarde sont retirés (l'état restauré est celui de la sauvegarde).
    /// Renvoie les fichiers écrits et retirés.
    @discardableResult
    public static func restoreFiles(_ contents: BackupContents, to directory: URL) throws -> (written: [String], removed: [String]) {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in contents.files where !isSafeRelativePath(file.path) {
            throw BackupError.corrupted("chemin « \(file.path) » refusé")
        }
        // 1. Tout est d'abord écrit dans un dossier voisin : un disque plein ou un refus d'écriture
        //    laisse le dossier de données intact.
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent)-restauration-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        for file in contents.files {
            let url = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        // 2. Remplacement fichier par fichier (même volume : rapide et atomique pour chacun).
        for file in contents.files {
            let target = directory.appendingPathComponent(file.path)
            let source = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: source)
            } else {
                try manager.moveItem(at: source, to: target)
            }
        }
        // 3. Seulement quand tout est en place : retrait des fichiers JSON absents de la sauvegarde.
        let keep = Set(contents.files.map(\.path))
        var removed: [String] = []
        for path in dataFiles(in: directory).files where !keep.contains(path) {
            try manager.removeItem(at: directory.appendingPathComponent(path))
            removed.append(path)
        }
        return (contents.files.map(\.path), removed)
    }

    /// Préférences à remettre : celles de la sauvegarde, plus les préférences actuelles dont le nom
    /// commence par un préfixe gardé (réglages de la sauvegarde elle-même : dossier, rotation…) ou
    /// évoque un secret (jamais dans la sauvegarde, donc jamais effacées par elle).
    public static func mergedPreferences(backup: Data?, current: [String: Any], preserving prefixes: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let backup, let dictionary = try? PropertyListSerialization.propertyList(from: backup, format: nil) as? [String: Any] {
            result = filterPreferences(dictionary).kept
        }
        for (key, value) in current {
            let lower = key.lowercased()
            if prefixes.contains(where: key.hasPrefix) || secretKeyFragments.contains(where: lower.contains) {
                result[key] = value
            }
        }
        return result
    }

    // MARK: Outils

    /// Taille d'un fichier, ou total d'un dossier.
    public static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let item as URL in enumerator {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Prochaine sauvegarde automatique due ? (une par jour au plus).
    public static func isAutomaticBackupDue(last: Date?, now: Date = Date(), interval: TimeInterval = 86_400) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now.addingTimeInterval(3600)
    }
}
