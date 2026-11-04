import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Sauvegardes de NetScope (Réglages › Export et sauvegarde) : sauvegarde automatique quotidienne,
/// « Sauvegarder maintenant », liste, rotation et restauration. La restauration se termine au
/// lancement suivant (avant que les écrans ne lisent leurs fichiers), pour qu'aucune donnée en
/// mémoire ne réécrive l'état restauré en quittant.
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
    }

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
        if RegEnvironment.isDemo { loadDemo() }
    }

    var folderLabel: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    // MARK: Liste

    func refresh() {
        guard !RegEnvironment.isSandboxed else { return }
        let folder = self.folder
        Task {
            let list = await Task.detached { BackupEngine.list(in: folder) }.value
            let items = await Task.detached { BackupKeychainScan.items() }.value
            self.backups = list
            self.keychainItems = items
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
        Task { await backup(kind: .automatique) }
    }

    func backupNow() {
        if RegEnvironment.isDemo {
            message = ("Démonstration\u{00A0}: aucune sauvegarde n’est écrite sur le disque.", .neutral)
            return
        }
        guard !isWorking else { return }
        Task { await backup(kind: .manuelle) }
    }

    /// Source de la sauvegarde : fichiers JSON, préférences de l'app, noms des comptes du Trousseau.
    nonisolated static func makeSource() -> BackupSource {
        UserDefaults.standard.synchronize()
        let domain = UserDefaults.standard.persistentDomain(forName: preferencesDomain) ?? [:]
        let preferences = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let info = Bundle.main.infoDictionary
        return BackupSource(dataDirectory: dataDirectory, preferences: preferences, keychain: BackupKeychainScan.items(),
                            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
                            appBuild: info?["CFBundleVersion"] as? String ?? "dev")
    }

    @discardableResult
    func backup(kind: BackupKind, to target: URL? = nil, format chosen: BackupFormat? = nil) async -> BackupInfo? {
        guard !RegEnvironment.isSandboxed else { return nil }
        workCount += 1
        defer { workCount -= 1 }
        // Les fichiers en mémoire sont écrits d'abord : la sauvegarde contient l'état actuel.
        MonStore.shared.save()
        let folder = target ?? self.folder
        let format = chosen ?? self.format
        let copyToICloud = self.copyToICloud && target == nil
        do {
            let info = try await Task.detached(priority: .utility) { () throws -> BackupInfo in
                let info = try BackupEngine.create(Self.makeSource(), in: folder, format: format, kind: kind)
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
                let label = kind == .securite ? "Sauvegarde de sécurité créée" : "Sauvegarde créée"
                message = ("\(label)\u{00A0}: \(info.manifest.summary) (\(info.url.lastPathComponent)).", .success)
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
        panel.message = "Choisissez le dossier où enregistrer l’archive (.zip) de la sauvegarde."
        panel.prompt = "Exporter ici"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard !isWorking, panel.runModal() == .OK, let url = panel.url else { return }
        Task { await backup(kind: .manuelle, to: url, format: .zip) }
    }

    /// Choix d'une sauvegarde hors du dossier (autre Mac, clé USB), à restaurer.
    func pickArchiveToRestore() -> BackupInfo? {
        guard !RegEnvironment.isSandboxed else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Restaurer une sauvegarde"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
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
            guard await backup(kind: .securite) != nil else {
                message = ("Restauration annulée\u{00A0}: la sauvegarde de sécurité de l’état actuel a échoué.", .critical)
                return
            }
            defaults?.set(info.url.path, forKey: Key.pending)
            defaults?.synchronize()
            pendingRestore = info.url.path
            relaunch()
        }
    }

    /// Relance NetScope (application installée) ; avec `swift run`, demande de rouvrir à la main.
    private func relaunch() {
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
        do {
            let contents = try BackupEngine.read(URL(fileURLWithPath: path))
            try BackupEngine.restoreFiles(contents, to: dataDirectory)
            let current = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
            var merged = BackupEngine.mergedPreferences(backup: contents.preferences, current: current, preserving: ["sauvegarde."])
            merged.removeValue(forKey: Key.pending)
            merged["sauvegarde.derniereRestauration"] = (path as NSString).lastPathComponent
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
            message = ("Sauvegarde restaurée\u{00A0}: \(name). Ressaisissez au besoin les secrets du Trousseau (ils ne sont jamais sauvegardés).", .success)
            defaults.removeObject(forKey: "sauvegarde.derniereRestauration")
        }
    }

    // MARK: Démonstration

    private func loadDemo() {
        let demo = ReglagesDemo.backups()
        backups = demo
        lastBackup = demo.first?.date
        keychainItems = ReglagesDemo.keychainItems
        folder = Self.defaultFolder
    }
}
