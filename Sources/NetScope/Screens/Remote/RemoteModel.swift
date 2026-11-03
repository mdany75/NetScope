import AppKit
import Foundation
import NetScopeCore
import SwiftUI

/// Joignabilité d'une connexion (sonde TCP à la demande).
enum RemoteReachability: Equatable {
    case unknown, checking, reachable, unreachable
}

/// Formulaire de création ou de modification.
struct RemoteDraft: Equatable {
    var editingID: UUID?
    var name = ""
    var proto: RemoteProtocol = .ssh
    var host = ""
    var port = "22"
    var username = ""
    var folder = ""
    var note = ""
    var isFavorite = false

    init() {}

    init(_ connection: RemoteConnection) {
        editingID = connection.id
        name = connection.name
        proto = connection.proto
        host = connection.host
        port = String(connection.port)
        username = connection.username
        folder = connection.folder
        note = connection.note
        isFavorite = connection.isFavorite
    }

    /// Connexion validée, ou erreur à afficher.
    func connection(existing: RemoteConnection?) throws -> RemoteConnection {
        guard let portValue = Int(port.trimmingCharacters(in: .whitespaces)) else {
            throw RemoteValidationError.invalidPort(0)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var connection = existing ?? RemoteConnection(name: "", proto: proto, host: "")
        connection.name = trimmedName.isEmpty ? host.trimmingCharacters(in: .whitespaces) : trimmedName
        connection.proto = proto
        connection.host = host
        connection.port = portValue
        connection.username = username
        connection.folder = folder
        connection.note = note
        connection.isFavorite = isFavorite
        return try connection.validated()
    }
}

/// État de l'écran Accès distant (instance unique, conservée entre les écrans).
@MainActor
final class RemoteModel: ObservableObject {
    static let shared = RemoteModel()

    @Published private(set) var connections: [RemoteConnection] = []
    @Published var selectedID: UUID?
    @Published var searchText = ""
    @Published var collapsedGroups: Set<String> = []
    @Published private(set) var reachability: [UUID: RemoteReachability] = [:]
    @Published private(set) var lastCheck: Date?
    @Published var draft: RemoteDraft?
    @Published var draftError: String?
    @Published var showImport = false
    @Published var showDetails = true
    @Published var toast: String?
    @Published var pendingDeletion: RemoteConnection?
    @Published private(set) var serialPorts: [String] = []

    private let store: RemoteConnectionStore?

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("--demo")
        store = (demo || arguments.contains("--snapshot")) ? nil : RemoteConnectionStore.standard
        if demo {
            connections = RemoteDemo.connections
            reachability = RemoteDemo.reachability(for: connections)
            lastCheck = Calendar.current.date(bySettingHour: 10, minute: 41, second: 0, of: Date())
            selectedID = connections.first?.id
        } else {
            connections = store?.load() ?? []
            selectedID = connections.first?.id
        }
        serialPorts = RemoteSerialPorts.list()
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            if raw == "nouveau" { draft = RemoteDraft() }
            if raw == "import" { showImport = true }
        }
    }

    var selected: RemoteConnection? {
        guard let selectedID else { return nil }
        return connections.first { $0.id == selectedID }
    }

    // MARK: Groupes

    struct RemoteGroup: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let items: [RemoteConnection]
    }

    /// Favoris, puis un groupe par dossier (ordre alphabétique, « Importés du scan » à la fin).
    var groups: [RemoteGroup] {
        let visible = connections.filter { $0.matches(searchText) }
        var result: [RemoteGroup] = []
        let favorites = visible.filter(\.isFavorite)
        if !favorites.isEmpty { result.append(RemoteGroup(id: "★", label: "Favoris", symbol: "star", items: favorites)) }
        let folders = Set(visible.map(\.folderLabel)).sorted { lhs, rhs in
            if lhs == RemoteImport.folder { return false }
            if rhs == RemoteImport.folder { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for folder in folders {
            let items = visible.filter { $0.folderLabel == folder }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.append(RemoteGroup(id: "dossier:" + folder, label: folder, symbol: RemoteModel.symbol(forFolder: folder, items: items), items: items))
        }
        return result
    }

    private static func symbol(forFolder folder: String, items: [RemoteConnection]) -> String {
        let lower = folder.lowercased()
        if folder == RemoteImport.folder { return "square.and.arrow.down" }
        if lower.contains("console") || items.allSatisfy({ $0.proto == .serie }) { return "cable.connector" }
        if lower.contains("serveur") { return "server.rack" }
        if lower.contains("poste") { return "desktopcomputer" }
        return "folder"
    }

    var folders: [String] {
        Set(connections.map(\.folder).filter { !$0.isEmpty } + ["Siège › Réseau", "Siège › Serveurs", "Siège › Postes", "Console"])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    // MARK: Modifications

    func toggleFavorite(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isFavorite.toggle()
        save()
    }

    func startNew(proto: RemoteProtocol = .ssh) {
        var draft = RemoteDraft()
        draft.proto = proto
        draft.port = String(proto.defaultPort)
        draft.folder = selected?.folder ?? ""
        if proto == .serie { draft.host = serialPorts.first ?? "" }
        self.draft = draft
        draftError = nil
    }

    func startEditing() {
        guard let selected else { return }
        draft = RemoteDraft(selected)
        draftError = nil
    }

    func cancelDraft() {
        draft = nil
        draftError = nil
    }

    /// Enregistre le formulaire ; renvoie la connexion enregistrée.
    @discardableResult
    func commitDraft() -> RemoteConnection? {
        guard let draft else { return nil }
        let existing = draft.editingID.flatMap { id in connections.first { $0.id == id } }
        do {
            let connection = try draft.connection(existing: existing)
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index] = connection
                toast = "Connexion « \(connection.name) » enregistrée."
            } else {
                connections.append(connection)
                toast = "Connexion « \(connection.name) » ajoutée."
            }
            selectedID = connection.id
            self.draft = nil
            draftError = nil
            save()
            return connection
        } catch {
            draftError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func duplicateSelected() {
        guard let selected else { return }
        let copy = selected.duplicated()
        connections.append(copy)
        selectedID = copy.id
        toast = "Connexion dupliquée : \(copy.name)."
        save()
    }

    func delete(_ connection: RemoteConnection) {
        connections.removeAll { $0.id == connection.id }
        reachability[connection.id] = nil
        if selectedID == connection.id { selectedID = connections.first?.id }
        toast = "Connexion « \(connection.name) » supprimée."
        pendingDeletion = nil
        save()
    }

    // MARK: Import depuis le scan

    func importCandidates(from devices: [Device]) -> [RemoteImportCandidate] {
        RemoteImport.candidates(from: devices, existing: connections)
    }

    func add(_ candidate: RemoteImportCandidate) {
        guard !connections.contains(where: { $0.host == candidate.ip && $0.proto == candidate.proto }) else { return }
        let connection = candidate.connection()
        guard (try? connection.validated()) != nil else { return }
        connections.append(connection)
        save()
    }

    func addAll(_ candidates: [RemoteImportCandidate]) -> Int {
        var added = 0
        for candidate in candidates where !candidate.alreadySaved {
            let before = connections.count
            add(candidate)
            if connections.count > before { added += 1 }
        }
        if added > 0 { toast = "\(added) connexion\(added > 1 ? "s" : "") importée\(added > 1 ? "s" : "") du scan." }
        return added
    }

    // MARK: Joignabilité

    func state(of id: UUID) -> RemoteReachability { reachability[id] ?? .unknown }

    /// Sonde TCP de toutes les connexions (ou d'une seule), à la demande de l'utilisateur.
    func checkReachability(only id: UUID? = nil) {
        serialPorts = RemoteSerialPorts.list()
        let targets = connections.filter { id == nil || $0.id == id }
        for connection in targets { reachability[connection.id] = .checking }
        Task {
            await withTaskGroup(of: (UUID, Bool).self) { group in
                for connection in targets {
                    group.addTask { (connection.id, await RemoteProbe.check(connection, timeout: 2)) }
                }
                for await (id, ok) in group {
                    self.reachability[id] = ok ? .reachable : .unreachable
                }
            }
            self.lastCheck = Date()
        }
    }

    var reachableCount: Int { reachability.values.filter { $0 == .reachable }.count }

    // MARK: Connexion

    func plan(for connection: RemoteConnection) -> Result<RemoteLaunchPlan, Error> {
        Result { try RemoteLauncher.plan(for: connection) }
    }

    func connect(_ connection: RemoteConnection) {
        do {
            let plan = try RemoteLauncher.plan(for: connection)
            try RemoteExecutor.execute(plan, title: connection.name)
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index].lastConnected = Date()
                save()
            }
            toast = "Ouverture dans \(plan.appName) : \(connection.name)."
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshSerialPorts() {
        serialPorts = RemoteSerialPorts.list()
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(connections)
        } catch {
            NSLog("NetScope : enregistrement des connexions impossible : %@", error.localizedDescription)
        }
    }
}

/// Exécution d'un plan de lancement : Terminal, fichier .rdp ou URL.
enum RemoteExecutor {
    enum Failure: LocalizedError {
        case noApplication(String)
        case terminalMissing

        var errorDescription: String? {
            switch self {
            case .noApplication(let kind): return "Aucune application installée pour ouvrir \(kind). Installez Windows App depuis le Mac App Store."
            case .terminalMissing: return "Terminal est introuvable."
            }
        }
    }

    @MainActor
    static func execute(_ plan: RemoteLaunchPlan, title: String) throws {
        let workspace = NSWorkspace.shared
        switch plan {
        case .terminal(let command):
            // Fichier .command temporaire ouvert par Terminal : aucune autorisation d'automatisation requise.
            let name = "netscope-\(UUID().uuidString.prefix(8)).command"
            let url = try RemoteLauncher.writeTemporary(RemoteLauncher.commandFile(command: command, title: title),
                                                        fileName: name, executable: true)
            guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw Failure.terminalMissing
            }
            workspace.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .rdpFile(let contents, let fileName):
            let url = try RemoteLauncher.writeTemporary(contents, fileName: fileName)
            guard workspace.urlForApplication(toOpen: url) != nil else { throw Failure.noApplication("les fichiers .rdp") }
            workspace.open(url)
        case .url(let url):
            guard workspace.urlForApplication(toOpen: url) != nil else { throw Failure.noApplication(url.scheme ?? "cette adresse") }
            workspace.open(url)
        }
    }
}
