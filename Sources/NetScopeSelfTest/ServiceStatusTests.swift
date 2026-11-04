import Foundation
import NetScopeCore

// Tests de l'état des services en ligne (note 15) : réponses JSON et RSS fixes de chaque format,
// règles du bilan, historique et sonde de Surveillance. Aucun accès réseau : lecture et test
// depuis ce réseau sont remplacés par des faux.

private struct FakeFetcher: SvcFetching {
    /// Réponse par début d'adresse.
    let responses: [String: (String, Int)]

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url?.absoluteString ?? ""
        guard let match = responses.first(where: { url.hasPrefix($0.key) }) else {
            throw SvcParseError.unreadable("adresse inattendue \(url)")
        }
        return (Data(match.value.0.utf8), match.value.1)
    }
}

private struct FakeProber: SvcProbing {
    let failing: [String: SvcFailure]

    func probe(_ url: String) async -> SvcEndpointResult {
        let host = URL(string: url)?.host ?? url
        if let failure = failing[host] {
            return SvcEndpointResult(url: url, host: host, dnsMs: 3, failure: failure)
        }
        return SvcEndpointResult(url: url, host: host, addresses: ["192.0.2.10"], dnsMs: 12, tlsMs: 30, httpMs: 80, httpStatus: 200)
    }
}

private let now = Date(timeIntervalSince1970: 1_793_808_000) // 2026-11-04

private func service(_ format: SvcFeedFormat, page: String = "https://status.exemple.com") -> SvcService {
    SvcService(id: "test", name: "Test", category: "Test", format: format, feedURL: "https://status.exemple.com/feed",
               pageURL: page, endpoints: ["https://a.exemple.com/"])
}

private func parse(_ text: String, _ format: SvcFeedFormat, page: String = "https://status.exemple.com") throws -> SvcFeedReport {
    try SvcFeedParser.parse(Data(text.utf8), service: service(format, page: page), now: now)
}

func registerServiceStatusTests(_ suite: TestSuite) {
    // MARK: Statuspage

    suite.add("Services : Statuspage, incident mineur, composant dégradé et maintenance en cours") {
        let json = """
        {"page":{"id":"x","name":"GitHub","url":"https://www.githubstatus.com","updated_at":"2026-11-04T14:02:11.123Z"},
         "status":{"indicator":"minor","description":"Partially Degraded Service"},
         "components":[{"id":"a","name":"Git Operations","status":"operational","group":false},
                       {"id":"b","name":"Actions","status":"degraded_performance","group":false},
                       {"id":"g","name":"Groupe","status":"major_outage","group":true}],
         "incidents":[{"id":"inc1","name":"Incident with Actions","status":"investigating","impact":"minor",
                       "created_at":"2026-11-04T13:00:00.000Z","updated_at":"2026-11-04T13:30:00.000Z","started_at":"2026-11-04T12:58:00.000Z",
                       "shortlink":"https://stspg.io/abc",
                       "incident_updates":[{"body":"We are <b>investigating</b> reports &amp; delays.","status":"investigating"}],
                       "components":[{"name":"Actions","status":"degraded_performance"}]}],
         "scheduled_maintenances":[{"id":"m1","name":"Database upgrade","status":"in_progress","impact":"maintenance",
                                    "scheduled_for":"2026-11-04T12:00:00Z","updated_at":"2026-11-04T12:00:00Z","incident_updates":[]},
                                   {"id":"m2","name":"Later","status":"scheduled","impact":"maintenance","incident_updates":[]}]}
        """
        let report = try parse(json, .statuspage)
        try expectEqual(report.health, .degraded, "indicateur minor")
        try expectEqual(report.components, [SvcComponent(name: "Actions", health: .degraded)], "composants hors service seulement, sans groupes")
        try expectEqual(report.activeIncidents.count, 2, "incident et maintenance en cours (la planifiée est écartée)")
        let incident = try unwrap(report.incidents.first { $0.id == "inc1" })
        try expectEqual(incident.title, "Incident with Actions", "titre")
        try expectEqual(incident.status, "En cours d’analyse", "statut traduit")
        try expectEqual(incident.affected, ["Actions"], "composants touchés")
        try expectEqual(incident.url, "https://stspg.io/abc", "lien court")
        try expectEqual(incident.latestUpdate, "We are investigating reports & delays.", "texte brut")
        try expectEqual(incident.started, Date(timeIntervalSince1970: 1_793_797_080), "début (started_at)")
        try expectEqual(report.incidents.first { $0.id == "m1" }?.impact, .maintenance, "maintenance")
    }

    suite.add("Services : Statuspage tout opérationnel, panne majeure et réponse invalide") {
        let ok = try parse("""
        {"status":{"indicator":"none","description":"All Systems Operational"},"components":[],"incidents":[],"scheduled_maintenances":[]}
        """, .statuspage)
        try expectEqual(ok.health, .operational, "aucun incident")
        try expectEqual(ok.description, "Aucun incident en cours", "description française")
        let major = try parse("""
        {"status":{"indicator":"major","description":"Partial System Outage"},
         "components":[{"name":"API","status":"partial_outage"}],
         "incidents":[{"id":"x","name":"API errors","status":"identified","impact":"major","incident_updates":[]}]}
        """, .statuspage)
        try expectEqual(major.health, .outage, "major = panne")
        try expectEqual(major.incidents.first?.status, "Cause identifiée", "statut")
        try expectThrows(SvcParseError.unreadable("page HTML au lieu du JSON attendu"), "page HTML") {
            _ = try parse("<!DOCTYPE html><html></html>", .statuspage)
        }
    }

    // MARK: Slack

    suite.add("Services : API Slack Status, panne en cours puis rien") {
        let report = try parse("""
        {"status":"active","date_created":"2026-11-04T09:00:00-08:00","date_updated":"2026-11-04T09:30:00-08:00",
         "active_incidents":[{"id":1234,"date_created":"2026-11-04T09:12:00-08:00","date_updated":"2026-11-04T09:40:00-08:00",
           "title":"Some users can't send messages","type":"outage","status":"active","url":"https://slack-status.com/2026-11/abc",
           "services":["Messaging","Connectivity"],"notes":[{"date_created":"2026-11-04T09:12:00-08:00","body":"<p>We're on it.</p>"}]}]}
        """, .slack, page: "https://slack-status.com")
        try expectEqual(report.health, .outage, "type outage")
        let incident = try unwrap(report.incidents.first)
        try expectEqual(incident.id, "1234", "identifiant numérique")
        try expectEqual(incident.affected, ["Messaging", "Connectivity"], "services")
        try expectEqual(incident.latestUpdate, "We're on it.", "dernière note")
        try expectEqual(incident.started, Date(timeIntervalSince1970: 1_793_812_320), "date avec fuseau")
        let ok = try parse(#"{"status":"ok","active_incidents":[]}"#, .slack)
        try expectEqual(ok.health, .operational, "ok")
    }

    // MARK: Apple

    suite.add("Services : Apple System Status enveloppé dans jsonCallback") {
        let text = """
        jsonCallback({"drpost":false,"services":[
          {"serviceName":"iCloud Mail","redirectUrl":null,"events":[
            {"usersAffected":"Some users are affected","epochStartDate":1793800800000,"epochEndDate":null,"messageId":"1000123",
             "statusType":"Outage","eventStatus":"ongoing","message":"Users may be unable to send mail."}]},
          {"serviceName":"App Store","events":[
            {"usersAffected":"All users","epochStartDate":1793700000000,"epochEndDate":1793703600000,"messageId":"1000100",
             "statusType":"Performance","eventStatus":"resolved","message":"Slow downloads."}]},
          {"serviceName":"Maps","events":[{"statusType":"Maintenance","eventStatus":"upcoming","messageId":"9"}]},
          {"serviceName":"Siri","events":[]}]});
        """
        let report = try parse(text, .apple)
        try expectEqual(report.health, .outage, "panne iCloud Mail")
        try expectEqual(report.activeIncidents.count, 1, "un seul en cours (la maintenance à venir est ignorée)")
        let incident = try unwrap(report.activeIncidents.first)
        try expectEqual(incident.id, "1000123", "messageId")
        try expectEqual(incident.title, "iCloud Mail\u{00A0}: panne", "titre")
        try expectEqual(incident.started, Date(timeIntervalSince1970: 1_793_800_800), "millisecondes")
        try expectEqual(incident.latestUpdate, "Some users are affected Users may be unable to send mail.", "message")
        try expectEqual(report.incidents.filter(\.isResolved).count, 1, "événement résolu gardé pour l’historique")
    }

    // MARK: AWS

    suite.add("Services : AWS Health (JSON en UTF-16 avec BOM)") {
        let json = """
        [{"date":"1793800000","region_name":"N. Virginia","status":"2","service":"ec2-us-east-1","service_name":"Amazon Elastic Compute Cloud",
          "summary":"Increased API Error Rates","event_log":[{"summary":"x","message":"We are investigating increased error rates.","status":2,"timestamp":1793800100},
          {"summary":"y","message":"We have identified the cause.","status":2,"timestamp":1793803000}]},
         {"date":"1793700000","region_name":"Oregon","status":"0","service":"s3-us-west-2","service_name":"Amazon S3",
          "summary":"[RESOLVED] Elevated latencies","event_log":[]}]
        """
        var data = Data([0xFF, 0xFE])
        data.append(json.data(using: .utf16LittleEndian)!)
        let report = try SvcFeedParser.parse(data, service: service(.awsHealth), now: now)
        try expectEqual(report.health, .degraded, "statut 2 = dégradé")
        try expectEqual(report.activeIncidents.count, 1, "le résolu est écarté des incidents en cours")
        let incident = try unwrap(report.activeIncidents.first)
        try expectEqual(incident.affected, ["Amazon Elastic Compute Cloud · N. Virginia"], "service et région")
        try expectEqual(incident.latestUpdate, "We have identified the cause.", "dernière entrée du journal")
        try expectEqual(incident.updated, Date(timeIntervalSince1970: 1_793_803_000), "mise à jour")
        let empty = try SvcFeedParser.parse(Data("[]".utf8), service: service(.awsHealth), now: now)
        try expectEqual(empty.health, .operational, "liste vide")
    }

    // MARK: RSS

    suite.add("Services : flux RSS d’Azure Status (éléments en cours)") {
        let rss = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"><channel><title>Azure Status</title>
        <item><guid isPermaLink="false">VS1-ABC</guid><link>https://azure.status.microsoft/en-us/status/history/</link>
        <category>Virtual Machines</category>
        <title>Virtual Machines - Service outage in East US</title>
        <description><![CDATA[<p>Starting at 13:05 UTC customers may experience <b>failures</b>.</p>]]></description>
        <pubDate>Wed, 04 Nov 2026 13:20:00 GMT</pubDate></item>
        </channel></rss>
        """
        let report = try parse(rss, .azureRSS)
        try expectEqual(report.health, .outage, "« outage » dans le titre")
        let incident = try unwrap(report.activeIncidents.first)
        try expectEqual(incident.id, "VS1-ABC", "guid")
        try expectEqual(incident.affected, ["Virtual Machines"], "catégorie")
        try expectEqual(incident.latestUpdate, "Starting at 13:05 UTC customers may experience failures.", "CDATA en texte brut")
        try expectEqual(incident.started, Date(timeIntervalSince1970: 1_793_798_400), "date RFC 822")
        let empty = try parse(#"<rss version="2.0"><channel><title>Azure</title></channel></rss>"#, .azureRSS)
        try expectEqual(empty.health, .operational, "flux vide")
        try expectThrows(SvcParseError.unreadable("flux RSS ou Atom attendu"), "XML qui n’est pas un flux") {
            _ = try parse("<html><body/></html>", .azureRSS)
        }
    }

    suite.add("Services : flux RSS générique (récent en cours, résolu ou ancien en historique)") {
        let rss = """
        <rss version="2.0"><channel>
        <item><title>Service disruption: API</title><pubDate>Wed, 04 Nov 2026 13:00:00 +0000</pubDate><guid>a</guid></item>
        <item><title>Service is operating normally: Mail</title><pubDate>Wed, 04 Nov 2026 12:00:00 +0000</pubDate><guid>b</guid></item>
        <item><title>Old problem</title><pubDate>Mon, 02 Nov 2026 12:00:00 +0000</pubDate><guid>c</guid></item>
        <item><title>Very old</title><pubDate>Mon, 05 Oct 2026 12:00:00 +0000</pubDate><guid>d</guid></item>
        </channel></rss>
        """
        let report = try parse(rss, .rss)
        try expectEqual(report.activeIncidents.map(\.id), ["a"], "seul l’élément récent non résolu est en cours")
        try expectEqual(report.health, .outage, "disruption = panne")
        try expectEqual(report.incidents.filter(\.isResolved).map(\.id), ["b", "c"], "historique de 7 jours")
    }

    // MARK: Google

    suite.add("Services : Google incidents.json (Workspace et Cloud)") {
        let json = """
        [{"id":"abc123","number":"123","begin":"2026-11-04T13:05:00+00:00","created":"2026-11-04T13:10:00+00:00",
          "modified":"2026-11-04T14:00:00+00:00","external_desc":"Gmail users are experiencing delays\\nMore text",
          "status_impact":"SERVICE_OUTAGE","severity":"high","service_name":"Gmail",
          "affected_products":[{"title":"Gmail","id":"x"}],"uri":"incidents/abc123",
          "most_recent_update":{"text":"Our engineers are **investigating**.","status":"SERVICE_OUTAGE"}},
         {"id":"old","begin":"2026-11-02T10:00:00+00:00","end":"2026-11-02T11:00:00+00:00","external_desc":"Meet issue",
          "status_impact":"SERVICE_DISRUPTION","affected_products":[{"title":"Google Meet"}],"uri":"incidents/old"},
         {"id":"ancient","begin":"2026-09-02T10:00:00+00:00","end":"2026-09-02T11:00:00+00:00","external_desc":"Old"}]
        """
        let report = try parse(json, .googleIncidents, page: "https://www.google.com/appsstatus/dashboard/")
        try expectEqual(report.health, .outage, "SERVICE_OUTAGE")
        let incident = try unwrap(report.activeIncidents.first)
        try expectEqual(incident.title, "Gmail users are experiencing delays", "première ligne")
        try expectEqual(incident.url, "https://www.google.com/appsstatus/dashboard/incidents/abc123", "lien relatif complété")
        try expectEqual(incident.status, "Panne", "statut")
        try expectEqual(incident.affected, ["Gmail"], "produits")
        try expectEqual(report.incidents.filter(\.isResolved).map(\.id), ["old"], "résolu récent gardé, ancien écarté")
    }

    // MARK: Microsoft 365

    suite.add("Services : Microsoft 365, page publique (lecture tolérante)") {
        let report = try parse("""
        {"Value":[{"Id":"MO12345","Title":"Users can't access Outlook on the web","Status":"serviceDegradation",
          "ImpactedServices":["Outlook.com"],"StartTime":"2026-11-04T12:00:00Z","LastUpdatedTime":"2026-11-04T13:00:00Z"},
          {"Id":"MO1","Title":"Fixed","Status":"serviceRestored"}]}
        """, .microsoft365)
        try expectEqual(report.activeIncidents.map(\.id), ["MO12345"], "rétabli écarté")
        try expectEqual(report.health, .degraded, "dégradation")
        try expectEqual(report.activeIncidents.first?.affected, ["Outlook.com"], "services")
        try expectEqual(report.activeIncidents.first?.status, "Dégradation", "statut traduit")
        let empty = try parse("[]", .microsoft365)
        try expectEqual(empty.health, .operational, "aucune publication")
    }

    suite.add("Services : Microsoft Graph, jeton, santé et problèmes du locataire") {
        let credentials = SvcGraphCredentials(tenantID: "contoso.onmicrosoft.com", clientID: "abc", clientSecret: "s3cr&t=+")
        let request = try unwrap(SvcGraph.tokenRequest(credentials))
        try expectEqual(request.url?.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token", "adresse du jeton")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        try expect(body.contains("grant_type=client_credentials"), "client credentials")
        try expect(body.contains("client_secret=s3cr%26t%3D%2B"), "secret encodé : \(body)")
        try expect(body.contains("scope=https%3A%2F%2Fgraph.microsoft.com%2F.default"), "portée Graph")
        try expect(SvcGraph.tokenRequest(SvcGraphCredentials(tenantID: "a/b", clientID: "x", clientSecret: "y")) == nil,
                   "locataire invalide refusé")
        try expectEqual(try SvcGraph.parseToken(Data(#"{"token_type":"Bearer","access_token":"eyJ0"}"#.utf8)), "eyJ0", "jeton")
        try expectThrows(SvcParseError.unreadable("jeton Microsoft refusé (invalid_client) · AADSTS7000215: Invalid client secret."), "secret refusé") {
            _ = try SvcGraph.parseToken(Data(#"{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret.\r\nTrace ID: x"}"#.utf8))
        }
        let overviews = try SvcGraph.parseHealthOverviews(Data("""
        {"value":[{"service":"Exchange Online","status":"serviceOperational","id":"Exchange"},
                  {"service":"Microsoft Teams","status":"serviceDegradation","id":"Teams"},
                  {"service":"Power BI","status":"serviceInterruption","id":"PowerBI"}]}
        """.utf8))
        let issues = try SvcGraph.parseIssues(Data("""
        {"value":[{"id":"TM892341","title":"Delays in chat messages","impactDescription":"Users may see delays.",
          "classification":"incident","status":"investigating","service":"Microsoft Teams","feature":"Chat",
          "startDateTime":"2026-11-04T13:05:00Z","lastModifiedDateTime":"2026-11-04T14:18:00Z","isResolved":false}]}
        """.utf8))
        let report = SvcGraph.report(overviews: overviews, issues: issues)
        try expectEqual(report.health, .degraded, "Power BI (non suivi) n’influence pas le bilan")
        try expectEqual(report.components, [SvcComponent(name: "Teams", health: .degraded)], "nom court des services suivis")
        try expectEqual(report.activeIncidents.first?.affected, ["Teams", "Chat"], "service et fonction")
        try expectEqual(report.activeIncidents.first?.status, "En cours d’analyse", "statut")
    }

    // MARK: Bilan

    suite.add("Services : bilan « panne chez eux » contre « problème chez nous »") {
        let ok = SvcEndpointResult(url: "https://a/", host: "a", dnsMs: 1, tlsMs: 2, httpMs: 3, httpStatus: 200)
        let dns = SvcEndpointResult(url: "https://b/", host: "b", failure: .dns)
        let tls = SvcEndpointResult(url: "https://c/", host: "c", failure: .tls)
        let fine = SvcFeedReport(health: .operational, description: "")
        let outage = SvcFeedReport(health: .outage, description: "", incidents: [
            SvcIncident(id: "1", title: "Down", impact: .outage, status: "En cours", affected: ["API"])])

        let ours = SvcVerdictRules.verdict(feed: fine, feedError: nil, endpoints: [dns, tls])
        try expectEqual(ours.health, .unreachable, "page normale, tout injoignable : chez nous")
        try expectEqual(ours.side, .ours, "côté")
        try expect(ours.detail?.contains("de notre côté") == true, "explication")

        let theirs = SvcVerdictRules.verdict(feed: outage, feedError: nil, endpoints: [dns])
        try expectEqual(theirs.health, .outage, "panne publiée l’emporte")
        try expectEqual(theirs.headline, "API\u{00A0}: Down", "titre de l’incident")

        let partial = SvcVerdictRules.verdict(feed: fine, feedError: nil, endpoints: [ok, tls])
        try expectEqual(partial.health, .degraded, "une adresse sur deux")
        try expectEqual(partial.side, .ours, "chez nous")
        try expectEqual(partial.headline, "1 adresse sur 2 injoignable d’ici", "phrase")

        let unknown = SvcVerdictRules.verdict(feed: nil, feedError: "HTTP 503", endpoints: [ok])
        try expectEqual(unknown.health, .operational, "page illisible mais joignable")
        try expectEqual(unknown.headline, "Joignable d’ici · page d’état non lue", "phrase")
        let noPage = SvcVerdictRules.verdict(feed: nil, feedError: nil, endpoints: [ok], hasFeed: false)
        try expectEqual(noPage.headline, "Joignable d’ici", "service sans page lisible")

        func snapshot(_ endpoints: [SvcEndpointResult]) -> SvcSnapshot {
            SvcSnapshot(serviceID: "x", date: now, feed: nil, feedError: nil, endpoints: endpoints,
                        verdict: SvcVerdict(health: .unreachable, side: .ours, headline: ""))
        }
        try expect(SvcVerdictRules.globalProblem([snapshot([dns]), snapshot([dns])]) == nil, "au moins trois services")
        try expect(SvcVerdictRules.globalProblem([snapshot([dns]), snapshot([dns]), snapshot([dns])])?.contains("DNS") == true, "DNS en cause")
        try expect(SvcVerdictRules.globalProblem([snapshot([dns]), snapshot([ok]), snapshot([dns])]) == nil, "un service joignable")
    }

    suite.add("Services : vérification complète avec page et réseau simulés (Graph compris)") {
        let github = try unwrap(SvcCatalog.find("github", in: SvcCatalog.builtIn))
        let fetcher = FakeFetcher(responses: [
            "https://www.githubstatus.com/api/v2/summary.json": (#"{"status":{"indicator":"none"},"components":[],"incidents":[]}"#, 200),
        ])
        let checker = SvcChecker(fetcher: fetcher, prober: FakeProber(failing: ["api.github.com": .tls]))
        let snapshot = await checker.check(github, now: now)
        try expectEqual(snapshot.endpoints.map(\.host), ["github.com", "api.github.com"], "ordre du catalogue")
        try expectEqual(snapshot.verdict.health, .degraded, "une adresse en échec TLS")
        try expectEqual(snapshot.verdict.side, .ours, "chez nous")
        try expectEqual(snapshot.feedSource, "Statuspage (JSON)", "source")
        try expectEqual(snapshot.latencyMs, 80, "latence médiane des adresses joignables")

        let m365 = try unwrap(SvcCatalog.find("Microsoft 365", in: SvcCatalog.builtIn))
        let graph = FakeFetcher(responses: [
            "https://login.microsoftonline.com/": (#"{"access_token":"t"}"#, 200),
            "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews": (#"{"value":[{"service":"Microsoft Teams","status":"serviceDegradation"}]}"#, 200),
            "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues": (#"{"value":[{"id":"TM1","title":"Delays","status":"serviceDegradation","service":"Microsoft Teams","isResolved":false}]}"#, 200),
        ])
        let credentials = SvcGraphCredentials(tenantID: "contoso.onmicrosoft.com", clientID: "c", clientSecret: "s")
        let viaGraph = await SvcChecker(fetcher: graph, prober: FakeProber(failing: [:]), graph: credentials).check(m365, now: now)
        try expectEqual(viaGraph.feedSource, "Microsoft Graph (locataire)", "Graph lu en premier")
        try expectEqual(viaGraph.verdict.health, .degraded, "Teams dégradé")
        try expectEqual(viaGraph.verdict.headline, "Teams\u{00A0}: Delays", "incident")

        // Sans page lisible et tout injoignable : explication adaptée.
        let zscaler = try unwrap(SvcCatalog.find("zscaler", in: SvcCatalog.builtIn))
        let blocked = await SvcChecker(fetcher: FakeFetcher(responses: [:]),
                                       prober: FakeProber(failing: ["gateway.zscaler.net": .connect, "trust.zscaler.com": .connect]))
            .check(zscaler, now: now)
        try expectEqual(blocked.verdict.health, .unreachable, "injoignable d’ici")
        try expect(blocked.feedError == nil, "aucune page à lire")

        // Page en erreur HTTP : notée, sans fausse alerte.
        let broken = await SvcChecker(fetcher: FakeFetcher(responses: ["https://www.githubstatus.com": ("oops", 503)]),
                                      prober: FakeProber(failing: [:])).check(github, now: now)
        try expectEqual(broken.feedError, "HTTP 503", "erreur notée")
        try expectEqual(broken.verdict.health, .operational, "joignable, page non lue")
    }

    // MARK: Historique

    suite.add("Services : historique, incidents nouveaux, résolus et perte d’accès") {
        let svc = SvcService(id: "gh", name: "GitHub", category: "", format: .statuspage, feedURL: nil, pageURL: "", endpoints: [])
        let incident = SvcIncident(id: "i1", title: "Actions lentes", impact: .degraded, status: "En cours", url: "https://x/i1")
        func snap(_ incidents: [SvcIncident]?, _ health: SvcHealth, at minutes: Double) -> SvcSnapshot {
            SvcSnapshot(serviceID: "gh", date: now.addingTimeInterval(minutes * 60),
                        feed: incidents.map { SvcFeedReport(health: .degraded, description: "", incidents: $0) }, feedError: nil,
                        endpoints: [], verdict: SvcVerdict(health: health, side: .none, headline: "h"))
        }
        var history = SvcHistory()
        try expectEqual(history.record(snap([incident], .degraded, at: 0), service: svc).map(\.id), ["i1"], "nouvel incident")
        try expectEqual(history.record(snap([incident], .degraded, at: 5), service: svc).count, 0, "déjà vu")
        try expectEqual(history.record(snap(nil, .unreachable, at: 10), service: svc).count, 0, "page illisible : rien de résolu")
        try expectEqual(history.events.first?.kind, .unreachable, "perte d’accès notée")
        history.record(snap([], .operational, at: 15), service: svc)
        try expect(history.events.contains { $0.kind == .resolved && $0.title == "Actions lentes" }, "incident résolu noté")
        try expect(history.events.contains { $0.kind == .reachable }, "accès retrouvé noté")
        try expect(history.openIncidents.isEmpty, "plus d’incident ouvert")
        try expectEqual(history.record(snap([incident], .degraded, at: 20), service: svc).count, 1, "réapparu : de nouveau signalé")
        history.prune(now: now.addingTimeInterval(40 * 86_400))
        try expect(history.events.isEmpty, "30 jours de rétention")
    }

    // MARK: Surveillance

    suite.add("Services : sonde « Service en ligne » de Surveillance") {
        func snap(_ health: SvcHealth, side: SvcSide = .theirs) -> SvcSnapshot {
            SvcSnapshot(serviceID: "x", date: now, feed: nil, feedError: nil,
                        endpoints: [SvcEndpointResult(url: "https://a/", host: "a", httpMs: 96, httpStatus: 200)],
                        verdict: SvcVerdict(health: health, side: side, headline: "Teams\u{00A0}: retards"))
        }
        let ok = SvcMonitorCheck.evaluate(snap(.operational))
        try expect(ok.reachable && ok.problem == nil, "OK")
        try expectEqual(ok.value, "OK · 96\u{00A0}ms", "valeur")
        let degraded = SvcMonitorCheck.evaluate(snap(.degraded))
        try expect(degraded.reachable, "dégradé : joignable")
        try expectEqual(degraded.problem, "Service dégradé\u{00A0}: Teams\u{00A0}: retards", "avertissement")
        let outage = SvcMonitorCheck.evaluate(snap(.outage))
        try expect(!outage.reachable, "panne : échec")
        let unreachable = SvcMonitorCheck.evaluate(snap(.unreachable, side: .ours))
        try expect(!unreachable.reachable && unreachable.value == "Injoignable d’ici", "injoignable : échec")

        let probe = MonProbe(name: "Microsoft 365", kind: .onlineService, target: "Microsoft 365")
        let decoded = try JSONDecoder().decode(MonProbe.self, from: try JSONEncoder().encode(probe))
        try expectEqual(decoded.kind, .onlineService, "type enregistré")
        try expectEqual(MonProbeKind.onlineService.label, "Service en ligne", "libellé")
        let unknown = await SvcMonitorCheck.run(probe, target: "Inconnu-xyz",
                                                context: MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], now: now))
        try expect(!unknown.reachable && unknown.error?.contains("Service inconnu") == true, "service hors catalogue, sans réseau")
    }

    // MARK: Catalogue et classement

    suite.add("Services : catalogue, adresses, classement des erreurs et proxy") {
        try expectEqual(SvcCatalog.find("microsoft 365", in: SvcCatalog.builtIn)?.id, "microsoft365", "nom sans casse")
        try expectEqual(SvcCatalog.find("Google W", in: SvcCatalog.builtIn)?.id, "googleworkspace", "début du nom")
        try expect(Set(SvcCatalog.builtIn.map(\.id)).count == SvcCatalog.builtIn.count, "identifiants uniques")
        try expect(SvcCatalog.builtIn.allSatisfy { $0.endpoints.allSatisfy { SvcCatalog.endpoint(from: $0) == $0 } }, "adresses clés valides")
        let merged = SvcCatalog.merged(saved: [SvcCatalog.builtIn[0]])
        try expectEqual(merged.count, SvcCatalog.builtIn.count, "nouveaux services intégrés ajoutés")
        try expectEqual(SvcCatalog.customID(for: "Intranet", existing: [SvcService(id: "perso-intranet", name: "", category: "", format: .none, feedURL: nil, pageURL: "", endpoints: [])]),
                        "perso-intranet-2", "identifiant libre")
        try expectEqual(SvcCatalog.endpoint(from: "outlook.office365.com"), "https://outlook.office365.com/", "hôte seul")
        try expect(SvcCatalog.endpoint(from: "http://exemple.com") == nil, "https seulement")

        try expectEqual(SvcReachability.classify(posix: ECONNREFUSED).0, .connect, "refus")
        try expectEqual(SvcReachability.classify(posix: ETIMEDOUT).0, .timeout, "délai")
        try expectEqual(SvcReachability.classify(urlErrorCode: NSURLErrorCannotFindHost), .dns, "DNS")
        try expectEqual(SvcReachability.classify(urlErrorCode: NSURLErrorServerCertificateUntrusted), .tls, "certificat")
        try expectEqual(SvcReachability.classify(urlErrorCode: NSURLErrorNotConnectedToInternet), .connect, "hors ligne")
        try expectEqual(SvcReachability.describeProxy(["HTTPSEnable": 1, "HTTPSProxy": "10.0.0.5", "HTTPSPort": 8080]),
                        "proxy HTTPS 10.0.0.5:8080", "proxy HTTPS")
        try expectEqual(SvcReachability.describeProxy(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad/proxy.pac"]),
                        "configuration automatique du proxy (http://wpad/proxy.pac)", "PAC")
        try expect(SvcReachability.describeProxy(["HTTPEnable": 0]) == nil, "aucun proxy")
    }
}

private func unwrap<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "valeur absente", file: file, line: line) }
    return value
}
