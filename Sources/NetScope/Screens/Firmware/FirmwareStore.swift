import Foundation
import NetScopeCore

/// Firmware et licences du parc Fortinet (note 41) : versions FortiOS, FortiSwitch et FortiAP de
/// chaque FortiGate, versions disponibles ou recommandées, contrats FortiGuard et FortiCare, lus
/// par l'API REST en lecture seule. NetScope ne lance jamais de mise à jour. Les lectures sont
/// gardées par FortiGate : la vue « Tous les sites », les sondes de la Surveillance et les rapports
/// s'en servent. Le jeton reste dans FortiGateStore (Trousseau) ; seuls les seuils des licences
/// sont enregistrés (préférences).
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de FirmwareDemo.
@MainActor
final class FirmwareStore: ObservableObject {
    static let shared = FirmwareStore()

    private static let thresholdsKey = "NetScope.firmware.seuils"

    /// Dernière lecture réussie de chaque FortiGate.
    @Published private(set) var reports: [UUID: FirmwareSiteReport] = [:]
    /// Erreur de la dernière lecture de chaque FortiGate (403 expliqué, jeton absent…).
    @Published private(set) var errors: [UUID: String] = [:]
    /// Appels de la dernière lecture de chaque FortiGate (réponses brutes du diagnostic).
    @Published private(set) var calls: [UUID: [FortiCallRecord]] = [:]
    @Published private(set) var reading: Set<UUID> = []
    @Published private(set) var lastRefresh: Date?
    /// Équipement détaillé (identifiant `FirmwareDevice.id`).
    @Published var selectedDeviceID: String?
    @Published var thresholds: FirmwareThresholds {
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
           let saved = try? JSONDecoder().decode(FirmwareThresholds.self, from: data) {
            thresholds = saved
        } else {
            thresholds = .standard
        }
        if demo {
            let content = FirmwareDemo.make()
            reports = content.reports
            errors = content.errors
            calls = content.calls
            lastRefresh = content.reports.values.map(\.report.readAt).max()
            selectedDeviceID = FirmwareDemo.initialDeviceID
        }
    }

    // MARK: Sites affichés

    /// FortiGate des sites donnés (clés de SiteScopeStore) ; mêmes règles que le WAN.
    func controllerIDs(forSiteKeys keys: [String], state: AppState) -> [UUID] {
        WANStore.shared.controllerIDs(forSiteKeys: keys, state: state)
    }

    /// Vue des FortiGate données (dans l'ordre donné).
    func overview(_ ids: [UUID], now: Date = Date()) -> FirmwareOverview {
        FirmwareAnalysis.overview(ids.compactMap { reports[$0] }, thresholds: thresholds, now: now)
    }

    func errorList(_ ids: [UUID]) -> [(site: String, message: String)] {
        let names = FortiGateStore.shared.controllerNames
        return ids.compactMap { id in errors[id].map { (names[id] ?? "FortiGate", $0) } }
    }

    func isReading(_ ids: [UUID]) -> Bool { !reading.isDisjoint(with: ids) }

    func readDate(_ ids: [UUID]) -> Date? { ids.compactMap { reports[$0]?.report.readAt }.min() }

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

    /// « Relire » : GET seulement, quatre FortiGate à la fois au plus.
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
            let content = FirmwareDemo.make()
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
        let jobs = targets.ready.map { FirmwareJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1) }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await FirmwareStore.performRead(job)
        }
        for (job, result) in zip(jobs, results) where generation[job.id] == mine[job.id] {
            switch result {
            case .success(let report):
                reports[job.id] = FirmwareSiteReport(controllerID: job.id, site: job.site, report: report)
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

    private struct FirmwareJob: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
    }

    private enum FirmwareResult: Sendable {
        case success(FirmwareReadReport)
        case failure(String, [FortiCallRecord])
        case cancelled
    }

    /// Lecture réseau, hors du fil principal (GET seulement).
    nonisolated private static func performRead(_ job: FirmwareJob) async -> FirmwareResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readFirmwareKeepingCalls())
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.firmwareDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.firmwareDescription, token: job.token), [])
        } catch {
            return .failure("Lecture du firmware et des licences impossible.", [])
        }
    }

    // MARK: Surveillance

    var monitoredIDs: [UUID] { FortiGateStore.shared.enabledControllers.map(\.id) }

    /// Vue de toutes les FortiGate activées (sondes « Licence bientôt expirée » et « Firmware pas à jour »).
    var monitoringOverview: FirmwareOverview { overview(monitoredIDs) }

    var readError: String? {
        let ids = monitoredIDs
        guard ids.allSatisfy({ reports[$0] == nil }) else { return nil }
        let messages = Array(Set(ids.compactMap { errors[$0] })).sorted()
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    var monitoringErrors: [String: String] {
        let names = FortiGateStore.shared.controllerNames
        var result: [String: String] = [:]
        for id in monitoredIDs where reports[id] == nil {
            guard let message = errors[id] else { continue }
            result[names[id] ?? "FortiGate"] = message
        }
        return result
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

    func addToReport() {
        RapportModel.shared.config.sections.insert(.firmware)
    }

    var isInReport: Bool { RapportModel.shared.config.sections.contains(.firmware) }

    /// Vue pour le rapport : FortiGate du site actif ; nil sans lecture.
    func reportOverview(state: AppState) -> FirmwareOverview? {
        let ids = controllerIDs(forSiteKeys: [SiteModel.shared.activeKey], state: state)
        let view = overview(ids)
        return view.sites.isEmpty ? nil : view
    }
}
