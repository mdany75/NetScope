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
    var display = RemoteDisplaySettings.defaults(for: .ssh)
    /// Taille personnalisée saisie (texte du champ).
    var customWidth = "1600"
    var customHeight = "1000"

    init() {}

    /// Change de protocole ; l'affichage reprend les valeurs par défaut du nouveau protocole s'il
    /// n'avait pas été modifié.
    mutating func switchProtocol(to option: RemoteProtocol) {
        if display == .defaults(for: proto) { display = .defaults(for: option) }
        proto = option
    }

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
        display = connection.display
        customWidth = String(connection.display.customWidth)
        customHeight = String(connection.display.customHeight)
    }

    /// Connexion validée, ou erreur à afficher.
    func connection(existing: RemoteConnection?) throws -> RemoteConnection {
        guard var portValue = Int(port.trimmingCharacters(in: .whitespaces)) else {
            throw RemoteValidationError.invalidPort(0)
        }
        // Note 52 : « admin@10.0.0.2 » ou « admin@10.0.0.2:2222 » accepté dans le champ Hôte.
        var host = self.host
        var username = self.username
        if proto != .serie, host.contains("@") || host.contains("://") {
            let address = try QuickLoginAddress.parse(host)
            host = address.host
            if !address.user.isEmpty { username = address.user }
            if let port = address.port { portValue = port }
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
        // Taille personnalisée lue seulement si ses champs sont affichés (RDP, fenêtre, personnalisée).
        let display = try display.applyingCustomSize(width: customWidth, height: customHeight, for: proto)
        connection.display = display
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
    /// Recherche de la barre d'outils (note 26), appliquée en plus de celle de la colonne.
    @Published var toolbarSearch = ""

    /// Connexion retenue par les deux recherches (moteur commun : `proto:ssh dossier:Réseau`…).
    func isVisible(_ connection: RemoteConnection) -> Bool {
        connection.matches(searchText) && connection.matches(toolbarSearch)
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !toolbarSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }
    @Published var collapsedGroups: Set<String> = []
    @Published private(set) var reachability: [UUID: RemoteReachability] = [:]
    @Published private(set) var lastCheck: Date?
    @Published var draft: RemoteDraft?
    @Published var draftError: String?
    @Published var showImport = false
    /// Panneau de détails ouvert en grande fenêtre (ouvert par défaut).
    @Published var showDetails = true
    /// Panneau de détails ouvert en petite fenêtre : replié par défaut, car il prend alors la place
    /// de la zone des sessions (trois colonnes ne tiennent pas côte à côte).
    @Published var showDetailsCompact = false
    /// Petite fenêtre (mesurée par l'écran).
    @Published var compactLayout = false
    @Published var toast: String?
    @Published var pendingDeletion: RemoteConnection?
    @Published private(set) var serialPorts: [String] = []

    private let store: RemoteConnectionStore?
    /// Passage en plein écran de Partage d'écran en attente, un seul par connexion.
    private var fullScreenTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("--demo")
        store = (demo || arguments.contains("--snapshot")) ? nil : RemoteConnectionStore.standard
        if demo {
            connections = RemoteDemo.connections
            reachability = RemoteDemo.reachability(for: connections)
            // Vérification juste après la connexion la plus récente de la démonstration (il y a 6 min).
            lastCheck = Date().addingTimeInterval(-60)
            selectedID = connections.first?.id
        } else {
            connections = store?.load() ?? []
            selectedID = connections.first?.id
        }
        serialPorts = RemoteSerialPorts.list()
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            if raw == "nouveau" { draft = RemoteDraft() }
            if raw == "import" { showImport = true }
            // Captures : connexion RDP choisie, ou son formulaire de modification.
            if ["rdp", "vnc", "modifier-rdp", "modifier-vnc"].contains(raw) {
                let proto: RemoteProtocol = raw.hasSuffix("vnc") ? .vnc : .rdp
                selectedID = connections.first { $0.proto == proto }?.id
                if raw.hasPrefix("modifier") { startEditing() }
            }
            // Captures : connexion Telnet choisie (encadré « Installer » de telnet).
            if raw == "telnet" { selectedID = connections.first { $0.proto == .telnet }?.id }
        }
    }

    /// Panneau de détails visible, selon la taille de la fenêtre.
    var detailsVisible: Bool {
        get { compactLayout ? showDetailsCompact : showDetails }
        set {
            if compactLayout { showDetailsCompact = newValue } else { showDetails = newValue }
        }
    }

    /// Nom de ce Mac dans l'invite du terminal ; celui du croquis en démonstration.
    var localHostName: String {
        ProcessInfo.processInfo.arguments.contains("--demo") ? "Macmini-de-Dany" : speedLocalHostName
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
        let visible = connections.filter(isVisible)
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
        draft.switchProtocol(to: proto)
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

    /// Note 52 : connexion rapide ouverte par la feuille. `originID` : connexion du carnet d'où
    /// elle vient (enregistrée sans utilisateur) ; elle est mise à jour (date, et nom d'utilisateur
    /// si « Enregistrer dans le carnet » est coché) tant que l'hôte et le port sont les siens.
    /// Sinon, avec la case cochée, la connexion de même protocole, hôte, port ET utilisateur (ou
    /// sans utilisateur) est mise à jour ; à défaut, une nouvelle est ajoutée : jamais une
    /// connexion « root » ne devient « admin » en silence.
    @discardableResult
    func saveQuickConnection(_ connection: RemoteConnection, originID: UUID? = nil, saveToBook: Bool = true) -> Bool {
        guard let valid = try? connection.validated() else { return false }
        let sameEndpoint: (RemoteConnection) -> Bool = { $0.proto == valid.proto && $0.host == valid.host && $0.port == valid.port }
        if let originID, let index = connections.firstIndex(where: { $0.id == originID && sameEndpoint($0) }) {
            if saveToBook { connections[index].username = valid.username }
            connections[index].lastConnected = Date()
        } else if !saveToBook {
            return false
        } else if let index = connections.firstIndex(where: { sameEndpoint($0) && $0.username == valid.username })
                    ?? connections.firstIndex(where: { sameEndpoint($0) && $0.username.isEmpty }) {
            connections[index].username = valid.username
            connections[index].lastConnected = Date()
        } else {
            var added = valid
            added.lastConnected = Date()
            connections.append(added)
        }
        save()
        return true
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

    /// Ouvre la connexion ; `mode` : choix rapide du bouton « Connecter » (fenêtre ou plein
    /// écran pour cette fois seulement, sans changer la connexion enregistrée).
    func connect(_ connection: RemoteConnection, mode: RemoteDisplayMode? = nil) {
        // Note 52 : connexion SSH ou Telnet du carnet sans utilisateur : le nom est demandé.
        if [.ssh, .telnet].contains(connection.proto), connection.username.trimmingCharacters(in: .whitespaces).isEmpty {
            QuickLoginModel.shared.ask(QuickLoginTarget(connection: connection))
            return
        }
        var target = connection
        if let mode { target.display = connection.display.with(mode: mode) }
        do {
            let plan = try RemoteLauncher.plan(for: target)
            let wantsFullScreen = target.proto == .vnc && target.display.mode == .fullScreen
            let note = target.proto == .vnc ? prepareScreenSharing(target) : ""
            let before = wantsFullScreen ? RemoteScreenSharingControl.snapshot() : nil
            try RemoteExecutor.execute(plan, title: target.name)
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index].lastConnected = Date()
                save()
            }
            toast = "Ouverture dans \(plan.appName)\u{00A0}: \(target.name)\(note)."
            fullScreenTasks[connection.id]?.cancel()
            fullScreenTasks[connection.id] = nil
            if let before, RemoteScreenSharingControl.isTrusted(prompt: false) {
                let id = connection.id, host = target.host, name = target.name
                fullScreenTasks[id] = Task {
                    let outcome = await RemoteScreenSharingControl.enterFullScreen(host: host, name: name, before: before)
                    // Une tâche remplacée (nouveau clic) ne touche plus à rien.
                    guard !Task.isCancelled else { return }
                    self.fullScreenTasks[id] = nil
                    if outcome == .timedOut {
                        self.toast = "Plein écran non appliqué à « \(name) »\u{00A0}: utilisez Présentation › Passer en plein écran dans Partage d’écran."
                    }
                }
            }
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Échelle de Partage d'écran et autorisation d'accessibilité pour le plein écran ;
    /// renvoie un complément au message d'ouverture.
    private func prepareScreenSharing(_ connection: RemoteConnection) -> String {
        RemoteScreenSharingControl.applyScale(connection.display.vncScale)
        guard connection.display.mode == .fullScreen else { return "" }
        if RemoteScreenSharingControl.isTrusted(prompt: true) {
            return " (plein écran après l’identification)"
        }
        return ", en fenêtre\u{00A0}: pour le plein écran, autorisez NetScope dans Réglages Système › Confidentialité et sécurité › Accessibilité"
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
            case .noApplication(let kind):
                let hint = kind.contains(".rdp") ? " Installez Windows App depuis le Mac App Store." : ""
                return "Aucune application installée pour ouvrir \(kind).\(hint)"
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
            guard workspace.urlForApplication(toOpen: url) != nil else { throw Failure.noApplication(url.scheme.map { "les adresses \($0)://" } ?? "cette adresse") }
            workspace.open(url)
        }
    }
}
