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
    private static let tabKey = "NetScope.fortiap.onglet"

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
    /// Note 48 : dernière lecture réussie de chaque FortiGate, gardée en mémoire même après un
    /// changement de site (vue d'un autre site par le menu « Site ▾ » de l'écran Wi-Fi).
    @Published private(set) var cache: [UUID: FortiWifiSiteReport] = [:]
    /// Sites affichés par l'écran Wi-Fi (nil : le site actif seulement, lecture habituelle).
    @Published private(set) var scopeKeys: [String]?
    /// Ce que montre l'écran Wi-Fi : la lecture du site actif, ou celle des sites choisis.
    @Published private(set) var shownOverview = FortiWifiOverview()
    @Published private(set) var shownDiagnosis = FortiWifiAnalysis.diagnose(FortiWifiOverview())
    /// FortiGate lues à la demande pour la vue d'un autre site.
    @Published private(set) var viewReading: Set<UUID> = []
    @Published var focusBand: WifiBand?
    /// Note 46 : fiche du client ouverte dans Wi-Fi › FortiAP (identifiant `FortiWifiClient.id`).
    @Published private(set) var openClientID: FortiWifiClient.ID?
    /// Note 46 : section Clients regroupée par SSID, et SSID dépliés (`FortiWifiSSIDGroup.id`).
    @Published var clientsBySSID = false
    @Published var expandedSSIDs: Set<String> = []
    /// Borne et SSID montrés en dernier (endroit retenu par Retour, note 45).
    var viewedAP: FortiManagedAP.ID?
    /// Demande d'ouvrir la partie FortiAP de l'écran Wi-Fi (fiche d'un client, SSID).
    @Published var openFortiAPPart = false
    /// Note 80 : onglet affiché (Bornes, Clients, SSID, Canaux, Voisins, Conseils), retenu d'une
    /// visite et d'un lancement à l'autre (captures : NETSCOPE_WIFI_ONGLET).
    @Published var tab: FortiAPTab = .bornes {
        didSet {
            guard tab != oldValue, !isDemo else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        }
    }
    var viewedSSID: String?
    /// Note 46 : historique du signal des clients, un par site (fichier sites/<site>/wifi-signal.json).
    @Published private(set) var signal = FortiWifiSignalBook()
    private var signalLoaded = Set<String>()
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
        if !demo, let raw = UserDefaults.standard.string(forKey: Self.tabKey), let saved = FortiAPTab(rawValue: raw) {
            tab = saved
        }
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
            // Les bornes du Siège et de Laval sont déjà lues (vue d'un autre site, note 48).
            cache[FortiGateSitesDemo.siegeID] = FortiWifiSiteReport(controllerID: FortiGateSitesDemo.siegeID, site: "Siège", report: FortiAPDemo.siege())
            cache[FortiGateSitesDemo.lavalID] = FortiWifiSiteReport(controllerID: FortiGateSitesDemo.lavalID, site: "Entrepôt Laval", report: FortiAPDemo.laval())
            for site in initial { cache[site.controllerID] = site }
            // Note 46 : historique du signal de démonstration (rien n'est lu ni écrit sur le disque).
            signal = FortiAPDemo.signalBook(now: Date())
            recompute()
            FortiAPDemo.applySnapshotFocus(self)
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
        for site in sites { cache[site.controllerID] = site }
        recomputeShown()
        dropMissingClient()
    }

    /// Après une lecture : la fiche d'un client qui n'est plus lu se ferme (elle ne se rouvrirait
    /// pas d'elle-même à son retour).
    private func dropMissingClient() {
        if let id = openClientID, client(id: id) == nil { openClientID = nil }
    }

    /// Client Wi-Fi d'un appareil du Scanner : par MAC, sinon par adresse IP quand elle est unique
    /// (même règle que `FortiWifiMerge.match`). Les clients du site actif seulement (`overview`).
    func client(for device: Device) -> FortiWifiClient? {
        if let mac = device.mac { return byMAC[mac] }
        if let list = byIP[device.ip], list.count == 1 { return list[0] }
        return nil
    }

    // MARK: Clients (note 46)

    /// Libellés de site des clients du site actif, dans la vue de l'écran Wi-Fi (« Siège », ou le nom
    /// de sa FortiGate pour la lecture habituelle) : seuls ces clients sont rattachés au Scanner.
    var activeSiteLabels: Set<String> {
        var labels = Set(overview.sites)
        for report in reports(forKey: SiteModel.shared.activeKey) { labels.insert(report.site) }
        return labels
    }

    /// Appareil du Scanner de chaque client affiché (site actif seulement, par MAC).
    func deviceLinks(_ devices: [Device]) -> [FortiWifiClient.ID: Device.ID] {
        FortiWifiClientLink.devices(for: shownOverview.clients, devices: devices, activeSites: activeSiteLabels)
    }

    /// Client d'un identifiant « site|mac » : dans la vue de l'écran Wi-Fi d'abord, sinon dans la
    /// lecture du site actif. Le site d'un identifiant peut être le nom de la FortiGate (lecture
    /// habituelle) ou celui du site (vue d'un site) : à défaut d'égalité, la même MAC dans le site
    /// qui porte ce libellé, puis la même MAC n'importe où dans la vue.
    func client(id: FortiWifiClient.ID) -> FortiWifiClient? {
        if let c = shownOverview.clients.first(where: { $0.id == id }) ?? overview.clients.first(where: { $0.id == id }) { return c }
        guard let bar = id.lastIndex(of: "|"), let mac = MACAddress(String(id[id.index(after: bar)...])) else { return nil }
        let site = String(id[..<bar])
        let all = shownOverview.clients + overview.clients
        return all.first { $0.mac == mac && $0.site == site } ?? shownOverview.clients.first { $0.mac == mac } ?? overview.clients.first { $0.mac == mac }
    }

    /// Fiche du client ouverte (nil : aucune, ou le client n'est plus dans la lecture).
    var openClient: FortiWifiClient? { openClientID.flatMap { client(id: $0) } }

    /// Ouvre la fiche d'un client (appelé par la navigation : l'historique la retient aussitôt).
    func showClient(_ id: FortiWifiClient.ID) {
        let resolved = client(id: id)?.id ?? id
        openClientID = resolved
        tab = .clients
        if let c = client(id: resolved), let ap = ap(for: c) { viewedAP = shownAPID(for: ap.id) ?? ap.id }
    }

    func closeClient() { openClientID = nil }

    /// Fiche d'un client affiché, dans SON site (ajouté aux sites montrés s'il n'y est pas).
    func clientDestination(_ client: FortiWifiClient) -> NavDestination {
        NavDestination(.wifi, focus: .wifiClient(client.id), sites: .include(siteKey(for: client)))
    }

    /// Montre un SSID déplié dans la section Clients (Retour vers le SSID d'origine).
    func showSSID(_ id: String) {
        openClientID = nil
        clientsBySSID = true
        expandedSSIDs.insert(id)
        viewedSSID = id
        tab = .clients
    }

    /// Ce que montre la partie FortiAP, pour l'historique Retour / Avancer.
    var navFocus: NavFocus? {
        if let id = openClientID, openClient != nil { return .wifiClient(id) }
        if let ssid = viewedSSID { return .wifiSSID(ssid) }
        return viewedAP.map(NavFocus.accessPoint)
    }

    /// Diagnostic brut : champs de la fiche du client absents de la dernière lecture de cette FortiGate.
    func clientFieldsNote(controller id: UUID) -> String? {
        let clients = sites.first { $0.controllerID == id }?.report.clients ?? cache[id]?.report.clients ?? []
        return FortiWifiClientFields.diagnosticLine(clients)
    }

    // MARK: Historique du signal (note 46)

    /// Site (clé `SiteFiles.key`) d'une FortiGate : le site actif s'il la contient, sinon le premier
    /// site qui l'a ; à défaut, le site actif.
    func siteKey(forController id: UUID) -> String {
        let model = SiteModel.shared
        if model.site(forKey: model.activeKey)?.fortiGateIDs.contains(id) == true { return model.activeKey }
        if let site = model.sites.first(where: { $0.fortiGateIDs.contains(id) }) { return SiteFiles.key(for: site.id) }
        return model.activeKey
    }

    /// Site d'un client affiché : celui de la FortiGate dont le libellé est le sien.
    func siteKey(for client: FortiWifiClient) -> String { siteKey(forLabel: client.site) }

    /// Site d'un libellé de lecture (nom de la FortiGate, nom du site, ou « Site · FGT-2 ») : par la
    /// FortiGate qui porte ce libellé, sinon le site actif.
    func siteKey(forLabel label: String) -> String {
        if let report = sites.first(where: { $0.site == label }) { return siteKey(forController: report.controllerID) }
        for key in scopeKeys ?? [] where reports(forKey: key).contains(where: { $0.site == label }) { return key }
        for (id, report) in cache where report.site == label { return siteKey(forController: id) }
        if let site = SiteModel.shared.sites.first(where: { $0.displayName == label }) { return SiteFiles.key(for: site.id) }
        return SiteModel.shared.activeKey
    }

    /// Historique du signal d'un site (lu sur le disque à la première demande).
    func signalHistory(siteKey: String) -> FortiWifiSignalHistory {
        loadSignal(siteKey)
        return signal.history(site: siteKey)
    }

    func signalHistory(for client: FortiWifiClient) -> FortiWifiSignalHistory { signalHistory(siteKey: siteKey(for: client)) }

    private func loadSignal(_ key: String) {
        guard !isDemo, !signalLoaded.contains(key) else { return }
        signalLoaded.insert(key)
        guard signal.sites[key] == nil, let files = SiteModel.shared.files,
              let data = try? Data(contentsOf: FortiWifiSignalHistory.url(in: files, siteKey: key)) else { return }
        guard let history = FortiWifiSignalHistory.decode(data) else {
            // Fichier illisible ou d'une version future : on ne l'écrase pas (historique en mémoire seulement).
            signalReadOnly.insert(key)
            return
        }
        signal.sites[key] = history
    }

    /// Sites dont le fichier wifi-signal.json n'a pas pu être relu : jamais réécrit.
    private var signalReadOnly = Set<String>()
    /// Dernière écriture lancée : chaque écriture attend la précédente (jamais dans le désordre).
    private var signalWrite: Task<Void, Never>?

    /// Chaque lecture réussie des bornes ajoute un relevé par client dans l'historique de SON site
    /// (jamais de mélange entre sites), à la date de la lecture de SA FortiGate, puis l'écrit sur
    /// le disque (hors démonstration). Seules les FortiGate lues sont notées : une FortiGate en
    /// échec ne fait pas passer ses clients pour déconnectés.
    private func recordSignal(_ reports: [FortiWifiSiteReport]) {
        guard !reports.isEmpty else { return }
        var changed = Set<String>()
        for report in reports {
            let key = siteKey(forController: report.controllerID)
            loadSignal(key)
            // Note 99 : bornes, IP et noms des clients Wi-Fi dans l'historique des MAC du site.
            MACHistoryStore.shared.record(wifiClients: report.report.clients, siteKey: key, at: report.report.readAt)
            if signal.record(site: key, controller: report.controllerID, clients: report.report.clients, at: report.report.readAt) {
                changed.insert(key)
            }
        }
        guard !isDemo, !RegEnvironment.isSnapshot, let files = SiteModel.shared.files else { return }
        for key in changed.sorted() where !signalReadOnly.contains(key) {
            guard let data = signal.sites[key]?.encoded() else { continue }
            let url = FortiWifiSignalHistory.url(in: files, siteKey: key)
            let previous = signalWrite
            signalWrite = Task.detached(priority: .utility) {
                await previous?.value
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Borne d'un client : dans la vue de l'écran Wi-Fi (autre site compris), sinon du site actif.
    func ap(for client: FortiWifiClient) -> FortiManagedAP? { shownOverview.ap(for: client) ?? overview.ap(for: client) }

    /// Identifiant d'une borne dans la vue de l'écran Wi-Fi. Une borne du site actif s'appelle
    /// « FortiGate|SN » dans `overview` mais « Site|SN » dans `shownOverview` (renommée d'après le
    /// site) : on la retrouve par son numéro de série (à défaut son nom), jamais par l'identifiant seul.
    func shownAPID(for id: FortiManagedAP.ID) -> FortiManagedAP.ID? {
        let shown = shownOverview.aps
        if shown.contains(where: { $0.id == id }) { return id }
        let key: String
        if let ap = overview.aps.first(where: { $0.id == id }) {
            key = ap.serial.isEmpty ? ap.name : ap.serial
        } else if let bar = id.lastIndex(of: "|") {
            key = String(id[id.index(after: bar)...])
        } else {
            key = id
        }
        guard !key.isEmpty else { return nil }
        return shown.first { ($0.serial.isEmpty ? $0.name : $0.serial) == key }?.id
    }

    func isWeak(_ client: FortiWifiClient) -> Bool { FortiWifiAnalysis.isWeak(client, thresholds: thresholds) }

    // MARK: Lecture

    /// Relecture des FortiGate choisies pour les switchs (appelée par FortiGateStore).
    func refresh(selection chosen: FortiControllerSelection, state: AppState) {
        task?.cancel()
        task = Task { [weak self] in await self?.read(chosen) }
    }

    /// Note 28 : changement de site, seules les bornes des FortiGate du nouveau site restent (rien
    /// n'est relu sur le réseau).
    func keepOnly(_ controllerIDs: Set<UUID>, selection chosen: FortiControllerSelection) {
        task?.cancel()
        task = nil
        generation += 1
        selection = chosen
        if isDemo {
            sites = FortiAPDemo.initialSites().filter { controllerIDs.contains($0.controllerID) }
        } else {
            sites = sites.filter { controllerIDs.contains($0.controllerID) }
        }
        errors = errors.filter { controllerIDs.contains($0.key) }
        busy = false
        focusAP = nil
        recompute()
    }

    /// « Relire » de l'écran Wi-Fi : plages cochées du Scanner, sinon l'adresse du Mac.
    func refreshNow(state: AppState) {
        refresh(selection: FortiGateStore.shared.previewSelection(state: state), state: state)
    }

    /// Sondes de la Surveillance : relit si la dernière lecture date de plus de `maxAge` secondes,
    /// et attend la fin de la lecture.
    func refreshForMonitoring(maxAge: TimeInterval, state: AppState?) async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
        // Note 29 : une lecture de la FortiGate (bouton, fin de scan, relecture automatique) est en
        // cours : jamais deux lectures à la fois vers elle. Elle relit aussi les bornes juste après :
        // on l'attend (60 s au plus), puis on ne relit que si rien de récent n'en est sorti.
        var waited = 0
        while FortiGateStore.shared.isBusy, waited < 120, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        if waited > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
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
            recordSignal(sites)
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
        recordSignal(fresh)
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

    // MARK: Sites choisis dans l'écran Wi-Fi (note 48)

    /// Sites affichés par l'écran Wi-Fi (menu « Site ▾ ») ; le site actif seul garde la lecture habituelle.
    func setScope(_ keys: [String]) {
        let next: [String]? = keys == [SiteModel.shared.activeKey] || keys.isEmpty ? nil : keys
        guard next != scopeKeys else { return }
        scopeKeys = next
        recomputeShown()
    }

    /// Lectures des FortiGate d'un site, renommées d'après le site (la plus récente de chacune).
    func reports(for site: Site) -> [FortiWifiSiteReport] {
        var merged = cache
        for report in sites { merged[report.controllerID] = report }
        return SiteWifiBrowse.reports(site: site, fortiGateNames: FortiGateStore.shared.controllerNames, cache: merged)
    }

    /// Lectures d'un site affiché (le site actif sans site enregistré : sa lecture habituelle).
    func reports(forKey key: String) -> [FortiWifiSiteReport] {
        if let site = SiteModel.shared.site(forKey: key) { return reports(for: site) }
        return key == SiteModel.shared.activeKey ? sites : []
    }

    private func recomputeShown() {
        guard let keys = scopeKeys else {
            shownOverview = overview
            shownDiagnosis = diagnosis
            return
        }
        shownOverview = SiteWifiBrowse.overview(perSite: keys.map { reports(forKey: $0) })
        shownDiagnosis = FortiWifiAnalysis.diagnose(shownOverview, thresholds: thresholds)
    }

    /// « Lire les bornes » d'un site affiché (à la demande, lecture seule) : la lecture va dans la
    /// mémoire des sites vus, sans toucher au Wi-Fi du site actif ni aux appareils du Scanner.
    func readForView(_ controllerIDs: [UUID]) {
        let wanted = controllerIDs.filter { !viewReading.contains($0) }
        guard !wanted.isEmpty else { return }
        viewReading.formUnion(wanted)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.viewReading.subtract(wanted)
                self.recomputeShown()
                self.dropMissingClient()
            }
            if self.isDemo {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return
            }
            let fortigate = FortiGateStore.shared
            let picks = wanted.map { id in
                FortiControllerSelection.Pick(controllerID: id, site: fortigate.controller(id)?.displayName ?? "FortiGate",
                                              reason: .activeSite, coveredRanges: [], scannedRanges: [])
            }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            let jobs = targets.ready.map { WifiJob(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1) }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
                await FortiAPStore.performRead(job)
            }
            for (id, reason) in targets.blocked { self.errors[id] = reason }
            var fresh: [FortiWifiSiteReport] = []
            defer { self.recordSignal(fresh) }
            for (job, result) in zip(jobs, results) {
                switch result {
                case .success(let report):
                    let site = FortiWifiSiteReport(controllerID: job.id, site: job.site, report: report)
                    self.cache[job.id] = site
                    self.errors[job.id] = nil
                    fresh.append(site)
                case .failure(let message, _):
                    self.errors[job.id] = message
                case .cancelled:
                    break
                }
            }
        }
    }
}
