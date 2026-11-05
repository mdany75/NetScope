import Foundation

/// Fichier tournant du journal de l'app (note 35) : `NetScope.log`, puis `NetScope.1.log`,
/// `NetScope.2.log`… Quand le fichier courant dépasse `maxBytes`, il devient `.1`, l'ancien `.1`
/// devient `.2`, et le plus vieux est supprimé : au plus `maxFiles` fichiers, donc
/// `maxFiles × maxBytes` octets sur le disque. Sûr entre fils.
public final class AppLogFile: @unchecked Sendable {
    public let directory: URL
    public let baseName: String
    public let maxBytes: Int
    public let maxFiles: Int

    private let lock = NSLock()
    private let fileManager = FileManager.default

    /// Dossier des journaux de macOS pour NetScope : ~/Library/Logs/NetScope.
    public static var standardDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/NetScope", isDirectory: true)
    }

    public init(directory: URL, baseName: String = "NetScope", maxBytes: Int = 1_000_000, maxFiles: Int = 3) {
        self.directory = directory
        self.baseName = baseName
        self.maxBytes = max(256, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    /// Fichier de rang `index` (0 : le courant).
    public func url(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "\(baseName).log" : "\(baseName).\(index).log")
    }

    /// Fichiers présents, du plus ancien au courant.
    public var existingFiles: [URL] {
        (0..<maxFiles).reversed().map(url).filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Taille totale des fichiers.
    public var totalBytes: Int {
        existingFiles.reduce(0) { total, url in
            total + ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: Écriture

    /// Ajoute une entrée (déjà masquée par `AppLog`) ; échec d'écriture ignoré (disque plein,
    /// dossier protégé) : le journal en mémoire reste complet.
    public func append(_ entry: AppLogEntry) {
        let line = Data((entry.fileLine + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = url(0)
            let size = (try? fileManager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0, size + line.count > maxBytes { rotateLocked() }
            if fileManager.fileExists(atPath: current.path) {
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: current, options: .atomic)
                // Journal personnel : lisible par l'utilisateur seulement.
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            }
        } catch {
            // Rien à faire : pas de boucle d'erreurs dans le journal lui-même.
        }
    }

    private func rotateLocked() {
        try? fileManager.removeItem(at: url(maxFiles - 1))
        guard maxFiles > 1 else { return }
        for index in stride(from: maxFiles - 2, through: 0, by: -1) {
            let source = url(index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: url(index + 1))
        }
    }

    /// Supprime tous les fichiers du journal.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<(maxFiles + 2) { try? fileManager.removeItem(at: url(index)) }
    }

    // MARK: Lecture

    /// Dernières entrées des fichiers (au plus `limit`), de la plus ancienne à la plus récente ;
    /// les lignes illisibles sont ignorées.
    public func readEntries(limit: Int = AppLog.defaultCapacity) -> [AppLogEntry] {
        lock.lock()
        let files = existingFiles
        var entries: [AppLogEntry] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            entries += text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { AppLogEntry(fileLine: String($0)) }
        }
        lock.unlock()
        return Array(entries.suffix(max(0, limit)))
    }
}
