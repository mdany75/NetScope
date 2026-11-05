import Foundation
import NetScopeCore

// Note 54 : trafic FortiView et analyse complète du réseau. Réponses JSON fixes en variantes de
// versions (7.4 realtime-statistics, 6.4 statistics, sans enveloppe, nombres en texte), lecture par
// un faux transport (404 d'une adresse, report_by refusé, 403), fusion multisite, « Qui sature le
// lien ? », règles de l'analyse, sondes de la Surveillance et section de rapport. Aucun réseau.

/// Faux transport qui répond selon l'adresse ET la valeur de « report_by ».
final class TrafficFakeTransport: FortiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: (Int, String)]
    private(set) var requested: [String] = []
    private(set) var queries: [[URLQueryItem]] = []

    init(_ responses: [String: (Int, String)]) {
        self.responses = responses
    }

    static func key(_ path: String, _ reportBy: String? = nil) -> String {
        reportBy.map { path + "#" + $0 } ?? path
    }

    private func take(_ path: String, query: [URLQueryItem]) -> (Int, String)? {
        let reportBy = query.first { $0.name == "report_by" }?.value
        lock.lock()
        defer { lock.unlock() }
        requested.append(Self.key(path, reportBy))
        queries.append(query)
        return responses[Self.key(path, reportBy)] ?? responses[path]
    }

    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        let response = take(path, query: query)
        guard let (status, body) = response else {
            return FortiHTTPResponse(status: 404, body: Data(#"{"http_method":"GET","status":"error","http_status":404}"#.utf8))
        }
        return FortiHTTPResponse(status: status, body: Data(body.utf8))
    }
}

enum TrafficFixtures {
    /// FortiOS 7.4, realtime-statistics : enveloppe « results.details », noms en « _ ».
    static let sources74 = """
    {"http_method":"GET","results":{"details":[
      {"srcaddr":"10.182.122.117","srcname":"WKS346","srcmac":"b0:7b:25:44:a1:6c","srcintf":"internal","sentbyte":1850000000,"rcvdbyte":42000000,"bandwidth":438000000,"tx_bandwidth":430000000,"rx_bandwidth":8000000,"sessions":38},
      {"srcaddr":"10.182.122.100","sentbyte":120000000,"rcvdbyte":610000000,"bandwidth":41000000,"sessions":212},
      {"srcaddr":"10.182.122.113","srcname":"PF4L8M20","sentbyte":9000000,"rcvdbyte":95000000,"bandwidth":6500000,"sessions":44},
      {"srcaddr":"10.182.122.113","srcname":"PF4L8M20","sentbyte":1000000,"rcvdbyte":5000000,"bandwidth":500000,"sessions":2}
    ],"summary":{"total_sessions":296}},"vdom":"root","path":"fortiview","name":"realtime-statistics","status":"success","version":"v7.4.4"}
    """

    static let applications74 = """
    {"results":{"details":[
      {"app_name":"Microsoft.OneDrive","appid":40175,"appcat":"Storage.Backup","apprisk":"medium","sentbyte":1820000000,"rcvdbyte":30000000,"bandwidth":425000000,"sessions":24},
      {"app_name":"BitTorrent","appid":15896,"appcat":"P2P","apprisk":"high","sentbyte":110000000,"rcvdbyte":590000000,"bandwidth":39000000,"sessions":190},
      {"app_name":"Microsoft.Teams","appid":43541,"appcat":"Collaboration","apprisk":2,"sentbyte":30000000,"rcvdbyte":60000000,"bandwidth":5000000,"sessions":12}
    ]}}
    """

    static let destinations74 = """
    {"results":{"details":[
      {"dstaddr":"20.190.128.12","hostname":"onedrive.live.com","dstcountry":"United States","sentbyte":1820000000,"rcvdbyte":30000000,"sessions":24},
      {"dstaddr":"185.21.216.140","dstcountry":"Netherlands","sentbyte":60000000,"rcvdbyte":310000000,"sessions":88},
      {"dstaddr":"142.250.65.78","hostname":"www.google.com","dstcountry":"Canada","sentbyte":2000000,"rcvdbyte":15000000,"sessions":9}
    ]}}
    """

    static let threats74 = """
    {"results":{"details":[
      {"threat":"Mirai.Botnet","threattype":"botnet","threatlevel":"critical","srcaddr":"10.182.122.133","srcname":"Android_89UM1WTN","count":7,"blocked":7,"action":"blocked"},
      {"threat":"Hikvision.Web.Server.Command.Injection","threattype":"ips","threatlevel":"high","count":3,"action":"dropped"},
      {"threat":"Adware.Generic","threattype":"virus","threatlevel":"low","srcaddr":"10.182.122.113","count":1,"action":"passthrough"}
    ]}}
    """

    static let interfaces74 = """
    {"results":{"details":[{"interface":"wan1","sentbyte":1950000000,"rcvdbyte":780000000,"bandwidth":480000000},
                           {"interface":"internal","sentbyte":780000000,"rcvdbyte":1950000000,"bandwidth":480000000}]}}
    """

    static let policies74 = """
    {"results":{"details":[{"policyid":3,"policy_name":"LAN vers Internet","policytype":"policy","sentbyte":1990000000,"rcvdbyte":700000000,"sessions":280}]}}
    """

    static let webCategories74 = """
    {"results":{"details":[{"catdesc":"Information Technology","cat":52,"sentbyte":5000000,"rcvdbyte":80000000,"sessions":40},
                           {"catdesc":"Peer-to-peer File Sharing","cat":24,"count":15,"blocked":15,"action":"blocked"}]}}
    """

    static let sessions74 = """
    {"results":{"details":[
      {"saddr":"10.182.122.117","sport":52811,"daddr":"20.190.128.12","dport":443,"proto":6,"apps":[{"name":"Microsoft.OneDrive","id":40175}],"srcintf":"internal","dstintf":"wan1","policyid":3,"sentbyte":1200000000,"rcvdbyte":9000000,"duration":2710,"country":"United States","serial":"0024c1"},
      {"saddr":"10.182.122.100","sport":6881,"daddr":"185.21.216.140","dport":51413,"proto":17,"apps":["BitTorrent"],"srcintf":"internal","dstintf":"wan1","policyid":3,"sentbyte":60000000,"rcvdbyte":310000000,"duration":980,"serial":"0024c2"},
      {"saddr":"10.182.122.117","sport":52812,"daddr":"20.190.128.13","dport":443,"proto":"tcp","application":"Microsoft.OneDrive","sentbyte":"600000000","rcvdbyte":"2000000","serial":"0024c3"}
    ],"summary":{"session_count":3}}}
    """

    static let interfaceConfig74 = """
    {"results":[{"name":"wan1","alias":"Vidéotron 500/50","role":"wan","estimated-upstream-bandwidth":500000,"estimated-downstream-bandwidth":500000},
                {"name":"internal","role":"lan"},{"name":"wan2","alias":"LTE secours","role":"wan","estimated-upstream-bandwidth":20000,"estimated-downstream-bandwidth":50000}]}
    """

    static let interfaceMonitor74 = """
    {"results":{"wan1":{"name":"wan1","link":true,"speed":1000},"internal":{"name":"internal","link":true,"speed":1000},"wan2":{"name":"wan2","link":true,"speed":1000}}}
    """

    static func full74() -> [String: (Int, String)] {
        let rt = TrafficPaths.realtime
        return [
            TrafficFakeTransport.key(rt, "source"): (200, sources74),
            TrafficFakeTransport.key(rt, "destination"): (200, destinations74),
            TrafficFakeTransport.key(rt, "application"): (200, applications74),
            TrafficFakeTransport.key(rt, "web-category"): (200, webCategories74),
            TrafficFakeTransport.key(rt, "interface"): (200, interfaces74),
            TrafficFakeTransport.key(rt, "policy"): (200, policies74),
            TrafficFakeTransport.key(rt, "threat"): (200, threats74),
            TrafficPaths.sessions: (200, sessions74),
            TrafficPaths.interfacesConfig: (200, interfaceConfig74),
            TrafficPaths.interfacesMonitor: (200, interfaceMonitor74),
        ]
    }

    /// FortiOS 6.4 : seulement /fortiview/statistics, liste sans « details », nombres en texte.
    static let sources64 = """
    {"results":[{"source":"10.20.0.41","hostname":"POSTE-LAV-1","bytes":"52000000","bandwidth":"2.5 Mbps","sessions":"14"},
                {"source":"10.20.0.42","bytes":"9000000","sessions":"3"}],"status":"success","version":"v6.4.15"}
    """
}

func registerTrafficTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)

    suite.add("Trafic : analyse des vues FortiView 7.4 (sources, applications, menaces)") {
        let sources = try trafficRequire(TrafficParsers.entries(Data(TrafficFixtures.sources74.utf8), view: .sources), "sources lisibles")
        try expectEqual(sources.count, 3, "même source deux fois additionnée")
        try expectEqual(sources[0].name, "WKS346", "nom de l’appareil")
        try expectEqual(sources[0].mac?.formatted(.upperColon), "B0:7B:25:44:A1:6C", "MAC")
        try expectEqual(sources[0].bandwidth, 438_000_000, "débit en b/s")
        try expectEqual(sources[2].sessions, 46, "sessions additionnées")
        try expectEqual(sources[1].name, "10.182.122.100", "sans nom : l’adresse")

        let apps = try trafficRequire(TrafficParsers.entries(Data(TrafficFixtures.applications74.utf8), view: .applications), "applications")
        try expectEqual(apps.map(\.risk), [3, 4, 2], "risques texte et nombre")
        try expectEqual(apps[1].category, "P2P", "catégorie")
        // Échelle FortiGuard : le libellé texte donne le même chiffre que le nombre.
        let labels = ["low", "elevated", "medium", "high", "critical", "faible", "modéré", "moyen", "élevé", "critique"]
        let riskJSON = "{\"results\":[" + labels.enumerated().map { i, label in
            "{\"app_name\":\"App\(i)\",\"appid\":\(i + 1),\"apprisk\":\"\(label)\",\"bandwidth\":\(1000 - i),\"sessions\":1}"
        }.joined(separator: ",") + "]}"
        let risks = try trafficRequire(TrafficParsers.entries(Data(riskJSON.utf8), view: .applications), "risques en texte")
        let byName = Dictionary(uniqueKeysWithValues: risks.map { ($0.name, $0.risk) })
        try expectEqual(labels.indices.map { byName["App\($0)"] ?? nil }, [1, 2, 3, 4, 5, 1, 2, 3, 4, 5], "risques texte sur l’échelle 1-5")
        try expectEqual(TrafficFormat.risk(2), "Modéré (2/5)", "libellé du risque 2")
        try expectEqual(TrafficThreatLevel.parse("elevated"), .medium, "« elevated » n’est pas « élevé »")
        try expectEqual(TrafficThreatLevel.parse("élevé"), .high, "« élevé » : élevé")

        let threats = try trafficRequire(TrafficParsers.entries(Data(TrafficFixtures.threats74.utf8), view: .threats), "menaces")
        try expectEqual(threats.map(\.threatLevel), [.critical, .high, .low], "niveaux")
        try expectEqual(threats.map(\.threatType), ["Botnet", "IPS", "Antivirus"], "types en français")
        try expect(threats[0].isBlocked && threats[1].isBlocked && !threats[2].isBlocked, "bloquées selon l’action")
        try expectEqual(threats[0].ip?.description, "10.182.122.133", "appareil visé")

        let web = try trafficRequire(TrafficParsers.entries(Data(TrafficFixtures.webCategories74.utf8), view: .webCategories), "catégories")
        try expect(web[1].isBlocked, "catégorie bloquée")
    }

    suite.add("Trafic : variantes 6.4, sans enveloppe et JSON illisible") {
        let sources = try trafficRequire(TrafficParsers.entries(Data(TrafficFixtures.sources64.utf8), view: .sources), "6.4")
        try expectEqual(sources.count, 2, "deux sources")
        try expectEqual(sources[0].bandwidth, 2_500_000, "débit « 2.5 Mbps »")
        try expectEqual(sources[0].bytes, 52_000_000, "octets en texte, comptés en réception")
        try expectEqual(sources[0].sessions, 14, "sessions en texte")
        let bare = try trafficRequire(TrafficParsers.entries(Data(#"[{"policyid":"7","bytes":100}]"#.utf8), view: .policies), "sans enveloppe")
        try expectEqual(bare.first?.name, "Politique 7", "nom par défaut")
        try expect(TrafficParsers.entries(Data("<html>".utf8), view: .sources) == nil, "pas du JSON")
        try expectEqual(TrafficParsers.entries(Data(#"{"results":{"summary":{}}}"#.utf8), view: .sources)?.count, 0, "résumé seul : vide")

        let sessions = try trafficRequire(TrafficParsers.sessions(Data(TrafficFixtures.sessions74.utf8)), "sessions")
        try expectEqual(sessions.map(\.proto), ["TCP", "UDP", "TCP"], "protocoles")
        try expectEqual(sessions.map(\.application), ["Microsoft.OneDrive", "BitTorrent", "Microsoft.OneDrive"], "applications des sessions")
        try expectEqual(sessions[2].sentBytes, 600_000_000, "octets en texte")

        let links = try trafficRequire(TrafficParsers.links(config: Data(TrafficFixtures.interfaceConfig74.utf8),
                                                       monitor: Data(TrafficFixtures.interfaceMonitor74.utf8)), "liens")
        try expectEqual(links.filter(\.isWAN).map(\.name), ["wan1", "wan2"], "liens WAN par rôle")
        try expectEqual(links[0].downCapacity, 500_000_000, "débit déclaré prioritaire sur la vitesse du port")
    }

    suite.add("Trafic : lecture 7.4 complète par un faux transport") {
        let transport = TrafficFakeTransport(TrafficFixtures.full74())
        let reader = FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token)
        let report = try await reader.readTraffic(TrafficReadOptions(period: .realtime), now: now)
        try expectEqual(report.endpoint, TrafficPaths.realtime, "adresse 7.x")
        try expect(report.statuses.values.allSatisfy { $0 == .ok }, "toutes les vues lues : \(report.statuses)")
        try expectEqual(report.sessions.first?.serial, "0024c1", "sessions triées par octets")
        let wan1 = try trafficRequire(report.links.first { $0.name == "wan1" }, "wan1")
        try expect(abs((wan1.utilization ?? 0) - 68.6) < 0.5, "charge de wan1 calculée : \(wan1.utilization ?? -1)")
        try expect(!transport.requested.contains { $0.hasPrefix(TrafficPaths.legacy) }, "pas d’adresse 6.4")
        let first = try trafficRequire(transport.queries.first, "paramètres")
        try expect(first.contains(URLQueryItem(name: "sort_by", value: "bandwidth")) && first.contains(URLQueryItem(name: "count", value: "50")),
                   "tri et nombre demandés")
        try expect(!first.contains { $0.name == "start" }, "temps réel : ni début ni fin")
    }

    suite.add("Trafic : FortiOS 6.4 (404 puis statistics), report_by refusé, historique") {
        var responses: [String: (Int, String)] = [
            TrafficFakeTransport.key(TrafficPaths.legacy, "source"): (200, TrafficFixtures.sources64),
            TrafficFakeTransport.key(TrafficPaths.legacy, "web-category"): (400, #"{"status":"error","http_status":400}"#),
            TrafficFakeTransport.key(TrafficPaths.legacy, "category"): (200, TrafficFixtures.webCategories74),
        ]
        responses[TrafficPaths.interfacesMonitor] = (200, TrafficFixtures.interfaceMonitor74)
        let transport = TrafficFakeTransport(responses)
        let report = try await FortiGateReader(transport: transport)
            .readTraffic(TrafficReadOptions(period: .day, views: [.sources, .webCategories, .threats]), now: now)
        try expectEqual(report.endpoint, TrafficPaths.legacy, "repli sur l’adresse 6.4")
        try expectEqual(transport.requested.filter { $0.hasPrefix(TrafficPaths.historical) }.count, 1, "adresse 7.x essayée une seule fois")
        try expectEqual(report.statuses[.webCategories], .ok, "deuxième nom de report_by")
        try expectEqual(report.statuses[.threats], .absent, "vue absente")
        let query = try trafficRequire(transport.queries.last { $0.contains { $0.name == "start" } }, "historique daté")
        try expect(query.contains(URLQueryItem(name: "realtime", value: "false")), "realtime=false en 6.4")
        try expect(query.contains(URLQueryItem(name: "end", value: String(Int(now.timeIntervalSince1970)))), "fin = maintenant")
        try expect(report.notes.contains { $0.contains("Menaces") }, "vue absente expliquée")
    }

    suite.add("Trafic : 403 sur toutes les vues → droits FortiView expliqués, 403 partiel noté") {
        let refused = TrafficFakeTransport([TrafficPaths.realtime: (403, #"{"status":"error","http_status":403}"#)])
        do {
            _ = try await FortiGateReader(transport: refused).readTraffic(TrafficReadOptions(views: [.sources, .threats]), now: now)
            throw TestFailure(message: "403 partout : erreur attendue", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expect(error.trafficDescription.contains("FortiView") && error.trafficDescription.contains("Log & Report"), "droits nommés")
        }
        var responses = TrafficFixtures.full74()
        responses[TrafficFakeTransport.key(TrafficPaths.realtime, "threat")] = (403, #"{"status":"error","http_status":403}"#)
        let partial = try await FortiGateReader(transport: TrafficFakeTransport(responses)).readTraffic(TrafficReadOptions(), now: now)
        try expectEqual(partial.statuses[.threats], .refused, "menaces refusées")
        try expectEqual(partial.statuses[.sources], .ok, "le reste est lu")
        try expect(partial.notes.contains { $0.contains("Log & Report") }, "droit à ajouter")
        let rejected = TrafficFakeTransport([TrafficPaths.realtime: (401, "{}")])
        do {
            _ = try await FortiGateReader(transport: rejected).readTraffic(TrafficReadOptions(), now: now)
            throw TestFailure(message: "401 : erreur attendue", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expectEqual(error, .tokenRejected, "jeton refusé")
        }
    }

    func siege() async throws -> TrafficSiteReport {
        let report = try await FortiGateReader(transport: TrafficFakeTransport(TrafficFixtures.full74())).readTraffic(TrafficReadOptions(), now: now)
        return TrafficSiteReport(controllerID: UUID(), site: "Siège", report: report)
    }

    suite.add("Trafic : qui sature le lien, consommateurs, applications, pays, menaces") {
        let overview = TrafficAnalysis.merge([try await siege()], period: .realtime)
        // Lien à 70 % : sous le seuil d'alerte par défaut (80 %).
        var verdict = TrafficAnalysis.whoSaturates(overview)
        try expect(!verdict.isSaturated, "70 % : pas saturé")
        try expectEqual(verdict.consumers.first?.entry.name, "WKS346", "premier consommateur")
        try expectEqual(verdict.consumers.first?.mainApplication, "Microsoft.OneDrive", "application tirée des sessions")
        try expect(verdict.consumers.first?.mainDestination?.contains("onedrive.live.com") == true, "destination nommée")
        verdict = TrafficAnalysis.whoSaturates(overview, thresholds: TrafficThresholds(linkWarningPercent: 60))
        try expect(verdict.isSaturated && verdict.headline.contains("wan1"), "seuil 60 % : saturé, lien nommé")
        try expect(verdict.advice.contains("sauvegarde"), "conseil adapté à une sauvegarde")
        try expectEqual(TrafficAnalysis.unexpectedApplications(overview).map(\.name), ["BitTorrent"], "application inattendue")
        try expectEqual(TrafficAnalysis.unusualCountries(overview).map(\.country), ["Pays-Bas"], "pays inhabituel, nommé en français")
        try expectEqual(TrafficFormat.country("United States"), "États-Unis", "pays FortiView en français")
        let wan = [NetworkWANStatus(site: "Siège", name: "wan1", isUp: true, latencyMs: 120, lossPercent: 0, jitterMs: 5)]
        try expect(NetworkAnalysis.analyze(NetworkAnalysisInput(wan: wan)).findings.filter { $0.id.hasPrefix("wan|") }.isEmpty,
                   "120 ms : sous le seuil de l’onglet WAN (150 ms), pas dégradé")
        try expect(!NetworkAnalysis.analyze(NetworkAnalysisInput(wan: wan, wanThresholds: WANThresholds(latencyMs: 100))).findings.filter { $0.id.hasPrefix("wan|") }.isEmpty,
                   "seuils de l’onglet WAN appliqués à l’analyse")
        try expectEqual(TrafficFormat.country("Russian Federation"), "Russie", "variante GeoIP")
        try expectEqual(TrafficFormat.country("Reserved"), "Réservé", "adresse réservée")
        try expectEqual(TrafficFormat.country("DE"), "Allemagne", "code ISO")
        try expectEqual(TrafficFormat.country("Atlantide"), "Atlantide", "nom inconnu gardé")
        try expectEqual(TrafficAnalysis.threatenedDevices(overview).map(\.ip.description), ["10.182.122.133"], "appareil visé (menace moyenne ou plus)")
        try expectEqual(TrafficAnalysis.sorted(overview.entries(.sources), by: .sessions).first?.name, "10.182.122.100", "tri par sessions")
    }

    suite.add("Trafic : plusieurs sites jamais fusionnés") {
        let a = try await siege()
        let b = TrafficSiteReport(controllerID: UUID(), site: "Entrepôt Laval",
                                  report: TrafficReadReport(period: .realtime,
                                                            entries: TrafficParsers.entries(Data(TrafficFixtures.sources64.utf8), view: .sources) ?? [],
                                                            statuses: [.sources: .ok, .threats: .refused], readAt: now))
        let overview = TrafficAnalysis.merge([a, b], period: .realtime)
        try expect(overview.isMultiSite, "deux sites")
        try expectEqual(Set(overview.entries(.sources).map(\.site)), ["Siège", "Entrepôt Laval"], "lignes marquées du site")
        try expectEqual(Set(overview.entries.map(\.id)).count, overview.entries.count, "identifiants uniques")
        try expectEqual(overview.statuses[.threats], .refused, "pire état d’un site")
        let laval = TrafficAnalysis.consumers(overview).first { $0.entry.site == "Entrepôt Laval" }
        try expect(laval.map { abs($0.sharePercent - 85.2) < 1 } == true, "part calculée par site : \(laval?.sharePercent ?? -1)")
    }

    suite.add("Analyse complète : points classés par gravité, couverture et note") {
        let traffic = TrafficAnalysis.merge([try await siege()], period: .realtime)
        let input = NetworkAnalysisInput(
            traffic: traffic, trafficThresholds: TrafficThresholds(linkWarningPercent: 60),
            wan: [NetworkWANStatus(site: "Siège", name: "wan2", isUp: true, latencyMs: 180, lossPercent: 4),
                  NetworkWANStatus(site: "Siège", name: "VPN-Laval", isTunnel: true, isUp: false)],
            ports: [NetworkPortIssue(site: "Siège", switchName: "SW-ETG2-01", host: "10.182.122.3", port: "1/7", kind: .errors(PortErrorRate(errors: 4_800, seconds: 3600)))],
            unknownDevices: [NetworkUnknownDevice(site: "Siège", ip: "10.182.122.100", name: "10.182.122.100", firstSeen: now.addingTimeInterval(-3600))],
            now: now)
        let result = NetworkAnalysis.analyze(input)
        let titles = result.findings.map(\.title)
        try expectEqual(result.findings.first?.severity, .critical, "critique en premier")
        try expect(titles.contains("Tunnel VPN VPN-Laval tombé"), "tunnel tombé : \(titles)")
        try expect(titles.contains("Lien wan1 saturé"), "lien saturé")
        try expect(titles.contains { $0.contains("BitTorrent") }, "application inattendue")
        try expect(titles.contains { $0.contains("Menace bloquée") && $0.contains("Android") }, "menace bloquée sur l’appareil")
        try expect(titles.contains { $0.hasPrefix("Port SW-ETG2-01 · 1/7") }, "port en erreur")
        try expect(titles.contains { $0.contains("inconnu") && $0.contains("nouveau") }, "inconnu récent")
        try expect(titles.contains("Lien WAN wan2 dégradé"), "WAN dégradé")
        try expect(!titles.contains { $0.contains("WKS346 consomme") }, "consommateur déjà nommé par le lien saturé")
        let order = result.findings.map(\.severity)
        try expectEqual(order, order.sorted(), "classés par gravité")
        try expect(result.coverage.contains { $0.part == "Wi-Fi (FortiAP)" && !$0.analyzed }, "Wi-Fi non lu signalé")
        try expect(result.score > 0 && result.score < 70, "note dégressive, basse sans être nulle : \(result.score)")
        let saturated = result.findings.first { $0.title == "Lien wan1 saturé" }
        try expectEqual(saturated?.target, .link(name: "wan1", site: "Siège"), "cible « Voir »")

        let empty = NetworkAnalysis.analyze(NetworkAnalysisInput(ports: [], unknownDevices: [], now: now))
        try expectEqual(empty.findings.map(\.severity), [.ok], "rien à signaler")
        try expectEqual(empty.score, 100, "note parfaite")
        try expect(empty.coverage.contains { $0.part == "Trafic (FortiView)" && !$0.analyzed }, "trafic non lu")
    }

    suite.add("Sondes de trafic : lien saturé, appareil qui consomme trop, nouvelle menace") {
        let traffic = TrafficAnalysis.merge([try await siege()], period: .realtime)
        var link = MonProbe(name: "Lien", kind: .linkSaturated, target: "*")
        var out = MonTrafficChecks.run(link, target: "*", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem == nil, "70 % < 80 %")
        link.resourceLimit = 60
        out = MonTrafficChecks.run(link, target: "wan1", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem?.contains("WKS346") == true, "cause nommée : \(out.result.problem ?? "")")
        out = MonTrafficChecks.run(link, target: "wan9", traffic: traffic, error: nil, now: now)
        try expectEqual(out.result.value, "Lien introuvable", "lien inconnu")

        let heavy = MonProbe(name: "Conso", kind: .heavyDevice, target: "*")
        out = MonTrafficChecks.run(heavy, target: "*", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem?.contains("Microsoft.OneDrive") == true, "438 Mb/s > 50 Mb/s")
        out = MonTrafficChecks.run(heavy, target: "10.182.122.113", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem == nil, "poste léger")

        var threat = MonProbe(name: "Menaces", kind: .newThreat, target: "*")
        out = MonTrafficChecks.run(threat, target: "*", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem == nil && out.knownThreats?.count == 3, "base apprise sans alerte")
        threat.knownThreats = Array((out.knownThreats ?? []).dropFirst())
        out = MonTrafficChecks.run(threat, target: "*", traffic: traffic, error: nil, now: now)
        try expect(out.result.problem?.hasPrefix("Nouvelle menace") == true, "menace nouvelle : \(out.result.problem ?? "")")
        try expectEqual(out.knownThreats?.count, 3, "base complétée")

        out = MonTrafficChecks.run(threat, target: "*", traffic: nil, error: nil, now: now)
        try expect(out.noData, "sans lecture : rien à évaluer")
        out = MonTrafficChecks.run(threat, target: "*", traffic: nil, error: "Accès refusé", now: now)
        try expect(!out.result.reachable, "erreur de lecture signalée")

        // Décodage tolérant : la base des menaces est relue.
        let data = try JSONEncoder().encode(threat)
        let decoded = try JSONDecoder().decode(MonProbe.self, from: data)
        try expectEqual(decoded.knownThreats, threat.knownThreats, "base enregistrée")
        try expectEqual(MonProbeKind.linkSaturated.label, "Lien saturé", "libellé")
    }

    suite.add("Rapport : section « Trafic et bilan de santé »") {
        let traffic = TrafficAnalysis.merge([try await siege()], period: .realtime)
        let analysis = NetworkAnalysis.analyze(NetworkAnalysisInput(traffic: traffic, now: now))
        let config = ReportConfig(template: .audit, sections: [.trafic])
        var input = ReportInput(devices: [], now: now)
        input.traffic = traffic
        input.networkAnalysis = analysis
        let document = ReportBuilder.build(config: config, input: input)
        let section = try trafficRequire(document.sections.first { $0.kind == .trafic }, "section présente")
        try expectEqual(section.heading, "1. Trafic et bilan de santé", "titre")
        try expect(section.tables.count >= 4, "liens, consommateurs, menaces, analyse : \(section.tables.count)")
        try expect(section.tables.contains { $0.columns.first?.title == "Gravité" }, "tableau de l’analyse")
        var empty = ReportInput(devices: [], now: now)
        empty.traffic = nil
        let none = ReportBuilder.build(config: config, input: empty)
        if case .note(let text)? = none.sections.first?.blocks.first {
            try expect(text.contains("FortiView"), "droit expliqué")
        } else {
            throw TestFailure(message: "note attendue sans trafic", file: #fileID, line: #line)
        }
    }
}

/// Valeur non nulle, sinon échec.
func trafficRequire<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — valeur absente", file: file, line: line) }
    return value
}
