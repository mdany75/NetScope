import AppKit
import Foundation
import NetScopeCore

/// Trafic des FortiGate (note 54) : vues FortiView (sources, destinations, applications,
/// catégories web, interfaces, politiques, menaces), sessions et liens, lus par l'API REST en
/// lecture seule pour les sites montrés par l'écran Trafic (menu « Site ▾ »), à l'ouverture de
/// l'écran, au changement de période et avec « Relire ». Les sondes de la Surveillance lisent le
/// temps réel du site actif. Le jeton reste dans FortiGateStore (Trousseau) ; seuls la période, le
/// tri et les seuils sont enregistrés (préférences).
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de TrafficDemo.
@MainActor
final class TrafficStore: ObservableObject {
    static let shared = TrafficStore()

    private static let periodKey = "NetScope.trafic.periode"
    private static let sortKey = "NetScope.trafic.tri"
    private static let thresholdsKey = "NetScope.trafic.seuils"

    @Published var period: TrafficPeriod {
        didSet {
            guard period != oldValue else { return }
            if !isDemo { UserDefaults.standard.set(period.rawValue, forKey: Self.periodKey) }
            // Autre période : les lectures gardées ne valent plus, on relit les sites montrés.
            cache = [:]
            errors = [:]
            invalidateAnalysisIfStale()
            recompute()
            refresh()
        }
    }
    @Published var sort: TrafficSort {
        didSet { if !isDemo { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) } }
    }
    @Published var thresholds: TrafficThresholds {
        didSet {
            guard thresholds != oldValue else { return }
            if !isDemo, let data = try? JSONEncoder().encode(thresholds) { UserDefaults.standard.set(data, forKey: Self.thresholdsKey) }
            recompute()
        }
    }
    /// Lectures réussies de la période choisie, par FortiGate.
    @Published private(set) var cache: [UUID: TrafficSiteReport] = [:]
    /// Erreur de la dernière lecture de chaque FortiGate (403 expliqué, jeton absent…).
    @Published private(set) var errors: [UUID: String] = [:]
    /// Appels de la dernière lecture de chaque FortiGate (réponses brutes du diagnostic).
    @Published private(set) var calls: [UUID: [FortiCallRecord]] = [:]
    @Published private(set) var reading: Set<UUID> = []
    @Published private(set) var lastRefresh: Date?
    /// Trafic des sites montrés, réunis.
    @Published private(set) var overview = TrafficOverview()
    /// Sites montrés par l'écran (clés `SiteFiles.key`).
    @Published private(set) var shownKeys: [String] = []
    /// Dernière analyse complète du réseau.
    @Published private(set) var analysis: NetworkAnalysisResult?
    /// Périmètre de l'analyse : sites montrés, période et présence du trafic au moment où elle a
    /// été faite (une analyse ne vaut que pour ce périmètre).
    private var analysisScope: (keys: [String], period: TrafficPeriod, withTraffic: Bool)?
    @Published var toast: String?

    /// Temps réel du site actif, pour les sondes (même si l'écran montre une autre période).
    private var monitorCache: [UUID: TrafficSiteReport] = [:]
    private var monitorError: String?
    private var monitorRefresh: Date?
    private var monitorTask: Task<Void, Never>?

    let isDemo: Bool

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        let defaults = UserDefaults.standard
        if demo {
            period = TrafficDemo.requestedPeriod ?? .realtime
            sort = .bandwidth
            thresholds = .standard
        } else {
            period = defaults.string(forKey: Self.periodKey).flatMap(TrafficPeriod.init(rawValue:)) ?? .realtime
            sort = defaults.string(forKey: Self.sortKey).flatMap(TrafficSort.init(rawValue:)) ?? .bandwidth
            thresholds = defaults.data(forKey: Self.thresholdsKey).flatMap { try? JSONDecoder().decode(TrafficThresholds.self, from: $0) } ?? .standard
        }
    }

    // MARK: Sites montrés

    /// FortiGate d'un site : celles du site enregistré, sinon (site actif sans site enregistré)
    /// celles choisies pour les switchs.
    func controllerIDs(forKey key: String) -> [UUID] {
        if let site = SiteModel.shared.site(forKey: key) { return site.fortiGateIDs }
        return key == SiteModel.shared.activeKey ? FortiGateStore.shared.selection.controllerIDs : []
    }

    var shownControllerIDs: [UUID] {
        var seen = Set<UUID>()
        return shownKeys.flatMap(controllerIDs(forKey:)).filter { seen.insert($0).inserted }
    }

    /// Site (clé) d'une FortiGate lue.
    func siteKey(forController id: UUID) -> String {
        SiteModel.shared.sites.first { $0.fortiGateIDs.contains(id) }.map { SiteFiles.key(for: $0.id) } ?? SiteModel.shared.activeKey
    }

    /// Site (clé) d'une ligne, d'après le nom du site qu'elle porte.
    func siteKey(forLabel label: String) -> String {
        if let report = cache.values.first(where: { $0.site == label }) { return siteKey(forController: report.controllerID) }
        return SiteModel.shared.sites.first { $0.displayName == label }.map { SiteFiles.key(for: $0.id) } ?? SiteModel.shared.activeKey
    }

    /// Change les sites montrés (menu « Site ▾ ») et lit ceux qui ne l'ont pas encore été.
    func setScope(_ keys: [String]) {
        guard keys != shownKeys else { return }
        shownKeys = keys
        invalidateAnalysisIfStale()
        recompute()
        refreshIfNeeded()
    }

    private func recompute() {
        let reports = shownControllerIDs.compactMap { cache[$0] }
        overview = named(TrafficAnalysis.merge(reports, period: period))
    }

    /// L'analyse vaut-elle pour les sites montrés et la période choisie ? Une analyse faite sans
    /// trafic ne dépend pas de la période.
    private var analysisMatchesScope: Bool {
        guard let scope = analysisScope else { return false }
        return scope.keys == shownKeys && (!scope.withTraffic || scope.period == period)
    }

    /// Autres sites ou autre période : l'analyse d'avant ne correspond plus au trafic montré.
    private func invalidateAnalysisIfStale() {
        guard analysis != nil, !analysisMatchesScope else { return }
        analysis = nil
        analysisScope = nil
    }

    /// État de l'app (appareils du Scanner), pour nommer les sources comme dans NetScope.
    weak var appState: AppState?

    /// Sources et appareils visés nommés comme dans NetScope (nom saisi, nom du Scanner ou de
    /// l'inventaire) plutôt que par le nom d'hôte vu par FortiView.
    private func named(_ overview: TrafficOverview) -> TrafficOverview {
        guard let state = appState else { return overview }
        var copy = overview
        copy.entries = overview.entries.map { entry in
            guard entry.view == .sources || entry.view == .threats, entry.ip != nil || entry.mac != nil,
                  let ref = deviceRef(ip: entry.ip, mac: entry.mac, name: entry.name, site: entry.site, state: state),
                  ref.name != ref.ip else { return entry }
            var renamed = entry
            if entry.view == .sources {
                if entry.hostname == nil, entry.name != ref.name { renamed.hostname = entry.name == entry.key ? nil : entry.name }
                renamed.name = ref.name
            } else {
                renamed.hostname = ref.name
            }
            return renamed
        }
        return copy
    }

    /// Rattache l'état de l'app (écran Trafic, Surveillance) et renomme les sources.
    func attach(_ state: AppState) {
        guard appState !== state else { return }
        appState = state
        recompute()
    }

    /// Libellé des sites lus (« Siège », « Siège, Entrepôt Laval »).
    var sitesLabel: String { overview.sites.joined(separator: ", ") }

    var isBusy: Bool { !reading.isEmpty }

    /// Erreurs des FortiGate montrées (messages distincts).
    var shownErrors: [String] {
        let ids = Set(shownControllerIDs)
        return Array(Set(errors.filter { ids.contains($0.key) }.map { key, message in
            let name = FortiGateStore.shared.controller(key)?.displayName
            return shownKeys.count > 1 ? (name.map { "\($0)\u{00A0}: " } ?? "") + message : message
        })).sorted()
    }

    /// « Relire » possible : lecture activée et au moins une FortiGate pour les sites montrés.
    var canRefresh: Bool {
        let fortigate = FortiGateStore.shared
        return fortigate.isEnabled && !shownControllerIDs.isEmpty && (fortigate.isReady || isDemo)
    }

    // MARK: Lecture

    /// Lit les FortiGate montrées qui n'ont encore rien donné pour cette période.
    func refreshIfNeeded() {
        if isDemo {
            loadDemoNow()
            return
        }
        let missing = shownControllerIDs.filter { cache[$0] == nil && errors[$0] == nil && !reading.contains($0) }
        guard !missing.isEmpty else { return }
        read(missing)
    }

    /// « Relire » : toutes les FortiGate montrées.
    func refresh() {
        read(shownControllerIDs)
    }

    private func read(_ ids: [UUID]) {
        let wanted = ids.filter { !reading.contains($0) }
        guard !wanted.isEmpty else { return }
        reading.formUnion(wanted)
        let chosenPeriod = period
        let options = TrafficReadOptions(period: chosenPeriod, sort: sort)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.reading.subtract(wanted)
                self.recompute()
                // Période changée pendant la lecture : la nouvelle lecture de ces FortiGate a été
                // écartée (elles étaient en cours) ; on les relit pour la période choisie.
                if chosenPeriod != self.period { self.refreshIfNeeded() }
            }
            if self.isDemo {
                try? await Task.sleep(nanoseconds: RegEnvironment.isSnapshot ? 0 : 450_000_000)
                guard chosenPeriod == self.period else { return }
                for id in wanted { self.applyDemo(id) }
                self.lastRefresh = Date()
                return
            }
            let fortigate = FortiGateStore.shared
            guard fortigate.isEnabled else { return }
            let picks = wanted.map { id in
                FortiControllerSelection.Pick(controllerID: id, site: fortigate.controller(id)?.displayName ?? "FortiGate", reason: .activeSite)
            }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            let jobs = targets.ready.map { TrafficJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1, options: options) }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
                await TrafficStore.performRead(job)
            }
            // Période changée pendant la lecture : ce résultat ne vaut plus.
            guard chosenPeriod == self.period else { return }
            for (id, reason) in targets.blocked { self.errors[id] = reason }
            for (job, result) in zip(jobs, results) {
                switch result {
                case .success(let report):
                    let site = TrafficSiteReport(controllerID: job.id, site: job.site, report: report)
                    self.cache[job.id] = site
                    self.errors[job.id] = nil
                    self.calls[job.id] = report.calls
                    if chosenPeriod == .realtime { self.monitorCache[job.id] = site }
                case .failure(let message, let records):
                    self.errors[job.id] = message
                    self.calls[job.id] = records
                case .cancelled:
                    break
                }
            }
            self.lastRefresh = Date()
        }
    }

    private func applyDemo(_ id: UUID) {
        let name = FortiGateStore.shared.controller(id)?.displayName ?? "FortiGate"
        if let report = TrafficDemo.report(controllerID: id, period: period) {
            let site = TrafficSiteReport(controllerID: id, site: name, report: report)
            cache[id] = site
            calls[id] = report.calls
            errors[id] = nil
        } else if let error = TrafficDemo.error(controllerID: id) {
            errors[id] = error
        } else {
            errors[id] = "FortiGate pas encore lue\u{00A0}: «\u{00A0}Tester\u{00A0}» dans Réglages › Switchs."
        }
    }

    /// Démonstration et captures : les sites montrés sont lus tout de suite (sans attente).
    func loadDemoNow() {
        guard isDemo else { return }
        for id in shownControllerIDs where cache[id] == nil { applyDemo(id) }
        lastRefresh = lastRefresh ?? Date()
        recompute()
    }

    struct TrafficJob: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
        var options: TrafficReadOptions
    }

    enum TrafficResult: Sendable {
        case success(TrafficReadReport)
        case failure(String, [FortiCallRecord])
        case cancelled
    }

    /// Lecture réseau, hors du fil principal (GET seulement).
    nonisolated static func performRead(_ job: TrafficJob) async -> TrafficResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readTrafficKeepingCalls(job.options))
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.trafficDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.trafficDescription, token: job.token), [])
        } catch {
            return .failure("Lecture du trafic impossible.", [])
        }
    }

    // MARK: Surveillance

    /// Temps réel du site actif pour les sondes de trafic.
    var monitorOverview: TrafficOverview? {
        let ids = controllerIDs(forKey: SiteModel.shared.activeKey)
        let reports = ids.compactMap { monitorCache[$0] }
        return reports.isEmpty ? nil : named(TrafficAnalysis.merge(reports, period: .realtime))
    }

    var monitorReadError: String? { monitorOverview == nil ? monitorError : nil }

    /// Sonde de la Surveillance : relit le temps réel du site actif si la lecture date de plus de
    /// `maxAge` secondes, et attend la fin de la lecture.
    func refreshForMonitoring(maxAge: TimeInterval) async {
        if let last = monitorRefresh, Date().timeIntervalSince(last) < maxAge, monitorOverview != nil { return }
        if let running = monitorTask {
            await running.value
            return
        }
        let ids = controllerIDs(forKey: SiteModel.shared.activeKey)
        guard !ids.isEmpty else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.monitorTask = nil }
            if self.isDemo {
                for id in ids {
                    if let report = TrafficDemo.report(controllerID: id, period: .realtime) {
                        self.monitorCache[id] = TrafficSiteReport(controllerID: id, site: FortiGateStore.shared.controller(id)?.displayName ?? "FortiGate", report: report)
                    }
                }
                self.monitorRefresh = Date()
                return
            }
            let fortigate = FortiGateStore.shared
            guard fortigate.isEnabled else { return }
            let picks = ids.map { FortiControllerSelection.Pick(controllerID: $0, site: fortigate.controller($0)?.displayName ?? "FortiGate", reason: .activeSite) }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            let options = TrafficReadOptions(period: .realtime, views: [.sources, .applications, .interfaces, .threats, .sessions])
            let jobs = targets.ready.map { TrafficJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1, options: options) }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { await TrafficStore.performRead($0) }
            var messages = Array(targets.blocked.values)
            for (job, result) in zip(jobs, results) {
                switch result {
                case .success(let report): self.monitorCache[job.id] = TrafficSiteReport(controllerID: job.id, site: job.site, report: report)
                case .failure(let message, _): messages.append(message)
                case .cancelled: break
                }
            }
            self.monitorError = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: " ")
            self.monitorRefresh = Date()
        }
        monitorTask = task
        await task.value
    }

    // MARK: Appareils

    /// Appareil du Scanner ou fiche d'inventaire d'une ligne (source, menace, session).
    func deviceRef(ip: IPv4Address?, mac: MACAddress?, name: String, site: String, state: AppState) -> NavDeviceRef? {
        guard ip != nil || mac != nil else { return nil }
        let key = siteKey(forLabel: site)
        if key == SiteModel.shared.activeKey,
           let device = state.devices.first(where: { (ip != nil && $0.ip == ip) || (mac != nil && $0.mac == mac) }) {
            return NavDeviceRef(device, siteKey: key)
        }
        let records = InvModel.shared.inventory(for: key).records.values
        if let record = records.first(where: { (mac != nil && $0.mac == mac) || (ip != nil && $0.ip == ip) }) {
            return NavDeviceRef(record, siteKey: key)
        }
        guard let ip else { return nil }
        return NavDeviceRef(ip: ip.description, mac: mac?.formatted(.upperColon), name: name, siteKey: key)
    }

    /// Nom connu de NetScope (nom saisi, nom du Scanner), sinon celui de FortiView.
    func displayName(ip: IPv4Address?, mac: MACAddress?, fallback: String, site: String, state: AppState) -> String {
        guard let ref = deviceRef(ip: ip, mac: mac, name: fallback, site: site, state: state), ref.name != ref.ip else { return fallback }
        return ref.name
    }

    /// Borne Wi-Fi d'un appareil (client FortiAP du site actif).
    func accessPointName(ip: IPv4Address?, mac: MACAddress?, state: AppState) -> String? {
        let fortiAP = FortiAPStore.shared
        guard let client = fortiAP.overview.clients.first(where: { (mac != nil && $0.mac == mac) || (ip != nil && $0.ip == ip) }) else { return nil }
        return fortiAP.ap(for: client)?.name ?? client.apName
    }

    // MARK: Analyse complète

    /// Lance l'analyse complète : trafic des sites montrés, WAN (si lu), ports des switchs du site
    /// actif, Wi-Fi, étendues DHCP et inconnus de l'inventaire. Rien n'est lu sur le réseau ici :
    /// l'analyse réunit ce que NetScope a déjà relevé.
    func runAnalysis(state: AppState) {
        analysis = makeAnalysis(state: state, traffic: overview, keys: shownKeys)
        analysisScope = (shownKeys, period, !overview.isEmpty)
    }

    private func makeAnalysis(state: AppState, traffic overview: TrafficOverview, keys shownKeys: [String]) -> NetworkAnalysisResult {
        var input = NetworkAnalysisInput(traffic: overview.isEmpty ? nil : overview, trafficThresholds: thresholds, now: Date())
        input.wan = wanStatuses(ids: shownKeys.flatMap(controllerIDs(forKey:)), sites: overview.sites)
        input.wanThresholds = WANStore.shared.thresholds
        let active = SiteModel.shared.activeKey
        if shownKeys.contains(active) {
            let snapshots = SwitchStore.shared.orderedSnapshots
            if !snapshots.isEmpty {
                input.ports = NetworkAnalysis.portIssues(snapshots, site: SiteModel.shared.activeName)
            }
            let wifi = FortiAPStore.shared
            if !wifi.overview.aps.isEmpty { input.wifi = wifi.diagnosis }
            let dhcp = DHCPScopeStore.shared
            let scopes = dhcp.overview(devices: state.devices)
            if !scopes.scopes.isEmpty {
                input.dhcp = scopes
                input.dhcpThresholds = dhcp.thresholds
            }
        }
        let now = Date()
        var unknown: [NetworkUnknownDevice] = []
        var hasInventory = false
        for key in shownKeys {
            let store = InvModel.shared.inventory(for: key)
            guard !store.records.isEmpty else { continue }
            hasInventory = true
            let name = SiteModel.shared.name(forKey: key)
            for record in store.records.values where record.isUnidentified && record.annotations.customType == nil
                && now.timeIntervalSince(record.lastSeen) < 7 * 86_400 {
                unknown.append(NetworkUnknownDevice(site: name, ip: record.ip.description, mac: record.mac?.formatted(.upperColon),
                                                    name: record.displayName, firstSeen: record.firstSeen))
            }
        }
        if hasInventory { input.unknownDevices = unknown }
        return NetworkAnalysis.analyze(input)
    }

    /// Trafic et analyse de la section « Trafic et analyse » des rapports : ceux de l'écran Trafic ;
    /// en démonstration, sans visite de l'écran, ceux du site actif (rien n'est modifié ici).
    func reportContent(state: AppState) -> (traffic: TrafficOverview?, analysis: NetworkAnalysisResult?) {
        // Noms NetScope des appareils (sans republier : l'écran les recalcule à son ouverture).
        if appState == nil { appState = state }
        // L'analyse ne va au rapport que si elle porte sur le trafic montré (mêmes sites, même période).
        let shownAnalysis = analysisMatchesScope ? analysis : nil
        if !overview.isEmpty || !isDemo { return (overview.isEmpty ? nil : overview, shownAnalysis) }
        let key = SiteModel.shared.activeKey
        let reports = controllerIDs(forKey: key).compactMap { id -> TrafficSiteReport? in
            TrafficDemo.report(controllerID: id, period: period).map {
                TrafficSiteReport(controllerID: id, site: FortiGateStore.shared.controller(id)?.displayName ?? "FortiGate", report: $0)
            }
        }
        let demo = named(TrafficAnalysis.merge(reports, period: period))
        return (demo.isEmpty ? nil : demo, shownAnalysis ?? makeAnalysis(state: state, traffic: demo, keys: [key]))
    }

    /// État du WAN et des tunnels pour l'analyse : liens et tunnels IPsec lus par la lecture du WAN
    /// (WANStore) pour les FortiGate données ; nil si aucune n'a encore été lue (l'analyse le dit
    /// dans sa couverture). Les liens désactivés et les tunnels en attente ne sont pas des pannes.
    /// En démonstration, WANStore tient les relevés de WANDemo : l'analyse voit le même WAN que
    /// l'onglet « WAN » (tunnel VPN-QUEBEC tombé, wan2 dégradé).
    func wanStatuses(ids: [UUID], sites: [String]) -> [NetworkWANStatus]? {
        let wan = WANStore.shared
        var seen = Set<UUID>()
        let read = ids.filter { wan.reports[$0] != nil && seen.insert($0).inserted }
        guard !read.isEmpty else { return nil }
        let view = wan.overview(read)
        let links = view.links.filter { $0.state != .disabled }.map { link in
            NetworkWANStatus(site: link.site, name: link.interface.displayName, isUp: link.state != .down,
                             latencyMs: link.latencyMs, lossPercent: link.lossPercent, jitterMs: link.jitterMs)
        }
        let tunnels = view.tunnels.filter { $0.state != .idle }.map { tunnel in
            NetworkWANStatus(site: tunnel.site, name: tunnel.tunnel.name, isTunnel: true, isUp: tunnel.state != .down)
        }
        return links + tunnels
    }

    // MARK: Rapport

    func addToReport() {
        RapportModel.shared.config.sections.insert(.trafic)
        toast = "Section «\u{00A0}Trafic et analyse\u{00A0}» ajoutée au rapport."
    }

    var isInReport: Bool { RapportModel.shared.config.sections.contains(.trafic) }

    // MARK: Export

    /// Lignes d'une vue en CSV (séparateur « ; », champs protégés comme l'inventaire).
    func csv(_ view: TrafficView) -> String {
        let multi = overview.isMultiSite
        var lines: [String]
        if view == .sessions {
            lines = [(multi ? "Site;" : "") + "Source;Port source;Destination;Port;Protocole;Application;Interface entrée;Interface sortie;Politique;Envoyé (octets);Reçu (octets);Durée (s)"]
            for s in overview.sessions {
                var fields: [String] = multi ? [s.site] : []
                fields.append(s.source?.description ?? "")
                fields.append(s.sourcePort.map(String.init) ?? "")
                fields.append(s.destination?.description ?? "")
                fields.append(s.destinationPort.map(String.init) ?? "")
                fields.append(s.proto)
                fields.append(s.application ?? "")
                fields.append(s.sourceInterface ?? "")
                fields.append(s.destinationInterface ?? "")
                fields.append(s.policyID.map(String.init) ?? "")
                fields.append(String(s.sentBytes))
                fields.append(String(s.receivedBytes))
                fields.append(s.duration.map(String.init) ?? "")
                lines.append(fields.map(AnaCSV.quote).joined(separator: ";"))
            }
        } else {
            lines = [(multi ? "Site;" : "") + "Nom;Adresse;Débit (b/s);Envoyé (octets);Reçu (octets);Sessions;Catégorie;Pays;Risque;Niveau;Événements;Bloqués"]
            for e in TrafficAnalysis.sorted(overview.entries(view), by: sort) {
                var fields: [String] = multi ? [e.site] : []
                fields.append(e.name)
                fields.append(e.ip?.description ?? "")
                fields.append(String(Int(e.bandwidth)))
                fields.append(String(e.sentBytes))
                fields.append(String(e.receivedBytes))
                fields.append(String(e.sessions))
                fields.append(e.category ?? "")
                fields.append(e.country.map(TrafficFormat.country) ?? "")
                fields.append(e.risk.map(String.init) ?? "")
                fields.append(e.threatLevel?.label ?? "")
                fields.append(String(e.incidents))
                fields.append(String(e.blocked))
                lines.append(fields.map(AnaCSV.quote).joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Diagnostic

    /// Réponses brutes FortiView d'une FortiGate (diagnostic de FortiGateStore), sans le jeton.
    func diagnosticCalls(_ id: UUID) -> [FortiCallRecord] { calls[id] ?? [] }
}
