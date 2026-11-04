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

    let isDemo: Bool
    private let store: DiskHistoryStore?
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
        pending = ephemeral ? nil : DiskPendingCleanup.standard
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
        let path = location.testFolder.appendingPathComponent("essai").path
        return "dd if=/dev/urandom of=\"\(path)\" bs=1m count=\(sizeBytes >> 20) && sync"
    }

    // MARK: Emplacements

    /// Relit les volumes montés et les dossiers nuage (lecture locale, aucun accès réseau).
    func refreshLocations() {
        guard !isDemo, !loadingLocations else { return }
        loadingLocations = true
        Task.detached(priority: .userInitiated) {
            let found = DiskLocationCatalog.discover()
            await MainActor.run {
                let model = DiskSpeedModel.shared
                model.locations = found
                model.loadingLocations = false
                if model.selected == nil {
                    model.selectedID = DiskLocationCatalog.preferred(in: found, lastUsed: model.lastLocation)?.id
                }
            }
        }
    }

    func loadDemoLocations(_ list: [DiskLocation], selected: String) {
        locations = list
        selectedID = selected
    }

    private func selectionChanged() {
        guard !isRunning else { return }
        notice = nil
        error = nil
    }

    // MARK: Vérifications avant le test

    /// Problème qui empêche de lancer le test sur l'emplacement choisi (nil : tout va bien).
    var blockingProblem: String? {
        guard let location = selected else { return "Choisissez un emplacement." }
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
        let config = self.config.effective(for: location.kind)
        task?.cancel()
        networkTask?.cancel()
        generation += 1
        let run = generation
        reset()
        lastRecordID = nil
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
                guard let self, self.generation == run else { return }
                self.handle(event, location: location, toolStore: toolStore)
            }
            guard let self, self.generation == run, self.isRunning else { return }
            // Flux terminé sans résultat (tâche annulée) : arrêt.
            self.isRunning = false
            self.phase = nil
        }
    }

    func stop() {
        guard isRunning else { return }
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
