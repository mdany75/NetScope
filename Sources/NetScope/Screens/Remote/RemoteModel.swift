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
    /// Note 50 : réglages FTP, FTPS et SFTP.
    var transfer = FileTransferSettings()
    /// Mot de passe saisi (jamais enregistré ailleurs qu'au Trousseau) ; nil : inchangé.
    var password: String?
    /// Note 66 : hôtes de rebond (ProxyJump) et clé privée (IdentityFile), SSH seulement.
    var proxyJump = ""
    var identityFile = ""
    /// Note 6 : usager du poste RustDesk.
    var endUser = ""

    init() {}

    /// Change de protocole ; l'affichage reprend les valeurs par défaut du nouveau protocole s'il
    /// n'avait pas été modifié.
    mutating func switchProtocol(to option: RemoteProtocol) {
        if display == .defaults(for: proto) { display = .defaults(for: option) }
        proto = option
    }

    /// Port par défaut du protocole (FTPS : selon le TLS explicite ou implicite).
    var defaultPort: Int { proto == .ftps ? transfer.tlsMode.defaultPort : proto.defaultPort }

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
        transfer = connection.transfer
        proxyJump = connection.proxyJump
        identityFile = connection.identityFile
        endUser = connection.endUser
    }

    /// Connexion validée, ou erreur à afficher.
    func connection(existing: RemoteConnection?) throws -> RemoteConnection {
        guard var portValue = Int(port.trimmingCharacters(in: .whitespaces)) else {
            throw RemoteValidationError.invalidPort(0)
        }
        // Note 52 : « admin@10.0.0.2 » ou « admin@10.0.0.2:2222 » accepté dans le champ Hôte.
        var host = self.host
        var username = self.username
        if proto != .serie, proto != .rustdesk, host.contains("@") || host.contains("://") {
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
        if proto.isFileTransfer {
            var transfer = self.transfer
            transfer.remoteDirectory = transfer.remoteDirectory.trimmingCharacters(in: .whitespaces)
            if !transfer.remoteDirectory.isEmpty {
                transfer.remoteDirectory = RemotePath.normalize(try RemotePath.validate(transfer.remoteDirectory))
                if !transfer.remoteDirectory.hasPrefix("/") { transfer.remoteDirectory = "/" + transfer.remoteDirectory }
            }
            if proto == .sftp, transfer.sftpAuth == .key {
                _ = try QuickLogin.validateKeyPath(transfer.keyPath)
            }
            connection.transfer = transfer
        }
        // Note 66 : rebond et clé (validés avec la connexion ; retirés des autres protocoles).
        connection.proxyJump = proxyJump.trimmingCharacters(in: .whitespaces)
        connection.identityFile = identityFile.trimmingCharacters(in: .whitespaces)
        connection.endUser = endUser
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
    /// Note 66 : formulaire d'un tunnel SSH (onglet « Sessions »).
    @Published var tunnelDraft: SSHTunnelDraft?
    @Published var tunnelDraftError: String?
    @Published var showImport = false
    /// Note 78 : source de l'import (scan ou ~/.ssh/config).
    @Published var importSource: RemoteImportSource = .scan
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
            // Mots de passe SSH et Telnet au Trousseau : lus une fois, hors du rendu.
            let ids = connections.filter { [.ssh, .telnet].contains($0.proto) }.map(\.id)
            let rustdesk = connections.filter { $0.proto == .rustdesk }.map(\.id)
            DispatchQueue.main.async {
                RemoteSessionStore.shared.loadSavedPasswords(for: ids)
                RustDeskModel.shared.loadSavedPasswords(for: rustdesk)
            }
        }
        serialPorts = RemoteSerialPorts.list()
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            if raw == "nouveau" { draft = RemoteDraft() }
            if raw == "import" { showImport = true }
            // Note 78 : import de ~/.ssh/config (fichier fictif de la démonstration).
            if raw == "import-ssh" {
                showImport = true
                importSource = .sshConfig
            }
            // Note 66 : formulaire d'un tunnel, ou détails d'une connexion avec ses tunnels.
            if raw == "tunnel-nouveau", let bastion = connections.first(where: { $0.name.hasPrefix("Bastion") }) {
                selectedID = bastion.id
                tunnelDraft = SSHTunnelDemo.draft(connectionID: bastion.id)
            }
            if raw == "tunnels" { selectedID = connections.first { $0.name.hasPrefix("Bastion") }?.id ?? selectedID }
            // Note 57 : session VNC intégrée ouverte (bureau Windows dessiné, aucun réseau) ;
            // « vnc-mac » : celle du Mac mini du croquis ; « vnc-mdp » : demande du mot de passe.
            if ["vnc", "vnc-mac", "vnc-mdp"].contains(raw) {
                let target = connections.first { $0.proto == .vnc && (raw == "vnc-mac" ? $0.name != VNCDemo.windowsName : $0.name == VNCDemo.windowsName) }
                    ?? connections.first { $0.proto == .vnc }
                if let target {
                    selectedID = target.id
                    // Onglet de la barre des sessions, à côté des onglets de terminal de la démonstration.
                    if raw == "vnc-mdp" { VNCSessionStore.shared.open(target).showDemoCredentialsPrompt() }
                    RemoteSessionStore.shared.open(target)
                    showDetails = false
                }
            }
            // Captures : connexion RDP choisie, ou son formulaire de modification.
            if ["rdp", "modifier-rdp", "modifier-vnc", "vnc-externe"].contains(raw) {
                let proto: RemoteProtocol = raw.hasSuffix("vnc") || raw == "vnc-externe" ? .vnc : .rdp
                selectedID = connections.first { $0.proto == proto }?.id
                if raw.hasPrefix("modifier") { startEditing() }
            }
            // Captures : connexion Telnet choisie (encadré « Installer » de telnet).
            if raw == "telnet" { selectedID = connections.first { $0.proto == .telnet }?.id }
            // Note 50 : connexion FTP (avertissement), navigateur de fichiers ouvert, formulaire SFTP.
            if raw == "ftp" { selectedID = connections.first { $0.proto == .ftp }?.id }
            if raw == "fichiers" { selectedID = connections.first { $0.proto == .sftp }?.id }
            if raw == "fichiers-ftp" { selectedID = connections.first { $0.proto == .ftp }?.id }
            if raw == "modifier-sftp" {
                selectedID = connections.first { $0.proto == .sftp }?.id
                startEditing()
            }
        }
    }

    /// Note 50 : connexion de fichiers mise à jour depuis le navigateur (utilisateur saisi,
    /// certificat accepté, dossier du Mac) ; ajoutée au carnet si elle n'y est pas encore.
    /// Une session de fichiers ne renvoie que le champ qu'elle change, sur l'élément courant du
    /// carnet : les modifications faites entre-temps dans le panneau de détail sont gardées, et une
    /// connexion supprimée du carnet n'y revient jamais.
    func setTransferLocalDirectory(_ path: String, for id: UUID) {
        updateExisting(id) { $0.transfer.localDirectory = path }
    }

    func setTrustedCertificate(_ sha256: String, for id: UUID) {
        updateExisting(id) { $0.transfer.trustedCertificateSHA256 = sha256 }
    }

    func setTransferUsername(_ user: String, for id: UUID) {
        updateExisting(id) { $0.username = user }
    }

    /// Note 57 : débit choisi dans l'onglet de la console série (débits du carnet seulement).
    func setSerialBaud(_ baud: Int, for id: UUID) {
        guard RemoteValidator.baudRates.contains(baud) else { return }
        updateExisting(id) { $0.port = baud }
    }

    private func updateExisting(_ id: UUID, _ change: (inout RemoteConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        var updated = connections[index]
        change(&updated)
        guard updated != connections[index] else { return }
        connections[index] = updated
        save()
    }

    /// Note 50 : ouvre (ou crée dans le carnet) la connexion de fichiers d'un appareil, puis le
    /// navigateur dans Accès distant.
    func openFileTransfer(host: String, name: String, proto: RemoteProtocol, port: Int? = nil, state: AppState) {
        let existing = connections.first { $0.host == host && $0.proto == proto && (port == nil || $0.port == port) }
        var connection = existing ?? RemoteConnection(name: "\(name) · \(proto.label)", proto: proto, host: host, port: port,
                                                      folder: SiteModel.shared.activeSite?.displayName ?? RemoteImport.folder)
        if existing == nil {
            if proto == .ftps, port == nil || port == 990 { connection.transfer.tlsMode = .implicit }
            // Note 78 : SFTP : nom retenu pour l'appareil, son site ou son compte SSH.
            if proto == .sftp { connection.username = QuickLoginModel.shared.suggestedUser(proto: .sftp, host: host) }
            guard (try? connection.validated()) != nil else { return }
            connections.append(connection)
            save()
            toast = "Connexion «\u{00A0}\(connection.name)\u{00A0}» ajoutée au carnet."
        }
        selectedID = connection.id
        draft = nil
        state.open(.acces)
        connect(connection)
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
        draft.port = String(draft.defaultPort)
        draft.folder = selected?.folder ?? ""
        if proto == .serie { draft.host = serialPorts.first ?? "" }
        self.draft = draft
        draftError = nil
        tunnelDraft = nil
    }

    func startEditing() {
        guard let selected else { return }
        draft = RemoteDraft(selected)
        draftError = nil
        tunnelDraft = nil
    }

    func cancelDraft() {
        draft = nil
        draftError = nil
        tunnelDraft = nil
        tunnelDraftError = nil
    }

    /// Enregistre le formulaire ; renvoie la connexion enregistrée.
    @discardableResult
    func commitDraft() -> RemoteConnection? {
        guard let draft else { return nil }
        let existing = draft.editingID.flatMap { id in connections.first { $0.id == id } }
        do {
            let connection = try draft.connection(existing: existing)
            // Note 50 : mot de passe FTP, FTPS ou SFTP au Trousseau seulement.
            if connection.proto.isFileTransfer, let password = draft.password {
                try FileTransferStore.shared.setPassword(password, for: connection.id)
            }
            // Note 57 : mot de passe SSH ou Telnet au Trousseau seulement (vide : oublié).
            if [.ssh, .telnet].contains(connection.proto), let password = draft.password {
                try RemoteSessionStore.shared.setPassword(password, for: connection.id)
            }
            // Note 6 : mot de passe permanent RustDesk, au Trousseau seulement (vide : oublié).
            if connection.proto == .rustdesk, let password = draft.password {
                try RustDeskModel.shared.setPassword(password, for: connection.id)
            }
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
            // Les tunnels de cette connexion suivent le carnet : réglages SSH à jour au prochain
            // démarrage ; plus de SSH (ou redirection retirée) : tunnel arrêté et onglet fermé.
            syncTunnelSessions(with: connection)
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
        if connection.proto.isFileTransfer {
            if FileTransferStore.shared.session?.connection.id == connection.id { FileTransferStore.shared.close() }
            try? FileTransferStore.shared.setPassword("", for: connection.id)
        }
        // Note 57 : onglets de la connexion fermés (terminal ou VNC, plein écran compris),
        // mots de passe SSH, Telnet et VNC oubliés.
        RemoteSessionStore.shared.forget(connection.id)
        if connection.proto == .rustdesk { RustDeskModel.shared.forget(connection.id) }
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
        // Note 78 : un alias de ~/.ssh/config est sondé à son HostName.
        let config = SSHConfigCache.config
        // Note 6 : postes RustDesk désignés par leur ID : joints par le serveur d'ID, jamais sondés.
        let targets = connections.filter { (id == nil || $0.id == id) && !$0.isRustDeskByID }.map { connection -> RemoteConnection in
            guard connection.proto == .ssh, let hostName = config.resolve(connection.host).hostName,
                  let valid = try? RemoteValidator.validateHost(hostName) else { return connection }
            var probe = connection
            probe.host = valid
            return probe
        }
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
        // Captures et démonstration : dossier personnel fixe (rien du Mac qui les produit).
        Result { try RemoteLauncher.plan(for: connection, home: RegEnvironment.isSandboxed ? "/Users/dany" : NSHomeDirectory()) }
    }

    /// Ouvre la connexion ; `mode` : choix rapide du bouton « Connecter » (fenêtre ou plein
    /// écran pour cette fois seulement, sans changer la connexion enregistrée).
    /// Note 57 : SSH, Telnet et série s'ouvrent dans un onglet de NetScope (`newTab` : un onglet
    /// de plus même si la session est déjà ouverte) ; `inTerminalApp` : l'ancien comportement.
    /// `external` : VNC dans Partage d'écran plutôt que dans la session intégrée.
    func connect(_ connection: RemoteConnection, mode: RemoteDisplayMode? = nil, newTab: Bool = false, inTerminalApp: Bool = false, external: Bool = false,
                 askUser: Bool = true) {
        // Note 6 : RustDesk s'ouvre par rustdesk:// (mot de passe permanent du Trousseau s'il y en a un).
        if connection.proto == .rustdesk {
            connectRustDesk(connection)
            return
        }
        // Note 57 : VNC s'ouvre dans la session intégrée de NetScope.
        if connection.proto == .vnc, !external {
            openVNC(connection, fullScreen: (mode ?? connection.display.mode) == .fullScreen)
            return
        }
        // Note 52 : connexion SSH ou Telnet du carnet sans utilisateur : le nom est demandé.
        // Note 78 : le nom peut venir de ~/.ssh/config (User) : ssh le prend, rien n'est demandé.
        // RDP sans utilisateur : demandé aussi, puis retenu par appareil et par site.
        if askUser, [.ssh, .telnet, .rdp].contains(connection.proto), connection.username.trimmingCharacters(in: .whitespaces).isEmpty,
           !(connection.proto == .ssh && SSHConfigCache.config.resolve(connection.host).user != nil) {
            QuickLoginModel.shared.ask(QuickLoginTarget(connection: connection, inTerminalApp: inTerminalApp))
            return
        }
        if connection.proto == .rdp, !connection.username.isEmpty {
            QuickLoginModel.shared.rememberUse(proto: .rdp, host: connection.host, user: connection.username, port: connection.port)
        }
        if !inTerminalApp, mode == nil || connection.proto != .vnc, RemoteSessionStore.opensInTab(connection.proto) {
            guard let valid = try? connection.validated() else {
                toast = "Connexion «\u{00A0}\(connection.name)\u{00A0}» à corriger avant de l’ouvrir."
                return
            }
            selectedID = connection.id
            draft = nil
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index].lastConnected = Date()
                save()
            }
            RemoteSessionStore.shared.open(valid, newTab: newTab)
            // Grande fenêtre : le panneau de détails se replie pour laisser la largeur au terminal.
            if !compactLayout { showDetails = false }
            return
        }
        // Note 50 : FTP, FTPS et SFTP s'ouvrent dans le navigateur de fichiers de NetScope.
        if connection.proto.isFileTransfer {
            selectedID = connection.id
            draft = nil
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index].lastConnected = Date()
                save()
            }
            FileTransferStore.shared.open(connections.first { $0.id == connection.id } ?? connection)
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
                        self.toast = "Plein écran non appliqué à «\u{00A0}\(name)\u{00A0}»\u{00A0}: utilisez Présentation › Passer en plein écran dans Partage d’écran."
                    }
                }
            }
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: RustDesk (note 6)

    /// Ouvre RustDesk sur ce poste et note le lancement (historique, dernière connexion).
    func connectRustDesk(_ connection: RemoteConnection) {
        guard let valid = try? connection.validated(), let target = valid.rustDeskTarget else {
            toast = "Connexion «\u{00A0}\(connection.name)\u{00A0}» à corriger avant de l’ouvrir."
            return
        }
        selectedID = connection.id
        draft = nil
        let rustdesk = RustDeskModel.shared
        let message = rustdesk.launch(target, name: valid.name, connection: valid)
        guard !rustdesk.needsInstall else { return }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].lastConnected = Date()
            save()
        }
        toast = message
    }

    /// « Nouvelle connexion RustDesk » : ID collé (espaces acceptés) ou IP directe. `saveToBook` :
    /// ajoutée au carnet (ou celle du carnet qui a déjà cet ID est reprise), sinon seulement lancée.
    /// Renvoie l'erreur à afficher, nil si tout va bien.
    @discardableResult
    func quickRustDesk(_ text: String, name: String = "", endUser: String = "", saveToBook: Bool, launch: Bool = true) -> String? {
        do {
            let folder = selected?.proto == .rustdesk ? (selected?.folder ?? "") : ""
            let fresh = try RemoteConnection.rustDesk(text, name: name, folder: folder, endUser: endUser)
            if let existing = connections.first(where: { $0.proto == .rustdesk && $0.host == fresh.host }) {
                if launch { connectRustDesk(existing) } else { selectedID = existing.id }
                return nil
            }
            if saveToBook {
                connections.append(fresh)
                selectedID = fresh.id
                save()
                if launch { connectRustDesk(fresh) } else { toast = "Poste «\u{00A0}\(fresh.name)\u{00A0}» ajouté au carnet." }
            } else if launch, let target = fresh.rustDeskTarget {
                toast = RustDeskModel.shared.launch(target, name: fresh.name)
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Note 6 : ID RustDesk d'une fiche d'inventaire ou d'un appareil : la connexion du carnet qui a
    /// cet ID, sinon un lancement direct (sans l'ajouter au carnet).
    /// Renvoie le message affiché (aussi gardé dans `toast` pour l'écran Accès distant).
    @discardableResult
    func connectRustDesk(id text: String, name: String) -> String? {
        guard let id = RustDeskID.parse(text) else {
            toast = RemoteValidationError.invalidRustDeskID(text).errorDescription
            return toast
        }
        if let existing = connections.first(where: { $0.proto == .rustdesk && $0.host == id }) {
            toast = nil
            connectRustDesk(existing)
        } else {
            toast = RustDeskModel.shared.launch(.id(id), name: name)
        }
        return RustDeskModel.shared.needsInstall ? nil : toast
    }

    /// Note 57 : session VNC intégrée (VNCSessionView), dans un onglet de la barre des sessions.
    /// Plein écran demandé : tout de suite si la session est déjà connectée, sinon dès qu'elle
    /// l'est (après l'identification).
    func openVNC(_ connection: RemoteConnection, fullScreen: Bool = false) {
        selectedID = connection.id
        draft = nil
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].lastConnected = Date()
            save()
        }
        guard let session = RemoteSessionStore.shared.open(connections.first { $0.id == connection.id } ?? connection)?.vncSession else { return }
        if !compactLayout { showDetails = false }
        guard fullScreen else { return }
        if session.phase == .connected {
            VNCFullScreenController.shared.present(session)
        } else {
            session.pendingFullScreen = true
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

    // MARK: Tunnels SSH (note 66)

    /// « Nouveau tunnel » pour cette connexion SSH (formulaire dans l'onglet « Sessions »).
    func startTunnel(for connection: RemoteConnection) {
        draft = nil
        draftError = nil
        tunnelDraft = SSHTunnelDraft(connectionID: connection.id)
        tunnelDraftError = nil
        selectedID = connection.id
        RemoteSessionStore.shared.select(nil)
    }

    func editTunnel(_ tunnel: SSHTunnelSpec, of connection: RemoteConnection) {
        draft = nil
        draftError = nil
        tunnelDraft = SSHTunnelDraft(tunnel, connectionID: connection.id)
        tunnelDraftError = nil
        selectedID = connection.id
        RemoteSessionStore.shared.select(nil)
    }

    /// Enregistre le tunnel dans sa connexion ; `open` : le démarre dans un onglet.
    func commitTunnelDraft(open: Bool) {
        guard let tunnelDraft, let index = connections.firstIndex(where: { $0.id == tunnelDraft.connectionID }) else { return }
        do {
            let spec = try tunnelDraft.tunnel().validated()
            var updated = connections[index]
            if let position = updated.tunnels.firstIndex(where: { $0.id == spec.id }) {
                updated.tunnels[position] = spec
            } else {
                updated.tunnels.append(spec)
            }
            updated = try updated.validated()
            connections[index] = updated
            save()
            self.tunnelDraft = nil
            tunnelDraftError = nil
            toast = "Tunnel «\u{00A0}\(spec.title)\u{00A0}» enregistré dans \(updated.name)."
            SSHTunnelStore.shared.session(for: spec.id)?.update(tunnel: spec, connection: updated)
            if open { openTunnel(spec, of: updated) }
        } catch {
            tunnelDraftError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteTunnel(_ id: UUID, from connectionID: UUID) {
        if let tab = RemoteSessionStore.shared.tunnelTab(id) { RemoteSessionStore.shared.close(tab.id) }
        SSHTunnelStore.shared.discard(id)
        let removed = connections.first { $0.id == connectionID }?.tunnels.first { $0.id == id }
        updateExisting(connectionID) { $0.tunnels.removeAll { $0.id == id } }
        if let removed { toast = "Redirection «\u{00A0}\(removed.title)\u{00A0}» supprimée." }
    }

    /// Aligne les sessions de tunnel ouvertes sur la connexion enregistrée.
    private func syncTunnelSessions(with connection: RemoteConnection) {
        let store = SSHTunnelStore.shared
        for session in store.sessions(of: connection.id) {
            if connection.proto == .ssh, let spec = connection.tunnels.first(where: { $0.id == session.id }) {
                session.update(tunnel: spec, connection: connection)
            } else {
                if let tab = RemoteSessionStore.shared.tunnelTab(session.id) { RemoteSessionStore.shared.close(tab.id) }
                store.discard(session.id)
            }
        }
    }

    /// Démarre le tunnel et montre son onglet de session.
    func openTunnel(_ tunnel: SSHTunnelSpec, of connection: RemoteConnection) {
        let current = connections.first { $0.id == connection.id } ?? connection
        guard let valid = try? current.validated() else {
            toast = "Connexion «\u{00A0}\(current.name)\u{00A0}» à corriger avant d’ouvrir un tunnel."
            return
        }
        let spec = valid.tunnels.first { $0.id == tunnel.id } ?? tunnel
        let session = SSHTunnelStore.shared.start(spec, via: valid)
        RemoteSessionStore.shared.openTunnel(session)
        selectedID = connection.id
        draft = nil
        tunnelDraft = nil
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].lastConnected = Date()
            save()
        }
    }

    func stopTunnel(_ id: UUID) {
        SSHTunnelStore.shared.stop(id)
    }

    /// Hôte de rebond choisi dans le panneau de détails (croquis : liste des connexions SSH).
    func setProxyJump(_ jump: String, for id: UUID) {
        guard let normalized = try? SSHJumpChain.normalized(jump) else {
            toast = SSHTunnelError.invalidJump(jump).errorDescription
            return
        }
        updateExisting(id) { $0.proxyJump = normalized }
    }

    struct JumpCandidate: Equatable {
        let spec: String
        let label: String
    }

    /// Connexions SSH du carnet utilisables comme rebond (avec leur propre rebond, en chaîne).
    func jumpCandidates(excluding id: UUID) -> [JumpCandidate] {
        connections.filter { $0.proto == .ssh && $0.id != id }.compactMap { connection in
            let hop = SSHJumpHost(user: connection.username, host: connection.host, port: connection.port).formatted
            let chain = connection.proxyJump.isEmpty ? hop : connection.proxyJump + "," + hop
            guard let spec = try? SSHJumpChain.normalized(chain), !spec.isEmpty else { return nil }
            return JumpCandidate(spec: spec, label: "\(connection.name) · \(connection.host):\(connection.port)")
        }
    }

    /// RDP, VNC ou navigateur à travers un tunnel ouvert (127.0.0.1:port).
    func openThroughTunnel(_ session: SSHTunnelSession, use: SSHTunnelUse) {
        guard session.phase == .open, let port = session.localPort else { return }
        switch use {
        case .rdp, .vnc:
            let proto: RemoteProtocol = use == .rdp ? .rdp : .vnc
            let base = connections.first { $0.proto == proto && $0.host == session.tunnel.remoteHost }
            guard var through = SSHTunnelCommand.throughTunnel(use, port: port, name: (base?.name ?? session.title) + " (tunnel)", base: base) else { return }
            // Une session VNC par tunnel (mot de passe VNC propre à cette entrée).
            through.id = session.id
            if use == .vnc {
                RemoteSessionStore.shared.open(through)
                return
            }
            if RegEnvironment.isSandboxed {
                toast = "Démonstration\u{00A0}: Windows App non lancée (\(through.name), 127.0.0.1:\(port))."
                return
            }
            do {
                let plan = try RemoteLauncher.plan(for: through)
                try RemoteExecutor.execute(plan, title: through.name)
                toast = "Ouverture dans Windows App\u{00A0}: \(through.name), par le tunnel."
            } catch {
                toast = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .http, .https:
            guard let url = SSHTunnelCommand.webURL(use: use, port: port) else { return }
            if RegEnvironment.isSandboxed {
                toast = "Démonstration\u{00A0}: \(url.absoluteString) non ouvert."
                return
            }
            NSWorkspace.shared.open(url)
            toast = "Ouverture de \(url.absoluteString) dans le navigateur."
        case .none:
            session.copyLocalAddress()
        }
    }

    // MARK: Import de ~/.ssh/config (note 78)

    func sshConfigCandidates() -> [SSHConfigCandidate] {
        SSHConfigImport.candidates(from: SSHConfigCache.config, existing: connections)
    }

    func addFromSSHConfig(_ candidate: SSHConfigCandidate) {
        guard !candidate.alreadySaved, let connection = candidate.connection,
              !connections.contains(where: { $0.proto == .ssh && $0.host == connection.host && $0.port == connection.port }) else { return }
        connections.append(connection)
        save()
    }

    func addAllFromSSHConfig(_ candidates: [SSHConfigCandidate]) -> Int {
        var added = 0
        for candidate in candidates where !candidate.alreadySaved && candidate.connection != nil {
            let before = connections.count
            addFromSSHConfig(candidate)
            if connections.count > before { added += 1 }
        }
        if added > 0 { toast = "\(added) hôte\(added > 1 ? "s" : "") importé\(added > 1 ? "s" : "") de ~/.ssh/config." }
        return added
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(connections)
        } catch {
            AppLog.shared.error("Accès distant", "Enregistrement des connexions impossible : \(error.localizedDescription)")
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
        case .fileBrowser, .rustdesk:
            // Ouverts par RemoteModel.connect : navigateur de NetScope, ou RustDeskModel (mot de passe du Trousseau).
            break
        }
    }
}
