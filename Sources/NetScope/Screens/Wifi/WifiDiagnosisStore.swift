import Foundation
import NetScopeCore

/// Ce qu'on diagnostique (note 47) : un client, une borne ou un SSID d'une lecture FortiAP.
struct WifiDiagnosisTarget: Identifiable {
    enum Kind {
        case client(FortiWifiClient, WifiClientDetails?)
        case ap(FortiManagedAP)
        case ssid(FortiSSID)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .client(let c, _): return "client|" + c.id
        case .ap(let a): return "borne|" + a.id
        case .ssid(let s): return "ssid|" + s.id
        }
    }

    var site: String {
        switch kind {
        case .client(let c, _): return c.site
        case .ap(let a): return a.site
        case .ssid(let s): return s.site
        }
    }

    var title: String {
        switch kind {
        case .client(let c, _): return c.displayName
        case .ap(let a): return a.name
        case .ssid(let s): return "«\u{00A0}\(s.ssid)\u{00A0}»"
        }
    }

    static func client(_ c: FortiWifiClient, details: WifiClientDetails? = nil) -> WifiDiagnosisTarget { .init(kind: .client(c, details)) }
    static func ap(_ a: FortiManagedAP) -> WifiDiagnosisTarget { .init(kind: .ap(a)) }
    static func ssid(_ s: FortiSSID) -> WifiDiagnosisTarget { .init(kind: .ssid(s)) }
}

/// Diagnostic Wi-Fi (note 47) : lance le diagnostic d'un client, d'une borne ou d'un SSID à partir
/// de la dernière lecture des FortiGate (FortiAPStore), du port de la borne (FortiGateStore), de
/// l'étendue DHCP (DHCPScopeStore) et, si on le veut, de pings de quelques secondes depuis ce Mac.
/// Lecture seule : rien n'est envoyé à la FortiGate.
///
/// Suivi dans le temps : les derniers diagnostics de chaque client, borne ou SSID sont gardés dans
/// le dossier du site (sites/<id>/diagnostics-wifi.json), avec ceux retenus pour le rapport.
/// En démonstration et pendant les captures, rien n'est lu ni écrit et aucun ping n'est envoyé :
/// les mesures viennent de WifiDiagnosisDemo.
@MainActor
final class WifiDiagnosisStore: ObservableObject {
    static let shared = WifiDiagnosisStore()

    /// Historique de chaque site, chargé à la demande (clé du site) ; pas publié : la lecture du
    /// fichier peut se faire pendant le dessin d'une vue. `revision` annonce les changements.
    private var histories: [String: WifiDiagnosisHistory] = [:]
    @Published private(set) var revision = 0
    /// Ping depuis ce Mac pendant le diagnostic (préférence).
    @Published var pingEnabled: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(pingEnabled, forKey: Self.pingKey) } }
    }

    let isDemo: Bool
    private static let pingKey = "NetScope.wifi.diagnostic.ping"
    /// Durée des pings vers chaque cible (en même temps).
    static let pingSeconds: TimeInterval = 4

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        pingEnabled = demo ? true : (UserDefaults.standard.object(forKey: Self.pingKey) as? Bool ?? true)
        if demo { histories = WifiDiagnosisDemo.histories() }
    }

    // MARK: Sites et historique

    /// Clé du site d'une cible : celui de sa FortiGate (comme l'historique du signal).
    func siteKey(for target: WifiDiagnosisTarget) -> String {
        let fortiAP = FortiAPStore.shared
        switch target.kind {
        case .client(let c, _): return fortiAP.siteKey(for: c)
        case .ap(let a): return fortiAP.siteKey(forLabel: a.site)
        case .ssid(let s): return fortiAP.siteKey(forLabel: s.site)
        }
    }

    /// Clé du site d'un diagnostic : celle résolue au diagnostic, sinon d'après son libellé.
    func siteKey(of result: WifiDiagnosisResult) -> String {
        result.siteKey ?? FortiAPStore.shared.siteKey(forLabel: result.site)
    }

    private func url(for key: String) -> URL? {
        SiteModel.shared.files?.folder(for: key).appendingPathComponent(WifiDiagnosisHistory.fileName)
    }

    func history(forKey key: String) -> WifiDiagnosisHistory {
        if let loaded = histories[key] { return loaded }
        guard !isDemo, let url = url(for: key) else { return WifiDiagnosisHistory() }
        let loaded = WifiDiagnosisHistory.load(from: url)
        histories[key] = loaded
        return loaded
    }

    func history(of result: WifiDiagnosisResult) -> WifiDiagnosisHistory { history(forKey: siteKey(of: result)) }

    private func update(_ key: String, _ change: (inout WifiDiagnosisHistory) -> Void) {
        var h = history(forKey: key)
        change(&h)
        histories[key] = h
        revision += 1
        guard !isDemo, let url = url(for: key) else { return }
        do {
            try h.save(to: url)
        } catch {
            AppLog.shared.error("Wi-Fi", "Historique des diagnostics Wi-Fi non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Garde le diagnostic dans le suivi du site.
    func record(_ result: WifiDiagnosisResult, rssi: Int?) {
        update(siteKey(of: result)) { $0.add(result, rssi: rssi) }
    }

    /// « Ajouter au rapport du site » : retenu pour la section « Diagnostic Wi-Fi » (cochée).
    func addToReport(_ result: WifiDiagnosisResult) {
        update(siteKey(of: result)) { $0.report(result) }
        RapportModel.shared.config.sections.insert(.wifiDiag)
    }

    func removeFromReport(_ result: WifiDiagnosisResult) {
        update(siteKey(of: result)) { $0.unreport(result.subject.key) }
    }

    func isReported(_ result: WifiDiagnosisResult) -> Bool {
        history(of: result).isReported(result)
    }

    /// Diagnostics retenus pour le rapport d'un site.
    func reported(forKey key: String) -> [WifiDiagnosisResult] { history(forKey: key).reported }

    // MARK: Diagnostic

    /// Diagnostic immédiat (sans ping), puis, si demandé, avec les pings de ce Mac.
    func diagnose(_ target: WifiDiagnosisTarget, paths: [WifiPathMeasure], state: AppState) -> WifiDiagnosisResult {
        var result = diagnoseNow(target, paths: paths, state: state)
        result.siteKey = siteKey(for: target)
        return result
    }

    /// Client d'une cible relu dans la lecture la plus récente (signal, borne, bande, radio à jour).
    func currentClient(_ client: FortiWifiClient) -> FortiWifiClient {
        let overview = FortiAPStore.shared.shownOverview.clients.contains(where: { $0.site == client.site })
            ? FortiAPStore.shared.shownOverview : FortiAPStore.shared.overview
        return overview.clients.first { $0.mac == client.mac && $0.site == client.site } ?? client
    }

    /// Détails d'un client : ceux donnés par l'appelant, sinon les mêmes que la fiche du client
    /// (historique du signal du site ; en démonstration, complétés par WifiDiagnosisDemo).
    func details(for client: FortiWifiClient, given: WifiClientDetails?) -> WifiClientDetails {
        if let given { return given }
        let details = WifiClientDetails(client: client, history: FortiAPStore.shared.signalHistory(for: client))
        return isDemo ? details.filling(from: WifiDiagnosisDemo.details(for: client)) : details
    }

    private func diagnoseNow(_ target: WifiDiagnosisTarget, paths: [WifiPathMeasure], state: AppState) -> WifiDiagnosisResult {
        let fortiAP = FortiAPStore.shared
        let overview = overview(for: target)
        let thresholds = WifiDiagnosisThresholds(forti: fortiAP.thresholds)
        switch target.kind {
        case .client(let stale, let given):
            let client = currentClient(stale)
            var measures = baseMeasures(ap: overview.ap(for: client), vlan: client.vlan, ip: client.ip, site: client.site, state: state)
            measures.paths = paths
            let known = details(for: client, given: given)
            let input = WifiDiagnosisInput.from(overview: overview, client: client, details: known, measures: measures)
            return WifiDiagnosis.diagnose(input, thresholds: thresholds)
        case .ap(let ap):
            var measures = baseMeasures(ap: ap, vlan: nil, ip: nil, site: ap.site, state: state)
            measures.paths = paths
            return WifiDiagnosis.diagnose(ap: ap, overview: overview, measures: measures, thresholds: thresholds)
        case .ssid(let ssid):
            var measures = baseMeasures(ap: nil, vlan: ssid.vlan, ip: nil, site: ssid.site, state: state)
            measures.paths = paths
            return WifiDiagnosis.diagnose(ssid: ssid, overview: overview, measures: measures, thresholds: thresholds)
        }
    }

    /// Lecture qui contient la cible : la vue de l'écran Wi-Fi (autre site compris), sinon celle du site actif.
    private func overview(for target: WifiDiagnosisTarget) -> FortiWifiOverview {
        let store = FortiAPStore.shared
        let site = target.site
        if store.shownOverview.aps.contains(where: { $0.site == site }) || store.shownOverview.clients.contains(where: { $0.site == site }) {
            return store.shownOverview
        }
        return store.overview
    }

    /// Port du switch de la borne, étendue DHCP du VLAN, changements DFS (lectures déjà faites, aucun réseau).
    private func baseMeasures(ap: FortiManagedAP?, vlan: Int?, ip: IPv4Address?, site: String, state: AppState) -> WifiDiagnosisMeasures {
        var m = isDemo ? WifiDiagnosisDemo.measures(ap: ap, vlan: vlan, site: site, state: state) : WifiDiagnosisMeasures()
        if !isDemo, let ap { m.uplink = uplink(of: ap, state: state) }
        m.dhcp = dhcpScope(vlan: vlan, ip: ip, site: site, state: state)
        return m
    }

    /// Port FortiSwitch où la borne est branchée : appareil du scan à l'adresse de la borne, puis son
    /// switch et son port dans la dernière lecture des FortiGate (note 33).
    func uplink(of ap: FortiManagedAP, state: AppState) -> WifiUplinkStatus? {
        guard let ip = ap.ip, let device = state.device(withID: ip.description),
              let switchName = device.switchName, let portName = device.switchPort else { return nil }
        let key = switchName.lowercased()
        for site in FortiGateStore.shared.sites {
            for sw in site.report.switches where sw.keys.contains(key) {
                if let port = sw.port(named: portName) { return WifiUplinkStatus(switchName: sw.name, port: port) }
            }
        }
        return nil
    }

    /// Étendue DHCP du client (par son adresse) ou du SSID (par son VLAN).
    func dhcpScope(vlan: Int?, ip: IPv4Address?, site: String, state: AppState) -> WifiDHCPStatus? {
        let scopes = DHCPScopeStore.shared.overview(devices: state.devices).scopes.filter { $0.level != .inactive }
        let sameSite = scopes.filter { $0.site.isEmpty || $0.site == site }
        let pool = sameSite.isEmpty ? scopes : sameSite
        if let ip, let usage = pool.first(where: { $0.subnet?.contains(ip) == true }) { return WifiDHCPStatus(usage: usage) }
        if let vlan, let usage = pool.first(where: { $0.vlan == vlan }) { return WifiDHCPStatus(usage: usage) }
        return nil
    }

    /// Adresses pingées depuis ce Mac : passerelle, premier DNS, 1.1.1.1.
    func pingTargets(state: AppState) -> [(WifiPathTarget, IPv4Address)] {
        var targets: [(WifiPathTarget, IPv4Address)] = []
        if let gateway = state.activeInterface?.gateway { targets.append((.gateway, gateway)) }
        if let dns = state.dnsServers.first(where: { $0 != state.activeInterface?.gateway }) ?? state.dnsServers.first {
            targets.append((.dns, dns))
        }
        if let internet = IPv4Address("1.1.1.1") { targets.append((.internet, internet)) }
        return targets
    }

    /// Pings de quelques secondes, en même temps, vers chaque cible. Jamais en démonstration.
    func measurePaths(state: AppState) async -> [WifiPathMeasure] {
        if isDemo { return WifiDiagnosisDemo.paths() }
        let targets = pingTargets(state: state)
        let seconds = Self.pingSeconds
        return await withTaskGroup(of: (Int, WifiPathMeasure?).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, await Self.ping(target.1, as: target.0, seconds: seconds)) }
            }
            var results: [(Int, WifiPathMeasure)] = []
            for await (index, measure) in group { if let measure { results.append((index, measure)) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Ping d'une adresse pendant `seconds` (une demande toutes les 0,5 s).
    nonisolated private static func ping(_ address: IPv4Address, as target: WifiPathTarget, seconds: TimeInterval) async -> WifiPathMeasure? {
        let box = PingBox()
        let monitor = PingMonitor(address: address, options: PingOptions(interval: 0.5, timeout: 1)) { sample in box.append(sample) }
        do {
            try monitor.start()
        } catch {
            return nil
        }
        try? await Task.sleep(nanoseconds: UInt64((seconds + 1.1) * 1_000_000_000))
        monitor.stop()
        let samples = box.samples
        guard !samples.isEmpty else { return nil }
        return WifiPathMeasure(target: target, address: address.description, statistics: PingStatistics(values: samples.map(\.rttMs)))
    }
}

/// Mesures reçues sur la file du moniteur de ping.
private final class PingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PingSample] = []

    func append(_ sample: PingSample) {
        lock.lock()
        list.append(sample)
        lock.unlock()
    }

    var samples: [PingSample] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}
