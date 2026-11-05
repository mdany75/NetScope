import Foundation

/// Lecture d'une adresse (page d'état, Microsoft Graph) ; injectable pour les tests.
public protocol SvcFetching: Sendable {
    /// Corps et code HTTP de la réponse.
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
}

/// Lecture réelle par URLSession (session éphémère, 2 Mo au plus).
public struct SvcNetworkFetcher: SvcFetching {
    public static let maxBytes = 2 * 1024 * 1024
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 12) {
        self.timeout = timeout
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope", "Accept": "application/json, application/rss+xml, */*"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw SvcParseError.unreadable("réponse trop volumineuse") }
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Vérifie un service : page d'état (ou Microsoft Graph) et adresses clés en parallèle, puis bilan.
public struct SvcChecker: Sendable {
    public var fetcher: SvcFetching
    public var prober: SvcProbing
    /// Accès Microsoft Graph (Microsoft 365 seulement) ; nil : page publique.
    public var graph: SvcGraphCredentials?

    public init(fetcher: SvcFetching, prober: SvcProbing, graph: SvcGraphCredentials? = nil) {
        self.fetcher = fetcher
        self.prober = prober
        self.graph = graph
    }

    public func check(_ service: SvcService, now: Date = Date()) async -> SvcSnapshot {
        async let feedResult = readFeed(service, now: now)
        async let endpointResults = probeAll(service.endpoints)
        let (rawFeed, feedError, source) = await feedResult
        let feed = rawFeed.map { Self.filtered($0, for: service) }
        let endpoints = await endpointResults
        let verdict = SvcVerdictRules.verdict(feed: feed, feedError: feedError, endpoints: endpoints,
                                              hasFeed: service.format != .none || usesGraph(service))
        return SvcSnapshot(serviceID: service.id, date: now, feed: feed, feedError: feedError, feedSource: source,
                           endpoints: endpoints, verdict: verdict)
    }

    /// Garde seulement les incidents qui touchent les parties suivies (`service.components`), ou le
    /// service entier (aucune partie nommée, ou le nom du service) ; recalcule alors l'état de la page.
    public static func filtered(_ feed: SvcFeedReport, for service: SvcService) -> SvcFeedReport {
        guard !service.components.isEmpty else { return feed }
        let followed = service.components.map { $0.lowercased() }
        let whole = [service.name.lowercased()]
        func concerns(_ text: String) -> Bool {
            let lower = text.lowercased()
            return followed.contains { lower.contains($0) || (!lower.isEmpty && $0.contains(lower)) }
        }
        func keep(_ incident: SvcIncident) -> Bool {
            if incident.affected.isEmpty { return true }
            if incident.affected.contains(where: { name in whole.contains { name.lowercased().hasPrefix($0) } }) { return true }
            return incident.affected.contains(where: concerns) || concerns(incident.title)
        }
        let incidents = feed.incidents.filter(keep)
        guard incidents.count != feed.incidents.count else { return feed }
        let components = feed.components.filter { concerns($0.name) }
        let worst = (incidents.filter { !$0.isResolved }.map(\.impact) + components.map(\.health)).max() ?? .operational
        let health = feed.health.isProblem || feed.health == .maintenance ? worst : feed.health
        return SvcFeedReport(health: health, description: SvcFeedParser.describe(health: health, incidents: incidents),
                             incidents: incidents, components: feed.components)
    }

    private func usesGraph(_ service: SvcService) -> Bool {
        service.id == "microsoft365" && graph?.isComplete == true
    }

    /// Adresses testées en parallèle, dans l'ordre du catalogue.
    func probeAll(_ endpoints: [String]) async -> [SvcEndpointResult] {
        await withTaskGroup(of: (Int, SvcEndpointResult).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask { (index, await prober.probe(endpoint)) }
            }
            var results: [(Int, SvcEndpointResult)] = []
            for await item in group { results.append(item) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Page d'état : (rapport, erreur, source lue).
    func readFeed(_ service: SvcService, now: Date) async -> (SvcFeedReport?, String?, String?) {
        var graphError: String?
        if usesGraph(service), let graph {
            do {
                return (try await readGraph(graph), nil, "Microsoft Graph (locataire)")
            } catch {
                graphError = "Microsoft Graph\u{00A0}: " + Self.message(error)
            }
        }
        guard service.format != .none, let text = service.feedURL, let url = URL(string: text) else {
            return (nil, graphError, nil)
        }
        do {
            let (data, status) = try await fetcher.fetch(URLRequest(url: url))
            guard (200..<300).contains(status) else {
                throw SvcParseError.unreadable("HTTP \(status)")
            }
            let report = try SvcFeedParser.parse(data, service: service, now: now)
            return (report, graphError, service.format.label)
        } catch {
            let message = Self.message(error)
            return (nil, graphError.map { $0 + " · page publique\u{00A0}: " + message } ?? message, nil)
        }
    }

    private func readGraph(_ credentials: SvcGraphCredentials) async throws -> SvcFeedReport {
        guard let tokenRequest = SvcGraph.tokenRequest(credentials) else {
            throw SvcParseError.unreadable("identifiants incomplets")
        }
        let (tokenData, _) = try await fetcher.fetch(tokenRequest)
        let token = try SvcGraph.parseToken(tokenData)
        func authorized(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        let (overviewData, overviewStatus) = try await fetcher.fetch(authorized(SvcGraph.healthOverviewsURL))
        guard overviewStatus == 200 else {
            throw SvcParseError.unreadable(overviewStatus == 403 ? "permission ServiceHealth.Read.All manquante (HTTP 403)"
                                           : "HTTP \(overviewStatus)")
        }
        let (issueData, issueStatus) = try await fetcher.fetch(authorized(SvcGraph.issuesURL))
        guard issueStatus == 200 else { throw SvcParseError.unreadable("HTTP \(issueStatus) (issues)") }
        return SvcGraph.report(overviews: try SvcGraph.parseHealthOverviews(overviewData),
                               issues: try SvcGraph.parseIssues(issueData))
    }

    static func message(_ error: Error) -> String {
        if let parse = error as? SvcParseError, case .unreadable(let text) = parse { return text }
        return error.localizedDescription
    }
}

/// Règles du bilan (pures, testées) : « panne chez eux » contre « problème chez nous ».
public enum SvcVerdictRules {
    public static func verdict(feed: SvcFeedReport?, feedError: String?, endpoints: [SvcEndpointResult],
                               hasFeed: Bool = true) -> SvcVerdict {
        let failed = endpoints.filter { !$0.isReachable }
        let allFailed = !endpoints.isEmpty && failed.count == endpoints.count
        let incident = feed?.activeIncidents.max { $0.impact < $1.impact }
        let incidentLine = incident.map { item in
            (item.affected.first.map { "\($0)\u{00A0}: " } ?? "") + item.title
        }
        let cause = failed.first.map { "\($0.host) — \($0.failure?.cause ?? "échec")" }

        // Note 53 : bloqué ici par le filtrage (page de blocage, portail DNS, certificat de
        // remplacement) : ce n'est pas une panne, même si la page d'état en publie une.
        let blocked = endpoints.filter { $0.block != nil }
        if let block = blocked.first?.block {
            var headline = "Bloqué ici · " + block.source
            if let category = block.category { headline += " · catégorie «\u{00A0}\(category)\u{00A0}»" }
            var parts = ["Ce n’est pas une panne\u{00A0}: \(blocked.first?.host ?? "") — \(block.evidence)."]
            if blocked.count < endpoints.count {
                parts.append("\(blocked.count) adresse\(blocked.count > 1 ? "s" : "") sur \(endpoints.count) bloquée\(blocked.count > 1 ? "s" : "") ici.")
            }
            if let feed, feed.health == .outage || feed.health == .degraded {
                parts.append("La page d’état signale aussi un problème\u{00A0}: \(incidentLine ?? feed.description).")
            } else if feed?.health == .operational {
                parts.append("La page d’état est normale.")
            }
            parts.append(block.advice)
            parts.append("Si le blocage est voulu, masquer ce service ou sa catégorie pour ce site.")
            return SvcVerdict(health: .blocked, side: .ours, headline: headline, detail: parts.joined(separator: " "))
        }

        if let feed, feed.health == .outage {
            return SvcVerdict(health: .outage, side: .theirs, headline: incidentLine ?? "Panne publiée sur la page d’état",
                              detail: allFailed ? "Injoignable d’ici aussi, ce qui concorde avec la panne publiée." : nil)
        }
        if allFailed {
            var detail: String
            if let feed, feed.health == .operational {
                detail = "La page d’état est normale\u{00A0}: le problème est probablement de notre côté (DNS, pare-feu, proxy ou lien Internet)."
            } else if let feed, feed.health.isProblem || feed.health == .maintenance {
                detail = "La page d’état signale aussi un problème (\(incidentLine ?? feed.description)), mais aucune adresse ne répond d’ici."
            } else if hasFeed {
                detail = "La page d’état n’a pas pu être lue non plus\u{00A0}: vérifier le lien Internet, le DNS et le pare-feu."
            } else {
                detail = "Aucune page d’état lisible pour ce service\u{00A0}: consulter la page officielle, puis vérifier le DNS, le pare-feu et le proxy."
            }
            if let hint = SvcFilterDetector.silentBlockHint(endpoints) { detail += " " + hint }
            return SvcVerdict(health: .unreachable, side: .ours, headline: "Injoignable d’ici\u{00A0}: " + (failed.first?.failure?.cause ?? "échec"),
                              detail: detail)
        }
        if let feed, feed.health == .degraded {
            return SvcVerdict(health: .degraded, side: .theirs, headline: incidentLine ?? "Service dégradé selon la page d’état",
                              detail: failed.isEmpty ? nil : "De plus, \(failed.count) adresse(s) injoignable(s) d’ici\u{00A0}: \(cause ?? "")")
        }
        if !failed.isEmpty {
            return SvcVerdict(health: .degraded, side: .ours,
                              headline: "\(failed.count) adresse\(failed.count > 1 ? "s" : "") sur \(endpoints.count) injoignable\(failed.count > 1 ? "s" : "") d’ici",
                              detail: (cause ?? "") + (feed?.health == .operational ? " · la page d’état est normale." : "."))
        }
        if let feed, feed.health == .maintenance {
            return SvcVerdict(health: .maintenance, side: .theirs, headline: incidentLine ?? "Maintenance en cours")
        }
        if feed == nil, endpoints.isEmpty {
            return SvcVerdict(health: .unknown, side: .none, headline: feedError.map { "Page d’état illisible\u{00A0}: \($0)" } ?? "Rien à vérifier")
        }
        if feed == nil {
            let headline = hasFeed ? "Joignable d’ici · page d’état non lue" : "Joignable d’ici"
            return SvcVerdict(health: .operational, side: .none, headline: headline, detail: feedError)
        }
        return SvcVerdict(health: .operational, side: .none, headline: "Fonctionne normalement",
                          detail: feedError)
    }

    /// Problème général de notre côté : aucun service joignable d'ici (au moins trois vérifiés).
    public static func globalProblem(_ snapshots: [SvcSnapshot]) -> String? {
        let tested = snapshots.filter { !$0.endpoints.isEmpty }
        guard tested.count >= 3, tested.allSatisfy({ $0.endpoints.allSatisfy { !$0.isReachable } }) else { return nil }
        let failures = tested.flatMap { $0.endpoints.compactMap(\.failure) }
        if failures.allSatisfy({ $0 == .dns }) {
            return "Aucun nom ne se résout\u{00A0}: le DNS de ce réseau (ou de ce Mac) ne répond pas. Vérifier les serveurs DNS et le filtrage DNS."
        }
        if failures.allSatisfy({ $0 == .tls || $0 == .proxy }) {
            return "Toutes les connexions TLS échouent\u{00A0}: un proxy ou une inspection TLS bloque ce Mac."
        }
        return "Aucun service n’est joignable d’ici\u{00A0}: vérifier le lien Internet, le pare-feu et le proxy."
    }

    /// Comptes par état, pour les tuiles et la barre de menus.
    public static func counts(_ snapshots: [SvcSnapshot]) -> [SvcHealth: Int] {
        var result: [SvcHealth: Int] = [:]
        for snapshot in snapshots { result[snapshot.verdict.health, default: 0] += 1 }
        return result
    }
}
