import Foundation
import NetScopeCore

/// WAN et VPN fictifs (note 39), lus « sur » les FortiGate de démonstration. Aucun accès réseau.
///
/// - Siège (FortiGate-60F) : deux liens WAN en SD-WAN, wan1 Bell Fibre 500/50 en bon état mais
///   dont l'envoi est saturé par une sauvegarde OneDrive (mêmes débits que TrafficDemo) et wan2
///   Vidéotron Câble 400/20 dégradé (perte 4 %, gigue élevée, SLA non respecté) ; trois tunnels IPsec,
///   vers Entrepôt Laval et Usine Drummondville montés, vers Bureau Québec tombé ; un serveur
///   d'accès distant (FortiClient) et trois utilisateurs VPN SSL ;
/// - Entrepôt Laval (FortiGate-40F) : un lien WAN sans SD-WAN, le tunnel vers le Siège monté ;
/// - Bureau Québec : jeton manquant ; Usine Drummondville : refusée (HTTP 403).
///
/// Captures : NETSCOPE_OUTIL_DEMO=wan ouvre l'outil ; NETSCOPE_SITES_VUE_OUTILS=tous montre tous
/// les sites ; NETSCOPE_WAN_TUNNEL=VPN-LAVAL choisit le tunnel détaillé (VPN-QUEBEC par défaut) ;
/// NETSCOPE_RAPPORT_WAN=1 coche la section du rapport.
@MainActor
enum WANDemo {
    struct Content {
        var reports: [UUID: WANSiteReport]
        var errors: [UUID: String]
        var calls: [UUID: [FortiCallRecord]]
    }

    static var initialTunnelID: String {
        let name = ProcessInfo.processInfo.environment["NETSCOPE_WAN_TUNNEL"] ?? "VPN-QUEBEC"
        let owner = name.uppercased() == "VPN-SIEGE" ? FortiGateSitesDemo.lavalID : FortiGateSitesDemo.siegeID
        return "\(owner.uuidString)|\(name)"
    }

    static func make(now: Date = Date()) -> Content {
        let siegeReport = siege(now: now)
        var lavalReport = laval(now: now)
        lavalReport.readAt = now.addingTimeInterval(-3 * 60)
        let drummondError = FortiGateError.forbidden(path: WANPaths.interfaceStatus).wanDescription
        return Content(
            reports: [FortiGateSitesDemo.siegeID: WANSiteReport(controllerID: FortiGateSitesDemo.siegeID, site: "Siège", report: siegeReport),
                      FortiGateSitesDemo.lavalID: WANSiteReport(controllerID: FortiGateSitesDemo.lavalID, site: "Entrepôt Laval", report: lavalReport)],
            errors: [FortiGateSitesDemo.quebecID: "Jeton absent\u{00A0}: enregistrez-le dans Réglages › Switchs › Contrôleurs FortiGate.",
                     FortiGateSitesDemo.drummondID: drummondError],
            calls: [FortiGateSitesDemo.siegeID: siegeReport.calls, FortiGateSitesDemo.lavalID: lavalReport.calls,
                    FortiGateSitesDemo.drummondID: [
                        FortiCallRecord(path: WANPaths.system, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
                        FortiCallRecord(path: WANPaths.interfaceStatus, status: 403, outcome: .refused, message: drummondError,
                                        body: #"{"status":"error","http_status":403}"#),
                    ]])
    }

    private static func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

    private static func calls(_ report: WANReadReport, sdwan: Bool) -> [FortiCallRecord] {
        var list = [FortiCallRecord(path: WANPaths.system, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
                    FortiCallRecord(path: WANPaths.interfaceConfig + "?format=" + WANPaths.interfaceFields, status: 200, outcome: .ok,
                                    body: "(démonstration)", items: report.interfaces.count + 9),
                    FortiCallRecord(path: WANPaths.interfaceStatus + "?include_vlan=true&include_aggregate=true", status: 200, outcome: .ok,
                                    body: "(démonstration)", items: report.interfaces.count + 9),
                    FortiCallRecord(path: WANPaths.healthCheck, status: 200, outcome: .ok, body: "(démonstration)",
                                    items: Set(report.health.map(\.checkName)).count)]
        if sdwan {
            list.append(FortiCallRecord(path: WANPaths.members, status: 200, outcome: .ok, body: "(démonstration)", items: report.interfaces.count))
            list.append(FortiCallRecord(path: WANPaths.sdwanConfig, status: 200, outcome: .ok, body: "(démonstration)", items: 1))
        } else {
            list.append(FortiCallRecord(path: WANPaths.members, status: 200, outcome: .ok, body: "(démonstration)", items: 0))
            list.append(FortiCallRecord(path: WANPaths.sdwanConfig, status: 200, outcome: .ok, body: "(démonstration)", items: 1))
        }
        list.append(FortiCallRecord(path: WANPaths.ipsec, status: 200, outcome: .ok, body: "(démonstration)", items: report.tunnels.count))
        list.append(FortiCallRecord(path: WANPaths.ssl, status: 200, outcome: .ok, body: "(démonstration)", items: report.sslUsers?.count ?? 0))
        return list
    }

    // MARK: Siège

    static func siege(now: Date = Date()) -> WANReadReport {
        let system = FortiGateSystem(hostname: "FGT-SIEGE", model: "FortiGate-60F", serial: "FGT60FTK22004711",
                                     version: "v7.2.8", build: 1639, vdom: "root")
        let wan1 = WANInterfaceStatus(name: "wan1", alias: "Bell Fibre", role: "wan", type: "physical", mode: "static", adminUp: true,
                                      linkUp: true, speedMbps: 1000, ip: ip("203.0.113.10"), prefix: 29,
                                      rxBytes: 9_412_884_120_311, txBytes: 1_288_017_442_960, rxErrors: 0, txErrors: 0,
                                      rxBps: 66_400_000, txBps: 48_100_000, estimatedDownKbps: 500_000, estimatedUpKbps: 50_000,
                                      gateway: ip("203.0.113.9"), sdwanZone: "virtual-wan-link", isSDWANMember: true, sessions: 428,
                                      stateChanged: now.addingTimeInterval(-19 * 86_400))
        let wan2 = WANInterfaceStatus(name: "wan2", alias: "Vidéotron Câble", role: "wan", type: "physical", mode: "dhcp", adminUp: true,
                                      linkUp: true, speedMbps: 1000, ip: ip("198.51.100.73"), prefix: 24,
                                      rxBytes: 2_106_330_918_004, txBytes: 402_119_783_210, rxErrors: 1_284, txErrors: 0,
                                      rxBps: 300_000, txBps: 100_000, estimatedDownKbps: 400_000, estimatedUpKbps: 20_000,
                                      gateway: ip("198.51.100.1"), sdwanZone: "virtual-wan-link", isSDWANMember: true, sessions: 3,
                                      stateChanged: now.addingTimeInterval(-47 * 60))
        let checks = [
            WANHealthCheckConfig(name: "Google_DNS", servers: ["8.8.8.8", "8.8.4.4"], proto: "ping", members: ["wan1", "wan2"],
                                 sla: [WANSLATarget(id: 1, latencyMs: 100, jitterMs: 30, lossPercent: 2)]),
            WANHealthCheckConfig(name: "Microsoft_365", servers: ["www.office.com"], proto: "http", members: ["wan1", "wan2"],
                                 sla: [WANSLATarget(id: 1, latencyMs: 150, jitterMs: 40, lossPercent: 3)]),
        ]
        let changed = now.addingTimeInterval(-47 * 60)
        let health = [
            WANHealthMeasure(checkName: "Google_DNS", interface: "wan1", status: "up", latencyMs: 6.8, jitterMs: 0.9, lossPercent: 0,
                             packetsSent: 30_412, packetsReceived: 30_412, slaTargetsMet: [1], stateChanged: now.addingTimeInterval(-19 * 86_400),
                             rxBps: 66_400_000, txBps: 48_100_000, sessions: 428),
            WANHealthMeasure(checkName: "Google_DNS", interface: "wan2", status: "up", latencyMs: 38.6, jitterMs: 12.4, lossPercent: 4,
                             packetsSent: 30_410, packetsReceived: 29_194, slaTargetsMet: [], stateChanged: changed,
                             rxBps: 300_000, txBps: 100_000, sessions: 3),
            WANHealthMeasure(checkName: "Microsoft_365", interface: "wan1", status: "up", latencyMs: 11.2, jitterMs: 1.6, lossPercent: 0,
                             packetsSent: 6_080, packetsReceived: 6_080, slaTargetsMet: [1], stateChanged: now.addingTimeInterval(-19 * 86_400)),
            WANHealthMeasure(checkName: "Microsoft_365", interface: "wan2", status: "up", latencyMs: 44.1, jitterMs: 15.8, lossPercent: 3.2,
                             packetsSent: 6_080, packetsReceived: 5_886, slaTargetsMet: [], stateChanged: changed),
        ]
        func p2(_ name: String, _ dst: String, up: Bool, rx: UInt64, tx: UInt64) -> WANPhase2 {
            WANPhase2(name: name, status: up ? "up" : "down", source: "10.182.0.0/16", destination: dst,
                      incomingBytes: up ? rx : 0, outgoingBytes: up ? tx : 0, expiresIn: up ? 21_604 : nil)
        }
        let tunnels = [
            WANTunnel(name: "VPN-LAVAL", remoteGateway: "192.0.2.44", type: "automatic", comments: "Vers Entrepôt Laval",
                      connectionCount: 1, incomingBytes: 48_204_117_830, outgoingBytes: 61_993_402_118,
                      upSince: now.addingTimeInterval(-(6 * 86_400 + 4 * 3600)),
                      phase2: [p2("VPN-LAVAL-LAN", "10.20.0.0/16", up: true, rx: 48_204_117_830, tx: 61_993_402_118)]),
            WANTunnel(name: "VPN-DRUMMOND", remoteGateway: "192.0.2.130", type: "automatic", comments: "Vers Usine Drummondville",
                      connectionCount: 1, incomingBytes: 12_870_440_115, outgoingBytes: 9_118_204_660,
                      upSince: now.addingTimeInterval(-(2 * 86_400 + 9 * 3600)),
                      phase2: [p2("VPN-DRUMMOND-LAN", "10.40.0.0/16", up: true, rx: 12_870_440_115, tx: 9_118_204_660)]),
            WANTunnel(name: "VPN-QUEBEC", remoteGateway: "203.0.113.30", type: "automatic", comments: "Vers Bureau Québec",
                      connectionCount: 0, incomingBytes: 0, outgoingBytes: 0,
                      phase2: [p2("VPN-QUEBEC-LAN", "10.30.0.0/16", up: false, rx: 0, tx: 0),
                               p2("VPN-QUEBEC-VOIX", "10.40.12.0/24", up: false, rx: 0, tx: 0)]),
            WANTunnel(name: "Nomades", type: "dialup", comments: "FortiClient (accès distant)", connectionCount: 0),
        ]
        let ssl = [WANSSLUser(user: "mgagnon", remoteHost: "70.52.18.144", loginAt: now.addingTimeInterval(-2 * 3600 - 12 * 60)),
                   WANSSLUser(user: "jtremblay", remoteHost: "184.161.40.9", loginAt: now.addingTimeInterval(-38 * 60)),
                   WANSSLUser(user: "technicien", remoteHost: "24.48.77.201", loginAt: now.addingTimeInterval(-6 * 60))]
        var report = WANReadReport(system: system, interfaces: [wan1, wan2], health: health, healthConfig: checks, tunnels: tunnels,
                                   sslUsers: ssl, readAt: now.addingTimeInterval(-40))
        report.calls = calls(report, sdwan: true)
        return report
    }

    // MARK: Entrepôt Laval

    static func laval(now: Date = Date()) -> WANReadReport {
        let system = FortiGateSystem(hostname: "FGT-LAVAL", model: "FortiGate-40F", serial: "FGT40FTK23001802", version: "v7.2.8", build: 1639, vdom: "root")
        let wan = WANInterfaceStatus(name: "wan", alias: "Cogeco Affaires", role: "wan", type: "physical", mode: "dhcp", adminUp: true,
                                     linkUp: true, speedMbps: 1000, ip: ip("192.0.2.44"), prefix: 26,
                                     rxBytes: 1_904_442_117_002, txBytes: 811_204_337_412, rxErrors: 0, txErrors: 0,
                                     rxBps: 9_600_000, txBps: 3_300_000, estimatedDownKbps: 250_000, estimatedUpKbps: 50_000)
        let tunnel = WANTunnel(name: "VPN-SIEGE", remoteGateway: "203.0.113.10", type: "automatic", comments: "Vers Siège",
                               connectionCount: 1, incomingBytes: 61_993_402_118, outgoingBytes: 48_204_117_830,
                               upSince: now.addingTimeInterval(-(6 * 86_400 + 4 * 3600)),
                               phase2: [WANPhase2(name: "VPN-SIEGE-LAN", status: "up", source: "10.20.0.0/16", destination: "10.182.0.0/16",
                                                  incomingBytes: 61_993_402_118, outgoingBytes: 48_204_117_830, expiresIn: 18_220)])
        var report = WANReadReport(system: system, interfaces: [wan], tunnels: [tunnel], sslUsers: [], readAt: now)
        report.notes = ["SD-WAN non configuré sur cette FortiGate\u{00A0}: latence et perte du lien non mesurées (aucune sonde de performance)."]
        report.calls = calls(report, sdwan: false)
        return report
    }
}
