import Foundation
import NetScopeCore

/// Démonstration de la note 77 : un contrôleur UniFi Network (Clinique Exemple), un contrôleur
/// TP-Link Omada (Bureau Québec) et le tableau de bord Cisco Meraki (Usine Drummondville), avec des
/// switchs, des bornes et des clients cohérents avec les plages de ces sites. Aucun réseau, aucune
/// vraie donnée de client. Captures : NETSCOPE_SITE=clinique (ou québec, drummondville).
@MainActor
enum ControllerDemo {
    static let unifiID = UUID(uuidString: "5A7E0077-0001-4C1E-9A11-00000000C001")!
    static let omadaID = UUID(uuidString: "5A7E0077-0002-4C1E-9A11-00000000C002")!
    static let merakiID = UUID(uuidString: "5A7E0077-0003-4C1E-9A11-00000000C003")!

    static let unifi = SiteController(id: unifiID, kind: .unifi, name: "UDM Pro de la clinique", host: "192.168.1.1", unifiOS: true,
                                      authMode: .unifiAPIKey, siteRef: "default",
                                      pinnedFingerprint: "3F:A8:51:0C:E2:97:4D:B6:18:73:C5:2E:9A:04:F1:68:BD:32:7C:E5:09:A1:56:D8:4B:F3:20:8E:C7:69:15:DA")
    static let omada = SiteController(id: omadaID, kind: .omada, name: "OC200 du bureau", host: "10.30.0.5", port: 443,
                                      authMode: .omadaOpenAPI, account: "8d4f2c1a9b7e4f6d", siteRef: "Bureau Québec",
                                      pinnedFingerprint: "C1:5E:83:2A:F7:40:9D:16:B8:E4:63:0F:A9:52:7C:D1:3B:86:E0:4F:97:2D:C5:18:6A:F0:B3:49:D7:21:8E:65")
    static let meraki = SiteController(id: merakiID, kind: .meraki, name: "Tableau de bord Meraki", siteRef: "Usine Drummondville",
                                       orgRef: "Groupe Exemple")

    static var allControllers: [SiteController] { [unifi, omada, meraki] }

    /// Contrôleurs d'un site de démonstration (SitesDemo).
    static func controllers(for siteID: UUID) -> [SiteController] {
        switch siteID {
        case SitesDemo.cliniqueID: return [unifi]
        case SitesDemo.quebecID: return [omada]
        case SitesDemo.drummondID: return [meraki]
        default: return []
        }
    }

    /// Erreur de démonstration d'un contrôleur (aucune : les trois répondent).
    static func error(for id: UUID) -> String? { nil }

    static func readings(for site: Site, now: Date = Date()) -> [ControllerSiteReading] {
        site.controllers.filter(\.isEnabled).compactMap { c in
            report(for: c.id, now: now).map { ControllerSiteReading(controllerID: c.id, siteID: site.id, siteName: site.displayName, report: $0) }
        }
    }

    static func report(for id: UUID, now: Date = Date()) -> ControllerReport? {
        switch id {
        case unifiID: return unifiReport(now: now)
        case omadaID: return omadaReport(now: now)
        case merakiID: return merakiReport(now: now)
        default: return nil
        }
    }

    /// « Tester » de la feuille en démonstration : la lecture fictive du contrôleur.
    static func testOutcome(for draft: SiteController) -> SiteControllerStore.TestOutcome {
        if draft.usesPinning, draft.pinnedFingerprint == nil {
            return SiteControllerStore.TestOutcome(error: ControllerError.certificateUnknown(fingerprint: unifi.pinnedFingerprint!, subject: "unifi.local").errorDescription,
                                                   pending: .init(fingerprint: unifi.pinnedFingerprint!, subject: "unifi.local", changed: false,
                                                                  host: draft.cleanHost, port: draft.effectivePort))
        }
        guard var report = report(for: draft.id) ?? report(for: [.unifi: unifiID, .omada: omadaID, .meraki: merakiID][draft.kind]!) else {
            return SiteControllerStore.TestOutcome(error: "Aucune réponse de démonstration.")
        }
        report.calls = demoCalls(draft.kind)
        return SiteControllerStore.TestOutcome(report: report, calls: report.calls)
    }

    private static func demoCalls(_ kind: ControllerKind) -> [ControllerCallRecord] {
        let paths: [String]
        switch kind {
        case .unifi: paths = ["/proxy/network/api/self/sites", "/proxy/network/api/s/default/stat/sysinfo", "/proxy/network/api/s/default/rest/networkconf",
                              "/proxy/network/api/s/default/stat/device", "/proxy/network/api/s/default/stat/sta"]
        case .omada: paths = ["/api/info", "POST /openapi/authorize/token?grant_type=client_credentials", "/openapi/v1/…/sites?page=1&pageSize=100",
                              "/openapi/v1/…/sites/…/devices", "/openapi/v1/…/sites/…/clients"]
        case .meraki: paths = ["/api/v1/organizations", "/api/v1/organizations/549236/networks", "/api/v1/networks/L_6468…/devices",
                               "/api/v1/devices/…/switch/ports/statuses?timespan=300", "/api/v1/networks/L_6468…/clients?timespan=3600&perPage=1000"]
        }
        return paths.map { ControllerCallRecord(path: $0, status: 200, outcome: .ok) }
    }

    // MARK: Fabriques

    private static func m(_ text: String) -> MACAddress { MACAddress(text)! }
    private static func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

    /// Ports d'un switch : `used` donne, par numéro, ce qui y est branché.
    private static func ports(count: Int, sfp: Int = 0, poe: Bool, used: [Int: ControllerPort]) -> [ControllerPort] {
        (1...(count + sfp)).map { n in
            if let port = used[n] { return port }
            let isSFP = n > count
            return ControllerPort(number: n, name: isSFP ? "SFP+ \(n)" : nil, linkUp: false, enabled: true,
                                  speedMbps: isSFP ? 10_000 : nil, poeCapable: poe && !isSFP, poeEnabled: poe && !isSFP ? true : nil,
                                  poePowerW: poe && !isSFP ? 0 : nil, nativeVLAN: 1)
        }
    }

    private static func port(_ n: Int, _ name: String? = nil, speed: UInt64 = 1000, vlan: Int = 1, poeW: Double? = nil, poeClass: Int? = nil,
                             uplink: Bool = false, neighbor: ControllerNeighbor? = nil, errors: UInt64 = 0, rx: UInt64 = 0, tx: UInt64 = 0,
                             tagged: [Int] = [], alerts: [String] = [], poe: Bool = true) -> (Int, ControllerPort) {
        (n, ControllerPort(number: n, name: name, linkUp: true, enabled: true, speedMbps: speed, fullDuplex: true,
                           poeCapable: poe, poeEnabled: poe ? true : nil, poePowerW: poe ? (poeW ?? 0) : nil, poeClass: poeClass,
                           nativeVLAN: vlan, taggedVLANs: tagged, isUplink: uplink, neighbor: neighbor,
                           rxBytes: rx > 0 ? rx : nil, txBytes: tx > 0 ? tx : nil, rxErrors: errors, alerts: alerts))
    }

    private static func wired(_ mac: String, _ ip: String, _ name: String, sw: (MACAddress, String), port: Int, vlan: Int = 1,
                              vendor: String, now: Date) -> ControllerClient {
        ControllerClient(mac: m(mac), ip: Self.ip(ip), hostname: name, isWired: true, switchMAC: sw.0, switchName: sw.1, port: port,
                         vlan: vlan, lastSeen: now.addingTimeInterval(-30), manufacturer: vendor)
    }

    private static func wifi(_ mac: String, _ ip: String?, _ name: String, ap: ControllerAP, ssid: String, band: WifiBand, rssi: Int?,
                             vlan: Int = 1, rate: Double? = nil, vendor: String? = nil, now: Date) -> ControllerClient {
        let channel = ap.radios.first { $0.band == band }?.channel
        return ControllerClient(mac: m(mac), ip: ip.map(Self.ip), hostname: name, isWired: false, ssid: ssid, apMAC: ap.mac, apName: ap.name,
                                band: band, channel: channel, rssi: rssi, signalPercent: rssi.map { max(0, min(100, 2 * ($0 + 100))) },
                                vlan: vlan, lastSeen: now.addingTimeInterval(-20), manufacturer: vendor, rateMbps: rate)
    }

    // MARK: UniFi · Clinique Exemple

    static func unifiReport(now: Date) -> ControllerReport {
        let proMAC = m("74:AC:B9:10:20:30")
        let liteMAC = m("74:AC:B9:10:40:50")
        let apAccueil = ControllerAP(mac: m("D8:B3:70:AA:BB:01"), name: "U6-Accueil", model: "U6-Pro", firmware: "6.6.77", serial: "D8B370AABB01",
                                     ip: ip("192.168.1.21"), online: true, uptime: 1_036_800,
                                     radios: [ControllerRadio(band: .ghz24, channel: 1, widthMHz: 20, txPowerDBm: 14, clientCount: 2, utilization: 34),
                                              ControllerRadio(band: .ghz5, channel: 36, widthMHz: 80, txPowerDBm: 20, clientCount: 5, utilization: 18)],
                                     uplinkSwitchMAC: proMAC, uplinkSwitchName: "USW-Pro-Accueil", uplinkPort: 11,
                                     ssids: ["Clinique-Invites", "Clinique-Personnel"])
        let apAttente = ControllerAP(mac: m("D8:B3:70:AA:BB:02"), name: "U6-Salle-attente", model: "U6-Lite", firmware: "6.6.77",
                                     serial: "D8B370AABB02", ip: ip("192.168.1.22"), online: true, uptime: 1_036_200,
                                     radios: [ControllerRadio(band: .ghz24, channel: 6, widthMHz: 20, txPowerDBm: 14, clientCount: 1, utilization: 41),
                                              ControllerRadio(band: .ghz5, channel: 149, widthMHz: 80, txPowerDBm: 20, clientCount: 3, utilization: 12)],
                                     uplinkSwitchMAC: proMAC, uplinkSwitchName: "USW-Pro-Accueil", uplinkPort: 12,
                                     ssids: ["Clinique-Invites", "Clinique-Personnel"])
        let apImagerie = ControllerAP(mac: m("D8:B3:70:AA:BB:03"), name: "U6-Imagerie", model: "U6-LR", firmware: "6.6.77", serial: "D8B370AABB03",
                                      ip: ip("192.168.20.23"), online: true, uptime: 604_800,
                                      radios: [ControllerRadio(band: .ghz24, channel: 11, widthMHz: 20, txPowerDBm: 17, clientCount: 0, utilization: 22),
                                               ControllerRadio(band: .ghz5, channel: 52, widthMHz: 80, txPowerDBm: 23, clientCount: 2, utilization: 9)],
                                      uplinkSwitchMAC: liteMAC, uplinkSwitchName: "USW-Imagerie", uplinkPort: 5, ssids: ["Clinique-Personnel"])
        let udm = ControllerNeighbor(name: "UDM-Pro-Clinique", port: "Port 9", mac: m("24:5A:4C:00:00:01"), ip: ip("192.168.1.1"), isInfrastructure: true)
        let pro = ControllerSwitch(mac: proMAC, name: "USW-Pro-Accueil", model: "USW-Pro-24-PoE", firmware: "6.6.61", serial: "74ACB9102030",
                                   ip: ip("192.168.1.2"), online: true, uptime: 3_542_400, poeBudgetW: 400,
                                   ports: ports(count: 24, sfp: 2, poe: true, used: Dictionary(uniqueKeysWithValues: [
                                       port(1, "Uplink UDM", uplink: true, neighbor: udm, rx: 912_345_678_901, tx: 123_456_789_012, tagged: [20], poe: false),
                                       port(2, "Accueil 1", rx: 18_204_551_200, tx: 4_120_448_900), port(3, "Accueil 2"), port(4, "Accueil 3"),
                                       port(5, "Bureau Dr Roy"), port(6, "Bureau Dre Lavoie"), port(7, "Salle 1"),
                                       port(10, "Imprimante accueil", speed: 100, errors: 418),
                                       port(11, poeW: 9.8, poeClass: 4), port(12, poeW: 7.1, poeClass: 4),
                                       port(13, "Téléphone accueil", speed: 100, poeW: 3.9, poeClass: 2),
                                       port(14, "Téléphone Dr Roy", speed: 100, poeW: 4.2, poeClass: 2),
                                       port(17, "Vers imagerie", uplink: true, neighbor: ControllerNeighbor(name: "USW-Imagerie", port: "Port 1", mac: liteMAC,
                                                                                                           isInfrastructure: true), tagged: [20], poe: false),
                                   ])))
        let lite = ControllerSwitch(mac: liteMAC, name: "USW-Imagerie", model: "USW-Lite-8-PoE", firmware: "6.6.61", serial: "74ACB9104050",
                                    ip: ip("192.168.20.3"), online: true, uptime: 3_541_900, poeBudgetW: 52,
                                    ports: ports(count: 8, poe: true, used: Dictionary(uniqueKeysWithValues: [
                                        port(1, "Vers accueil", uplink: true, neighbor: ControllerNeighbor(name: "USW-Pro-Accueil", port: "Port 17", mac: proMAC,
                                                                                                          isInfrastructure: true), tagged: [20]),
                                        port(2, "Station RX 1", vlan: 20), port(3, "Station RX 2", vlan: 20), port(4, "Serveur PACS", vlan: 20),
                                        port(5, vlan: 1, poeW: 12.4, poeClass: 4),
                                        port(6, "Imprimante imagerie", speed: 100, vlan: 20, errors: 2_310),
                                    ])))
        let proRef = (proMAC, "USW-Pro-Accueil")
        let liteRef = (liteMAC, "USW-Imagerie")
        var clients: [ControllerClient] = [
            wired("B0:7B:25:30:00:01", "192.168.1.50", "POSTE-ACCUEIL-01", sw: proRef, port: 2, vendor: "Dell", now: now),
            wired("B0:7B:25:30:00:02", "192.168.1.51", "POSTE-ACCUEIL-02", sw: proRef, port: 3, vendor: "Dell", now: now),
            wired("B0:7B:25:30:00:03", "192.168.1.52", "POSTE-ACCUEIL-03", sw: proRef, port: 4, vendor: "Dell", now: now),
            wired("B0:7B:25:30:00:04", "192.168.1.53", "POSTE-DR-ROY", sw: proRef, port: 5, vendor: "Dell", now: now),
            wired("3C:22:FB:7E:05:B2", "192.168.1.54", "iMac-Dre-Lavoie", sw: proRef, port: 6, vendor: "Apple", now: now),
            wired("B0:7B:25:30:00:06", "192.168.1.55", "POSTE-SALLE-1", sw: proRef, port: 7, vendor: "Dell", now: now),
            wired("00:1B:A9:5E:70:01", "192.168.1.30", "Imprimante accueil", sw: proRef, port: 10, vendor: "Brother", now: now),
            wired("80:5E:C0:3A:61:21", "192.168.1.40", "TEL-ACCUEIL", sw: proRef, port: 13, vendor: "Yealink", now: now),
            wired("80:5E:C0:3A:61:22", "192.168.1.41", "TEL-DR-ROY", sw: proRef, port: 14, vendor: "Yealink", now: now),
            wired("00:0E:C6:20:00:31", "192.168.20.31", "STATION-RX-01", sw: liteRef, port: 2, vlan: 20, vendor: "HP", now: now),
            wired("00:0E:C6:20:00:32", "192.168.20.32", "STATION-RX-02", sw: liteRef, port: 3, vlan: 20, vendor: "HP", now: now),
            wired("D0:94:66:20:00:10", "192.168.20.10", "PACS-01", sw: liteRef, port: 4, vlan: 20, vendor: "Dell", now: now),
            wired("00:1B:A9:5E:70:02", "192.168.20.30", "Imprimante imagerie", sw: liteRef, port: 6, vlan: 20, vendor: "Brother", now: now),
        ]
        clients += [
            wifi("F2:6A:19:C4:0E:58", "192.168.1.61", "iPhone-Dre-Lavoie", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz5, rssi: -54, rate: 866, now: now),
            wifi("A4:83:E7:11:22:33", "192.168.1.62", "MacBook-Accueil", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz5, rssi: -49, rate: 1201, vendor: "Apple", now: now),
            wifi("A4:83:E7:11:22:34", "192.168.1.63", "MacBook-Dr-Roy", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz5, rssi: -61, rate: 780, vendor: "Apple", now: now),
            wifi("58:D9:D5:40:00:01", "192.168.1.64", "iPad-Accueil-1", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz5, rssi: -58, rate: 573, vendor: "Apple", now: now),
            wifi("58:D9:D5:40:00:02", "192.168.1.65", "iPad-Accueil-2", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz5, rssi: -63, rate: 433, vendor: "Apple", now: now),
            wifi("D2:11:8A:6C:00:01", "192.168.1.120", "Galaxy-A54", ap: apAccueil, ssid: "Clinique-Invites", band: .ghz24, rssi: -66, vlan: 1, rate: 72, now: now),
            wifi("E8:48:B8:00:10:01", "192.168.1.70", "Balance-connectee", ap: apAccueil, ssid: "Clinique-Personnel", band: .ghz24, rssi: -71, rate: 65, vendor: "Withings", now: now),
            wifi("9A:3C:55:21:00:02", "192.168.1.121", "iPhone-Patient", ap: apAttente, ssid: "Clinique-Invites", band: .ghz5, rssi: -68, rate: 390, now: now),
            wifi("9A:3C:55:21:00:03", "192.168.1.122", "Pixel-8", ap: apAttente, ssid: "Clinique-Invites", band: .ghz5, rssi: -72, rate: 243, now: now),
            wifi("9A:3C:55:21:00:04", "192.168.1.123", "Surface-Go", ap: apAttente, ssid: "Clinique-Invites", band: .ghz5, rssi: -59, rate: 520, now: now),
            wifi("9A:3C:55:21:00:05", "192.168.1.124", "Kindle", ap: apAttente, ssid: "Clinique-Invites", band: .ghz24, rssi: -77, rate: 39, now: now),
            wifi("58:D9:D5:40:00:20", "192.168.20.40", "iPad-Imagerie", ap: apImagerie, ssid: "Clinique-Personnel", band: .ghz5, rssi: -57, vlan: 20, rate: 650, vendor: "Apple", now: now),
            wifi("40:1C:83:20:00:41", "192.168.20.41", "Portable-Technicien", ap: apImagerie, ssid: "Clinique-Personnel", band: .ghz5, rssi: -64, vlan: 20, rate: 480, vendor: "Intel", now: now),
        ]
        return ControllerReport(kind: .unifi, controllerName: "UDM-Pro-Clinique", version: "9.0.114", siteName: "Default",
                                switches: [pro, lite], aps: [apAccueil, apAttente, apImagerie], clients: clients,
                                calls: demoCalls(.unifi), readAt: now.addingTimeInterval(-95))
    }

    // MARK: Omada · Bureau Québec

    static func omadaReport(now: Date) -> ControllerReport {
        let swMAC = m("50:91:E3:00:10:01")
        let apAccueil = ControllerAP(mac: m("50:91:E3:00:20:01"), name: "EAP-QC-Accueil", model: "EAP650", firmware: "1.0.4", serial: "2231B0000201",
                                     ip: ip("10.30.0.21"), online: true, uptime: 604_800,
                                     radios: [ControllerRadio(band: .ghz24, channel: 6, widthMHz: 20, txPowerDBm: 17, clientCount: 1, utilization: 38),
                                              ControllerRadio(band: .ghz5, channel: 44, widthMHz: 80, txPowerDBm: 22, clientCount: 4, utilization: 21)],
                                     uplinkSwitchMAC: swMAC, uplinkSwitchName: "SW-QC-01", uplinkPort: 1, ssids: ["QC-Bureau", "QC-Invites"])
        let apBureaux = ControllerAP(mac: m("50:91:E3:00:20:02"), name: "EAP-QC-Bureaux", model: "EAP670", firmware: "1.1.2", serial: "2231B0000202",
                                     ip: ip("10.30.0.22"), online: true, uptime: 604_500,
                                     radios: [ControllerRadio(band: .ghz24, channel: 11, widthMHz: 20, txPowerDBm: 17, clientCount: 0, utilization: 29),
                                              ControllerRadio(band: .ghz5, channel: 149, widthMHz: 80, txPowerDBm: 22, clientCount: 3, utilization: 14)],
                                     uplinkSwitchMAC: swMAC, uplinkSwitchName: "SW-QC-01", uplinkPort: 2, ssids: ["QC-Bureau", "QC-Invites"])
        let gateway = ControllerNeighbor(name: "ER605-QC", port: "WAN/LAN2", mac: m("50:91:E3:00:30:01"), ip: ip("10.30.0.1"), isInfrastructure: true)
        let sw = ControllerSwitch(mac: swMAC, name: "SW-QC-01", model: "TL-SG3428MP", firmware: "2.0.12", serial: "2231A0000101",
                                  ip: ip("10.30.0.2"), online: true, uptime: 1_209_600, poeBudgetW: 384,
                                  ports: ports(count: 24, sfp: 4, poe: true, used: Dictionary(uniqueKeysWithValues: [
                                      port(1, poeW: 11.2, poeClass: 4), port(2, poeW: 13.5, poeClass: 4),
                                      port(3, "Poste QC 1"), port(4, "Poste QC 2"), port(5, "Poste QC 3"), port(6, "Poste QC 4"),
                                      port(8, "Salle de réunion", speed: 100), port(11, "Imprimante QC", speed: 100),
                                      port(12, "Téléphone QC 1", speed: 100, poeW: 4.1, poeClass: 2),
                                      port(13, "Téléphone QC 2", speed: 100, poeW: 3.8, poeClass: 2),
                                      port(24, "Uplink ER605", uplink: true, neighbor: gateway, tagged: [99], poe: false),
                                  ])))
        let ref = (swMAC, "SW-QC-01")
        var clients: [ControllerClient] = [
            wired("B0:7B:25:31:00:01", "10.30.0.50", "POSTE-QC-01", sw: ref, port: 3, vendor: "Dell", now: now),
            wired("B0:7B:25:31:00:02", "10.30.0.51", "POSTE-QC-02", sw: ref, port: 4, vendor: "Dell", now: now),
            wired("B0:7B:25:31:00:03", "10.30.0.52", "POSTE-QC-03", sw: ref, port: 5, vendor: "Dell", now: now),
            wired("3C:22:FB:7E:05:C1", "10.30.0.53", "iMac-Direction", sw: ref, port: 6, vendor: "Apple", now: now),
            wired("00:0D:F0:10:20:30", "10.30.0.60", "Écran-Réunion", sw: ref, port: 8, vendor: "Logitech", now: now),
            wired("00:80:77:31:00:11", "10.30.0.30", "IMPRIMANTE-QC", sw: ref, port: 11, vendor: "Brother", now: now),
            wired("80:5E:C0:3A:62:01", "10.30.0.40", "TEL-QC-01", sw: ref, port: 12, vendor: "Yealink", now: now),
            wired("80:5E:C0:3A:62:02", "10.30.0.41", "TEL-QC-02", sw: ref, port: 13, vendor: "Yealink", now: now),
        ]
        clients += [
            wifi("F2:6A:19:C4:0E:77", "10.30.0.61", "Galaxy-S23", ap: apAccueil, ssid: "QC-Bureau", band: .ghz5, rssi: -61, rate: 866, now: now),
            wifi("A4:83:E7:44:55:61", "10.30.0.62", "MacBook-QC-1", ap: apAccueil, ssid: "QC-Bureau", band: .ghz5, rssi: -52, rate: 1201, vendor: "Apple", now: now),
            wifi("A4:83:E7:44:55:62", "10.30.0.63", "MacBook-QC-2", ap: apAccueil, ssid: "QC-Bureau", band: .ghz5, rssi: -58, rate: 960, vendor: "Apple", now: now),
            wifi("D2:11:8A:6C:01:01", "192.168.1.110", "iPhone-Visiteur", ap: apAccueil, ssid: "QC-Invites", band: .ghz5, rssi: -69, vlan: 99, rate: 286, now: now),
            wifi("E8:48:B8:01:10:01", "192.168.1.111", "Android-Visiteur", ap: apAccueil, ssid: "QC-Invites", band: .ghz24, rssi: -74, vlan: 99, rate: 58, now: now),
            wifi("A4:83:E7:44:55:66", "10.30.0.64", "MacBook-Comptabilité", ap: apBureaux, ssid: "QC-Bureau", band: .ghz5, rssi: -78, rate: 144, vendor: "Apple", now: now),
            wifi("40:1C:83:31:00:41", "10.30.0.65", "Portable-Ventes", ap: apBureaux, ssid: "QC-Bureau", band: .ghz5, rssi: -63, rate: 520, vendor: "Intel", now: now),
            wifi("58:D9:D5:41:00:01", "10.30.0.66", "iPad-Direction", ap: apBureaux, ssid: "QC-Bureau", band: .ghz5, rssi: -55, rate: 650, vendor: "Apple", now: now),
        ]
        return ControllerReport(kind: .omada, controllerName: "Omada · Bureau Québec", version: "5.14.26.1", siteName: "Bureau Québec",
                                switches: [sw], aps: [apAccueil, apBureaux], clients: clients, calls: demoCalls(.omada),
                                readAt: now.addingTimeInterval(-140))
    }

    // MARK: Meraki · Usine Drummondville

    static func merakiReport(now: Date) -> ControllerReport {
        let prodMAC = m("E0:55:3D:10:00:01")
        let autoMAC = m("E0:55:3D:10:00:02")
        let atelier = ControllerAP(mac: m("E0:55:3D:20:00:02"), name: "MR46-Atelier", model: "MR46", firmware: "MR 29.7", serial: "Q2KD-BBBB-0002",
                                   ip: ip("10.40.0.21"), online: true,
                                   radios: [ControllerRadio(band: .ghz24, channel: 11, widthMHz: 20, txPowerDBm: 18),
                                            ControllerRadio(band: .ghz5, channel: 36, widthMHz: 40, txPowerDBm: 20)],
                                   uplinkSwitchMAC: prodMAC, uplinkSwitchName: "MS120-Production", uplinkPort: 1, ssids: ["Usine-Interne", "Usine-Scanners"])
        let bureau = ControllerAP(mac: m("E0:55:3D:20:00:03"), name: "MR36-Bureau", model: "MR36", firmware: "MR 29.7", serial: "Q2KD-BBBB-0003",
                                  ip: ip("10.40.0.22"), online: true,
                                  radios: [ControllerRadio(band: .ghz24, channel: 1, widthMHz: 20, txPowerDBm: 15),
                                           ControllerRadio(band: .ghz5, channel: 100, widthMHz: 40, txPowerDBm: 18)],
                                  uplinkSwitchMAC: prodMAC, uplinkSwitchName: "MS120-Production", uplinkPort: 2, ssids: ["Usine-Interne"])
        let quai = ControllerAP(mac: m("E0:55:3D:20:00:04"), name: "MR46-Quai", model: "MR46", firmware: "MR 29.7", serial: "Q2KD-BBBB-0004",
                                ip: ip("10.40.0.23"), online: false, radios: [], ssids: [])
        let mx = ControllerNeighbor(name: "MX68-Usine", port: "Port 3", mac: m("E0:55:3D:30:00:03"), ip: ip("10.40.0.1"), isInfrastructure: true)
        let prod = ControllerSwitch(mac: prodMAC, name: "MS120-Production", model: "MS120-24P", firmware: "MS 16.7", serial: "Q2HP-AAAA-0001",
                                    ip: ip("10.40.0.2"), online: true, poeBudgetW: 370,
                                    ports: ports(count: 24, sfp: 4, poe: true, used: Dictionary(uniqueKeysWithValues: [
                                        port(1, "MR46 atelier", poeW: 12.6, tagged: [12]), port(2, "MR36 bureau", poeW: 9.4, tagged: [12]),
                                        (3, ControllerPort(number: 3, name: "MR46 quai", linkUp: false, enabled: true, poeCapable: true,
                                                           poeEnabled: true, poePowerW: 0, nativeVLAN: 1, taggedVLANs: [12])),
                                        port(5, "Poste contremaître"), port(6, "Poste qualité"), port(7, "Poste expédition"),
                                        port(9, "Horodateur", speed: 100, poeW: 5.2),
                                        port(11, "Caméra atelier", speed: 100, poeW: 6.8),
                                        port(12, "Caméra quai", speed: 100, poeW: 0, alerts: ["PoE overload"]),
                                        port(23, "Vers automates", uplink: true, neighbor: ControllerNeighbor(name: "MS120-Automates", port: "Port 9",
                                                                                                             mac: autoMAC, isInfrastructure: true),
                                             tagged: [12], poe: false),
                                        port(24, "Uplink MX", speed: 1000, uplink: true, neighbor: mx, tagged: [12], poe: false),
                                    ])))
        let auto = ControllerSwitch(mac: autoMAC, name: "MS120-Automates", model: "MS120-8LP", firmware: "MS 16.7", serial: "Q2HP-AAAA-0005",
                                    ip: ip("10.40.12.2"), online: true, poeBudgetW: 67,
                                    ports: ports(count: 8, sfp: 2, poe: true, used: Dictionary(uniqueKeysWithValues: [
                                        port(1, "Automate L1", speed: 100, vlan: 12, poe: false), port(2, "Automate L2", speed: 100, vlan: 12, poe: false),
                                        port(3, "Automate L3", speed: 100, vlan: 12, errors: 0, alerts: ["CRC align errors"], poe: false),
                                        port(4, "IHM ligne 1", vlan: 12, poeW: 7.9), port(5, "IHM ligne 2", vlan: 12, poeW: 8.3),
                                        port(9, "Vers production", uplink: true, neighbor: ControllerNeighbor(name: "MS120-Production", port: "Port 23",
                                                                                                             mac: prodMAC, isInfrastructure: true),
                                             tagged: [12], poe: false),
                                    ])))
        let prodRef = (prodMAC, "MS120-Production")
        let autoRef = (autoMAC, "MS120-Automates")
        var clients: [ControllerClient] = [
            wired("B0:7B:25:32:00:01", "10.40.0.50", "POSTE-CONTREMAITRE", sw: prodRef, port: 5, vendor: "Dell", now: now),
            wired("B0:7B:25:32:00:02", "10.40.0.51", "POSTE-QUALITE", sw: prodRef, port: 6, vendor: "Dell", now: now),
            wired("B0:7B:25:32:00:03", "10.40.0.52", "POSTE-EXPEDITION", sw: prodRef, port: 7, vendor: "Dell", now: now),
            wired("00:40:9D:32:00:09", "10.40.0.60", "Horodateur", sw: prodRef, port: 9, vendor: "Digi", now: now),
            wired("BC:AD:28:32:00:11", "10.40.0.70", "CAM-ATELIER", sw: prodRef, port: 11, vendor: "Hikvision", now: now),
            wired("00:30:DE:40:12:01", "10.40.12.41", "Automate-L1", sw: autoRef, port: 1, vlan: 12, vendor: "WAGO", now: now),
            wired("00:30:DE:40:12:02", "10.40.12.42", "Automate-L2", sw: autoRef, port: 2, vlan: 12, vendor: "WAGO", now: now),
            wired("00:30:DE:40:12:03", "10.40.12.43", "Automate-L3", sw: autoRef, port: 3, vlan: 12, vendor: "WAGO", now: now),
            wired("00:0E:8C:40:12:04", "10.40.12.44", "IHM-L1", sw: autoRef, port: 4, vlan: 12, vendor: "Siemens", now: now),
            wired("00:0E:8C:40:12:05", "10.40.12.45", "IHM-L2", sw: autoRef, port: 5, vlan: 12, vendor: "Siemens", now: now),
        ]
        // Meraki ne donne pas le signal des clients dans sa liste : rssi absent.
        clients += [
            wifi("F2:6A:19:C4:0E:99", "10.40.0.77", "Tablette-Atelier", ap: atelier, ssid: "Usine-Interne", band: .ghz5, rssi: nil, vendor: "Samsung", now: now),
            wifi("00:07:4D:40:00:01", "10.40.12.81", "Scanner-Zebra-01", ap: atelier, ssid: "Usine-Scanners", band: .ghz24, rssi: nil, vlan: 12, vendor: "Zebra Technologies", now: now),
            wifi("00:07:4D:40:00:02", "10.40.12.82", "Scanner-Zebra-02", ap: atelier, ssid: "Usine-Scanners", band: .ghz24, rssi: nil, vlan: 12, vendor: "Zebra Technologies", now: now),
            wifi("00:07:4D:40:00:03", "10.40.12.83", "Scanner-Zebra-03", ap: atelier, ssid: "Usine-Scanners", band: .ghz24, rssi: nil, vlan: 12, vendor: "Zebra Technologies", now: now),
            wifi("A4:83:E7:55:00:01", "10.40.0.78", "MacBook-Directeur", ap: bureau, ssid: "Usine-Interne", band: .ghz5, rssi: nil, vendor: "Apple", now: now),
            wifi("58:D9:D5:42:00:01", "10.40.0.79", "iPad-Bureau", ap: bureau, ssid: "Usine-Interne", band: .ghz5, rssi: nil, vendor: "Apple", now: now),
        ]
        return ControllerReport(kind: .meraki, controllerName: "Groupe Exemple · Usine Drummondville", siteName: "Usine Drummondville",
                                switches: [prod, auto], aps: [atelier, bureau, quai], clients: clients, calls: demoCalls(.meraki),
                                notes: ["Signal des clients Wi-Fi\u{00A0}: non fourni par la liste des clients de l’API Meraki."],
                                readAt: now.addingTimeInterval(-60))
    }

    // MARK: Appareils des sites (Scanner)

    /// Appareils du dernier scan d'un site de démonstration qui a un contrôleur : clients,
    /// switchs et bornes du contrôleur, sans emplacement (la lecture du contrôleur le donne).
    static func devices(for siteID: UUID, now: Date = Date()) -> [Device] {
        guard let c = controllers(for: siteID).first, let report = report(for: c.id, now: now) else { return [] }
        let seen = now.addingTimeInterval(-3_600)
        var list: [Device] = []
        func type(_ name: String, vendor: String?) -> DeviceType {
            let n = name.lowercased()
            if n.contains("imprimante") { return .imprimante }
            if n.hasPrefix("tel-") { return .telephoneIP }
            if n.contains("iphone") || n.contains("galaxy") || n.contains("pixel") || n.contains("android") { return .telephone }
            if n.contains("cam") { return .camera }
            if n.contains("pacs") { return .serveur }
            if n.contains("automate") || n.contains("ihm") || n.contains("scanner") || n.contains("horodateur") || n.contains("balance") || n.contains("kindle") { return .iot }
            return .poste
        }
        for sw in report.switches {
            guard let ip = sw.ip else { continue }
            list.append(Device(ip: ip, mac: sw.mac, vendor: report.kind.brand, latencyMs: 0.8, openPorts: [22, 443], firstSeen: seen, lastSeen: seen,
                               deviceType: .switch))
        }
        for ap in report.aps {
            guard let ip = ap.ip else { continue }
            list.append(Device(ip: ip, mac: ap.mac, vendor: report.kind.brand, isOnline: ap.online != false, latencyMs: ap.online == false ? nil : 1.4,
                               openPorts: [22], firstSeen: seen, lastSeen: seen, deviceType: .pointAcces))
        }
        for (index, client) in report.clients.enumerated() {
            guard let ip = client.ip else { continue }
            list.append(Device(ip: ip, mac: client.mac, vendor: client.manufacturer,
                               latencyMs: client.isWired ? 1.2 + Double(index % 5) / 10 : 6.5 + Double(index % 7),
                               openPorts: client.hostname?.hasPrefix("POSTE") == true ? [135, 445] : [],
                               firstSeen: seen, lastSeen: seen, deviceType: type(client.hostname ?? "", vendor: client.manufacturer)))
        }
        return list.sorted { $0.ip < $1.ip }
    }

    /// Résultats gardés de ces sites (appareils du dernier scan).
    static func results(now: Date = Date()) -> [String: SiteResults] {
        var map: [String: SiteResults] = [:]
        for (siteID, ranges) in [(SitesDemo.cliniqueID, ["192.168.1.0/24", "192.168.20.0/24"]),
                                 (SitesDemo.quebecID, ["10.30.0.0/24", "192.168.1.0/24"]),
                                 (SitesDemo.drummondID, ["10.40.0.0/24", "10.40.12.0/24"])] {
            let devices = devices(for: siteID, now: now)
            guard !devices.isEmpty else { continue }
            let finished = now.addingTimeInterval(-3_600)
            map[SiteFiles.key(for: siteID)] = SiteResults(devices: devices, lastScanRanges: ranges, startedAt: finished.addingTimeInterval(-38),
                                                          finishedAt: finished, portLabel: "Rapide")
        }
        return map
    }
}
