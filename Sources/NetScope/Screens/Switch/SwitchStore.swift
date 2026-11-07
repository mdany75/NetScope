import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

/// État du module Switchs et ports : switchs à interroger, relevés SNMP, sélection.
///
/// Les switchs sont découverts automatiquement à la fin de chaque scan (`autoDiscover`) ou
/// ajoutés à la main. La communauté saisie ici est préremplie depuis le Trousseau (Réglages ›
/// Identifiants) ; celle qui a répondu pour chaque switch découvert est gardée au Trousseau,
/// jamais dans les préférences. Le Trousseau n'est lu qu'au premier besoin, hors du fil principal.
@MainActor
final class SwitchStore: ObservableObject {
    static let shared = SwitchStore()

    /// Adresses des switchs à interroger (enregistrées dans les préférences, hors démonstration).
    @Published private(set) var hosts: [String] {
        didSet { if !isDemo { UserDefaults.standard.set(hosts, forKey: Self.hostsKey) } }
    }
    @Published var community = ""
    @Published private(set) var snapshots: [String: SNMPSwitchSnapshot] = [:] {
        // Chaque nouveau relevé (SNMP ou FortiGate) alimente le suivi des erreurs récentes ; un
        // relevé déjà vu (même heure) est ignoré par le suivi.
        didSet { for snapshot in snapshots.values { errorTracker.record(snapshot) } }
    }
    /// Compteurs d'erreurs des ports des 30 dernières minutes, par switch (en mémoire seulement).
    private var errorTracker = PortErrorTracker()

    /// Erreurs récentes des ports d'un switch (seules les erreurs qui augmentent sont signalées).
    func recentErrors(_ host: String) -> SwitchRecentErrors { errorTracker.recent(host) }

    /// Note 74 : site dont l'historique du trafic reçoit les relevés d'un switch : celui du relevé
    /// SNMP, sinon celui de la FortiGate du FortiSwitch, sinon le site actif.
    func historySiteKey(for host: String) -> String {
        if let key = readingSites[host] { return key }
        if let controller = controllerOwners[host],
           let site = SiteModel.shared.sites.first(where: { $0.fortiGateIDs.contains(controller) }) {
            return SiteFiles.key(for: site.id)
        }
        // Note 77 : switch lu par un contrôleur UniFi, Omada ou Meraki : le site de ce contrôleur.
        if let controller = vendorOwners[host],
           let site = SiteModel.shared.sites.first(where: { $0.controllers.contains { $0.id == controller } }) {
            return SiteFiles.key(for: site.id)
        }
        return SiteModel.shared.activeKey
    }
    /// FortiSwitch lus par la FortiGate (note 24) : adresses FortiLink, jamais interrogées en SNMP.
    @Published private(set) var controllerHosts: [String] = []
    /// Noms connus de la FortiGate (inventaire, baux DHCP), pour les appareils absents du scan.
    private(set) var controllerNames: [MACAddress: String] = [:]
    /// FortiGate de chaque FortiSwitch affiché (adresse du relevé → contrôleur), note 28.
    private var controllerOwners: [String: UUID] = [:]
    /// Note 77 : FortiSwitch reçus des FortiGate, avant la fusion avec les switchs des contrôleurs
    /// UniFi, Omada et Meraki (`vendorSnapshots`) ; les deux listes forment `controllerHosts`.
    private var fortiSnapshots: [SNMPSwitchSnapshot] = []
    private(set) var vendorSnapshots: [SNMPSwitchSnapshot] = []
    /// Contrôleur (UniFi, Omada, Meraki) de chaque switch qu'il a fourni (adresse → identifiant).
    private var vendorOwners: [String: UUID] = [:]
    /// Réseau sur lequel les FortiSwitch ont été lus : sur un autre réseau, ils ne servent plus à
    /// situer les appareils (une table MAC périmée donnerait un faux port).
    private var controllerNetwork: NetworkContext?
    /// Heure de la lecture des FortiSwitch : au-delà de 15 min, la fin de scan les relit d'abord.
    private var controllerReadAt: Date?
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isPolling = false
    /// Découverte automatique en cours (fin de scan) : l'interrogation manuelle attend.
    @Published private(set) var isDiscovering = false
    @Published private(set) var pollingHost: String?
    @Published private(set) var lastPoll: Date?
    @Published var selectedHost: String?
    @Published var selectedPort: Int?
    @Published var findQuery = ""
    @Published private(set) var findResult: SwitchFindResult?
    @Published var tableFilter = ""
    @Published var hideUplinks = true
    @Published var copiedPort: Int?
    /// Switchs ajoutés par la découverte automatique (les autres l'ont été à la main).
    @Published private(set) var autoHosts: Set<String> {
        didSet { if !isDemo { UserDefaults.standard.set(Array(autoHosts).sorted(), forKey: Self.autoHostsKey) } }
    }
    /// Switchs retirés par l'utilisateur : la découverte automatique ne les interroge plus.
    @Published private(set) var ignoredHosts: Set<String> {
        didSet { if !isDemo { UserDefaults.standard.set(Array(ignoredHosts).sorted(), forKey: Self.ignoredKey) } }
    }
    /// Bilan de la dernière découverte automatique, rattaché aux plages et au réseau de son scan
    /// (nil pendant un scan, après un scan sans découverte et après « Effacer »).
    var autoResult: SwitchAutoResult? { ledger.result }
    @Published private var ledger = SwitchAutoLedger()
    /// Réseau sur lequel l'emplacement de chaque appareil a été relevé (note 18) : un emplacement
    /// d'un autre réseau, ou non confirmé par la dernière découverte, n'est pas présenté comme actuel.
    @Published private(set) var locations = LocationLedger()
    /// Nombre de communautés retenues par switch (pour Réglages › Switchs).
    @Published private(set) var rememberedCommunities = 0
    /// Communauté qui a répondu, par switch (adresse IP → communauté), lue au Trousseau.
    private var hostCommunities: [String: String] = [:] {
        didSet { rememberedCommunities = hostCommunities.count }
    }

    /// Note 48 : site actif au moment de chaque relevé SNMP (adresse → clé du site). Un relevé
    /// n'est montré que pour ce site : la même adresse chez un autre client est un autre switch.
    private(set) var readingSites: [String: String] = [:]
    /// Note 60 : dernière lecture de la fiche matériel (ENTITY-MIB) par switch.
    private var hardwareReadAt: [String: Date] = [:]
    private static let hardwareRefresh: TimeInterval = 3600
    /// Switch à montrer dans la vue d'un autre site (double-clic, « Ouvrir dans », Retour).
    @Published var browseFocus: SwitchBrowseFocus?
    /// Switch choisi dans la vue d'un autre site ou de plusieurs (« site|adresse »).
    @Published var browseSelection: String?

    /// Noms d'hôte des postes fictifs de la démonstration (absents d'AppState).
    private(set) var demoNames: [MACAddress: String] = [:]

    let isDemo: Bool
    private static let hostsKey = "NetScope.switchs.hotes"
    private static let autoHostsKey = "NetScope.switchs.decouverts"
    private static let ignoredKey = "NetScope.switchs.ignores"
    private static let controllerSwitchesKey = "NetScope.fortigate.switchs"
    /// FortiSwitch déjà lus par une FortiGate (nom du switch → nom du contrôleur), gardés entre deux
    /// lancements : la source affichée de l'emplacement reste « FortiGate » avant la première lecture.
    private var knownControllerSwitches: [String: String] = [:]
    /// Écritures au Trousseau, dans l'ordre, hors du fil principal.
    private static let vaultQueue = DispatchQueue(label: "netscope.switchs.trousseau")
    private var pollTask: Task<Void, Never>?
    private var vaultTask: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        if demo {
            hosts = []
            autoHosts = []
            ignoredHosts = []
            loadDemo()
        } else {
            hosts = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
            autoHosts = Set(UserDefaults.standard.stringArray(forKey: Self.autoHostsKey) ?? [])
            ignoredHosts = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
            knownControllerSwitches = UserDefaults.standard.dictionary(forKey: Self.controllerSwitchesKey) as? [String: String] ?? [:]
        }
    }

    /// Note 86 : switchs reçus d'un autre Mac (préférences déjà écrites), relus sans redémarrer.
    func reloadFromDisk() {
        guard !isDemo else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: Self.hostsKey) ?? []
        if saved != hosts { hosts = saved }
        let auto = Set(defaults.stringArray(forKey: Self.autoHostsKey) ?? [])
        if auto != autoHosts { autoHosts = auto }
        let ignored = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
        if ignored != ignoredHosts { ignoredHosts = ignored }
    }

    /// Lit au Trousseau (une seule fois, hors du fil principal) la communauté des Identifiants et
    /// celles retenues par switch. Une demande d'autorisation de macOS ne gèle donc pas l'app.
    func loadVault() async {
        guard !isDemo else { return }
        // Note 59 : utilisateurs SNMP v3 (tous les sites et par site), lus au même moment.
        await SNMPAccessVault.shared.load()
        if vaultTask == nil {
            vaultTask = Task { [weak self] in
                let (map, saved) = await Task.detached(priority: .userInitiated) {
                    (RegSNMPDiscoveryVault.hostCommunities(), RegSNMPCredentials.load()?.community ?? "")
                }.value
                guard let self else { return }
                // Ce qui a été appris pendant la lecture l'emporte sur le Trousseau.
                self.hostCommunities = map.merging(self.hostCommunities) { _, new in new }
                if self.community.isEmpty { self.community = saved }
            }
        }
        await vaultTask?.value
    }

    private func saveHostCommunities() {
        let copy = hostCommunities
        Self.vaultQueue.async { RegSNMPDiscoveryVault.saveHostCommunities(copy) }
    }

    /// Oublie les communautés retenues par switch (mémoire et Trousseau).
    func forgetCommunities() {
        hostCommunities = [:]
        guard !isDemo else { return }
        Self.vaultQueue.async { RegSNMPDiscoveryVault.forgetHostCommunities() }
    }

    /// Une communauté vient d'être enregistrée dans les Identifiants : elle sert aux relevés (et à la
    /// relecture automatique) si aucune n'est encore en mémoire, sans attendre un redémarrage.
    func credentialsSaved(community saved: String) {
        guard !isDemo, !saved.isEmpty, community.isEmpty else { return }
        community = saved
    }

    /// La communauté des Identifiants vient d'être effacée : elle ne sert plus pour les relevés.
    func credentialsErased() {
        community = ""
        forgetCommunities()
    }

    /// Démonstration : un relevé fabriqué 10 min plus tôt sert de base, pour que SW-CORE-01 et
    /// FSW-QUAI montrent des erreurs qui augmentent et que SW-ETG2-01 garde un vieux total sans
    /// hausse (aucun réseau).
    private func seedDemoErrorHistory() {
        var tracker = PortErrorTracker()
        let rising: [String: UInt64] = ["SW-CORE-01": 37, "FSW-QUAI": 12]
        for snapshot in snapshots.values {
            var counters: [Int: UInt64] = [:]
            for port in snapshot.physicalPorts where port.isUp {
                guard var value = port.inErrors else { continue }
                if let delta = rising[snapshot.displayName], value >= 100 { value -= min(delta, value) }
                counters[port.index] = value
            }
            tracker.record(host: snapshot.host.description, at: snapshot.polledAt.addingTimeInterval(-600), counters: counters)
            tracker.record(snapshot)
        }
        errorTracker = tracker
    }

    private func loadDemo() {
        let demo = SwitchDemo.make()
        hosts = demo.snapshots.map(\.host.description)
        snapshots = Dictionary(uniqueKeysWithValues: demo.snapshots.map { ($0.host.description, $0) })
        demoNames = demo.names
        community = "lecture-demo"
        autoHosts = Set(hosts)
        lastPoll = demo.snapshots.first?.polledAt
        // FortiSwitch gérés par les FortiGate de démonstration choisies pour ces plages (notes 24 et 25).
        let fortiDemo = FortiGateSitesDemo.selectedSites()
        setControllerSnapshots(FortiMulti.snapshots(fortiDemo))
        controllerNames = FortiMulti.names(fortiDemo)
        controllerOwners = SiteSwitchFilter.controllerOwners(fortiDemo)
        // Note 28 : un switch SNMP hors des plages et sans site, masqué dans « Switchs et ports ».
        let extra = SitesDemo.unassignedSwitch(now: demo.snapshots.first?.polledAt ?? Date())
        hosts.append(extra.host.description)
        snapshots[extra.host.description] = extra
        // Relevés SNMP de la démonstration : ceux du Siège.
        for host in hosts { readingSites[host] = SitesDemo.siegeKey }
        selectedHost = Self.demoSelection.flatMap { wanted in allHosts.first { snapshots[$0]?.displayName == wanted } } ?? hosts.first
        selectedPort = 12
        seedDemoErrorHistory()
        let devices = DemoData.devices()
        let locatedHosts = devices.filter { $0.switchName != nil && $0.switchPort != "Wi-Fi" }.map(\.ip)
        let ranges = DemoData.ranges.compactMap { try? $0.parsed() }
        ledger.scanStarted(ranges: ranges, network: NetworkContext(DemoData.interface))
        ledger.record(SwitchAutoResult(
            date: lastPoll ?? Date(),
            queriedHosts: Array(ranges.flatMap { $0.addresses() }.prefix(214)),
            respondedHosts: devices.filter { $0.snmpKind != nil }.map(\.ip),
            discoveredHosts: demo.snapshots.map(\.host),
            switches: demo.snapshots.map { snapshot in
                SwitchAutoResult.SwitchEntry(name: snapshot.displayName, host: snapshot.host,
                                             located: devices.filter { $0.switchName == snapshot.displayName }.map(\.ip))
            },
            locatedHosts: locatedHosts, filledHosts: Array(locatedHosts.prefix(3)), communitiesTried: 2))
        locations.record(devices.filter { $0.switchName != nil }.map(\.ip), network: NetworkContext(DemoData.interface))
    }

    /// Vrai si le switch a été trouvé par la découverte automatique.
    func isAutoDiscovered(_ host: String) -> Bool { autoHosts.contains(host) }

    /// Communauté utilisée pour un switch : celle qui a répondu à la découverte, sinon celle saisie.
    func community(for host: String) -> String {
        if let saved = hostCommunities[host], !saved.isEmpty { return saved }
        return community
    }

    // MARK: Switchs

    /// Captures : NETSCOPE_SWITCH=FSW-QUAI affiche ce switch (démonstration).
    private static var demoSelection: String? {
        CommandLine.arguments.contains("--snapshot") ? ProcessInfo.processInfo.environment["NETSCOPE_SWITCH"] : nil
    }

    /// Switchs affichés : SNMP d'abord (ordre d'ajout), puis les FortiSwitch de la FortiGate.
    var allHosts: [String] {
        hosts.filter { !controllerHosts.contains($0) } + controllerHosts
    }

    var orderedSnapshots: [SNMPSwitchSnapshot] {
        allHosts.compactMap { snapshots[$0] }
    }

    /// Relevés SNMP seuls (hors FortiSwitch lus par la FortiGate).
    var snmpSnapshots: [SNMPSwitchSnapshot] {
        hosts.filter { !controllerHosts.contains($0) }.compactMap { snapshots[$0] }
    }

    /// Relevés fournis par la FortiGate.
    var controllerSnapshots: [SNMPSwitchSnapshot] {
        controllerHosts.compactMap { snapshots[$0] }
    }

    /// Vrai si le switch est lu par la FortiGate (FortiLink) et non en SNMP.
    func isController(_ host: String) -> Bool { controllerHosts.contains(host) }

    /// Contrôleur (FortiGate) du switch qui porte ce nom, si c'est un FortiSwitch géré.
    func controllerName(forSwitch name: String) -> String? {
        controllerSnapshots.first { $0.displayName == name }?.controllerName ?? knownControllerSwitches[name]
    }

    /// Remplace les FortiSwitch lus par la FortiGate (une lecture remplace la précédente).
    func setControllerSnapshots(_ list: [SNMPSwitchSnapshot]) {
        fortiSnapshots = list
        installControllerSnapshots()
    }

    /// FortiSwitch, puis switchs des contrôleurs UniFi, Omada et Meraki (note 77).
    private func installControllerSnapshots() {
        for host in controllerHosts { snapshots[host] = nil }
        // Une adresse déjà relevée en SNMP garde son relevé : le FortiSwitch est écarté. Un switch
        // lu par UniFi, Omada ou Meraki (adresse de gestion réelle) passe avant son relevé SNMP.
        let fortiHosts = Set(fortiSnapshots.map(\.host))
        let fresh = fortiSnapshots.filter { !hosts.contains($0.host.description) } + vendorSnapshots.filter { !fortiHosts.contains($0.host) }
        controllerHosts = fresh.map(\.host.description)
        for snapshot in fresh {
            snapshots[snapshot.host.description] = snapshot
            errors[snapshot.host.description] = nil
        }
        if selectedHost == nil || snapshots[selectedHost!] == nil { selectedHost = allHosts.first { snapshots[$0] != nil } }
    }

    // MARK: Note 77 : contrôleurs UniFi, Omada et Meraki

    /// Lectures des contrôleurs du site actif : switchs affichés (marqués du site et de la marque),
    /// puis, si `locate`, MAC, noms, emplacement des appareils filaires et borne des clients Wi-Fi.
    func applyVendorControllers(_ readings: [ControllerSiteReading], state: AppState, locate: Bool = true) {
        let list = ControllerConvert.snapshots(readings, avoiding: Set(fortiSnapshots.map(\.host)))
        var owners: [String: UUID] = [:]
        var index = 0
        for reading in readings {
            for _ in reading.report.switches where index < list.count {
                owners[list[index].host.description] = reading.controllerID
                index += 1
            }
        }
        vendorSnapshots = list
        vendorOwners = owners
        installControllerSnapshots()
        for (mac, name) in ControllerConvert.names(readings) where controllerNames[mac] == nil { controllerNames[mac] = name }
        if !isDemo {
            for snapshot in list {
                PortHistoryStore.shared.record(snapshot, siteKey: historySiteKey(for: snapshot.id))
                // Note 99 : MAC apprises sur les ports d'accès (contrôleur UniFi, Omada, Meraki).
                MACHistoryStore.shared.record(snapshot: snapshot, siteKey: historySiteKey(for: snapshot.id))
            }
        }
        guard locate, !readings.isEmpty else { return }
        let result = ControllerConvert.apply(readings, to: state.devices, controller: controllerSnapshots, snmp: snmpSnapshots)
        state.devices = result.devices
        let ports = FortiLocate.accessPorts(controller: controllerSnapshots, snmp: snmpSnapshots)
        let placed = result.devices.filter { device in device.mac.map { ports[$0] != nil } ?? false }.map(\.ip)
        locations.record(placed, network: isDemo ? NetworkContext(DemoData.interface) : state.currentNetwork)
        if !isDemo, let readAt = readings.map(\.report.readAt).max() { lastPoll = max(lastPoll ?? readAt, readAt) }
    }

    /// Contrôleur (UniFi, Omada, Meraki) qui a fourni ce switch, s'il y en a un.
    func vendorOwner(_ host: String) -> UUID? { vendorOwners[host] }

    /// Retire les FortiSwitch lus par la FortiGate (lecture échouée, FortiGate changée ou désactivée).
    func clearController() {
        guard !isDemo, !controllerHosts.isEmpty || !controllerNames.isEmpty else { return }
        setControllerSnapshots([])
        controllerNames = [:]
        controllerOwners = [:]
        controllerNetwork = nil
        controllerReadAt = nil
    }

    /// FortiSwitch utilisables pour situer les appareils : lus sur le réseau actuel.
    private func usableControllerSnapshots(_ state: AppState) -> [SNMPSwitchSnapshot] {
        guard !isDemo else { return controllerSnapshots }
        guard let read = controllerNetwork, let current = state.currentNetwork,
              read.subnet == current.subnet, read.gateway == current.gateway,
              let readAt = controllerReadAt, Date().timeIntervalSince(readAt) < FortiGateReport.locationMaxAge else { return [] }
        return controllerSnapshots
    }

    /// Lectures des FortiGate reçues (un site ou plusieurs, note 25) : FortiSwitch affichés, chacun
    /// marqué de son site, puis MAC, noms et emplacement des appareils du scan (FortiGate > SNMP).
    func applyControllers(_ sites: [FortiSiteReport], state: AppState) {
        setControllerSnapshots(FortiMulti.snapshots(sites))
        controllerNames = FortiMulti.names(sites)
        controllerOwners = SiteSwitchFilter.controllerOwners(sites)
        // Note 74 : compteurs des FortiSwitch dans l'historique de leur site.
        for snapshot in controllerSnapshots {
            PortHistoryStore.shared.record(snapshot, siteKey: historySiteKey(for: snapshot.id))
            // Note 99 : MAC apprises sur les FortiSwitch, lues par la FortiGate.
            MACHistoryStore.shared.record(snapshot: snapshot, siteKey: historySiteKey(for: snapshot.id), source: .fortigate)
        }
        controllerNetwork = state.currentNetwork
        controllerReadAt = Date()
        if !isDemo {
            // Emplacement donné par la FortiGate : la source (le site) est retenue avec le nom du switch.
            for snapshot in controllerSnapshots { knownControllerSwitches[snapshot.displayName] = snapshot.controllerName ?? "FortiGate" }
            UserDefaults.standard.set(knownControllerSwitches, forKey: Self.controllerSwitchesKey)
        }
        let result = FortiMulti.apply(sites, to: state.devices, snmp: snmpSnapshots)
        state.devices = result.devices
        let ports = FortiLocate.accessPorts(controller: controllerSnapshots, snmp: snmpSnapshots)
        let placed = result.devices.filter { device in device.mac.map { ports[$0] != nil } ?? false }.map(\.ip)
        locations.record(placed, network: isDemo ? NetworkContext(DemoData.interface) : state.currentNetwork)
        if !isDemo, let readAt = sites.map(\.report.readAt).max() { lastPoll = readAt }
    }

    var current: SNMPSwitchSnapshot? {
        if let selectedHost, let snapshot = snapshots[selectedHost] { return snapshot }
        return orderedSnapshots.first
    }

    var selectedInterface: SNMPInterface? {
        guard let current else { return nil }
        if let selectedPort, let iface = current.interface(selectedPort) { return iface }
        return current.physicalPorts.first
    }

    /// Ajoute un switch par son adresse IPv4 ; renvoie un message d'erreur si l'adresse est illisible.
    @discardableResult
    func addHost(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let ip = IPv4Address(trimmed) else { return "Adresse IPv4 invalide\u{00A0}: «\u{00A0}\(trimmed)\u{00A0}»." }
        let key = ip.description
        ignoredHosts.remove(key)
        if !hosts.contains(key) { hosts.append(key) }
        if selectedHost == nil { selectedHost = key }
        return nil
    }

    /// Retire un switch ; la découverte automatique ne l'interrogera plus (« Ne plus ignorer » dans
    /// Réglages › Switchs, ou l'ajouter à la main, le rétablit).
    func removeHost(_ host: String) {
        hosts.removeAll { $0 == host }
        autoHosts.remove(host)
        ignoredHosts.insert(host)
        if hostCommunities.removeValue(forKey: host) != nil { saveHostCommunities() }
        snapshots[host] = nil
        errorTracker.forget(host)
        readingSites[host] = nil
        errors[host] = nil
        if selectedHost == host { selectedHost = hosts.first }
    }

    /// Rend un switch écarté à la découverte automatique.
    func unignore(_ host: String) {
        ignoredHosts.remove(host)
    }

    func select(host: String, port: Int? = nil) {
        selectedHost = host
        selectedPort = port ?? snapshots[host]?.physicalPorts.first(where: \.isUp)?.index
    }

    /// Appareils du scan qui ressemblent à des switchs : reconnus en SNMP, de type switch, ou
    /// fabricant d'équipement réseau.
    func candidates(from devices: [Device]) -> [Device] {
        let brands = ["cisco", "aruba", "hpe", "juniper", "ubiquiti"]
        return devices.filter { device in
            // Note 77 : un switch déjà lu par son contrôleur (ou une FortiGate) n'est pas proposé.
            guard !hosts.contains(device.id), !controllerHosts.contains(device.id) else { return false }
            if device.snmpKind == .switch || device.deviceType == .switch { return true }
            let vendor = device.vendorLabel.lowercased()
            return brands.contains { vendor.contains($0) } && device.deviceType != .pointAcces
        }
    }

    // MARK: Interrogation

    var canPoll: Bool {
        guard !isPolling, !isDiscovering else { return false }
        let fortigate = FortiGateStore.shared
        guard !fortigate.isBusy else { return false }
        return hosts.contains { !isController($0) && hasSNMPAccess($0) }
            || (fortigate.isEnabled && (fortigate.isReady || fortigate.isDemo))
    }

    func poll(state: AppState) {
        guard canPoll else { return }
        pollTask?.cancel()
        pollTask = Task { await runPoll(state: state) }
    }

    private func runPoll(state: AppState) async {
        if isDemo {
            // Démonstration : aucun trafic, on recharge simplement les relevés fictifs.
            isPolling = true
            defer { isPolling = false }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let demo = SwitchDemo.make()
            snapshots = Dictionary(uniqueKeysWithValues: demo.snapshots.map { ($0.host.description, $0) })
            let extra = SitesDemo.unassignedSwitch(now: demo.snapshots.first?.polledAt ?? Date())
            snapshots[extra.host.description] = extra
            controllerHosts = []
            setControllerSnapshots(FortiMulti.snapshots(FortiGateSitesDemo.selectedSites()))
            seedDemoErrorHistory()
            lastPoll = Date()
            applyLocations(to: state)
            return
        }
        // Site du relevé : s'il change en cours de route, les tables MAC de ce site ne doivent
        // jamais toucher les appareils de l'autre (note 28).
        let siteKey = SiteModel.shared.activeKey
        await loadVault()
        guard !Task.isCancelled, SiteModel.shared.activeKey == siteKey else { return }
        // Note 28 : seulement les switchs du site actif (un switch d'un autre client peut avoir la
        // même adresse qu'un appareil d'ici) ; « Afficher tous les switchs » les interroge tous.
        let fresh = await pollHosts(siteHosts.filter { !isController($0) })
        guard !Task.isCancelled, SiteModel.shared.activeKey == siteKey else { return }
        let (located, _) = complete(state, fresh: fresh, routerTables: [])
        // Interrogation manuelle : les appareils localisés le sont sur le réseau actuel.
        locations.record(located.values.flatMap { $0 }, network: state.currentNetwork)
        // FortiSwitch gérés : relus par la FortiGate (prioritaire sur SNMP).
        await FortiGateStore.shared.refreshAfterScan(state: state, ranges: state.checkedRanges)
        // Note 77 : switchs, bornes et clients des contrôleurs UniFi, Omada et Meraki du site.
        await SiteControllerStore.shared.refreshAfterScan(state: state)
    }

    /// Relève les switchs donnés (quatre à la fois), chacun avec sa communauté. Renvoie les
    /// adresses relevées avec succès : seuls ces relevés servent à localiser les appareils.
    private func pollHosts(_ list: [String]) async -> Set<String> {
        isPolling = true
        defer {
            isPolling = false
            pollingHost = nil
        }
        // Note 60 : la fiche matériel (ENTITY-MIB) n'est relue qu'au premier relevé d'un switch, puis
        // une fois par heure au plus ; entre-temps, celle du relevé précédent est recopiée.
        let now = Date()
        let jobs: [(host: String, target: SNMPTarget, readHardware: Bool, previous: SNMPHardwareInfo?)] = list.compactMap { host in
            // Note 59 : utilisateur v3 du site d'abord, communauté en repli.
            guard let target = snmpTarget(for: host) else { return nil }
            let previous = snapshots[host]
            let stale = hardwareReadAt[host].map { now.timeIntervalSince($0) > Self.hardwareRefresh } ?? true
            return (host, target, previous == nil || stale, previous?.hardware)
        }
        let readsHardware = Set(jobs.filter(\.readHardware).map(\.host))
        var fresh = Set<String>()
        var next = 0
        let siteKey = SiteModel.shared.activeKey
        await withTaskGroup(of: (String, Result<SNMPSwitchSnapshot, Error>).self) { group in
            func launch() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    do {
                        let snapshot = try await SNMPSwitchPoller(target: job.target)
                            .snapshot(readHardware: job.readHardware, previousHardware: job.previous)
                        return (job.host, .success(snapshot))
                    }
                    catch { return (job.host, .failure(error)) }
                }
            }
            for _ in 0..<min(4, jobs.count) { launch() }
            for await (host, result) in group {
                // Switch retiré pendant le relevé : son résultat est ignoré.
                guard hosts.contains(host) else { continue }
                switch result {
                case .success(let snapshot):
                    snapshots[host] = snapshot
                    readingSites[host] = siteKey
                    // Note 74 : compteurs des ports dans l'historique du site.
                    PortHistoryStore.shared.record(snapshot, siteKey: siteKey)
                    // Note 99 : MAC apprises sur les ports d'accès, dans l'historique du site.
                    MACHistoryStore.shared.record(snapshot: snapshot, siteKey: siteKey)
                    errors[host] = nil
                    fresh.insert(host)
                    if readsHardware.contains(host) { hardwareReadAt[host] = snapshot.polledAt }
                case .failure(let error):
                    // « Arrêter » n'est pas une panne du switch.
                    if error is CancellationError || Task.isCancelled { break }
                    let previous = errors[host]
                    errors[host] = (error as? LocalizedError)?.errorDescription ?? "Relevé SNMP impossible."
                    // Note 35 : l'échec du relevé va au journal (jamais la communauté ni la réponse),
                    // une fois tant qu'il se répète à l'identique.
                    if errors[host] != previous {
                        AppLog.shared.error("SNMP", "\(host)\u{00A0}: \(errors[host] ?? "relevé SNMP impossible.")")
                    }
                }
                pollingHost = host
                if !Task.isCancelled { launch() }
            }
        }
        if !fresh.isEmpty { lastPoll = Date() }
        // Note 60 : modèle, numéro de série et version lus avec le relevé, dans l'inventaire du site.
        InvHardwareFeed.shared.recordSwitches(fresh.compactMap { snapshots[$0] }, site: siteKey)
        if selectedHost == nil || snapshots[selectedHost!] == nil {
            selectedHost = hosts.first { snapshots[$0] != nil } ?? hosts.first
        }
        if let current, selectedPort == nil || current.interface(selectedPort!) == nil {
            selectedPort = current.physicalPorts.first(where: \.isUp)?.index
        }
        return fresh
    }

    /// Après les relevés : MAC manquantes complétées par l'ARP SNMP (routeurs, switchs de niveau 3),
    /// switchs relevés marqués comme tels, puis emplacement de chaque appareil. Seuls les relevés
    /// réussis de ce passage (`fresh`) servent : une table MAC périmée donnerait un faux port.
    /// Renvoie les appareils localisés, par switch, et ceux dont la MAC a été complétée.
    private func complete(_ state: AppState, fresh: Set<String>,
                          routerTables: [[IPv4Address: MACAddress]]) -> (located: [IPv4Address: [IPv4Address]], filled: [IPv4Address]) {
        let all = hosts.filter(fresh.contains).compactMap { snapshots[$0] }
        let arp = SNMPAutoLocate.mergedARP(routers: routerTables, snapshots: all)
        let missingMAC = Set(state.devices.filter { $0.mac == nil }.map(\.ip))
        var (devices, _) = SNMPAutoLocate.fillMACs(state.devices, from: arp)
        let filled = devices.filter { missingMAC.contains($0.ip) && $0.mac != nil }.map(\.ip)
        let switchHosts = Set(all.map(\.host))
        for index in devices.indices where switchHosts.contains(devices[index].ip) && devices[index].snmpKind == nil {
            devices[index].snmpKind = .switch
            devices[index].deviceType = .switch
        }
        // Les FortiSwitch lus par la FortiGate passent avant SNMP (note 24).
        let located = FortiLocate.locate(devices, controller: usableControllerSnapshots(state), snmp: all)
        state.devices = located.devices
        ScanController.shared.applyVoIPHints(state)   // note 30 : voisins LLDP « téléphone », VLAN voix
        let ports = located.ports
        var bySwitch: [IPv4Address: [IPv4Address]] = [:]
        for device in located.devices {
            guard let mac = device.mac, let location = ports[mac] else { continue }
            bySwitch[location.switchHost, default: []].append(device.ip)
        }
        return (bySwitch, filled)
    }

    /// Reporte le switch, le port et le VLAN de chaque appareil localisé dans AppState (colonne du scanner).
    @discardableResult
    func applyLocations(to state: AppState) -> Int {
        let result = FortiLocate.locate(state.devices, controller: usableControllerSnapshots(state), snmp: snmpSnapshots)
        if result.located > 0 { state.devices = result.devices }
        let ports = result.ports
        let placed = result.devices.filter { device in device.mac.map { ports[$0] != nil } ?? false }.map(\.ip)
        locations.record(placed, network: isDemo ? NetworkContext(DemoData.interface) : state.currentNetwork)
        return result.located
    }

    // MARK: Découverte automatique (fin de scan)

    /// Hôtes à sonder en SNMP parmi ceux en ligne : adresses privées seulement (la communauté
    /// circule en clair, elle ne part jamais vers Internet) et hors switchs écartés.
    func discoveryTargets(_ online: [IPv4Address]) -> [IPv4Address] {
        online.filter { AddressScope.of($0) == .privee && !ignoredHosts.contains($0.description) }
    }

    /// Un scan commence : l'ancien bilan n'est plus d'actualité, même si ce scan ne fait aucune
    /// découverte SNMP. Le prochain bilan sera rattaché à ces plages et à ce réseau.
    func scanStarted(ranges: [IPRange], network: NetworkContext?, discovers: Bool) {
        guard !isDemo else { return }
        ledger.scanStarted(ranges: ranges, network: network)
        isDiscovering = discovers
    }

    /// Le scan s'arrête avant l'étape SNMP (ou sans elle).
    func scanEnded(interrupted: Bool, planned: Bool) {
        isDiscovering = false
        guard !isDemo else { return }
        ledger.scanEnded(interrupted: interrupted, planned: planned)
    }

    /// Efface le bilan (bouton « Effacer » du scanner).
    func clearResult() {
        guard !isDemo else { return }
        ledger.clear()
        locations.clear()
    }

    // MARK: Sites (note 28)

    /// Bilan des switchs et emplacements relevés du site quitté.
    func shelve(into results: inout SiteResults) {
        results.switchResult = ledger.result.map(SiteSwitchRecord.init)
        results.locations = SiteResults.locations(of: locations)
    }

    /// Bilan et emplacements du site choisi (ceux d'un autre site ne valent pas ici, même IP comprise).
    func restore(_ results: SiteResults) {
        // Un relevé manuel du site quitté ne s'applique pas au site choisi.
        pollTask?.cancel()
        pollTask = nil
        ledger = SwitchAutoLedger(result: results.switchResult?.result)
        var ledgerOfSite = LocationLedger()
        for group in results.locationsByNetwork { ledgerOfSite.record(group.hosts, network: group.network) }
        locations = ledgerOfSite
        findResult = nil
    }

    /// FortiSwitch des FortiGate du site choisi, sans toucher aux appareils (ils sont ceux du site).
    func showControllerSites(_ sites: [FortiSiteReport]) {
        setControllerSnapshots(FortiMulti.snapshots(sites))
        controllerNames = FortiMulti.names(sites)
        controllerOwners = SiteSwitchFilter.controllerOwners(sites)
    }

    /// Switchs affichés dans « Switchs et ports » : ceux du site actif (FortiSwitch de ses
    /// FortiGate, switchs SNMP associés), plus un switch sans site s'il est dans les plages du
    /// dernier scan. « Afficher tous les switchs » lève le filtre.
    var siteHosts: [String] { siteHosts(ignoringShowAll: false) }

    /// Relevés des switchs du site actif seulement (rapports : jamais deux sites mélangés).
    var siteSnapshots: [SNMPSwitchSnapshot] { siteHosts(ignoringShowAll: true).compactMap { snapshots[$0] } }

    func siteHosts(ignoringShowAll: Bool) -> [String] {
        let sites = SiteModel.shared
        guard ignoringShowAll || !sites.showAllSwitches else { return allHosts }
        let candidates = allHosts.map { host in
            SiteSwitchFilter.Candidate(host: host, controllerID: isController(host)
                                       ? (controllerOwners[host] ?? vendorOwners[host] ?? Self.unknownOwner) : nil)
        }
        return SiteSwitchFilter.visible(candidates, activeSite: sites.activeSite, sites: sites.sites,
                                        scanRanges: ScanController.shared.lastScanRanges)
    }

    /// Relevés SNMP gardés en mémoire, chacun avec le site pour lequel il a été fait (note 48).
    var snmpReadings: [SiteSNMPReading] {
        snmpSnapshots.map { SiteSNMPReading(snapshot: $0, siteKey: readingSites[$0.id]) }
    }

    /// FortiSwitch dont la FortiGate n'est pas connue (jamais celle du site actif).
    private static let unknownOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Un seul équipement par switch : un switch de niveau 3 répond sur chacune de ses adresses
    /// (une par VLAN). On garde l'adresse déjà connue, sinon la première qui a répondu.
    static func deduplicated(_ list: [SNMPDiscovered], known: Set<String>) -> [SNMPDiscovered] {
        var byKey: [String: SNMPDiscovered] = [:]
        var order: [String] = []
        for item in list {
            let key = item.sysName.isEmpty
                ? item.host.description
                : [item.sysName.lowercased(), item.sysObjectID ?? "", item.sysDescr].joined(separator: "|")
            if let existing = byKey[key] {
                if !known.contains(existing.host.description), known.contains(item.host.description) { byKey[key] = item }
            } else {
                byKey[key] = item
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Après la découverte SNMP (faite pendant le scan) : ajout des switchs trouvés, ARP SNMP des
    /// routeurs, relevé complet de chaque switch, puis emplacement des appareils. `phase` annonce le
    /// passage à l'étape « Emplacements ». Rien n'est envoyé en démonstration.
    func autoDiscover(state: AppState, discovered found: [SNMPDiscovered], queried: [IPv4Address], communitiesTried: Int,
                      readGatewayARP: Bool, phase: (ScanPhase) -> Void) async -> SwitchAutoResult {
        guard !isDemo else { return autoResult ?? SwitchAutoResult() }
        isDiscovering = true
        defer { isDiscovering = false }
        await loadVault()
        // Une interrogation manuelle lancée juste avant : on attend sa fin plutôt que de doubler le trafic.
        await pollTask?.value

        var result = SwitchAutoResult(date: Date(), queriedHosts: queried, respondedHosts: found.map(\.host),
                                      noCommunity: communitiesTried == 0 && !SNMPAccessVault.shared.hasAnyV3,
                                      communitiesTried: communitiesTried)
        guard !Task.isCancelled else { return interrupted(result) }
        if !found.isEmpty { state.devices = SNMPAutoLocate.applyDiscovery(found, to: state.devices) }
        // Note 60 : sysDescr déjà lu par la découverte → modèle et version dans l'inventaire du site.
        InvHardwareFeed.shared.recordDiscovery(found, site: SiteModel.shared.activeKey)

        // Switchs : un par équipement, ajoutés à la liste, communauté retenue au Trousseau.
        let switches = Self.deduplicated(found.filter { $0.kind == .switch && !ignoredHosts.contains($0.host.description) },
                                         known: Set(hosts))
        result.discoveredHosts = switches.map(\.host)
        var vaultChanged = false
        for item in switches {
            let key = item.host.description
            if !hosts.contains(key) {
                hosts.append(key)
                autoHosts.insert(key)
            }
            // Découvert en v3 : aucune communauté à retenir (celle déjà connue reste le repli).
            if !item.community.isEmpty, hostCommunities[key] != item.community {
                hostCommunities[key] = item.community
                vaultChanged = true
            }
        }
        if vaultChanged { saveHostCommunities() }
        if selectedHost == nil { selectedHost = hosts.first }

        // ARP des routeurs (et de la passerelle) qui répondent : MAC des appareils des autres VLAN.
        var routerTables: [[IPv4Address: MACAddress]] = []
        if readGatewayARP {
            let gateway = state.activeInterface?.gateway
            let routers = Self.deduplicated(found.filter { $0.kind == .routeur || $0.host == gateway }, known: [])
            routerTables = await withTaskGroup(of: [IPv4Address: MACAddress].self) { group in
                for router in routers.prefix(8) {
                    group.addTask { await SNMPDiscovery.routerARP(host: router.host, community: router.community, v3: router.v3) }
                }
                var tables: [[IPv4Address: MACAddress]] = []
                for await table in group where !table.isEmpty { tables.append(table) }
                return tables
            }
        }
        guard !Task.isCancelled else { return interrupted(result) }

        // Relevé complet des switchs de ce réseau (plages scannées, sous-réseau de l'interface,
        // découverts à l'instant, ajoutés à la main), puis emplacements. Un switch découvert sur un
        // autre réseau n'est pas interrogé : ni délai d'attente, ni communauté envoyée ailleurs.
        let ranges = ledger.scanRanges
        let discoveredNow = Set(switches.map(\.host))
        // Note 28 : un switch associé à un autre site n'est jamais interrogé automatiquement (sa
        // communauté partirait vers l'appareil qui a la même adresse ici).
        let sites = SiteModel.shared
        let ofThisSite = SiteSwitchFilter.pollable(hosts.filter { !isController($0) }, activeSite: sites.activeSite,
                                                   sites: sites.sites, scanRanges: ranges)
        let relevant = Set(SwitchAutoResult.hostsToPoll(
            known: ofThisSite.compactMap(IPv4Address.init), manual: Set(hosts.filter { !autoHosts.contains($0) }.compactMap(IPv4Address.init)),
            discoveredNow: discoveredNow, ranges: ranges, localSubnet: ledger.scanNetwork?.subnet).map(\.description))
        let allowed = Set(ofThisSite)
        let polled = hosts.filter { relevant.contains($0) && allowed.contains($0) && hasSNMPAccess($0) }
        let fresh = await pollHosts(polled)
        guard !Task.isCancelled else { return interrupted(result) }
        phase(.locations)
        let (located, filled) = complete(state, fresh: fresh, routerTables: routerTables)
        locations.discoveryFinished(ranges: ranges, located: located.values.flatMap { $0 }, network: ledger.scanNetwork)
        func inScan(_ ip: IPv4Address) -> Bool { ranges.isEmpty || ScanRelevance.contains(ranges, ip) }
        result.switches = hosts.filter(fresh.contains).compactMap { host in
            guard let snapshot = snapshots[host] else { return nil }
            return SwitchAutoResult.SwitchEntry(name: snapshot.displayName, host: snapshot.host,
                                                located: (located[snapshot.host] ?? []).filter(inScan))
        }
        // Seuls les switchs de ce réseau ont été interrogés : chacun de leurs échecs est signalé.
        result.failed = polled.filter { !fresh.contains($0) }.map { host in
            SwitchAutoResult.SwitchEntry(name: snapshots[host]?.displayName ?? host, host: IPv4Address(host))
        }
        result.locatedHosts = located.values.flatMap { $0 }.filter(inScan).sorted()
        result.filledHosts = filled.filter(inScan)
        result.date = Date()
        ledger.record(result)
        return ledger.result ?? result
    }

    private func interrupted(_ partial: SwitchAutoResult) -> SwitchAutoResult {
        var result = partial
        result.interrupted = true
        result.date = Date()
        ledger.record(result)
        return ledger.result ?? result
    }

    // MARK: Recherche d'un appareil

    /// Cherche une IP, une MAC ou un nom ; sélectionne le port trouvé.
    func find(_ query: String, devices: [Device]) {
        let raw = query.trimmingCharacters(in: .whitespaces)
        findQuery = raw
        // Note 83 : le résultat s'affiche sous la façade, dans l'onglet Switchs.
        SwitchTabState.shared.tab = .switchs
        guard !raw.isEmpty else {
            findResult = nil
            return
        }
        let all = orderedSnapshots
        guard !all.isEmpty else {
            findResult = SwitchFindResult(ok: false, text: "Aucun relevé disponible\u{00A0}: interrogez d’abord les switchs.")
            return
        }
        var macs: [MACAddress] = []
        if let mac = MACAddress(raw) {
            macs = [mac]
        } else if let ip = IPv4Address(raw) {
            macs = devices.filter { $0.ip == ip }.compactMap(\.mac)
            for snapshot in all { macs += snapshot.arp.filter { $0.value == ip }.map(\.key) }
        } else if raw.count >= 3 {
            macs = devices.filter { device in
                [device.displayName, device.hostname ?? ""].contains { $0.range(of: raw, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }.compactMap(\.mac)
            macs += demoNames.filter { $0.value.range(of: raw, options: .caseInsensitive) != nil }.map(\.key)
            macs += controllerNames.filter { $0.value.range(of: raw, options: .caseInsensitive) != nil }.map(\.key).sorted { $0.value < $1.value }
        }
        var seen = Set<MACAddress>()
        macs = macs.filter { seen.insert($0).inserted }
        for mac in macs {
            if let location = SNMPLocator.locate(mac, in: all) {
                selectedHost = location.switchHost.description
                selectedPort = location.ifIndex
                let info = describe(mac, devices: devices)
                var parts = [info.name, info.ip, mac.formatted(.upperColon)].filter { !$0.isEmpty && $0 != "—" }
                parts = [parts.joined(separator: " · ")]
                let vlan = location.vlan.map { " · VLAN \($0)" } ?? ""
                let source = isController(location.switchHost.description) ? "source FortiGate" : "source FDB"
                findResult = SwitchFindResult(ok: true, text: "\(parts[0]) → \(location.switchName) · port \(location.portName)\(vlan) · \(source)",
                                              host: location.switchHost.description, ifIndex: location.ifIndex)
                return
            }
        }
        if let mac = macs.first, let uplink = SNMPLocator.sightings(of: mac, in: all).first {
            findResult = SwitchFindResult(ok: false, text: "«\u{00A0}\(raw)\u{00A0}» n’est vu que sur un uplink (\(uplink.switchName) · \(uplink.portName))\u{00A0}: ajoutez le switch situé derrière pour trouver le port d’accès.")
            return
        }
        let hint = macs.isEmpty ? " (adresse MAC inconnue\u{00A0}: lancez un scan ou saisissez la MAC)" : ""
        findResult = SwitchFindResult(ok: false, text: "Aucun port trouvé pour «\u{00A0}\(raw)\u{00A0}»\(hint). Vérifiez la saisie ou relancez l’interrogation des switchs.")
    }

    func clearFind() {
        findResult = nil
    }

    // MARK: Croisement avec les appareils du scan

    struct DeviceInfo {
        var name: String
        var ip: String
        var vendor: String
        var deviceID: Device.ID?
    }

    func describe(_ mac: MACAddress, devices: [Device]) -> DeviceInfo {
        if let device = devices.first(where: { $0.mac == mac }) {
            return DeviceInfo(name: device.displayName, ip: device.ip.description, vendor: device.vendorLabel, deviceID: device.id)
        }
        let ip = orderedSnapshots.lazy.compactMap { $0.arp[mac] }.first
        return DeviceInfo(name: demoNames[mac] ?? controllerNames[mac] ?? "—", ip: ip?.description ?? "—", vendor: OUIDatabase.builtIn.label(for: mac), deviceID: nil)
    }

    /// Vrai si la MAC appartient au voisin LLDP du port (même nom que l'appareil connu).
    func isAnnounced(_ mac: MACAddress, by neighbor: SNMPLLDPNeighbor?, devices: [Device]) -> Bool {
        guard let neighbor, !neighbor.sysName.isEmpty else { return false }
        let names = [describe(mac, devices: devices).name, devices.first { $0.mac == mac }?.hostname ?? ""]
        return names.contains { $0.caseInsensitiveCompare(neighbor.sysName) == .orderedSame }
    }

    // MARK: Export

    func csv(devices: [Device]) -> String {
        var lines = ["Switch;Port;Alias;VLAN;MAC;IP;Nom;Fabricant;Uplink"]
        for snapshot in orderedSnapshots {
            let uplinks = snapshot.locatedUplinks
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex else { continue }
                let iface = snapshot.interface(i)
                let info = describe(entry.mac, devices: devices)
                let fields = [snapshot.displayName, iface?.name ?? "\(entry.bridgePort)", iface?.alias ?? "",
                              (entry.vlan ?? snapshot.pvid[i]).map(String.init) ?? "", entry.mac.formatted(.upperColon),
                              info.ip, info.name, info.vendor, uplinks.contains(i) ? "oui" : "non"]
                lines.append(fields.map(CSVText.field).joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func exportCSV(devices: [Device]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "switchs-table-mac.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(devices: devices).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }
}

struct SwitchFindResult: Equatable {
    var ok: Bool
    var text: String
    var host: String? = nil
    var ifIndex: Int? = nil
}

// MARK: - Relecture automatique (note 29)

extension SwitchStore {
    /// Résultat d'une relecture automatique des switchs SNMP.
    enum AutoOutcome: Equatable {
        /// Au moins un switch relevé.
        case success
        /// Aucun n'a répondu : délai croissant.
        case failure
        /// Rien de fait (relevé ou découverte en cours, site changé, aucun switch avec sa communauté).
        case skipped
        /// Aucun switch du site relisible (communauté absente) : rien à relire.
        case nothing
    }

    /// Switchs SNMP que la relecture automatique peut relever pour le site actif : jamais un
    /// switch d'un autre site (sa communauté partirait vers l'appareil qui porte la même adresse ici).
    func autoRefreshHosts() -> [String] {
        let sites = SiteModel.shared
        return AutoRefreshTargets.snmpHosts(hosts, controllerHosts: Set(controllerHosts), activeSite: sites.activeSite,
                                            sites: sites.sites, readingSites: readingSites,
                                            scanRanges: ScanController.shared.lastScanRanges)
    }

    /// Relecture automatique : relève les switchs SNMP du site actif (quatre à la fois), puis
    /// replace chaque appareil sur son switch, son port et son VLAN. Sans relancer de scan ni
    /// relire la FortiGate (la relecture automatique s'en charge à part).
    func autoPoll(state: AppState) async -> AutoOutcome {
        guard !isPolling, !isDiscovering else { return .skipped }
        if isDemo {
            // Démonstration : aucun trafic, les relevés fictifs restent ceux affichés.
            lastPoll = Date()
            return .success
        }
        let siteKey = SiteModel.shared.activeKey
        await loadVault()
        guard !Task.isCancelled, SiteModel.shared.activeKey == siteKey, !isPolling, !isDiscovering else { return .skipped }
        let list = autoRefreshHosts().filter { hasSNMPAccess($0) }
        guard !list.isEmpty else { return .nothing }
        let fresh = await pollHosts(list)
        guard !Task.isCancelled, SiteModel.shared.activeKey == siteKey else { return .skipped }
        guard !fresh.isEmpty else { return .failure }
        let (located, _) = complete(state, fresh: fresh, routerTables: [])
        locations.record(located.values.flatMap { $0 }, network: state.currentNetwork)
        return .success
    }
}

/// Champ CSV sûr : sans séparateur ni saut de ligne, et neutralisé s'il ressemble à une formule
/// (un alias de port ou un SSID peut commencer par « = », « + », « - » ou « @ »).
enum CSVText {
    static func field(_ text: String) -> String {
        var value = text.replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let isNumber = Double(value.replacingOccurrences(of: ",", with: ".")) != nil
        if let first = value.first, "=+-@\t".contains(first), !isNumber { value = "'" + value }
        return value
    }
}

/// Switch d'un autre site à montrer dans Switchs et ports (note 48) : adresse de gestion ou nom.
struct SwitchBrowseFocus: Equatable {
    var siteKey: String
    var hostOrName: String
    var port: String?
}
