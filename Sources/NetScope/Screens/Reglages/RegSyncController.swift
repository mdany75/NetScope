import AppKit
import NetScopeCore
import SwiftUI

/// Notes 56 et 86 : synchronisation des données entre les Mac de l'utilisateur, par un simple
/// dossier : iCloud Drive › NetScope › Sync par défaut (jamais CloudKit), ou un autre dossier
/// (OneDrive, NAS monté, dossier partagé). Désactivée par défaut ; une fois activée, TOUT est
/// synchronisé (tous les sites et les données globales), par catégories qu'on peut décocher.
/// Les secrets voyagent chiffrés par un mot de passe de synchronisation gardé au Trousseau de
/// chaque Mac (le même sur tous les Mac).
///
/// Déclenchement : quelques secondes après un changement local (fichiers suivis du dossier de
/// données et réglages synchronisés), à l'activation de l'app, quand un autre Mac change un
/// fichier du dossier de synchronisation, et toutes les 15 minutes ; jamais pendant un scan.
/// Les changements reçus s'appliquent À CHAUD (les magasins relisent, `RegSyncReload`) ; seul
/// un fichier sans magasin connu attend le redémarrage (« Redémarrer et appliquer »).
/// En démonstration et pendant les captures : état fictif, rien n'est lu ni écrit (ni dossier de
/// synchronisation, ni Trousseau, ni surveillance des fichiers).
@MainActor
final class RegSyncController: ObservableObject {
    static let shared = RegSyncController()

    enum Key {
        static let enabled = "synchro.active"
        /// 0.18 à 0.28 : sites cochés un par un (relu une fois, à la migration).
        static let sites = "synchro.sites"
        /// Note 86 : sites décochés (tous les autres sont synchronisés).
        static let excludedSites = "synchro.sitesExclus"
        /// Sites d'un autre Mac ajoutés à ce Mac (reçus à la synchronisation suivante).
        static let addedSites = "synchro.sitesAjoutes"
        static let migrated = "synchro.migration86"
        static let disabledCategories = "synchro.categoriesDecochees"
        static let folder = "synchro.dossier"
        static let device = "synchro.appareil"
        static let last = "synchro.derniere"
        static let report = "synchro.bilanApplication"
    }

    /// Dossier caché de ce Mac : état de la fusion et changements en attente (jamais sauvegardés).
    nonisolated static var localFolder: URL { RegBackupController.dataDirectory.appendingPathComponent(".synchro", isDirectory: true) }
    nonisolated static var stateURL: URL { localFolder.appendingPathComponent("etat.json") }
    nonisolated static var pendingURL: URL { localFolder.appendingPathComponent("en-attente.json") }

    /// iCloud Drive › NetScope › Sync ; nil si iCloud Drive n'est pas activé sur ce Mac.
    nonisolated static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("NetScope/Sync", isDirectory: true)
    }

    /// Ancien nom (0.18) : le dossier iCloud Drive.
    nonisolated static var syncFolder: URL? { iCloudFolder }

    nonisolated static let keychain = UpdKeychain(service: ConfigSecrets.syncService)
    static let interval: TimeInterval = 15 * 60
    /// Délai après le dernier changement local avant de synchroniser.
    static let debounce: TimeInterval = 4

    @Published var enabled: Bool {
        didSet {
            guard !RegEnvironment.isSandboxed, enabled != oldValue else { return }
            defaults?.set(enabled, forKey: Key.enabled)
            if enabled { start(); syncNow() } else { stop() }
        }
    }
    @Published private(set) var excludedSites: Set<UUID>
    @Published private(set) var addedSites: Set<UUID>
    @Published private(set) var disabledCategories: Set<String>
    /// Autre dossier que iCloud Drive (OneDrive, NAS, partage) ; nil : iCloud Drive.
    @Published private(set) var customFolder: URL?
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var hasPassword = false
    @Published private(set) var conflicts: [ConfigSyncConflict] = []
    @Published private(set) var pendingDeletions: [ConfigSyncDeletion] = []
    @Published private(set) var recent: [ConfigSyncChange] = []
    @Published private(set) var devices: [ConfigSyncDevice] = []
    @Published private(set) var olderDevices: [ConfigSyncDevice] = []
    @Published private(set) var counts: [ConfigSyncGlobal.CategoryCount] = []
    /// Sites publiés par d'autres Mac, absents de ce Mac.
    @Published private(set) var remoteSites: [ConfigSyncRemoteSite] = []
    /// Changements reçus en attente du redémarrage (fichiers sans magasin relu à chaud).
    @Published private(set) var pendingCount = 0
    /// Résumé du dernier passage (« 3 reçus de MacBook Air, 1 envoyé »).
    @Published private(set) var lastSummary: String?
    @Published var message: (text: String, tone: Tone)? {
        didSet { RegDiagnosticController.note(message, module: "Synchronisation") }
    }
    @Published var passwordSheet = false
    /// Heure affichée (« il y a… »), rafraîchie toutes les 30 secondes.
    @Published private(set) var now = Date()

    let deviceID: String
    let deviceName: String
    let deviceModel: String
    let appVersion: String
    private let defaults: UserDefaults?
    private weak var appState: AppState?
    private var timer: Timer?
    private var clock: Timer?
    private var debounceTask: Task<Void, Never>?
    private var rerun = false
    private var watchers: [RegSyncWatcher] = []
    private var observers: [NSObjectProtocol] = []
    /// Nos propres écritures (application des changements reçus) ne relancent pas de synchro.
    private var suppressUntil = Date.distantPast
    /// Empreinte des réglages synchronisés (un clic sur un onglet ne relance rien).
    private var preferencesSignature = ""
    /// Décisions prises pendant une synchronisation (conflits écartés, suppressions oubliées ou
    /// gardées) : la synchro réécrit l'état à sa fin, elles y sont donc rejouées ensuite.
    private var decidedConflicts: Set<UUID> = []
    private var forgottenDeletions: Set<String> = []
    private var keptDeletions: [String: Date] = [:]

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if let saved = defaults?.string(forKey: Key.device) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults?.set(deviceID, forKey: Key.device)
        }
        deviceName = RegEnvironment.isSandboxed ? ConfigSyncDemo.deviceName : RegConfigController.deviceName
        deviceModel = RegEnvironment.isSandboxed ? ConfigSyncDemo.deviceModel : RegSyncDeviceInfo.model
        appVersion = UpdController.currentVersionText
        enabled = defaults?.bool(forKey: Key.enabled) ?? false
        excludedSites = Set((defaults?.stringArray(forKey: Key.excludedSites) ?? []).compactMap(UUID.init(uuidString:)))
        addedSites = Set((defaults?.stringArray(forKey: Key.addedSites) ?? []).compactMap(UUID.init(uuidString:)))
        disabledCategories = Set(defaults?.stringArray(forKey: Key.disabledCategories) ?? [])
        customFolder = defaults?.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        lastSync = defaults?.object(forKey: Key.last) as? Date
        if RegEnvironment.isSandboxed {
            loadDemo()
        } else {
            migrate()
            let state = ConfigSyncEngine.loadState(from: Self.stateURL)
            apply(state)
            pendingCount = Self.pendingOperationCount()
        }
    }

    /// 0.18 à 0.28 : seuls les sites cochés étaient synchronisés. Ils le restent ; les sites
    /// d'alors non cochés restent sur ce Mac seulement ; les sites créés ensuite le sont.
    private func migrate() {
        guard let defaults, !defaults.bool(forKey: Key.migrated) else { return }
        if let legacy = defaults.stringArray(forKey: Key.sites), defaults.bool(forKey: Key.enabled) {
            let chosen = Set(legacy.compactMap(UUID.init(uuidString:)))
            let local = Set(SiteModel.shared.sites.map(\.id))
            excludedSites = local.subtracting(chosen)
            addedSites = chosen.subtracting(local)
            defaults.set(excludedSites.map(\.uuidString).sorted(), forKey: Key.excludedSites)
            defaults.set(addedSites.map(\.uuidString).sorted(), forKey: Key.addedSites)
        }
        defaults.set(true, forKey: Key.migrated)
    }

    private func apply(_ state: ConfigSyncState) {
        conflicts = state.conflicts
        pendingDeletions = state.pendingDeletions
        recent = state.recent
        devices = state.devices
        olderDevices = state.devices.filter { engine(root: URL(fileURLWithPath: "/"), password: nil).isOlder($0) }
    }

    /// Dossier de synchronisation : l'autre dossier choisi, sinon iCloud Drive.
    var syncRoot: URL? { customFolder ?? Self.iCloudFolder }

    var isAvailable: Bool { RegEnvironment.isSandboxed || syncRoot != nil }

    var folderLabel: String {
        guard let customFolder else { return "iCloud Drive › NetScope › Sync" }
        return customFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var usesICloud: Bool { customFolder == nil }

    /// Conflits et suppressions à voir (pastille de la section).
    var attentionCount: Int { enabled ? conflicts.count + pendingDeletions.count : 0 }

    private func engine(root: URL, password: String?) -> ConfigSyncEngine {
        var engine = ConfigSyncEngine(root: root, deviceID: deviceID, deviceName: deviceName, password: password)
        engine.deviceModel = deviceModel
        engine.appVersion = appVersion
        engine.disabledCategories = disabledCategories
        // Dossier choisi (OneDrive, NAS, partage) : jamais recréé en local s'il manque, et sans
        // mot de passe de synchronisation, rien d'y venu n'est authentifié.
        engine.createsRoot = customFolder == nil
        engine.untrustedFolder = customFolder != nil
        return engine
    }

    // MARK: Lancement et déclencheurs

    /// Au lancement (après l'application des changements en attente) : synchro si activée.
    func startIfEnabled(state: AppState? = nil) {
        if let state { appState = state }
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
        watch()
        preferencesSignature = Self.preferencesSignature()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in RegSyncController.shared.preferencesChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in RegSyncController.shared.becameActive() }
        })
        Task { hasPassword = await Task.detached { Self.storedPassword() != nil }.value }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        debounceTask?.cancel()
        watchers.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    /// Surveille le dossier de données (changements locaux) et le dossier de synchronisation
    /// (fichiers d'un autre Mac). FSEvents fonctionne sur iCloud Drive et sur un dossier local ;
    /// sur un partage réseau il peut ne rien signaler : la minuterie de 15 minutes prend le relais.
    private func watch() {
        watchers.removeAll()
        let data = RegBackupController.dataDirectory.standardizedFileURL.path
        if let watcher = RegSyncWatcher(path: data, handler: { paths in
            Task { @MainActor in RegSyncController.shared.localFilesChanged(paths, base: data) }
        }) { watchers.append(watcher) }
        if let root = syncRoot?.standardizedFileURL {
            // Seul iCloud Drive › NetScope › Sync est créé : un partage non monté reste absent.
            if usesICloud { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            let mine = ConfigSyncEngine.safeFileName(deviceID) + ".json"
            if let watcher = RegSyncWatcher(path: root.path, handler: { paths in
                // Nos propres fichiers ne comptent pas ; ceux d'un autre Mac, oui.
                let others = paths.filter { !$0.hasSuffix("/" + mine) && $0.hasSuffix(".json") }
                guard !others.isEmpty else { return }
                Task { @MainActor in RegSyncController.shared.scheduleSync(reason: "autre Mac") }
            }) { watchers.append(watcher) }
        }
    }

    private func localFilesChanged(_ paths: [String], base: String) {
        guard Date() >= suppressUntil else { return }
        let relevant = paths.contains { path in
            guard path.hasPrefix(base + "/"), path.hasSuffix(".json") else { return false }
            let relative = String(path.dropFirst(base.count + 1))
            guard !relative.hasPrefix("."), !relative.contains("/.") else { return false }
            return ConfigSyncPolicy.localReason(forFile: relative) == nil
        }
        if relevant { scheduleSync(reason: "changement local") }
    }

    private func preferencesChanged() {
        guard Date() >= suppressUntil else { return }
        let signature = Self.preferencesSignature()
        guard signature != preferencesSignature else { return }
        preferencesSignature = signature
        scheduleSync(reason: "réglage changé")
    }

    private func becameActive() {
        guard enabled, (lastSync.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
        scheduleSync(reason: "activation")
    }

    /// Empreinte des réglages synchronisés de ce Mac.
    nonisolated static func preferencesSignature() -> String {
        let domain = UserDefaults.standard.persistentDomain(forName: RegBackupController.preferencesDomain) ?? [:]
        var parts: [String] = []
        for key in domain.keys.sorted() where ConfigSyncPolicy.isGlobalPreference(key) {
            if let data = domain[key].flatMap(ConfigPlist.encode) { parts.append(key + "=" + ConfigPlist.hash(data)) }
        }
        return ConfigHash.sha256(Data(parts.joined(separator: "\n").utf8))
    }

    /// Synchro quelques secondes après le dernier changement (anti-rebond).
    func scheduleSync(reason: String) {
        guard enabled, !RegEnvironment.isSandboxed else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AppLog.shared.info("Synchronisation", "Synchronisation déclenchée (\(reason))")
            RegSyncController.shared.syncNow(quiet: true)
        }
    }

    /// Rafraîchit « il y a… » tant que la section est affichée.
    func appear() {
        now = Date()
        if !RegEnvironment.isSandboxed {
            Task {
                hasPassword = await Task.detached { Self.storedPassword() != nil }.value
                refreshRemote()
                if counts.isEmpty { await refreshCounts() }
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

    // MARK: Dossier

    /// Autre dossier (OneDrive, NAS monté, dossier partagé), choisi dans le Finder.
    func chooseFolder() {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: le dossier n’est pas changé.", .neutral)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Synchroniser ici"
        panel.message = "Choisissez un dossier partagé par tous vos Mac (OneDrive, NAS monté, dossier partagé)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolder = url
        defaults?.set(url.path, forKey: Key.folder)
        message = ("Dossier de synchronisation\u{00A0}: \(folderLabel). Choisissez le même sur chacun de vos Mac.", .warning)
        if enabled { watch(); syncNow() }
    }

    func useICloudDrive() {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: le dossier n’est pas changé.", .neutral)
            return
        }
        customFolder = nil
        defaults?.removeObject(forKey: Key.folder)
        message = ("Synchronisation par iCloud Drive › NetScope › Sync.", .success)
        if enabled { watch(); syncNow() }
    }

    // MARK: Catégories et sites

    func isCategoryOn(_ id: String) -> Bool { !disabledCategories.contains(id) }

    func setCategory(_ id: String, _ on: Bool) {
        if on { disabledCategories.remove(id) } else { disabledCategories.insert(id) }
        guard !RegEnvironment.isSandboxed else { return }
        defaults?.set(disabledCategories.sorted(), forKey: Key.disabledCategories)
        if enabled { scheduleSync(reason: "catégorie") }
    }

    func isSynced(_ id: UUID) -> Bool { !excludedSites.contains(id) }

    func setSynced(_ id: UUID, _ on: Bool) {
        if on { excludedSites.remove(id) } else { excludedSites.insert(id) }
        guard !RegEnvironment.isSandboxed else { return }
        defaults?.set(excludedSites.map(\.uuidString).sorted(), forKey: Key.excludedSites)
        if on, enabled { scheduleSync(reason: "site coché") }
    }

    /// Site d'un autre Mac : synchronisé ici aussi (reçu tout de suite).
    func addRemoteSite(_ site: ConfigSyncRemoteSite) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: «\u{00A0}\(site.name)\u{00A0}» n’est pas ajouté.", .neutral)
            return
        }
        addedSites.insert(site.id)
        excludedSites.remove(site.id)
        defaults?.set(addedSites.map(\.uuidString).sorted(), forKey: Key.addedSites)
        defaults?.set(excludedSites.map(\.uuidString).sorted(), forKey: Key.excludedSites)
        syncNow()
    }

    /// Sites à synchroniser : ceux de ce Mac, ceux déjà synchronisés (une suppression faite ici
    /// est publiée) et ceux ajoutés d'un autre Mac, moins les sites décochés.
    private func siteIDs(state: ConfigSyncState) -> [UUID] {
        var ids = Set(SiteModel.shared.sites.map(\.id)).union(addedSites)
        ids.formUnion(state.sites.keys.compactMap(UUID.init(uuidString:)))
        return ids.subtracting(excludedSites).sorted { $0.uuidString < $1.uuidString }
    }

    private func refreshRemote() {
        guard let root = syncRoot else { remoteSites = []; return }
        let local = Set(SiteModel.shared.sites.map(\.id))
        let engine = engine(root: root, password: nil)
        Task {
            let found = await Task.detached { (engine.availableSites(excluding: local), engine.devices()) }.value
            remoteSites = found.0
            devices = found.1
            olderDevices = found.1.filter(engine.isOlder)
        }
    }

    private func refreshCounts() async {
        let ids = siteIDs(state: ConfigSyncState())
        counts = await Task.detached {
            let snapshot = ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory, preferences: RegConfigController.currentPreferences(),
                                               secretNames: RegConfigController.secretNames())
            return ConfigSyncGlobal.counts(snapshot: snapshot, sites: ids)
        }.value
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
        message = ("Mot de passe de synchronisation retiré\u{00A0}: les secrets ne sont plus synchronisés depuis ce Mac.", .success)
    }

    // MARK: Synchronisation

    func syncNow(quiet: Bool = false) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: le dossier de synchronisation n’est ni lu ni modifié.", .neutral)
            return
        }
        guard !isSyncing else { rerun = true; return }
        guard let root = syncRoot else {
            if !quiet { message = ("iCloud Drive n’est pas activé sur ce Mac (Réglages Système › Identifiant Apple › iCloud), ou choisissez un autre dossier.", .warning) }
            return
        }
        // Jamais pendant un scan : la synchronisation attend sa fin.
        if ScanController.shared.isRunning {
            if !quiet { message = ("Scan en cours\u{00A0}: la synchronisation se fera après le scan.", .neutral) }
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                RegSyncController.shared.syncNow(quiet: true)
            }
            return
        }
        isSyncing = true
        RegSyncReload.flushStores()
        var engine = engine(root: root, password: nil)
        engine.heldPaths = Self.pendingPaths()
        let idsSource = ConfigSyncEngine.loadState(from: Self.stateURL)
        let ids = siteIDs(state: idsSource)
        Task {
            defer {
                isSyncing = false
                replayDecisions()
                if rerun { rerun = false; scheduleSync(reason: "changement pendant la synchro") }
            }
            let outcome = await Task.detached(priority: .utility) { () -> Result<(ConfigSyncReport, ConfigSyncState, ConfigSyncState, [ConfigSyncGlobal.CategoryCount]), Error> in
                Result {
                    var engine = engine
                    let password = Self.storedPassword()
                    engine.password = password
                    // Secrets du Trousseau lus seulement avec le mot de passe (sinon jamais envoyés).
                    let secrets = password == nil ? [] : ((try? BackupKeychainSecrets().readSecrets()) ?? [])
                    // Sans mot de passe, les secrets sont comptés par leur nom (comme à l'ouverture).
                    let snapshot = ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory,
                                                       preferences: RegConfigController.currentPreferences(), secrets: secrets,
                                                       secretNames: password == nil ? RegConfigController.secretNames() : [])
                    var state = ConfigSyncEngine.loadState(from: Self.stateURL)
                    let before = state
                    let report = try engine.sync(sites: ids, global: true, snapshot: snapshot, state: &state)
                    if !report.plan.secrets.isEmpty {
                        _ = BackupEngine.restoreSecrets(report.plan.secrets, to: BackupKeychainSecrets())
                    }
                    try ConfigSyncEngine.saveState(state, to: Self.stateURL)
                    let counts = ConfigSyncGlobal.counts(snapshot: snapshot, sites: ids)
                    return (report, before, state, counts)
                }
            }.value
            switch outcome {
            case .success(let (report, before, state, counts)):
                lastSync = state.lastSync
                defaults?.set(state.lastSync, forKey: Key.last)
                apply(state)
                olderDevices = state.devices.filter(engine.isOlder)
                self.counts = counts
                let applied = applyReceived(report.plan)
                if applied.failed {
                    // Écriture d'un changement reçu impossible : l'état ne doit pas le croire
                    // appliqué, sinon l'ancienne version restée ici serait republiée par-dessus.
                    let restored = Self.revertingItems(state, to: before)
                    try? ConfigSyncEngine.saveState(restored, to: Self.stateURL)
                }
                lastSummary = Self.summary(report)
                if !report.errors.isEmpty {
                    message = (report.errors.joined(separator: " "), .warning)
                } else if !report.conflicts.isEmpty {
                    message = (MonText.plural(report.conflicts.count, "conflit", "conflits") + "\u{00A0}: la version la plus récente a été gardée, l’autre peut être rétablie ci-dessous.", .warning)
                } else if !report.pendingDeletions.isEmpty {
                    message = (MonText.plural(report.pendingDeletions.count, "suppression venue d’un autre Mac", "suppressions venues d’un autre Mac") + " à confirmer ci-dessous.", .warning)
                } else if applied.deferred > 0 {
                    message = (MonText.plural(applied.deferred, "changement reçu attend", "changements reçus attendent") + " le redémarrage de NetScope.", .accent)
                } else if applied.hot > 0 {
                    message = (MonText.plural(applied.hot, "changement reçu appliqué", "changements reçus appliqués") + " sans redémarrer.", .success)
                } else if report.secretsSkipped, !quiet {
                    message = ("Synchronisé, sans les secrets\u{00A0}: définissez le mot de passe de synchronisation.", .warning)
                } else if !quiet {
                    message = ("Synchronisé.", .success)
                }
                refreshRemote()
            case .failure(let error):
                message = ("Synchronisation impossible\u{00A0}: \(error.localizedDescription)", .critical)
            }
        }
    }

    /// Applique les changements reçus : à chaud quand le magasin sait relire, sinon au redémarrage.
    @discardableResult
    private func applyReceived(_ plan: ConfigApplyPlan) -> (hot: Int, deferred: Int, failed: Bool) {
        let received = plan.withoutSecrets
        guard !received.isEmpty else { return (0, 0, false) }
        let hot = received.filtered(files: { RegSyncReload.isHot(file: $0) }, preferences: { _ in true })
        let later = received.filtered(files: { !RegSyncReload.isHot(file: $0) }, preferences: { _ in false })
        var applied = 0
        var failed = false
        if !hot.isEmpty {
            RegSyncReload.flushStores()
            suppressUntil = Date().addingTimeInterval(6)
            let outcome = ConfigImporter.apply(hot, to: RegBackupController.dataDirectory, preferences: RegConfigController.currentPreferences())
            for (key, data) in outcome.preferences {
                if let value = ConfigPlist.decode(data) { UserDefaults.standard.set(value, forKey: key) }
            }
            preferencesSignature = Self.preferencesSignature()
            RegSyncReload.reload(files: hot.touchedFiles, preferences: hot.touchedPreferences, state: appState)
            applied = outcome.applied.count
            if !outcome.skipped.isEmpty {
                AppLog.shared.warning("Synchronisation", "Changé ici entre-temps, pas remplacé\u{00A0}: \(outcome.skipped.joined(separator: ", "))")
            }
            if !outcome.failed.isEmpty {
                failed = true
                AppLog.shared.error("Synchronisation", "Écriture impossible\u{00A0}: \(outcome.failed.joined(separator: ", "))")
            }
        }
        if !later.isEmpty {
            var merged = later
            var restored = 0
            if let data = try? Data(contentsOf: Self.pendingURL),
               let waiting = try? BackupEngine.decoder().decode(RegConfigController.Pending.self, from: data) {
                merged = waiting.plan.merging(later)
                restored = waiting.secretsRestored
            }
            try? RegConfigController.savePending(merged, secretsRestored: restored, to: Self.pendingURL)
            pendingCount = Self.pendingOperationCount()
        }
        return (applied, later.operationCount, failed)
    }

    /// Remet, pour chaque élément dont l'état a changé à ce passage, l'état d'avant la
    /// synchronisation. Un élément reçu mais pas écrit est ainsi reçu de nouveau au passage
    /// suivant (jamais republié comme changé ici) ; un élément déjà identique des deux côtés
    /// retrouve sa base sans rien envoyer ni signaler.
    nonisolated static func revertingItems(_ state: ConfigSyncState, to before: ConfigSyncState) -> ConfigSyncState {
        var result = state
        for (scope, site) in state.sites {
            let old = before.sites[scope]?.items ?? [:]
            for (key, item) in site.items where old[key] != item {
                result.sites[scope]?.items[key] = old[key]
            }
        }
        return result
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
        if !report.pendingDeletions.isEmpty {
            parts.append(MonText.plural(report.pendingDeletions.count, "suppression à confirmer", "suppressions à confirmer"))
        }
        return parts.isEmpty ? "Aucun changement" : parts.joined(separator: " · ")
    }

    nonisolated static func pendingOperationCount() -> Int {
        pendingPlan()?.operationCount ?? 0
    }

    nonisolated static func pendingPlan() -> ConfigApplyPlan? {
        guard let data = try? Data(contentsOf: pendingURL),
              let pending = try? BackupEngine.decoder().decode(RegConfigController.Pending.self, from: data) else { return nil }
        return pending.plan
    }

    /// Fichiers dont des changements reçus attendent le redémarrage (laissés de côté par la synchro).
    nonisolated static func pendingPaths() -> Set<String> {
        pendingPlan()?.touchedFiles ?? []
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
            guard UpdInstaller.runningBundle() != nil else {
                message = ("Quittez NetScope et rouvrez-le pour appliquer les changements reçus.", .warning)
                return
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

    /// Rétablit la version écartée, à chaud, puis l'envoie aux autres Mac.
    func restore(_ conflict: ConfigSyncConflict) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: rien n’est rétabli.", .neutral)
            return
        }
        RegSyncReload.flushStores()
        Task {
            let plan = await Task.detached {
                ConfigSyncEngine.restorePlan(conflict, snapshot: ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory,
                                                                                     preferences: RegConfigController.currentPreferences()))
            }.value
            guard let plan else {
                message = ("Cette version ne peut pas être rétablie (un secret n’est jamais gardé en clair).", .warning)
                return
            }
            let applied = applyReceived(plan)
            dismiss(conflict)
            message = applied.deferred > 0
                ? ("Version de «\u{00A0}\(conflict.otherDevice)\u{00A0}» prête\u{00A0}: redémarrez NetScope pour la rétablir.", .accent)
                : ("Version de «\u{00A0}\(conflict.otherDevice)\u{00A0}» rétablie\u{00A0}; elle part vers les autres Mac.", .success)
            scheduleSync(reason: "version rétablie")
        }
    }

    func dismiss(_ conflict: ConfigSyncConflict) {
        conflicts.removeAll { $0.id == conflict.id }
        guard !RegEnvironment.isSandboxed else { return }
        // Pendant une synchro, l'état sera réécrit à sa fin : la décision y est rejouée.
        if isSyncing { decidedConflicts.insert(conflict.id); return }
        var state = ConfigSyncEngine.loadState(from: Self.stateURL)
        state.conflicts.removeAll { $0.id == conflict.id }
        try? ConfigSyncEngine.saveState(state, to: Self.stateURL)
    }

    // MARK: Suppressions venues d'un autre Mac

    /// Supprime aussi ici ce que l'autre Mac a supprimé.
    func confirmDeletion(_ deletion: ConfigSyncDeletion) {
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: rien n’est supprimé.", .neutral)
            return
        }
        if deletion.isWholeSite, let id = deletion.siteID {
            guard let state = appState else { return }
            if let site = SiteModel.shared.site(id) {
                // Même avertissement que Réglages › Sites : le site part avec son inventaire.
                let count = SiteModel.shared.inventoryCount(site)
                let alert = NSAlert()
                alert.messageText = "Supprimer le site «\u{00A0}\(site.displayName)\u{00A0}» sur ce Mac aussi\u{00A0}?"
                alert.informativeText = "«\u{00A0}\(deletion.device)\u{00A0}» l’a supprimé. L’inventaire du site sera supprimé ici\u{00A0}: \(count) fiche\(count > 1 ? "s" : ""), leur historique, leurs événements, l’archive, les notes, ainsi que ses derniers résultats de scan. Une sauvegarde (Réglages › Export et sauvegarde) permet de le retrouver."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Supprimer le site et son inventaire")
                alert.addButton(withTitle: "Annuler")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                SiteModel.shared.remove(id, state: state)
                guard SiteModel.shared.site(id) == nil else {
                    message = ("Site actif occupé\u{00A0}: réessayez après le scan.", .warning)
                    return
                }
            }
            forgetDeletion(deletion, keep: false)
            message = ("Site «\u{00A0}\(deletion.scopeName)\u{00A0}» supprimé sur ce Mac aussi.", .success)
            return
        }
        RegSyncReload.flushStores()
        Task {
            let plan = await Task.detached {
                // Base commune de la dernière synchro : un élément changé depuis n'est pas retiré.
                let base = ConfigSyncEngine.loadState(from: Self.stateURL).sites[deletion.scope]?.items[deletion.key]?.synced
                return ConfigSyncEngine.deletionPlan(deletion, snapshot: ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory,
                                                                                             preferences: RegConfigController.currentPreferences()),
                                                     base: base)
            }.value
            guard let plan else {
                // Jamais une demande qui reste en attente pour toujours.
                forgetDeletion(deletion, keep: false)
                message = ("«\u{00A0}\(deletion.label)\u{00A0}» n’est pas retiré d’ici\u{00A0}: retirez-le à la main sur ce Mac au besoin.", .warning)
                return
            }
            applyReceived(plan)
            forgetDeletion(deletion, keep: false)
            message = ("«\u{00A0}\(deletion.label)\u{00A0}» supprimé sur ce Mac aussi.", .success)
        }
    }

    /// Garde l'élément sur ce Mac (la suppression n'est plus signalée).
    func keepDeletion(_ deletion: ConfigSyncDeletion) {
        forgetDeletion(deletion, keep: true)
        if !RegEnvironment.isSandboxed { message = ("«\u{00A0}\(deletion.label)\u{00A0}» gardé sur ce Mac.", .neutral) }
    }

    private func forgetDeletion(_ deletion: ConfigSyncDeletion, keep: Bool) {
        pendingDeletions.removeAll { $0.id == deletion.id }
        guard !RegEnvironment.isSandboxed else { return }
        // Pendant une synchro, l'état sera réécrit à sa fin : la décision y est rejouée.
        if isSyncing {
            forgottenDeletions.insert(deletion.id)
            if keep { keptDeletions[deletion.id] = deletion.date }
            return
        }
        var state = ConfigSyncEngine.loadState(from: Self.stateURL)
        state.pendingDeletions.removeAll { $0.id == deletion.id }
        if keep { state.dismissed[deletion.id] = deletion.date }
        try? ConfigSyncEngine.saveState(state, to: Self.stateURL)
    }

    /// Rejoue sur l'état écrit par la synchro les décisions prises pendant qu'elle tournait.
    private func replayDecisions() {
        guard !decidedConflicts.isEmpty || !forgottenDeletions.isEmpty, !RegEnvironment.isSandboxed else { return }
        var state = ConfigSyncEngine.loadState(from: Self.stateURL)
        state.conflicts.removeAll { decidedConflicts.contains($0.id) }
        state.pendingDeletions.removeAll { forgottenDeletions.contains($0.id) }
        for (id, date) in keptDeletions { state.dismissed[id] = date }
        decidedConflicts = []
        forgottenDeletions = []
        keptDeletions = [:]
        try? ConfigSyncEngine.saveState(state, to: Self.stateURL)
        conflicts = state.conflicts
        pendingDeletions = state.pendingDeletions
    }

    // MARK: Démonstration

    private func loadDemo() {
        let demo = ConfigSyncDemo.state()
        enabled = demo.enabled
        excludedSites = demo.excludedSites
        disabledCategories = demo.disabledCategories
        lastSync = demo.lastSync
        hasPassword = true
        conflicts = demo.conflicts
        pendingDeletions = demo.deletions
        recent = demo.recent
        // Ce Mac de la démonstration porte l'identifiant de ce Mac (« Ce Mac » dans le tableau).
        devices = demo.devices.map { device in
            guard device.name == ConfigSyncDemo.deviceName else { return device }
            var copy = device
            copy.id = deviceID
            return copy
        }
        olderDevices = demo.devices.filter { $0.name == ConfigSyncDemo.officeDevice }
        counts = demo.counts
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
        if Calendar.current.isDateInYesterday(date) {
            let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
            return "hier à \(time)"
        }
        return "le " + RegFormat.moment(date)
    }
}
