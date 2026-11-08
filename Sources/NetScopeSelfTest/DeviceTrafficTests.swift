import Foundation
import NetScopeCore

// Note 105 : trafic d'un appareil dans sa fiche. Calcul pur (vu de l'appareil, débits entre deux
// relevés, sites jamais confondus) et lecture par un faux transport. Aucun réseau.

/// Faux transport : répond selon l'adresse, « report_by » et le filtre de sessions.
private final class DeviceTrafficTransport: FortiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: (Int, String)]
    private(set) var requests: [String] = []

    init(_ responses: [String: (Int, String)]) {
        self.responses = responses
    }

    static func key(_ path: String, _ detail: String? = nil) -> String {
        detail.map { path + "#" + $0 } ?? path
    }

    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        let detail = query.first { ["report_by", "srcaddr", "dstaddr"].contains($0.name) }.map { item in
            item.name == "report_by" ? item.value ?? "" : item.name
        }
        let key = Self.key(path, detail)
        lock.lock()
        requests.append(key)
        lock.unlock()
        guard let (status, body) = responses[key] ?? responses[path] else {
            return FortiHTTPResponse(status: 404, body: Data(#"{"status":"error","http_status":404}"#.utf8))
        }
        return FortiHTTPResponse(status: status, body: Data(body.utf8))
    }
}

private enum DeviceTrafficFixtures {
    static let ip = IPv4Address("10.182.122.117")!

    static func session(_ source: String, _ destination: String, port: Int = 443, app: String? = nil, sent: UInt64, received: UInt64,
                        serial: String, sport: Int = 50_000, site: String = "Siège", country: String? = nil) -> TrafficSession {
        TrafficSession(site: site, source: IPv4Address(source), sourcePort: sport, destination: IPv4Address(destination), destinationPort: port,
                       proto: "TCP", application: app, sentBytes: sent, receivedBytes: received, country: country, serial: serial)
    }

    static func sessionsJSON(_ rows: [(String, String, Int)]) -> String {
        let items = rows.map { #"{"saddr":"\#($0.0)","sport":5000,"daddr":"\#($0.1)","dport":443,"proto":6,"sentbyte":1000,"rcvdbyte":2000,"serial":\#($0.2)}"# }
        return #"{"status":"success","results":{"details":[\#(items.joined(separator: ","))]}}"#
    }

    static let sources = #"{"status":"success","results":{"details":[{"srcaddr":"10.182.122.117","srcname":"WKS346","sentbyte":9000,"rcvdbyte":3000,"bandwidth":800000,"sessions":3},{"srcaddr":"10.182.122.100","sentbyte":1,"rcvdbyte":1,"bandwidth":5,"sessions":1}]}}"#
    static let threats = #"{"status":"success","results":{"details":[{"threat":"Botnet.C2","srcaddr":"10.182.122.117","threatlevel":"critical","count":4,"blocked":4},{"threat":"Autre","srcaddr":"10.182.122.100","threatlevel":"low","count":1}]}}"#
}

func registerDeviceTrafficTests(_ suite: TestSuite) {
    typealias F = DeviceTrafficFixtures
    let now = Date(timeIntervalSince1970: 1_793_700_000)

    suite.add("Trafic d’un appareil : destinations et applications vues de l’appareil") {
        let read = DeviceTrafficRead(ip: F.ip, sessions: [
            F.session("10.182.122.117", "20.190.128.12", app: "OneDrive", sent: 1000, received: 10, serial: "1"),
            F.session("10.182.122.117", "20.190.128.12", app: "OneDrive", sent: 500, received: 5, serial: "2", sport: 50_001),
            // Connexion entrante : ce que l'autre « envoie », l'appareil le reçoit.
            F.session("10.182.122.50", "10.182.122.117", port: 3389, sent: 70, received: 900, serial: "3"),
        ], readAt: now)
        let overview = DeviceTrafficAnalysis.build(reads: [read], ip: F.ip, now: now)
        try expectEqual(overview.sessionCount, 3, "trois sessions")
        try expectEqual(overview.destinations.count, 2, "deux extrémités")
        try expectEqual(overview.destinations[0].key, "20.190.128.12", "la plus lourde d’abord")
        try expectEqual(overview.destinations[0].sentBytes, 1500, "volumes additionnés")
        try expectEqual(overview.destinations[0].sessions, 2, "sessions additionnées")
        try expectEqual(overview.destinations[1].key, "10.182.122.50", "pour une session entrante : l’autre extrémité")
        try expectEqual(overview.destinations[1].sentBytes, 900, "entrante : envoyé vu de l’appareil")
        try expectEqual(overview.destinations[1].receivedBytes, 70, "entrante : reçu vu de l’appareil")
        try expectEqual(overview.sentBytes, 2400, "total envoyé")
        try expectEqual(overview.receivedBytes, 85, "total reçu")
        try expectEqual(overview.applications.map(\.name), ["OneDrive", "TCP/3389"], "sans contrôle d’applications : protocole et port")
        try expect(overview.receiveBps == nil && overview.sendBps == nil, "premier relevé : débit inconnu par sens")
    }

    suite.add("Trafic d’un appareil : débits entre deux relevés") {
        let before = [F.session("10.182.122.117", "1.1.1.1", sent: 1000, received: 2000, serial: "1"),
                      F.session("8.8.8.8", "10.182.122.117", sent: 100, received: 400, serial: "2")]
        let after = [F.session("10.182.122.117", "1.1.1.1", sent: 2000, received: 2500, serial: "1"),
                     F.session("8.8.8.8", "10.182.122.117", sent: 300, received: 900, serial: "2"),
                     // Apparue entre-temps : ses octets peuvent dater d'avant, pas de débit.
                     F.session("10.182.122.117", "9.9.9.9", sent: 900_000, received: 0, serial: "3")]
        let read = DeviceTrafficRead(ip: F.ip, sessions: after, readAt: now)
        let previous = DeviceTrafficAnalysis.counters(before, at: now.addingTimeInterval(-5))
        let overview = DeviceTrafficAnalysis.build(reads: [read], ip: F.ip, previous: previous, now: now)
        try expectEqual(overview.sendBps ?? -1, Double((1000 + 500) * 8) / 5, "émission : session sortante + réponse entrante")
        try expectEqual(overview.receiveBps ?? -1, Double((500 + 200) * 8) / 5, "réception")
        try expectEqual(overview.bandwidth ?? -1, Double(2200 * 8) / 5, "sans ligne FortiView : somme des sessions")
        try expectEqual(overview.destinations.first { $0.key == "9.9.9.9" }?.bandwidth ?? -1, 0, "session nouvelle sans débit")

        let reused = [F.session("10.182.122.117", "1.1.1.1", sent: 10, received: 10, serial: "1")]
        let spike = DeviceTrafficAnalysis.build(reads: [DeviceTrafficRead(ip: F.ip, sessions: reused, readAt: now)], ip: F.ip, previous: previous, now: now)
        try expectEqual(spike.sendBps ?? -1, 0, "compteur revenu en arrière : pas de pic")

        let stale = DeviceTrafficCounters(at: now.addingTimeInterval(-600), values: previous.values)
        let late = DeviceTrafficAnalysis.build(reads: [read], ip: F.ip, previous: stale, now: now)
        try expect(late.sendBps == nil, "relevés trop éloignés : pas de débit")
    }

    suite.add("Trafic d’un appareil : FortiView prime pour le débit total, autres adresses écartées") {
        let source = TrafficEntry(site: "Siège", view: .sources, key: "10.182.122.117", name: "WKS346", ip: F.ip,
                                  sentBytes: 9000, receivedBytes: 3000, bandwidth: 800_000, sessions: 7)
        let foreign = TrafficEntry(site: "Siège", view: .threats, key: "x", name: "x", ip: IPv4Address("10.182.122.100"))
        let read = DeviceTrafficRead(ip: F.ip, source: source, sessions: [
            F.session("10.182.122.117", "1.1.1.1", sent: 10, received: 20, serial: "1"),
            F.session("10.182.122.100", "1.1.1.1", sent: 999, received: 999, serial: "2"),
        ], threats: [foreign], readAt: now)
        let overview = DeviceTrafficAnalysis.build(reads: [read], ip: F.ip, now: now)
        try expectEqual(overview.bandwidth ?? -1, 800_000, "débit de FortiView")
        try expectEqual(overview.sentBytes, 9000, "volume de FortiView s’il est plus grand")
        try expectEqual(overview.sessionCount, 7, "compte de FortiView s’il est plus grand")
        try expectEqual(overview.sessions.count, 1, "session d’une autre adresse écartée")
        try expect(overview.threats.isEmpty, "menace d’une autre adresse écartée")
        try expect(!overview.isIdle, "appareil actif")
        try expect(DeviceTrafficAnalysis.build(reads: [DeviceTrafficRead(ip: F.ip, readAt: now)], ip: F.ip, now: now).isIdle, "rien lu : inactif")
    }

    suite.add("Trafic d’un appareil : inactif, ou seulement illisible") {
        let empty = DeviceTrafficRead(ip: F.ip, readAt: now)
        let previous = DeviceTrafficCounters(at: now.addingTimeInterval(-5), values: [:])
        let second = DeviceTrafficAnalysis.build(reads: [empty], ip: F.ip, previous: previous, now: now)
        try expect(second.isIdle, "toujours inactif au deuxième relevé")
        try expect(second.bandwidth == nil, "aucun débit inventé")

        let source = TrafficEntry(site: "Siège", view: .sources, key: "10.182.122.117", name: "WKS346", ip: F.ip, bandwidth: 800_000)
        let denied = DeviceTrafficRead(ip: F.ip, source: source, readAt: now, sessionsRead: false)
        let partial = DeviceTrafficAnalysis.build(reads: [denied], ip: F.ip, previous: previous, now: now)
        try expect(partial.sendBps == nil && partial.receiveBps == nil, "sessions illisibles : débits par sens inconnus")
        try expectEqual(partial.bandwidth ?? -1, 800_000, "débit de FortiView gardé")
        try expect(!partial.sessionsKnown, "compteurs à ne pas retenir")

        let nothing = DeviceTrafficRead(ip: F.ip, readAt: now, sourcesRead: false, sessionsRead: false)
        try expect(!DeviceTrafficAnalysis.build(reads: [nothing], ip: F.ip, now: now).isIdle, "rien de lisible : on ne conclut pas à l’inactivité")
    }

    suite.add("Trafic d’un appareil : pays d’une session entrante, relevés sans numéro") {
        let incoming = F.session("45.95.147.236", "10.182.122.117", sent: 1, received: 1, serial: "1", country: "Canada")
        let outgoing = F.session("10.182.122.117", "20.190.128.12", sent: 1, received: 1, serial: "2", country: "United States")
        let overview = DeviceTrafficAnalysis.build(reads: [DeviceTrafficRead(ip: F.ip, sessions: [incoming, outgoing], readAt: now)], ip: F.ip, now: now)
        try expect(overview.destinations.first { $0.key == "45.95.147.236" }?.country == nil, "le pays de l’appareil n’est pas attribué à la source")
        try expectEqual(overview.destinations.first { $0.key == "20.190.128.12" }?.country ?? "", "United States", "pays d’une session sortante")

        // Rangs différents d'un relevé à l'autre : mêmes sessions, débit calculé.
        let a0 = F.session("10.182.122.117", "1.1.1.1", sent: 1000, received: 0, serial: "0")
        let a1 = F.session("10.182.122.117", "1.1.1.1", sent: 2000, received: 0, serial: "1")
        let new = F.session("10.182.122.117", "9.9.9.9", sent: 5, received: 0, serial: "0")
        let previous = DeviceTrafficAnalysis.counters([a0], at: now.addingTimeInterval(-5))
        let moved = DeviceTrafficAnalysis.build(reads: [DeviceTrafficRead(ip: F.ip, sessions: [new, a1], readAt: now)], ip: F.ip, previous: previous, now: now)
        try expectEqual(moved.sendBps ?? -1, Double(1000 * 8) / 5, "session retrouvée malgré son nouveau rang")
    }

    suite.add("Trafic d’un appareil : deux FortiGate du même site ne se confondent pas") {
        let a = F.session("10.182.122.117", "1.1.1.1", sent: 10, received: 0, serial: "1", site: "FGT-A")
        let b = F.session("10.182.122.117", "1.1.1.1", sent: 20, received: 0, serial: "1", site: "FGT-B")
        let overview = DeviceTrafficAnalysis.build(reads: [DeviceTrafficRead(ip: F.ip, sessions: [a], readAt: now),
                                                           DeviceTrafficRead(ip: F.ip, sessions: [b], readAt: now)], ip: F.ip, now: now)
        try expectEqual(overview.sessions.count, 2, "même numéro sur deux FortiGate")
        try expectEqual(overview.destinations[0].sentBytes, 30, "destination réunie")
    }

    suite.add("Trafic d’un appareil : noms repris de l’écran Trafic") {
        let read = DeviceTrafficRead(ip: F.ip, sessions: [F.session("10.182.122.117", "20.190.128.12", app: "OneDrive", sent: 1, received: 1, serial: "1")], readAt: now)
        let known = [TrafficEntry(site: "Siège", view: .destinations, key: "20.190.128.12", name: "onedrive.live.com", ip: IPv4Address("20.190.128.12"), country: "Canada"),
                     TrafficEntry(site: "Siège", view: .applications, key: "OneDrive", name: "OneDrive", category: "Storage", risk: 2)]
        let overview = DeviceTrafficAnalysis.build(reads: [read], ip: F.ip, known: known, now: now)
        try expectEqual(overview.destinations[0].name, "onedrive.live.com", "nom de FortiView")
        try expectEqual(overview.destinations[0].country, "Canada", "pays de FortiView")
        try expectEqual(overview.applications[0].category, "Storage", "catégorie de FortiView")
        try expectEqual(overview.applications[0].risk, 2, "risque de FortiView")
    }

    func reader(_ transport: DeviceTrafficTransport) -> FortiGateReader {
        FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token)
    }
    let realtime = TrafficPaths.realtime
    let sessions = TrafficPaths.sessions
    typealias T = DeviceTrafficTransport

    suite.add("Trafic d’un appareil : lecture filtrée par adresse, dans les deux sens") {
        let transport = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (200, F.threats),
            T.key(sessions, "srcaddr"): (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11)])),
            T.key(sessions, "dstaddr"): (200, F.sessionsJSON([("10.182.122.50", "10.182.122.117", 12)])),
        ])
        let read = try await reader(transport).readDeviceTraffic(ip: F.ip, now: now)
        try expectEqual(read.source?.bandwidth ?? -1, 800_000, "sa ligne Sources")
        try expectEqual(read.threats.map(\.ip), [F.ip], "ses menaces seulement")
        try expectEqual(read.sessions.map(\.serial), ["11", "12"], "sessions des deux sens")
        try expect(read.notes.isEmpty, "aucune remarque")
    }

    suite.add("Trafic d’un appareil : filtre ignoré ou refusé par FortiOS") {
        // Ignoré : la réponse contient d'autres adresses ; une seule requête suffit.
        let ignored = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (200, F.threats),
            sessions: (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11), ("10.182.122.100", "1.1.1.1", 13), ("10.182.122.50", "10.182.122.117", 14)])),
        ])
        let first = try await reader(ignored).readDeviceTraffic(ip: F.ip, now: now)
        try expectEqual(first.sessions.map(\.serial), ["11", "14"], "ses sessions dans la liste générale")
        try expect(!ignored.requests.contains(T.key(sessions, "dstaddr")), "pas de seconde requête inutile")
        try expect(first.notes.contains { $0.contains("ne filtre pas") }, "remarque affichée")

        // Refusé (paramètre inconnu) : la liste générale.
        let refused = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (200, F.threats),
            T.key(sessions, "srcaddr"): (400, "{}"),
            sessions: (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11), ("10.182.122.100", "1.1.1.1", 13)])),
        ])
        let second = try await reader(refused).readDeviceTraffic(ip: F.ip, now: now)
        try expectEqual(second.sessions.map(\.serial), ["11"], "repli sur la liste générale")
        try expect(second.notes.contains { $0.contains("ne filtre pas") }, "remarque affichée")

        // Refus en HTTP 200 « status: error » : même repli, comme l'écran Trafic.
        let soft = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (200, F.threats),
            T.key(sessions, "srcaddr"): (200, #"{"status":"error","error":"invalid parameter"}"#),
            sessions: (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11), ("10.182.122.100", "1.1.1.1", 13)])),
        ])
        let third = try await reader(soft).readDeviceTraffic(ip: F.ip, now: now)
        try expectEqual(third.sessions.map(\.serial), ["11"], "repli après un refus en 200")
    }

    suite.add("Trafic d’un appareil : second sens illisible, vue absente de cette version") {
        for status in [503, 403] {
            let transport = T([
                T.key(realtime, "source"): (200, F.sources),
                T.key(realtime, "threat"): (200, F.threats),
                T.key(sessions, "srcaddr"): (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11)])),
                T.key(sessions, "dstaddr"): (status, "{}"),
            ])
            let read = try await reader(transport).readDeviceTraffic(ip: F.ip, now: now)
            try expectEqual(read.sessions.map(\.serial), ["11"], "sessions sortantes gardées (\(status))")
            try expect(read.sessionsRead, "sessions lues (\(status))")
            try expect(read.notes.contains { $0.contains("entrantes illisibles") }, "remarque affichée (\(status))")
        }

        let noThreats = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (400, "{}"),
            T.key(sessions, "srcaddr"): (200, F.sessionsJSON([])),
            T.key(sessions, "dstaddr"): (200, F.sessionsJSON([])),
        ])
        let read = try await reader(noThreats).readDeviceTraffic(ip: F.ip, now: now)
        try expect(read.notes.contains { $0.contains("vue absente") }, "limite de version, pas une panne")
    }

    suite.add("Trafic d’un appareil : FortiOS 6.4, droits manquants") {
        // 6.4 : l'adresse temps réel n'existe pas, repli sur statistics.
        let legacy = T([
            T.key(TrafficPaths.legacy, "source"): (200, F.sources),
            T.key(TrafficPaths.legacy, "threat"): (200, F.threats),
            T.key(sessions, "srcaddr"): (200, F.sessionsJSON([("10.182.122.117", "1.1.1.1", 11)])),
            T.key(sessions, "dstaddr"): (200, F.sessionsJSON([])),
        ])
        let read = try await reader(legacy).readDeviceTraffic(ip: F.ip, now: now)
        try expect(read.source != nil, "ligne Sources lue sur statistics")
        try expectEqual(legacy.requests.filter { $0.hasPrefix(realtime) }.count, 1, "adresse absente essayée une fois")

        // Sessions refusées seulement : le reste est gardé, avec une remarque.
        let partial = T([
            T.key(realtime, "source"): (200, F.sources),
            T.key(realtime, "threat"): (200, F.threats),
            T.key(sessions, "srcaddr"): (403, "{}"),
        ])
        let kept = try await reader(partial).readDeviceTraffic(ip: F.ip, now: now)
        try expect(kept.source != nil, "ligne Sources gardée")
        try expect(kept.notes.contains { $0.contains("Sessions") }, "remarque sur les sessions")

        // Tout refusé : l'erreur est levée.
        let denied = T([realtime: (403, "{}"), sessions: (403, "{}")])
        do {
            _ = try await reader(denied).readDeviceTraffic(ip: F.ip, now: now)
            try expect(false, "erreur attendue")
        } catch let error as FortiGateError {
            guard case .forbidden = error else { throw TestFailure(message: "403 attendu : \(error)", file: #fileID, line: #line) }
        }
    }
}
