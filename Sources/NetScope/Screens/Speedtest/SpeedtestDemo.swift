import Foundation
import NetScopeCore

/// Données de démonstration du Speedtest, reprises du croquis (docs/croquis/Speedtest.dc.html).
@MainActor
enum SpeedtestDemo {
    static func apply(to model: SpeedtestModel, now: Date = Date()) {
        let result = SpeedTestSummary(
            downMbps: 912, upMbps: 487, idleLatencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4,
            probesSent: 40, probesLost: 0, streams: 8,
            server: SpeedServerInfo(colo: "YUL", city: "Montréal", country: "CA", clientIP: "203.0.113.24",
                                    asn: 577, asOrganization: "Bell Canada"),
            downloadBytes: 1_140_000_000, uploadBytes: 608_000_000)
        model.loadDemo(result: result, down: curve(912, phase: 2.1), up: curve(487, phase: 1.7),
                       history: history(now: now), lan: lanResult(), lanHost: "10.10.0.20")
        let list = servers
        let favorites = list.filter { ["mlab:yul04", "librespeed:3", "custom:https://vitesse.exemple.ca/"].contains($0.id) }
        model.loadDemoServers(list, prefs: SpeedServerPrefs(favorites: favorites.map(\.stored),
                                                            custom: list.filter { $0.source == .custom }.map(\.stored)),
                              tested: list[0])
    }

    /// Serveurs de démonstration : latences mesurées fictives, noms d'opérateurs inventés.
    static var servers: [SpeedServer] {
        func libre(_ id: Int, _ name: String, _ host: String, _ latency: Double?) -> SpeedServer {
            let parts = LibreSpeedParser.splitName(name)
            return SpeedServer(id: "librespeed:\(id)", source: .librespeed, name: name, city: parts.city, country: parts.country,
                               sponsor: parts.sponsor, host: host, port: 443, baseURL: "https://\(host)/backend/",
                               downloadPath: "garbage.php", uploadPath: "empty.php", pingPath: "empty.php",
                               ipPath: "getIP.php", latencyMs: latency)
        }
        func mlab(_ site: String, _ city: String, _ latency: Double) -> SpeedServer {
            SpeedServer(id: "mlab:\(site)", source: .mlab, name: city, city: city, country: "Canada", sponsor: "Measurement Lab",
                        host: "ndt-mlab1-\(site).mlab-oti.measurement-lab.org", port: 443, site: site, latencyMs: latency)
        }
        var cloudflare = SpeedServer.cloudflare
        cloudflare.latencyMs = 4.2
        var custom = (try? SpeedServer.custom(address: "https://vitesse.exemple.ca/", label: "Serveur du fournisseur")) ?? .cloudflare
        custom.latencyMs = 6.8
        return [
            cloudflare,
            mlab("yul04", "Montréal", 7.8),
            mlab("yul06", "Montréal", 8.6),
            mlab("yyz04", "Toronto", 13.6),
            libre(3, "Montréal, Canada (Fibre Laurentides)", "mtl.fibre-laurentides.exemple.net", 6.1),
            libre(7, "Québec, Canada (Réseau Capitale)", "qc.reseau-capitale.exemple.net", 9.3),
            libre(12, "Toronto, Canada (Northline Hosting)", "yyz.northline.exemple.net", 14.8),
            libre(21, "New York, États-Unis (Hudson Transit)", "nyc.hudson.exemple.net", 19.7),
            libre(25, "Chicago, États-Unis (Lakeside Data)", "chi.lakeside.exemple.net", 27.4),
            libre(40, "Amsterdam, Pays-Bas (Polder IX)", "ams.polder.exemple.net", 88.0),
            libre(44, "Paris, France (Seine Fibre)", "par.seine.exemple.net", 92.5),
            libre(9, "Ottawa, Canada (Outaouais Net)", "ott.outaouais.exemple.net", nil),
            .ooklaAuto,
            SpeedServer(id: "ookla:30514", source: .ookla, name: "Bell Canada · Montréal, QC", city: "Montréal, QC",
                        country: "Canada", sponsor: "Bell Canada", host: "speedtest.mtl.exemple.net", port: 8080,
                        ooklaID: 30514, latencyMs: 5.4),
            custom,
        ]
    }

    /// Montée en régime exponentielle, comme dans le croquis.
    private static func curve(_ target: Double, phase: Double) -> [SpeedPoint] {
        (0..<50).map { index in
            let t = Double(index + 1) * 0.2
            let value = target * (1 - exp(-t / 1.2)) * (1 + 0.03 * sin(Double(index) * phase))
            return SpeedPoint(time: t, mbps: value)
        }
    }

    private static func history(now: Date) -> [SpeedTestRecord] {
        let server = "Cloudflare · YUL · Montréal"
        let cf = SpeedServerSource.cloudflare
        func at(_ days: Double, _ hours: Double) -> Date { now.addingTimeInterval(-(days * 86_400 + hours * 3_600)) }
        var records = [
            SpeedTestRecord(date: at(0, 1), kind: .internet, server: server, interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 912, upMbps: 487, latencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4, streams: 8, serverSource: cf, serverID: "cloudflare:YUL"),
            SpeedTestRecord(date: at(0, 2.2), kind: .internet, origin: "planifié", server: server, interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 905, upMbps: 489, latencyMs: 6, loadedLatencyMs: 17, jitterMs: 1.2, streams: 8, serverSource: cf, serverID: "cloudflare:YUL"),
            SpeedTestRecord(date: at(0.8, 0), kind: .lan, server: "NAS 10.10.0.20:5201", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 941, latencyMs: 0.4, streams: 4),
            SpeedTestRecord(date: at(0.8, 0.1), kind: .lan, server: "NAS 10.10.0.20:5201", interfaceName: "en0", interfaceKind: "Wi-Fi",
                            downMbps: 612, latencyMs: 3.1, streams: 4),
            SpeedTestRecord(date: at(0.9, 0), kind: .internet, server: server, interfaceName: "en0", interfaceKind: "Wi-Fi",
                            downMbps: 588, upMbps: 462, latencyMs: 8, loadedLatencyMs: 42, jitterMs: 4.8, streams: 8, serverSource: cf, serverID: "cloudflare:YUL"),
            SpeedTestRecord(date: at(3, 0), kind: .internet, server: "Cloudflare · YYZ · Toronto", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 884, upMbps: 481, latencyMs: 13, loadedLatencyMs: 24, jitterMs: 1.9, streams: 8, serverSource: cf, serverID: "cloudflare:YYZ"),
            SpeedTestRecord(date: at(1.5, 0), kind: .internet, server: "M-Lab · Montréal (yul04)", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 864, upMbps: 471, latencyMs: 8, loadedLatencyMs: 21, jitterMs: 0.9, streams: 1,
                            serverSource: .mlab, serverID: "mlab:yul04"),
            SpeedTestRecord(date: at(2, 1), kind: .internet, server: "LibreSpeed · Montréal · Fibre Laurentides", interfaceName: "en7",
                            interfaceKind: "Ethernet", downMbps: 897, upMbps: 482, latencyMs: 6, loadedLatencyMs: 19, jitterMs: 1.1,
                            streams: 8, serverSource: .librespeed, serverID: "librespeed:3"),
            SpeedTestRecord(date: at(2.5, 0), kind: .internet, server: "Ookla · Bell Canada · Montréal, QC", interfaceName: "en7",
                            interfaceKind: "Ethernet", downMbps: 921, upMbps: 492, latencyMs: 5, loadedLatencyMs: 16, jitterMs: 0.6,
                            streams: 1, serverSource: .ookla, serverID: "ookla:30514"),
            SpeedTestRecord(date: at(4, 0), kind: .lan, server: "SRV-FICHIERS 10.10.0.12:5201", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 938, latencyMs: 0.5, streams: 4),
        ]
        // Un test par jour sur 30 jours pour la courbe d'évolution.
        for day in 5..<30 {
            let wobble = sin(Double(day) * 1.3)
            records.append(SpeedTestRecord(
                date: at(Double(day), 2), kind: .internet, origin: day % 3 == 0 ? "planifié" : "manuel", server: server,
                interfaceName: "en7", interfaceKind: "Ethernet", downMbps: 900 + 10 * wobble, upMbps: 485 + 3 * wobble,
                latencyMs: 6 + abs(wobble) * 2, loadedLatencyMs: 18, jitterMs: 1.3 + abs(wobble) * 0.3, streams: 8,
                serverSource: cf, serverID: "cloudflare:YUL"))
            if day % 7 == 3 {
                records.append(SpeedTestRecord(
                    date: at(Double(day), 5), kind: .internet, server: "M-Lab · Montréal (yul04)", interfaceName: "en7",
                    interfaceKind: "Ethernet", downMbps: 852 + 12 * wobble, upMbps: 466 + 4 * wobble, latencyMs: 8,
                    loadedLatencyMs: 22, jitterMs: 1.0, streams: 1, serverSource: .mlab, serverID: "mlab:yul04"))
            }
        }
        return records
    }

    private static func lanResult() -> IperfResult {
        let rates: [Double] = [918, 941, 942, 940, 941, 939, 942, 941, 940, 941]
        let retransmits = [12, 0, 0, 3, 0, 0, 1, 0, 0, 0]
        let intervals = rates.enumerated().map { index, rate in
            IperfInterval(start: Double(index), end: Double(index + 1), bytes: Int64(rate * 125_000),
                          bitsPerSecond: rate * 1_000_000, retransmits: retransmits[index])
        }
        return IperfResult(version: "iperf 3.17.1", protocolName: "TCP", streams: 4, duration: 10,
                           localHost: "10.182.122.135", remoteHost: "10.10.0.20", remotePort: 5201,
                           reverse: false, bidirectional: false, intervals: intervals,
                           sentBytes: 1_176_000_000, sentBitsPerSecond: 941_000_000,
                           receivedBytes: 1_174_000_000, receivedBitsPerSecond: 938_500_000, retransmits: 16)
    }
}
