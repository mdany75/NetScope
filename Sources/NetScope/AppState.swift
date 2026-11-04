import Foundation
import NetScopeCore
import SwiftUI

/// Informations sur l'application.
enum AppInfo {
    /// Version lue dans Info.plist du paquet ; hors paquet (.build/, captures), celle de
    /// `Resources/Info.plist` du dépôt, sinon « dev ».
    static let version: String = {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/NetScope
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // dépôt
            .appendingPathComponent("Resources/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = info["CFBundleShortVersionString"] as? String {
            return version
        }
        return "dev"
    }()
}

/// État partagé de l'application : écran courant, appareils, plages, sélection.
/// Une seule instance, injectée par `.environmentObject` ; tous les écrans la lisent.
@MainActor
final class AppState: ObservableObject {
    // MARK: Navigation

    @Published var screen: Screen = .scanner
    /// Recherche de la barre d'outils, propre à chaque module (note 26) : les préfixes
    /// (`switch:`, `type:`…) dépendent du module, une recherche du Scanner ne filtre pas les Réglages.
    @Published var searchTexts: [Screen: String] = [:]

    /// Recherche de l'écran courant (champ de la barre d'outils).
    var searchText: String {
        get { searchTexts[screen] ?? "" }
        set { searchTexts[screen] = newValue.isEmpty ? nil : newValue }
    }

    /// Recherche d'un module, analysée avec ses champs (requête vide si l'écran n'en a pas).
    func searchQuery(for screen: Screen) -> SearchQuery {
        SearchQuery(searchTexts[screen] ?? "", schema: screen.searchSchema ?? .textOnly)
    }

    // MARK: Réseau et appareils

    @Published var devices: [Device] = []
    @Published var selectedDeviceID: Device.ID?
    @Published var ranges: [ScanRangeConfig] {
        didSet { save() }
    }
    /// Noms personnalisés, par adresse IP (conservés d'un lancement à l'autre).
    @Published private(set) var customNames: [String: String] {
        didSet { save() }
    }
    @Published var scanProfile: ScanProfile = .rapide
    /// Interface active (barre latérale) ; nil tant qu'elle n'est pas détectée.
    @Published var activeInterface: LocalInterface?
    @Published var dnsServers: [IPv4Address] = []

    // MARK: Divers

    /// Numéro de la version disponible, s'il y en a une plus récente (« 1.1.0 »).
    @Published var updateAvailable: String?
    /// Cibles du ping continu (adresses ou noms), alimentées depuis les autres écrans.
    @Published var pingTargets: [String] = []
    /// Compteurs affichés dans la barre latérale (Surveillance : alertes, Analyse : nouveautés).
    @Published var sidebarBadges: [Screen: Int] = [:]

    private let store: StateStore?

    /// `store` nil : rien n'est lu ni écrit sur le disque (captures, démonstration).
    init(store: StateStore? = StateStore.standard) {
        self.store = store
        let saved = store?.load()
        ranges = saved?.ranges ?? AppState.defaultRanges
        customNames = saved?.customNames ?? [:]
        isFirstLaunch = saved == nil
    }

    /// Vrai si aucun état n'était enregistré : les plages par défaut seront remplacées par le réseau détecté.
    private(set) var isFirstLaunch: Bool

    static let defaultRanges = [ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau", vlan: 1)]

    // MARK: Actions

    func open(_ screen: Screen) {
        self.screen = screen
    }

    var selectedDevice: Device? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first { $0.id == id }
    }

    func device(withID id: Device.ID) -> Device? {
        devices.first { $0.id == id }
    }

    /// Ouvre la fiche d'un appareil.
    func showDevice(_ id: Device.ID) {
        selectedDeviceID = id
        open(.appareil)
    }

    /// Ajoute une cible au ping continu (sans doublon) et ouvre l'écran.
    func sendToPing(_ target: String, open shouldOpen: Bool = true) {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !pingTargets.contains(trimmed) { pingTargets.append(trimmed) }
        if shouldOpen { open(.ping) }
    }

    /// Appareils filtrés par la recherche du Scanner (type choisi à la main, site FortiGate et
    /// notes de la fiche compris).
    var filteredDevices: [Device] {
        DeviceSearch.filter(devices, searchQuery(for: .scanner))
    }

    /// Ajoute ou met à jour des appareils (par IP), en gardant `firstSeen` et le nom personnalisé.
    func merge(_ incoming: [Device]) {
        var index: [String: Int] = [:]
        for (position, device) in devices.enumerated() { index[device.id] = position }
        for var device in incoming {
            device.customName = customNames[device.id] ?? device.customName
            if let position = index[device.id] {
                device.firstSeen = min(devices[position].firstSeen, device.firstSeen)
                devices[position] = device
            } else {
                index[device.id] = devices.count
                devices.append(device)
            }
        }
        devices.sort { $0.ip < $1.ip }
    }

    /// Noms personnalisés du site choisi (note 28 : les noms vont avec les résultats de chaque site).
    func replaceCustomNames(_ names: [String: String]) {
        customNames = names
    }

    /// Nom personnalisé d'un appareil ; un nom vide l'efface.
    func setCustomName(_ name: String?, for id: Device.ID) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        customNames[id] = trimmed.isEmpty ? nil : trimmed
        if let position = devices.firstIndex(where: { $0.id == id }) {
            devices[position].customName = trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Interface active

    /// Lit l'interface active (état local, aucun trafic) ; au premier lancement, remplace les
    /// plages par défaut par le réseau de cette interface.
    func detectInterface() async {
        let interfaces = await LocalInterfaces.listWithKinds()
        let primary = interfaces.first { $0.kind == .wifi || $0.kind == .ethernet } ?? interfaces.first
        activeInterface = primary
        if isFirstLaunch, let primary {
            isFirstLaunch = false
            let subnet = primary.subnet
            // Un réseau plus grand qu'un /16 dépasserait la limite de scan : on se limite au /24 de l'adresse.
            let usable = subnet.prefix < 16 ? Subnet(address: primary.address, prefix: 24) : subnet
            ranges = [ScanRangeConfig(text: usable.description, label: primary.kind == .wifi ? "Wi-Fi" : "Réseau local")]
            // Note 28 : le premier site reçoit ces plages détectées.
            SiteModel.shared.firstLaunchRangesDetected(self)
        }
    }

    /// Interface choisie dans Réglages › Interface : gardée tant qu'elle existe, reprise quand
    /// elle revient après une coupure.
    var preferredInterfaceName: String?

    /// Rafraîchit l'interface active, sa passerelle et les serveurs DNS (getifaddrs, table de
    /// routage, resolv.conf : lecture locale, aucun trafic), quel que soit l'écran affiché. Un
    /// changement d'interface, de sous-réseau ou de passerelle rend périmés le bilan des switchs,
    /// les emplacements relevés et l'encart LLDP/CDP.
    func refreshInterface() async {
        let (interfaces, gateway, servers) = await Task.detached(priority: .utility) {
            (LocalInterfaces.list(), ScanNetwork.defaultGateway(), ScanNetwork.dnsServers())
        }.value
        if !servers.isEmpty, servers != dnsServers { dnsServers = servers }
        if activeInterface == nil, interfaces.isEmpty { return }
        switch InterfaceRefresh.decide(active: activeInterface, preferred: preferredInterfaceName,
                                       listed: interfaces, defaultGateway: gateway) {
        case .keep(let updated):
            if updated != activeInterface { activeInterface = updated }
        case .choose:
            // Interface disparue (ou choix de l'utilisateur revenu) : on relit les types (Wi-Fi, Ethernet).
            let withKinds = await LocalInterfaces.listWithKinds()
            let choice = InterfaceRefresh.pick(from: withKinds, preferred: preferredInterfaceName, defaultGateway: gateway)
            if choice != activeInterface { activeInterface = choice }
        }
    }

    // MARK: Pertinence (note 18)

    /// Plages cochées, lues.
    var checkedRanges: [IPRange] {
        ranges.filter(\.isEnabled).compactMap { try? $0.parsed() }
    }

    /// Réseau actuel (interface active, sous-réseau, passerelle).
    var currentNetwork: NetworkContext? {
        activeInterface.map(NetworkContext.init)
    }

    /// Part du bilan des switchs qui concerne les plages cochées, et si le réseau a changé depuis.
    func switchPresentation(_ result: SwitchAutoResult?) -> SwitchAutoPresentation? {
        result?.presentation(checked: checkedRanges, network: currentNetwork)
    }

    /// Noms saisis des plages (« 10.10.0.1-50 »), pour nommer les plages d'un bilan.
    var rangeNames: [IPRange: String] {
        var names: [IPRange: String] = [:]
        for config in ranges { if let range = try? config.parsed(), names[range] == nil { names[range] = config.text } }
        return names
    }

    /// État de l'emplacement (switch, port) d'un appareil : actuel seulement s'il a été relevé ou
    /// confirmé sur le réseau actuel et que sa plage est cochée. Même règle dans tous les écrans.
    func locationStatus(_ device: Device) -> LocationStatus {
        SwitchStore.shared.locations.status(of: device.ip, checked: checkedRanges, network: currentNetwork)
    }

    /// État du VLAN affiché (celui d'un emplacement relevé, ou celui de la plage).
    func vlanStatus(_ device: Device) -> LocationStatus {
        SwitchStore.shared.locations.vlanStatus(of: device.ip, hasSwitchLocation: device.switchName != nil,
                                                checked: checkedRanges, network: currentNetwork)
    }

    // MARK: Persistance

    private func save() {
        store?.save(StateStore.Snapshot(ranges: ranges, customNames: customNames))
    }
}

/// Enregistre les plages et les noms personnalisés en JSON dans
/// ~/Library/Application Support/NetScope/etat.json.
struct StateStore {
    struct Snapshot: Codable {
        var version = 1
        var ranges: [ScanRangeConfig]
        var customNames: [String: String]
    }

    let url: URL

    static var standard: StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return StateStore(url: base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("etat.json"))
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
    }
}
