import Foundation

/// Un fichier de la file des transferts : envoi (Mac → serveur) ou réception (serveur → Mac).
public struct TransferJob: Identifiable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case upload, download

        public var label: String { self == .upload ? "Envoi" : "Réception" }
        public var symbol: String { self == .upload ? "arrow.up" : "arrow.down" }
    }

    public enum State: Hashable, Sendable {
        case waiting
        case running
        /// Coupure : reprise automatique prévue (essai n°).
        case retrying(attempt: Int)
        case paused
        case done
        case failed(String)
        case cancelled

        public var label: String {
            switch self {
            case .waiting: return "En attente"
            case .running: return "En cours"
            case .retrying(let attempt): return "Reprise (essai \(attempt))"
            case .paused: return "En pause"
            case .done: return "Terminé"
            case .failed: return "Échec"
            case .cancelled: return "Annulé"
            }
        }

        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }

        public var isActive: Bool {
            switch self {
            case .running, .retrying: return true
            default: return false
            }
        }
    }

    public let id: UUID
    public var direction: Direction
    public var localURL: URL
    public var remotePath: String
    /// Taille totale (nil : inconnue).
    public var totalBytes: Int64?
    /// Octets présents à l'arrivée (reprise comprise).
    public var transferredBytes: Int64
    public var state: State
    /// Débit lissé (octets par seconde).
    public var bytesPerSecond: Double?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Nombre de reprises après coupure.
    public var attempts: Int

    public init(id: UUID = UUID(), direction: Direction, localURL: URL, remotePath: String, totalBytes: Int64?,
                transferredBytes: Int64 = 0, state: State = .waiting, bytesPerSecond: Double? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil, attempts: Int = 0) {
        self.id = id
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.state = state
        self.bytesPerSecond = bytesPerSecond
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempts = attempts
    }

    /// Nom du fichier.
    public var name: String { direction == .upload ? localURL.lastPathComponent : RemotePath.name(remotePath) }

    /// Avancement de 0 à 1 (nil si la taille est inconnue).
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .done ? 1 : nil }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }

    /// Temps restant estimé (secondes).
    public var remainingSeconds: Double? {
        guard let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, totalBytes - transferredBytes)) / bytesPerSecond
    }

    /// « 4,2 Mo sur 18 Mo ».
    public var progressLabel: String {
        let done = FileTransferFormat.size(transferredBytes)
        guard let totalBytes else { return done }
        return "\(done) sur \(FileTransferFormat.size(totalBytes))"
    }

    /// Débit moyen d'un transfert terminé.
    public var averageRate: Double? {
        guard let startedAt, let finishedAt, finishedAt > startedAt else { return nil }
        return Double(transferredBytes) / finishedAt.timeIntervalSince(startedAt)
    }
}

/// Débit lissé (moyenne glissante sur quelques secondes) à partir des octets transférés.
public struct TransferRateMeter: Sendable {
    private var samples: [(time: Date, bytes: Int64)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 4) {
        self.window = window
    }

    /// Ajoute une mesure ; renvoie le débit (octets/s) ou nil s'il manque du recul.
    public mutating func record(bytes: Int64, at time: Date = Date()) -> Double? {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((time, bytes))
        samples.removeAll { time.timeIntervalSince($0.time) > window }
        guard let first = samples.first, let last = samples.last, last.time.timeIntervalSince(first.time) >= 0.4 else { return nil }
        return Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
    }
}

/// Règles de reprise : combien d'essais, quel délai.
public enum TransferRetryPolicy {
    public static let maxAttempts = 3

    /// Délai avant l'essai `attempt` (1, 2, 3) : 2 s, 5 s, 10 s.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        [2, 5, 10][min(max(attempt, 1), 3) - 1]
    }

    /// Faut-il reprendre automatiquement après cette erreur ?
    public static func shouldRetry(_ error: Error, attempts: Int) -> Bool {
        guard attempts < maxAttempts else { return false }
        return (error as? FileTransferError)?.isResumable ?? false
    }
}

/// Envoi d'un dossier entier : fichiers à envoyer et dossiers à créer, chemins distants calculés.
public enum TransferPlanner {
    public struct UploadItem: Hashable, Sendable {
        public var localURL: URL
        public var remotePath: String
        public var isDirectory: Bool
        public var size: Int64?
    }

    /// Parcourt `localURL` (fichier ou dossier) ; les fichiers cachés et les liens sont ignorés.
    public static func uploadItems(_ localURL: URL, into remoteDirectory: String,
                                   fileManager: FileManager = .default) -> [UploadItem] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else { return [] }
        let root = RemotePath.join(remoteDirectory, RemotePath.safeLocalName(localURL.lastPathComponent))
        guard isDirectory.boolValue else {
            let size = (try? fileManager.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber
            return [UploadItem(localURL: localURL, remotePath: root, isDirectory: false, size: size?.int64Value)]
        }
        var items = [UploadItem(localURL: localURL, remotePath: root, isDirectory: true, size: nil)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: localURL, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return items }
        let basePath = localURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/") else { continue }
            let relative = String(path.dropFirst(basePath.count + 1))
            let remote = relative.split(separator: "/").reduce(root) { RemotePath.join($0, String($1)) }
            items.append(UploadItem(localURL: url, remotePath: remote, isDirectory: values?.isDirectory == true,
                                    size: (values?.fileSize).map(Int64.init)))
        }
        return items
    }

    /// Nom libre dans un dossier : « config.cfg » → « config (2).cfg » si le nom est pris.
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }
}
