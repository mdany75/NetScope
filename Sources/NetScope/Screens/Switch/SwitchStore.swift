import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

/// Bilan de la découverte automatique faite à la fin d'un scan.
struct SwitchAutoResult: Equatable {
    var date: Date
    /// Appareils qui ont répondu en SNMP (switchs, routeurs, imprimantes…).
    var responded: Int
    /// Noms des switchs découverts ou relevés.
    var switchNames: [String]
    /// Appareils dont le switch et le port sont connus.
    var located: Int
    /// MAC complétées par l'ARP SNMP des routeurs et des switchs de niveau 3.
    var filledMACs: Int
    /// Aucune communauté à essayer (liste vide et rien dans les Identifiants).
    var noCommunity = false

    var foundSwitch: Bool { !switchNames.isEmpty }
}

/// État du module Switchs et ports : switchs à interroger, relevés SNMP, sélection.
///
/// Les switchs sont découverts automatiquement à la fin de chaque scan (`autoDiscover`) ou
/// ajoutés à la main. La communauté saisie ici est préremplie depuis le Trousseau (Réglages ›
/// Identifiants) ; celle qui a répondu pour chaque switch découvert est gardée au Trousseau,
/// jamais dans les préférences.
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
    /// Bilan de la dernière découverte automatique.
    @Published private(set) var autoResult: SwitchAutoResult?
    /// Communauté qui a répondu, par switch (adresse IP → communauté), lue au Trousseau.
    private var hostCommunities: [String: String] = [:]

    /// Noms d'hôte des postes fictifs de la démonstration (absents d'AppState).
    private(set) var demoNames: [MACAddress: String] = [:]

    let isDemo: Bool
    private static let hostsKey = "NetScope.switchs.hotes"
    private static let autoHostsKey = "NetScope.switchs.decouverts"
    private var pollTask: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        if demo {
            hosts = []
            autoHosts = []
            loadDemo()
        } else {
            hosts = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
            autoHosts = Set(UserDefaults.standard.stringArray(forKey: Self.autoHostsKey) ?? [])
            hostCommunities = RegSNMPDiscoveryVault.hostCommunities()
            community = RegSNMPCredentials.load()?.community ?? ""
        }
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
        let located = DemoData.devices().filter { $0.switchName != nil && $0.switchPort != "Wi-Fi" }.count
        autoResult = SwitchAutoResult(date: lastPoll ?? Date(), responded: 4, switchNames: demo.snapshots.map(\.displayName),
                                      located: located, filledMACs: 3)
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
        if !hosts.contains(key) { hosts.append(key) }
        if selectedHost == nil { selectedHost = key }
        return nil
    }

    func removeHost(_ host: String) {
        hosts.removeAll { $0 == host }
        autoHosts.remove(host)
        if hostCommunities.removeValue(forKey: host) != nil { RegSNMPDiscoveryVault.saveHostCommunities(hostCommunities) }
        snapshots[host] = nil
        errors[host] = nil
        if selectedHost == host { selectedHost = hosts.first }
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

    var canPoll: Bool { !isPolling && hosts.contains { !community(for: $0).isEmpty } }

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
        await pollHosts(hosts)
        _ = complete(state, routerTables: [])
    }

    /// Relève les switchs donnés (quatre à la fois), chacun avec sa communauté.
    private func pollHosts(_ list: [String]) async {
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
                switch result {
                case .success(let snapshot):
                    snapshots[host] = snapshot
                    errors[host] = nil
                case .failure(let error):
                    errors[host] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                pollingHost = host
                if !Task.isCancelled { launch() }
            }
        }
        lastPoll = Date()
        if selectedHost == nil || snapshots[selectedHost!] == nil {
            selectedHost = hosts.first { snapshots[$0] != nil } ?? hosts.first
        }
        if let current, selectedPort == nil || current.interface(selectedPort!) == nil {
            selectedPort = current.physicalPorts.first(where: \.isUp)?.index
        }
    }

    /// Après les relevés : MAC manquantes complétées par l'ARP SNMP (routeurs, switchs de niveau 3),
    /// switchs relevés marqués comme tels, puis emplacement de chaque appareil.
    private func complete(_ state: AppState, routerTables: [[IPv4Address: MACAddress]]) -> (located: Int, filled: Int) {
        let all = orderedSnapshots
        let arp = SNMPAutoLocate.mergedARP(routers: routerTables, snapshots: all)
        var (devices, filled) = SNMPAutoLocate.fillMACs(state.devices, from: arp)
        let switchHosts = Set(all.map(\.host))
        for index in devices.indices where switchHosts.contains(devices[index].ip) && devices[index].snmpKind == nil {
            devices[index].snmpKind = .switch
            devices[index].deviceType = .switch
        }
        let located = SNMPAutoLocate.locate(devices, in: all)
        state.devices = located.devices
        return (located.located, filled)
    }

    /// Reporte le switch, le port et le VLAN de chaque appareil localisé dans AppState (colonne du scanner).
    @discardableResult
    func applyLocations(to state: AppState) -> Int {
        let result = SNMPAutoLocate.locate(state.devices, in: orderedSnapshots)
        if result.located > 0 { state.devices = result.devices }
        return result.located
    }

    // MARK: Découverte automatique (fin de scan)

    /// Découverte SNMP des hôtes en ligne du scan, ajout des switchs trouvés, relevé complet de
    /// chaque switch, ARP SNMP des routeurs, puis emplacement des appareils. `phase` annonce le
    /// passage à l'étape « Emplacements ». Rien n'est envoyé en démonstration.
    func autoDiscover(state: AppState, hosts online: [IPv4Address], communities: [String],
                      phase: (ScanPhase) -> Void) async -> SwitchAutoResult {
        guard !isDemo else { return autoResult ?? SwitchAutoResult(date: Date(), responded: 0, switchNames: [], located: 0, filledMACs: 0) }
        guard !communities.isEmpty else {
            phase(.locations)
            let located = applyLocations(to: state)
            let result = SwitchAutoResult(date: Date(), responded: 0, switchNames: orderedSnapshots.map(\.displayName),
                                          located: located, filledMACs: 0, noCommunity: true)
            autoResult = result
            return result
        }
        let discovered = await SNMPDiscovery(communities: communities).discover(online)
        guard !Task.isCancelled else {
            return SwitchAutoResult(date: Date(), responded: discovered.count, switchNames: [], located: 0, filledMACs: 0)
        }
        state.devices = SNMPAutoLocate.applyDiscovery(discovered, to: state.devices)

        // Switchs : ajoutés à la liste, communauté retenue au Trousseau.
        var vaultChanged = false
        for item in discovered where item.kind == .switch {
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
        if vaultChanged { RegSNMPDiscoveryVault.saveHostCommunities(hostCommunities) }
        if selectedHost == nil { selectedHost = hosts.first }

        // ARP des routeurs (et de la passerelle) qui répondent : MAC des appareils des autres VLAN.
        let gateway = state.activeInterface?.gateway
        let routers = discovered.filter { $0.kind == .routeur || $0.host == gateway }
        let routerTables: [[IPv4Address: MACAddress]] = await withTaskGroup(of: [IPv4Address: MACAddress].self) { group in
            for router in routers.prefix(8) {
                group.addTask { await SNMPDiscovery.routerARP(host: router.host, community: router.community) }
            }
            var tables: [[IPv4Address: MACAddress]] = []
            for await table in group where !table.isEmpty { tables.append(table) }
            return tables
        }

        // Relevé complet des switchs (découverts et ajoutés à la main), puis emplacements.
        await pollHosts(hosts)
        phase(.locations)
        let (located, filled) = complete(state, routerTables: routerTables)
        let result = SwitchAutoResult(date: Date(), responded: discovered.count, switchNames: orderedSnapshots.map(\.displayName),
                                      located: located, filledMACs: filled)
        autoResult = result
        return result
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
