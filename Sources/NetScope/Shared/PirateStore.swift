import Foundation
import NetScopeCore
import SwiftUI

/// Notes 96 et 97 : serveurs DHCP attendus, conflits d'adresses IP et bornes Wi-Fi pirates, calculés
/// à partir des relevés déjà faits (scan, table ARP de ce Mac, FortiGate, Inventaire, FortiAP,
/// balayage Wi-Fi de ce Mac). Rien n'est envoyé ici ; en démonstration, données fixes.
@MainActor
final class PirateStore: ObservableObject {
    static let shared = PirateStore()

    /// Voisines acceptées : « site|BSSID » (jamais par l'IP).
    @Published private(set) var accepted: Set<String>
    /// Dernier balayage de ce Mac retenu pour les bornes pirates (sur clic).
    @Published private(set) var localScan: [WifiNetwork] = []
    @Published private(set) var localScanDate: Date?
    /// Site actif au moment du balayage : un balayage n'est jamais attribué à un autre site.
    private var localScanSiteID: UUID?
    /// Durée pendant laquelle le balayage de ce Mac reste retenu.
    static let localScanLifetime: TimeInterval = 3600
    @Published var apFilter: RogueAPClass?
    /// Dernier Test DHCP jugé (site actif), pour la section des rapports.
    @Published private(set) var dhcpFindings: [RogueDHCPFinding] = []
    /// Historique borné des lectures ARP de ce Mac, par site (va-et-vient de MAC, comme arpwatch).
    /// Pas publié : alimenté pendant le calcul des conflits.
    private var arpHistory: [String: [ARPRun]] = [:]
    struct ARPRun {
        var ip: IPv4Address
        var mac: MACAddress
        var first: Date
        var last: Date
    }
    static let arpHistoryWindow: TimeInterval = 2 * 3600
    static let arpHistoryLimit = 400

    private static let acceptedKey = "NetScope.pirates.voisinesAcceptees"
    let isDemo: Bool

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            accepted = PirateDemo.accepted
            localScan = PirateDemo.localScan
            localScanDate = Date().addingTimeInterval(-6 * 60)
            localScanSiteID = SiteModel.shared.activeID
            dhcpFindings = RogueDHCPAnalyzer.findings(CaptureDemo.offers(), policy: RogueDHCPPolicy(text: "10.182.122.1"),
                                                      vendor: Self.vendor)
        } else {
            accepted = Set(UserDefaults.standard.stringArray(forKey: Self.acceptedKey) ?? [])
        }
    }

    // MARK: DHCP

    /// Adresses des FortiGate du site actif (hôte de l'API) : serveurs DHCP attendus du site. Les
    /// FortiGate des autres sites n'en font pas partie (plages IP parfois partagées).
    static func fortiGateAddresses() -> [IPv4Address] {
        let ids = Set(SiteModel.shared.activeSite?.fortiGateIDs ?? [])
        return FortiGateStore.shared.controllers.filter { $0.isEnabled && ids.contains($0.id) }.compactMap { IPv4Address($0.host) }
    }

    static func vendor(_ mac: MACAddress) -> String? { OUIDatabase.builtIn.vendor(for: mac) }

    /// Offres reçues par le Test DHCP, jugées par la même règle que le test.
    func recordDHCP(_ offers: [DHCPOffer], allowedText: String) {
        guard !isDemo else { return }
        dhcpFindings = RogueDHCPAnalyzer.findings(offers, policy: RogueDHCPPolicy(text: allowedText, fortiGates: Self.fortiGateAddresses()),
                                                  vendor: Self.vendor)
    }

    // MARK: Bornes Wi-Fi

    func isAccepted(_ finding: RogueAPFinding) -> Bool { accepted.contains(finding.id) }

    func setAccepted(_ finding: RogueAPFinding, _ value: Bool) {
        if value { accepted.insert(finding.id) } else { accepted.remove(finding.id) }
        guard !isDemo else { return }
        UserDefaults.standard.set(accepted.sorted(), forKey: Self.acceptedKey)
    }

    /// Retient le dernier balayage de WifiStore (lancé sur clic par l'utilisateur).
    func scanFromThisMac() {
        let wifi = WifiStore.shared
        if isDemo {
            localScanDate = Date()
            return
        }
        let siteID = SiteModel.shared.activeID
        wifi.scan()
        Task { @MainActor in
            // Le balayage CoreWLAN dure quelques secondes.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !wifi.isScanning { break }
            }
            self.localScan = wifi.networks
            self.localScanDate = Date()
            self.localScanSiteID = siteID
        }
    }

    /// Site des relevés de ce Mac : celui des FortiAP qui porte le nom du site actif.
    private func localSite(_ overview: FortiWifiOverview) -> String {
        let active = SiteModel.shared.activeName
        let sites = Set(overview.aps.map(\.site) + overview.ssids.map(\.site))
        if let match = sites.first(where: { $0.compare(active, options: FrenchOrder.options, range: nil, locale: FrenchOrder.locale) == .orderedSame }) { return match }
        return sites.count == 1 ? sites.first! : active
    }

    /// Balayage de ce Mac retenu pour le site actif : fait sur ce site, il y a moins d'une heure.
    private var currentLocalScan: [WifiNetwork] {
        guard localScanSiteID == SiteModel.shared.activeID, let date = localScanDate,
              Date().timeIntervalSince(date) <= Self.localScanLifetime else { return [] }
        return localScan
    }

    func rogueAPs(devices: [Device]) -> [RogueAPFinding] {
        let overview = FortiAPStore.shared.overview
        let site = localSite(overview)
        let localScan = currentLocalScan
        var sightings = overview.rogues.map(RogueAPSighting.init)
        sightings += localScan.map { RogueAPSighting($0, site: site) }
        var ssids: [String: Set<String>] = [:]
        for s in overview.ssids where !s.ssid.isEmpty { ssids[s.site, default: []].insert(s.ssid) }
        // BSSID connus : le réseau auquel ce Mac est connecté, s'il diffuse un SSID du site.
        let known = Set(localScan.filter { $0.isConnected && $0.ssid.map { ssids[site]?.contains($0) == true } == true }.compactMap(\.bssid))
        // MAC filaires des FortiAP du site : appareil du scan à MAC Fortinet dont l'adresse est celle
        // d'une FortiAP lue sur la FortiGate du site (la MAC reste la clé).
        let apIPs = Set(overview.aps.filter { $0.site == site }.compactMap(\.ip))
        let apMACs = Set(devices.compactMap { device -> MACAddress? in
            guard let mac = device.mac, apIPs.contains(device.ip),
                  (Self.vendor(mac) ?? "").lowercased().contains("fortinet") else { return nil }
            return mac
        })
        var wired = devices.compactMap { device -> RogueAPWiredMAC? in
            guard let mac = device.mac, let place = device.switchLocation else { return nil }
            return RogueAPWiredMAC(site: site, mac: mac, place: place)
        }
        if isDemo { wired += PirateDemo.wired(site: site) }
        return RogueAPAnalyzer.classify(sightings, siteSSIDs: ssids, knownBSSIDs: known, knownAPMACs: apMACs, wired: wired,
                                        accepted: accepted, vendor: Self.vendor)
    }

    // MARK: Conflits d'IP

    func ipConflicts(devices: [Device], now: Date = Date()) -> [IPConflict] {
        let site = SiteModel.shared.activeName
        var observations = IPConflictAnalyzer.observations(devices: devices, site: site)
        var changes: [IPChange] = []
        if isDemo {
            observations += PirateDemo.observations(site: site, now: now)
            changes = PirateDemo.changes(site: site, now: now)
        } else {
            // Table ARP de ce Mac (lecture locale, gardée en historique) et tables ARP des FortiGate du site.
            observations += recordARP(ARPTable().read(), site: site, now: now)
            if let active = SiteModel.shared.activeSite {
                for report in FortiGateStore.shared.reports(for: active) {
                    for entry in report.report.arp where report.owns(entry.ip) {
                        observations.append(IPObservation(site: site, ip: entry.ip, mac: entry.mac, source: .fortiGate,
                                                          date: report.report.readAt))
                    }
                }
            }
            let store = InvModel.shared.store
            for event in store.events where event.kind == .changementIP {
                guard let mac = store.records[event.key]?.mac else { continue }
                changes.append(IPChange(site: site, mac: mac, ip: event.ip, date: event.date))
            }
        }
        var gateways: [String: IPv4Address] = [:]
        if let router = devices.first(where: { $0.deviceType == .routeur }) { gateways[site] = router.ip }
        return IPConflictAnalyzer.analyze(observations, changes: changes, gateways: gateways, now: now,
                                          isApple: { (Self.vendor($0) ?? "").lowercased().hasPrefix("apple") })
    }

    /// Ajoute une lecture ARP de ce Mac à l'historique du site actif (une suite par IP et MAC) et
    /// renvoie les observations gardées : début et fin de chaque suite.
    private func recordARP(_ table: [IPv4Address: MACAddress], site: String, now: Date) -> [IPObservation] {
        let key = SiteModel.shared.activeKey
        var runs = arpHistory[key, default: []].filter { now.timeIntervalSince($0.last) <= Self.arpHistoryWindow }
        for (ip, mac) in table {
            if let index = runs.lastIndex(where: { $0.ip == ip }), runs[index].mac == mac {
                runs[index].last = max(runs[index].last, now)
            } else {
                runs.append(ARPRun(ip: ip, mac: mac, first: now, last: now))
            }
        }
        if runs.count > Self.arpHistoryLimit { runs.removeFirst(runs.count - Self.arpHistoryLimit) }
        arpHistory[key] = runs
        return runs.flatMap { run -> [IPObservation] in
            let first = IPObservation(site: site, ip: run.ip, mac: run.mac, source: .arp, date: run.first)
            guard run.last > run.first else { return [first] }
            return [first, IPObservation(site: site, ip: run.ip, mac: run.mac, source: .arp, date: run.last)]
        }
    }
}
