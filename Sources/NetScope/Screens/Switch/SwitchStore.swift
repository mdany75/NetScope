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
    @Published private(set) var snapshots: [String: SNMPSwitchSnapshot] = [:]
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

    /// Noms d'hôte des postes fictifs de la démonstration (absents d'AppState).
    private(set) var demoNames: [MACAddress: String] = [:]

    let isDemo: Bool
    private static let hostsKey = "NetScope.switchs.hotes"
    private static let autoHostsKey = "NetScope.switchs.decouverts"
    private static let ignoredKey = "NetScope.switchs.ignores"
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
        }
    }

    /// Lit au Trousseau (une seule fois, hors du fil principal) la communauté des Identifiants et
    /// celles retenues par switch. Une demande d'autorisation de macOS ne gèle donc pas l'app.
    func loadVault() async {
        guard !isDemo else { return }
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

    /// La communauté des Identifiants vient d'être effacée : elle ne sert plus pour les relevés.
    func credentialsErased() {
        community = ""
        forgetCommunities()
    }

    private func loadDemo() {
        let demo = SwitchDemo.make()
        hosts = demo.snapshots.map(\.host.description)
        snapshots = Dictionary(uniqueKeysWithValues: demo.snapshots.map { ($0.host.description, $0) })
        demoNames = demo.names
        community = "lecture-demo"
        autoHosts = Set(hosts)
        lastPoll = demo.snapshots.first?.polledAt
        selectedHost = hosts.first
        selectedPort = 12
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

    var orderedSnapshots: [SNMPSwitchSnapshot] {
        hosts.compactMap { snapshots[$0] }
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
            guard !hosts.contains(device.id) else { return false }
            if device.snmpKind == .switch || device.deviceType == .switch { return true }
            let vendor = device.vendorLabel.lowercased()
            return brands.contains { vendor.contains($0) } && device.deviceType != .pointAcces
        }
    }

    // MARK: Interrogation

    var canPoll: Bool { !isPolling && !isDiscovering && hosts.contains { !community(for: $0).isEmpty } }

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
            lastPoll = Date()
            applyLocations(to: state)
            return
        }
        await loadVault()
        let fresh = await pollHosts(hosts)
        guard !Task.isCancelled else { return }
        let (located, _) = complete(state, fresh: fresh, routerTables: [])
        // Interrogation manuelle : les appareils localisés le sont sur le réseau actuel.
        locations.record(located.values.flatMap { $0 }, network: state.currentNetwork)
    }

    /// Relève les switchs donnés (quatre à la fois), chacun avec sa communauté. Renvoie les
    /// adresses relevées avec succès : seuls ces relevés servent à localiser les appareils.
    private func pollHosts(_ list: [String]) async -> Set<String> {
        isPolling = true
        defer {
            isPolling = false
            pollingHost = nil
        }
        let jobs: [(host: String, target: SNMPTarget)] = list.compactMap { host in
            let community = community(for: host)
            guard let ip = IPv4Address(host), !community.isEmpty else { return nil }
            return (host, SNMPTarget(host: ip, community: community, timeout: 2, retries: 1))
        }
        var fresh = Set<String>()
        var next = 0
        await withTaskGroup(of: (String, Result<SNMPSwitchSnapshot, Error>).self) { group in
            func launch() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    do { return (job.host, .success(try await SNMPSwitchPoller(target: job.target).snapshot())) }
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
                    errors[host] = nil
                    fresh.insert(host)
                case .failure(let error):
                    // « Arrêter » n'est pas une panne du switch.
                    if error is CancellationError || Task.isCancelled { break }
                    errors[host] = (error as? LocalizedError)?.errorDescription ?? "Relevé SNMP impossible."
                }
                pollingHost = host
                if !Task.isCancelled { launch() }
            }
        }
        if !fresh.isEmpty { lastPoll = Date() }
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
        let located = SNMPAutoLocate.locate(devices, in: all)
        state.devices = located.devices
        let ports = all.isEmpty ? [:] : SNMPAutoLocate.accessPorts(in: all)
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
        let result = SNMPAutoLocate.locate(state.devices, in: orderedSnapshots)
        if result.located > 0 { state.devices = result.devices }
        let ports = orderedSnapshots.isEmpty ? [:] : SNMPAutoLocate.accessPorts(in: orderedSnapshots)
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
                                      noCommunity: communitiesTried == 0, communitiesTried: communitiesTried)
        guard !Task.isCancelled else { return interrupted(result) }
        if !found.isEmpty { state.devices = SNMPAutoLocate.applyDiscovery(found, to: state.devices) }

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
            if hostCommunities[key] != item.community {
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
                    group.addTask { await SNMPDiscovery.routerARP(host: router.host, community: router.community) }
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
        let relevant = Set(SwitchAutoResult.hostsToPoll(
            known: hosts.compactMap(IPv4Address.init), manual: Set(hosts.filter { !autoHosts.contains($0) }.compactMap(IPv4Address.init)),
            discoveredNow: discoveredNow, ranges: ranges, localSubnet: ledger.scanNetwork?.subnet).map(\.description))
        let polled = hosts.filter { relevant.contains($0) && !community(for: $0).isEmpty }
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
                findResult = SwitchFindResult(ok: true, text: "\(parts[0]) → \(location.switchName) · port \(location.portName)\(vlan) · source FDB",
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
        return DeviceInfo(name: demoNames[mac] ?? "—", ip: ip?.description ?? "—", vendor: OUIDatabase.builtIn.label(for: mac), deviceID: nil)
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
            let uplinks = snapshot.uplinkInterfaces()
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
