import Foundation

// Note 54 : lecture FortiView d'une FortiGate (GET seulement), avec le même transport et le même
// jeton que les FortiSwitch. Adresses selon la version :
// - FortiOS 7.0 et plus : /monitor/fortiview/realtime-statistics (temps réel) et
//   /monitor/fortiview/historical-statistics (5 min à 7 jours, journaux sur disque ou FortiAnalyzer) ;
// - FortiOS 6.4 : /monitor/fortiview/statistics avec realtime=true ou start/end.
// Chaque vue demande « report_by » (source, destination, application…), « sort_by » et « count ».
// Sessions : /monitor/firewall/session (count, summary). Liens : cmdb et monitor system/interface.
// Une adresse absente (404) fait passer à la suivante ; une valeur de « report_by » refusée (400)
// à la suivante ; un droit manquant (403) est noté pour la vue, les autres continuent.

/// Adresses de l'API utilisées pour le trafic (toutes en lecture).
public enum TrafficPaths {
    public static let realtime = "/api/v2/monitor/fortiview/realtime-statistics"
    public static let historical = "/api/v2/monitor/fortiview/historical-statistics"
    /// FortiOS 6.4 : une seule adresse, temps réel ou historique selon « realtime ».
    public static let legacy = "/api/v2/monitor/fortiview/statistics"
    public static let sessions = "/api/v2/monitor/firewall/session"
    public static let interfacesConfig = FortiPaths.interfacesConfig
    public static let interfacesMonitor = FortiPaths.interfacesMonitor
    /// Champs demandés à cmdb system/interface : rôle et débits déclarés, jamais de secret.
    public static let interfaceFields = "name|alias|role|type|estimated-upstream-bandwidth|estimated-downstream-bandwidth"

    public static let all = [realtime, historical, legacy, sessions, interfacesConfig, interfacesMonitor]
}

/// Ce qu'on demande à FortiView.
public struct TrafficReadOptions: Hashable, Sendable {
    public var period: TrafficPeriod
    public var views: [TrafficView]
    public var sort: TrafficSort
    /// Lignes par vue.
    public var count: Int
    /// Sessions lues (les plus gros transferts sont gardés).
    public var sessionCount: Int

    public init(period: TrafficPeriod = .realtime, views: [TrafficView] = TrafficView.allCases, sort: TrafficSort = .bandwidth,
                count: Int = 50, sessionCount: Int = 200) {
        self.period = period
        self.views = views
        self.sort = sort
        self.count = max(1, min(count, 1000))
        self.sessionCount = max(1, min(sessionCount, 1000))
    }
}

extension FortiGateReader {
    /// Lit les vues FortiView demandées, les sessions et les liens. Erreur levée seulement si le
    /// jeton est refusé, si la FortiGate est injoignable, ou si TOUTES les vues sont refusées (403 :
    /// droits « FortiView » / « Log & Report » à ajouter, expliqué par `trafficDescription`).
    public func readTraffic(_ options: TrafficReadOptions, now: Date = Date()) async throws -> TrafficReadReport {
        do {
            return try await readTrafficKeepingCalls(options, now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `readTraffic`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`).
    public func readTrafficKeepingCalls(_ options: TrafficReadOptions, now: Date = Date()) async throws -> TrafficReadReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readTrafficAll(options, now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    /// Adresses FortiView à essayer, dans l'ordre, pour une période.
    static func trafficEndpoints(_ period: TrafficPeriod) -> [String] {
        period.isRealtime ? [TrafficPaths.realtime, TrafficPaths.legacy] : [TrafficPaths.historical, TrafficPaths.legacy]
    }

    /// Paramètres d'une requête FortiView.
    static func trafficQuery(endpoint: String, reportBy: String, options: TrafficReadOptions, now: Date) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "report_by", value: reportBy),
                     URLQueryItem(name: "sort_by", value: options.sort.apiValue(for: options.period)),
                     URLQueryItem(name: "count", value: String(options.count))]
        if endpoint == TrafficPaths.legacy {
            items.insert(URLQueryItem(name: "realtime", value: options.period.isRealtime ? "true" : "false"), at: 0)
        }
        if let seconds = options.period.seconds {
            // Horodatages Unix en secondes (la fin : maintenant).
            let end = Int(now.timeIntervalSince1970)
            items.append(URLQueryItem(name: "start", value: String(end - Int(seconds))))
            items.append(URLQueryItem(name: "end", value: String(end)))
        }
        return items
    }

    private func readTrafficAll(_ options: TrafficReadOptions, now: Date, calls: inout [FortiCallRecord]) async throws -> TrafficReadReport {
        var report = TrafficReadReport(period: options.period, readAt: now)
        var endpoints = Self.trafficEndpoints(options.period)
        var refusedViews: [TrafficView] = []
        var firstForbidden: FortiGateError?

        for view in options.views where view != .sessions {
            var status: TrafficViewStatus = .absent
            var lastError: FortiGateError?
            viewLoop: for reportBy in view.reportBy {
                let index = 0
                while index < endpoints.count {
                    let endpoint = endpoints[index]
                    let fetched = try await fetch(endpoint, query: Self.trafficQuery(endpoint: endpoint, reportBy: reportBy, options: options, now: now))
                    calls.append(fetched.record)
                    switch fetched.error {
                    case nil:
                        // Cette adresse répond : les vues suivantes ne réessaient plus les autres.
                        endpoints = [endpoint]
                        report.endpoint = endpoint
                        if let body = fetched.response?.body, let parsed = TrafficParsers.entries(body, view: view) {
                            report.entries += parsed
                            status = parsed.isEmpty ? .empty : .ok
                        } else {
                            status = .failed
                            lastError = .invalidResponse(path: endpoint)
                        }
                        break viewLoop
                    case .notFound?:
                        // Adresse absente de cette version : la suivante (les vues suivantes ne la redemandent pas).
                        if endpoints.count > 1 {
                            endpoints.remove(at: index)
                            continue
                        }
                        status = .absent
                        lastError = fetched.error
                        break viewLoop
                    case .forbidden?:
                        status = .refused
                        lastError = fetched.error
                        if firstForbidden == nil { firstForbidden = fetched.error }
                        break viewLoop
                    case .http(let code, _)? where code == 400 || code == 422 || code == 500:
                        // Valeur de « report_by » inconnue de cette version : la suivante.
                        status = .absent
                        lastError = fetched.error
                        continue viewLoop
                    case .apiError?:
                        status = .absent
                        lastError = fetched.error
                        continue viewLoop
                    case .some(let error):
                        status = .failed
                        lastError = error
                        break viewLoop
                    }
                }
            }
            report.statuses[view] = status
            if status == .refused { refusedViews.append(view) }
            if let note = Self.trafficNote(view, status: status, error: lastError, period: options.period) { report.notes.append(note) }
        }

        let readsFortiView = options.views.contains { $0 != .sessions }
        if readsFortiView, refusedViews.count == options.views.filter({ $0 != .sessions }).count, let forbidden = firstForbidden {
            // Aucune vue lisible : le profil n'a pas le droit FortiView.
            report.calls = calls
            throw forbidden
        }

        if options.views.contains(.sessions) {
            let fetched = try await fetch(TrafficPaths.sessions, query: [URLQueryItem(name: "count", value: String(options.sessionCount)),
                                                                        URLQueryItem(name: "summary", value: "true")])
            calls.append(fetched.record)
            if let body = fetched.response?.body, fetched.error == nil, let list = TrafficParsers.sessions(body) {
                report.sessions = list.sorted { $0.bytes > $1.bytes }
                report.statuses[.sessions] = list.isEmpty ? .empty : .ok
            } else {
                let status: TrafficViewStatus
                switch fetched.error {
                case .forbidden?: status = .refused
                case .notFound?: status = .absent
                default: status = .failed
                }
                report.statuses[.sessions] = status
                if let note = Self.trafficNote(.sessions, status: status, error: fetched.error, period: options.period) { report.notes.append(note) }
            }
        }

        // Liens : rôle et débits déclarés (cmdb), vitesse et état (monitor). Facultatifs.
        let config = try await fetch(TrafficPaths.interfacesConfig, query: [URLQueryItem(name: "format", value: TrafficPaths.interfaceFields)])
        calls.append(config.record)
        let monitor = try await fetch(TrafficPaths.interfacesMonitor)
        calls.append(monitor.record)
        let links = TrafficParsers.links(config: config.error == nil ? config.response?.body : nil,
                                         monitor: monitor.error == nil ? monitor.response?.body : nil) ?? []
        report.links = TrafficParsers.applyRates(links, interfaces: report.entries(.interfaces))
        if links.isEmpty, config.error != nil, monitor.error != nil {
            report.notes.append("Liens WAN\u{00A0}: interfaces illisibles (droit «\u{00A0}Network\u{00A0}» en lecture)\u{00A0}; la charge des liens n’est pas calculée.")
        } else if !links.contains(where: \.isWAN) {
            report.notes.append("Aucune interface de rôle «\u{00A0}WAN\u{00A0}» sur cette FortiGate\u{00A0}: la charge du lien Internet n’est pas calculée.")
        }

        report.calls = calls
        return report
    }

    /// Explication d'une vue absente, refusée ou vide.
    static func trafficNote(_ view: TrafficView, status: TrafficViewStatus, error: FortiGateError?, period: TrafficPeriod) -> String? {
        let part = view.label
        switch status {
        case .ok: return nil
        case .empty:
            if !period.isRealtime, view != .threats, view != .sessions {
                return "\(part)\u{00A0}: aucun historique \(period.span) (journalisation du trafic sur disque, FortiAnalyzer ou FortiGate Cloud nécessaire)."
            }
            return nil
        case .absent:
            return "\(part)\u{00A0}: vue absente de cette version de FortiOS."
        case .refused:
            return "\(part)\u{00A0}: accès refusé (HTTP 403), ajoutez les droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture au profil de l’administrateur API."
        case .failed:
            return "\(part)\u{00A0}: " + (error?.errorDescription ?? "lecture impossible.")
        }
    }
}

extension FortiGateError {
    /// Message propre au trafic pour un 403 sur FortiView.
    public var trafficDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) à FortiView\u{00A0}: ajoutez les droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
