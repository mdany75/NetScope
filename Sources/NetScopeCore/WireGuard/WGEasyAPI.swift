import Foundation

// Note 100 (1.3.0) : API REST de wg-easy 15 (routes de server/api du projet wg-easy, version 15) :
//   GET    /api/information                       version en cours, dernière publiée, mode HTTP simple
//   GET    /api/client                            liste des clients
//   POST   /api/client                            ajout { name, expiresAt }
//   GET    /api/client/{id}                       un client
//   POST   /api/client/{id}                       modification (fiche complète, sans les champs du serveur)
//   DELETE /api/client/{id}                       suppression
//   POST   /api/client/{id}/enable | /disable     activer, désactiver
//   GET    /api/client/{id}/configuration         fichier .conf (montré puis oublié)
//   POST   /api/client/{id}/generateOneTimeLink   lien à usage unique (/cnf/<jeton>)
// Authentification HTTP Basic avec le compte administrateur (refusée par wg-easy quand le 2FA est
// actif). Les clés privées et partagées présentes dans les réponses ne sont jamais décodées ni gardées.

/// Client wg-easy 15, tel que NetScope le garde (aucune clé privée ni partagée).
public struct WGEasyClient: Equatable, Codable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var enabled: Bool
    public var ipv4Address: String?
    public var ipv6Address: String?
    public var publicKey: String?
    public var expiresAt: Date?
    public var createdAt: Date?
    public var latestHandshakeAt: Date?
    public var endpoint: String?
    public var transferRx: Int64?
    public var transferTx: Int64?
    public var dns: [String]?
    /// Jeton du lien à usage unique en cours (« /cnf/<jeton> »).
    public var oneTimeLink: String?

    public init(id: Int, name: String, enabled: Bool = true, ipv4Address: String? = nil, ipv6Address: String? = nil,
                publicKey: String? = nil, expiresAt: Date? = nil, createdAt: Date? = nil, latestHandshakeAt: Date? = nil,
                endpoint: String? = nil, transferRx: Int64? = nil, transferTx: Int64? = nil, dns: [String]? = nil,
                oneTimeLink: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.publicKey = publicKey
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.latestHandshakeAt = latestHandshakeAt
        self.endpoint = endpoint
        self.transferRx = transferRx
        self.transferTx = transferTx
        self.dns = dns
        self.oneTimeLink = oneTimeLink
    }

    private enum Keys: String, CodingKey {
        case id, name, enabled, ipv4Address, ipv6Address, publicKey, expiresAt, createdAt, latestHandshakeAt, endpoint
        case transferRx, transferTx, dns, oneTimeLink
    }

    /// Décodage tolérant : dates en texte ISO 8601 (ou jour seul), lien à usage unique objet ou texte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let number = try? c.decode(Int.self, forKey: .id) {
            id = number
        } else if let text = try? c.decode(String.self, forKey: .id), let number = Int(text) {
            id = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id")
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        ipv4Address = try? c.decode(String.self, forKey: .ipv4Address)
        ipv6Address = try? c.decode(String.self, forKey: .ipv6Address)
        publicKey = try? c.decode(String.self, forKey: .publicKey)
        expiresAt = (try? c.decode(String.self, forKey: .expiresAt)).flatMap(WGEasyAPI.date)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(WGEasyAPI.date)
        latestHandshakeAt = (try? c.decode(String.self, forKey: .latestHandshakeAt)).flatMap(WGEasyAPI.date)
        endpoint = try? c.decode(String.self, forKey: .endpoint)
        transferRx = try? c.decode(Int64.self, forKey: .transferRx)
        transferTx = try? c.decode(Int64.self, forKey: .transferTx)
        dns = try? c.decode([String].self, forKey: .dns)
        if let text = try? c.decode(String.self, forKey: .oneTimeLink) {
            oneTimeLink = text
        } else if let object = try? c.decode(OneTimeLink.self, forKey: .oneTimeLink) {
            oneTimeLink = object.oneTimeLink
        } else {
            oneTimeLink = nil
        }
    }

    private struct OneTimeLink: Decodable { var oneTimeLink: String }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(ipv4Address, forKey: .ipv4Address)
        try c.encodeIfPresent(ipv6Address, forKey: .ipv6Address)
        try c.encodeIfPresent(publicKey, forKey: .publicKey)
        try c.encodeIfPresent(expiresAt.map(WGEasyAPI.isoString), forKey: .expiresAt)
        try c.encodeIfPresent(createdAt.map(WGEasyAPI.isoString), forKey: .createdAt)
        try c.encodeIfPresent(latestHandshakeAt.map(WGEasyAPI.isoString), forKey: .latestHandshakeAt)
        try c.encodeIfPresent(endpoint, forKey: .endpoint)
        try c.encodeIfPresent(transferRx, forKey: .transferRx)
        try c.encodeIfPresent(transferTx, forKey: .transferTx)
        try c.encodeIfPresent(dns, forKey: .dns)
        try c.encodeIfPresent(oneTimeLink, forKey: .oneTimeLink)
    }
}

/// « /api/information » : versions et mode HTTP simple.
public struct WGEasyInformation: Equatable, Sendable {
    public var currentRelease: String?
    public var latestRelease: String?
    public var updateAvailable: Bool
    public var insecure: Bool?

    public init(currentRelease: String? = nil, latestRelease: String? = nil, updateAvailable: Bool = false, insecure: Bool? = nil) {
        self.currentRelease = currentRelease
        self.latestRelease = latestRelease
        self.updateAvailable = updateAvailable
        self.insecure = insecure
    }
}

/// Refus ou panne de l'API ; `readOnly` : NetScope passe en lecture seule par SSH.
public struct WGEasyAPIError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case address, unreachable, unauthorized, twoFactor, notVersion15, server, decoding, missingPassword, clientNotFound, plainHTTPRefused
    }
    public var kind: Kind
    public var detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    /// Refus d'authentification (mot de passe, 2FA) : gestion coupée, lecture seule par SSH.
    public var readOnly: Bool { [.unauthorized, .twoFactor, .notVersion15, .missingPassword, .plainHTTPRefused].contains(kind) }

    public var title: String {
        switch kind {
        case .address: return "Adresse de wg-easy invalide"
        case .unreachable: return "wg-easy injoignable"
        case .unauthorized: return "Compte wg-easy refusé"
        case .twoFactor: return "2FA actif sur le compte wg-easy"
        case .notVersion15: return "API de wg-easy 15 introuvable"
        case .server: return "Erreur de wg-easy"
        case .decoding: return "Réponse de wg-easy illisible"
        case .missingPassword: return "Mot de passe de wg-easy à saisir"
        case .clientNotFound: return "Client introuvable"
        case .plainHTTPRefused: return "HTTP simple refusé par macOS"
        }
    }

    public var advice: String {
        switch kind {
        case .twoFactor:
            return "L’API n’accepte pas l’authentification Basic avec le 2FA\u{00A0}: NetScope lit le serveur par SSH en lecture seule. Les changements se font dans wg-easy («\u{00A0}Interface web\u{00A0}»)."
        case .unauthorized, .missingPassword:
            return "Vérifiez le compte administrateur de wg-easy et son mot de passe (gardé au Trousseau). En attendant, lecture seule par SSH."
        case .notVersion15:
            return "Ce serveur n’est pas un wg-easy 15 (une 14 se lit par SSH en lecture seule)."
        case .clientNotFound:
            return "Ce client n’existe plus (supprimé dans wg-easy, par exemple)\u{00A0}: liste relue."
        case .plainHTTPRefused:
            return WGEasyAPI.plainHTTPAdvice + " En attendant, lecture seule par SSH."
        default:
            return "La lecture par SSH continue\u{00A0}; les changements attendent le retour de l’API."
        }
    }
}

/// Modification d'un client par l'API (une à la fois, confirmée).
public enum WGEasyChange: Equatable, Sendable {
    case create(name: String, expiresAt: Date?)
    case rename(id: Int, to: String)
    case setEnabled(id: Int, Bool)
    case setExpiry(id: Int, Date?)
    case setDNS(id: Int, [String]?)
    case delete(id: Int)
}

public enum WGEasyAPI {
    /// Requête HTTP d'une route (méthode, chemin, corps JSON éventuel).
    public struct Route: Equatable, Sendable {
        public var method: String
        public var path: String
        public var body: Data?

        public init(method: String, path: String, body: Data? = nil) {
            self.method = method
            self.path = path
            self.body = body
        }
    }

    public static let information = Route(method: "GET", path: "/api/information")
    public static let clients = Route(method: "GET", path: "/api/client")
    public static func client(_ id: Int) -> Route { Route(method: "GET", path: "/api/client/\(id)") }
    public static func configuration(_ id: Int) -> Route { Route(method: "GET", path: "/api/client/\(id)/configuration") }
    public static func oneTimeLink(_ id: Int) -> Route { Route(method: "POST", path: "/api/client/\(id)/generateOneTimeLink") }

    /// Route d'une modification simple ; `nil` pour celles qui passent par la fiche complète
    /// (renommer, expiration, DNS : `updateBody`).
    public static func route(for change: WGEasyChange) -> Route? {
        switch change {
        case .create(let name, let expiresAt):
            var object: [String: Any] = ["name": name]
            object["expiresAt"] = expiresAt.map(day) ?? NSNull()
            return Route(method: "POST", path: "/api/client", body: try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        case .setEnabled(let id, let on):
            return Route(method: "POST", path: "/api/client/\(id)/\(on ? "enable" : "disable")")
        case .delete(let id):
            return Route(method: "DELETE", path: "/api/client/\(id)")
        case .rename, .setExpiry, .setDNS:
            return nil
        }
    }

    /// Champs du serveur ou secrets retirés de la fiche avant de la renvoyer (et jamais gardés).
    public static let serverOnlyKeys: Set<String> = ["id", "userId", "interfaceId", "privateKey", "publicKey", "preSharedKey",
                                                    "createdAt", "updatedAt", "oneTimeLink", "latestHandshakeAt", "endpoint",
                                                    "transferRx", "transferTx"]

    /// Corps de « POST /api/client/{id} » : la fiche lue juste avant (GET), sans les champs du
    /// serveur ni les clés, avec la modification appliquée.
    public static func updateBody(from fetched: Data, applying change: WGEasyChange) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: fetched) as? [String: Any] else {
            throw WGEasyAPIError(.decoding, "Fiche du client attendue.")
        }
        for key in serverOnlyKeys { object.removeValue(forKey: key) }
        switch change {
        case .rename(_, let name): object["name"] = name
        case .setExpiry(_, let date): object["expiresAt"] = date.map(day) ?? NSNull()
        case .setDNS(_, let servers): object["dns"] = servers ?? NSNull()
        case .setEnabled(_, let on): object["enabled"] = on
        case .create, .delete: throw WGEasyAPIError(.decoding, "Modification inattendue.")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Identifiant du client visé.
    public static func clientID(_ change: WGEasyChange) -> Int? {
        switch change {
        case .create: return nil
        case .rename(let id, _), .setEnabled(let id, _), .setExpiry(let id, _), .setDNS(let id, _), .delete(let id): return id
        }
    }

    /// Modification inverse (retour arrière), d'après la fiche d'avant ; nil quand il n'y en a pas
    /// (une suppression ne se défait pas : les clés du client sont perdues).
    public static func inverse(of change: WGEasyChange, before: WGEasyClient?) -> WGEasyChange? {
        switch change {
        case .create: return nil
        case .delete: return nil
        case .rename(let id, _): return before.map { .rename(id: id, to: $0.name) }
        case .setEnabled(let id, _): return before.map { .setEnabled(id: id, $0.enabled) }
        case .setExpiry(let id, _): return before.map { .setExpiry(id: id, $0.expiresAt) }
        case .setDNS(let id, _): return before.map { .setDNS(id: id, $0.dns) }
        }
    }

    // MARK: Adresse et requêtes

    /// Adresse de l'interface web déduite de l'hôte SSH : `http://hôte:port`, 51821 si le port du
    /// conteneur (variable PORT) est absent ou invalide. nil si l'hôte n'est pas utilisable.
    public static func webInterfaceURL(host: String, port: String?) -> URL? {
        let clean = host.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let number = port.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { (1...65_535).contains($0) ? $0 : nil } ?? 51_821
        let authority = clean.contains(":") && !clean.hasPrefix("[") ? "[\(clean)]" : clean
        return try? baseURL("http://\(authority):\(number)")
    }

    /// « http://wg.exemple.ca:51821 » validée : http ou https, hôte, port ; aucun chemin, aucun identifiant.
    public static func baseURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.path.isEmpty || components.path == "/" else {
            throw WGEasyAPIError(.address, "Attendu\u{00A0}: http://hôte:51821 ou https://hôte")
        }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = components.port
        guard let url = clean.url else { throw WGEasyAPIError(.address, trimmed) }
        return url
    }

    /// Mot de passe envoyé en clair sur le réseau (HTTP simple).
    public static func isInsecure(_ base: URL) -> Bool { base.scheme?.lowercased() == "http" }

    /// macOS (App Transport Security, `NSAllowsLocalNetworking` seulement) refuse le HTTP simple vers un nom
    /// de domaine complet : seuls une adresse IP, un nom sans point ou un nom en .local passent en http://.
    public static func plainHTTPBlocked(_ base: URL) -> Bool {
        guard isInsecure(base), var host = base.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") || host.contains(":") { return false }            // IPv6
        if IPv4Address(host) != nil { return false }
        if !host.contains(".") || host.hasSuffix(".local") { return false }
        return true
    }

    public static let plainHTTPAdvice = "macOS refuse le HTTP simple vers un nom de domaine\u{00A0}: utiliser https://, l’adresse IP ou un nom en .local."

    /// En-tête « Authorization: Basic … ».
    public static func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
    }

    public static func request(_ route: Route, base: URL, user: String, password: String, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(String(route.path.dropFirst())), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = route.method
        request.setValue(basicAuthorization(user: user, password: password), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        if let body = route.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Lien à usage unique : « <adresse>/cnf/<jeton> ».
    public static func oneTimeURL(base: URL, token: String) -> URL? {
        let allowed = token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
        guard allowed, !token.isEmpty else { return nil }
        return base.appendingPathComponent("cnf").appendingPathComponent(token)
    }

    // MARK: Réponses

    /// Code HTTP et corps → erreur (nil : réussite). 401/403 : 2FA si le corps en parle.
    public static func classify(status: Int, body: Data, path: String) -> WGEasyAPIError? {
        if (200..<300).contains(status) { return nil }
        let text = String(decoding: body.prefix(2_000), as: UTF8.self)
        let lower = text.lowercased()
        if status == 401 || status == 403 {
            if lower.contains("totp") || lower.contains("2fa") || lower.contains("two-factor") || lower.contains("two factor") {
                return WGEasyAPIError(.twoFactor, "HTTP \(status)")
            }
            return WGEasyAPIError(.unauthorized, "HTTP \(status)")
        }
        if status == 404, path == "/api/client" || path == "/api/information" {
            return WGEasyAPIError(.notVersion15, "HTTP 404 sur \(path)")
        }
        // 404 sur la fiche d'un client : il a été supprimé ailleurs ; rien de bloquant.
        if status == 404, path.hasPrefix("/api/client/") {
            return WGEasyAPIError(.clientNotFound, "HTTP 404 sur \(path)")
        }
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["message"] as? String) ?? ($0["statusMessage"] as? String) }
        return WGEasyAPIError(.server, "HTTP \(status)" + (message.map { "\u{00A0}: \($0)" } ?? ""))
    }

    public static func decodeClients(_ data: Data) throws -> [WGEasyClient] {
        do {
            return try JSONDecoder().decode([WGEasyClient].self, from: data).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw WGEasyAPIError(.decoding, "Liste des clients attendue.")
        }
    }

    public static func decodeClient(_ data: Data) throws -> WGEasyClient {
        do { return try JSONDecoder().decode(WGEasyClient.self, from: data) } catch {
            throw WGEasyAPIError(.decoding, "Fiche du client attendue.")
        }
    }

    public static func decodeInformation(_ data: Data) throws -> WGEasyInformation {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WGEasyAPIError(.decoding, "Informations attendues.")
        }
        func version(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            if let nested = value as? [String: Any] { return version(nested["version"]) }
            return nil
        }
        return WGEasyInformation(currentRelease: version(object["currentRelease"]), latestRelease: version(object["latestRelease"]),
                                 updateAvailable: (object["updateAvailable"] as? Bool) ?? false, insecure: object["insecure"] as? Bool)
    }

    /// Jeton du lien à usage unique dans la réponse (ou dans la fiche relue).
    public static func decodeOneTimeToken(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = object["oneTimeLink"] as? String { return text }
        if let nested = object["oneTimeLink"] as? [String: Any] { return nested["oneTimeLink"] as? String }
        return nil
    }

    // MARK: Dates

    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: text) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: text) { return value }
        // SQLite « 2026-11-07 10:24:51 » (UTC) ou jour seul « 2026-12-31 ».
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: text) { return value }
        }
        return nil
    }

    static func isoString(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: date)
    }

    /// Jour d'expiration envoyé à wg-easy (« 2026-12-31 »).
    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Envoi des requêtes (session éphémère : aucun témoin, aucun cache, rien sur disque).
public enum WGEasyHTTP {
    public static func send(_ route: WGEasyAPI.Route, base: URL, user: String, password: String) async -> Result<Data, WGEasyAPIError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        if WGEasyAPI.plainHTTPBlocked(base) { return .failure(WGEasyAPIError(.plainHTTPRefused, base.host ?? "")) }
        do {
            let (data, response) = try await session.data(for: WGEasyAPI.request(route, base: base, user: user, password: password))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = WGEasyAPI.classify(status: status, body: data, path: route.path) { return .failure(error) }
            return .success(data)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            return .failure(WGEasyAPIError(.plainHTTPRefused, base.host ?? ""))
        } catch {
            return .failure(WGEasyAPIError(.unreachable, error.localizedDescription))
        }
    }
}
