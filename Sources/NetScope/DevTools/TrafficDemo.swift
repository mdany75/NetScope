import Foundation
import NetScopeCore

/// Démonstration de la note 54 (écran Trafic) : trafic FortiView fictif, cohérent avec les
/// appareils de démonstration (DemoData, SitesDemo). Aucun accès réseau.
/// - Siège : le Poste comptabilité (WKS346, 10.182.122.117) envoie une sauvegarde OneDrive qui
///   sature l'envoi du lien wan1 (Bell Fibre 500/50) ; l'appareil inconnu 10.182.122.100 utilise
///   BitTorrent (application inattendue) ; le téléphone Android 10.182.122.133 a contacté un serveur
///   de commande de botnet, bloqué par la FortiGate ; une tentative d'injection vers une caméra
///   Hikvision a été bloquée par l'IPS.
/// - Entrepôt Laval : trafic calme (lecteurs, postes, caméras), lien Cogeco Affaires 250/50 peu chargé.
///
/// Captures : NETSCOPE_ECRANS=trafic ; NETSCOPE_TRAFIC_VUE=analyse (analyse complète),
/// saturation (feuille « Qui sature le lien ? »), menaces, applications, sessions, wan…
/// NETSCOPE_TRAFIC_PERIODE=24h choisit la période.
@MainActor
enum TrafficDemo {
    /// Onglet ou partie demandés par la capture.
    static var requestedView: String? {
        guard CommandLine.arguments.contains("--snapshot") else { return nil }
        return ProcessInfo.processInfo.environment["NETSCOPE_TRAFIC_VUE"]?.lowercased()
    }

    static var requestedPeriod: TrafficPeriod? {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_TRAFIC_PERIODE"]?.lowercased() else { return nil }
        return TrafficPeriod(rawValue: raw)
    }

    /// Relevé fictif d'une FortiGate de démonstration (nil : FortiGate non lue).
    static func report(controllerID: UUID, period: TrafficPeriod, now: Date = Date()) -> TrafficReadReport? {
        switch controllerID {
        case FortiGateSitesDemo.siegeID: return build(siege, links: siegeLinks, threats: siegeThreats, period: period, now: now)
        case FortiGateSitesDemo.lavalID: return build(laval, links: lavalLinks, threats: [], period: period, now: now)
        default: return nil
        }
    }

    /// Erreur de lecture d'une FortiGate de démonstration (Drummondville : droit FortiView manquant).
    static func error(controllerID: UUID) -> String? {
        controllerID == FortiGateSitesDemo.drummondID ? FortiGateError.forbidden(path: TrafficPaths.realtime).trafficDescription : nil
    }

    // MARK: Données

    /// Une ligne fictive : débits en Mb/s (réception, émission) en temps réel, sessions.
    private struct Line {
        var view: TrafficView
        var key: String
        var name: String
        var rxMbps: Double
        var txMbps: Double
        var sessions: Int
        var ip: String? = nil
        var mac: String? = nil
        var host: String? = nil
        var country: String? = nil
        var category: String? = nil
        var risk: Int? = nil
        var policy: Int? = nil
        var interface: String? = nil
        /// Part de la journée où ce trafic a lieu (une sauvegarde ne tourne pas 24 h sur 24).
        var duty: Double = 0.5
    }

    private static let siege: [Line] = [
        // Sources.
        Line(view: .sources, key: "10.182.122.117", name: "WKS346", rxMbps: 1.1, txMbps: 44.2, sessions: 38, ip: "10.182.122.117", mac: "B0:7B:25:44:A1:6C", host: "WKS346", interface: "internal", duty: 0.3),
        Line(view: .sources, key: "10.182.122.100", name: "10.182.122.100", rxMbps: 29.4, txMbps: 2.1, sessions: 214, ip: "10.182.122.100", mac: "3A:1F:C7:02:9B:E4", interface: "internal", duty: 0.4),
        Line(view: .sources, key: "10.182.122.113", name: "PF4L8M20", rxMbps: 17.2, txMbps: 1.2, sessions: 61, ip: "10.182.122.113", mac: "8C:16:45:2B:9E:03", host: "PF4L8M20", interface: "internal"),
        Line(view: .sources, key: "10.182.122.135", name: "Macmini-de-Dany", rxMbps: 5.8, txMbps: 0.4, sessions: 47, ip: "10.182.122.135", mac: "3C:22:FB:7E:05:B1", host: "Macmini-de-Dany", interface: "vlan20"),
        Line(view: .sources, key: "10.182.122.106", name: "BrightSign-D1E876001191", rxMbps: 4.4, txMbps: 0.2, sessions: 6, ip: "10.182.122.106", mac: "90:AC:3F:0D:18:76", host: "BrightSign-D1E876001191", interface: "internal", duty: 0.9),
        Line(view: .sources, key: "10.10.0.31", name: "SRV-BACKUP", rxMbps: 2.9, txMbps: 0.3, sessions: 12, ip: "10.10.0.31", mac: "00:50:56:AA:10:31", host: "SRV-BACKUP", interface: "vlan100"),
        Line(view: .sources, key: "192.168.50.21", name: "DS-2CD2143G2-I", rxMbps: 0.1, txMbps: 2.6, sessions: 4, ip: "192.168.50.21", mac: "BC:AD:28:6F:01:5A", host: "DS-2CD2143G2-I", interface: "vlan40", duty: 1),
        Line(view: .sources, key: "10.182.122.133", name: "Android_89UM1WTN", rxMbps: 1.2, txMbps: 0.2, sessions: 29, ip: "10.182.122.133", mac: "D6:4E:81:7A:33:C0", host: "Android_89UM1WTN", interface: "vlan20"),
        Line(view: .sources, key: "10.10.0.10", name: "SRV-AD-01", rxMbps: 0.5, txMbps: 0.1, sessions: 18, ip: "10.10.0.10", mac: "F4:EE:08:3C:72:A1", host: "SRV-AD-01", interface: "vlan100", duty: 1),
        Line(view: .sources, key: "10.182.122.121", name: "SIP-T54W", rxMbps: 0.09, txMbps: 0.09, sessions: 2, ip: "10.182.122.121", mac: "80:5E:C0:3A:61:21", host: "SIP-T54W", interface: "internal"),
        // Destinations.
        Line(view: .destinations, key: "20.190.128.12", name: "onedrive.live.com", rxMbps: 0.6, txMbps: 31.8, sessions: 22, ip: "20.190.128.12", host: "onedrive.live.com", country: "United States", duty: 0.3),
        Line(view: .destinations, key: "40.108.204.17", name: "exemple-my.sharepoint.com", rxMbps: 0.5, txMbps: 12.4, sessions: 16, ip: "40.108.204.17", host: "exemple-my.sharepoint.com", country: "United States", duty: 0.3),
        Line(view: .destinations, key: "185.21.216.140", name: "185.21.216.140", rxMbps: 14.1, txMbps: 1.1, sessions: 96, ip: "185.21.216.140", country: "Netherlands", duty: 0.4),
        Line(view: .destinations, key: "91.121.88.34", name: "91.121.88.34", rxMbps: 9.6, txMbps: 0.6, sessions: 71, ip: "91.121.88.34", country: "France", duty: 0.4),
        Line(view: .destinations, key: "142.250.65.78", name: "rr3.googlevideo.com", rxMbps: 13.8, txMbps: 0.3, sessions: 8, ip: "142.250.65.78", host: "rr3.googlevideo.com", country: "Canada"),
        Line(view: .destinations, key: "52.112.120.41", name: "teams.microsoft.com", rxMbps: 2.6, txMbps: 0.9, sessions: 12, ip: "52.112.120.41", host: "teams.microsoft.com", country: "Canada"),
        Line(view: .destinations, key: "13.107.4.50", name: "dl.delivery.mp.microsoft.com", rxMbps: 2.8, txMbps: 0.1, sessions: 6, ip: "13.107.4.50", host: "dl.delivery.mp.microsoft.com", country: "United States"),
        Line(view: .destinations, key: "47.91.89.21", name: "hik-connect.com", rxMbps: 0.1, txMbps: 2.6, sessions: 4, ip: "47.91.89.21", host: "hik-connect.com", country: "United States", duty: 1),
        Line(view: .destinations, key: "45.95.147.236", name: "45.95.147.236", rxMbps: 0, txMbps: 0.01, sessions: 12, ip: "45.95.147.236", country: "Russian Federation"),
        // Applications.
        Line(view: .applications, key: "Microsoft.OneDrive", name: "Microsoft.OneDrive", rxMbps: 1.1, txMbps: 44.2, sessions: 38, category: "Storage.Backup", risk: 3, duty: 0.3),
        Line(view: .applications, key: "BitTorrent", name: "BitTorrent", rxMbps: 29.4, txMbps: 2.1, sessions: 214, category: "P2P", risk: 4, duty: 0.4),
        Line(view: .applications, key: "YouTube", name: "YouTube", rxMbps: 13.8, txMbps: 0.3, sessions: 8, category: "Video/Audio", risk: 3),
        Line(view: .applications, key: "HTTPS.BROWSER", name: "HTTPS.BROWSER", rxMbps: 6.1, txMbps: 0.7, sessions: 84, category: "Web.Client", risk: 2),
        Line(view: .applications, key: "BrightSign.Network", name: "BrightSign.Network", rxMbps: 4.4, txMbps: 0.2, sessions: 6, category: "Video/Audio", risk: 2, duty: 0.9),
        Line(view: .applications, key: "Microsoft.Teams", name: "Microsoft.Teams", rxMbps: 2.6, txMbps: 0.9, sessions: 12, category: "Collaboration", risk: 2),
        Line(view: .applications, key: "Microsoft.Windows.Update", name: "Microsoft.Windows.Update", rxMbps: 2.8, txMbps: 0.1, sessions: 6, category: "Update", risk: 1),
        Line(view: .applications, key: "Hikvision.Hik-Connect", name: "Hikvision.Hik-Connect", rxMbps: 0.1, txMbps: 2.6, sessions: 4, category: "IoT", risk: 2, duty: 1),
        Line(view: .applications, key: "DNS", name: "DNS", rxMbps: 0.2, txMbps: 0.1, sessions: 41, category: "Network.Service", risk: 1, duty: 1),
        Line(view: .applications, key: "SIP", name: "SIP", rxMbps: 0.09, txMbps: 0.09, sessions: 2, category: "VoIP", risk: 1),
        // Catégories web.
        Line(view: .webCategories, key: "Information Technology", name: "Information Technology", rxMbps: 3.9, txMbps: 0.5, sessions: 52),
        Line(view: .webCategories, key: "Streaming Media and Download", name: "Streaming Media and Download", rxMbps: 13.8, txMbps: 0.3, sessions: 8),
        Line(view: .webCategories, key: "Business", name: "Business", rxMbps: 1.4, txMbps: 0.2, sessions: 23),
        Line(view: .webCategories, key: "Search Engines and Portals", name: "Search Engines and Portals", rxMbps: 0.8, txMbps: 0.1, sessions: 19),
        Line(view: .webCategories, key: "Peer-to-peer File Sharing", name: "Peer-to-peer File Sharing", rxMbps: 0, txMbps: 0, sessions: 0),
        Line(view: .webCategories, key: "Malicious Websites", name: "Malicious Websites", rxMbps: 0, txMbps: 0, sessions: 0),
        // Interfaces.
        Line(view: .interfaces, key: "wan1", name: "wan1", rxMbps: 66.4, txMbps: 48.1, sessions: 431, interface: "wan1"),
        Line(view: .interfaces, key: "internal", name: "internal", rxMbps: 47.4, txMbps: 51.9, sessions: 319, interface: "internal"),
        Line(view: .interfaces, key: "vlan20", name: "vlan20", rxMbps: 0.7, txMbps: 7.0, sessions: 78, interface: "vlan20"),
        Line(view: .interfaces, key: "vlan100", name: "vlan100", rxMbps: 0.4, txMbps: 3.4, sessions: 30, interface: "vlan100"),
        Line(view: .interfaces, key: "vlan40", name: "vlan40", rxMbps: 2.6, txMbps: 0.1, sessions: 4, interface: "vlan40"),
        Line(view: .interfaces, key: "wan2", name: "wan2", rxMbps: 0.3, txMbps: 0.1, sessions: 3, interface: "wan2"),
        // Politiques.
        Line(view: .policies, key: "3", name: "LAN vers Internet", rxMbps: 59.0, txMbps: 48.0, sessions: 389, category: "policy", policy: 3),
        Line(view: .policies, key: "5", name: "Caméras vers Hik-Connect", rxMbps: 0.1, txMbps: 2.6, sessions: 4, category: "policy", policy: 5),
        Line(view: .policies, key: "7", name: "Wi-Fi invités", rxMbps: 7.0, txMbps: 0.6, sessions: 76, category: "policy", policy: 7),
        Line(view: .policies, key: "1", name: "Serveurs vers Internet", rxMbps: 3.4, txMbps: 0.4, sessions: 30, category: "policy", policy: 1),
        Line(view: .policies, key: "0", name: "Refus implicite", rxMbps: 0, txMbps: 0, sessions: 0, category: "policy", policy: 0),
    ]

    private static let laval: [Line] = [
        Line(view: .sources, key: "10.20.0.41", name: "POSTE-LAV-1", rxMbps: 6.2, txMbps: 0.6, sessions: 33, ip: "10.20.0.41", host: "POSTE-LAV-1", interface: "lan"),
        Line(view: .sources, key: "10.20.0.42", name: "POSTE-LAV-2", rxMbps: 3.1, txMbps: 0.4, sessions: 21, ip: "10.20.0.42", host: "POSTE-LAV-2", interface: "lan"),
        Line(view: .sources, key: "10.20.0.21", name: "LECTEUR-LAV-01", rxMbps: 0.2, txMbps: 0.1, sessions: 3, ip: "10.20.0.21", host: "LECTEUR-LAV-01", interface: "lan", duty: 1),
        Line(view: .sources, key: "10.20.10.31", name: "CAM-LAV-01", rxMbps: 0.1, txMbps: 2.2, sessions: 2, ip: "10.20.10.31", host: "CAM-LAV-01", interface: "vlan10", duty: 1),
        Line(view: .destinations, key: "52.112.120.41", name: "teams.microsoft.com", rxMbps: 3.4, txMbps: 0.6, sessions: 14, ip: "52.112.120.41", host: "teams.microsoft.com", country: "Canada"),
        Line(view: .destinations, key: "10.10.0.10", name: "SRV-AD-01 (VPN)", rxMbps: 1.1, txMbps: 0.4, sessions: 21, ip: "10.10.0.10", host: "SRV-AD-01 (VPN)", country: "Reserved"),
        Line(view: .applications, key: "Microsoft.Teams", name: "Microsoft.Teams", rxMbps: 3.4, txMbps: 0.6, sessions: 14, category: "Collaboration", risk: 2),
        Line(view: .applications, key: "HTTPS.BROWSER", name: "HTTPS.BROWSER", rxMbps: 4.8, txMbps: 0.3, sessions: 37, category: "Web.Client", risk: 2),
        Line(view: .applications, key: "Hikvision.Hik-Connect", name: "Hikvision.Hik-Connect", rxMbps: 0.1, txMbps: 2.2, sessions: 2, category: "IoT", risk: 2, duty: 1),
        Line(view: .webCategories, key: "Business", name: "Business", rxMbps: 2.1, txMbps: 0.2, sessions: 18),
        Line(view: .interfaces, key: "wan", name: "wan", rxMbps: 9.6, txMbps: 3.3, sessions: 59, interface: "wan"),
        Line(view: .interfaces, key: "lan", name: "lan", rxMbps: 1.1, txMbps: 9.5, sessions: 57, interface: "lan"),
        Line(view: .policies, key: "2", name: "Entrepôt vers Internet", rxMbps: 9.5, txMbps: 3.3, sessions: 57, category: "policy", policy: 2),
    ]

    private static let siegeLinks = [
        TrafficLink(site: "", name: "wan1", alias: "Bell Fibre", role: "wan", linkUp: true, speedMbps: 1000, upstreamKbps: 50_000, downstreamKbps: 500_000),
        TrafficLink(site: "", name: "wan2", alias: "Vidéotron Câble", role: "wan", linkUp: true, speedMbps: 1000, upstreamKbps: 20_000, downstreamKbps: 400_000),
        TrafficLink(site: "", name: "internal", role: "lan", linkUp: true, speedMbps: 1000),
    ]

    private static let lavalLinks = [
        TrafficLink(site: "", name: "wan", alias: "Cogeco Affaires", role: "wan", linkUp: true, speedMbps: 1000, upstreamKbps: 50_000, downstreamKbps: 250_000),
        TrafficLink(site: "", name: "lan", role: "lan", linkUp: true, speedMbps: 1000),
    ]

    private static let siegeThreats = [
        TrafficEntry(site: "", view: .threats, key: "Mozi.Botnet|10.182.122.133", name: "Mozi.Botnet", ip: IPv4Address("10.182.122.133"),
                     mac: MACAddress("D6:4E:81:7A:33:C0"), hostname: "Android_89UM1WTN", country: "Russian Federation",
                     incidents: 12, blocked: 12, threatLevel: .high, threatType: "Botnet", action: "blocked"),
        TrafficEntry(site: "", view: .threats, key: "Hikvision.Web.Server.Command.Injection|192.168.50.21", name: "Hikvision.Web.Server.Command.Injection",
                     ip: IPv4Address("192.168.50.21"), hostname: "Caméra quai", country: "China", incidents: 3, blocked: 3,
                     threatLevel: .critical, threatType: "IPS", action: "dropped"),
        TrafficEntry(site: "", view: .threats, key: "Peer-to-peer File Sharing|10.182.122.100", name: "Peer-to-peer File Sharing",
                     ip: IPv4Address("10.182.122.100"), incidents: 34, blocked: 34, threatLevel: .low, threatType: "Filtrage web", action: "blocked"),
    ]

    private static func build(_ lines: [Line], links: [TrafficLink], threats: [TrafficEntry], period: TrafficPeriod, now: Date) -> TrafficReadReport {
        // Volume : débit × durée × part de la période où ce trafic a lieu ; temps réel : 45 min de sessions.
        let seconds = period.seconds ?? 2700
        var entries: [TrafficEntry] = lines.map { line in
            let factor = period.isRealtime || period == .fiveMinutes ? 1 : line.duty
            let rx = UInt64(line.rxMbps * 1_000_000 / 8 * seconds * factor)
            let tx = UInt64(line.txMbps * 1_000_000 / 8 * seconds * factor)
            var entry = TrafficEntry(site: "", view: line.view, key: line.key, name: line.name,
                                     ip: line.ip.flatMap(IPv4Address.init), mac: line.mac.flatMap(MACAddress.init), hostname: line.host,
                                     interface: line.interface, country: line.country, category: line.category,
                                     sentBytes: tx, receivedBytes: rx,
                                     bandwidth: period.isRealtime ? (line.rxMbps + line.txMbps) * 1_000_000 : 0,
                                     sessions: period.isRealtime ? line.sessions : Int(Double(line.sessions) * max(1, (seconds / 300).squareRoot())),
                                     risk: line.risk, policyID: line.policy)
            if line.view == .webCategories, line.rxMbps == 0 {
                // Catégories bloquées : des requêtes, aucun octet.
                let hits = line.key.hasPrefix("Peer") ? 34 : 6
                entry.incidents = hits
                entry.blocked = hits
                entry.action = "blocked"
            }
            return entry
        }
        let scale = period.isRealtime ? 1 : max(1, (seconds / 2700).squareRoot())
        entries += threats.map { threat in
            var copy = threat
            copy.incidents = Int(Double(threat.incidents) * scale)
            copy.blocked = Int(Double(threat.blocked) * scale)
            return copy
        }
        let interfaces = entries.filter { $0.view == .interfaces }
        var withRates = links.map { link -> TrafficLink in
            var copy = link
            if let line = lines.first(where: { $0.view == .interfaces && $0.key == link.name }) {
                let factor = period.isRealtime || period == .fiveMinutes ? 1 : 0.42
                copy.rxBps = line.rxMbps * 1_000_000 * factor
                copy.txBps = line.txMbps * 1_000_000 * factor
            }
            return copy
        }
        if withRates.isEmpty { withRates = TrafficParsers.applyRates(links, interfaces: interfaces) }
        var statuses: [TrafficView: TrafficViewStatus] = [:]
        for view in TrafficView.allCases { statuses[view] = entries.contains { $0.view == view } ? .ok : .empty }
        let sessions = period.isRealtime ? demoSessions(lines) : []
        statuses[.sessions] = sessions.isEmpty ? (period.isRealtime ? .empty : .ok) : .ok
        var notes: [String] = []
        if !period.isRealtime {
            notes.append("Sessions\u{00A0}: seulement en temps réel (FortiOS ne garde pas l’historique des sessions).")
        }
        return TrafficReadReport(period: period, entries: entries, sessions: sessions, links: withRates, statuses: statuses,
                                 endpoint: period.isRealtime ? TrafficPaths.realtime : TrafficPaths.historical, notes: notes,
                                 calls: [FortiCallRecord(path: (period.isRealtime ? TrafficPaths.realtime : TrafficPaths.historical) + "?report_by=source&sort_by=bandwidth&count=50",
                                                         status: 200, outcome: .ok, body: "(démonstration)", items: entries.count)],
                                 readAt: now.addingTimeInterval(-74))
    }

    /// Sessions en cours tirées des sources (applications et destinations cohérentes).
    private static func demoSessions(_ lines: [Line]) -> [TrafficSession] {
        let plan: [(String, Int, String, Int, String, String, Double, Double, Int)] = [
            ("10.182.122.117", 52811, "20.190.128.12", 443, "TCP", "Microsoft.OneDrive", 0.4, 31.8, 2710),
            ("10.182.122.117", 52844, "40.108.204.17", 443, "TCP", "Microsoft.OneDrive", 0.3, 12.4, 2650),
            ("10.182.122.100", 6881, "185.21.216.140", 51413, "UDP", "BitTorrent", 14.1, 1.1, 980),
            ("10.182.122.100", 6881, "91.121.88.34", 6889, "TCP", "BitTorrent", 9.6, 0.6, 1220),
            ("10.182.122.113", 61022, "142.250.65.78", 443, "UDP", "YouTube", 13.8, 0.3, 640),
            ("10.182.122.113", 61190, "52.112.120.41", 3478, "UDP", "Microsoft.Teams", 2.6, 0.9, 1810),
            ("10.182.122.135", 50114, "17.253.144.10", 443, "TCP", "HTTPS.BROWSER", 3.2, 0.2, 140),
            ("10.182.122.106", 49920, "34.120.53.24", 443, "TCP", "BrightSign.Network", 4.4, 0.2, 5400),
            ("10.10.0.31", 51002, "13.107.4.50", 443, "TCP", "Microsoft.Windows.Update", 2.8, 0.1, 380),
            ("192.168.50.21", 40311, "47.91.89.21", 7660, "UDP", "Hikvision.Hik-Connect", 0.1, 2.6, 86_400),
            ("10.182.122.133", 39822, "45.95.147.236", 8443, "TCP", "Unknown.TCP", 0, 0.01, 2),
            ("10.182.122.121", 5060, "10.10.0.20", 5060, "UDP", "SIP", 0.09, 0.09, 9100),
        ]
        let siegeIPs = Set(lines.compactMap(\.ip))
        return plan.enumerated().compactMap { index, p in
            guard siegeIPs.contains(p.0) else { return nil }
            let seconds = Double(min(p.8, 2700))
            return TrafficSession(site: "", source: IPv4Address(p.0), sourcePort: p.1, destination: IPv4Address(p.2), destinationPort: p.3,
                                  proto: p.4, application: p.5, sourceInterface: p.0.hasPrefix("10.10.") ? "vlan100" : (p.0.hasPrefix("192.168.50.") ? "vlan40" : "internal"),
                                  destinationInterface: p.2.hasPrefix("10.10.") ? "vlan100" : "wan1",
                                  policyID: p.0.hasPrefix("192.168.50.") ? 5 : (p.0.hasPrefix("10.10.") ? 1 : 3),
                                  sentBytes: UInt64(p.7 * 1_000_000 / 8 * seconds), receivedBytes: UInt64(p.6 * 1_000_000 / 8 * seconds),
                                  duration: p.8, country: p.2.hasPrefix("185.") ? "Netherlands" : (p.2.hasPrefix("45.95") ? "Russian Federation" : nil),
                                  serial: String(format: "%06x", 0x24c1 + index * 7))
        }
    }
}
