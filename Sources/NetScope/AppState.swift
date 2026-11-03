import Foundation
import NetScopeCore
import SwiftUI

/// Informations sur l'application.
enum AppInfo {
    /// Version lue dans Info.plist ; « 0.2.1 » quand l'exécutable tourne hors de son paquet (.build/).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1"
    }
}

/// État partagé de l'application : écran courant, appareils, plages, sélection.
/// Une seule instance, injectée par `.environmentObject` ; tous les écrans la lisent.
@MainActor
final class AppState: ObservableObject {
    // MARK: Navigation

    @Published var screen: Screen = .scanner
    /// Recherche globale (barre d'outils du contenu) : IP, MAC, nom, fabricant, port de switch.
    @Published var searchText = ""

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

    /// Appareils filtrés par la recherche globale.
    var filteredDevices: [Device] {
        devices.filter { $0.matches(searchText) }
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
        }
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
