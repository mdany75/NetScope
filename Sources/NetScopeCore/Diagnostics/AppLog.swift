import Foundation

/// Niveau d'une entrée du journal de l'app (note 35).
public enum AppLogLevel: String, Codable, CaseIterable, Comparable, Sendable, Identifiable {
    case info, warning, error

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Avertissement"
        case .error: return "Erreur"
        }
    }

    /// Mot court du fichier journal (« INFO », « AVERT », « ERREUR »).
    public var fileKeyword: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "AVERT"
        case .error: return "ERREUR"
        }
    }

    init?(fileKeyword: String) {
        guard let level = AppLogLevel.allCases.first(where: { $0.fileKeyword == fileKeyword }) else { return nil }
        self = level
    }

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Entrée du journal : date, niveau, module (« FortiGate », « SNMP », « Sauvegarde »…) et message
/// déjà masqué.
public struct AppLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: AppLogLevel
    public var module: String
    public var message: String

    public init(id: UUID = UUID(), date: Date, level: AppLogLevel, module: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.module = module
        self.message = message
    }

    // MARK: Ligne du fichier

    /// « 2026-11-05T14:02:05.120-05:00<TAB>ERREUR<TAB>FortiGate<TAB>message » ; les retours à la ligne
    /// et tabulations du message sont échappés (\n, \t, \\).
    public var fileLine: String {
        [AppLogEntry.dateFormatter.string(from: date), level.fileKeyword, AppLogEntry.escape(module), AppLogEntry.escape(message)]
            .joined(separator: "\t")
    }

    /// Relit une ligne écrite par `fileLine` (nil si elle est illisible).
    public init?(fileLine line: String) {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let date = AppLogEntry.dateFormatter.date(from: parts[0]),
              let level = AppLogLevel(fileKeyword: parts[1]) else { return nil }
        self.init(date: date, level: level, module: AppLogEntry.unescape(parts[2]), message: AppLogEntry.unescape(parts[3]))
    }

    /// Texte lisible d'une entrée (copie, export) : « 5 nov. 2026 14:02:05 · Erreur · FortiGate · … ».
    public var displayLine: String {
        "\(fileLine.split(separator: "\t").first ?? "")  \(level.label.uppercased())  [\(module)]  \(message)"
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Journal de l'app (note 35), sûr entre fils : tampon circulaire en mémoire (les dernières
/// `capacity` entrées) et, si un dossier est donné, fichier tournant. Chaque message passe par
/// `SecretMasker` AVANT d'être gardé ou écrit : aucun secret n'atteint le disque.
public final class AppLog: @unchecked Sendable {
    /// Journal de l'application. Sans `configure`, il ne garde les entrées qu'en mémoire.
    public static let shared = AppLog()

    public static let defaultCapacity = 5_000

    private let lock = NSLock()
    private var buffer: [AppLogEntry?]
    /// Position de la prochaine écriture dans `buffer`.
    private var head = 0
    private var count = 0
    private var file: AppLogFile?
    private var observers: [UUID: @Sendable (AppLogEntry?) -> Void] = [:]
    /// Horloge (fixe dans les tests).
    private let now: @Sendable () -> Date

    public let capacity: Int

    public init(capacity: Int = AppLog.defaultCapacity, file: AppLogFile? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        buffer = Array(repeating: nil, count: max(1, capacity))
        self.file = file
        self.now = now
    }

    /// Branche le fichier tournant et recharge en mémoire les dernières entrées des fichiers
    /// (erreurs d'avant un redémarrage ou d'un plantage).
    public func configure(file: AppLogFile, reload: Bool = true) {
        let previous = reload ? file.readEntries(limit: capacity) : []
        lock.lock()
        self.file = file
        let current = orderedLocked()
        resetLocked()
        for entry in (previous + current).suffix(capacity) { appendLocked(entry) }
        lock.unlock()
        notify(nil)
    }

    // MARK: Écriture

    @discardableResult public func info(_ module: String, _ message: String) -> AppLogEntry { log(.info, module, message) }
    @discardableResult public func warning(_ module: String, _ message: String) -> AppLogEntry { log(.warning, module, message) }
    @discardableResult public func error(_ module: String, _ message: String) -> AppLogEntry { log(.error, module, message) }

    /// Ajoute une entrée ; le message est masqué ici, avant toute mémorisation.
    @discardableResult
    public func log(_ level: AppLogLevel, _ module: String, _ message: String, date: Date? = nil) -> AppLogEntry {
        let entry = AppLogEntry(date: date ?? now(), level: level,
                                module: SecretMasker.mask(module.trimmingCharacters(in: .whitespacesAndNewlines)),
                                message: SecretMasker.mask(message.trimmingCharacters(in: .whitespacesAndNewlines)))
        lock.lock()
        appendLocked(entry)
        let file = self.file
        lock.unlock()
        file?.append(entry)
        notify(entry)
        return entry
    }

    /// Remet des entrées déjà connues (démonstration) : masquées elles aussi, jamais écrites.
    public func seed(_ entries: [AppLogEntry]) {
        lock.lock()
        for var entry in entries {
            entry.message = SecretMasker.mask(entry.message)
            appendLocked(entry)
        }
        lock.unlock()
        notify(nil)
    }

    // MARK: Lecture

    /// Entrées du tampon, de la plus ancienne à la plus récente.
    public var entries: [AppLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return orderedLocked()
    }

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Nombre d'entrées d'au moins `level` depuis `date`.
    public func count(atLeast level: AppLogLevel, since date: Date) -> Int {
        entries.filter { $0.level >= level && $0.date >= date }.count
    }

    /// Vide le tampon et les fichiers.
    public func clear() {
        lock.lock()
        resetLocked()
        let file = self.file
        lock.unlock()
        file?.removeAll()
        notify(nil)
    }

    /// Texte du journal (une ligne par entrée, la plus ancienne d'abord), masqué une seconde fois.
    public func exportText(_ entries: [AppLogEntry]? = nil) -> String {
        let list = entries ?? self.entries
        return list.map { SecretMasker.mask($0.displayLine) }.joined(separator: "\n") + (list.isEmpty ? "" : "\n")
    }

    // MARK: Observateurs

    /// `handler` reçoit chaque nouvelle entrée (nil : rechargement ou effacement), sur le fil de
    /// l'écriture. Renvoie un jeton pour `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping @Sendable (AppLogEntry?) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    private func notify(_ entry: AppLogEntry?) {
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        for handler in handlers { handler(entry) }
    }

    // MARK: Tampon circulaire (verrou tenu)

    private func appendLocked(_ entry: AppLogEntry) {
        buffer[head] = entry
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    private func orderedLocked() -> [AppLogEntry] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { buffer[(start + $0) % capacity] }
    }

    private func resetLocked() {
        buffer = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}
