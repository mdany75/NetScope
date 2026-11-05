import Foundation
import NetScopeCore

// Tests de la note 53 : réseaux sociaux et assistants IA dans l'état des services, pages d'état
// incident.io et Statuspage (réponses fixes calquées sur status.openai.com et status.claude.com),
// reconnaissance du filtrage (FortiGuard, Umbrella, certificat de remplacement), bilan « bloqué
// ici » et services masqués par site. Aucun accès réseau.

private let now53 = Date(timeIntervalSince1970: 1_793_808_000) // 2026-11-04

private struct Fetcher53: SvcFetching {
    let responses: [String: (String, Int)]

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url?.absoluteString ?? ""
        guard let match = responses.first(where: { url.hasPrefix($0.key) }) else {
            throw SvcParseError.unreadable("adresse inattendue \(url)")
        }
        return (Data(match.value.0.utf8), match.value.1)
    }
}

/// Résultats fixes par hôte ; les autres répondent normalement.
private struct Prober53: SvcProbing {
    let fixed: [String: SvcEndpointResult]

    func probe(_ url: String) async -> SvcEndpointResult {
        let host = URL(string: url)?.host ?? url
        if var result = fixed[host] {
            result.url = url
            return result
        }
        return SvcEndpointResult(url: url, host: host, addresses: ["192.0.2.20"], dnsMs: 9, tlsMs: 25, httpMs: 70, httpStatus: 200)
    }
}

/// Page de blocage par défaut d'une FortiGate (message de remplacement « ftgd-block »).
private let fortiGuardPage = """
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Web Filter Violation</title>
<style>body{font-family:Arial}</style></head><body><div class="logo"></div>
<h1>Web Page Blocked!</h1>
<p>You have tried to access a web page which is in violation of your internet usage policy.</p>
<p><b>URL:</b> www.instagram.com/</p>
<p><b>Category:</b> Social Networking</p>
<p>To have the rating of this web page re-evaluated <a href="https://www.fortiguard.com/faq/wfratingsubmit?url=www.instagram.com">please click here</a>.</p>
</body></html>
"""

private func catalogService(_ id: String) throws -> SvcService {
    guard let service = SvcCatalog.builtIn.first(where: { $0.id == id }) else {
        throw TestFailure(message: "service \(id) absent du catalogue", file: #fileID, line: #line)
    }
    return service
}

func registerSocialAIServiceTests(_ suite: TestSuite) {
    // MARK: Catalogue

    suite.add("Services IA et réseaux sociaux : catégories, formats et adresses du catalogue") {
        let social = SvcCatalog.builtIn.filter { $0.category == SvcCatalog.socialCategory }
        let ai = SvcCatalog.builtIn.filter { $0.category == SvcCatalog.aiCategory }
        try expectEqual(social.map(\.name), ["Facebook", "Instagram", "TikTok", "Snapchat"], "réseaux sociaux")
        try expectEqual(ai.map(\.name), ["Claude", "ChatGPT", "Microsoft Copilot", "Grok"], "assistants IA")
        try expect(Set(SvcCatalog.builtIn.map(\.id)).count == SvcCatalog.builtIn.count, "identifiants uniques")
        try expect((social + ai).allSatisfy { !$0.endpoints.isEmpty && $0.endpoints.allSatisfy { SvcCatalog.endpoint(from: $0) == $0 } },
                   "adresses clés https valides")
        let claude = try catalogService("claude")
        try expectEqual(claude.format, .statuspage, "Claude : Statuspage")
        try expectEqual(claude.feedURL, "https://status.claude.com/api/v2/summary.json", "nouvelle adresse (status.anthropic.com redirige)")
        try expect(claude.endpointHosts.contains("api.anthropic.com") && claude.endpointHosts.contains("claude.ai"), "claude.ai et l’API")
        let chatgpt = try catalogService("chatgpt")
        try expectEqual(chatgpt.format, .incidentIO, "ChatGPT : incident.io")
        try expectEqual(chatgpt.endpointHosts.prefix(2), ["chatgpt.com", "api.openai.com"], "adresses ChatGPT")
        let copilot = try catalogService("copilot")
        try expectEqual(copilot.format, .microsoft365, "Copilot : page Microsoft 365")
        try expectEqual(copilot.components, ["Copilot"], "incidents Copilot seulement")
        try expect(["facebook", "instagram", "tiktok", "snapchat", "grok"].allSatisfy { id in
            SvcCatalog.builtIn.first { $0.id == id }?.format == SvcFeedFormat.none
        }, "sans flux lisible : test depuis ce réseau seulement")
        let facebook = try catalogService("facebook")
        try expect(facebook.endpointHosts.contains("graph.facebook.com"), "API Graph de Meta")
        let categories = SvcCatalog.categories(in: SvcCatalog.builtIn)
        try expectEqual(Array(categories.suffix(2)), [SvcCatalog.socialCategory, SvcCatalog.aiCategory], "deux nouvelles catégories, à la fin")
        // Catalogue enregistré par la 0.17.0 : les huit nouveaux services sont ajoutés, suivis.
        let saved = SvcCatalog.builtIn.filter { $0.category != SvcCatalog.socialCategory && $0.category != SvcCatalog.aiCategory }
        let merged = SvcCatalog.merged(saved: saved)
        try expectEqual(merged.count, SvcCatalog.builtIn.count, "fusion")
        try expect(merged.filter { $0.category == SvcCatalog.aiCategory }.allSatisfy(\.isEnabled), "nouveaux services suivis")
        try expectEqual(SvcFeedFormat.incidentIO.label, "incident.io (JSON)", "libellé du format")
    }

    // MARK: Pages d'état

    suite.add("Services IA : incident.io (OpenAI), indicateur « none » mais incident ouvert") {
        // Structure de status.openai.com/api/v2/summary.json (incident.io) : pas de groupes, pas de
        // maintenances planifiées, ni lien court ni composants dans les incidents, mises à jour
        // dans l'ordre chronologique.
        let json = """
        {"page":{"id":"01JMDK9XYNY6RXSED6SDWW50WY","name":"OpenAI","url":"https://status.openai.com/","updated_at":"2026-11-04T22:49:34Z"},
         "status":{"description":"All Systems Operational","indicator":"none"},
         "components":[{"id":"c1","name":"Chat Completions","status":"operational","position":1},
                       {"id":"c2","name":"File uploads","status":"degraded_performance","position":2},
                       {"id":"c3","name":"Login","status":"operational","position":3}],
         "incidents":[{"id":"01M6MBCX427A7113A3T4FJ1N6Y","name":"Elevated error rates across paid ChatGPT plans",
                       "status":"monitoring","impact":"minor","created_at":"2026-11-04T22:38:12Z","updated_at":"2026-11-04T22:49:34Z",
                       "monitoring_at":"2026-11-04T22:49:34Z","page_id":"01JMDK9XYNY6RXSED6SDWW50WY",
                       "incident_updates":[{"status":"identified","body":"Some users may see errors when sending messages.","created_at":"2026-11-04T22:38:12Z"},
                                           {"status":"monitoring","body":"We’ve applied a mitigation and are monitoring.","created_at":"2026-11-04T22:49:34Z"}]}]}
        """
        let chatgpt = try catalogService("chatgpt")
        let report = try SvcFeedParser.parse(Data(json.utf8), service: chatgpt, now: now53)
        try expectEqual(report.health, .degraded, "incident mineur ouvert malgré « none »")
        try expectEqual(report.description, "1 incident en cours", "description")
        try expectEqual(report.components, [SvcComponent(name: "File uploads", health: .degraded)], "composant dégradé")
        let incident = try unwrap53(report.incidents.first)
        try expectEqual(incident.status, "Sous surveillance", "statut traduit")
        try expectEqual(incident.url, "https://status.openai.com/incidents/01M6MBCX427A7113A3T4FJ1N6Y", "lien sans double barre")
        try expectEqual(incident.latestUpdate, "We’ve applied a mitigation and are monitoring.", "mise à jour la plus récente (ordre chronologique)")
        try expectEqual(incident.affected, [], "pas de composants par incident")
        try expectEqual(incident.started, Date(timeIntervalSince1970: 1_793_831_892), "début (created_at)")
    }

    suite.add("Services IA : Statuspage de Claude, tout opérationnel puis panne majeure de l’API") {
        let claude = try catalogService("claude")
        let ok = """
        {"page":{"id":"tymt9n04zgry","name":"Claude","url":"https://status.claude.com","time_zone":"Etc/UTC","updated_at":"2026-11-04T23:45:12.041Z"},
         "components":[{"id":"a","name":"claude.ai","status":"operational","group":false,"group_id":null,"only_show_if_degraded":false,"showcase":true},
                       {"id":"b","name":"Claude API (api.anthropic.com)","status":"operational","group":false},
                       {"id":"c","name":"Claude Code","status":"operational","group":false}],
         "incidents":[],"scheduled_maintenances":[],"status":{"indicator":"none","description":"All Systems Operational"}}
        """
        let report = try SvcFeedParser.parse(Data(ok.utf8), service: claude, now: now53)
        try expectEqual(report.health, .operational, "opérationnel")
        let outage = """
        {"page":{"url":"https://status.claude.com"},"status":{"indicator":"major","description":"Partial System Outage"},
         "components":[{"name":"Claude API (api.anthropic.com)","status":"major_outage","group":false}],
         "incidents":[{"id":"k9","name":"Elevated errors on the API","status":"investigating","impact":"major",
                       "shortlink":"https://stspg.io/k9","incident_updates":[{"body":"We are investigating.","created_at":"2026-11-04T13:00:00Z"}],
                       "components":[{"name":"Claude API (api.anthropic.com)"}]}],"scheduled_maintenances":[]}
        """
        let down = try SvcFeedParser.parse(Data(outage.utf8), service: claude, now: now53)
        try expectEqual(down.health, .outage, "panne majeure")
        let verdict = SvcVerdictRules.verdict(feed: down, feedError: nil, endpoints: [
            SvcEndpointResult(url: "https://claude.ai/", host: "claude.ai", httpMs: 80, httpStatus: 200)])
        try expectEqual(verdict.side, .theirs, "panne chez eux")
        try expectEqual(verdict.headline, "Claude API (api.anthropic.com)\u{00A0}: Elevated errors on the API", "titre de l’incident")
    }

    suite.add("Services IA : Copilot ne garde que les incidents Copilot de la page Microsoft 365") {
        let json = """
        [{"id":"MO1","title":"Users can't access Outlook.com","status":"Investigating","impactedServices":["Outlook.com"]},
         {"id":"CP2","title":"Copilot responses are delayed","status":"Service degradation","impactedServices":["Microsoft Copilot"]}]
        """
        let copilot = try catalogService("copilot")
        let raw = try SvcFeedParser.parse(Data(json.utf8), service: copilot, now: now53)
        try expectEqual(raw.activeIncidents.count, 2, "page entière")
        let filtered = SvcChecker.filtered(raw, for: copilot)
        try expectEqual(filtered.incidents.map(\.id), ["CP2"], "incident Copilot seulement")
        try expectEqual(filtered.health, .degraded, "état recalculé")
    }

    // MARK: Filtrage

    suite.add("Services : page de blocage FortiGuard, contrôle des applications et pages normales") {
        let block = try unwrap53(SvcFilterDetector.pageBlock(status: 403, location: nil, body: fortiGuardPage))
        try expectEqual(block.kind, .blockPage, "page de blocage")
        try expectEqual(block.source, "FortiGuard (filtrage web de la FortiGate)", "FortiGuard reconnu")
        try expectEqual(block.category, "Social Networking", "catégorie FortiGuard")
        try expect(block.isFortinet, "FortiGate")
        try expectEqual(block.evidence, "HTTP 403 avec une page de blocage au lieu du site", "preuve")
        try expect(block.advice.contains("filtrage web"), "conseil FortiGate")

        let appControl = try unwrap53(SvcFilterDetector.pageBlock(status: 200, location: nil, body: """
        <html><title>Application Blocked</title><body><h2>Application Blocked!</h2>
        <p>You have attempted to use an application that violates your Internet usage policy.</p>
        <p>Application: TikTok</p><p>Category: Video/Audio</p><p>Powered by Fortinet</p></body></html>
        """))
        try expectEqual(appControl.source, "Contrôle des applications (FortiGate)", "contrôle des applications")
        try expectEqual(appControl.category, "Video/Audio", "catégorie d’application")

        let french = try unwrap53(SvcFilterDetector.pageBlock(status: 403, location: nil, body: """
        <h1>Page web bloquée</h1><p>Catégorie&nbsp;: Réseaux sociaux</p><p>URL : www.facebook.com</p>
        """))
        try expectEqual(french.category, "Réseaux sociaux", "page en français")
        try expectEqual(french.source, "pare-feu ou proxy de filtrage", "éditeur inconnu")

        try expect(SvcFilterDetector.pageBlock(status: 200, location: nil,
                                               body: "<html><title>Instagram</title><p>You blocked this account. Log in to continue.</p></html>") == nil,
                   "page normale qui contient « blocked »")
        try expect(SvcFilterDetector.pageBlock(status: 302, location: "https://www.instagram.com/accounts/login/", body: "") == nil,
                   "redirection normale")
        let portal = try unwrap53(SvcFilterDetector.pageBlock(status: 303, location: "https://10.182.122.1:1003/fgtauth?0a1b2c3d", body: ""))
        try expectEqual(portal.kind, .firewallPortal, "portail d’authentification FortiGate")
        let override = try unwrap53(SvcFilterDetector.pageBlock(status: 302, location: "https://10.182.122.1:8010/override?u=www.tiktok.com", body: ""))
        try expectEqual(override.source, "FortiGuard (dérogation de la FortiGate)", "dérogation FortiGuard")
        let umbrella = try unwrap53(SvcFilterDetector.pageBlock(status: 302, location: "https://block.opendns.com/?url=snapchat.com", body: ""))
        try expectEqual(umbrella.source, "Cisco Umbrella (page de blocage)", "Umbrella")
    }

    suite.add("Services : portails de blocage DNS et certificat de remplacement") {
        let forti = try unwrap53(SvcFilterDetector.dnsBlock(host: "www.tiktok.com", addresses: ["208.91.112.55"]))
        try expectEqual(forti.kind, .dnsSinkhole, "filtrage DNS")
        try expectEqual(forti.source, "FortiGuard (filtrage DNS de la FortiGate)", "portail FortiGuard")
        try expectEqual(forti.evidence, "DNS\u{00A0}: www.tiktok.com → 208.91.112.55", "preuve DNS")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["146.112.61.106"])?.source == "Cisco Umbrella (filtrage DNS)", "Umbrella")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["0.0.0.0", "::"]) != nil, "réponse 0.0.0.0")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["0.0.0.0", "2a03:2880:f12f:83:face:b00c:0:25de"]) != nil,
                   "IPv4 bloquée, IPv6 réelle ignorée")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["157.240.3.35"]) == nil, "adresse réelle")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["157.240.3.35", "0.0.0.0"]) == nil, "réponse mélangée : pas de conclusion")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: []) == nil, "aucune adresse")
        try expect(SvcFilterDetector.dnsBlock(host: "x", addresses: ["10.182.122.1"], extraPortals: ["10.182.122.1"]) != nil,
                   "portail propre à la FortiGate")

        let replaced = try unwrap53(SvcFilterDetector.certificateBlock(issuer: "Fortinet_CA_SSL · Fortinet", tlsFailed: true))
        try expectEqual(replaced.kind, .certificateReplacement, "certificat de remplacement")
        try expectEqual(replaced.source, "FortiGate (certificat de remplacement)", "FortiGate")
        try expect(SvcFilterDetector.certificateBlock(issuer: "Fortinet_CA_SSL · Fortinet", tlsFailed: false) == nil,
                   "inspection SSL approuvée : pas un blocage")
        try expect(SvcFilterDetector.certificateBlock(issuer: "DigiCert Global G2 TLS RSA SHA256 2020 CA1 · DigiCert Inc", tlsFailed: true) == nil,
                   "certificat public : erreur TLS ordinaire")
        try expectEqual(SvcFilterDetector.inspectionVendor(issuer: "SG-Firewall CA · Sophos Ltd"), "Sophos", "Sophos")
        try expect(SvcFilterDetector.inspectionVendor(issuer: nil) == nil, "sans émetteur")
    }

    suite.add("Services : bilan « bloqué ici » plutôt que panne, et coupure sans page de blocage") {
        let block = SvcBlock(kind: .blockPage, source: "FortiGuard (filtrage web de la FortiGate)", category: "Social Networking",
                             evidence: "HTTP 403 avec une page de blocage au lieu du site")
        let blocked = SvcEndpointResult(url: "https://www.instagram.com/", host: "www.instagram.com", addresses: ["157.240.3.174"],
                                        dnsMs: 7, tlsMs: 20, httpMs: 9, httpStatus: 403, failure: .blocked,
                                        detail: block.evidence, block: block)
        let fine = SvcEndpointResult(url: "https://graph.facebook.com/", host: "graph.facebook.com", httpMs: 50, httpStatus: 400)
        let verdict = SvcVerdictRules.verdict(feed: nil, feedError: nil, endpoints: [blocked], hasFeed: false)
        try expectEqual(verdict.health, .blocked, "bloqué")
        try expectEqual(verdict.side, .ours, "chez nous")
        try expectEqual(verdict.headline, "Bloqué ici · FortiGuard (filtrage web de la FortiGate) · catégorie «\u{00A0}Social Networking\u{00A0}»",
                        "titre")
        try expect(verdict.detail?.hasPrefix("Ce n’est pas une panne") == true, "pas une panne")
        try expect(verdict.detail?.contains("masquer ce service ou sa catégorie pour ce site") == true, "piste : masquer pour ce site")

        let partial = SvcVerdictRules.verdict(feed: SvcFeedReport(health: .operational, description: "Aucun incident en cours"),
                                              feedError: nil, endpoints: [fine, blocked])
        try expectEqual(partial.health, .blocked, "bloqué en partie")
        try expect(partial.detail?.contains("1 adresse sur 2 bloquée ici") == true, "compte des adresses")
        try expect(partial.detail?.contains("La page d’état est normale.") == true, "page d’état normale")

        let outage = SvcFeedReport(health: .outage, description: "1 incident en cours",
                                   incidents: [SvcIncident(id: "1", title: "Instagram down", impact: .outage, status: "En cours")])
        let both = SvcVerdictRules.verdict(feed: outage, feedError: nil, endpoints: [blocked])
        try expectEqual(both.health, .blocked, "le blocage d’ici l’emporte")
        try expect(both.detail?.contains("La page d’état signale aussi un problème\u{00A0}: Instagram down") == true, "panne publiée mentionnée")

        // Coupure juste après le DNS (contrôle des applications en mode flux) : injoignable, avec la piste du filtrage.
        let reset = SvcEndpointResult(url: "https://www.tiktok.com/", host: "www.tiktok.com", addresses: ["23.40.0.10"], dnsMs: 8,
                                      failure: .connect, detail: "connexion coupée par le réseau")
        let silent = SvcVerdictRules.verdict(feed: nil, feedError: nil, endpoints: [reset], hasFeed: false)
        try expectEqual(silent.health, .unreachable, "pas de preuve : injoignable")
        try expect(silent.detail?.contains("contrôle des applications") == true, "piste du contrôle des applications")
        let dnsFailure = SvcEndpointResult(url: "https://www.tiktok.com/", host: "www.tiktok.com", dnsMs: 3, failure: .dns)
        try expect(SvcFilterDetector.silentBlockHint([dnsFailure]) == nil, "échec DNS : pas cette piste")
        try expect(SvcFilterDetector.silentBlockHint([reset, fine]) == nil, "une adresse répond : pas cette piste")

        // Sonde de Surveillance et historique.
        let snapshot = SvcSnapshot(serviceID: "instagram", date: now53, feed: nil, feedError: nil, endpoints: [blocked], verdict: verdict)
        let result = SvcMonitorCheck.evaluate(snapshot)
        try expect(!result.reachable && result.value == "Bloqué ici", "sonde : bloqué ici")
        let instagram = try catalogService("instagram")
        var history = SvcHistory()
        history.record(SvcSnapshot(serviceID: "instagram", date: now53.addingTimeInterval(-600), feed: nil, feedError: nil,
                                   endpoints: [fine], verdict: SvcVerdict(health: .operational, side: .none, headline: "Joignable d’ici")),
                       service: instagram)
        history.record(snapshot, service: instagram)
        try expectEqual(history.events.first?.kind, .blocked, "événement « bloqué ici »")
        try expectEqual(history.events.first?.kindLabel, "Bloqué ici", "libellé")
        history.record(SvcSnapshot(serviceID: "instagram", date: now53.addingTimeInterval(600), feed: nil, feedError: nil,
                                   endpoints: [fine], verdict: SvcVerdict(health: .operational, side: .none, headline: "Joignable d’ici")),
                       service: instagram)
        try expectEqual(history.events.first?.title, "Plus bloqué depuis ce réseau", "levée du blocage")
        try expect(SvcHealth.blocked > .degraded && SvcHealth.blocked < .unreachable && SvcHealth.blocked.isProblem, "gravité")
    }

    suite.add("Services : vérification complète d’Instagram bloqué et de ChatGPT, réponses fixes") {
        let block = try unwrap53(SvcFilterDetector.pageBlock(status: 403, location: nil, body: fortiGuardPage))
        var blocked = SvcEndpointResult(url: "", host: "www.instagram.com", addresses: ["157.240.3.174"], dnsMs: 7, tlsMs: 21, httpMs: 9,
                                        httpStatus: 403, failure: .blocked, detail: block.evidence,
                                        certificateIssuer: "Fortinet_CA_SSL · Fortinet", block: block)
        blocked.url = "https://www.instagram.com/"
        let prober = Prober53(fixed: ["www.instagram.com": blocked])
        let fetcher = Fetcher53(responses: ["https://status.openai.com/api/v2/summary.json": ("""
            {"page":{"url":"https://status.openai.com/"},"status":{"indicator":"none","description":"All Systems Operational"},
             "components":[],"incidents":[]}
            """, 200)])
        let checker = SvcChecker(fetcher: fetcher, prober: prober)
        let instagram = await checker.check(try catalogService("instagram"), now: now53)
        try expectEqual(instagram.verdict.health, .blocked, "Instagram bloqué au site")
        try expectEqual(instagram.endpoints.count, 3, "trois adresses testées")
        try expectEqual(instagram.endpoints.filter { $0.block != nil }.count, 1, "une adresse bloquée")
        try expect(instagram.feed == nil && instagram.feedError == nil, "aucune page d’état lue (metastatus.com)")
        let chatgpt = await checker.check(try catalogService("chatgpt"), now: now53)
        try expectEqual(chatgpt.verdict.health, .operational, "ChatGPT normal")
        try expectEqual(chatgpt.feedSource, "incident.io (JSON)", "source lue")
        let encoded = try JSONEncoder().encode(instagram)
        let decoded = try JSONDecoder().decode(SvcSnapshot.self, from: encoded)
        try expectEqual(decoded.endpoints.first { $0.block != nil }?.block?.category, "Social Networking", "preuve enregistrée")
        // Vérification enregistrée par la 0.17.0 (sans émetteur ni preuve) : toujours lisible.
        let old = #"{"url":"https://a/","host":"a","addresses":[],"httpMs":80,"httpStatus":200}"#
        let legacy = try JSONDecoder().decode(SvcEndpointResult.self, from: Data(old.utf8))
        try expect(legacy.block == nil && legacy.certificateIssuer == nil && legacy.isReachable, "ancien format")
    }

    // MARK: Sites

    suite.add("Services : catégories et services masqués par site") {
        let services = SvcCatalog.builtIn
        var preferences = SvcSitePreferences()
        let laval = "site-laval"
        let siege = "site-siege"
        preferences.update(laval) { $0.setCategory(SvcCatalog.socialCategory, visible: false, in: services) }
        try expectEqual(preferences.visible(services, siteKey: laval).count, services.count - 4, "réseaux sociaux masqués à Laval")
        try expectEqual(preferences.visible(services, siteKey: siege).count, services.count, "tout suivi au Siège")
        try expectEqual(preferences.selection(for: laval).categoryState(SvcCatalog.socialCategory, in: services), .hidden, "catégorie masquée")

        // Montrer Facebook seulement : la catégorie redevient visible, les trois autres sont masqués un à un.
        let facebook = try catalogService("facebook")
        preferences.update(laval) { $0.setService(facebook, visible: true, in: services) }
        let selection = preferences.selection(for: laval)
        try expect(selection.isVisible(facebook), "Facebook suivi")
        try expectEqual(selection.hiddenServices, ["instagram", "tiktok", "snapchat"], "les autres masqués un à un")
        try expectEqual(selection.categoryState(SvcCatalog.socialCategory, in: services), .partial, "catégorie en partie")

        // Masquer Facebook de nouveau : toute la catégorie est masquée.
        preferences.update(laval) { $0.setService(facebook, visible: false, in: services) }
        try expectEqual(preferences.selection(for: laval).hiddenCategories, [SvcCatalog.socialCategory], "catégorie entière")
        try expect(preferences.selection(for: laval).hiddenServices.isEmpty, "plus de masquage un à un")

        // Montrer la catégorie : le site n'a plus de choix propre.
        preferences.update(laval) { $0.setCategory(SvcCatalog.socialCategory, visible: true, in: services) }
        try expect(preferences.bySite[laval] == nil, "choix vide retiré")

        // Un service décoché dans le catalogue n'est suivi nulle part.
        var catalog = services
        catalog[0].isEnabled = false
        try expectEqual(preferences.visible(catalog, siteKey: siege).count, services.count - 1, "décoché partout")

        preferences.update(siege) { $0.hiddenServices = ["grok", "perso-intranet"] }
        preferences.forget(serviceID: "perso-intranet")
        try expectEqual(preferences.selection(for: siege).hiddenServices, ["grok"], "service retiré oublié")
        let decoded = try JSONDecoder().decode(SvcSitePreferences.self, from: try JSONEncoder().encode(preferences))
        try expectEqual(decoded, preferences, "enregistrement")
    }
}

private func unwrap53<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "valeur absente", file: file, line: line) }
    return value
}
