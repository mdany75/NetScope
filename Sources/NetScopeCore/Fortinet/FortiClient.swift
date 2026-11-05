import Foundation

// Client de l'API REST de FortiOS, en lecture seule (GET uniquement), en HTTPS. Le jeton part
// dans l'en-tête « Authorization: Bearer … », jamais dans l'adresse ni dans un journal.

/// Réponse HTTP brute.
public struct FortiHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Transport des requêtes GET : URLSession en vrai, réponses fixes dans les tests.
public protocol FortiTransport: Sendable {
    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse
}

/// Adresses de l'API utilisées (toutes en lecture).
public enum FortiPaths {
    public static let systemStatus = "/api/v2/monitor/system/status"
    public static let switchStatus = "/api/v2/monitor/switch-controller/managed-switch/status"
    public static let switchLegacy = "/api/v2/monitor/switch-controller/managed-switch"
    public static let switchConfig = "/api/v2/cmdb/switch-controller/managed-switch"
    public static let portStats = "/api/v2/monitor/switch-controller/managed-switch/port-stats"
    public static let poe = "/api/v2/monitor/switch-controller/managed-switch/poe"
    public static let detectedDevice = "/api/v2/monitor/switch-controller/detected-device"
    public static let arp = "/api/v2/monitor/network/arp"
    public static let dhcp = "/api/v2/monitor/system/dhcp"
    public static let userDevices = "/api/v2/monitor/user/device/query"

    /// Tous les chemins, dans l'ordre de la lecture.
    public static let all = [systemStatus, switchStatus, switchLegacy, switchConfig, portStats, poe, detectedDevice, arp, dhcp, userDevices]
}

/// Retrait du jeton (et de toute forme de secret reconnaissable) d'un texte destiné à être affiché
/// ou copié.
public enum FortiRedact {
    public static func clean(_ text: String, token: String?) -> String {
        var result = text
        if let token, token.count >= 4 { result = result.replacingOccurrences(of: token, with: "«\u{00A0}jeton masqué\u{00A0}»") }
        // access_token=… dans une adresse, « Bearer … » dans un en-tête recopié.
        // Valeur JSON d'une clé qui nomme un secret (« passphrase », « sae-password », « mpsk-key »,
        // « radius-secret », « psk »…), valeur « ENC … » (secret chiffré de FortiOS, récupérable).
        let value = #"(?:[^"\\]|\\.)*"#
        let patterns = [#"(?i)(access_token=)[^&\s"']+"#, #"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#,
                        #"(?i)("[^"]*(?:passphrase|password|passwd|secret|psk|token|api[_-]?key)[^"]*"\s*:\s*")"# + value,
                        #"(?i)("key"\s*:\s*")"# + value,
                        #"(")ENC\s"# + value]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1•••", options: .regularExpression)
        }
        return result
    }
}

/// Transport réel : URLSession éphémère (ni cookie, ni cache), confiance par empreinte.
public final class FortiURLSessionTransport: FortiTransport, @unchecked Sendable {
    public let config: FortiGateConfig
    private let token: String
    private let delegate: FortiSessionDelegate
    private let session: URLSession

    public init(config: FortiGateConfig, token: String) {
        self.config = config
        self.token = token
        delegate = FortiSessionDelegate(pinned: config.pinnedFingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Adresse d'une requête (sans le jeton) : https://hôte:port/chemin?vdom=…
    public static func url(config: FortiGateConfig, path: String, query: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.cleanHost
        components.port = config.effectivePort
        components.path = path
        var items = query
        let vdom = config.vdom.trimmingCharacters(in: .whitespaces)
        if !vdom.isEmpty { items.append(URLQueryItem(name: "vdom", value: vdom)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        guard config.isValid, let url = Self.url(config: config, path: path, query: query) else { throw FortiGateError.invalidAddress }
        guard !token.isEmpty else { throw FortiGateError.missingToken }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FortiGateError.invalidResponse(path: path) }
            return FortiHTTPResponse(status: http.statusCode, body: data)
        } catch let error as FortiGateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if let rejection = delegate.rejection { throw rejection }
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw FortiGateError.from(urlError: error)
        } catch {
            if let rejection = delegate.rejection { throw rejection }
            throw FortiGateError.cannotConnect("erreur inattendue.")
        }
    }
}

/// Lecture complète d'une FortiGate : système, FortiSwitch gérés (état, configuration, ports,
/// PoE), appareils détectés, ARP, DHCP et inventaire. Seul le système est indispensable ; une
/// adresse absente de cette version de FortiOS (404) ou refusée au profil (403) est notée et
/// ignorée, sauf pour la liste des switchs (sans elle, rien à montrer).
public struct FortiGateReader: Sendable {
    public let transport: FortiTransport
    /// Jeton, seulement pour le retirer des réponses brutes (jamais envoyé ici).
    let tokenForRedaction: String?
    /// Taille maximale gardée de chaque réponse brute.
    public static let rawLimit = 48_000

    public init(transport: FortiTransport, tokenForRedaction: String? = nil) {
        self.transport = transport
        self.tokenForRedaction = tokenForRedaction
    }

    /// Une réponse et son enregistrement de diagnostic.
    struct Fetched {
        var response: FortiHTTPResponse?
        var record: FortiCallRecord
        var error: FortiGateError?
    }

    func fetch(_ path: String, query: [URLQueryItem] = []) async throws -> Fetched {
        let shown = query.isEmpty ? path : path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        do {
            let response = try await transport.get(path, query: query)
            let body = String(decoding: response.body.prefix(Self.rawLimit), as: UTF8.self)
                + (response.body.count > Self.rawLimit ? "\n… (réponse tronquée à \(Self.rawLimit) octets)" : "")
            let clean = FortiRedact.clean(body, token: tokenForRedaction)
            if let error = FortiGateError.from(status: response.status, path: path) {
                // Jeton refusé : inutile de poursuivre la lecture.
                if error == .tokenRejected { throw error }
                let outcome: FortiCallRecord.Outcome = (response.status == 404 || response.status == 405) ? .absent : (response.status == 403 ? .refused : .failed)
                return Fetched(response: response, record: FortiCallRecord(path: shown, status: response.status, outcome: outcome,
                                                                           message: error.errorDescription ?? "", body: clean), error: error)
            }
            if let embedded = FortiParsers.embeddedError(response.body) {
                let error = embedded.status.flatMap { FortiGateError.from(status: $0, path: path) } ?? .apiError(path: path, message: embedded.message)
                let outcome: FortiCallRecord.Outcome = embedded.status == 404 ? .absent : (embedded.status == 403 ? .refused : .failed)
                return Fetched(response: response, record: FortiCallRecord(path: shown, status: embedded.status ?? response.status, outcome: outcome,
                                                                           message: error.errorDescription ?? "", body: clean), error: error)
            }
            // Réponse lisible seulement une fois réparée (octets invalides envoyés par FortiOS) : dit dans le diagnostic.
            let message = FortiJSON.needsRepair(response.body)
                ? "Réponse réparée par NetScope\u{00A0}: la FortiGate y a glissé des octets invalides (défaut de FortiOS), retirés avant la lecture."
                : ""
            return Fetched(response: response, record: FortiCallRecord(path: shown, status: response.status, outcome: .ok, message: message, body: clean,
                                                                       items: FortiParsers.itemCount(response.body)), error: nil)
        } catch let error as FortiGateError {
            if error.isBlocking { throw error }
            return Fetched(response: nil, record: FortiCallRecord(path: shown, status: nil, outcome: .failed,
                                                                  message: FortiRedact.clean(error.errorDescription ?? "", token: tokenForRedaction)),
                           error: error)
        }
    }

    /// Test de connexion : seulement l'état du système.
    public func system() async throws -> (FortiGateSystem, FortiCallRecord) {
        let fetched = try await fetch(FortiPaths.systemStatus)
        if let error = fetched.error { throw error }
        guard let body = fetched.response?.body, let system = FortiParsers.system(body) else {
            throw FortiGateError.invalidResponse(path: FortiPaths.systemStatus)
        }
        return (system, fetched.record)
    }

    public func read(now: Date = Date()) async throws -> FortiGateReport {
        do {
            return try await readKeepingCalls(now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `read`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`) : le
    /// diagnostic garde les réponses brutes justement quand la lecture échoue.
    public func readKeepingCalls(now: Date = Date()) async throws -> FortiGateReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readAll(now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readAll(now: Date, calls: inout [FortiCallRecord]) async throws -> FortiGateReport {
        let systemFetched = try await fetch(FortiPaths.systemStatus)
        calls.append(systemFetched.record)
        if let error = systemFetched.error { throw error }
        guard let systemBody = systemFetched.response?.body, let system = FortiParsers.system(systemBody) else {
            throw FortiGateError.invalidResponse(path: FortiPaths.systemStatus)
        }

        // FortiSwitch gérés : adresse 7.x, sinon celle de 6.4 (avec PoE et compteurs).
        var switches: [FortiManagedSwitch] = []
        var status = try await fetch(FortiPaths.switchStatus)
        calls.append(status.record)
        if case .notFound? = status.error {
            status = try await fetch(FortiPaths.switchLegacy, query: [URLQueryItem(name: "poe", value: "true"),
                                                                       URLQueryItem(name: "port_stats", value: "true")])
            calls.append(status.record)
        }
        if let error = status.error {
            // Sans la liste des switchs, la lecture n'a pas de sens : 403 dit quel droit manque.
            throw error
        }
        guard let body = status.response?.body, let parsed = FortiParsers.managedSwitches(body) else {
            throw FortiGateError.invalidResponse(path: FortiPaths.switchStatus)
        }
        switches = parsed

        // Configuration : descriptions, VLAN natif, état administratif, liens FortiLink et ISL.
        let config = try await fetch(FortiPaths.switchConfig)
        calls.append(config.record)
        if let body = config.response?.body, config.error == nil, let map = FortiParsers.switchConfig(body) {
            switches = FortiConvert.merge(switches, config: map)
        }

        // Compteurs des ports.
        let stats = try await fetch(FortiPaths.portStats)
        calls.append(stats.record)
        if let body = stats.response?.body, stats.error == nil, let map = FortiParsers.portStats(body) {
            switches = FortiConvert.merge(switches, stats: map)
        }

        // PoE détaillé, si cette version le publie à part.
        let poe = try await fetch(FortiPaths.poe)
        calls.append(poe.record)
        if let body = poe.response?.body, poe.error == nil, let map = FortiParsers.poe(body) {
            switches = FortiConvert.merge(switches, poe: map)
        }

        var report = FortiGateReport(system: system, switches: switches, readAt: now)

        let detected = try await fetch(FortiPaths.detectedDevice)
        calls.append(detected.record)
        if let body = detected.response?.body, detected.error == nil { report.detected = FortiParsers.detectedDevices(body, now: now) ?? [] }

        let arp = try await fetch(FortiPaths.arp)
        calls.append(arp.record)
        if let body = arp.response?.body, arp.error == nil { report.arp = FortiParsers.arp(body) ?? [] }

        let dhcp = try await fetch(FortiPaths.dhcp)
        calls.append(dhcp.record)
        if let body = dhcp.response?.body, dhcp.error == nil { report.dhcp = FortiParsers.dhcpLeases(body) ?? [] }

        let users = try await fetch(FortiPaths.userDevices)
        calls.append(users.record)
        if let body = users.response?.body, users.error == nil { report.userDevices = FortiParsers.userDevices(body, now: now) ?? [] }

        report.calls = calls
        return report
    }
}

/// Lecture interrompue : l'erreur et les appels faits avant elle (pour le diagnostic).
public struct FortiReadFailure: Error, Sendable {
    public var error: FortiGateError
    public var calls: [FortiCallRecord]

    public init(error: FortiGateError, calls: [FortiCallRecord]) {
        self.error = error
        self.calls = calls
    }
}

/// Réponses brutes de la dernière lecture, à copier pour le diagnostic (sans le jeton).
public enum FortiDiagnostic {
    public static func text(calls: [FortiCallRecord], config: FortiGateConfig, system: FortiGateSystem?, token: String?, date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("NetScope · réponses brutes de la FortiGate (diagnostic, jeton retiré)")
        lines.append("Date : \(formatter.string(from: date))")
        lines.append("FortiGate : \(config.cleanHost):\(config.effectivePort)" + (config.vdom.isEmpty ? "" : " · VDOM \(config.vdom)"))
        if let system {
            lines.append("Modèle : \(system.model) · \(system.versionLabel) · nom \(system.hostname)")
        }
        for call in calls {
            lines.append("")
            lines.append("=== GET \(call.path) → " + (call.status.map { "HTTP \($0)" } ?? "pas de réponse") + " (\(call.outcome.rawValue))")
            if !call.message.isEmpty { lines.append("# " + call.message) }
            if !call.body.isEmpty { lines.append(call.body) }
        }
        return FortiRedact.clean(lines.joined(separator: "\n"), token: token)
    }
}
