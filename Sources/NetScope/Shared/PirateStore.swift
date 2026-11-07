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
    @Published var apFilter: RogueAPClass?
    /// Dernier Test DHCP jugé (site actif), pour la section des rapports.
    @Published private(set) var dhcpFindings: [RogueDHCPFinding] = []

    private static let acceptedKey = "NetScope.pirates.voisinesAcceptees"
    let isDemo: Bool

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            accepted = PirateDemo.accepted
            localScan = PirateDemo.localScan
            localScanDate = Date().addingTimeInterval(-6 * 60)
            dhcpFindings = RogueDHCPAnalyzer.findings(CaptureDemo.offers(), policy: RogueDHCPPolicy(text: "10.182.122.1"),
                                                      vendor: Self.vendor)
        } else {
            accepted = Set(UserDefaults.standard.stringArray(forKey: Self.acceptedKey) ?? [])
        }
    }

    // MARK: DHCP

    /// Adresses des FortiGate déclarées (hôte de l'API) : serveurs DHCP attendus du site.
    static func fortiGateAddresses() -> [IPv4Address] {
        FortiGateStore.shared.controllers.filter(\.isEnabled).compactMap { IPv4Address($0.host) }
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
        wifi.scan()
        Task { @MainActor in
            // Le balayage CoreWLAN dure quelques secondes.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !wifi.isScanning { break }
            }
            self.localScan = wifi.networks
            self.localScanDate = Date()
        }
    }

    /// Site des relevés de ce Mac : celui des FortiAP qui porte le nom du site actif.
    private func localSite(_ overview: FortiWifiOverview) -> String {
        let active = SiteModel.shared.activeName
        let sites = Set(overview.aps.map(\.site) + overview.ssids.map(\.site))
        if let match = sites.first(where: { $0.compare(active, options: FrenchOrder.options, range: nil, locale: FrenchOrder.locale) == .orderedSame }) { return match }
        return sites.count == 1 ? sites.first! : active
    }

    func rogueAPs(devices: [Device]) -> [RogueAPFinding] {
        let overview = FortiAPStore.shared.overview
        let site = localSite(overview)
        var sightings = overview.rogues.map(RogueAPSighting.init)
        sightings += localScan.map { RogueAPSighting($0, site: site) }
        var ssids: [String: Set<String>] = [:]
        for s in overview.ssids where !s.ssid.isEmpty { ssids[s.site, default: []].insert(s.ssid) }
        // BSSID connus : le réseau auquel ce Mac est connecté, s'il diffuse un SSID du site.
        let known = Set(localScan.filter { $0.isConnected && $0.ssid.map { ssids[site]?.contains($0) == true } == true }.compactMap(\.bssid))
        var wired = devices.compactMap { device -> RogueAPWiredMAC? in
            guard let mac = device.mac, let place = device.switchLocation else { return nil }
            return RogueAPWiredMAC(site: site, mac: mac, place: place)
        }
        if isDemo { wired += PirateDemo.wired(site: site) }
        return RogueAPAnalyzer.classify(sightings, siteSSIDs: ssids, knownBSSIDs: known, wired: wired, accepted: accepted,
                                        vendor: Self.vendor)
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
            // Table ARP de ce Mac (lecture locale) et tables ARP des FortiGate du site.
            for (ip, mac) in ARPTable().read() {
                observations.append(IPObservation(site: site, ip: ip, mac: mac, source: .arp, date: now))
            }
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
        return IPConflictAnalyzer.analyze(observations, changes: changes, gateways: gateways, now: now)
    }
}
