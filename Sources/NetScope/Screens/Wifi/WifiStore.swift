import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

/// État de l'analyseur Wi-Fi. La connexion actuelle est lue localement (CoreWLAN, aucun trafic) ;
/// l'analyse des réseaux voisins (scanForNetworks) ne part que sur demande.
@MainActor
final class WifiStore: NSObject, ObservableObject {
    static let shared = WifiStore()

    struct Connection: Equatable {
        var interfaceName: String
        var network: WifiNetwork?
        var transmitRate: Double?
        var transmitPower: Int?
        var countryCode: String?
        var hardwareAddress: String?
        var powerOn: Bool
    }

    struct Roam: Identifiable, Equatable {
        let id = UUID()
        var time: Date
        var from: String
        var to: String
        var rssiBefore: Int
        var rssiAfter: Int
    }

    struct SurveyPoint: Identifiable, Equatable {
        let id = UUID()
        var room: String
        var rssi: Int
        var bssid: String
        var time: Date
    }

    @Published private(set) var connection: Connection?
    /// Aucune interface Wi-Fi sur ce Mac.
    @Published private(set) var noInterface = false
    @Published private(set) var networks: [WifiNetwork] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanCount = 0
    @Published private(set) var scanError: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Service de localisation actif pour tout le Mac.
    @Published private(set) var locationServicesEnabled = true
    /// Demande d'autorisation envoyée, réponse attendue.
    @Published private(set) var locationRequestPending = false
    /// La demande est restée sans réponse après le délai : la fenêtre n'a peut-être pas paru.
    @Published private(set) var locationRequestUnanswered = false
    /// RSSI de la connexion, toutes les 2 s, sur 2 minutes (nil : déconnecté).
    @Published private(set) var history: [Int?] = []
    @Published private(set) var roams: [Roam] = []
    @Published var surveyPoints: [SurveyPoint] = []
    @Published var surveyActive = false
    @Published var band: WifiBand = .ghz5
    @Published var selectedID: String?
    @Published var dismissed: Set<String> = []
    @Published var filter = ""
    @Published var tableFilter: WifiTableFilter = .all
    @Published var sortDescending = true
    @Published var toast: String?

    let isDemo: Bool
    private let locationManager = CLLocationManager()
    private var pendingTimeout: Task<Void, Never>?
    private var timer: Timer?
    private var lastBSSID: String?
    static let historyLength = 60

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        super.init()
        if demo {
            WifiDemo.apply(to: self)
        } else {
            locationManager.delegate = self
            authorization = locationManager.authorizationStatus
            updateLocationServicesEnabled()
        }
    }

    // MARK: Démonstration

    func loadDemo(connection: Connection, networks: [WifiNetwork], history: [Int?], roams: [Roam], points: [SurveyPoint]) {
        self.connection = connection
        self.networks = networks
        self.history = history
        self.roams = roams
        surveyPoints = points
        authorization = .authorizedAlways
        lastScan = Date().addingTimeInterval(-12)
        scanCount = 128
        band = .ghz24
        selectedID = networks.first { $0.band == .ghz24 && $0.channel == 6 && $0.ssid == "Bureau-Corp" }?.id
    }

    // MARK: Autorisation de localisation

    /// macOS masque le SSID et le BSSID tant que la localisation n'est pas autorisée.
    var locationAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorized
    }

    /// macOS ne donne pas le nom du réseau connecté. Un réseau connecté a toujours un nom (même
    /// caché) : s'il manque, c'est l'autorisation qui manque ou qui n'est pas encore prise en compte.
    /// Le bandeau s'affiche alors quel que soit l'état (y compris « autorisé », pour actualiser).
    var namesRedacted: Bool {
        guard let connection, connection.powerOn, let network = connection.network else { return false }
        return network.ssid == nil
    }

    /// État vu par NetScopeCore (service coupé dans macOS, non déterminé, refusé, restreint, autorisé).
    var locationStatus: WifiLocationStatus {
        let status: WifiLocationStatus
        switch authorization {
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        case .restricted: status = .restricted
        default: status = locationAuthorized ? .authorized : .notDetermined
        }
        return WifiLocationStatus.from(servicesEnabled: locationServicesEnabled, status: status)
    }

    /// Bouton et message du bandeau de localisation.
    var locationGuidance: WifiLocationGuidance {
        WifiLocationGuidance.make(status: locationStatus, requestPending: locationRequestPending,
                                  requestUnanswered: locationRequestUnanswered)
    }

    /// Bouton du bandeau : demande, ouvre les réglages ou actualise, selon l'état.
    func requestLocation() {
        perform(locationGuidance.action)
    }

    /// Second bouton du bandeau, s'il y en a un (« Redemander »).
    func requestLocationSecondary() {
        guard let action = locationGuidance.secondaryAction else { return }
        perform(action)
    }

    private func perform(_ action: WifiLocationAction) {
        guard !isDemo else { return }
        switch action {
        case .openSettings:
            if let url = URL(string: WifiLocationGuidance.settingsURL) { NSWorkspace.shared.open(url) }
        case .refresh:
            refresh()
            scan()
        case .request:
            askForAuthorization()
        }
        updateLocationServicesEnabled()
    }

    /// Sur macOS, requestWhenInUseAuthorization seul n'affiche pas toujours la fenêtre : une
    /// demande de position la déclenche (arrêtée dès la réponse ; la position n'est pas utilisée).
    private func askForAuthorization() {
        locationRequestPending = true
        locationRequestUnanswered = false
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
        pendingTimeout?.cancel()
        pendingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WifiLocationGuidance.promptTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.locationRequestPending,
                  self.locationManager.authorizationStatus == .notDetermined else { return }
            self.locationRequestUnanswered = true
        }
    }

    /// CLLocationManager.locationServicesEnabled() peut bloquer le fil principal : lu à part.
    private func updateLocationServicesEnabled() {
        Task.detached(priority: .utility) { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            await self?.setLocationServicesEnabled(enabled)
        }
    }

    private func setLocationServicesEnabled(_ enabled: Bool) {
        if locationServicesEnabled != enabled { locationServicesEnabled = enabled }
    }

    /// Réponse de macOS (locationManagerDidChangeAuthorization, seule voie) : met à jour le bandeau
    /// et relit les noms. Un état inchangé hors demande en cours ne relance rien.
    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard status != authorization || locationRequestPending else { return }
        authorization = status
        if status != .notDetermined {
            locationRequestPending = false
            locationRequestUnanswered = false
            pendingTimeout?.cancel()
            locationManager.stopUpdatingLocation()
        }
        updateLocationServicesEnabled()
        refresh()
        if locationAuthorized, !networks.isEmpty { scan() }
    }

    // MARK: Connexion actuelle (lecture locale)

    /// Commence à relire la connexion toutes les 2 s (écran visible seulement).
    func start() {
        guard !isDemo, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isDemo else { return }
        guard let iface = CWWiFiClient.shared().interface() else {
            noInterface = true
            connection = nil
            return
        }
        noInterface = false
        let powerOn = iface.powerOn()
        var network: WifiNetwork?
        if powerOn, let channel = iface.wlanChannel(), iface.rssiValue() != 0 {
            let bssid = iface.bssid().flatMap(MACAddress.init)
            network = WifiNetwork(ssid: iface.ssid(), bssid: bssid, channel: channel.channelNumber,
                                  band: WifiMapping.band(channel), widthMHz: WifiMapping.width(channel),
                                  rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                                  security: WifiMapping.security(iface.security()), standard: WifiMapping.phy(iface.activePHYMode()),
                                  isConnected: true)
        }
        let updated = Connection(interfaceName: iface.interfaceName ?? "en0", network: network,
                                 transmitRate: powerOn ? iface.transmitRate() : nil,
                                 transmitPower: powerOn ? iface.transmitPower() : nil,
                                 countryCode: iface.countryCode(), hardwareAddress: iface.hardwareAddress(), powerOn: powerOn)
        trackRoaming(old: connection?.network, new: network)
        connection = updated
        history.append(network?.rssi)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func trackRoaming(old: WifiNetwork?, new: WifiNetwork?) {
        guard let new, let bssid = new.bssid?.formatted(.upperColon) else { return }
        defer { lastBSSID = bssid }
        guard let previous = lastBSSID, previous != bssid, let old else { return }
        roams.append(Roam(time: Date(), from: "\(previous) (canal \(old.channel))", to: "\(bssid) (canal \(new.channel))",
                          rssiBefore: old.rssi, rssiAfter: new.rssi))
    }

    // MARK: Analyse à la demande

    func scan() {
        guard !isScanning else { return }
        if isDemo {
            scanCount += 1
            lastScan = Date()
            return
        }
        isScanning = true
        scanError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[WifiNetwork], Error> in
                guard let iface = CWWiFiClient.shared().interface() else {
                    return .failure(WifiScanError.noInterface)
                }
                do {
                    let found = try iface.scanForNetworks(withSSID: nil)
                    return .success(found.map(WifiMapping.network))
                } catch {
                    return .failure(error)
                }
            }.value
            isScanning = false
            switch result {
            case .success(var found):
                // BSSID masqués (localisation refusée) : identifiants rendus uniques.
                var seen = Set<String>()
                for k in found.indices where !seen.insert(found[k].id).inserted { found[k].id += "-\(k)" }
                if let current = connection?.network {
                    for k in found.indices where found[k].matches(current) { found[k].isConnected = true }
                    if !found.contains(where: \.isConnected) { found.append(current) }
                }
                networks = found
                lastScan = Date()
                scanCount += 1
                if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
                    let pick = found.first(where: \.isConnected) ?? found.max { $0.rssi < $1.rssi }
                    selectedID = pick?.id
                    if let pick { band = pick.band }
                }
            case .failure(let error):
                scanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Dérivés

    var connected: WifiNetwork? {
        networks.first(where: \.isConnected) ?? connection?.network
    }

    var recommendations: [WifiRecommendation] {
        var list = WifiAdvisor.recommendations(networks: networks.isEmpty ? connection?.network.map { [$0] } ?? [] : networks,
                                               connected: connected)
        if namesRedacted { list.removeAll { $0.id == "cache" || $0.id.hasPrefix("jumeau-") } }
        return list.filter { !dismissed.contains($0.id) }
    }

    func label(for network: WifiNetwork) -> String {
        if namesRedacted, network.isHidden { return "(nom masqué par macOS)" }
        return network.displaySSID
    }

    func isSuspicious(_ network: WifiNetwork) -> Bool {
        WifiAdvisor.suspiciousTwins(networks, connected: connected).contains { $0.id == network.id }
    }

    func focus(_ recommendation: WifiRecommendation) {
        if let band = recommendation.band { self.band = band }
        if let id = recommendation.networkID { selectedID = id }
    }

    // MARK: Relevé de couverture

    func addSurveyPoint(room: String) {
        guard let network = connection?.network else { return }
        let name = room.trimmingCharacters(in: .whitespaces)
        surveyPoints.append(SurveyPoint(room: name.isEmpty ? "Point \(surveyPoints.count + 1)" : name, rssi: network.rssi,
                                        bssid: network.bssid?.formatted(.upperColon) ?? "—", time: Date()))
    }

    // MARK: Export

    /// Note 71 : colonnes des éléments de la balise (vides quand macOS ne les fournit pas).
    private func beaconFields(_ network: WifiNetwork) -> [String] {
        guard let beacon = network.beacon else { return Array(repeating: "", count: 8) }
        func yes(_ value: Bool) -> String { value ? "oui" : "non" }
        return [beacon.generation(band: network.band).label, yes(beacon.supports11k), yes(beacon.supports11v), yes(beacon.supports11r),
                beacon.bssLoad.map { String($0.utilizationPercent) } ?? "", beacon.bssLoad.map { String($0.stationCount) } ?? "",
                beacon.pmf.label, beacon.apName ?? ""]
    }

    func exportCSV() {
        var lines = ["SSID;BSSID;Fabricant;Canal;Largeur (MHz);Bande;RSSI (dBm);Bruit (dBm);Sécurité;Norme;Connecté;"
                     + "Génération;802.11k;802.11v;802.11r;Utilisation du canal (%);Clients;PMF;Nom de la borne"]
        for network in networks.sorted(by: { $0.rssi > $1.rssi }) {
            let fields = [label(for: network), network.bssid?.formatted(.upperColon) ?? "", WifiText.vendor(network),
                          String(network.channel), String(network.widthMHz), network.band.label, String(network.rssi),
                          network.noise.map(String.init) ?? "", network.security.label, network.standard ?? "",
                          network.isConnected ? "oui" : "non"] + beaconFields(network)
            lines.append(fields.map(CSVText.field).joined(separator: ";"))
        }
        if !surveyPoints.isEmpty {
            lines.append("")
            lines.append("Relevé de couverture;RSSI (dBm);BSSID;Heure")
            for point in surveyPoints {
                lines.append([point.room, String(point.rssi), point.bssid, WifiText.time(point.time)].map(CSVText.field).joined(separator: ";"))
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wifi-analyse.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            toast = "Export enregistré\u{00A0}: \(url.lastPathComponent) (\(networks.count) BSSID)."
        } catch {
            toast = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }
}

extension WifiStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    /// Exigé par requestLocation : la position elle-même n'est pas utilisée.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
    }

    /// Refus ou position introuvable : la demande de position s'arrête ; le nouvel état arrive
    /// par locationManagerDidChangeAuthorization (pas de second rafraîchissement ici).
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
    }
}

enum WifiTableFilter: Hashable {
    case all, band, flagged
}

enum WifiScanError: LocalizedError {
    case noInterface

    var errorDescription: String? { "Aucune interface Wi-Fi active sur ce Mac." }
}

extension WifiNetwork {
    /// Même BSSID, ou même SSID et canal quand le BSSID est masqué.
    func matches(_ other: WifiNetwork) -> Bool {
        if let a = bssid, let b = other.bssid { return a == b }
        return ssid == other.ssid && channel == other.channel && band == other.band
    }
}

// MARK: - Correspondance CoreWLAN → NetScopeCore

enum WifiMapping {
    static func band(_ channel: CWChannel) -> WifiBand {
        switch channel.channelBand {
        case .band2GHz: return .ghz24
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return WifiBand.guess(channel: channel.channelNumber)
        }
    }

    static func width(_ channel: CWChannel) -> Int {
        switch channel.channelWidth {
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return 20
        }
    }

    static func security(_ value: CWSecurity) -> WifiSecurity {
        switch value {
        case .none: return .open
        case .WEP, .dynamicWEP: return .wep
        case .wpaPersonal, .wpaPersonalMixed: return .wpaPersonal
        case .wpa2Personal, .personal: return .wpa2Personal
        case .wpa3Personal: return .wpa3Personal
        case .wpa3Transition: return .wpa3Transition
        case .wpaEnterprise, .wpaEnterpriseMixed: return .wpaEnterprise
        case .wpa2Enterprise, .enterprise: return .wpa2Enterprise
        case .wpa3Enterprise: return .wpa3Enterprise
        case .OWE, .oweTransition: return .owe
        default: return .unknown
        }
    }

    /// Sécurité annoncée par un réseau voisin : la plus forte prise en charge.
    static func security(of network: CWNetwork) -> WifiSecurity {
        let order: [(CWSecurity, WifiSecurity)] = [
            (.wpa3Enterprise, .wpa3Enterprise), (.wpa3Transition, .wpa3Transition), (.wpa3Personal, .wpa3Personal),
            (.wpa2Enterprise, .wpa2Enterprise), (.wpaEnterprise, .wpaEnterprise), (.enterprise, .wpa2Enterprise),
            (.wpa2Personal, .wpa2Personal), (.wpaPersonal, .wpaPersonal), (.personal, .wpa2Personal),
            (.OWE, .owe), (.oweTransition, .owe), (.dynamicWEP, .wep), (.WEP, .wep), (.none, .open),
        ]
        for (security, mapped) in order where network.supportsSecurity(security) { return mapped }
        return .unknown
    }

    static func phy(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        default: return nil
        }
    }

    static func standard(of network: CWNetwork) -> String? {
        for mode in [CWPHYMode.mode11ax, .mode11ac, .mode11n, .mode11g, .mode11a, .mode11b] where network.supportsPHYMode(mode) {
            return phy(mode)
        }
        return nil
    }

    static func network(_ network: CWNetwork) -> WifiNetwork {
        let channel = network.wlanChannel
        // Note 71 : éléments de la balise (nil tant que la localisation n'est pas autorisée,
        // comme le BSSID). Ils précisent la norme (Wi-Fi 7) et la largeur (320 MHz) que CoreWLAN ignore.
        let beacon = network.informationElementData.map(WifiBeaconParser.parse)
        let resolvedBand = channel.map(band) ?? .ghz24
        var standard = standard(of: network)
        if let generation = beacon?.generation(band: resolvedBand), generation >= .wifi4,
           standard.map({ WifiGeneration.from(standard: $0) < generation }) ?? true {
            standard = generation.standard
        }
        var widthMHz = channel.map(width) ?? 20
        if let announced = beacon?.channelWidthMHz, announced > widthMHz { widthMHz = announced }
        return WifiNetwork(ssid: network.ssid, bssid: network.bssid.flatMap(MACAddress.init),
                           channel: channel?.channelNumber ?? 0,
                           band: resolvedBand, widthMHz: widthMHz,
                           rssi: network.rssiValue, noise: network.noiseMeasurement,
                           security: security(of: network), standard: standard, beacon: beacon)
    }
}
