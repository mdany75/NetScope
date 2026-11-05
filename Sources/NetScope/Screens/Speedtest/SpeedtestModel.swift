import AppKit
import Foundation
import NetScopeCore
import SwiftUI

/// Onglets de l'écran Speedtest.
enum SpeedTab: String, CaseIterable, Identifiable {
    case internet, serveurs, lan, historique

    var id: String { rawValue }

    var label: String {
        switch self {
        case .internet: return "Internet"
        case .serveurs: return "Serveurs"
        case .lan: return "Réseau local (iperf3)"
        case .historique: return "Historique"
        }
    }

    var hint: String {
        switch self {
        case .internet: return "Débit du lien Internet : Cloudflare, M-Lab ou LibreSpeed (Ookla en option)"
        case .serveurs: return "Serveurs de test : latence mesurée, favoris et serveurs personnalisés"
        case .lan: return "Débit entre ce Mac et un serveur iperf3 du réseau"
        case .historique: return "Résultats conservés 90 jours sur ce Mac"
        }
    }
}

/// État d'un test Internet.
enum SpeedRunState: Equatable {
    case idle
    case running(SpeedPhase)
    case done
    case stopped
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Point d'une courbe temps réel (secondes, Mb/s).
struct SpeedPoint: Identifiable, Hashable {
    var id: Double { time }
    let time: Double
    let mbps: Double
}

/// État de l'écran Speedtest, conservé quand on change d'écran (instance unique).
@MainActor
final class SpeedtestModel: ObservableObject {
    static let shared = SpeedtestModel()

    // MARK: Internet

    @Published var tab: SpeedTab = .internet
    @Published var streams = 4
    @Published private(set) var runState: SpeedRunState = .idle
    /// Valeur affichée par la jauge (Mb/s, ou ms pendant la latence).
    @Published private(set) var gaugeValue: Double = 0
    @Published private(set) var fraction: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var downSeries: [SpeedPoint] = []
    @Published private(set) var upSeries: [SpeedPoint] = []
    @Published private(set) var idleLatency: Double?
    @Published private(set) var jitter: Double?
    @Published private(set) var downMbps: Double?
    @Published private(set) var upMbps: Double?
    @Published private(set) var summary: SpeedTestSummary?
    @Published private(set) var server: SpeedServerInfo?
    @Published var planDownText = "" { didSet { savePlan() } }
    @Published var planUpText = "" { didSet { savePlan() } }

    // MARK: Historique

    @Published private(set) var history: [SpeedTestRecord] = []
    @Published var historyFilter: SpeedTestKind?
    @Published private(set) var freshRecordID: UUID?
    @Published var toast: String?

    // MARK: Réseau local (iperf3)

    @Published var lanHost = ""
    @Published var lanPort = "5201"
    @Published var lanDuration = 10
    @Published var lanStreams = 4
    @Published var lanTransport: IperfOptions.Transport = .tcp
    @Published var lanDirection: IperfOptions.Direction = .normal
    @Published private(set) var lanRunning = false
    @Published private(set) var lanStartedAt: Date?
    @Published private(set) var lanResult: IperfResult?
    @Published private(set) var lanError: String?

    /// Chemin d'iperf3, nil s'il n'est pas installé (détection partagée avec le bouton « Installer »).
    var iperfPath: URL? { ToolInstallMonitor.shared(.iperf3).path.map { URL(fileURLWithPath: $0) } }

    // MARK: Serveurs de test

    /// Choix (« auto » ou un serveur), favoris et serveurs personnalisés, enregistrés.
    @Published private(set) var serverPrefs = SpeedServerPrefs()
    /// Liste chargée (Cloudflare, M-Lab, LibreSpeed, Ookla) avec la latence mesurée.
    @Published private(set) var catalog: [SpeedServer] = []
    @Published private(set) var catalogDate: Date?
    @Published private(set) var catalogLoading = false
    @Published private(set) var catalogStatus: String?
    @Published private(set) var catalogFailures: [String] = []
    @Published var serverQuery = ""
    @Published var serverSourceFilter: SpeedServerSource?
    @Published var customAddress = ""
    @Published var customLabel = ""
    @Published private(set) var customError: String?
    /// Serveur du test en cours ou du dernier test.
    @Published private(set) var testedServer: SpeedServer?
    /// Vrai pendant le choix automatique du serveur, avant la mesure.
    @Published private(set) var preparingServer = false
    /// CLI d'Ookla vérifié (« Speedtest by Ookla »), nil s'il est absent.
    @Published private(set) var ooklaPath: String?

    private var internetTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private let serverStore: SpeedServerPrefsStore?
    private var lanTask: Task<Void, Never>?
    /// Numéro du test iperf3 en cours : une tâche arrêtée ne modifie plus l'état.
    private var lanGeneration = 0
    private let store: SpeedHistoryStore?
    private var loading = true

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("--demo")
        // Captures et démonstration : rien n'est lu ni écrit sur le disque.
        store = (demo || arguments.contains("--snapshot")) ? nil : SpeedHistoryStore.standard
        serverStore = (demo || arguments.contains("--snapshot")) ? nil : SpeedServerPrefsStore.standard
        if let serverStore { serverPrefs = serverStore.load() }
        if demo {
            SpeedtestDemo.apply(to: self)
        } else if let store {
            let content = store.load()
            history = content.records
            planDownText = content.planDownMbps.map { SpeedFormat.integer($0) } ?? ""
            planUpText = content.planUpMbps.map { SpeedFormat.integer($0) } ?? ""
        }
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_SPEED_TAB"], let tab = SpeedTab(rawValue: raw) {
            self.tab = tab
        }
        loading = false
        // Ookla masqué (note 79, par défaut) : son CLI n'est même pas cherché.
        if serverPrefs.ooklaEnabled || demo { refreshOokla() }
    }

    var planDown: Double? { SpeedFormat.parse(planDownText) }
    var planUp: Double? { SpeedFormat.parse(planUpText) }

    /// Graduation de la jauge, selon le forfait et le plus haut débit vu.
    var gaugeScale: Double {
        let peak = max(downSeries.map(\.mbps).max() ?? 0, upSeries.map(\.mbps).max() ?? 0, downMbps ?? 0, planDown ?? 0)
        return SpeedMath.gaugeScale(for: peak)
    }

    var currentPhase: SpeedPhase? {
        if case .running(let phase) = runState { return phase }
        return nil
    }

    // MARK: Test Internet

    func startInternet(interface: LocalInterface?) {
        internetTask?.cancel()
        resetResults()
        runState = .running(.latency)
        toast = nil
        let streams = self.streams
        internetTask = Task { [weak self] in
            guard let self else { return }
            // Automatique : liste des serveurs (si elle date de plus de 30 min), puis le plus proche.
            var server = self.selectedServer
            if server == nil {
                if self.catalogIsStale {
                    self.preparingServer = true
                    await self.loadCatalog(includeOokla: false, quick: true)
                    self.preparingServer = false
                    if Task.isCancelled { return }
                }
                server = SpeedServerPicker.automatic(self.catalog)
            }
            guard let server else { return }
            self.testedServer = server
            guard let engine = self.engine(for: server, streams: streams) else {
                self.runState = .failed("Le CLI d’Ookla n’est pas installé : installez-le ou choisissez un autre serveur.")
                return
            }
            for await event in engine.run() {
                guard !Task.isCancelled else { return }
                self.handle(event, interface: interface)
            }
            // Flux terminé sans résultat ni erreur (moteur arrêté net) : ne pas rester « en cours ».
            if !Task.isCancelled, self.runState.isRunning {
                self.runState = .failed("Test interrompu sans résultat.")
                self.gaugeValue = 0
            }
        }
    }

    /// Moteur de mesure du serveur choisi.
    private func engine(for server: SpeedServer, streams: Int) -> SpeedTestEngine? {
        // Démonstration : progression et résultat rejoués, aucun moteur réseau construit.
        if Launcher.isDemo { return SpeedtestDemoEngine(server: server, streams: streams) }
        switch server.source {
        case .cloudflare:
            return SpeedTester(config: SpeedTestConfig(streams: streams))
        case .librespeed, .custom:
            guard let endpoints = LibreSpeedEndpoints(server: server) else { return nil }
            let label = server.historyLabel.replacingOccurrences(of: server.source.label + " · ", with: "")
            let info = SpeedServerInfo(city: server.city, country: server.country, source: server.source.label,
                                       serverName: label, serverID: server.id)
            // Blocs de téléversement plus petits : les serveurs PHP limitent souvent la taille des envois.
            return SpeedTester(config: SpeedTestConfig(streams: streams, uploadChunkBytes: 4_000_000,
                                                       libreSpeed: endpoints, serverInfo: info))
        case .mlab:
            return NDT7Tester(site: server.site)
        case .ookla:
            guard let ooklaPath else { return nil }
            return OoklaTester(executable: ooklaPath, serverID: server.ooklaID)
        }
    }

    func stopInternet() {
        guard runState.isRunning else { return }
        internetTask?.cancel()
        internetTask = nil
        runState = .stopped
        gaugeValue = 0
        preparingServer = false
    }

    // MARK: Serveurs de test

    /// Serveur choisi ; nil : automatique (le plus proche).
    var selectedServer: SpeedServer? {
        guard serverPrefs.selectedID != SpeedServerPrefs.automaticID else { return nil }
        let server = allServers.first { $0.id == serverPrefs.selectedID } ?? serverPrefs.selected
        // Ookla masqué (note 79) : un ancien choix Ookla repasse en automatique.
        return server.flatMap { serverPrefs.allows($0) ? $0 : nil }
    }

    /// Note 79 : moteur Ookla proposé (masqué par défaut, réactivable dans Serveurs › Sources).
    var ooklaEnabled: Bool { serverPrefs.ooklaEnabled }

    func setOoklaEnabled(_ enabled: Bool) {
        guard !runState.isRunning, enabled != serverPrefs.ooklaEnabled else { return }
        serverPrefs.setOoklaEnabled(enabled)
        if !enabled, serverSourceFilter == .ookla { serverSourceFilter = nil }
        saveServers()
        if enabled { refreshOokla() }
    }

    var isAutomatic: Bool { serverPrefs.selectedID == SpeedServerPrefs.automaticID }

    /// Serveur que choisirait le mode automatique avec la liste actuelle.
    var automaticChoice: SpeedServer { SpeedServerPicker.automatic(catalog) }

    /// Serveur qui sera utilisé au prochain test (pour les libellés).
    var plannedServer: SpeedServer { selectedServer ?? automaticChoice }

    /// Tous les serveurs : liste chargée, personnalisés, favoris absents de la liste, Ookla automatique.
    var allServers: [SpeedServer] {
        var list = catalog.isEmpty ? [SpeedServer.cloudflare] : catalog
        if ooklaPath != nil, !list.contains(where: { $0.id == SpeedServer.ooklaAuto.id }) { list.append(.ooklaAuto) }
        for server in serverPrefs.custom + serverPrefs.favorites where !list.contains(where: { $0.id == server.id }) {
            list.append(server)
        }
        return serverPrefs.allowed(list)
    }

    /// Liste filtrée (source, recherche) et triée : favoris, puis latence.
    var visibleServers: [SpeedServer] {
        let filtered = allServers.filter { server in
            (serverSourceFilter == nil || server.source == serverSourceFilter) && SpeedServerPicker.matches(server, query: serverQuery)
        }
        return SpeedServerPicker.sorted(filtered, favorites: serverPrefs.favoriteIDs)
    }

    /// Favoris, avec la latence de la dernière mesure.
    var favoriteServers: [SpeedServer] {
        serverPrefs.allowed(serverPrefs.favorites).map { favorite in allServers.first { $0.id == favorite.id } ?? favorite }
    }

    func isFavorite(_ server: SpeedServer) -> Bool { serverPrefs.favoriteIDs.contains(server.id) }

    var catalogIsStale: Bool {
        guard let catalogDate, !catalog.isEmpty else { return true }
        return Date().timeIntervalSince(catalogDate) > 30 * 60
    }

    func selectServer(_ server: SpeedServer?) {
        guard !runState.isRunning else { return }
        serverPrefs.selectedID = server?.id ?? SpeedServerPrefs.automaticID
        serverPrefs.selected = server?.stored
        saveServers()
    }

    func toggleFavorite(_ server: SpeedServer) {
        serverPrefs.toggleFavorite(server)
        saveServers()
    }

    /// Ajoute le serveur personnalisé saisi (compatible LibreSpeed) et le choisit.
    func addCustomServer() {
        do {
            let server = try SpeedServer.custom(address: customAddress, label: customLabel)
            serverPrefs.addCustom(server)
            customAddress = ""
            customLabel = ""
            customError = nil
            selectServer(server)
            toast = "Serveur « \(server.name) » ajouté aux favoris"
        } catch {
            customError = error.localizedDescription
        }
    }

    func removeCustomServer(_ server: SpeedServer) {
        serverPrefs.removeCustom(id: server.id)
        saveServers()
    }

    /// Recharge la liste et mesure les latences (bouton « Actualiser »).
    func refreshCatalog() {
        guard !catalogLoading, !Launcher.isDemo else { return }
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            await self?.loadCatalog(includeOokla: self?.ooklaEnabled == true)
        }
    }

    /// `quick` : une seule connexion par serveur (choix automatique juste avant un test).
    private func loadCatalog(includeOokla: Bool, quick: Bool = false) async {
        guard !Launcher.isDemo else { return }
        catalogLoading = true
        catalogStatus = "Chargement de la liste des serveurs…"
        let extra = serverPrefs.custom + serverPrefs.favorites
        let status: @Sendable (String) -> Void = { text in
            Task { @MainActor in SpeedtestModel.shared.catalogStatus = text }
        }
        let result = await SpeedServerCatalog.load(ooklaPath: includeOokla ? ooklaPath : nil, extra: extra,
                                                   probes: quick ? 1 : 3, timeout: quick ? 1 : 1.5, progress: status)
        // Chargement interrompu : liste partielle, souvent sans latence ; on garde l'ancienne.
        if Task.isCancelled {
            catalogLoading = false
            catalogStatus = catalog.isEmpty ? "Chargement interrompu" : Self.catalogSummary(catalog)
            return
        }
        // Les serveurs Ookla déjà listés restent si on recharge sans eux (test automatique).
        let keptOokla = includeOokla ? [] : catalog.filter { $0.source == .ookla }
        catalog = result.servers + keptOokla.filter { item in !result.servers.contains { $0.id == item.id } }
        // Sans aucune latence mesurée, la liste n'est pas datée : le choix automatique la remesurera.
        catalogDate = result.servers.contains { $0.latencyMs != nil } ? result.date : nil
        catalogFailures = result.failures
        catalogLoading = false
        catalogStatus = Self.catalogSummary(result.servers)
    }

    /// « 12 serveurs · 9 joignables ».
    static func catalogSummary(_ servers: [SpeedServer]) -> String {
        let measured = servers.filter { $0.latencyMs != nil }.count
        return "\(MonText.plural(servers.count, "serveur", "serveurs")) · \(MonText.plural(measured, "joignable", "joignables"))"
    }

    /// Cherche le CLI d'Ookla et vérifie que c'est bien celui d'Ookla (« --version », local).
    func refreshOokla() {
        if let demo = DemoTools.presence(for: .ooklaSpeedtest) {
            ooklaPath = demo.path
            return
        }
        Task.detached(priority: .utility) {
            let path = OoklaLocator.findVerified()
            await MainActor.run { SpeedtestModel.shared.ooklaPath = path }
        }
    }

    private func saveServers() {
        guard let serverStore else { return }
        do {
            try serverStore.save(serverPrefs)
        } catch {
            AppLog.shared.error("Speedtest", "Enregistrement des serveurs Speedtest impossible : \(error.localizedDescription)")
        }
    }

    private func resetResults() {
        gaugeValue = 0
        fraction = 0
        elapsed = 0
        downSeries = []
        upSeries = []
        idleLatency = nil
        jitter = nil
        downMbps = nil
        upMbps = nil
        summary = nil
        freshRecordID = nil
        server = nil
        latencyDuration = 0
    }

    private func handle(_ event: SpeedEvent, interface: LocalInterface?) {
        switch event {
        case .update(let update):
            runState = .running(update.phase)
            fraction = update.fraction.isFinite ? update.fraction : fraction
            switch update.phase {
            case .latency:
                elapsed = update.elapsed
                if let latency = update.latencyMs { gaugeValue = latency }
            case .download:
                elapsed = latencyDuration + update.elapsed
                gaugeValue = update.mbps ?? 0
                downSeries.append(SpeedPoint(time: update.elapsed, mbps: update.mbps ?? 0))
            case .upload:
                elapsed = latencyDuration + (downSeries.last?.time ?? 10) + update.elapsed
                gaugeValue = update.mbps ?? 0
                upSeries.append(SpeedPoint(time: update.elapsed, mbps: update.mbps ?? 0))
            }
        case .server(let info):
            server = info
        case .latencyMeasured(let idle, let jitter):
            latencyDuration = elapsed
            idleLatency = idle
            self.jitter = jitter
            gaugeValue = 0
        case .downloadMeasured(let value):
            downMbps = value
            gaugeValue = 0
        case .uploadMeasured(let value):
            upMbps = value
        case .finished(let result):
            summary = result
            downMbps = result.downMbps
            upMbps = result.upMbps
            gaugeValue = result.downMbps
            fraction = 1
            runState = .done
            let tested = testedServer ?? .cloudflare
            // Toujours le serveur de ce test (jamais celui du précédent), comme dans l'historique.
            server = result.server ?? SpeedServerInfo(city: tested.city, country: tested.country,
                                                      source: tested.source.label, serverName: tested.name,
                                                      serverID: tested.id)
            let record = SpeedTestRecord(
                kind: .internet, server: result.server?.label ?? tested.historyLabel,
                interfaceName: interface?.name ?? "—", interfaceKind: interface?.kind.label ?? "",
                downMbps: result.downMbps, upMbps: result.upMbps, latencyMs: result.idleLatencyMs,
                loadedLatencyMs: result.loadedLatencyMs, jitterMs: result.jitterMs, streams: result.streams,
                serverSource: tested.source, serverID: Self.recordServerID(result.server, tested: tested))
            addToHistory(record)
            toast = "Test terminé et ajouté à l’historique"
        case .failed(let message):
            runState = .failed(message)
            gaugeValue = 0
        }
    }

    private var latencyDuration: Double = 0

    /// Clé du serveur dans l'historique : Cloudflare par nœud (« cloudflare:YUL »), sinon l'identifiant.
    static func recordServerID(_ info: SpeedServerInfo?, tested: SpeedServer) -> String {
        if let id = info?.serverID { return id }
        if tested.source == .cloudflare, let colo = info?.colo { return "cloudflare:\(colo)" }
        return tested.id
    }

    // MARK: Test iperf3

    var lanOptions: IperfOptions {
        IperfOptions(host: lanHost.trimmingCharacters(in: .whitespaces), port: Int(lanPort) ?? 5201,
                     duration: lanDuration, streams: lanStreams, transport: lanTransport, direction: lanDirection)
    }

    func startLan(interface: LocalInterface?) {
        guard !lanRunning else { return }
        ToolInstallMonitor.shared(.iperf3).refresh()
        let options = lanOptions
        lanError = nil
        guard let path = iperfPath else {
            lanError = IperfLocator.missingMessage
            return
        }
        do {
            _ = try options.arguments()
        } catch {
            lanError = error.localizedDescription
            return
        }
        lanRunning = true
        lanStartedAt = Date()
        lanResult = nil
        lanGeneration += 1
        let generation = lanGeneration
        lanTask = Task { [weak self] in
            do {
                // Démonstration : résultat rejoué, iperf3 n'est jamais lancé.
                let result = Launcher.isDemo ? try await Self.demoLanRun(options)
                                             : try await IperfRunner.run(options, executable: path)
                guard let self, self.lanGeneration == generation else { return }
                self.lanResult = result
                self.lanRunning = false
                let record = SpeedTestRecord(
                    kind: .lan, server: "\(options.host):\(options.port)",
                    interfaceName: interface?.name ?? "—", interfaceKind: interface?.kind.label ?? "",
                    downMbps: result.megabitsPerSecond, upMbps: result.reverseMegabitsPerSecond,
                    jitterMs: result.jitterMs, streams: options.streams)
                self.addToHistory(record)
                self.toast = "Test iperf3 terminé et ajouté à l’historique"
            } catch {
                guard let self, self.lanGeneration == generation else { return }
                self.lanRunning = false
                if !Task.isCancelled { self.lanError = error.localizedDescription }
            }
        }
    }

    /// Test iperf3 de démonstration (`--demo`) : attend la durée choisie (3 s au plus), sans réseau.
    private static func demoLanRun(_ options: IperfOptions) async throws -> IperfResult {
        try await Task.sleep(nanoseconds: UInt64(min(3, max(1, Double(options.duration)))) * 1_000_000_000)
        var result = SpeedtestDemo.lanResult()
        result.remoteHost = options.host
        result.remotePort = options.port
        return result
    }

    func stopLan() {
        lanGeneration += 1
        lanTask?.cancel()
        lanTask = nil
        lanRunning = false
    }

    // MARK: Historique

    private func addToHistory(_ record: SpeedTestRecord) {
        history = SpeedHistoryStore.pruned([record] + history)
        freshRecordID = record.id
        persist()
    }

    var filteredHistory: [SpeedTestRecord] {
        guard let historyFilter else { return history }
        return history.filter { $0.kind == historyFilter }
    }

    func setHistory(_ records: [SpeedTestRecord]) {
        history = SpeedHistoryStore.pruned(records)
    }

    /// Enregistre l'historique au format CSV (fenêtre d'enregistrement).
    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Exporter l’historique"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "speedtest-historique-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // BOM UTF-8 : Excel reconnaît les accents.
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(SpeedHistoryStore.csv(filteredHistory).utf8)
            try data.write(to: url, options: .atomic)
            toast = "Historique exporté : \(url.lastPathComponent)"
        } catch {
            toast = "Export impossible : \(error.localizedDescription)"
        }
    }

    private func savePlan() {
        guard !loading else { return }
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(SpeedHistoryStore.Content(records: history, planDownMbps: planDown, planUpMbps: planUp))
        } catch {
            AppLog.shared.error("Speedtest", "Enregistrement de l’historique Speedtest impossible : \(error.localizedDescription)")
        }
    }

    // MARK: Démonstration

    /// Remplit l'écran avec les valeurs du croquis (captures --demo).
    func loadDemo(result: SpeedTestSummary, down: [SpeedPoint], up: [SpeedPoint], history: [SpeedTestRecord],
                  lan: IperfResult?, lanHost: String) {
        summary = result
        server = result.server
        idleLatency = result.idleLatencyMs
        jitter = result.jitterMs
        downMbps = result.downMbps
        upMbps = result.upMbps
        gaugeValue = result.downMbps
        fraction = 1
        elapsed = 21.5
        downSeries = down
        upSeries = up
        runState = .done
        streams = result.streams
        self.history = history
        lanResult = lan
        self.lanHost = lanHost
        planDownText = "1000"
        planUpText = "500"
    }

    /// Serveurs de démonstration (latences mesurées fictives), favoris et choix.
    func loadDemoServers(_ servers: [SpeedServer], prefs: SpeedServerPrefs, tested: SpeedServer) {
        catalog = servers
        catalogDate = Date()
        catalogStatus = Self.catalogSummary(servers)
        serverPrefs = prefs
        testedServer = tested
    }
}

/// Mise en forme des nombres à la française (virgule décimale, pas de séparateur de milliers).
enum SpeedFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func integer(_ value: Double) -> String {
        value.isFinite ? String(value.clampedInt) : "—"
    }

    /// Débit : entier au-delà de 100 Mb/s, une décimale en dessous.
    static func rate(_ value: Double) -> String {
        value >= 100 ? integer(value) : number(value, digits: 1)
    }

    /// Latence : une décimale sous 10 ms, entier au-delà.
    static func latency(_ value: Double) -> String {
        value < 10 ? number(value, digits: 1) : integer(value)
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        // « inf », « nan » ou « 1e400 » ne font pas un forfait : borne réaliste en Mb/s.
        guard let value = Double(cleaned), value.isFinite, value > 0, value <= 1_000_000 else { return nil }
        return value
    }

    static func bytes(_ value: Int64) -> String {
        let megabytes = Double(value) / 1_000_000
        return megabytes >= 1000 ? number(megabytes / 1000, digits: 2) + " Go" : number(megabytes, digits: 1) + " Mo"
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
