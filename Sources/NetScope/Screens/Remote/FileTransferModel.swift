import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 50 : session de fichiers (FTP, FTPS, SFTP) ouverte depuis Accès distant. Deux clients par
// session : l'un pour parcourir, l'autre pour la file des transferts (une connexion de contrôle FTP
// ne fait qu'une chose à la fois). Mots de passe au Trousseau (service com.danymenard.netscope.ftp,
// un compte par connexion), jamais en clair. En démonstration et pendant les captures : système de
// fichiers fictif (DevTools/FileTransferDemo.swift), aucun réseau, aucun Trousseau.

/// Sessions de fichiers et mots de passe des connexions FTP, FTPS et SFTP.
@MainActor
final class FileTransferStore: ObservableObject {
    static let shared = FileTransferStore()
    nonisolated static let keychain = UpdKeychain(service: "com.danymenard.netscope.ftp")

    /// Session ouverte (une à la fois ; elle continue ses transferts quand on choisit une autre connexion).
    @Published private(set) var session: FileTransferSession?
    /// Connexions dont le mot de passe est au Trousseau (lu sans afficher le secret).
    @Published private(set) var savedPasswords: Set<UUID> = []

    let isSandboxed = RegEnvironment.isSandboxed

    private init() {
        if isSandboxed {
            savedPasswords = Set(RemoteDemo.activeConnections.filter(\.proto.isFileTransfer).map(\.id))
            if let raw = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"], raw == "fichiers" || raw == "fichiers-ftp" {
                let proto: RemoteProtocol = raw == "fichiers" ? .sftp : .ftp
                if let connection = RemoteDemo.connections.first(where: { $0.proto == proto }) {
                    session = FileTransferDemo.snapshotSession(for: connection)
                }
            }
        }
    }

    // MARK: Trousseau

    func hasPassword(_ id: UUID) -> Bool {
        if savedPasswords.contains(id) { return true }
        guard !isSandboxed else { return false }
        if Self.keychain.string(for: id.uuidString) != nil {
            savedPasswords.insert(id)
            return true
        }
        return false
    }

    func password(for id: UUID) -> String? {
        guard !isSandboxed else { return savedPasswords.contains(id) ? "démonstration" : nil }
        return Self.keychain.string(for: id.uuidString)
    }

    /// Enregistre (ou efface, si vide) le mot de passe de la connexion.
    func setPassword(_ value: String, for id: UUID) throws {
        if value.isEmpty { savedPasswords.remove(id) } else { savedPasswords.insert(id) }
        guard !isSandboxed else { return }
        try Self.keychain.set(value.isEmpty ? nil : value, for: id.uuidString)
    }

    // MARK: Sessions

    /// Ouvre le navigateur de fichiers de la connexion (ou y revient s'il est déjà ouvert).
    func open(_ connection: RemoteConnection) {
        if let session, session.connection.id == connection.id {
            session.isVisible = true
            if case .failed = session.phase { session.reconnect() }
            return
        }
        session?.close()
        let created = FileTransferSession(connection: connection, store: self)
        session = created
        created.start()
    }

    func close() {
        session?.close()
        session = nil
    }

    /// Session ouverte pour cette connexion et affichée.
    func isShowing(_ id: UUID?) -> Bool {
        guard let id, let session else { return false }
        return session.connection.id == id && session.isVisible
    }
}

/// Une session de fichiers : volets Mac et serveur, file des transferts.
@MainActor
final class FileTransferSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case connected
        /// Utilisateur ou mot de passe à saisir (message de l'échec précédent).
        case needsCredentials(String?)
        /// FTPS : certificat autosigné ou inconnu, à accepter par son empreinte.
        case trustCertificate(sha256: String, subject: String)
        /// SFTP : serveur SSH encore inconnu.
        case trustHostKey(fingerprint: String)
        case failed(String)
    }

    let id = UUID()
    private(set) var connection: RemoteConnection
    private weak var store: FileTransferStore?
    @Published var phase: Phase = .connecting
    /// Montrée dans Accès distant (sinon la session tourne en arrière-plan).
    @Published var isVisible = true

    // Volet serveur.
    @Published var remotePath = "/"
    @Published var remoteEntries: [RemoteFileEntry] = []
    @Published var remoteSelection: Set<String> = []
    @Published var remoteLoading = false
    @Published var remoteError: String?

    // Volet Mac.
    @Published var localURL: URL
    @Published var localEntries: [RemoteFileEntry] = []
    @Published var localSelection: Set<String> = []
    @Published var localError: String?

    // File des transferts.
    @Published var jobs: [TransferJob] = []
    @Published var log: [String] = []

    // Dialogues.
    @Published var pendingDeletion: [RemoteFileEntry] = []
    @Published var renaming: RemoteFileEntry?
    @Published var renameText = ""
    @Published var creatingFolder = false
    @Published var newFolderName = "Nouveau dossier"
    @Published var pendingConflict: UploadConflict?
    @Published var message: String?

    // Identification demandée dans le navigateur.
    @Published var credentialUser = ""
    @Published var credentialPassword = ""
    @Published var rememberPassword = true

    struct UploadConflict: Equatable {
        var urls: [URL]
        var directory: String
        var names: [String]
    }

    private var browser: RemoteFileTransfer?
    private var transfer: RemoteFileTransfer?
    private var runner: Task<Void, Never>?
    private var jobTasks: [UUID: Task<Void, Never>] = [:]
    private var pauseRequested: Set<UUID> = []
    private var acceptHostKey = false
    let isDemo: Bool

    init(connection: RemoteConnection, store: FileTransferStore?, demo: Bool = RegEnvironment.isSandboxed) {
        self.connection = connection
        self.store = store
        isDemo = demo
        // Note 78 : SFTP sans utilisateur : nom retenu pour l'appareil (ou son compte SSH).
        if connection.proto == .sftp, connection.username.trimmingCharacters(in: .whitespaces).isEmpty, !demo {
            credentialUser = QuickLoginModel.shared.suggestedUser(proto: .sftp, host: connection.host)
        } else {
            credentialUser = connection.username
        }
        let configured = connection.transfer.localDirectory
        if demo {
            localURL = FileTransferDemo.localHome
        } else if !configured.isEmpty {
            localURL = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        } else {
            localURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    var isEncrypted: Bool { connection.proto != .ftp }

    /// « sftp://admin-nas@10.10.0.20/ ».
    var address: String { RemoteLauncher.fileTransferURL(for: connection) }

    // MARK: Connexion

    func start() {
        refreshLocal()
        connect()
    }

    func reconnect() {
        connect()
    }

    /// Ouvre les deux clients et lit le dossier de départ.
    private func connect() {
        phase = .connecting
        remoteError = nil
        let needsSecret: Bool
        switch connection.proto {
        case .sftp: needsSecret = connection.transfer.sftpAuth == .password
        default:
            // « anonymous » n'a pas de mot de passe (le client envoie « netscope@ ») : jamais demandé.
            let user = connection.username.trimmingCharacters(in: .whitespaces)
            needsSecret = !user.isEmpty && user.lowercased() != "anonymous"
        }
        let secret = store?.password(for: connection.id)
        if connection.proto == .sftp, connection.username.trimmingCharacters(in: .whitespaces).isEmpty {
            phase = .needsCredentials(nil)
            return
        }
        if needsSecret, secret == nil {
            phase = .needsCredentials(nil)
            return
        }
        let endpoint = FileTransferEndpoint(connection: connection, secret: secret, acceptNewHostKey: acceptHostKey)
        Task {
            await browser?.close()
            await transfer?.close()
            do {
                let browser = try makeClient(endpoint)
                let start = try await browser.connect()
                self.browser = browser
                self.transfer = try makeClient(endpoint)
                phase = .connected
                appendLog("Connecté à \(connection.host) (\(connection.proto.label)).")
                let configured = connection.transfer.remoteDirectory.trimmingCharacters(in: .whitespaces)
                navigateRemote(configured.isEmpty ? start : configured)
                startRunner()
            } catch let error as FileTransferError {
                handleConnectError(error)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handleConnectError(_ error: FileTransferError) {
        switch error {
        case .loginFailed:
            phase = .needsCredentials(error.errorDescription)
        case .untrustedCertificate(let sha, let subject):
            phase = .trustCertificate(sha256: sha, subject: subject)
        case .unknownHostKey(let fingerprint):
            phase = .trustHostKey(fingerprint: fingerprint)
        default:
            phase = .failed(error.errorDescription ?? "Connexion impossible.")
        }
        appendLog(error.errorDescription ?? "Erreur")
    }

    private func makeClient(_ endpoint: FileTransferEndpoint) throws -> RemoteFileTransfer {
        if isDemo { return FileTransferDemo.client(for: connection) }
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        switch endpoint.proto {
        case .ftp, .ftps: return FTPClient(endpoint: endpoint, log: log)
        case .sftp: return SFTPClient(endpoint: endpoint, log: log)
        default: throw FileTransferError.notTransferProtocol
        }
    }

    /// Identification saisie dans le navigateur.
    func submitCredentials() {
        let user = credentialUser.trimmingCharacters(in: .whitespaces)
        guard (try? RemoteValidator.validateUser(user)) != nil else {
            phase = .needsCredentials("Nom d’utilisateur invalide.")
            return
        }
        connection.username = user
        RemoteModel.shared.setTransferUsername(user, for: connection.id)
        // Note 78 : nom retenu pour l'appareil et le site (connexions SFTP suivantes).
        if connection.proto == .sftp {
            QuickLoginModel.shared.rememberUse(proto: .sftp, host: connection.host, user: user, port: connection.port)
        }
        var keychainFailure: String?
        if !credentialPassword.isEmpty, rememberPassword {
            do {
                try store?.setPassword(credentialPassword, for: connection.id)
            } catch {
                keychainFailure = "Mot de passe non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)"
                appendLog(keychainFailure!)
            }
        }
        if let keychainFailure {
            // Le mot de passe sert quand même à cette session ; l'échec est montré à l'écran.
            let endpoint = FileTransferEndpoint(connection: connection, secret: credentialPassword, acceptNewHostKey: acceptHostKey)
            credentialPassword = ""
            connectWith(endpoint, notice: keychainFailure)
            return
        }
        let agentAuth = connection.proto == .sftp && connection.transfer.sftpAuth != .password
        if credentialPassword.isEmpty, !agentAuth, store?.password(for: connection.id) == nil {
            // Aucun mot de passe (serveur qui accepte l'utilisateur sans mot de passe) : tenté tel
            // quel, au lieu de redemander l'identification en boucle.
            connectWith(FileTransferEndpoint(connection: connection, secret: "", acceptNewHostKey: acceptHostKey))
            return
        }
        if !rememberPassword, !credentialPassword.isEmpty {
            // Mot de passe pour cette session seulement : jamais au Trousseau.
            let endpoint = FileTransferEndpoint(connection: connection, secret: credentialPassword, acceptNewHostKey: acceptHostKey)
            credentialPassword = ""
            connectWith(endpoint)
            return
        }
        credentialPassword = ""
        connect()
    }

    private func connectWith(_ endpoint: FileTransferEndpoint, notice: String? = nil) {
        phase = .connecting
        Task {
            await browser?.close()
            await transfer?.close()
            do {
                let browser = try makeClient(endpoint)
                let start = try await browser.connect()
                self.browser = browser
                self.transfer = try makeClient(endpoint)
                phase = .connected
                let configured = connection.transfer.remoteDirectory.trimmingCharacters(in: .whitespaces)
                navigateRemote(configured.isEmpty ? start : configured)
                if let notice { remoteError = notice }
                startRunner()
            } catch let error as FileTransferError {
                handleConnectError(error)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// FTPS : faire confiance au certificat présenté (empreinte enregistrée avec la connexion).
    func trustCertificate(_ sha256: String) {
        connection.transfer.trustedCertificateSHA256 = sha256
        RemoteModel.shared.setTrustedCertificate(sha256, for: connection.id)
        appendLog("Certificat accepté\u{00A0}: \(sha256)")
        connect()
    }

    /// SFTP : ajouter la clé du serveur à ~/.ssh/known_hosts (comme « yes » dans Terminal).
    func trustHostKey() {
        acceptHostKey = true
        connect()
    }

    func close() {
        runner?.cancel()
        for task in jobTasks.values { task.cancel() }
        jobTasks.removeAll()
        let browser = self.browser, transfer = self.transfer
        self.browser = nil
        self.transfer = nil
        Task {
            await browser?.close()
            await transfer?.close()
        }
    }

    // MARK: Volet serveur

    func navigateRemote(_ path: String) {
        guard let browser else { return }
        remoteLoading = true
        remoteError = nil
        let target = RemotePath.normalize(path.isEmpty ? "/" : path)
        Task {
            do {
                let entries = try await browser.list(target)
                remotePath = target
                remoteEntries = entries
                remoteSelection = []
            } catch {
                remoteError = Self.describe(error)
                if case FileTransferError.connectionFailed = error { phase = .failed(Self.describe(error)) }
            }
            remoteLoading = false
        }
    }

    func refreshRemote() { navigateRemote(remotePath) }

    func openRemote(_ entry: RemoteFileEntry) {
        switch entry.kind {
        case .directory, .link:
            navigateRemote(entry.kind == .link ? (entry.linkTarget.map { RemotePath.join(remotePath, $0) } ?? entry.path) : entry.path)
        case .file:
            download([entry])
        }
    }

    var selectedRemote: [RemoteFileEntry] { remoteEntries.filter { remoteSelection.contains($0.id) } }

    func makeFolder() {
        guard let browser else { return }
        do {
            let name = try RemotePath.validateName(newFolderName)
            let path = RemotePath.join(remotePath, name)
            Task {
                do {
                    try await browser.makeDirectory(path)
                    message = "Dossier « \(name) » créé."
                    refreshRemote()
                } catch {
                    remoteError = Self.describe(error)
                }
            }
        } catch {
            remoteError = Self.describe(error)
        }
        creatingFolder = false
    }

    func startRename(_ entry: RemoteFileEntry) {
        renaming = entry
        renameText = entry.name
    }

    func commitRename() {
        guard let entry = renaming, let browser else { return }
        renaming = nil
        do {
            let name = try RemotePath.validateName(renameText)
            guard name != entry.name else { return }
            Task {
                do {
                    try await browser.rename(entry.path, to: RemotePath.join(RemotePath.parent(entry.path), name))
                    message = "« \(entry.name) » renommé en « \(name) »."
                    refreshRemote()
                } catch {
                    remoteError = Self.describe(error)
                }
            }
        } catch {
            remoteError = Self.describe(error)
        }
    }

    /// Suppression confirmée (dossiers avec tout leur contenu).
    func confirmDeletion() {
        let entries = pendingDeletion
        pendingDeletion = []
        guard let browser, !entries.isEmpty else { return }
        Task {
            var count = 0
            do {
                for entry in entries {
                    count += try await browser.deleteRecursively(entry)
                }
                message = count == 1 ? "1 élément supprimé." : "\(count) éléments supprimés."
            } catch {
                remoteError = Self.describe(error)
            }
            refreshRemote()
        }
    }

    // MARK: Volet Mac

    func refreshLocal() {
        if isDemo {
            localEntries = FileTransferDemo.localEntries(in: localURL)
            return
        }
        do {
            localEntries = try LocalFileListing.list(localURL)
            localError = nil
        } catch {
            localEntries = []
            localError = "Dossier illisible\u{00A0}: \(error.localizedDescription)"
        }
    }

    func navigateLocal(_ url: URL) {
        localURL = url
        localSelection = []
        refreshLocal()
        if !isDemo {
            connection.transfer.localDirectory = url.path
            RemoteModel.shared.setTransferLocalDirectory(url.path, for: connection.id)
        }
    }

    func openLocal(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            navigateLocal(URL(fileURLWithPath: entry.path))
        } else {
            upload([URL(fileURLWithPath: entry.path)])
        }
    }

    var selectedLocal: [RemoteFileEntry] { localEntries.filter { localSelection.contains($0.id) } }

    /// Choisir le dossier du Mac (panneau du Finder).
    func chooseLocalFolder() {
        guard !isDemo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = localURL
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { navigateLocal(url) }
    }

    func revealLocal() {
        guard !isDemo else { return }
        NSWorkspace.shared.activateFileViewerSelecting(selectedLocal.isEmpty ? [localURL] : selectedLocal.map { URL(fileURLWithPath: $0.path) })
    }

    // MARK: Transferts

    /// Envoie des fichiers ou dossiers du Mac vers le dossier distant affiché (ou `directory`).
    func upload(_ urls: [URL], to directory: String? = nil, overwrite: Bool? = nil) {
        guard phase == .connected, !urls.isEmpty else { return }
        let target = directory ?? remotePath
        let names = urls.map { RemotePath.safeLocalName($0.lastPathComponent) }
        let existing = target == remotePath ? Set(remoteEntries.map(\.name)) : []
        let clashes = names.filter { existing.contains($0) }
        if overwrite == nil, !clashes.isEmpty {
            pendingConflict = UploadConflict(urls: urls, directory: target, names: clashes)
            return
        }
        var taken = existing
        for url in urls {
            let original = RemotePath.safeLocalName(url.lastPathComponent)
            let name = overwrite == false ? TransferPlanner.uniqueName(original, taken: taken) : original
            taken.insert(name)
            if isDemo {
                let size = FileTransferDemo.localSize(url)
                jobs.append(TransferJob(direction: .upload, localURL: url, remotePath: RemotePath.join(target, name), totalBytes: size))
                continue
            }
            let items = TransferPlanner.uploadItems(url, into: target)
            let rename: (String) -> String = { path in
                guard name != original else { return path }
                let root = RemotePath.join(target, original)
                return path == root ? RemotePath.join(target, name) : RemotePath.join(target, name) + String(path.dropFirst(root.count))
            }
            let directories = items.filter(\.isDirectory).map { rename($0.remotePath) }
            let files = items.filter { !$0.isDirectory }
            let newJobs = files.map {
                TransferJob(direction: .upload, localURL: $0.localURL, remotePath: rename($0.remotePath), totalBytes: $0.size)
            }
            if !directories.isEmpty, let transfer {
                // Dossier envoyé : ses sous-dossiers sont créés d'abord (dans l'ordre), puis ses
                // fichiers entrent dans la file. Un dossier qui existe déjà n'est pas une erreur.
                Task {
                    for path in directories { try? await transfer.makeDirectory(path) }
                    jobs += newJobs
                    startRunner()
                    if RemotePath.parent(directories[0]) == remotePath { refreshRemote() }
                }
            } else {
                jobs += newJobs
            }
        }
        startRunner()
    }

    func resolveConflict(overwrite: Bool) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        upload(conflict.urls, to: conflict.directory, overwrite: overwrite)
    }

    /// Reçoit des fichiers ou dossiers distants dans le dossier du Mac affiché.
    func download(_ entries: [RemoteFileEntry]) {
        guard phase == .connected, !entries.isEmpty else { return }
        var taken = Set(localEntries.map(\.name))
        let destination = localURL
        for entry in entries {
            let name = TransferPlanner.uniqueName(RemotePath.safeLocalName(entry.name), taken: taken)
            taken.insert(name)
            let localURL = destination.appendingPathComponent(name)
            switch entry.kind {
            case .file, .link:
                jobs.append(TransferJob(direction: .download, localURL: localURL, remotePath: entry.path, totalBytes: entry.size))
            case .directory:
                guard let browser, !isDemo else {
                    message = "Démonstration\u{00A0}: les dossiers ne sont pas reçus."
                    continue
                }
                Task {
                    do {
                        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                        let root = localURL.standardizedFileURL.path + "/"
                        for (child, relative) in try await browser.walk(entry.path) {
                            // Chaque élément passe par le nom local sûr, et la cible doit rester
                            // dans le dossier reçu (un serveur ne choisit jamais où écrire sur le Mac).
                            let safe = relative.split(separator: "/").map { RemotePath.safeLocalName(String($0)) }.joined(separator: "/")
                            let target = localURL.appendingPathComponent(safe)
                            guard target.standardizedFileURL.path.hasPrefix(root) else { continue }
                            if child.isDirectory {
                                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                            } else {
                                jobs.append(TransferJob(direction: .download, localURL: target, remotePath: child.path, totalBytes: child.size))
                            }
                        }
                        refreshLocal()
                        startRunner()
                    } catch {
                        remoteError = Self.describe(error)
                    }
                }
            }
        }
        startRunner()
    }

    /// Exécute la file, un fichier à la fois.
    private func startRunner() {
        guard runner == nil, transfer != nil || isDemo else { return }
        guard !RegEnvironment.isSnapshot else { return }
        runner = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let index = self.jobs.firstIndex(where: { $0.state == .waiting }) else { break }
                let id = self.jobs[index].id
                let task = Task { await self.run(id) }
                self.jobTasks[id] = task
                await task.value
                self.jobTasks[id] = nil
            }
            self?.runner = nil
        }
    }

    private func run(_ id: UUID) async {
        guard let transfer = transfer ?? (isDemo ? FileTransferDemo.client(for: connection) : nil),
              var job = jobs.first(where: { $0.id == id }) else { return }
        var resume = job.transferredBytes > 0
        let meter = FileTransferRateBox()
        update(id) { $0.state = .running; if $0.startedAt == nil { $0.startedAt = Date() } }
        while true {
            do {
                let progress: FileTransferProgress = { [weak self] bytes in
                    Task { @MainActor in
                        guard let self else { return }
                        let rate = meter.meter.record(bytes: bytes)
                        self.update(id) {
                            $0.transferredBytes = bytes
                            if let rate { $0.bytesPerSecond = rate }
                        }
                    }
                }
                switch job.direction {
                case .download:
                    try await transfer.download(job.remotePath, to: job.localURL, resume: resume, progress: progress)
                case .upload:
                    try await transfer.upload(job.localURL, to: job.remotePath, resume: resume, progress: progress)
                }
                update(id) {
                    $0.state = .done
                    $0.finishedAt = Date()
                    if let total = $0.totalBytes { $0.transferredBytes = total }
                }
                appendLog("\(job.direction.label) terminé\u{00A0}: \(job.name)")
                if job.direction == .upload, RemotePath.parent(job.remotePath) == remotePath { refreshRemote() }
                if job.direction == .download, job.localURL.deletingLastPathComponent() == localURL { refreshLocal() }
                return
            } catch {
                if pauseRequested.remove(id) != nil {
                    update(id) { $0.state = .paused; $0.bytesPerSecond = nil }
                    return
                }
                if Task.isCancelled || (error as? FileTransferError) == .cancelled {
                    update(id) { $0.state = .cancelled; $0.bytesPerSecond = nil; $0.finishedAt = Date() }
                    if job.direction == .download { try? FileManager.default.removeItem(at: job.localURL) }
                    return
                }
                if TransferRetryPolicy.shouldRetry(error, attempts: job.attempts) {
                    job.attempts += 1
                    let attempt = job.attempts
                    update(id) { $0.state = .retrying(attempt: attempt); $0.attempts = attempt; $0.bytesPerSecond = nil }
                    appendLog("Coupure pendant \(job.name)\u{00A0}: reprise dans \(Int(TransferRetryPolicy.delay(forAttempt: attempt)))\u{00A0}s.")
                    try? await Task.sleep(nanoseconds: UInt64(TransferRetryPolicy.delay(forAttempt: attempt) * 1_000_000_000))
                    if Task.isCancelled {
                        // Pause ou annulation pendant l'attente : le transfert n'est pas relancé.
                        if pauseRequested.remove(id) != nil {
                            update(id) { $0.state = .paused; $0.bytesPerSecond = nil }
                        } else {
                            update(id) { $0.state = .cancelled; $0.bytesPerSecond = nil; $0.finishedAt = Date() }
                            if job.direction == .download { try? FileManager.default.removeItem(at: job.localURL) }
                        }
                        return
                    }
                    resume = true
                    update(id) { $0.state = .running }
                    continue
                }
                let text = Self.describe(error)
                update(id) { $0.state = .failed(text); $0.bytesPerSecond = nil; $0.finishedAt = Date() }
                appendLog("Échec de \(job.name)\u{00A0}: \(text)")
                return
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    func pause(_ id: UUID) {
        guard let task = jobTasks[id] else {
            update(id) { if $0.state == .waiting { $0.state = .paused } }
            return
        }
        pauseRequested.insert(id)
        task.cancel()
    }

    /// Reprend un transfert en pause, en échec ou annulé, là où il s'est arrêté.
    func resume(_ id: UUID) {
        update(id) {
            $0.state = .waiting
            $0.attempts = 0
            $0.finishedAt = nil
        }
        startRunner()
    }

    func cancel(_ id: UUID) {
        if let task = jobTasks[id] {
            task.cancel()
        } else {
            update(id) { if !$0.state.isFinished { $0.state = .cancelled } }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
    }

    var activeCount: Int { jobs.filter { $0.state.isActive || $0.state == .waiting }.count }

    var totalRate: Double { jobs.filter(\.state.isActive).compactMap(\.bytesPerSecond).reduce(0, +) }

    // MARK: Divers

    func appendLog(_ line: String) {
        log.append("\(RemoteFormat.time(Date()))  \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Glisser-déposer : chemins distants transportés comme texte (« netscope-fichier: » en tête).
    nonisolated static let dragPrefix = "netscope-fichier:"
}

/// Débit d'un transfert, mis à jour sur le fil principal.
@MainActor
final class FileTransferRateBox {
    var meter = TransferRateMeter()
}
