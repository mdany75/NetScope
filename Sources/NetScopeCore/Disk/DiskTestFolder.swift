import Foundation

// Sécurité du test de vitesse des disques : NetScope n'écrit que dans un sous-dossier
// « NetScope-test » de l'emplacement, n'y crée que des fichiers « netscope-essai-….bin », et ne
// supprime que ceux-là (puis le dossier s'il est vide). Aucun autre fichier n'est jamais touché.
// Les dossiers d'essai en cours sont notés dans un petit fichier : s'il en reste après un arrêt
// brutal, ils sont nettoyés au lancement suivant.

public enum DiskTestFolder {
    public static let folderName = "NetScope-test"
    public static let filePrefix = "netscope-essai-"
    public static let fileExtension = "bin"

    public static func url(in parent: URL) -> URL {
        parent.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Nom d'un fichier d'essai : « netscope-essai-<identifiant>.bin ».
    public static func fileName(id: UUID = UUID()) -> String {
        filePrefix + id.uuidString.lowercased() + "." + fileExtension
    }

    /// Vrai pour un fichier créé par NetScope (et seulement ceux-là).
    public static func isTestFile(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix("." + fileExtension) && !name.contains("/")
            && name.count > filePrefix.count + fileExtension.count + 1
    }

    /// Crée le dossier d'essai (le parent doit déjà exister : on ne crée jamais un volume ou un
    /// dossier nuage manquant).
    public static func prepare(in parent: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DiskBenchmarkError.missingLocation(parent.path)
        }
        let folder = url(in: parent)
        // Reste d'un essai précédent : on le nettoie ; un lien symbolique n'est jamais suivi.
        if let type = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType {
            guard type == .typeDirectory else { throw DiskBenchmarkError.unsafeFolder(folder.path) }
            cleanup(in: parent)
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: nil)
        return folder
    }

    /// Résultat d'un nettoyage.
    public struct Cleanup: Equatable, Sendable {
        /// Fichiers d'essai supprimés.
        public var removedFiles: Int = 0
        /// Le dossier « NetScope-test » a été supprimé (il était vide après nettoyage).
        public var removedFolder = false
        /// Autres éléments trouvés dans le dossier, laissés en place.
        public var keptItems: [String] = []

        public init(removedFiles: Int = 0, removedFolder: Bool = false, keptItems: [String] = []) {
            self.removedFiles = removedFiles
            self.removedFolder = removedFolder
            self.keptItems = keptItems
        }
    }

    /// Supprime les fichiers d'essai de « NetScope-test » dans `parent`, puis le dossier s'il est
    /// vide. Ne descend jamais dans un sous-dossier et ne suit aucun lien.
    @discardableResult
    public static func cleanup(in parent: URL) -> Cleanup {
        let folder = url(in: parent)
        var result = Cleanup()
        var isDirectory: ObjCBool = false
        // Lien symbolique à la place du dossier : on n'y touche pas.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            result.keptItems = [folderName]
            return result
        }
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return result
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            let item = folder.appendingPathComponent(name)
            let type = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType
            if isTestFile(name), type == .typeRegular {
                if (try? FileManager.default.removeItem(at: item)) != nil { result.removedFiles += 1 } else { result.keptItems.append(name) }
            } else {
                result.keptItems.append(name)
            }
        }
        // rmdir échoue sur un dossier non vide : rien d'autre ne peut être supprimé.
        if result.keptItems.isEmpty, rmdir(folder.path) == 0 { result.removedFolder = true }
        return result
    }
}

/// Dossiers d'essai en cours, notés pour un nettoyage au lancement suivant (arrêt brutal).
public final class DiskPendingCleanup: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// ~/Library/Application Support/NetScope/disques-en-cours.json
    public static var standard: DiskPendingCleanup {
        DiskPendingCleanup(url: DiskHistoryStore.supportDirectory.appendingPathComponent("disques-en-cours.json"))
    }

    public func entries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    public func add(_ parent: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = read()
        guard !list.contains(parent) else { return }
        list.append(parent)
        write(list)
    }

    public func remove(_ parent: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0 != parent })
    }

    /// Nettoie les dossiers notés qui sont joignables ; ceux d'un volume absent restent notés.
    @discardableResult
    public func cleanAll() -> [String: DiskTestFolder.Cleanup] {
        var done: [String: DiskTestFolder.Cleanup] = [:]
        for parent in entries() {
            guard FileManager.default.fileExists(atPath: parent) else { continue }
            done[parent] = DiskTestFolder.cleanup(in: URL(fileURLWithPath: parent, isDirectory: true))
            remove(parent)
        }
        return done
    }

    private func read() -> [String] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private func write(_ list: [String]) {
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }
}
