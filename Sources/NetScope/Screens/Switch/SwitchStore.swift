import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

/// État du module Switchs et ports : switchs à interroger, relevés SNMP, sélection.
/// La communauté reste en mémoire seulement (jamais enregistrée, jamais « public » par défaut).
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

    /// Noms d'hôte des postes fictifs de la démonstration (absents d'AppState).
    private(set) var demoNames: [MACAddress: String] = [:]

    let isDemo: Bool
    private static let hostsKey = "NetScope.switchs.hotes"
    private var pollTask: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        if demo {
            hosts = []
            loadDemo()
        } else {
            hosts = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
        }
    }

    private func loadDemo() {
        let demo = SwitchDemo.make()
        hosts = demo.snapshots.map(\.host.description)
        snapshots = Dictionary(uniqueKeysWithValues: demo.snapshots.map { ($0.host.description, $0) })
        demoNames = demo.names
        community = "lecture-demo"
        lastPoll = demo.snapshots.first?.polledAt
        selectedHost = hosts.first
        selectedPort = 12
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
        snapshots[host] = nil
        errors[host] = nil
        if selectedHost == host { selectedHost = hosts.first }
    }

    func select(host: String, port: Int? = nil) {
        selectedHost = host
        selectedPort = port ?? snapshots[host]?.physicalPorts.first(where: \.isUp)?.index
    }

    /// Appareils du scan qui ressemblent à des switchs : port 161 ouvert, type switch, ou fabricant d'équipement réseau.
    func candidates(from devices: [Device]) -> [Device] {
        let brands = ["cisco", "aruba", "hpe", "juniper", "ubiquiti"]
        return devices.filter { device in
            guard !hosts.contains(device.id) else { return false }
            if device.openPorts.contains(161) || device.deviceType == .switch { return true }
            let vendor = device.vendorLabel.lowercased()
            return brands.contains { vendor.contains($0) } && device.deviceType != .pointAcces
        }
    }

    // MARK: Interrogation

    var canPoll: Bool { !hosts.isEmpty && !community.isEmpty && !isPolling }

    func poll(state: AppState) {
        guard canPoll else { return }
        pollTask?.cancel()
        pollTask = Task { await runPoll(state: state) }
    }

    private func runPoll(state: AppState) async {
        isPolling = true
        defer {
            isPolling = false
            pollingHost = nil
        }
        if isDemo {
            // Démonstration : aucun trafic, on recharge simplement les relevés fictifs.
            try? await Task.sleep(nanoseconds: 800_000_000)
            let demo = SwitchDemo.make()
            snapshots = Dictionary(uniqueKeysWithValues: demo.snapshots.map { ($0.host.description, $0) })
            lastPoll = Date()
            applyLocations(to: state)
            return
        }
        let community = self.community
        for host in hosts {
            guard !Task.isCancelled, let ip = IPv4Address(host) else { continue }
            pollingHost = host
            let poller = SNMPSwitchPoller(target: SNMPTarget(host: ip, community: community, timeout: 2, retries: 1))
            do {
                let snapshot = try await poller.snapshot()
                snapshots[host] = snapshot
                errors[host] = nil
            } catch {
                errors[host] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        lastPoll = Date()
        if selectedHost == nil || snapshots[selectedHost!] == nil {
            selectedHost = hosts.first { snapshots[$0] != nil } ?? hosts.first
        }
        if let current, selectedPort == nil || current.interface(selectedPort!) == nil {
            selectedPort = current.physicalPorts.first(where: \.isUp)?.index
        }
        applyLocations(to: state)
    }

    /// Reporte le switch, le port et le VLAN de chaque appareil localisé dans AppState (colonne du scanner).
    func applyLocations(to state: AppState) {
        let all = orderedSnapshots
        guard !all.isEmpty else { return }
        for position in state.devices.indices {
            guard let mac = state.devices[position].mac, let location = SNMPLocator.locate(mac, in: all) else { continue }
            state.devices[position].switchName = location.switchName
            state.devices[position].switchPort = location.portName
            if let vlan = location.vlan { state.devices[position].vlan = vlan }
        }
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
