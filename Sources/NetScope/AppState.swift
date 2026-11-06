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

    @Published var screen: Screen = .scanner {
        // Notes 31, 33 et 34 : chaque changement d'écran est retenu pour Retour (⌘[).
        didSet {
            // Speedtest est devenu un outil : l'ancien écran ouvre la Boîte à outils sur cet outil.
            if screen == .speedtest {
                ToolStore.shared.selectedTool = .speedtest
                screen = .outils
            }
            screenChanged(from: oldValue)
        }
    }
    /// Recherche de la barre d'outils, propre à chaque module (note 26) : les préfixes
    /// (`switch:`, `type:`…) dépendent du module, une recherche du Scanner ne filtre pas les Réglages.
    @Published var searchTexts: [Screen: String] = [:]
    /// Note 32 : dernière validation du champ de recherche (↩︎ suivant, ⇧↩︎ précédent).
    @Published var searchSubmit = SearchSubmit()

    // MARK: Navigation entre les modules (notes 31, 33 et 34 ; Shared/Navigation.swift)

    /// Filtre transmis à un écran (ensemble exact d'appareils : groupe de la Carte, port de switch),
    /// affiché comme une étiquette retirable de la recherche.
    @Published var navFilters: [Screen: NavFilter] = [:]
    /// Historique Retour / Avancer.
    @Published var history = NavHistory(limit: 50)
    /// Liste à choisir ou message d'un double-clic (plusieurs appareils sur un port, port vide…).
    @Published var navPrompt: NavPrompt?
    /// Ce que l'écran d'arrivée doit montrer (nœud de la Carte…), lu puis effacé par l'écran.
    @Published var pendingFocus: [Screen: NavFocus] = [:]
    /// Ce que montre chaque écran (fiche d'inventaire, nœud de la Carte), pour que Retour le rende.
    var shownFocus: [Screen: NavFocus] = [:]
    /// Vrai pendant une restauration (Retour, Avancer) ou une navigation qui a déjà retenu l'endroit quitté.
    var isNavigating = false
    /// Faux pendant les captures (le défilement des écrans n'est pas un parcours de l'utilisateur).
    var recordsHistory = !CommandLine.arguments.contains("--snapshot")

    /// Recherche de l'écran courant (champ de la barre d'outils).
    var searchText: String {
        get { searchTexts[screen] ?? "" }
        set { searchTexts[screen] = newValue.isEmpty ? nil : newValue }
    }

    /// Validation du champ de recherche de l'écran courant (↩︎, ou ⇧↩︎ pour revenir en arrière).
    func submitSearch(backwards: Bool) {
        searchSubmit = SearchSubmit(screen: screen, backwards: backwards, serial: searchSubmit.serial + 1)
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

    // MARK: Appareils hors Scanner (écran Appareil, « Ouvrir une fiche »)

    /// Appareils ouverts dans l'écran Appareil sans être dans les résultats du Scanner : saisis à
    /// la main, ou repris d'une fiche d'inventaire ou d'un autre site. Jamais mêlés à `devices`.
    /// Tous les sites : `siteManualDevices` donne ceux du site actif.
    @Published private(set) var manualDevices: [ManualDeviceEntry] = [] {
        didSet { saveManual() }
    }
    /// Appareils consultés récemment dans l'écran Appareil.
    @Published private(set) var recentDeviceViews: [DeviceRecentView] = [] {
        didSet { saveManual() }
    }
    /// Message de la fiche d'un appareil (« saisie rattachée à l'appareil scanné »).
    @Published var deviceNotice: (deviceID: Device.ID, text: String)?

    private let store: StateStore?
    private let manualStore: ManualDeviceStore?
    /// Faux pendant la lecture du fichier : rien n'est réécrit avant.
    private var manualLoaded = false

    /// `store` nil : rien n'est lu ni écrit sur le disque (captures, démonstration).
    init(store: StateStore? = StateStore.standard) {
        self.store = store
        let saved = store?.load()
        ranges = saved?.ranges ?? AppState.defaultRanges
        customNames = saved?.customNames ?? [:]
        isFirstLaunch = saved == nil
        manualStore = store == nil ? nil : ManualDeviceStore.standard
        if let kept = manualStore?.load() {
            manualDevices = kept.entries
            recentDeviceViews = kept.recents
        }
        manualLoaded = true
    }

    /// Note 86 : appareils saisis reçus d'un autre Mac, relus sans redémarrer (les consultations
    /// récentes restent celles de ce Mac).
    func reloadManualFromDisk() {
        guard let kept = manualStore?.load(), kept.entries != manualDevices else { return }
        manualDevices = kept.entries
    }

    /// Vrai si aucun état n'était enregistré : les plages par défaut seront remplacées par le réseau détecté.
    private(set) var isFirstLaunch: Bool

    static let defaultRanges = [ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau", vlan: 1)]

    // MARK: Actions

    func open(_ screen: Screen) {
        self.screen = screen
    }

    /// Appareil de la fiche : celui du Scanner, sinon un appareil ouvert à la main (même IP).
    var selectedDevice: Device? {
        guard let id = selectedDeviceID else { return nil }
        return shownDevice(withID: id)
    }

    /// Appareil choisi, seulement s'il est dans les résultats du Scanner (outils qui modifient
    /// les résultats : sonde de ports, panneau de détail du Scanner).
    var selectedScannedDevice: Device? {
        guard let id = selectedDeviceID else { return nil }
        return device(withID: id)
    }

    /// Appareil des résultats du Scanner (site actif) ; jamais une saisie à la main.
    func device(withID id: Device.ID) -> Device? {
        devices.first { $0.id == id }
    }

    /// Appareil affiché par l'écran Appareil : celui du Scanner, sinon la saisie à la main (ou la
    /// fiche reprise) du site actif. Seuls la fiche et ses consultations récentes s'en servent.
    func shownDevice(withID id: Device.ID) -> Device? {
        device(withID: id) ?? manualEntry(forID: id)?.device
    }

    /// Met à jour les ports ouverts de l'appareil d'une fiche après un outil : par `merge` s'il est
    /// dans les résultats du Scanner, sinon dans sa saisie (jamais ajoutée à `devices`).
    func updateShownPorts(of id: Device.ID, seen: Bool, _ ports: ([UInt16]) -> [UInt16]) {
        if var device = device(withID: id) {
            device.openPorts = ports(device.openPorts)
            if seen {
                device.isOnline = true
                device.lastSeen = Date()
            }
            merge([device])
        } else if var entry = manualEntry(forID: id) {
            entry.openPorts = ports(entry.device.openPorts)
            updateManual(entry)
        }
    }

    /// Ouvre la fiche d'un appareil (retenu pour Retour, comme toute navigation).
    func showDevice(_ id: Device.ID) {
        navigate(NavDestination(.appareil, focus: .device(id)))
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
        let found = DeviceSearch.filter(devices, searchQuery(for: .scanner))
        // Filtre transmis (groupe de la Carte, port) : exactement ces appareils.
        guard let filter = navFilters[.scanner] else { return found }
        return found.filter { filter.matches($0) }
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
        // Seuls les appareils qui répondent sont « vus » (pas ceux qu'un scan marque hors ligne).
        attachManualDevices(seen: incoming.filter(\.isOnline))
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

    // MARK: Appareils hors Scanner

    /// Saisies à la main et fiches reprises du site actif.
    var siteManualDevices: [ManualDeviceEntry] {
        ManualDevices.visible(manualDevices, site: SiteModel.shared.activeKey)
    }

    /// Consultations récentes du site actif.
    var siteRecentDeviceViews: [DeviceRecentView] {
        let site = SiteModel.shared.activeKey
        return recentDeviceViews.filter { $0.siteKey == nil || $0.siteKey == site }
    }

    /// Saisie à la main (ou reprise) du site actif pour cet identifiant, si le Scanner n'a pas
    /// d'appareil à cette IP.
    func manualEntry(forID id: Device.ID) -> ManualDeviceEntry? {
        guard !manualDevices.isEmpty, !devices.contains(where: { $0.id == id }) else { return nil }
        let site = SiteModel.shared.activeKey
        return manualDevices.first { $0.deviceID == id && $0.belongs(to: site) }
    }

    /// Retient l'appareil (même site et même IP : il remplace l'ancien), écrit ses notes et ouvre sa fiche.
    func openManual(_ entry: ManualDeviceEntry, notes: String = "") {
        var entry = entry
        if entry.siteKey == nil { entry.siteKey = SiteModel.shared.activeKey }
        manualDevices = ManualDevices.upsert(entry, into: manualDevices)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { DeviceNotesStore.shared.setNote(trimmed, for: entry.device) }
        showDevice(entry.deviceID)
    }

    /// Modifie un appareil saisi (nom, type, vérification), sans changer sa place dans la liste.
    func updateManual(_ entry: ManualDeviceEntry) {
        guard let index = manualDevices.firstIndex(where: { $0.id == entry.id }) else { return }
        manualDevices[index] = entry
    }

    /// Oublie une saisie ; sa fiche se ferme si elle était ouverte (ses notes restent au site).
    func forgetManual(_ entry: ManualDeviceEntry) {
        manualDevices.removeAll { $0.id == entry.id }
        if selectedDeviceID == entry.deviceID, !devices.contains(where: { $0.id == entry.deviceID }) {
            selectedDeviceID = nil
        }
    }

    /// Retient la consultation d'une fiche (liste « Consultés récemment »).
    func recordDeviceView(_ device: Device) {
        let view = DeviceRecentView(device: device, viewed: Date(), isManual: manualEntry(forID: device.id) != nil,
                                    siteKey: SiteModel.shared.activeKey)
        if let first = recentDeviceViews.first, first.ip == view.ip, first.mac == view.mac, first.name == view.name,
           first.siteKey == view.siteKey, Date().timeIntervalSince(first.viewed) < 60 { return }
        recentDeviceViews = DeviceRecents.record(view, in: recentDeviceViews)
    }

    /// Démonstration et captures : appareils hors Scanner et consultations de départ.
    func setManualDemo(_ entries: [ManualDeviceEntry], recents: [DeviceRecentView]) {
        manualDevices = entries
        recentDeviceViews = recents
    }

    /// Un scan a vu ces appareils : chaque saisie qui correspond (même MAC, sinon même IP) leur est
    /// rattachée. Le nom saisi devient leur nom (s'ils n'en ont pas), les notes sont réunies.
    private func attachManualDevices(seen incoming: [Device]) {
        guard !manualDevices.isEmpty, !incoming.isEmpty else { return }
        let ids = Set(incoming.map(\.id))
        let scanned = devices.filter { ids.contains($0.id) }
        // Seulement les saisies du site actif : une saisie d'un autre site désigne un autre appareil.
        let result = ManualDevices.attach(siteManualDevices, to: scanned)
        guard !result.attached.isEmpty else { return }
        let notes = DeviceNotesStore.shared
        let inventory = InvModel.shared
        for attachment in result.attached {
            if let name = attachment.customName { setCustomName(name, for: attachment.deviceID) }
            guard let device = devices.first(where: { $0.id == attachment.deviceID }) else { continue }
            // Type choisi dans la saisie : gardé comme type choisi à la main (sauf si l'appareil en a déjà un).
            if attachment.entry.isTyped, attachment.entry.type != .inconnu, !inventory.typeChoice(for: device).isManual {
                _ = inventory.setManualType(attachment.entry.type, for: [device], all: devices)
            }
            let typedDevice = attachment.entry.device
            let typed = notes.note(for: typedDevice)
            let current = notes.note(for: device)
            let merged = ManualDevices.mergedNotes(scanned: current, typed: typed, nameForNotes: attachment.nameForNotes)
            if merged != current { notes.setNote(merged, for: device) }
            if !typed.isEmpty, DeviceNotesStore.key(for: typedDevice) != DeviceNotesStore.key(for: device) {
                notes.setNote("", for: typedDevice)
            }
            if selectedDeviceID == attachment.entry.deviceID { selectedDeviceID = device.id }
            deviceNotice = (device.id, "«\u{00A0}\(device.displayName)\u{00A0}» vu par le scan\u{00A0}: la saisie est rattachée à \(device.ip)\u{00A0}; le nom et les notes saisis sont gardés.")
        }
        let attachedIDs = Set(result.attached.map(\.entry.id))
        manualDevices.removeAll { attachedIDs.contains($0.id) }
    }

    // MARK: Persistance

    private func save() {
        store?.save(StateStore.Snapshot(ranges: ranges, customNames: customNames))
    }

    private func saveManual() {
        guard manualLoaded else { return }
        manualStore?.save(ManualDeviceStore.Snapshot(entries: manualDevices, recents: recentDeviceViews))
    }
}

/// Appareils saisis à la main et consultations récentes de l'écran Appareil, en JSON dans
/// ~/Library/Application Support/NetScope/appareils-saisis.json.
struct ManualDeviceStore {
    struct Snapshot: Codable {
        static let currentVersion = 1
        var version = Snapshot.currentVersion
        var entries: [ManualDeviceEntry]
        var recents: [DeviceRecentView]
    }

    let url: URL

    static var standard: ManualDeviceStore {
        ManualDeviceStore(url: StateStore.standard.url.deletingLastPathComponent().appendingPathComponent("appareils-saisis.json"))
    }

    /// Lit le fichier. Absent : nil. Illisible (abîmé, ou d'une version plus récente) : il est mis
    /// de côté en « .bak » (et noté au journal) avant que la prochaine écriture ne le remplace.
    func load() -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            guard snapshot.version <= Snapshot.currentVersion else {
                throw CocoaError(.fileReadCorruptFile,
                                 userInfo: [NSLocalizedDescriptionKey: "version \(snapshot.version) inconnue de cette version de NetScope"])
            }
            return snapshot
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            let moved = (try? FileManager.default.moveItem(at: url, to: backup)) != nil
            AppLog.shared.error("Appareil", "Appareils saisis illisibles (\(url.lastPathComponent))\u{00A0}: \(error.localizedDescription)"
                                + (moved ? "\u{00A0}; copie gardée dans \(backup.lastPathComponent)." : "."))
            return nil
        }
    }

    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("Appareil", "Enregistrement impossible de \(url.path)\u{00A0}: \(error.localizedDescription)")
        }
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
            AppLog.shared.error("État", "Enregistrement impossible de \(url.path) : \(error.localizedDescription)")
        }
    }
}
