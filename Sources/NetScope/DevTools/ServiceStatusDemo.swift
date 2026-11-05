import Foundation
import NetScopeCore

/// Démonstration (--demo) de l'outil « État des services » : catalogue intégré, Microsoft Teams
/// dégradé (incident publié par Microsoft Graph), Dropbox injoignable d'ici (filtrage DNS, page
/// d'état normale), maintenance Cloudflare à Montréal, historique de quelques jours.
/// Aucune requête : les mesures sont fixes et le bilan passe par les vraies règles (SvcVerdictRules).
@MainActor
enum ServiceStatusDemo {
    static func load(into store: SvcStore) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today) ?? today
        }
        // Captures : 14 h 32, comme l'écran Surveillance ; démonstration : l'heure réelle.
        let now = CommandLine.arguments.contains("--snapshot") ? at(14, 32) : Date()
        let checked = now.addingTimeInterval(-2 * 60)

        func ok(_ url: String, _ dns: Double, _ tls: Double, _ http: Double, _ code: Int) -> SvcEndpointResult {
            let host = URL(string: url)?.host ?? url
            return SvcEndpointResult(url: url, host: host, addresses: ["198.51.100.\(Int(dns) % 200 + 10)"], dnsMs: dns,
                                     tlsMs: tls, httpMs: http, httpStatus: code)
        }
        func operational() -> SvcFeedReport {
            SvcFeedReport(health: .operational, description: "Aucun incident en cours")
        }

        let teams = SvcIncident(
            id: "TM892341", title: "Retards dans la livraison des messages de conversation", impact: .degraded,
            status: "En cours d’analyse", affected: ["Teams", "Conversation et canaux"],
            started: at(13, 5), updated: at(14, 18), url: SvcGraph.adminURL + "/:/alerts/TM892341",
            latestUpdate: "Les utilisateurs touchés peuvent constater un délai de plusieurs minutes avant de recevoir les messages de conversation et de canal. Nous analysons les journaux du service pour isoler la cause.")
        let cloudflare = SvcIncident(
            id: "cf-yul-maint", title: "Maintenance planifiée du centre de données YUL (Montréal)", impact: .maintenance,
            status: "Maintenance en cours", affected: ["Montréal, QC, Canada - (YUL)"],
            started: at(13, 0), updated: at(13, 2), url: "https://www.cloudflarestatus.com/incidents/cf-yul-maint",
            latestUpdate: "Le trafic est acheminé vers les centres voisins pendant la maintenance\u{00A0}; une latence légèrement plus élevée est possible.")

        // Mesures depuis ce réseau (Montréal) : adresses du catalogue, dans le même ordre.
        var measures: [String: (SvcFeedReport?, String?, [SvcEndpointResult])] = [
            "microsoft365": (SvcFeedReport(health: .degraded, description: "1 incident en cours", incidents: [teams],
                                           components: [SvcComponent(name: "Teams", health: .degraded)]),
                             "Microsoft Graph (locataire)",
                             [ok("https://outlook.office365.com/", 14, 38, 96, 302), ok("https://login.microsoftonline.com/", 12, 35, 88, 200),
                              ok("https://teams.microsoft.com/", 15, 41, 112, 302), ok("https://www.office.com/", 11, 33, 84, 302)]),
            "azure": (operational(), "Azure Status (RSS)",
                      [ok("https://portal.azure.com/", 13, 36, 104, 200), ok("https://management.azure.com/", 12, 34, 79, 400)]),
            "apple": (operational(), "Apple System Status",
                      [ok("https://www.icloud.com/", 9, 27, 61, 200), ok("https://apps.apple.com/", 10, 29, 70, 301)]),
            "aws": (operational(), "AWS Health (JSON)",
                    [ok("https://console.aws.amazon.com/", 16, 42, 118, 302), ok("https://s3.amazonaws.com/", 14, 39, 92, 307)]),
            "googleworkspace": (operational(), "Google incidents.json",
                                [ok("https://mail.google.com/", 8, 21, 47, 302), ok("https://meet.google.com/", 8, 22, 51, 302),
                                 ok("https://drive.google.com/", 9, 23, 55, 302)]),
            "googlecloud": (operational(), "Google incidents.json",
                            [ok("https://console.cloud.google.com/", 9, 24, 66, 302), ok("https://storage.googleapis.com/", 8, 20, 44, 400)]),
            "cloudflare": (SvcFeedReport(health: .maintenance, description: "1 maintenance en cours", incidents: [cloudflare]),
                           "Statuspage (JSON)",
                           [ok("https://one.one.one.one/", 6, 17, 31, 200), ok("https://dash.cloudflare.com/", 7, 19, 58, 200)]),
            "zscaler": (nil, nil, [ok("https://gateway.zscaler.net/", 18, 44, 126, 200), ok("https://trust.zscaler.com/", 15, 40, 141, 200)]),
            "okta": (nil, nil, [ok("https://login.okta.com/", 17, 45, 133, 302)]),
            "github": (operational(), "Statuspage (JSON)",
                       [ok("https://github.com/", 12, 37, 82, 200), ok("https://api.github.com/", 11, 35, 74, 200)]),
            "atlassian": (operational(), "Statuspage (JSON)", [ok("https://id.atlassian.com/", 19, 47, 151, 302)]),
            "zoom": (operational(), "Statuspage (JSON)", [ok("https://zoom.us/", 13, 37, 97, 200)]),
            "slack": (operational(), "API Slack Status",
                      [ok("https://slack.com/", 12, 36, 86, 200), ok("https://app.slack.com/", 12, 38, 93, 302)]),
            // Injoignable d'ici : le filtre DNS du pare-feu bloque www.dropbox.com ; la page d'état est normale.
            "dropbox": (operational(), "Statuspage (JSON)",
                        [SvcEndpointResult(url: "https://www.dropbox.com/", host: "www.dropbox.com", dnsMs: 4,
                                           failure: .dns, detail: "nom introuvable (NXDOMAIN du résolveur 10.182.122.1)")]),
        ]

        // Note 53 : réseaux sociaux et assistants IA. Au Siège, la FortiGate bloque Instagram
        // (filtrage web FortiGuard, catégorie « Social Networking ») : la page de blocage reçue est
        // reconnue par les vraies règles (SvcFilterDetector), pas écrite à la main.
        let chatgpt = SvcIncident(
            id: "01M6MBCX427A7113A3T4FJ1N6Y", title: "Elevated error rates for file uploads in ChatGPT", impact: .degraded,
            status: "Sous surveillance", started: at(13, 48), updated: at(14, 21),
            url: "https://status.openai.com/incidents/01M6MBCX427A7113A3T4FJ1N6Y",
            latestUpdate: "We’ve applied a mitigation and are monitoring the affected services to confirm recovery.")
        for (id, value) in socialAndAI(ok: ok, chatgpt: chatgpt) { measures[id] = value }

        var snapshots: [String: SvcSnapshot] = [:]
        for service in SvcCatalog.builtIn {
            guard let (feed, source, endpoints) = measures[service.id] else { continue }
            let verdict = SvcVerdictRules.verdict(feed: feed, feedError: nil, endpoints: endpoints, hasFeed: service.format != .none)
            snapshots[service.id] = SvcSnapshot(serviceID: service.id, date: checked, feed: feed, feedError: nil,
                                                feedSource: source, endpoints: endpoints, verdict: verdict)
        }

        var history = SvcHistory()
        history.events = [
            SvcHistoryEvent(date: at(14, 20), serviceID: "dropbox", serviceName: "Dropbox", kind: .unreachable, health: .unreachable,
                            title: "Injoignable d’ici\u{00A0}: résolution DNS impossible (serveur DNS ou filtrage DNS de ce réseau)"),
            SvcHistoryEvent(date: at(13, 5), serviceID: "microsoft365", serviceName: "Microsoft 365", kind: .incident, health: .degraded,
                            title: teams.title, url: teams.url),
            SvcHistoryEvent(date: at(13, 0), serviceID: "cloudflare", serviceName: "Cloudflare", kind: .incident, health: .maintenance,
                            title: cloudflare.title, url: cloudflare.url),
            SvcHistoryEvent(date: at(11, 40, dayOffset: -1), serviceID: "github", serviceName: "GitHub", kind: .resolved, health: .operational,
                            title: "Incident with Actions", url: "https://www.githubstatus.com/incidents/demo-actions"),
            SvcHistoryEvent(date: at(10, 12, dayOffset: -1), serviceID: "github", serviceName: "GitHub", kind: .incident, health: .degraded,
                            title: "Incident with Actions", url: "https://www.githubstatus.com/incidents/demo-actions"),
            SvcHistoryEvent(date: at(16, 55, dayOffset: -2), serviceID: "zoom", serviceName: "Zoom", kind: .resolved, health: .operational,
                            title: "Delayed cloud recording processing", url: "https://status.zoom.us"),
            SvcHistoryEvent(date: at(15, 30, dayOffset: -2), serviceID: "zoom", serviceName: "Zoom", kind: .incident, health: .degraded,
                            title: "Delayed cloud recording processing", url: "https://status.zoom.us"),
            SvcHistoryEvent(date: at(9, 47, dayOffset: -3), serviceID: "aws", serviceName: "AWS", kind: .resolved, health: .operational,
                            title: "Increased API Error Rates · Amazon EC2 · N. Virginia", url: "https://health.aws.amazon.com/health/status"),
            SvcHistoryEvent(date: at(8, 58, dayOffset: -3), serviceID: "aws", serviceName: "AWS", kind: .incident, health: .degraded,
                            title: "Increased API Error Rates · Amazon EC2 · N. Virginia", url: "https://health.aws.amazon.com/health/status"),
        ]
        history.events.insert(SvcHistoryEvent(date: at(14, 30), serviceID: "instagram", serviceName: "Instagram", kind: .blocked,
                                              health: .blocked, title: snapshots["instagram"]?.verdict.headline ?? "Bloqué ici"), at: 0)
        history.events.insert(SvcHistoryEvent(date: at(13, 48), serviceID: "chatgpt", serviceName: "ChatGPT", kind: .incident,
                                              health: .degraded, title: chatgpt.title, url: chatgpt.url), at: 2)
        history.events.sort { $0.date > $1.date }
        history.openIncidents = ["microsoft365|TM892341": teams.title, "cloudflare|cf-yul-maint": cloudflare.title,
                                 "chatgpt|\(chatgpt.id)": chatgpt.title]
        for (id, snapshot) in snapshots { history.lastHealth[id] = snapshot.verdict.health }

        // Au Siège, tout est suivi ; à l'entrepôt de Laval, les réseaux sociaux sont bloqués exprès
        // et masqués ; au bureau de Québec, seul Grok est masqué.
        var preferences = SvcSitePreferences()
        preferences.update(SitesDemo.lavalKey) { $0.hiddenCategories = [SvcCatalog.socialCategory] }
        preferences.update(SiteFiles.key(for: SitesDemo.quebecID)) { $0.hiddenServices = ["grok"] }

        // Note 79 : services grand public masqués par défaut ; au Siège, le technicien a réactivé
        // Instagram pour suivre son blocage par la FortiGate (les autres restent masqués).
        let services = SvcCatalog.builtIn.map { service -> SvcService in
            var copy = service
            if service.id == "instagram" { copy.isEnabled = true }
            return copy
        }
        store.loadDemo(services: services, snapshots: snapshots, history: history, now: now,
                       selected: ProcessInfo.processInfo.environment["NETSCOPE_SERVICE"] ?? "microsoft365", proxy: nil,
                       sitePreferences: preferences)
    }

    /// Réseaux sociaux et assistants IA (note 53), mesurés « depuis le Siège ».
    private static func socialAndAI(ok: (String, Double, Double, Double, Int) -> SvcEndpointResult,
                                    chatgpt: SvcIncident) -> [String: (SvcFeedReport?, String?, [SvcEndpointResult])] {
        // Page de blocage par défaut d'une FortiGate (message de remplacement « ftgd-block »).
        let blockPage = """
        <html><head><title>Web Filter Violation</title></head><body><h1>Web Page Blocked!</h1>
        <p>You have tried to access a web page which is in violation of your internet usage policy.</p>
        <p>URL: www.instagram.com/</p><p>Category: Social Networking</p>
        <p>To have the rating of this web page re-evaluated <a href="https://www.fortiguard.com/faq/wfratingsubmit">please click here</a>.</p>
        </body></html>
        """
        func blocked(_ url: String, _ dns: Double, _ tls: Double, _ http: Double) -> SvcEndpointResult {
            var result = ok(url, dns, tls, http, 403)
            result.certificateIssuer = "Fortinet_CA_SSL · Fortinet"
            if let block = SvcFilterDetector.pageBlock(status: 403, location: nil,
                                                       body: blockPage.replacingOccurrences(of: "www.instagram.com", with: result.host)) {
                result.failure = .blocked
                result.block = block
                result.detail = block.evidence
            }
            return result
        }
        func operational() -> SvcFeedReport { SvcFeedReport(health: .operational, description: "Aucun incident en cours") }
        return [
            "facebook": (nil, nil, [ok("https://www.facebook.com/", 7, 19, 64, 302), ok("https://graph.facebook.com/", 7, 18, 52, 400),
                                    ok("https://static.xx.fbcdn.net/", 6, 17, 28, 404)]),
            "instagram": (nil, nil, [blocked("https://www.instagram.com/", 7, 21, 9), blocked("https://i.instagram.com/", 8, 20, 8),
                                     blocked("https://static.cdninstagram.com/", 6, 19, 8)]),
            "tiktok": (nil, nil, [ok("https://www.tiktok.com/", 11, 29, 88, 200), ok("https://www.tiktokv.com/", 12, 31, 71, 404)]),
            "snapchat": (nil, nil, [ok("https://www.snapchat.com/", 10, 30, 95, 200), ok("https://web.snapchat.com/", 10, 31, 102, 302),
                                    ok("https://accounts.snapchat.com/", 11, 33, 117, 302)]),
            "claude": (operational(), "Statuspage (JSON)",
                       [ok("https://claude.ai/", 9, 26, 74, 403), ok("https://api.anthropic.com/", 9, 25, 61, 404),
                        ok("https://platform.claude.com/", 10, 27, 83, 307)]),
            "chatgpt": (SvcFeedReport(health: .degraded, description: "1 incident en cours", incidents: [chatgpt],
                                      components: [SvcComponent(name: "File uploads", health: .degraded)]),
                        "incident.io (JSON)",
                        [ok("https://chatgpt.com/", 8, 22, 69, 403), ok("https://api.openai.com/", 9, 24, 58, 421),
                         ok("https://auth.openai.com/", 9, 25, 77, 302)]),
            "copilot": (operational(), "Microsoft 365 (page publique)",
                        [ok("https://copilot.microsoft.com/", 13, 36, 121, 200), ok("https://m365.cloud.microsoft/", 12, 34, 98, 302)]),
            "grok": (nil, nil, [ok("https://grok.com/", 9, 27, 92, 200), ok("https://x.com/", 8, 24, 81, 200),
                                ok("https://api.x.ai/", 10, 28, 66, 404)]),
        ]
    }
}
