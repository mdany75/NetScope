import Foundation
import NetScopeCore

/// Wi-Fi géré par les FortiGate (note 27) : bornes FortiAP, clients, SSID et AP voisins des
/// FortiGate choisies pour les switchs (`FortiControllerSelector`), lus par l'API REST en
/// lecture seule après chaque lecture des switchs et à la demande de l'écran Wi-Fi. Le jeton
/// reste dans FortiGateStore (Trousseau) ; rien n'est enregistré sur disque sauf les seuils.
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de FortiAPDemo.
@MainActor
final class FortiAPStore: ObservableObject {
    static let shared = FortiAPStore()

    private static let thresholdsKey = "NetScope.fortiap.seuils"

    /// Lectures réussies de la dernière relecture, une par site.
    @Published private(set) var sites: [FortiWifiSiteReport] = []
    @Published private(set) var overview = FortiWifiOverview()
    @Published private(set) var diagnosis = FortiWifiAnalysis.diagnose(FortiWifiOverview())
    /// Erreur de la dernière lecture de chaque FortiGate (403 expliqué, jeton absent…).
    @Published private(set) var errors: [UUID: String] = [:]
    /// Appels Wi-Fi de la dernière lecture de chaque FortiGate (réponses brutes du diagnostic).
    @Published private(set) var calls: [UUID: [FortiCallRecord]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var lastRefresh: Date?
    /// FortiGate choisies pour la dernière lecture.
    @Published private(set) var selection = FortiControllerSelection()
    /// Borne (et bande) à montrer à l'ouverture de Wi-Fi › FortiAP (fiche d'un appareil client).
    @Published var focusAP: FortiManagedAP.ID?
    @Published var focusBand: WifiBand?
    @Published var thresholds: FortiWifiThresholds {
        didSet {
            guard thresholds != oldValue else { return }
            if !isDemo, let data = try? JSONEncoder().encode(thresholds) { UserDefaults.standard.set(data, forKey: Self.thresholdsKey) }
            recompute()
        }
    }

    let isDemo: Bool
    private var byMAC: [MACAddress: FortiWifiClient] = [:]
    private var byIP: [IPv4Address: [FortiWifiClient]] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if !demo, let data = UserDefaults.standard.data(forKey: Self.thresholdsKey),
           let saved = try? JSONDecoder().decode(FortiWifiThresholds.self, from: data) {
            thresholds = saved
        } else {
            thresholds = .standard
        }
        if demo {
            let initial = FortiAPDemo.initialSites()
            sites = initial
            selection = FortiControllerSelector.select(FortiGateSitesDemo.controllers(), scanned: FortiGateSitesDemo.scannedRanges,
                                                       macAddress: DemoData.interface.address)
            calls = Dictionary(uniqueKeysWithValues: initial.map { ($0.controllerID, $0.report.calls) })
            lastRefresh = initial.map(\.report.readAt).max()
            recompute()
        }
    }

    // MARK: État

    var hasData: Bool { !overview.aps.isEmpty || !overview.clients.isEmpty }

    /// Lecture tentée sans aucune FortiGate lue : message des erreurs (sondes de la Surveillance).
    var readError: String? {
        guard lastRefresh != nil, overview.readAt == nil else { return nil }
        let messages = Array(Set(errors.values)).sorted()
        return messages.isEmpty ? "Aucune FortiGate lue pour le Wi-Fi" : messages.joined(separator: " ")
    }

    /// « Relire les bornes » possible : lecture activée, une FortiGate choisie, jeton et empreinte
    /// présents (même condition pour le bandeau et la barre d'outils).
    func canRefresh(state: AppState) -> Bool {
        let fortigate = FortiGateStore.shared
        return fortigate.isEnabled && !fortigate.previewSelection(state: state).isEmpty && (fortigate.isReady || fortigate.isDemo)
    }
    /// Libellé des sites lus (« Siège », « Siège, Entrepôt Laval »).
    var sitesLabel: String { sites.map(\.site).joined(separator: ", ") }

    private func recompute() {
        overview = FortiWifiMerge.overview(sites)
        diagnosis = FortiWifiAnalysis.diagnose(overview, thresholds: thresholds)
        byMAC = [:]
        byIP = [:]
        for client in overview.clients {
            if byMAC[client.mac] == nil { byMAC[client.mac] = client }
            if let ip = client.ip { byIP[ip, default: []].append(client) }
        }
    }

    /// Client Wi-Fi d'un appareil du Scanner : par MAC, sinon par adresse IP quand elle est unique
    /// (même règle que `FortiWifiMerge.match`).
    func client(for device: Device) -> FortiWifiClient? {
        if let mac = device.mac { return byMAC[mac] }
        if let list = byIP[device.ip], list.count == 1 { return list[0] }
        return nil
    }

    func ap(for client: FortiWifiClient) -> FortiManagedAP? { overview.ap(for: client) }

    func isWeak(_ client: FortiWifiClient) -> Bool { FortiWifiAnalysis.isWeak(client, thresholds: thresholds) }

    // MARK: Lecture

    /// Relecture des FortiGate choisies pour les switchs (appelée par FortiGateStore).
    func refresh(selection chosen: FortiControllerSelection, state: AppState) {
        task?.cancel()
        task = Task { [weak self] in await self?.read(chosen) }
    }

    /// « Relire » de l'écran Wi-Fi : plages cochées du Scanner, sinon l'adresse du Mac.
    func refreshNow(state: AppState) {
        refresh(selection: FortiGateStore.shared.previewSelection(state: state), state: state)
    }

    /// Sondes de la Surveillance : relit si la dernière lecture date de plus de `maxAge` secondes,
    /// et attend la fin de la lecture.
    func refreshForMonitoring(maxAge: TimeInterval, state: AppState?) async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
        // Une lecture en cours (`task` est remis à nil à la fin de chaque lecture) : l'attendre,
        // puis relire seulement si elle n'a rien donné de récent (annulée par une plus récente).
        if let running = task {
            await running.value
            if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
            if task != nil { return }
        }
        let chosen = state.map { FortiGateStore.shared.previewSelection(state: $0) } ?? FortiGateStore.shared.selection
        let next: Task<Void, Never> = Task { [weak self] in await self?.read(chosen) }
        task = next
        await next.value
    }

    private func read(_ chosen: FortiControllerSelection) async {
        generation += 1
        let mine = generation
        selection = chosen
        busy = true
        defer {
            if mine == generation {
                busy = false
                task = nil
            }
        }
        if isDemo {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard mine == generation, !Task.isCancelled else { return }
            sites = FortiAPDemo.sites(for: chosen)
            calls = Dictionary(uniqueKeysWithValues: sites.map { ($0.controllerID, $0.report.calls) })
            errors = [:]
            lastRefresh = Date()
            recompute()
            return
        }
        let fortigate = FortiGateStore.shared
        guard fortigate.isEnabled else {
            sites = []
            errors = [:]
            calls = [:]
            lastRefresh = nil
            recompute()
            return
        }
        let targets = await fortigate.wifiTargets(for: chosen)
        let jobs = targets.ready.map { WifiJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1) }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await FortiAPStore.performRead(job)
        }
        guard mine == generation, !Task.isCancelled else { return }
        var fresh: [FortiWifiSiteReport] = []
        var newErrors = targets.blocked
        var newCalls: [UUID: [FortiCallRecord]] = [:]
        for (job, result) in zip(jobs, results) {
            switch result {
            case .success(let report):
                fresh.append(FortiWifiSiteReport(controllerID: job.id, site: job.site, report: report))
                newCalls[job.id] = report.calls
            case .failure(let message, let records):
                newErrors[job.id] = message
                newCalls[job.id] = records
            case .cancelled:
                break
            }
        }
        sites = fresh
        errors = newErrors
        calls = newCalls
        lastRefresh = Date()
        recompute()
    }

    private struct WifiJob: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
    }

    private enum WifiResult: Sendable {
        case success(FortiWifiReport)
        case failure(String, [FortiCallRecord])
        case cancelled
    }

    /// Lecture réseau, hors du fil principal (GET seulement).
    nonisolated private static func performRead(_ job: WifiJob) async -> WifiResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readWifiKeepingCalls())
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.wifiDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.wifiDescription, token: job.token), [])
        } catch {
            return .failure("Lecture Wi-Fi impossible.", [])
        }
    }
}
