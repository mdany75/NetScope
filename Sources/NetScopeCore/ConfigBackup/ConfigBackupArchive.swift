import Foundation

// Note 40 (0.31.0) : historique des configurations d'un site, sur le disque :
// sites/<site>/configurations/<équipement>/<date>.conf (0600, dossiers 0700) et
// sites/<site>/configurations/reglages.json (sans secret).

/// Version gardée d'une configuration.
public struct ConfigVersion: Identifiable, Hashable, Sendable {
    /// Nom du fichier (« 2026-11-05_14-02-11.conf »).
    public var id: String { url.lastPathComponent }
    public var url: URL
    public var date: Date
    public var size: Int

    public init(url: URL, date: Date, size: Int) {
        self.url = url
        self.date = date
        self.size = size
    }
}

/// Résultat d'une sauvegarde.
public enum ConfigSaveOutcome: Equatable, Sendable {
    /// Nouvelle version écrite ; `changed` : elle diffère de la précédente (nil s'il n'y en avait pas).
    case saved(ConfigVersion, previous: ConfigVersion?, changed: Bool)
    /// Même configuration que la dernière version : rien d'écrit.
    case unchanged(ConfigVersion)
}

/// Dossier des configurations d'un site.
public struct ConfigBackupArchive: Sendable {
    public static let folderName = "configurations"
    public static let settingsName = "reglages.json"
    public static let fileExtension = "conf"

    public let root: URL
    public let timeZone: TimeZone

    public init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    /// Dossier d'un site (`SiteFiles.folder(for:)`) → son dossier « configurations ».
    public init(siteFolder: URL, timeZone: TimeZone = .current) {
        self.init(root: siteFolder.appendingPathComponent(Self.folderName, isDirectory: true), timeZone: timeZone)
    }

    public func folder(for equipmentID: String) -> URL {
        root.appendingPathComponent(ConfigEquipment.folderName(name: equipmentID, host: ""), isDirectory: true)
    }

    // MARK: Noms de fichier

    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }

    /// « 2026-11-05_14-02-11.conf ».
    public func fileName(for date: Date) -> String { formatter.string(from: date) + "." + Self.fileExtension }

    /// Date lue dans un nom de fichier (« 2026-11-05_14-02-11.conf », « …-2.conf »).
    public func date(fromFileName name: String) -> Date? {
        guard name.hasSuffix("." + Self.fileExtension) else { return nil }
        let stem = String(name.dropLast(Self.fileExtension.count + 1))
        return formatter.date(from: String(stem.prefix(19)))
    }

    // MARK: Lecture

    /// Versions d'un équipement, la plus récente d'abord.
    public func versions(of equipmentID: String) -> [ConfigVersion] {
        let folder = folder(for: equipmentID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> ConfigVersion? in
            guard let date = date(fromFileName: name) else { return nil }
            let url = folder.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return ConfigVersion(url: url, date: date, size: size)
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    public func read(_ version: ConfigVersion) -> String? {
        guard let data = try? Data(contentsOf: version.url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Écriture

    /// Garde la configuration lue : nouvelle version si elle diffère de la dernière (secrets
    /// rechiffrés et lignes datées ignorés), puis retrait des versions au-delà de `keep`.
    @discardableResult
    public func save(_ text: String, for equipmentID: String, at date: Date = Date(), keep: Int) throws -> ConfigSaveOutcome {
        let existing = versions(of: equipmentID)
        let previous = existing.first
        if let previous, let old = read(previous), ConfigText.sameConfiguration(old, text) {
            return .unchanged(previous)
        }
        let folder = folder(for: equipmentID)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var name = fileName(for: date)
        var counter = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = formatter.string(from: date) + "-\(counter)." + Self.fileExtension
            counter += 1
        }
        let url = folder.appendingPathComponent(name)
        let data = Data(text.utf8)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        prune(equipmentID, keep: keep)
        return .saved(ConfigVersion(url: url, date: date, size: data.count), previous: previous, changed: previous != nil)
    }

    /// Retire les versions les plus anciennes au-delà de `keep` ; renvoie celles retirées.
    @discardableResult
    public func prune(_ equipmentID: String, keep: Int) -> [ConfigVersion] {
        let all = versions(of: equipmentID)
        let limit = ConfigBackupSettings.clampedKeep(keep)
        guard all.count > limit else { return [] }
        let removed = Array(all[limit...])
        for version in removed { try? FileManager.default.removeItem(at: version.url) }
        return removed
    }

    // MARK: Réglages

    public var settingsURL: URL { root.appendingPathComponent(Self.settingsName) }

    public func loadSettings() -> ConfigBackupSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return ConfigBackupSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ConfigBackupSettings.self, from: data)) ?? ConfigBackupSettings()
    }

    public func saveSettings(_ settings: ConfigBackupSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
}
