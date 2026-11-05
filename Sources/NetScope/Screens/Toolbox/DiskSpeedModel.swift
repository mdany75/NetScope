import AppKit
import Foundation
import NetScopeCore
import SwiftUI

/// Point de la courbe en direct (secondes depuis le début du test, Mo/s).
struct DiskPoint: Identifiable, Hashable {
    let id: Int
    let time: Double
    let value: Double
    /// Écriture ou lecture séquentielle.
    let phase: DiskPhase
    /// Numéro du tronçon (une écriture ou une lecture d'une passe) : une série de la courbe chacun.
    let segment: Int
}

/// État de l'outil « Vitesse des disques » (note 22), conservé quand on change d'écran.
/// Historique et réglages : ~/Library/Application Support/NetScope/disques.json (rien n'est lu ni
/// écrit en démonstration et pendant les captures).
@MainActor
final class DiskSpeedModel: ObservableObject {
    static let shared = DiskSpeedModel()

    // MARK: Emplacements et réglages

    @Published private(set) var locations: [DiskLocation] = []
    @Published private(set) var loadingLocations = false
    @Published var selectedID: String? { didSet { if oldValue != selectedID { selectionChanged() } } }
    @Published var sizeBytes: Int64 = 1 << 30 { didSet { saveSettings() } }
    @Published var passes = 1 { didSet { saveSettings() } }
    @Published var random = true { didSet { saveSettings() } }
    @Published var cloudTimeout: Double = 600 { didSet { saveSettings() } }

    // MARK: Test en cours ou dernier test

    @Published private(set) var isRunning = false
    @Published private(set) var phase: DiskPhase?
    @Published private(set) var pass = 1
    @Published private(set) var fraction: Double = 0
    @Published private(set) var elapsed: Double = 0
    /// Débit instantané (Mo/s) pendant les phases séquentielles, IOPS pendant les accès aléatoires.
    @Published private(set) var instant: Double?
    @Published private(set) var points: [DiskPoint] = []
    @Published private(set) var writePasses: [Double] = []
    @Published private(set) var readPasses: [Double] = []
    @Published private(set) var randomRead: DiskRandomResult?
    @Published private(set) var randomWrite: DiskRandomResult?
    @Published private(set) var cloudStatus: DiskCloudStatus?
    @Published private(set) var cloudElapsed: Double = 0
    @Published private(set) var result: DiskBenchmarkResult?
    @Published private(set) var verdict: DiskVerdict?
    @Published private(set) var network: DiskNetworkContext?
    /// Emplacement du test affiché (en cours ou terminé).
    @Published private(set) var testedLocation: DiskLocation?
    @Published private(set) var testedConfig: DiskBenchmarkConfig?
    @Published private(set) var error: String?
    @Published private(set) var stopped = false
    @Published var notice: String?
    /// Fenêtre de confirmation avant d'écrire plus de 1 Gio dans un dossier nuage.
    @Published var confirmingCloud = false

    // MARK: Historique

    @Published private(set) var history: [DiskTestRecord] = []
    @Published var showAllHistory = false

    // MARK: Emplacements ajoutés (note 55)

    /// NAS, partages et dossiers ajoutés, tous sites confondus (la liste n'affiche que ceux du site actif).
    @Published private(set) var shares: [DiskShareLocation] = []
    /// Feuille « Ajouter un emplacement… » ou « Modifier… ».
    @Published var editing: DiskShareDraft?
    /// Suppression à confirmer.
    @Published var confirmingDelete: DiskShareLocation?
    /// Derniers « Tester le serveur », par emplacement.
    @Published private(set) var serverReports: [UUID: DiskServerReport] = [:]
    @Published private(set) var testingServers: Set<UUID> = []
    /// « Montage de smb://… » pendant la préparation d'un partage enregistré.
    @Published private(set) var mountStatus: String?
    /// Le dernier échec de montage concerne le compte ou le mot de passe (« Modifier… » mis en avant).
    @Published private(set) var credentialsProblem = false

    let isDemo: Bool
    private let store: DiskHistoryStore?
    private let shareStore: DiskShareStore?
    /// Volumes et dossiers nuage trouvés à la dernière lecture (avant fusion avec les emplacements ajoutés).
    private var discovered: [DiskLocation] = []
    /// Dossiers « Autre » trouvés à la dernière lecture (vérifiés hors du fil principal).
    private var existingFolders: Set<String> = []
    private let pending: DiskPendingCleanup?
    private var task: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    /// Enregistrement du dernier test, mis à jour si la latence du serveur arrive après la fin.
    private var lastRecordID: UUID?
    private var generation = 0
    private var loading = true
    private var lastLocation: String?
    private var pointID = 0
    private var segment = 0

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        let ephemeral = isDemo || arguments.contains("--snapshot")
        store = ephemeral ? nil : DiskHistoryStore.standard
        shareStore = ephemeral ? nil : DiskShareStore.standard
        pending = ephemeral ? nil : DiskPendingCleanup.standard
        if let shareStore { shares = shareStore.load() }
        if isDemo {
            DiskSpeedDemo.apply(to: self)
        } else if let store {
            let content = store.load()
            history = content.records
            lastLocation = content.lastLocation
            if let config = content.config {
                sizeBytes = DiskBenchmarkConfig.sizeChoices.contains(config.sizeBytes) ? config.sizeBytes : 1 << 30
                passes = DiskBenchmarkConfig.passChoices.contains(config.passes) ? config.passes : 1
                random = config.random
                cloudTimeout = DiskBenchmarkConfig.cloudTimeoutChoices.contains(config.cloudTimeout) ? config.cloudTimeout : 600
            }
        }
        loading = false
    }

    var selected: DiskLocation? { locations.first { $0.id == selectedID } }

    var config: DiskBenchmarkConfig {
        DiskBenchmarkConfig(sizeBytes: sizeBytes, passes: passes, random: random, cloudTimeout: cloudTimeout)
    }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        guard let location = selected else { return "dd if=/dev/urandom of=<emplacement>/NetScope-test/essai bs=1m" }
        if !location.isMounted, location.kind == .reseau {
            // Partage enregistré pas encore monté : NetFS le monte au lancement.
            return "dd if=/dev/urandom of=\"<\(location.path)>/NetScope-test/essai\" bs=1m count=\(sizeBytes >> 20) && sync"
        }
        let path = location.testFolder.appendingPathComponent("essai").path
        return "dd if=/dev/urandom of=\"\(path)\" bs=1m count=\(sizeBytes >> 20) && sync"
    }

    // MARK: Emplacements

    /// Relit les volumes montés et les dossiers nuage (lecture locale, aucun accès réseau).
    func refreshLocations() {
        guard !isDemo, !loadingLocations else { return }
        loadingLocations = true
        let folders = shares.filter { $0.kind == .dossier }.map { ($0.trimmedShare as NSString).standardizingPath }
        Task.detached(priority: .userInitiated) {
            let found = DiskLocationCatalog.discover()
            let existing = Set(folders.filter { FileManager.default.fileExists(atPath: $0) })
            await MainActor.run {
                let model = DiskSpeedModel.shared
                model.discovered = found
                model.existingFolders = existing
                model.loadingLocations = false
                model.rebuildLocations()
            }
        }
    }

    /// Liste affichée : volumes trouvés et emplacements ajoutés du site actif.
    func rebuildLocations() {
        let folders = existingFolders
        let demo = isDemo
        locations = DiskShareCatalog.merge(discovered: discovered, saved: shares, siteKey: SiteModel.shared.activeKey,
                                           folderExists: { demo || folders.contains($0) })
        if selected == nil {
            selectedID = DiskLocationCatalog.preferred(in: locations, lastUsed: lastLocation)?.id
        }
    }

    func loadDemoLocations(_ list: [DiskLocation], shares: [DiskShareLocation], selected: String) {
        discovered = list
        self.shares = shares
        rebuildLocations()
        selectedID = selected
    }

    func setDemoServerReport(_ report: DiskServerReport, for id: UUID) {
        serverReports[id] = report
    }

    // MARK: Emplacements ajoutés (note 55)

    /// Emplacement ajouté de la carte choisie, s'il y en a un.
    var selectedShare: DiskShareLocation? { selected.flatMap { DiskShareCatalog.saved(for: $0, in: shares) } }

    func share(for location: DiskLocation) -> DiskShareLocation? { DiskShareCatalog.saved(for: location, in: shares) }

    /// Emplacements du site actif.
    var siteShares: [DiskShareLocation] { DiskShareCatalog.forSite(shares, siteKey: SiteModel.shared.activeKey) }

    func beginAdd() {
        editing = DiskShareDraft(share: DiskShareLocation(siteKey: SiteModel.shared.activeKey, kind: .smb), isNew: true)
    }

    func beginEdit(_ share: DiskShareLocation) {
        editing = DiskShareDraft(share: share, isNew: false)
    }

    /// Enregistre l'emplacement ; le mot de passe va au Trousseau (jamais dans le fichier). Renvoie
    /// un message d'erreur, ou nil.
    func save(_ draft: DiskShareLocation, password: String, passwordChanged: Bool) -> String? {
        var share = draft
        if let twin = DiskShareStore.duplicate(of: share, in: shares) {
            return "Cet emplacement existe déjà dans ce site\u{00A0}: «\u{00A0}\(twin.displayName)\u{00A0}»."
        }
        let keychain = DiskShareMounter.keychain
        do {
            if !share.kind.usesCredentials || share.trimmedUser.isEmpty {
                // NFS, dossier ou invité : aucun mot de passe à garder.
                if share.hasPassword, !isDemo { try keychain.delete(share.keychainAccount) }
                share.hasPassword = false
            } else if passwordChanged {
                if !isDemo { try keychain.set(password.isEmpty ? nil : password, for: share.keychainAccount) }
                share.hasPassword = !password.isEmpty
            }
        } catch {
            return "Trousseau\u{00A0}: \(error.localizedDescription)"
        }
        if share.kind == .dossier {
            share.share = (share.trimmedShare as NSString).standardizingPath
            if isDemo || FileManager.default.fileExists(atPath: share.share) { existingFolders.insert(share.share) }
        }
        let isNew = !shares.contains { $0.id == share.id }
        shares = DiskShareStore.upsert(share, in: shares)
        persistShares()
        serverReports[share.id] = nil
        rebuildLocations()
        selectedID = share.locationID
        error = nil
        credentialsProblem = false
        notice = (isNew ? "Emplacement «\u{00A0}\(share.displayName)\u{00A0}» ajouté" : "Emplacement «\u{00A0}\(share.displayName)\u{00A0}» enregistré")
            + " pour le site «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}»."
        return nil
    }

    /// Retire l'emplacement (et son mot de passe du Trousseau) ; son historique reste.
    func delete(_ share: DiskShareLocation) {
        if share.hasPassword, !isDemo { try? DiskShareMounter.keychain.delete(share.keychainAccount) }
        let wasSelected = selectedID == share.locationID
        shares = DiskShareStore.remove(share.id, from: shares)
        serverReports[share.id] = nil
        persistShares()
        if wasSelected { selectedID = nil }
        rebuildLocations()
        notice = "Emplacement «\u{00A0}\(share.displayName)\u{00A0}» retiré (ses tests restent dans l’historique)."
    }

    /// « Tester le serveur » : nom, ping et ports des services de partage.
    func testServer(_ share: DiskShareLocation) {
        guard !testingServers.contains(share.id), share.kind != .dossier else { return }
        testingServers.insert(share.id)
        Task { [weak self] in
            guard let self else { return }
            let report = await self.checkServer(host: share.trimmedServer, kind: share.kind, customPort: share.port)
            self.serverReports[share.id] = report
            self.testingServers.remove(share.id)
        }
    }

    /// Vérification du serveur (aussi utilisée par la feuille avant d'enregistrer) ; en
    /// démonstration, un relevé fictif.
    func checkServer(host: String, kind: DiskShareKind, customPort: Int?) async -> DiskServerReport {
        if isDemo {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return DiskSpeedDemo.serverReport(host: host)
        }
        return await DiskServerProbe.run(host: host, kind: kind, customPort: customPort)
    }

    private func persistShares() {
        guard let shareStore else { return }
        do {
            try shareStore.save(shares)
        } catch {
            NSLog("NetScope\u{00A0}: enregistrement des emplacements des disques impossible\u{00A0}: %@", error.localizedDescription)
        }
    }

    private func selectionChanged() {
        guard !isRunning else { return }
        notice = nil
        error = nil
        credentialsProblem = false
    }

    // MARK: Vérifications avant le test

    /// Problème qui empêche de lancer le test sur l'emplacement choisi (nil : tout va bien).
    var blockingProblem: String? {
        guard let location = selected else { return "Choisissez un emplacement." }
        if let share = share(for: location) {
            if !share.kind.isAvailable { return DiskShareKind.ftpPending }
            if share.kind == .dossier, !location.isMounted {
                return "Dossier introuvable\u{00A0}: «\u{00A0}\(location.path)\u{00A0}» (disque éjecté, dossier déplacé ou renommé). Branchez le disque, puis Actualiser, ou choisissez un autre dossier dans «\u{00A0}Modifier…\u{00A0}»."
            }
        }
        if location.isReadOnly { return DiskBenchmarkError.readOnly.errorDescription }
        if !DiskMath.hasRoom(freeBytes: location.freeBytes, testSize: sizeBytes), let free = location.freeBytes {
            return DiskBenchmarkError.insufficientSpace(needed: DiskMath.requiredFreeSpace(forTestSize: sizeBytes), free: free).errorDescription
        }
        return nil
    }

    var needsCloudConfirmation: Bool {
        guard let location = selected else { return false }
        return DiskMath.needsCloudConfirmation(kind: location.kind, testSize: sizeBytes)
    }

    // MARK: Test

    /// Bouton « Lancer » : demande d'abord une confirmation pour un gros envoi vers le nuage.
    func requestStart(state: AppState, store: ToolStore) {
        guard !isRunning, blockingProblem == nil else { return }
        if needsCloudConfirmation {
            confirmingCloud = true
            return
        }
        start(state: state, store: store)
    }

    func start(state: AppState, store toolStore: ToolStore) {
        guard !isRunning, let location = selected, blockingProblem == nil else { return }
        task?.cancel()
        networkTask?.cancel()
        generation += 1
        let run = generation
        reset()
        lastRecordID = nil
        guard let share = share(for: location), share.kind.isMountable else {
            runBenchmark(location: location, state: state, toolStore: toolStore, run: run, unmountAfter: nil)
            return
        }
        // Partage enregistré (note 55) : monté par NetFS s'il ne l'est pas déjà, droit d'écriture
        // vérifié, puis le test habituel ; démonté à la fin seulement si NetScope l'a monté.
        isRunning = true
        testedLocation = location
        testedConfig = config.effective(for: location.kind)
        phase = .preparation
        credentialsProblem = false
        mountStatus = location.isMounted ? "Vérification de l’écriture dans \(share.displayName)" : "Montage de \(share.address)"
        if isDemo {
            // Démonstration : montage simulé, rien n'est monté.
            var mounted = location
            if !mounted.isMounted {
                mounted.path = "/Volumes/" + (share.trimmedShare.split(separator: "/").last.map(String.init) ?? share.displayName)
                mounted.testParent = mounted.path
                mounted.isMounted = true
                mounted.freeBytes = 5_210_000_000_000
                mounted.totalBytes = 11_980_000_000_000
            }
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, self.generation == run, self.isRunning else { return }
                self.mountStatus = nil
                self.runBenchmark(location: mounted, state: state, toolStore: toolStore, run: run, unmountAfter: nil)
            }
            return
        }
        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { DiskShareMounter.mount(share) }.value
            guard let self, self.generation == run, self.isRunning else {
                // Arrêté pendant le montage : on ne laisse pas monté ce que NetScope vient de monter.
                if case .mounted(let mounted) = outcome, mounted.mountedByNetScope {
                    _ = await Task.detached { await DiskShareMounter.unmount(path: mounted.path) }.value
                }
                return
            }
            switch outcome {
            case .failed(let problem):
                self.failPreparation(problem, share: share, location: location, toolStore: toolStore)
            case .mounted(let mounted):
                let path = mounted.path
                let writeProblem = await Task.detached(priority: .userInitiated) { DiskShareMounter.writeProblem(at: path) }.value
                guard self.generation == run, self.isRunning else {
                    if mounted.mountedByNetScope { _ = await Task.detached { await DiskShareMounter.unmount(path: path) }.value }
                    return
                }
                if let writeProblem {
                    self.failPreparation(writeProblem, share: share, location: location, toolStore: toolStore)
                    if mounted.mountedByNetScope { _ = await Task.detached { await DiskShareMounter.unmount(path: path) }.value }
                    return
                }
                var ready = location
                ready.path = path
                ready.testParent = path
                ready.isMounted = true
                ready.freeBytes = DiskSpace.freeBytes(at: path) ?? location.freeBytes
                self.mountStatus = nil
                if let free = ready.freeBytes, !DiskMath.hasRoom(freeBytes: free, testSize: self.sizeBytes) {
                    self.failPreparation(.diskFull, share: share, location: location, toolStore: toolStore)
                    if mounted.mountedByNetScope { _ = await Task.detached { await DiskShareMounter.unmount(path: path) }.value }
                    return
                }
                self.runBenchmark(location: ready, state: state, toolStore: toolStore, run: run,
                                  unmountAfter: mounted.mountedByNetScope ? path : nil)
            }
        }
    }

    /// Montage ou vérification d'écriture en échec : message expliqué, rien n'est mesuré.
    private func failPreparation(_ problem: DiskShareProblem, share: DiskShareLocation, location: DiskLocation, toolStore: ToolStore) {
        isRunning = false
        phase = nil
        mountStatus = nil
        credentialsProblem = problem.concernsCredentials
        error = problem.message(kind: share.kind, server: share.trimmedServer, share: share.trimmedShare)
        toolStore.record(ToolRecent(tool: .disques, target: location.name, summary: problem.title, status: .failure))
    }

    /// Le test lui-même, sur un emplacement prêt (monté). `unmountAfter` : point de montage à
    /// démonter à la fin (partage monté par NetScope pour ce test).
    private func runBenchmark(location: DiskLocation, state: AppState, toolStore: ToolStore, run: Int, unmountAfter: String?) {
        let config = self.config.effective(for: location.kind)
        isRunning = true
        testedLocation = location
        testedConfig = config
        phase = .preparation
        lastLocation = location.id
        saveSettings()
        toolStore.record(command: command)

        network = baseNetworkContext(for: location, state: state)
        if location.kind == .reseau, let server = location.server, !isDemo {
            // Latence vers le serveur, mesurée à côté (quelques pings).
            networkTask = Task { [weak self] in
                let latency = await DiskNetworkProbe.serverLatency(server)
                guard let self, self.generation == run else { return }
                self.network?.serverLatencyMs = latency
                if let result = self.result, let tested = self.testedLocation {
                    let verdict = DiskAdvisor.verdict(kind: tested.kind, result: result, context: self.network ?? DiskNetworkContext())
                    self.verdict = verdict
                    // Test déjà fini : l'historique (et donc le CSV et le rapport) suit le nouveau bilan.
                    if let id = self.lastRecordID, let index = self.history.firstIndex(where: { $0.id == id }) {
                        self.history[index].network = self.network
                        self.history[index].limit = verdict.limit
                        self.history[index].verdict = verdict.title
                        self.persist()
                    }
                }
            }
        }
        let engine: DiskBenchmarkEngine = isDemo ? DiskSpeedDemo.Engine(location: location, config: config)
                                                 : DiskBenchmark(location: location, config: config, pending: pending)
        task = Task { [weak self] in
            for await event in engine.run() {
                guard let self, self.generation == run else { break }
                self.handle(event, location: location, toolStore: toolStore)
            }
            if let unmountAfter {
                // Tâche détachée : le démontage se fait même si le test a été arrêté (tâche annulée).
                let done = await Task.detached { await DiskShareMounter.unmount(path: unmountAfter) }.value
                self?.noteUnmount(done, run: run)
            }
            guard let self, self.generation == run, self.isRunning else { return }
            // Flux terminé sans résultat (tâche annulée) : arrêt.
            self.isRunning = false
            self.phase = nil
        }
    }

    /// Message après le démontage d'un partage monté pour le test.
    private func noteUnmount(_ done: Bool, run: Int) {
        guard generation == run else { return }
        let text = done ? "Partage démonté (NetScope l’avait monté pour ce test)."
                        : "Le partage monté pour ce test n’a pas pu être démonté (fichier ouvert\u{00A0}?)\u{00A0}: éjectez-le dans le Finder."
        notice = [notice, text].compactMap { $0 }.joined(separator: " ")
        refreshLocations()
    }

    func stop() {
        guard isRunning else { return }
        mountStatus = nil
        task?.cancel()
        task = nil
        networkTask?.cancel()
        isRunning = false
        stopped = true
        phase = nil
        instant = nil
        if cloudStatus != nil, cloudStatus?.isFinal == false { cloudStatus = .arrete }
        notice = "Test arrêté\u{00A0}: le fichier d’essai et le dossier «\u{00A0}NetScope-test\u{00A0}» sont supprimés."
    }

    private func reset() {
        fraction = 0
        elapsed = 0
        instant = nil
        points = []
        pointID = 0
        segment = 0
        writePasses = []
        readPasses = []
        randomRead = nil
        randomWrite = nil
        cloudStatus = nil
        cloudElapsed = 0
        result = nil
        verdict = nil
        error = nil
        stopped = false
        notice = nil
        pass = 1
        mountStatus = nil
        credentialsProblem = false
    }

    /// Débit du lien actif et débit montant Internet connu (Speedtest), sans mesure réseau.
    private func baseNetworkContext(for location: DiskLocation, state: AppState) -> DiskNetworkContext? {
        switch location.kind {
        case .reseau:
            let interface = state.activeInterface
            var link: Double?
            // Un débit invalide (0, presque 0, infini : interface qui ne le connaît pas) est ignoré :
            // c'est lui qui faisait planter le bilan de la 0.8.0.
            func plausible(_ value: Double?) -> Double? {
                guard let value, value.isFinite, DiskNetworkContext.plausibleLinkMbps.contains(value) else { return nil }
                return value
            }
            if interface?.kind == .wifi {
                link = plausible(WifiStore.shared.connection?.transmitRate)
            }
            if link == nil, let name = interface?.name, !isDemo {
                link = plausible(LocalResources.interfaces().first { $0.name == name }?.counters.speedMbps.map(Double.init))
            }
            var context = DiskNetworkContext(linkMbps: link, linkKind: interface?.kind.label, interfaceName: interface?.name)
            if isDemo { context.serverLatencyMs = DiskSpeedDemo.serverLatency }
            return context
        case .nuage:
            let up = SpeedtestModel.shared.history.first { $0.kind == .internet && $0.upMbps != nil }?.upMbps
            return DiskNetworkContext(internetUpMbps: up)
        case .interne, .externe:
            return nil
        }
    }

    private func handle(_ event: DiskEvent, location: DiskLocation, toolStore: ToolStore) {
        switch event {
        case .phase(let phase, let pass):
            if phase == .ecriture || phase == .lecture { segment += 1 }
            self.phase = phase
            self.pass = pass
            instant = nil
        case .progress(let progress):
            fraction = progress.fraction
            elapsed = progress.elapsed
            instant = progress.instant
            if progress.phase == .ecriture || progress.phase == .lecture, let value = progress.instant {
                pointID += 1
                points.append(DiskPoint(id: pointID, time: progress.elapsed, value: value, phase: progress.phase, segment: segment))
            }
        case .passMeasured(let phase, _, let mbps):
            if phase == .ecriture { writePasses.append(mbps) } else { readPasses.append(mbps) }
        case .random(let phase, let value):
            if phase == .aleatoireLecture { randomRead = value } else { randomWrite = value }
        case .cloud(let status, let seconds):
            cloudStatus = status
            cloudElapsed = seconds
        case .finished(let value):
            finish(value, location: location, toolStore: toolStore)
        case .failed(let message):
            isRunning = false
            phase = nil
            instant = nil
            error = message
            toolStore.record(ToolRecent(tool: .disques, target: location.name, summary: message, status: .failure))
        case .stopped:
            isRunning = false
            stopped = true
            phase = nil
        }
    }

    private func finish(_ value: DiskBenchmarkResult, location: DiskLocation, toolStore: ToolStore) {
        isRunning = false
        phase = nil
        instant = nil
        fraction = 1
        result = value
        let verdict = DiskAdvisor.verdict(kind: location.kind, result: value, context: network ?? DiskNetworkContext())
        self.verdict = verdict
        let record = DiskTestRecord(location: location, result: value, network: network, verdict: verdict)
        lastRecordID = record.id
        addToHistory(record)
        let summary = Self.summary(record)
        let status: ToolRecent.Status = verdict.tone == .critical ? .failure : (verdict.tone == .warning ? .warning : .ok)
        toolStore.record(ToolRecent(tool: .disques, target: location.name, summary: summary, status: status))
        notice = "Test terminé et ajouté à l’historique."
    }

    /// « Écriture 2 850 Mo/s · lecture 3 120 Mo/s ».
    static func summary(_ record: DiskTestRecord) -> String {
        var parts: [String] = []
        if let write = record.writeMBps { parts.append("Écriture \(DiskFormat.rateWithUnit(write))") }
        if record.kind == .nuage {
            parts.append(record.uploadSeconds.map { "envoyé en \(DiskFormat.duration($0))" } ?? (record.cloudStatus?.label.lowercased() ?? ""))
        } else if let read = record.readMBps {
            parts.append("lecture \(DiskFormat.rateWithUnit(read))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Affichage

    /// Débit d'écriture à afficher : instantané pendant l'écriture, sinon la moyenne des passes.
    var displayedWrite: Double? {
        if isRunning, phase == .ecriture, let instant { return instant }
        return DiskMath.mean(writePasses)
    }

    var displayedRead: Double? {
        if isRunning, phase == .lecture, let instant { return instant }
        return DiskMath.mean(readPasses)
    }

    /// Échelle commune des deux jauges.
    var gaugeScale: Double {
        DiskMath.gaugeScale(for: max(points.map(\.value).max() ?? 0, displayedWrite ?? 0, displayedRead ?? 0, 1))
    }

    /// Historique affiché : l'emplacement choisi, ou tous.
    var visibleHistory: [DiskTestRecord] {
        guard !showAllHistory, let id = selectedID else { return history }
        if let location = selected { return DiskHistoryStore.records(history, for: location) }
        return DiskHistoryStore.records(history, for: id)
    }

    // MARK: Historique, export, rapport

    private func addToHistory(_ record: DiskTestRecord) {
        history = DiskHistoryStore.pruned([record] + history)
        persist()
    }

    func setDemo(history: [DiskTestRecord]) {
        self.history = history
    }

    /// Démonstration : un test terminé affiché tel quel.
    func loadDemoResult(location: DiskLocation, config: DiskBenchmarkConfig, result: DiskBenchmarkResult, points: [DiskPoint],
                        network: DiskNetworkContext?, verdict: DiskVerdict) {
        testedLocation = location
        testedConfig = config
        sizeBytes = config.sizeBytes
        passes = config.passes
        random = config.random
        self.result = result
        writePasses = result.writePasses
        readPasses = result.readPasses
        randomRead = result.randomRead
        randomWrite = result.randomWrite
        cloudStatus = result.cloudStatus
        cloudElapsed = result.uploadSeconds ?? 0
        self.points = points
        pointID = points.count
        segment = points.last?.segment ?? 0
        self.network = network
        self.verdict = verdict
        fraction = 1
        elapsed = points.last?.time ?? 0
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Exporter l’historique des disques"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "vitesse-disques-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // BOM UTF-8 : Excel reconnaît les accents.
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(DiskHistoryStore.csv(visibleHistory).utf8)
            try data.write(to: url, options: .atomic)
            notice = "Historique exporté\u{00A0}: \(url.lastPathComponent)"
        } catch {
            self.error = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }

    /// Derniers tests de chaque emplacement, pour la section « Vitesse des disques » des Rapports.
    var reportRecords: [DiskTestRecord] { DiskHistoryStore.latestPerLocation(history) }

    func addToReport() {
        RapportModel.shared.config.sections.insert(.disques)
        notice = "Section «\u{00A0}Vitesse des disques\u{00A0}» cochée dans les Rapports (dernier test de chaque emplacement)."
    }

    var isInReport: Bool { RapportModel.shared.config.sections.contains(.disques) }

    // MARK: Enregistrement

    private func saveSettings() {
        guard !loading else { return }
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(DiskHistoryStore.Content(records: history, lastLocation: lastLocation, config: config))
        } catch {
            NSLog("NetScope\u{00A0}: enregistrement de l’historique des disques impossible\u{00A0}: %@", error.localizedDescription)
        }
    }
}
