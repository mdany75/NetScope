import Foundation
import NetScopeCore

/// Étendues DHCP (note 37) : configuration des serveurs DHCP et baux des FortiGate choisies pour
/// les switchs (`FortiControllerSelector`), lus par l'API REST en lecture seule après chaque
/// lecture des switchs, à l'ouverture de l'outil et pour la sonde de la Surveillance. Sans
/// FortiGate lue : estimation à partir des offres du Test DHCP et des appareils du scan, marquée
/// « estimation ». Le jeton reste dans FortiGateStore (Trousseau) ; seuls les seuils sont
/// enregistrés (préférences).
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de DHCPScopeDemo.
@MainActor
final class DHCPScopeStore: ObservableObject {
    static let shared = DHCPScopeStore()

    private static let thresholdsKey = "NetScope.dhcp.etendues.seuils"

    /// Lectures réussies de la dernière relecture, une par site.
    @Published private(set) var sites: [DHCPScopeSiteReport] = []
    /// Étendues lues sur les FortiGate (vide sans lecture).
    @Published private(set) var fortiOverview = DHCPScopeOverview()
    /// Erreur de la dernière lecture de chaque FortiGate (403 expliqué, jeton absent…).
    @Published private(set) var errors: [UUID: String] = [:]
    /// Appels de la dernière lecture de chaque FortiGate (réponses brutes du diagnostic).
    @Published private(set) var calls: [UUID: [FortiCallRecord]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var lastRefresh: Date?
    /// Étendue détaillée dans l'outil.
    @Published var selectedScopeID: String?
    @Published var thresholds: DHCPScopeThresholds {
        didSet {
            guard thresholds != oldValue else { return }
            if !isDemo, let data = try? JSONEncoder().encode(thresholds) { UserDefaults.standard.set(data, forKey: Self.thresholdsKey) }
            recompute()
        }
    }

    let isDemo: Bool
    private var task: Task<Void, Never>?
    private var generation = 0

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if !demo, let data = UserDefaults.standard.data(forKey: Self.thresholdsKey),
           let saved = try? JSONDecoder().decode(DHCPScopeThresholds.self, from: data) {
            thresholds = saved
        } else {
            thresholds = .standard
        }
        if demo {
            sites = DHCPScopeDemo.sites(for: DHCPScopeDemo.initialSelection())
            calls = Dictionary(uniqueKeysWithValues: sites.map { ($0.controllerID, $0.report.calls) })
            lastRefresh = sites.map(\.report.readAt).max()
            recompute()
            selectedScopeID = fortiOverview.scopes.first { $0.interface == DHCPScopeDemo.initialScopeInterface }?.id
        }
    }

    // MARK: État

    /// Au moins une étendue lue sur une FortiGate.
    var hasFortiData: Bool { !fortiOverview.scopes.isEmpty }

    /// Étendues à montrer : celles des FortiGate, sinon l'estimation par le Test DHCP et le scan.
    func overview(devices: [Device]) -> DHCPScopeOverview {
        if hasFortiData { return fortiOverview }
        let dhcp = ToolStore.shared.dhcp
        var estimate = DHCPScopeAnalysis.estimatedOverview(offers: dhcp.offers, devices: devices,
                                                           site: SiteModel.shared.activeSite?.displayName ?? "",
                                                           thresholds: thresholds, now: dhcp.lastRun ?? Date())
        estimate.notes = fortiOverview.notes
        return estimate
    }

    /// Lecture tentée sans aucune FortiGate lue : message des erreurs (sonde de la Surveillance).
    var readError: String? {
        guard lastRefresh != nil, sites.isEmpty else { return nil }
        let messages = Array(Set(errors.values)).sorted()
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// « Relire » possible : lecture activée, une FortiGate choisie, jeton et empreinte présents.
    func canRefresh(state: AppState) -> Bool {
        let fortigate = FortiGateStore.shared
        return fortigate.isEnabled && !fortigate.previewSelection(state: state).isEmpty && (fortigate.isReady || fortigate.isDemo)
    }

    /// Libellé des sites lus (« Siège », « Siège, Entrepôt Laval »).
    var sitesLabel: String { sites.map(\.site).joined(separator: ", ") }

    private func recompute() {
        fortiOverview = DHCPScopeAnalysis.overview(sites, thresholds: thresholds)
    }

    // MARK: Lecture

    /// Relecture des FortiGate choisies pour les switchs (appelée par FortiGateStore).
    func refresh(selection chosen: FortiControllerSelection) {
        task?.cancel()
        task = Task { [weak self] in await self?.read(chosen) }
    }

    /// Changement de site : seules les étendues des FortiGate du nouveau site restent (rien n'est
    /// relu sur le réseau).
    func keepOnly(_ controllerIDs: Set<UUID>, selection chosen: FortiControllerSelection) {
        task?.cancel()
        task = nil
        generation += 1
        if isDemo {
            sites = DHCPScopeDemo.sites(for: chosen)
        } else {
            sites = sites.filter { controllerIDs.contains($0.controllerID) }
        }
        errors = errors.filter { controllerIDs.contains($0.key) }
        busy = false
        recompute()
        if let id = selectedScopeID, !fortiOverview.scopes.contains(where: { $0.id == id }) { selectedScopeID = nil }
    }

    /// « Relire » de l'outil : plages cochées du Scanner, sinon l'adresse du Mac.
    func refreshNow(state: AppState) {
        refresh(selection: FortiGateStore.shared.previewSelection(state: state))
    }

    /// Ouverture de l'outil : lit une première fois si rien n'a encore été lu.
    func refreshIfNeeded(state: AppState) {
        guard lastRefresh == nil, task == nil, canRefresh(state: state) else { return }
        refreshNow(state: state)
    }

    /// Sonde de la Surveillance : relit si la dernière lecture date de plus de `maxAge` secondes,
    /// et attend la fin de la lecture.
    func refreshForMonitoring(maxAge: TimeInterval, state: AppState?) async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
        if let running = task {
            await running.value
            if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
            if task != nil { return }
        }
        let chosen = state.map { FortiGateStore.shared.previewSelection(state: $0) } ?? FortiGateStore.shared.selection
        guard !chosen.isEmpty else { return }
        let next: Task<Void, Never> = Task { [weak self] in await self?.read(chosen) }
        task = next
        await next.value
    }

    private func read(_ chosen: FortiControllerSelection) async {
        generation += 1
        let mine = generation
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
            sites = DHCPScopeDemo.sites(for: chosen)
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
        // Mêmes FortiGate prêtes (jeton, empreinte) que la lecture Wi-Fi.
        let targets = await fortigate.wifiTargets(for: chosen)
        let jobs = targets.ready.map { ScopeJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1) }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await DHCPScopeStore.performRead(job)
        }
        guard mine == generation, !Task.isCancelled else { return }
        var fresh: [DHCPScopeSiteReport] = []
        var newErrors = targets.blocked
        var newCalls: [UUID: [FortiCallRecord]] = [:]
        for (job, result) in zip(jobs, results) {
            switch result {
            case .success(let report):
                fresh.append(DHCPScopeSiteReport(controllerID: job.id, site: job.site, report: report))
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

    private struct ScopeJob: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
    }

    private enum ScopeResult: Sendable {
        case success(DHCPScopeReadReport)
        case failure(String, [FortiCallRecord])
        case cancelled
    }

    /// Lecture réseau, hors du fil principal (GET seulement).
    nonisolated private static func performRead(_ job: ScopeJob) async -> ScopeResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readDHCPScopesKeepingCalls())
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.dhcpScopeDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.dhcpScopeDescription, token: job.token), [])
        } catch {
            return .failure("Lecture des étendues DHCP impossible.", [])
        }
    }

    // MARK: Rapport

    /// Ajoute la section « Étendues DHCP » au rapport en préparation.
    func addToReport() {
        RapportModel.shared.config.sections.insert(.dhcp)
    }

    var isInReport: Bool { RapportModel.shared.config.sections.contains(.dhcp) }
}
