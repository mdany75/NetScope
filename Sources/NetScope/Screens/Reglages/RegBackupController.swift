import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Sauvegardes de NetScope (Réglages › Export et sauvegarde) : sauvegarde automatique quotidienne,
/// « Sauvegarder maintenant », liste, rotation et restauration. La restauration se termine au
/// lancement suivant (avant que les écrans ne lisent leurs fichiers), pour qu'aucune donnée en
/// mémoire ne réécrive l'état restauré en quittant.
/// Note 38 : chiffrement par mot de passe (option), avec les secrets du Trousseau en option ; le
/// mot de passe n'est jamais écrit ailleurs qu'au Trousseau, et seulement sur demande.
@MainActor
final class RegBackupController: ObservableObject {
    static let shared = RegBackupController()

    enum Key {
        static let automatic = "sauvegarde.automatique"
        static let folder = "sauvegarde.dossier"
        static let keep = "sauvegarde.nombreGarde"
        static let format = "sauvegarde.forme"
        static let iCloud = "sauvegarde.copieICloud"
        static let last = "sauvegarde.derniere"
        static let pending = "sauvegarde.restaurationEnAttente"
        /// Note 38 : chiffrement par mot de passe et secrets du Trousseau inclus.
        static let encrypt = "sauvegarde.chiffrer"
        static let includeSecrets = "sauvegarde.inclureSecrets"
        /// Archive en attente tirée d'une sauvegarde chiffrée (à effacer après la restauration).
        static let pendingIsTemporary = "sauvegarde.restaurationTemporaire"
        static let restoredSecrets = "sauvegarde.secretsRemis"
    }

    /// Mot de passe demandé par une feuille (aucun n'est mémorisé, ou il faut le définir).
    enum PasswordRequest: Identifiable, Equatable {
        case backupNow
        case export(URL)
        case define

        var id: String {
            switch self {
            case .backupNow: return "sauvegarde"
            case .export(let url): return "export:" + url.path
            case .define: return "definir"
            }
        }
    }

    /// Mot de passe des sauvegardes chiffrées (Trousseau, seulement si « Mémoriser » est coché).
    nonisolated static let passwordKeychain = UpdKeychain(service: BackupPasswordKeychain.service)

    /// Nombre de sauvegardes gardées (0 : toutes).
    static let keepChoices = [5, 10, 30, 60, 0]

    @Published var automatic: Bool { didSet { defaults?.set(automatic, forKey: Key.automatic); if automatic { runIfDue() } } }
    /// Changer ce nombre ne supprime rien tout de suite : la section demande d'abord confirmation
    /// (`excessCount`, puis `applyKeep`), sinon la rotation attend la prochaine sauvegarde.
    @Published var keep: Int { didSet { defaults?.set(keep, forKey: Key.keep) } }
    @Published var format: BackupFormat { didSet { defaults?.set(format.rawValue, forKey: Key.format) } }
    @Published var copyToICloud: Bool { didSet { defaults?.set(copyToICloud, forKey: Key.iCloud) } }
    @Published private(set) var folder: URL
    @Published private(set) var backups: [BackupInfo] = []
    @Published private(set) var lastBackup: Date?
    /// Sauvegardes en cours (compteur : deux sauvegardes peuvent se chevaucher, sécurité comprise).
    @Published private var workCount = 0
    var isWorking: Bool { workCount > 0 }
    @Published var message: (text: String, tone: Tone)?
    /// Comptes du Trousseau à ressaisir après une restauration ailleurs (noms seulement).
    @Published private(set) var keychainItems: [BackupKeychainItem] = []
    /// Restauration prête, en attente du redémarrage.
    @Published private(set) var pendingRestore: String?
    /// Note 38 : sauvegardes chiffrées par mot de passe.
    @Published var encrypt: Bool { didSet { defaults?.set(encrypt, forKey: Key.encrypt) } }
    /// Note 38 : jetons et secrets du Trousseau rangés dans la partie chiffrée.
    @Published var includeSecrets: Bool { didSet { defaults?.set(includeSecrets, forKey: Key.includeSecrets) } }
    /// Mot de passe mémorisé au Trousseau (sauvegarde automatique chiffrée).
    @Published private(set) var hasStoredPassword = false
    /// Feuille de mot de passe à montrer.
    @Published var passwordRequest: PasswordRequest?

    private let defaults: UserDefaults?
    private var timer: Timer?

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("Sauvegardes", isDirectory: true)
    }

    nonisolated static var dataDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("NetScope", isDirectory: true)
    }

    nonisolated static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("NetScope/Sauvegardes", isDirectory: true)
    }

    /// Domaine des préférences de l'app (paquet installé ou exécutable SwiftPM).
    nonisolated static var preferencesDomain: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        automatic = defaults?.object(forKey: Key.automatic) as? Bool ?? true
        keep = defaults?.object(forKey: Key.keep) as? Int ?? 30
        format = defaults?.string(forKey: Key.format).flatMap(BackupFormat.init(rawValue:)) ?? .zip
        // Sans iCloud Drive, la copie n'aurait jamais lieu : l'option reste éteinte.
        copyToICloud = (defaults?.bool(forKey: Key.iCloud) ?? false) && (Self.iCloudFolder != nil || RegEnvironment.isDemo)
        folder = defaults?.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        lastBackup = defaults?.object(forKey: Key.last) as? Date
        pendingRestore = defaults?.string(forKey: Key.pending)
        encrypt = defaults?.bool(forKey: Key.encrypt) ?? false
        includeSecrets = defaults?.bool(forKey: Key.includeSecrets) ?? false
        if RegEnvironment.isDemo { loadDemo() }
    }

    var folderLabel: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    // MARK: Liste

    func refresh() {
        guard !RegEnvironment.isSandboxed else { return }
        let folder = self.folder
        Task {
            let list = await Task.detached { BackupEngine.list(in: folder) }.value
            // Note 25 : un jeton par FortiGate, nommé par son site dans la liste à ressaisir.
            let items = await Task.detached { BackupKeychainScan.describe(BackupKeychainScan.items(), fortiGates: FortiGateStore.savedControllers()) }.value
            let stored = await Task.detached { Self.storedPassword() != nil }.value
            self.backups = list
            self.keychainItems = items
            self.hasStoredPassword = stored
            if let newest = list.first?.date, newest > (self.lastBackup ?? .distantPast) { self.lastBackup = newest }
        }
    }

    // MARK: Sauvegarde

    /// Lancement : sauvegarde du jour si elle est due, puis vérification toutes les heures.
    func startSchedule() {
        guard !RegEnvironment.isSandboxed, timer == nil else { return }
        refresh()
        runIfDue()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in RegBackupController.shared.runIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func runIfDue() {
        guard automatic, !isWorking, pendingRestore == nil, BackupEngine.isAutomaticBackupDue(last: lastBackup) else { return }
        Task {
            let encryption = await scheduledEncryption()
            if encrypt, encryption == nil {
                // Chiffrement choisi sans mot de passe mémorisé : jamais de sauvegarde en clair à sa place.
                message = ("Sauvegarde automatique suspendue\u{00A0}: mémorisez le mot de passe des sauvegardes chiffrées (faites «\u{00A0}Sauvegarder maintenant\u{00A0}» et cochez «\u{00A0}Mémoriser dans le Trousseau\u{00A0}»).", .warning)
                return
            }
            await backup(kind: .automatique, encryption: encryption)
        }
    }

    func backupNow() {
        if RegEnvironment.isDemo {
            message = ("Démonstration\u{00A0}: aucune sauvegarde n’est écrite sur le disque.", .neutral)
            return
        }
        guard !isWorking else { return }
        Task {
            let encryption = await scheduledEncryption()
            if encrypt, encryption == nil {
                // Aucun mot de passe mémorisé (ou illisible) : il est demandé, jamais de repli en clair.
                passwordRequest = .backupNow
                return
            }
            await backup(kind: .manuelle, encryption: encryption)
        }
    }

    // MARK: Chiffrement (note 38)

    /// Mot de passe mémorisé au Trousseau, s'il y en a un.
    nonisolated static func storedPassword() -> String? {
        guard !RegEnvironment.isSandboxed else { return nil }
        return passwordKeychain.string(for: BackupPasswordKeychain.account).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Chiffrement des sauvegardes faites sans feuille (automatique, sécurité, « Sauvegarder
    /// maintenant » avec un mot de passe mémorisé) : seulement si un mot de passe est mémorisé ;
    /// sinon la sauvegarde habituelle, sans secret.
    /// La lecture du Trousseau se fait hors du fil principal : une demande d'accord de macOS ne
    /// bloque pas l'interface.
    private func scheduledEncryption() async -> BackupEncryption? {
        guard encrypt else { return nil }
        let password = await Task.detached(priority: .userInitiated) { Self.storedPassword() }.value
        guard let password else { return nil }
        return BackupEncryption(password: password, includeSecrets: includeSecrets)
    }

    /// Mot de passe saisi dans la feuille : mémorisé au Trousseau si demandé, puis la sauvegarde
    /// ou l'export en attente. Le mot de passe n'est gardé nulle part ailleurs.
    func submitPassword(_ password: String, remember: Bool, for request: PasswordRequest) {
        passwordRequest = nil
        if RegEnvironment.isDemo {
            message = ("Démonstration\u{00A0}: aucun mot de passe n’est enregistré, aucune sauvegarde n’est écrite.", .neutral)
            return
        }
        if remember {
            do {
                try Self.passwordKeychain.set(password, for: BackupPasswordKeychain.account)
                hasStoredPassword = true
            } catch {
                message = ("Mot de passe non mémorisé\u{00A0}: \(error.localizedDescription)", .warning)
            }
        }
        let encryption = BackupEncryption(password: password, includeSecrets: includeSecrets)
        switch request {
        case .backupNow:
            Task { await backup(kind: .manuelle, encryption: encryption) }
        case .export(let url):
            Task { await backup(kind: .manuelle, to: url, format: .zip, encryption: encryption) }
        case .define:
            if remember, hasStoredPassword {
                message = ("Mot de passe mémorisé dans le Trousseau\u{00A0}: la sauvegarde automatique quotidienne sera chiffrée.", .success)
            }
        }
    }

    /// Retire le mot de passe du Trousseau : la sauvegarde automatique redevient non chiffrée.
    func forgetPassword() {
        guard !RegEnvironment.isSandboxed else {
            message = ("Démonstration\u{00A0}: le Trousseau n’est pas modifié.", .neutral)
            return
        }
        do {
            try Self.passwordKeychain.delete(BackupPasswordKeychain.account)
            hasStoredPassword = false
            message = ("Mot de passe retiré du Trousseau. Les sauvegardes déjà chiffrées le demanderont à la restauration.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }

    /// Source de la sauvegarde : fichiers JSON, préférences de l'app, noms des comptes du Trousseau,
    /// et, pour une sauvegarde chiffrée « avec jetons et secrets », les secrets eux-mêmes.
    nonisolated static func makeSource(includingSecrets: Bool = false) -> BackupSource {
        UserDefaults.standard.synchronize()
        let domain = UserDefaults.standard.persistentDomain(forName: preferencesDomain) ?? [:]
        let preferences = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let info = Bundle.main.infoDictionary
        let controllers = FortiGateStore.savedControllers()
        var secrets: [BackupSecret] = []
        if includingSecrets {
            // Usages lisibles (« Jeton de l’API REST de la FortiGate · Siège ») pour l'écran de restauration.
            let usages = Dictionary(BackupKeychainScan.describe(BackupKeychainScan.items(), fortiGates: controllers)
                .map { ($0.service + "|" + $0.account, $0.usage) }, uniquingKeysWith: { a, _ in a })
            secrets = ((try? BackupKeychainSecrets().readSecrets()) ?? []).map { secret in
                var copy = secret
                copy.usage = usages[secret.service + "|" + secret.account] ?? secret.usage
                return copy
            }
        }
        return BackupSource(dataDirectory: dataDirectory, preferences: preferences, keychain: BackupKeychainScan.describe(BackupKeychainScan.items(), fortiGates: controllers),
                            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
                            appBuild: info?["CFBundleVersion"] as? String ?? "dev", secrets: secrets)
    }

    @discardableResult
    func backup(kind: BackupKind, to target: URL? = nil, format chosen: BackupFormat? = nil,
                encryption: BackupEncryption? = nil) async -> BackupInfo? {
        guard !RegEnvironment.isSandboxed else { return nil }
        workCount += 1
        defer { workCount -= 1 }
        // Les fichiers en mémoire sont écrits d'abord : la sauvegarde contient l'état actuel.
        MonStore.shared.save()
        InvModel.shared.flushPendingWrites()
        let folder = target ?? self.folder
        let format = chosen ?? self.format
        // Chiffrement choisi mais sauvegarde en clair (sauvegarde de sécurité sans mot de passe
        // mémorisé) : elle reste sur ce Mac, jamais copiée dans iCloud.
        let copyToICloud = self.copyToICloud && target == nil && !(encrypt && encryption == nil)
        do {
            let info = try await Task.detached(priority: .utility) { () throws -> BackupInfo in
                let source = Self.makeSource(includingSecrets: encryption?.includeSecrets == true)
                let info = try BackupEngine.create(source, in: folder, format: format, kind: kind, encryption: encryption)
                if copyToICloud, let cloud = Self.iCloudFolder {
                    try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: info.url, to: cloud.appendingPathComponent(info.url.lastPathComponent))
                }
                return info
            }.value
            if target == nil {
                lastBackup = info.date
                defaults?.set(info.date, forKey: Key.last)
                rotate()
            }
            if kind != .automatique {
                var label = kind == .securite ? "Sauvegarde de sécurité créée" : "Sauvegarde créée"
                if info.isEncrypted { label += info.includesSecrets ? " (chiffrée, avec les secrets du Trousseau)" : " (chiffrée)" }
                message = ("\(label)\u{00A0}: \(info.summary) (\(info.url.lastPathComponent)).", .success)
            }
            refresh()
            return info
        } catch {
            message = ("Sauvegarde impossible\u{00A0}: \(error.localizedDescription)", .critical)
            return nil
        }
    }

    /// Sauvegardes ordinaires que la rotation retirerait avec ce nombre gardé.
    func excessCount(keep: Int) -> Int {
        guard keep > 0 else { return 0 }
        return max(0, backups.filter { $0.manifest.kind != .securite }.count - keep)
    }

    /// Nouveau nombre gardé, confirmé : rotation tout de suite (vers la corbeille).
    func applyKeep(_ value: Int) {
        keep = value
        rotate(reportCount: true)
    }

    /// Rotation : les sauvegardes en trop vont à la corbeille (jamais supprimées définitivement).
    private func rotate(reportCount: Bool = false) {
        guard !RegEnvironment.isSandboxed else { return }
        let folder = self.folder, keep = self.keep
        Task.detached(priority: .utility) {
            let removed = (try? BackupEngine.rotate(in: folder, keep: keep,
                                                    remove: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })) ?? []
            await MainActor.run {
                let controller = RegBackupController.shared
                if reportCount, !removed.isEmpty {
                    let n = removed.count
                    controller.message = ("\(n) sauvegarde\(n > 1 ? "s" : "") placée\(n > 1 ? "s" : "") dans la corbeille.", .success)
                }
                controller.refresh()
            }
        }
    }

    // MARK: Dossier, export, import

    func chooseFolder() {
        guard !RegEnvironment.isSandboxed else { return }
        let panel = NSOpenPanel()
        panel.title = "Dossier des sauvegardes"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Jamais dans le dossier des données : la sauvegarde se recopierait elle-même.
        let data = Self.dataDirectory.standardizedFileURL.path
        if url.standardizedFileURL.path == data || url.standardizedFileURL.path.hasPrefix(data + "/") {
            message = ("Choisissez un autre dossier que celui des données de NetScope (Application Support).", .warning)
            return
        }
        folder = url
        defaults?.set(url.path, forKey: Key.folder)
        message = ("Les sauvegardes iront dans \(folderLabel).", .success)
        refresh()
    }

    func revealInFinder(_ info: BackupInfo? = nil) {
        guard !RegEnvironment.isSandboxed else { return }
        if let info {
            NSWorkspace.shared.activateFileViewerSelecting([info.url])
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// Sauvegarde ponctuelle à l'endroit choisi (archive .zip).
    func exportAs() {
        guard !RegEnvironment.isDemo else {
            message = ("Démonstration\u{00A0}: aucune archive n’est écrite.", .neutral)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Exporter une sauvegarde"
        panel.message = encrypt
            ? "Choisissez le dossier où enregistrer l’archive chiffrée (.netscope-backup) de la sauvegarde."
            : "Choisissez le dossier où enregistrer l’archive (.zip) de la sauvegarde."
        panel.prompt = "Exporter ici"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard !isWorking, panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let encryption = await scheduledEncryption()
            if encrypt, encryption == nil {
                passwordRequest = .export(url)
                return
            }
            await backup(kind: .manuelle, to: url, format: .zip, encryption: encryption)
        }
    }

    /// Choix d'une sauvegarde hors du dossier (autre Mac, clé USB), à restaurer.
    func pickArchiveToRestore() -> BackupInfo? {
        guard !RegEnvironment.isSandboxed else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Restaurer une sauvegarde"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder] + [UTType(filenameExtension: BackupEngine.encryptedExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try BackupEngine.info(at: url)
        } catch {
            message = (error.localizedDescription, .critical)
            return nil
        }
    }

    func delete(_ info: BackupInfo) {
        guard !RegEnvironment.isSandboxed else { return }
        do {
            try FileManager.default.trashItem(at: info.url, resultingItemURL: nil)
            message = ("Sauvegarde du \(RegFormat.moment(info.date)) placée dans la corbeille.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
        refresh()
    }

    // MARK: Restauration

    /// Restauration confirmée : sauvegarde de sécurité de l'état actuel, puis redémarrage ; la
    /// sauvegarde choisie est appliquée au lancement suivant (`applyPendingRestore`).
    func restore(_ info: BackupInfo) {
        if RegEnvironment.isDemo {
            message = ("Démonstration\u{00A0}: rien n’est restauré.", .neutral)
            return
        }
        Task {
            do {
                _ = try await Task.detached { try BackupEngine.read(info.url) }.value
            } catch {
                message = (error.localizedDescription, .critical)
                return
            }
            guard await backup(kind: .securite, encryption: await scheduledEncryption()) != nil else {
                message = ("Restauration annulée\u{00A0}: la sauvegarde de sécurité de l’état actuel a échoué.", .critical)
                return
            }
            discardTemporaryPending()
            defaults?.set(info.url.path, forKey: Key.pending)
            defaults?.removeObject(forKey: Key.pendingIsTemporary)
            defaults?.removeObject(forKey: Key.restoredSecrets)
            defaults?.synchronize()
            pendingRestore = info.url.path
            relaunch()
        }
    }

    /// Note 38 : ouvre une sauvegarde chiffrée avec le mot de passe saisi (dérivation lente, hors du
    /// fil principal). Mauvais mot de passe ou fichier modifié : une erreur, rien n'est restauré.
    nonisolated func unlock(_ info: BackupInfo, password: String) async -> Result<BackupContents, Error> {
        if RegEnvironment.isDemo {
            return password == ReglagesDemo.demoPassword ? .success(ReglagesDemo.unlockedContents(info)) : .failure(BackupCryptoError.wrongPassword)
        }
        return await Task.detached(priority: .userInitiated) {
            Result { try BackupEngine.read(info.url, password: password) }
        }.value
    }

    /// Restauration confirmée d'une sauvegarde chiffrée déjà ouverte : sauvegarde de sécurité de
    /// l'état actuel, archive en attente SANS secret (le mot de passe n'est pas gardé jusqu'au
    /// redémarrage), secrets remis au Trousseau si demandé, puis redémarrage.
    func restoreEncrypted(_ info: BackupInfo, contents: BackupContents, restoreSecrets: Bool) {
        if RegEnvironment.isDemo {
            message = ("Démonstration\u{00A0}: rien n’est restauré, le Trousseau n’est pas modifié.", .neutral)
            return
        }
        Task {
            guard await backup(kind: .securite, encryption: await scheduledEncryption()) != nil else {
                message = ("Restauration annulée\u{00A0}: la sauvegarde de sécurité de l’état actuel a échoué.", .critical)
                return
            }
            let staged = Self.dataDirectory.appendingPathComponent(".restauration-en-attente.zip")
            do {
                try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
                try BackupEngine.plainArchive(of: contents).write(to: staged, options: .atomic)
            } catch {
                message = ("Restauration annulée\u{00A0}: \(error.localizedDescription)", .critical)
                return
            }
            var restored = 0
            if restoreSecrets, !contents.secrets.isEmpty {
                let secrets = contents.secrets
                let failed = await Task.detached { BackupEngine.restoreSecrets(secrets, to: BackupKeychainSecrets()) }.value
                restored = secrets.count - failed.count
                if !failed.isEmpty {
                    // Le redémarrage attend : l'utilisateur voit quels secrets ressaisir.
                    message = ("\(failed.count) secret\(failed.count > 1 ? "s" : "") non remis au Trousseau\u{00A0}: "
                               + failed.map(\.usage).joined(separator: ", ") + ". La restauration des fichiers se fera au prochain lancement.", .warning)
                }
            }
            defaults?.set(staged.path, forKey: Key.pending)
            defaults?.set(true, forKey: Key.pendingIsTemporary)
            defaults?.set(restored, forKey: Key.restoredSecrets)
            defaults?.synchronize()
            pendingRestore = staged.path
            if message?.tone != .warning { relaunch() }
        }
    }

    /// Archive en clair tirée d'une sauvegarde chiffrée et restée en attente (secrets non remis,
    /// pas de redémarrage) : effacée avant qu'une autre restauration ne la remplace.
    private func discardTemporaryPending() {
        guard let defaults, defaults.bool(forKey: Key.pendingIsTemporary) else { return }
        if let path = defaults.string(forKey: Key.pending) { try? FileManager.default.removeItem(atPath: path) }
        defaults.removeObject(forKey: Key.pendingIsTemporary)
    }

    /// Note 56 : sauvegarde de sécurité de l'état actuel avant un import de configuration ou
    /// l'application de changements reçus (chiffrée si un mot de passe est mémorisé).
    func safetyBackup() async -> BackupInfo? {
        await backup(kind: .securite, encryption: await scheduledEncryption())
    }

    /// Relance NetScope (application installée) ; avec `swift run`, demande de rouvrir à la main.
    func relaunch() {
        guard let bundle = UpdInstaller.runningBundle() else {
            message = ("Restauration prête\u{00A0}: quittez NetScope et rouvrez-le pour l’appliquer.", .warning)
            return
        }
        // Attend la fin de ce processus (ses fichiers sont écrits en quittant), puis rouvre l'app.
        let pid = ProcessInfo.processInfo.processIdentifier
        // Valeurs passées en arguments positionnels, jamais insérées dans le script (chemin avec « " » ou « $( »).
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), bundle.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Au lancement, avant les écrans : applique la restauration en attente (fichiers puis préférences).
    nonisolated static func applyPendingRestore() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Key.pending) else { return }
        defaults.removeObject(forKey: Key.pending)
        let temporary = defaults.bool(forKey: Key.pendingIsTemporary)
        defaults.removeObject(forKey: Key.pendingIsTemporary)
        // Archive tirée d'une sauvegarde chiffrée : effacée, réussite ou non.
        defer { if temporary { try? FileManager.default.removeItem(atPath: path) } }
        do {
            let contents = try BackupEngine.read(URL(fileURLWithPath: path))
            try BackupEngine.restoreFiles(contents, to: dataDirectory)
            let current = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
            var merged = BackupEngine.mergedPreferences(backup: contents.preferences, current: current, preserving: ["sauvegarde."])
            merged.removeValue(forKey: Key.pending)
            merged.removeValue(forKey: Key.pendingIsTemporary)
            merged["sauvegarde.derniereRestauration"] = temporary ? "sauvegarde chiffrée du \(contents.manifest.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "fr_FR"))))"
                : (path as NSString).lastPathComponent
            defaults.setPersistentDomain(merged, forName: preferencesDomain)
            defaults.synchronize()
        } catch {
            defaults.set("Restauration impossible\u{00A0}: \(error.localizedDescription)", forKey: "sauvegarde.erreurRestauration")
        }
    }

    /// Message laissé par la restauration du lancement (réussie ou non), lu une fois.
    func takeRestoreReport() {
        guard let defaults else { return }
        if let error = defaults.string(forKey: "sauvegarde.erreurRestauration") {
            message = (error, .critical)
            defaults.removeObject(forKey: "sauvegarde.erreurRestauration")
        } else if let name = defaults.string(forKey: "sauvegarde.derniereRestauration") {
            let secrets = defaults.integer(forKey: Key.restoredSecrets)
            let tail = secrets > 0
                ? " \(secrets) secret\(secrets > 1 ? "s" : "") remis au Trousseau."
                : " Ressaisissez au besoin les secrets du Trousseau (une sauvegarde non chiffrée n’en contient jamais)."
            message = ("Sauvegarde restaurée\u{00A0}: \(name).\(tail)", .success)
            defaults.removeObject(forKey: "sauvegarde.derniereRestauration")
            defaults.removeObject(forKey: Key.restoredSecrets)
        }
    }

    // MARK: Démonstration

    private func loadDemo() {
        let demo = ReglagesDemo.backups()
        backups = demo
        lastBackup = demo.first?.date
        keychainItems = ReglagesDemo.encryptedSecrets.map(\.item)
        folder = Self.defaultFolder
        encrypt = true
        includeSecrets = true
        hasStoredPassword = true
    }
}
