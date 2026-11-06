import Foundation
import Security

// Note 77 : transport HTTPS des contrôleurs, injectable (réponses fixes dans les tests, rien sur le
// réseau). Les lecteurs ne font que des GET de lecture ; les seuls POST sont l'ouverture de session
// (compte local UniFi, API web Omada) et la demande du jeton de l'Open API d'Omada, puis la
// fermeture de session : jamais de modification de la configuration.

/// Requête vers le contrôleur (chemin relatif à l'adresse du contrôleur).
public struct ControllerRequest: Hashable, Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    /// En-têtes, dont l'authentification (jamais affichés ni journalisés).
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// « /api/s/default/stat/device?x=1 » : forme affichée dans le diagnostic (sans en-tête).
    public var shownPath: String {
        query.isEmpty ? path : path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }
}

/// Réponse HTTP brute.
public struct ControllerResponse: Sendable {
    public var status: Int
    /// En-têtes, noms en minuscules.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        var lower: [String: String] = [:]
        for (key, value) in headers { lower[key.lowercased()] = value }
        self.headers = lower
        self.body = body
    }
}

public protocol ControllerTransport: Sendable {
    func send(_ request: ControllerRequest) async throws -> ControllerResponse
}

// MARK: - Erreurs

/// Erreurs de la lecture d'un contrôleur, en français. Aucune ne contient de secret.
public enum ControllerError: Error, Equatable, Sendable, LocalizedError {
    case invalidAddress
    case missingSecret
    case missingAccount
    /// 401, ou ouverture de session refusée.
    case authRejected(ControllerKind)
    /// 403 sur une adresse.
    case forbidden(path: String)
    case notFound(path: String)
    case http(status: Int, path: String)
    case rateLimited
    case certificateUnknown(fingerprint: String, subject: String)
    case certificateChanged(expected: String, presented: String)
    case timeout
    case cannotConnect(String)
    case invalidResponse(path: String)
    /// Le contrôleur a répondu 200 avec une erreur (« rc: error », « errorCode ≠ 0 »).
    case apiError(path: String, message: String)
    /// Site, réseau ou organisation introuvable ; les noms disponibles sont proposés.
    case scopeNotFound(wanted: String, available: [String])
    /// Redirection vers une adresse qui n'est pas celle du contrôleur (refusée : le secret n'y part pas).
    case unsafeRedirect(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Adresse du contrôleur invalide\u{00A0}: saisissez son adresse IP ou son nom (sans «\u{00A0}https://\u{00A0}»)."
        case .missingSecret:
            return "Secret absent\u{00A0}: saisissez la clé d’API ou le mot de passe, gardé au Trousseau."
        case .missingAccount:
            return "Identifiant absent\u{00A0}: saisissez l’identifiant du compte ou le Client ID."
        case .authRejected(let kind):
            switch kind {
            case .unifi:
                return "Accès refusé par le contrôleur UniFi (HTTP 401)\u{00A0}: clé d’API fausse ou révoquée, ou identifiant et mot de passe refusés (un compte local est requis, pas un compte UI.com avec double authentification)."
            case .omada:
                return "Accès refusé par le contrôleur Omada\u{00A0}: Client ID et secret refusés (Paramètres › Plateforme › Open API, mode «\u{00A0}Client\u{00A0}»), ou identifiant et mot de passe refusés."
            case .meraki:
                return "Clé d’API refusée par Meraki (HTTP 401)\u{00A0}: clé fausse, révoquée, ou accès à l’API non activé dans l’organisation (Organisation › Paramètres › Accès à l’API)."
            }
        case .forbidden(let path):
            return "Accès refusé (HTTP 403) pour \(path)\u{00A0}: le compte ou la clé n’a pas le droit de lire cette partie."
        case .notFound(let path):
            return "Adresse absente sur ce contrôleur (HTTP 404)\u{00A0}: \(path). Vérifiez le type (UniFi OS ou contrôleur classique) et la version."
        case .http(let status, let path):
            if status >= 500 { return "Erreur interne du contrôleur (HTTP \(status)) pour \(path)\u{00A0}: réessayez dans un instant." }
            return "Réponse inattendue du contrôleur (HTTP \(status)) pour \(path)."
        case .rateLimited:
            return "Trop de requêtes (HTTP 429)\u{00A0}: le contrôleur limite l’API, réessayez dans une minute."
        case .certificateUnknown(let fingerprint, _):
            return "Certificat du contrôleur inconnu (souvent autosigné)\u{00A0}: vérifiez son empreinte SHA-256 puis acceptez-la. Empreinte présentée\u{00A0}: \(fingerprint)"
        case .certificateChanged(let expected, let presented):
            return "Le certificat du contrôleur a changé\u{00A0}: connexion refusée. Empreinte acceptée\u{00A0}: \(expected)\u{00A0}; empreinte présentée\u{00A0}: \(presented). Vérifiez la nouvelle empreinte avant de l’accepter."
        case .timeout:
            return "Pas de réponse du contrôleur dans le délai\u{00A0}: vérifiez l’adresse, le port HTTPS et le pare-feu."
        case .cannotConnect(let detail):
            return "Connexion impossible au contrôleur\u{00A0}: \(detail)"
        case .invalidResponse(let path):
            return "Réponse illisible pour \(path)\u{00A0}: ce n’est pas le JSON attendu de cette API."
        case .apiError(let path, let message):
            return "Le contrôleur a signalé une erreur pour \(path)\u{00A0}: \(message)"
        case .scopeNotFound(let wanted, let available):
            let list = available.prefix(8).map { "«\u{00A0}\($0)\u{00A0}»" }.joined(separator: ", ")
            return "«\u{00A0}\(wanted)\u{00A0}» introuvable sur le contrôleur." + (available.isEmpty ? "" : " Disponibles\u{00A0}: \(list)" + (available.count > 8 ? "…" : "") + ".")
        case .unsafeRedirect(let host):
            return "Redirection refusée vers «\u{00A0}\(host)\u{00A0}»\u{00A0}: le secret ne part jamais vers une autre adresse que celle du contrôleur."
        }
    }

    public static func from(status: Int, path: String, kind: ControllerKind) -> ControllerError? {
        switch status {
        case 200..<300: return nil
        case 401: return .authRejected(kind)
        case 403: return .forbidden(path: path)
        case 404, 405: return .notFound(path: path)
        case 429: return .rateLimited
        default: return .http(status: status, path: path)
        }
    }

    public static func from(urlError error: URLError) -> ControllerError {
        switch error.code {
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .cannotConnect("nom introuvable (DNS).")
        case .cannotConnectToHost: return .cannotConnect("port HTTPS fermé ou refusé.")
        case .notConnectedToInternet, .networkConnectionLost: return .cannotConnect("réseau indisponible.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .cannotConnect("négociation TLS impossible (certificat ou protocole refusé).")
        case .cancelled: return .cannotConnect("connexion annulée.")
        default: return .cannotConnect("erreur réseau (\(error.code.rawValue)).")
        }
    }

    /// Erreur qui arrête toute la lecture (les autres n'écartent qu'une partie facultative).
    public var isBlocking: Bool {
        switch self {
        case .authRejected, .certificateUnknown, .certificateChanged, .cannotConnect, .invalidAddress, .missingSecret,
             .missingAccount, .timeout, .scopeNotFound, .unsafeRedirect:
            return true
        default:
            return false
        }
    }
}

// MARK: - Secrets retirés

public enum ControllerRedact {
    /// Retire le secret, l'identifiant de session et toute valeur de champ secret reconnaissable.
    public static func clean(_ text: String, secrets: [String]) -> String {
        var result = FortiRedact.clean(text, token: nil)
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "«\u{00A0}secret masqué\u{00A0}»")
        }
        let value = #"(?:[^"\\]|\\.)*"#
        let patterns = [#"(?i)("(?:x_passphrase|wpa_psk|x_password|x_iapp_key|x_shadow|accessToken|refreshToken|csrfToken|client_secret|psk|privateKey)"\s*:\s*")"# + value,
                        #"(?i)(AccessToken=)[A-Za-z0-9._\-]+"#]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1•••", options: .regularExpression)
        }
        return result
    }
}

// MARK: - Transport réel

/// Transport réel : URLSession éphémère (cookies en mémoire pour la session du compte local,
/// jamais sur le disque), confiance par empreinte pour un contrôleur local, vérification normale du
/// système pour Meraki. Les redirections ne sont suivies que vers le même hôte, ou vers un autre
/// nœud *.meraki.com (l'API Meraki redirige vers le nœud de l'organisation).
public final class ControllerURLSessionTransport: ControllerTransport, @unchecked Sendable {
    public let controller: SiteController
    private let delegate: ControllerSessionDelegate
    private let session: URLSession

    public init(controller: SiteController) {
        self.controller = controller
        delegate = ControllerSessionDelegate(pinned: controller.usesPinning ? controller.pinnedFingerprint : nil,
                                             pinning: controller.usesPinning)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = controller.timeout
        configuration.timeoutIntervalForResource = controller.timeout * 3
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public static func url(host: String, port: Int, request: ControllerRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port == 443 ? nil : port
        components.path = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        return components.url
    }

    /// Hôte vers lequel une redirection est permise.
    public static func redirectAllowed(from original: String, to target: String, kind: ControllerKind) -> Bool {
        let a = original.lowercased()
        let b = target.lowercased()
        if a == b { return true }
        return kind == .meraki && (b == "meraki.com" || b.hasSuffix(".meraki.com"))
    }

    public func send(_ request: ControllerRequest) async throws -> ControllerResponse {
        guard controller.hasValidAddress, var url = Self.url(host: controller.cleanHost, port: controller.effectivePort, request: request) else {
            throw ControllerError.invalidAddress
        }
        var hops = 0
        while true {
            var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: controller.timeout)
            urlRequest.httpMethod = request.method
            for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            if urlRequest.value(forHTTPHeaderField: "Accept") == nil { urlRequest.setValue("application/json", forHTTPHeaderField: "Accept") }
            if let body = request.body {
                urlRequest.httpBody = body
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let response: ControllerResponse
            do {
                let (data, raw) = try await session.data(for: urlRequest)
                guard let http = raw as? HTTPURLResponse else { throw ControllerError.invalidResponse(path: request.path) }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String { headers[k] = v }
                }
                response = ControllerResponse(status: http.statusCode, headers: headers, body: data)
            } catch let error as ControllerError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if let rejection = delegate.rejection { throw rejection }
                if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
                throw ControllerError.from(urlError: error)
            } catch {
                if let rejection = delegate.rejection { throw rejection }
                throw ControllerError.cannotConnect("erreur inattendue.")
            }
            // Redirection : suivie à la main, seulement vers une adresse permise (GET seulement).
            if [301, 302, 303, 307, 308].contains(response.status), request.method == "GET", hops < 3,
               let location = response.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL {
                guard next.scheme == "https", let host = next.host,
                      Self.redirectAllowed(from: controller.cleanHost, to: host, kind: controller.kind) else {
                    throw ControllerError.unsafeRedirect(next.host ?? location)
                }
                url = next
                hops += 1
                continue
            }
            return response
        }
    }
}

/// Délégué : certificat vérifié par empreinte (contrôleur local) ou par le système (Meraki) ;
/// aucune redirection automatique (le transport les suit lui-même, vers une adresse permise).
final class ControllerSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pinned: String?
    let pinning: Bool
    private let lock = NSLock()
    private var _rejection: ControllerError?

    init(pinned: String?, pinning: Bool) {
        self.pinned = pinned
        self.pinning = pinning
    }

    var rejection: ControllerError? {
        lock.lock()
        defer { lock.unlock() }
        return _rejection
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard pinning else {
            // Meraki : certificat public, vérification normale du système.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let presented = FortiCertificatePin.fingerprint(der: SecCertificateCopyData(leaf) as Data)
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        switch FortiCertificatePin.evaluate(presented: presented, pinned: pinned) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .unknown(let fp):
            record(.certificateUnknown(fingerprint: fp, subject: subject))
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .changed(let expected, let fp):
            record(.certificateChanged(expected: expected, presented: fp))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func record(_ error: ControllerError) {
        lock.lock()
        _rejection = error
        lock.unlock()
    }
}

// MARK: - Transport de test

/// Réponses fixes par chemin (tests et démonstration) : aucune connexion. Chaque requête reçue est
/// gardée (sans rien envoyer) pour vérifier les en-têtes et l'ordre des appels.
public final class ControllerFixedTransport: ControllerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: ControllerResponse]
    private var _requests: [ControllerRequest] = []

    /// `routes` : « GET /chemin » ou « /chemin » (toute méthode) → réponse.
    public init(_ routes: [String: ControllerResponse]) {
        self.routes = routes
    }

    public convenience init(json: [String: String]) {
        var map: [String: ControllerResponse] = [:]
        for (key, text) in json { map[key] = ControllerResponse(status: 200, body: Data(text.utf8)) }
        self.init(map)
    }

    public var requests: [ControllerRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    public func set(_ path: String, _ response: ControllerResponse) {
        lock.lock()
        routes[path] = response
        lock.unlock()
    }

    public func send(_ request: ControllerRequest) async throws -> ControllerResponse {
        answer(request) ?? ControllerResponse(status: 404, body: Data(#"{"error":"absent"}"#.utf8))
    }

    private func answer(_ request: ControllerRequest) -> ControllerResponse? {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        return routes["\(request.method) \(request.path)"] ?? routes[request.path]
    }
}
