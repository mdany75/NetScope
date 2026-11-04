import Foundation
import NetScopeCore

/// WAN et VPN des FortiGate (note 39) : liens WAN, sondes SD-WAN et SLA, tunnels IPsec et VPN SSL
/// de chaque FortiGate, lus par l'API REST en lecture seule. Les lectures sont gardées par
/// FortiGate (pas seulement celles du site actif) : la vue « Tous les sites » et les sondes de la
/// Surveillance s'en servent. Le jeton reste dans FortiGateStore (Trousseau) ; seuls les seuils
/// sont enregistrés (préférences).
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de WANDemo.
@MainActor
final class WANStore: ObservableObject {
    static let shared = WANStore()

    private static let thresholdsKey = "NetScope.wan.seuils"

    /// Dernière lecture réussie de chaque FortiGate.
    @Published private(set) var reports: [UUID: WANSiteReport] = [:]
    /// Erreur de la dernière lecture de chaque FortiGate (403 expliqué, jeton absent…).
    @Published private(set) var errors: [UUID: String] = [:]
    /// Appels de la dernière lecture de chaque FortiGate (réponses brutes du diagnostic).
    @Published private(set) var calls: [UUID: [FortiCallRecord]] = [:]
    /// FortiGate en cours de lecture.
    @Published private(set) var reading: Set<UUID> = []
    @Published private(set) var lastRefresh: Date?
    /// Tunnel détaillé (identifiant `WANTunnelUsage.id`).
    @Published var selectedTunnelID: String?
    @Published var thresholds: WANThresholds {
        didSet {
            guard thresholds != oldValue, !isDemo, let data = try? JSONEncoder().encode(thresholds) else { return }
            UserDefaults.standard.set(data, forKey: Self.thresholdsKey)
        }
    }

    let isDemo: Bool
    private var generation: [UUID: Int] = [:]
    private var monitoringTask: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if !demo, let data = UserDefaults.standard.data(forKey: Self.thresholdsKey),
           let saved = try? JSONDecoder().decode(WANThresholds.self, from: data) {
            thresholds = saved
        } else {
            thresholds = .standard
        }
        if demo {
            let content = WANDemo.make()
            reports = content.reports
            errors = content.errors
            calls = content.calls
            lastRefresh = content.reports.values.map(\.report.readAt).max()
            selectedTunnelID = WANDemo.initialTunnelID
        }
    }

    // MARK: Sites affichés

    /// FortiGate des sites donnés (clés de SiteScopeStore) ; sans aucun site défini, celles choisies
    /// pour le Scanner (plages cochées, sinon l'adresse du Mac).
    func controllerIDs(forSiteKeys keys: [String], state: AppState) -> [UUID] {
        let fortigate = FortiGateStore.shared
        let model = SiteModel.shared
        var ids: [UUID] = []
        if model.sites.isEmpty {
            ids = fortigate.previewSelection(state: state).controllerIDs
        } else {
            for key in keys { ids += model.site(forKey: key)?.fortiGateIDs ?? [] }
        }
        var seen = Set<UUID>()
        return ids.filter { id in fortigate.controller(id)?.isEnabled == true && seen.insert(id).inserted }
    }

    /// Vue des FortiGate données (dans l'ordre donné).
    func overview(_ ids: [UUID]) -> WANOverview {
        WANAnalysis.overview(ids.compactMap { reports[$0] }, thresholds: thresholds)
    }

    /// Erreurs des FortiGate données, avec le nom du site.
    func errorList(_ ids: [UUID]) -> [(site: String, message: String)] {
        let names = FortiGateStore.shared.controllerNames
        return ids.compactMap { id in errors[id].map { (names[id] ?? "FortiGate", $0) } }
    }

    func isReading(_ ids: [UUID]) -> Bool { !reading.isDisjoint(with: ids) }

    /// Date de la plus ancienne lecture des FortiGate données.
    func readDate(_ ids: [UUID]) -> Date? { ids.compactMap { reports[$0]?.report.readAt }.min() }

    /// « Relire » possible : lecture des FortiGate activée et au moins une FortiGate prête.
    func canRead(_ ids: [UUID]) -> Bool {
        let fortigate = FortiGateStore.shared
        guard fortigate.isEnabled || isDemo else { return false }
        return ids.contains { id in fortigate.controller(id).map { fortigate.isReady($0) || isDemo } ?? false }
    }

    // MARK: Lecture

    /// Ouverture de la vue : lit les FortiGate encore jamais lues (ni en erreur).
    func readIfNeeded(_ ids: [UUID]) {
        let missing = ids.filter { reports[$0] == nil && errors[$0] == nil && !reading.contains($0) }
        guard !missing.isEmpty, canRead(missing) else { return }
        read(missing)
    }

    /// « Relire les FortiGate » : GET seulement, quatre FortiGate à la fois au plus.
    func read(_ ids: [UUID]) {
        let wanted = ids.filter { !reading.contains($0) }
        guard !wanted.isEmpty else { return }
        Task { await perform(wanted) }
    }

    private func perform(_ ids: [UUID]) async {
        var mine: [UUID: Int] = [:]
        for id in ids {
            generation[id, default: 0] += 1
            mine[id] = generation[id]
            reading.insert(id)
        }
        defer {
            for id in ids where generation[id] == mine[id] { reading.remove(id) }
        }
        if isDemo {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let content = WANDemo.make()
            for id in ids where generation[id] == mine[id] {
                reports[id] = content.reports[id]
                errors[id] = content.errors[id]
                calls[id] = content.calls[id]
            }
            lastRefresh = Date()
            return
        }
        let fortigate = FortiGateStore.shared
        guard fortigate.isEnabled else { return }
        let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: ids.compactMap { id in
            fortigate.controller(id).map { FortiControllerSelection.Pick(controllerID: id, site: $0.displayName, reason: .activeSite) }
        }))
        for (id, message) in targets.blocked where generation[id] == mine[id] {
            errors[id] = message
            reports[id] = nil
        }
        let jobs = targets.ready.map { WANJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1) }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await WANStore.performRead(job)
        }
        for (job, result) in zip(jobs, results) where generation[job.id] == mine[job.id] {
            switch result {
            case .success(let report):
                let withRates = WANAnalysis.withRates(report, previous: reports[job.id]?.report)
                reports[job.id] = WANSiteReport(controllerID: job.id, site: job.site, report: withRates)
                errors[job.id] = nil
                calls[job.id] = report.calls
            case .failure(let message, let records):
                errors[job.id] = message
                reports[job.id] = nil
                calls[job.id] = records
            case .cancelled:
                break
            }
        }
        lastRefresh = Date()
    }

    private struct WANJob: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
    }

    private enum WANResult: Sendable {
        case success(WANReadReport)
        case failure(String, [FortiCallRecord])
        case cancelled
    }

    /// Lecture réseau, hors du fil principal (GET seulement).
    nonisolated private static func performRead(_ job: WANJob) async -> WANResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readWANKeepingCalls())
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.wanDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.wanDescription, token: job.token), [])
        } catch {
            return .failure("Lecture du WAN impossible.", [])
        }
    }

    // MARK: Surveillance

    /// FortiGate suivies par les sondes : toutes celles activées.
    var monitoredIDs: [UUID] { FortiGateStore.shared.enabledControllers.map(\.id) }

    /// Vue de toutes les FortiGate activées (sondes « Tunnel VPN tombé » et « Lien WAN dégradé »).
    var monitoringOverview: WANOverview { overview(monitoredIDs) }

    /// Lecture tentée sans aucune FortiGate lue : message des erreurs.
    var readError: String? {
        let ids = monitoredIDs
        guard ids.allSatisfy({ reports[$0] == nil }) else { return nil }
        let messages = Array(Set(ids.compactMap { errors[$0] })).sorted()
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// Sonde de la Surveillance : relit les FortiGate dont la lecture date de plus de `maxAge`
    /// secondes, et attend la fin de la lecture.
    func refreshForMonitoring(maxAge: TimeInterval) async {
        if let running = monitoringTask { await running.value }
        let now = Date()
        let stale = monitoredIDs.filter { id in
            guard !reading.contains(id) else { return false }
            guard let read = reports[id]?.report.readAt else { return true }
            return now.timeIntervalSince(read) >= maxAge
        }
        guard !stale.isEmpty, !isDemo else { return }
        let next: Task<Void, Never> = Task { [weak self] in await self?.perform(stale) }
        monitoringTask = next
        await next.value
        monitoringTask = nil
    }

    // MARK: Rapport

    /// Ajoute la section « WAN et VPN » au rapport en préparation.
    func addToReport() {
        RapportModel.shared.config.sections.insert(.wan)
    }

    var isInReport: Bool { RapportModel.shared.config.sections.contains(.wan) }

    /// Vue pour le rapport : FortiGate du site actif.
    func reportOverview(state: AppState) -> WANOverview? {
        let ids = controllerIDs(forSiteKeys: [SiteModel.shared.activeKey], state: state)
        let view = overview(ids)
        return view.sites.isEmpty ? nil : view
    }
}
