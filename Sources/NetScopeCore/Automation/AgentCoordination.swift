import Darwin
import Foundation

// Note 64 : agent sans fenêtre (NetScopeAgent, LaunchAgent enregistré par SMAppService) qui fait
// tourner les sondes de Surveillance, le récepteur Syslog et les scans planifiés quand l'app est
// fermée. L'app reste l'interface et reprend la main dès qu'elle est ouverte :
//
// - l'app écrit app-ouverte.json (son pid, rafraîchi toutes les 30 s) AVANT de lire ses fichiers,
//   puis prend et rend le verrou automatique.verrou : une écriture de l'agent déjà commencée se termine,
//   et aucune autre ne suivra ;
// - l'agent n'écrit QUE sous ce verrou, après avoir vérifié (sous le verrou) que l'app n'est pas ouverte ;
// - l'état de l'agent (agent-etat.json) et son journal (agent-journal.json) sont lus par Réglages ›
//   Surveillance ; ses réglages (agent-reglages.json) y sont écrits.
//
// Rien de tout cela ne démarre en démonstration, pendant les captures ni dans les tests.

/// Emplacements des fichiers partagés par l'app et l'agent.
public struct AutomationFiles: Sendable, Hashable {
    public static let agentLabel = "com.danymenard.netscope.agent"
    public static let agentPlistName = "com.danymenard.netscope.agent.plist"
    public static let appBundleID = "com.danymenard.netscope"

    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static var standard: AutomationFiles { AutomationFiles(base: SiteFiles.standard.base) }

    public var lockURL: URL { base.appendingPathComponent("automatique.verrou") }
    public var presenceURL: URL { base.appendingPathComponent("app-ouverte.json") }
    public var agentStatusURL: URL { base.appendingPathComponent("agent-etat.json") }
    public var agentJournalURL: URL { base.appendingPathComponent("agent-journal.json") }
    public var agentSettingsURL: URL { base.appendingPathComponent("agent-reglages.json") }
    public var monitorURL: URL { base.appendingPathComponent("surveillance.json") }
    public var logsURL: URL { base.appendingPathComponent("journaux.json") }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - Verrou

/// Verrou entre processus (flock sur un fichier) : l'app et l'agent n'écrivent jamais en même temps.
public enum AutomationLock {
    /// Exécute `body` sous le verrou ; nil si le verrou n'a pas pu être pris dans le délai.
    public static func with<T>(_ url: URL, timeout: TimeInterval = 10, _ body: () throws -> T) rethrows -> T? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
            usleep(50_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// MARK: - Présence de l'app

/// L'app ouverte : son pid et la dernière fois qu'elle l'a dit.
public struct AppPresence: Codable, Equatable, Sendable {
    /// Au-delà, une présence qui n'est plus rafraîchie ne compte plus (app tuée, Mac en veille).
    public static let staleAfter: TimeInterval = 120

    public var pid: Int32
    public var date: Date
    public var version: String

    public init(pid: Int32, date: Date, version: String) {
        self.pid = pid
        self.date = date
        self.version = version
    }

    /// Vrai si l'app est ouverte : présence récente et processus vivant.
    public static func isActive(_ presence: AppPresence?, now: Date, alive: (Int32) -> Bool = AppPresence.processAlive) -> Bool {
        guard let presence else { return false }
        guard now.timeIntervalSince(presence.date) < staleAfter else { return false }
        return alive(presence.pid)
    }

    public static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func load(_ files: AutomationFiles) -> AppPresence? {
        AutomationFiles.read(AppPresence.self, from: files.presenceURL)
    }

    public func save(_ files: AutomationFiles) {
        try? AutomationFiles.write(self, to: files.presenceURL)
    }

    /// À la fermeture de l'app : l'agent reprend la main à son prochain passage.
    public static func clear(_ files: AutomationFiles, pid: Int32) {
        guard let current = load(files), current.pid == pid else { return }
        try? FileManager.default.removeItem(at: files.presenceURL)
    }
}

// MARK: - Agent

/// Réglages de l'agent, écrits par l'app (Réglages › Surveillance).
public struct AgentSettings: Codable, Equatable, Sendable {
    public var monitor: Bool
    public var syslog: Bool
    public var scans: Bool

    public init(monitor: Bool = true, syslog: Bool = true, scans: Bool = true) {
        self.monitor = monitor
        self.syslog = syslog
        self.scans = scans
    }

    public static func load(_ files: AutomationFiles) -> AgentSettings {
        AutomationFiles.read(AgentSettings.self, from: files.agentSettingsURL) ?? AgentSettings()
    }

    public func save(_ files: AutomationFiles) throws {
        try AutomationFiles.write(self, to: files.agentSettingsURL)
    }
}

/// Ce que fait l'agent en ce moment.
public enum AgentMode: String, Codable, Sendable {
    /// L'app est ouverte : l'agent attend, sans rien écrire.
    case standby
    /// L'app est fermée : l'agent surveille.
    case active

    public var label: String { self == .standby ? "En attente (NetScope est ouvert)" : "Actif (NetScope est fermé)" }
}

/// État de l'agent, écrit par lui toutes les quelques secondes.
public struct AgentStatus: Codable, Equatable, Sendable {
    /// Au-delà, l'agent ne répond plus (arrêté, ou Mac en veille).
    public static let staleAfter: TimeInterval = 60

    public var pid: Int32
    public var version: String
    public var startedAt: Date
    public var heartbeat: Date
    public var mode: AgentMode
    public var probes: Int
    public var syslogPort: UInt16?
    public var syslogError: String?
    public var nextScan: Date?
    public var scanning: String?

    public init(pid: Int32, version: String, startedAt: Date, heartbeat: Date, mode: AgentMode, probes: Int = 0,
                syslogPort: UInt16? = nil, syslogError: String? = nil, nextScan: Date? = nil, scanning: String? = nil) {
        self.pid = pid
        self.version = version
        self.startedAt = startedAt
        self.heartbeat = heartbeat
        self.mode = mode
        self.probes = probes
        self.syslogPort = syslogPort
        self.syslogError = syslogError
        self.nextScan = nextScan
        self.scanning = scanning
    }

    public func isResponding(now: Date) -> Bool { now.timeIntervalSince(heartbeat) < Self.staleAfter }

    public static func load(_ files: AutomationFiles) -> AgentStatus? {
        AutomationFiles.read(AgentStatus.self, from: files.agentStatusURL)
    }

    public func save(_ files: AutomationFiles) {
        try? AutomationFiles.write(self, to: files.agentStatusURL)
    }
}

/// Une ligne du journal de l'agent.
public struct AgentJournalEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var text: String

    public init(id: UUID = UUID(), date: Date, level: Level = .info, text: String) {
        self.id = id
        self.date = date
        self.level = level
        self.text = text
    }
}

/// Journal de l'agent (du plus récent au plus ancien, plafonné).
public struct AgentJournal: Codable, Equatable, Sendable {
    public static let maxEntries = 300

    public var entries: [AgentJournalEntry]

    public init(entries: [AgentJournalEntry] = []) {
        self.entries = entries
    }

    public mutating func add(_ entry: AgentJournalEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    public static func load(_ files: AutomationFiles) -> AgentJournal {
        AutomationFiles.read(AgentJournal.self, from: files.agentJournalURL) ?? AgentJournal()
    }

    public func save(_ files: AutomationFiles) {
        try? AutomationFiles.write(self, to: files.agentJournalURL)
    }
}

// MARK: - Sondes en arrière-plan

/// Sondes de Surveillance exécutées par l'agent : celles qui n'ont besoin que du réseau (ping, TCP,
/// HTTP, DNS). Les autres (SNMP, FortiGate, inventaire, journaux, services en ligne) attendent l'app :
/// leurs secrets et leurs lectures vivent dans l'interface.
public enum MonBackground {
    public static let supportedKinds: Set<MonProbeKind> = [.ping, .tcp, .http, .dns]

    public static func supports(_ probe: MonProbe) -> Bool { probe.isEnabled && supportedKinds.contains(probe.kind) }

    /// Applique le résultat d'une sonde à l'archive de Surveillance (suivi, historique, journal), comme
    /// l'app. Renvoie les alertes créées et vrai si une alerte a été refermée (retour à la normale).
    public static func apply(_ outcome: MonRunOutcome, probe id: UUID, archive: inout MonArchive, site: UUID?,
                             calendar: Calendar = .current) -> (alerts: [MonAlert], recovered: Bool) {
        guard !outcome.noData, let index = archive.probes.firstIndex(where: { $0.id == id }) else { return ([], false) }
        if let threats = outcome.knownThreats { archive.probes[index].knownThreats = threats }
        if let location = outcome.learnedLocation, archive.probes[index].expectedLocation == nil {
            archive.probes[index].expectedLocation = location
        }
        if let macs = outcome.knownMACs { archive.probes[index].knownMACs = macs }
        let probe = archive.probes[index]
        let key = id.uuidString
        let dependencyDown = probe.dependsOn.map { archive.trackers[$0.uuidString]?.state == .down } ?? false
        let gate = archive.planning.gate(probe: id, site: site, at: outcome.result.date, calendar: calendar)
        guard let step = MonStateMachine.step(probe: probe, tracker: archive.trackers[key] ?? MonTracker(), outcome: outcome,
                                              dependencyDown: dependencyDown, calendar: calendar, gate: gate) else { return ([], false) }
        archive.trackers[key] = step.tracker
        archive.history.record(probe: id, result: outcome.result, state: step.tracker.state, interval: probe.interval,
                               inMaintenance: gate.maintenance != nil)
        let openBefore = archive.journal.openCount(probe: id)
        let created = archive.journal.record(step.events, probe: probe, date: outcome.result.date)
        let recovered = step.events.contains { $0.kind == .recovered } && archive.journal.openCount(probe: id) < openBefore
        return (created, recovered)
    }
}
