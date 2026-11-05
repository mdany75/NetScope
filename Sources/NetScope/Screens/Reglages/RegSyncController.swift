import AppKit
import NetScopeCore
import SwiftUI

/// Note 56 : synchronisation de la configuration entre les Mac de l'utilisateur par iCloud Drive
/// (dossier NetScope/Sync, jamais CloudKit). Désactivée par défaut ; on choisit les sites à
/// synchroniser. Les jetons des FortiGate voyagent chiffrés par un mot de passe de synchronisation
/// gardé au Trousseau de chaque Mac (le même sur tous les Mac).
///
/// « Synchroniser maintenant » (et toutes les 15 minutes, et au lancement) : publie la version de
/// ce Mac, lit celles des autres, fusionne par date ; les jetons reçus vont au Trousseau tout de
/// suite, le reste est appliqué au lancement suivant (« Redémarrer et appliquer »), pour qu'aucune
/// donnée en mémoire ne le réécrive. En démonstration et pendant les captures : état fictif, rien
/// n'est lu ni écrit (ni iCloud Drive, ni Trousseau).
@MainActor
final class RegSyncController: ObservableObject {
    static let shared = RegSyncController()

    enum Key {
        static let enabled = "synchro.active"
        static let sites = "synchro.sites"
        static let device = "synchro.appareil"
        static let last = "synchro.derniere"
        static let report = "synchro.bilanApplication"
    }

    /// Dossier caché de ce Mac : état de la fusion et changements en attente (jamais sauvegardés).
    nonisolated static var localFolder: URL { RegBackupController.dataDirectory.appendingPathComponent(".synchro", isDirectory: true) }
    nonisolated static var stateURL: URL { localFolder.appendingPathComponent("etat.json") }
    nonisolated static var pendingURL: URL { localFolder.appendingPathComponent("en-attente.json") }

    /// iCloud Drive › NetScope › Sync ; nil si iCloud Drive n'est pas activé sur ce Mac.
    nonisolated static var syncFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("NetScope/Sync", isDirectory: true)
    }

    nonisolated static let keychain = UpdKeychain(service: ConfigSecrets.syncService)
    static let interval: TimeInterval = 15 * 60

    @Published var enabled: Bool {
        didSet {
            guard !RegEnvironment.isSandboxed else { return }
            defaults?.set(enabled, forKey: Key.enabled)
            if enabled { start(); syncNow() } else { stop() }
        }
    }
    /// Sites synchronisés (identifiants).
    @Published private(set) var siteIDs: Set<UUID>
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var hasPassword = false
    @Published private(set) var conflicts: [ConfigSyncConflict] = []
    /// Sites publiés par d'autres Mac, absents de ce Mac.
    @Published private(set) var remoteSites: [ConfigSyncRemoteSite] = []
    /// Changements reçus en attente du redémarrage.
    @Published private(set) var pendingCount = 0
    /// Résumé du dernier passage (« 3 reçus de MacBook Air, 1 envoyé »).
    @Published private(set) var lastSummary: String?
    @Published var message: (text: String, tone: Tone)?
    @Published var passwordSheet = false
    /// Heure affichée (« il y a… »), rafraîchie chaque minute.
    @Published private(set) var now = Date()

    let deviceID: String
    let deviceName: String
    private let defaults: UserDefaults?
    private var timer: Timer?
    private var clock: Timer?

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if let saved = defaults?.string(forKey: Key.device) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults?.set(deviceID, forKey: Key.device)
        }
        deviceName = RegEnvironment.isSandboxed ? ConfigSyncDemo.deviceName : RegConfigController.deviceName
        enabled = defaults?.bool(forKey: Key.enabled) ?? false
        siteIDs = Set((defaults?.stringArray(forKey: Key.sites) ?? []).compactMap(UUID.init(uuidString:)))
        lastSync = defaults?.object(forKey: Key.last) as? Date
        if RegEnvironment.isSandboxed {
            loadDemo()
        } else {
            conflicts = ConfigSyncEngine.loadState(from: Self.stateURL).conflicts
            pendingCount = Self.pendingOperationCount()
        }
    }

    var isAvailable: Bool { RegEnvironment.isSandboxed || Self.syncFolder != nil }

    var folderLabel: String {
        "iCloud Drive › NetScope › Sync"
    }

    // MARK: Lancement et minuterie

    /// Au lancement (après l'application des changements en attente) : synchro si activée.
    func startIfEnabled() {
        guard enabled, !RegEnvironment.isSandboxed else { return }
        start()
        syncNow(quiet: true)
    }

    private func start() {
        guard !RegEnvironment.isSandboxed, timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in RegSyncController.shared.syncNow(quiet: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { hasPassword = await Task.detached { Self.storedPassword() != nil }.value }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Rafraîchit « il y a… » tant que la section est affichée.
    func appear() {
        now = Date()
        if !RegEnvironment.isSandboxed {
            Task {
                hasPassword = await Task.detached { Self.storedPassword() != nil }.value
                refreshRemoteSites()
            }
            takeReport()
        }
        guard clock == nil else { return }
        let clock = Timer(timeInterval: 30, repeats: true) { _ in Task { @MainActor in RegSyncController.shared.now = Date() } }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    func disappear() {
        clock?.invalidate()
        clock = nil
    }

    // MARK: Sites

    func isSynced(_ id: UUID) -> Bool { siteIDs.contains(id) }

    func setSynced(_ id: UUID, _ on: Bool) {
        if on { siteIDs.insert(id) } else { siteIDs.remove(id) }
        defaults?.set(siteIDs.map(\.uuidString).sorted(), forKey: Key.sites)
        if on, enabled { syncNow() }
    }

    /// Site d'un autre Mac : synchronisé ici aussi (reçu à la prochaine synchro, appliqué au redémarrage).
    func addRemoteSite(_ site: ConfigSyncRemoteSite) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: «\u{00A0}\(site.name)\u{00A0}» n’est pas ajouté.", .neutral)
            return
        }
        setSynced(site.id, true)
        if !enabled { syncNow() }
    }

    private func refreshRemoteSites() {
        guard let root = Self.syncFolder else { remoteSites = []; return }
        let local = Set(SiteModel.shared.sites.map(\.id))
        let engine = ConfigSyncEngine(root: root, deviceID: deviceID, deviceName: deviceName, password: nil)
        Task {
            remoteSites = await Task.detached { engine.availableSites(excluding: local) }.value
        }
    }

    // MARK: Mot de passe

    nonisolated static func storedPassword() -> String? {
        guard !RegEnvironment.isSandboxed else { return nil }
        return keychain.string(for: ConfigSecrets.syncAccount).flatMap { $0.isEmpty ? nil : $0 }
    }

    func setPassword(_ password: String) {
        passwordSheet = false
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: le Trousseau n’est pas modifié.", .neutral)
            return
        }
        do {
            try Self.keychain.set(password, for: ConfigSecrets.syncAccount)
            hasPassword = true
            message = ("Mot de passe de synchronisation enregistré dans le Trousseau de ce Mac. Saisissez le même sur vos autres Mac.", .success)
            if enabled { syncNow() }
        } catch {
            message = ("Mot de passe non enregistré\u{00A0}: \(error.localizedDescription)", .critical)
        }
    }

    func forgetPassword() {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: le Trousseau n’est pas modifié.", .neutral)
            return
        }
        try? Self.keychain.delete(ConfigSecrets.syncAccount)
        hasPassword = false
        message = ("Mot de passe de synchronisation retiré\u{00A0}: les jetons ne sont plus synchronisés depuis ce Mac.", .success)
    }

    // MARK: Synchronisation

    func syncNow(quiet: Bool = false) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: iCloud Drive n’est ni lu ni modifié.", .neutral)
            return
        }
        guard !isSyncing else { return }
        guard let root = Self.syncFolder else {
            if !quiet { message = ("iCloud Drive n’est pas activé sur ce Mac (Réglages Système › Identifiant Apple › iCloud).", .warning) }
            return
        }
        guard pendingCount == 0 else {
            if !quiet { message = ("Des changements reçus attendent le redémarrage\u{00A0}: redémarrez NetScope avant de synchroniser de nouveau.", .warning) }
            return
        }
        let ids = Array(siteIDs)
        guard !ids.isEmpty else {
            if !quiet { message = ("Cochez au moins un site à synchroniser.", .neutral) }
            return
        }
        isSyncing = true
        MonStore.shared.save()
        InvModel.shared.flushPendingWrites()
        let deviceID = deviceID, deviceName = deviceName
        Task {
            defer { isSyncing = false }
            let outcome = await Task.detached(priority: .utility) { () -> Result<(ConfigSyncReport, ConfigSyncState), Error> in
                Result {
                    let password = Self.storedPassword()
                    let fortiService = BackupKeychainScan.servicePrefix + ".fortigate"
                    // Seuls les jetons des FortiGate sont lus (ceux des sites synchronisés en sont tirés).
                    let secrets = password == nil ? [] : ((try? BackupKeychainSecrets().readSecrets()) ?? []).filter { $0.service == fortiService }
                    let snapshot = ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory,
                                                       preferences: RegConfigController.currentPreferences(), secrets: secrets)
                    var state = ConfigSyncEngine.loadState(from: Self.stateURL)
                    let engine = ConfigSyncEngine(root: root, deviceID: deviceID, deviceName: deviceName, password: password)
                    let report = try engine.sync(sites: ids, snapshot: snapshot, state: &state)
                    if !report.plan.secrets.isEmpty {
                        _ = BackupEngine.restoreSecrets(report.plan.secrets, to: BackupKeychainSecrets())
                    }
                    let pending = report.plan.withoutSecrets
                    if !pending.isEmpty {
                        try RegConfigController.savePending(pending, secretsRestored: 0, to: Self.pendingURL)
                    }
                    try ConfigSyncEngine.saveState(state, to: Self.stateURL)
                    return (report, state)
                }
            }.value
            switch outcome {
            case .success(let (report, state)):
                lastSync = state.lastSync
                defaults?.set(state.lastSync, forKey: Key.last)
                conflicts = state.conflicts
                pendingCount = Self.pendingOperationCount()
                lastSummary = Self.summary(report)
                if !report.errors.isEmpty {
                    message = (report.errors.joined(separator: " "), .warning)
                } else if !report.conflicts.isEmpty {
                    message = (MonText.plural(report.conflicts.count, "conflit", "conflits") + "\u{00A0}: la version la plus récente a été gardée, l’autre peut être rétablie ci-dessous.", .warning)
                } else if pendingCount > 0 {
                    message = (MonText.plural(pendingCount, "changement reçu", "changements reçus") + "\u{00A0}: redémarrez NetScope pour l’appliquer.", .accent)
                } else if report.secretsSkipped, !quiet {
                    message = ("Synchronisé, sans les jetons\u{00A0}: définissez le mot de passe de synchronisation.", .warning)
                } else if !quiet {
                    message = ("Synchronisé.", .success)
                }
                refreshRemoteSites()
            case .failure(let error):
                message = ("Synchronisation impossible\u{00A0}: \(error.localizedDescription)", .critical)
            }
        }
    }

    /// « 3 reçus de MacBook Air · 1 envoyé · 1 conflit ».
    nonisolated static func summary(_ report: ConfigSyncReport) -> String {
        var parts: [String] = []
        if !report.received.isEmpty {
            let devices = Set(report.received.map(\.device)).sorted().joined(separator: ", ")
            parts.append("\(report.received.count) reçu\(report.received.count > 1 ? "s" : "") de \(devices)")
        }
        if !report.sent.isEmpty { parts.append("\(report.sent.count) envoyé\(report.sent.count > 1 ? "s" : "")") }
        if !report.conflicts.isEmpty { parts.append(MonText.plural(report.conflicts.count, "conflit", "conflits")) }
        if !report.deletions.isEmpty { parts.append("site supprimé sur " + Set(report.deletions.map(\.device)).sorted().joined(separator: ", ")) }
        return parts.isEmpty ? "Aucun changement" : parts.joined(separator: " · ")
    }

    nonisolated static func pendingOperationCount() -> Int {
        guard let data = try? Data(contentsOf: pendingURL),
              let pending = try? BackupEngine.decoder().decode(RegConfigController.Pending.self, from: data) else { return 0 }
        return pending.plan.operationCount
    }

    /// Changements reçus : sauvegarde de sécurité, puis redémarrage (appliqués au lancement).
    func applyAndRelaunch() {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: rien n’est appliqué.", .neutral)
            return
        }
        Task {
            guard await RegBackupController.shared.safetyBackup() != nil else {
                message = ("Redémarrage annulé\u{00A0}: la sauvegarde de sécurité de l’état actuel a échoué.", .critical)
                return
            }
            if UpdInstaller.runningBundle() == nil {
                message = ("Quittez NetScope et rouvrez-le pour appliquer les changements reçus.", .warning)
            }
            RegBackupController.shared.relaunch()
        }
    }

    /// Au lancement, avant les écrans.
    nonisolated static func applyPending() {
        RegConfigController.applyPending(at: pendingURL, reportKey: Key.report)
    }

    private func takeReport() {
        guard let text = defaults?.string(forKey: Key.report) else { return }
        defaults?.removeObject(forKey: Key.report)
        message = (text, .success)
    }

    // MARK: Conflits

    /// Rétablit la version écartée (appliquée au redémarrage, puis envoyée aux autres Mac).
    func restore(_ conflict: ConfigSyncConflict) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: rien n’est rétabli.", .neutral)
            return
        }
        Task {
            let plan = await Task.detached {
                ConfigSyncEngine.restorePlan(conflict, snapshot: ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory,
                                                                                     preferences: RegConfigController.currentPreferences()))
            }.value
            guard let plan else {
                message = ("Cette version ne peut pas être rétablie (un jeton n’est jamais gardé en clair).", .warning)
                return
            }
            do {
                // Des changements reçus attendent peut-être déjà le redémarrage : la restauration s'y
                // ajoute (etat.json les croit appliqués ; les perdre ferait republier l'ancienne version).
                var merged = plan
                var secretsRestored = 0
                if let data = try? Data(contentsOf: Self.pendingURL) {
                    guard let waiting = try? BackupEngine.decoder().decode(RegConfigController.Pending.self, from: data) else {
                        message = ("Des changements reçus attendent le redémarrage\u{00A0}: redémarrez d’abord NetScope pour les appliquer.", .warning)
                        return
                    }
                    merged = waiting.plan.merging(plan)
                    secretsRestored = waiting.secretsRestored
                }
                try RegConfigController.savePending(merged, secretsRestored: secretsRestored, to: Self.pendingURL)
                dismiss(conflict)
                pendingCount = Self.pendingOperationCount()
                message = ("Version de «\u{00A0}\(conflict.otherDevice)\u{00A0}» prête\u{00A0}: redémarrez NetScope pour la rétablir.", .accent)
            } catch {
                message = (error.localizedDescription, .critical)
            }
        }
    }

    func dismiss(_ conflict: ConfigSyncConflict) {
        conflicts.removeAll { $0.id == conflict.id }
        guard !RegEnvironment.isSandboxed else { return }
        var state = ConfigSyncEngine.loadState(from: Self.stateURL)
        state.conflicts.removeAll { $0.id == conflict.id }
        try? ConfigSyncEngine.saveState(state, to: Self.stateURL)
    }

    // MARK: Démonstration

    private func loadDemo() {
        let demo = ConfigSyncDemo.state()
        enabled = demo.enabled
        siteIDs = demo.siteIDs
        lastSync = demo.lastSync
        hasPassword = true
        conflicts = demo.conflicts
        remoteSites = demo.remoteSites
        pendingCount = demo.pendingCount
        lastSummary = demo.summary
        now = ConfigSyncDemo.now
    }
}

enum RegSyncFormat {
    /// « à l’instant », « il y a 4 min », « il y a 2 h », « hier à 14 h 05 », sinon la date.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "à l’instant" }
        if seconds < 3600 { return "il y a \(Int(seconds / 60))\u{00A0}min" }
        if seconds < 86_400 { return "il y a \(Int(seconds / 3600))\u{00A0}h" }
        return "le " + RegFormat.moment(date)
    }
}
