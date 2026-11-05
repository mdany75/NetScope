import Foundation
import NetScopeCore

/// Démonstration de la note 27 (Wi-Fi géré par la FortiGate). Aucun accès réseau.
///
/// Siège (FortiGate de FortiGateSitesDemo) : six FortiAP (FAP-231F, FAP-431F, FAP-23JF), deux SSID
/// (« Groupe-Interne » en WPA2 Entreprise, « Invités » ouvert avec portail captif), 42 clients dont
/// ce Mac et le téléphone Android du Scanner de démonstration (mêmes MAC), un chevauchement de
/// canal (AP-ACCUEIL canal 44 et AP-ETG2 canal 36 en 80 MHz, comme le croquis Wifi.dc.html), deux
/// clients à signal faible, une borne surchargée, une borne hors ligne (AP-QUAI) et des AP voisins
/// dont un non autorisé branché sur le réseau (le faux « Bureau-Corp » du croquis).
/// Entrepôt Laval : deux bornes, lues seulement quand la capture à deux sites la choisit.
///
/// Captures : NETSCOPE_WIFI_VUE=fortiap ouvre la partie FortiAP de l'écran Wi-Fi.
@MainActor
enum FortiAPDemo {
    /// Capture de la partie FortiAP.
    static var opensFortiAP: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_WIFI_VUE"] == "fortiap"
    }

    /// Lectures Wi-Fi des FortiGate choisies (Siège et Laval seulement répondent).
    static func sites(for selection: FortiControllerSelection, now: Date = Date()) -> [FortiWifiSiteReport] {
        selection.picks.compactMap { pick -> FortiWifiSiteReport? in
            switch pick.controllerID {
            case FortiGateSitesDemo.siegeID: return FortiWifiSiteReport(controllerID: pick.controllerID, site: pick.site, report: siege(now: now))
            case FortiGateSitesDemo.lavalID: return FortiWifiSiteReport(controllerID: pick.controllerID, site: pick.site, report: laval(now: now))
            default: return nil
            }
        }
    }

    /// Bornes à la sélection de la démonstration (comme FortiGateSitesDemo.make).
    static func initialSites(now: Date = Date()) -> [FortiWifiSiteReport] {
        let selection = FortiControllerSelector.select(FortiGateSitesDemo.controllers(now: now), scanned: FortiGateSitesDemo.scannedRanges,
                                                       macAddress: DemoData.interface.address)
        return sites(for: selection, now: now)
    }

    // MARK: Siège

    static let thisMac = MACAddress("3C:22:FB:7E:05:B1")!
    static let android = MACAddress("D6:4E:81:7A:33:C0")!

    static func radio(_ id: Int, _ band: WifiBand, _ channel: Int?, _ width: Int, power: Int? = nil, util: Double? = nil,
                      noise: Int? = nil, interfering: Int? = nil, mode: String = "AP") -> FortiAPRadio {
        let standard: String
        switch band {
        case .ghz24: standard = "802.11ax,n,g-only"
        case .ghz5: standard = "802.11ax-5G"
        case .ghz6: standard = "802.11ax-6G"
        }
        return FortiAPRadio(radioID: id, band: band, channel: channel, widthMHz: channel == nil ? nil : width, txPowerDBm: power,
                            channelUtilization: util, noiseDBm: noise, interferingAPs: interfering, mode: mode, standard: standard)
    }

    static func siege(now: Date = Date()) -> FortiWifiReport {
        var aps: [FortiManagedAP] = [
            FortiManagedAP(name: "AP-ACCUEIL", wtpID: "FP231FTF22004101", serial: "FP231FTF22004101", model: "FAP-231F",
                           firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.182.122.102"), connected: true, state: "connected",
                           admin: "authorized", uptime: 18 * 86_400 + 4 * 3600, profile: "FAP231F-bureau",
                           radios: [radio(1, .ghz24, 6, 20, power: 14, util: 41, noise: -94, interfering: 5),
                                    radio(2, .ghz5, 44, 80, power: 17, util: 36, noise: -96, interfering: 2)],
                           location: "Accueil, plafond"),
            FortiManagedAP(name: "AP-ETG2", wtpID: "FP231FTF22004187", serial: "FP231FTF22004187", model: "FAP-231F",
                           firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.182.122.104"), connected: true, state: "connected",
                           admin: "authorized", uptime: 18 * 86_400 + 3 * 3600, profile: "FAP231F-bureau",
                           radios: [radio(1, .ghz24, 11, 20, power: 14, util: 38, noise: -93, interfering: 4),
                                    radio(2, .ghz5, 36, 80, power: 17, util: 33, noise: -95, interfering: 2)],
                           location: "Étage 2, salle 204"),
            FortiManagedAP(name: "AP-SALLE-CONF", wtpID: "FP431FTF21000912", serial: "FP431FTF21000912", model: "FAP-431F",
                           firmware: "FP431F-v7.2.8-build0436", ip: IPv4Address("10.182.122.105"), connected: true, state: "connected",
                           admin: "authorized", uptime: 6 * 86_400 + 9 * 3600, profile: "FAP431F-salles",
                           radios: [radio(1, .ghz24, 1, 20, util: 22, noise: -95, mode: "Monitor"),
                                    radio(2, .ghz5, 149, 80, power: 18, util: 78, noise: -92, interfering: 1),
                                    radio(3, .ghz5, 100, 40, power: 16, util: 29, noise: -97)],
                           location: "Grande salle de conférence"),
            FortiManagedAP(name: "AP-ENTREPOT", wtpID: "FP231FTF22004233", serial: "FP231FTF22004233", model: "FAP-231F",
                           firmware: "FP231F-v7.2.4-build0412", ip: IPv4Address("10.182.130.12"), connected: true, state: "connected",
                           admin: "authorized", uptime: 41 * 86_400, profile: "FAP231F-entrepot",
                           radios: [radio(1, .ghz24, 1, 20, power: 18, util: 27, noise: -91, interfering: 3),
                                    radio(2, .ghz5, 52, 80, power: 20, util: 18, noise: -96)],
                           location: "Entrepôt, allée C"),
            FortiManagedAP(name: "AP-DIRECTION", wtpID: "FP23JFTF23001044", serial: "FP23JFTF23001044", model: "FAP-23JF",
                           firmware: "FP23JF-v7.2.8-build0436", ip: IPv4Address("10.182.122.108"), connected: true, state: "connected",
                           admin: "authorized", uptime: 2 * 86_400 + 5 * 3600, profile: "FAP23JF-bureaux",
                           radios: [radio(1, .ghz24, nil, 20, mode: "Disabled"),
                                    radio(2, .ghz5, 116, 80, power: 14, util: 12, noise: -97)],
                           location: "Bureau de la direction (prise murale)"),
            FortiManagedAP(name: "AP-QUAI", wtpID: "FP231FTF22004290", serial: "FP231FTF22004290", model: "FAP-231F",
                           firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.182.130.14"), connected: false, state: "disconnected",
                           admin: "authorized", profile: "FAP231F-entrepot",
                           radios: [radio(1, .ghz24, nil, 20), radio(2, .ghz5, nil, 80)],
                           lastSeen: now.addingTimeInterval(-47 * 60), location: "Quai de chargement"),
        ]

        // 42 clients : ce Mac et le téléphone Android du Scanner, deux à signal faible.
        var clients: [FortiWifiClient] = []
        func add(_ mac: MACAddress, _ ip: String, _ host: String?, ssid: String, ap: String, radio: Int, band: WifiBand, channel: Int,
                 rssi: Int, noise: Int = -95, rate: Double, minutes: Double, os: String, vlan: Int) {
            clients.append(FortiWifiClient(mac: mac, ip: IPv4Address(ip), hostname: host, ssid: ssid, apName: ap, radioID: radio, band: band,
                                           channel: channel, rssi: rssi, noise: noise, rateMbps: rate, associatedFor: minutes * 60, os: os, vlan: vlan))
        }
        add(thisMac, "10.182.122.135", "Macmini-de-Dany", ssid: "Groupe-Interne", ap: "AP-ACCUEIL", radio: 2, band: .ghz5, channel: 44,
            rssi: -52, rate: 866.7, minutes: 94, os: "macOS", vlan: 20)
        add(android, "10.182.122.133", "Android_89UM1WTN", ssid: "Groupe-Interne", ap: "AP-ETG2", radio: 1, band: .ghz24, channel: 11,
            rssi: -77, noise: -93, rate: 26, minutes: 12, os: "Android", vlan: 20)
        add(MACAddress("F2:6A:19:C4:0E:57")!, "10.182.140.31", "iPhone-Reception", ssid: "Invités", ap: "AP-ENTREPOT", radio: 1, band: .ghz24,
            channel: 1, rssi: -73, noise: -91, rate: 19.5, minutes: 6, os: "iOS", vlan: 60)

        struct Spot { let ap: String; let radio: Int; let band: WifiBand; let channel: Int; let count: Int; let rssi: Int }
        let spots = [Spot(ap: "AP-ACCUEIL", radio: 2, band: .ghz5, channel: 44, count: 6, rssi: -55),
                     Spot(ap: "AP-ACCUEIL", radio: 1, band: .ghz24, channel: 6, count: 2, rssi: -61),
                     Spot(ap: "AP-ETG2", radio: 2, band: .ghz5, channel: 36, count: 6, rssi: -57),
                     Spot(ap: "AP-ETG2", radio: 1, band: .ghz24, channel: 11, count: 1, rssi: -63),
                     Spot(ap: "AP-SALLE-CONF", radio: 2, band: .ghz5, channel: 149, count: 14, rssi: -54),
                     Spot(ap: "AP-SALLE-CONF", radio: 3, band: .ghz5, channel: 100, count: 4, rssi: -58),
                     Spot(ap: "AP-ENTREPOT", radio: 2, band: .ghz5, channel: 52, count: 3, rssi: -62),
                     Spot(ap: "AP-DIRECTION", radio: 2, band: .ghz5, channel: 116, count: 3, rssi: -50)]
        let hosts = ["iPhone-de-Julie", "LAP-COMPTA-03", "Galaxy-S23-Marc", "LAP-VENTES-11", "iPad-Salle-A", "LAP-RH-02", "Pixel-8-Simon",
                     "LAP-DIR-01", "iPhone-de-Karine", "LAP-TI-07", "MacBook-Air-Sophie", "SURFACE-SALLE", "LAP-VENTES-04", "Zebra-TC52-01",
                     "Zebra-TC52-02", "iPhone-de-Luc", "LAP-COMPTA-05", "Galaxy-Tab-Accueil", "LAP-PROJ-09", "Teams-Room-A",
                     "iPhone-de-Nadia", "LAP-VENTES-08", "MacBook-Pro-Eric", "Pixel-7-Amelie", "LAP-RH-04", "iPhone-Invite",
                     "LAP-TI-02", "Galaxy-A54", "iPad-Direction", "LAP-COMPTA-01", "iPhone-de-Paul", "LAP-DIR-02", "Zebra-TC52-03",
                     "LAP-PROJ-03", "Android-7F21", "iPhone-de-Mia", "LAP-VENTES-02", "LAP-RH-06", "SURFACE-DIR"]
        var n = 0
        for spot in spots {
            for k in 0..<spot.count {
                let host = hosts[n % hosts.count]
                let guest = host.contains("Invite") || (spot.ap == "AP-SALLE-CONF" && k % 4 == 3)
                let mac = MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x40, UInt8(n / 256), UInt8(n % 256)])
                let ip = guest ? "10.182.140.\(40 + n)" : "10.182.120.\(40 + n)"
                let os = host.hasPrefix("iPhone") || host.hasPrefix("iPad") ? "iOS" : (host.hasPrefix("Mac") ? "macOS"
                    : (host.hasPrefix("LAP") || host.hasPrefix("SURFACE") ? "Windows" : (host.hasPrefix("Teams") ? "Windows" : "Android")))
                let rssi = spot.rssi - (k * 3) % 11
                let rate: Double = spot.band == .ghz24 ? 72 + Double((k * 17) % 60) : (rssi > -58 ? 600.4 + Double(k * 40 % 600) : 288.2 + Double(k * 23 % 200))
                add(mac, ip, host, ssid: guest ? "Invités" : "Groupe-Interne", ap: spot.ap, radio: spot.radio, band: spot.band,
                    channel: spot.channel, rssi: rssi, rate: rate, minutes: Double(15 + (n * 37) % 400), os: os, vlan: guest ? 60 : 20)
                n += 1
            }
        }
        // Note 46 : détails de la fiche complète (FortiAPClientDemo).
        clients = enrichClients(clients)
        // Clients par radio, d'après la liste.
        for i in aps.indices {
            for r in aps[i].radios.indices where aps[i].radios[r].isServing {
                let id = aps[i].radios[r].radioID
                aps[i].radios[r].clientCount = clients.filter { $0.apName == aps[i].name && $0.radioID == id }.count
            }
            aps[i].clientCount = clients.filter { $0.apName == aps[i].name }.count
        }

        let ssids = [
            FortiSSID(name: "wifi-interne", ssid: "Groupe-Interne", security: "wpa2-only-enterprise", vlan: 20, hidden: false,
                      localBridging: false, maxClients: nil, captivePortal: false),
            FortiSSID(name: "wifi-invites", ssid: "Invités", security: "open", vlan: 60, hidden: false, localBridging: true,
                      maxClients: 60, captivePortal: true),
        ]

        let seen = now.addingTimeInterval(-90)
        let rogues = [
            FortiRogueAP(ssid: "Bureau-Corp", bssid: MACAddress("02:1F:6B:A0:44:93"), channel: 6, band: .ghz24, rssi: -58, status: .rogue,
                         onWire: true, seenBy: ["AP-ACCUEIL", "AP-ETG2"], security: "WPA2-Personnel", vendor: "Inconnu (MAC privée)", lastSeen: seen),
            FortiRogueAP(ssid: "Cafe-Voisin", bssid: MACAddress("9C:53:22:5D:18:C2"), channel: 6, band: .ghz24, rssi: -78,
                         seenBy: ["AP-ACCUEIL"], security: "WPA2-Personnel", vendor: "TP-Link", lastSeen: seen),
            FortiRogueAP(ssid: "Entrepot-Nord", bssid: MACAddress("94:B4:0F:62:7A:01"), channel: 6, band: .ghz24, rssi: -71,
                         seenBy: ["AP-ENTREPOT"], security: "WPA2-Entreprise", vendor: "Aruba", lastSeen: seen),
            FortiRogueAP(ssid: "Entrepot-Nord", bssid: MACAddress("94:B4:0F:62:7A:11"), channel: 149, band: .ghz5, rssi: -77,
                         seenBy: ["AP-ENTREPOT", "AP-SALLE-CONF"], security: "WPA2-Entreprise", vendor: "Aruba", lastSeen: seen),
            FortiRogueAP(ssid: "UBNT-Logistik", bssid: MACAddress("78:8A:20:4E:C3:05"), channel: 11, band: .ghz24, rssi: -69,
                         seenBy: ["AP-ETG2", "AP-ENTREPOT"], security: "WPA2-Personnel", vendor: "Ubiquiti", lastSeen: seen),
            FortiRogueAP(ssid: "UBNT-Logistik", bssid: MACAddress("78:8A:20:4E:C3:06"), channel: 100, band: .ghz5, rssi: -73,
                         seenBy: ["AP-SALLE-CONF"], security: "WPA2-Personnel", vendor: "Ubiquiti", lastSeen: seen),
            FortiRogueAP(ssid: "DIRECT-7D-DCP-L2640DW", bssid: MACAddress("96:DD:F8:18:15:7D"), channel: 1, band: .ghz24, rssi: -61,
                         status: .accepted, seenBy: ["AP-ACCUEIL"], security: "WPA2-Personnel", vendor: "Brother", lastSeen: seen),
            FortiRogueAP(ssid: nil, bssid: MACAddress("9C:53:22:7B:0E:41"), channel: 6, band: .ghz24, rssi: -74,
                         seenBy: ["AP-ACCUEIL"], security: "WPA2-Personnel", vendor: "TP-Link", lastSeen: seen),
        ]

        let readAt = now.addingTimeInterval(-40)
        var report = FortiWifiReport(aps: aps, clients: clients, ssids: ssids, rogues: rogues, readAt: readAt)
        report.calls = [
            FortiCallRecord(path: FortiWifiPaths.managedAP, status: 200, outcome: .ok, body: "(démonstration)", items: aps.count),
            FortiCallRecord(path: FortiWifiPaths.client, status: 200, outcome: .ok, body: "(démonstration)", items: clients.count),
            FortiCallRecord(path: FortiWifiPaths.vap, status: 200, outcome: .ok, body: "(démonstration)", items: ssids.count),
            FortiCallRecord(path: FortiWifiPaths.rogueAP, status: 200, outcome: .ok, body: "(démonstration)", items: rogues.count),
            FortiCallRecord(path: FortiWifiPaths.apStatus, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
        ]
        return report
    }

    // MARK: Entrepôt Laval

    static func laval(now: Date = Date()) -> FortiWifiReport {
        var aps = [
            FortiManagedAP(name: "AP-LAV-QUAI", wtpID: "FP231FTF23002210", serial: "FP231FTF23002210", model: "FAP-231F",
                           firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.20.10.20"), connected: true, state: "connected",
                           admin: "authorized", uptime: 9 * 86_400,
                           radios: [radio(1, .ghz24, 6, 20, power: 17, util: 35, noise: -92), radio(2, .ghz5, 36, 80, power: 18, util: 21, noise: -95)]),
            FortiManagedAP(name: "AP-LAV-BUREAU", wtpID: "FP23JFTF23003301", serial: "FP23JFTF23003301", model: "FAP-23JF",
                           firmware: "FP23JF-v7.2.8-build0436", ip: IPv4Address("10.20.0.21"), connected: true, state: "connected",
                           admin: "authorized", uptime: 9 * 86_400,
                           radios: [radio(1, .ghz24, 1, 20, power: 12, util: 18, noise: -94), radio(2, .ghz5, 149, 80, power: 15, util: 9, noise: -97)]),
        ]
        var clients: [FortiWifiClient] = []
        for n in 0..<7 {
            let quai = n < 5
            clients.append(FortiWifiClient(mac: MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x20, 0x10, UInt8(n)]), ip: IPv4Address("10.20.10.\(80 + n)"),
                                           hostname: quai ? "Zebra-LAV-0\(n + 1)" : "LAP-LAV-0\(n - 4)", ssid: "Groupe-Interne",
                                           apName: quai ? "AP-LAV-QUAI" : "AP-LAV-BUREAU", radioID: quai ? 1 : 2,
                                           band: quai ? .ghz24 : .ghz5, channel: quai ? 6 : 149, rssi: quai ? -60 - n * 2 : -54, noise: -94,
                                           rateMbps: quai ? 86.7 : 720.6, associatedFor: Double(600 + n * 900), os: quai ? "Android" : "Windows", vlan: 10))
        }
        clients = enrichClients(clients)
        for i in aps.indices {
            for r in aps[i].radios.indices {
                let id = aps[i].radios[r].radioID
                aps[i].radios[r].clientCount = clients.filter { $0.apName == aps[i].name && $0.radioID == id }.count
            }
            aps[i].clientCount = clients.filter { $0.apName == aps[i].name }.count
        }
        var report = FortiWifiReport(aps: aps, clients: clients,
                                     ssids: [FortiSSID(name: "wifi-interne", ssid: "Groupe-Interne", security: "wpa2-only-enterprise", vlan: 10)],
                                     rogues: [FortiRogueAP(ssid: "Transport-Rive-Nord", bssid: MACAddress("A4:2B:B0:11:72:0C"), channel: 11,
                                                           band: .ghz24, rssi: -80, seenBy: ["AP-LAV-QUAI"], vendor: "TP-Link")],
                                     readAt: now.addingTimeInterval(-3 * 60))
        report.calls = [FortiCallRecord(path: FortiWifiPaths.managedAP, status: 200, outcome: .ok, body: "(démonstration)", items: aps.count),
                        FortiCallRecord(path: FortiWifiPaths.client, status: 200, outcome: .ok, body: "(démonstration)", items: clients.count)]
        return report
    }
}
