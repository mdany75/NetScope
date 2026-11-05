import Foundation

// Note 73 : actions sur le port d'un FortiSwitch géré, par l'API REST de la FortiGate.
//
// Forme des appels (API « monitor » de FortiOS 7.0, 7.2 et 7.4, relevée dans la définition des
// sélecteurs du module Ansible fortinet.fortios « fortios_monitor », qui suit le schéma publié par
// Fortinet sur le FNDN ; à revérifier sur une FortiGate réelle) :
//
//   POST /api/v2/monitor/switch-controller/managed-switch/poe-reset[?vdom=…]
//        corps JSON {"mkey": "<switch-id>", "port": "<port>"}             (mkey et port obligatoires)
//        → la FortiGate coupe puis rétablit elle-même le PoE du port (durée fixée par FortiOS).
//
//   POST /api/v2/monitor/switch-controller/managed-switch/bounce-port[?vdom=…]
//        corps JSON {"mkey": "<switch-id>", "port": "<port>", "duration": <s>}   (duration et stop facultatifs)
//        → le lien du port est coupé `duration` secondes puis rétabli (les clients refont leur DHCP).
//
// mkey = switch-id du FortiSwitch dans FortiOS (le numéro de série par défaut, « S124FFTF21001234 »).
// Réponse : {"status": "success", "http_status": 200, …} ; une erreur : HTTP 401/403/404, ou 200 avec
// {"status": "error", "http_status": 403, …}. Le jeton doit appartenir à un administrateur API dont
// le profil a « WiFi & Switch Controller » en lecture-écriture : en lecture seule, FortiOS répond 403.

/// Requête d'écriture vers la FortiGate (jamais le jeton : il est ajouté par le transport).
public struct FortiWriteRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    /// Corps JSON (clés triées : octets identiques d'une fois à l'autre, testables).
    public var body: Data

    public init(method: String = "POST", path: String, query: [URLQueryItem] = [], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }

    /// Corps lisible (journal, tests).
    public var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// Envoi d'une requête d'écriture (protocole : remplacé par un faux dans les tests).
public protocol FortiWriteTransport: Sendable {
    func send(_ request: FortiWriteRequest) async throws -> FortiHTTPResponse
}

/// Erreurs d'une action sur un port, expliquées en français (sans jeton ni communauté).
public enum PortActionError: Error, Equatable, Sendable, LocalizedError {
    /// FortiOS : 403, profil de l'administrateur API en lecture seule (ou hôte de confiance).
    case readOnlyToken
    case tokenRejected
    /// FortiOS : adresse absente de cette version (404/405).
    case unsupportedByFortiOS(path: String)
    case fortiGate(String)
    /// SNMP : SET refusé (communauté en lecture seule, vue sans écriture, objet non modifiable).
    case snmpWriteRefused(String)
    /// SNMP : aucune réponse au SET (communauté d'écriture fausse : l'agent se tait).
    case snmpNoResponse(String)
    case snmp(String)
    /// Le PoE a été coupé mais n'a pas pu être rallumé : le port reste COUPÉ.
    case poeLeftOff(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .readOnlyToken:
            return "Refusé par la FortiGate (HTTP 403)\u{00A0}: le profil d’administrateur du jeton est en lecture seule. Donnez au profil de l’administrateur API le droit «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture-écriture (System › Admin Profiles), ou utilisez un jeton dédié aux actions. Vérifiez aussi que ce Mac est dans ses hôtes de confiance."
        case .tokenRejected:
            return "Jeton refusé par la FortiGate (HTTP 401)\u{00A0}: il est faux, régénéré ou l’administrateur API a été supprimé."
        case .unsupportedByFortiOS(let path):
            return "Action absente de cette version de FortiOS (\(path))."
        case .fortiGate(let message):
            return message
        case .snmpWriteRefused(let detail):
            return "Le switch refuse l’écriture SNMP (\(detail))\u{00A0}: la communauté ou l’utilisateur v3 n’a pas le droit d’écrire pethPsePortAdminEnable (vue SNMP en lecture seule, ou objet non modifiable sur ce modèle)."
        case .snmpNoResponse(let host):
            return "Pas de réponse SNMP de \(host) à l’écriture\u{00A0}: communauté d’écriture incorrecte, SNMP en écriture désactivé, ou ce Mac n’est pas autorisé à écrire."
        case .snmp(let message):
            return message
        case .poeLeftOff(let detail):
            return "ATTENTION\u{00A0}: le PoE a été coupé mais n’a pas pu être rallumé (\(detail)). Le port reste sans courant\u{00A0}: rallumez-le sur le switch (pethPsePortAdminEnable = true, ou «\u{00A0}power inline auto\u{00A0}»)."
        case .cancelled:
            return "Action annulée avant l’envoi."
        }
    }
}

/// Construction des appels et lecture des réponses de la FortiGate (sans réseau).
public enum FortiPortActions {
    public static let poeResetPath = "/api/v2/monitor/switch-controller/managed-switch/poe-reset"
    public static let bouncePortPath = "/api/v2/monitor/switch-controller/managed-switch/bounce-port"

    /// Cycle PoE d'un port : POST poe-reset {"mkey", "port"}.
    public static func poeReset(switchID: String, port: String, vdom: String = "") -> FortiWriteRequest {
        FortiWriteRequest(path: poeResetPath, query: vdomQuery(vdom), body: json(["mkey": switchID, "port": port]))
    }

    /// Redémarrage du port : POST bounce-port {"mkey", "port", "duration"} (1 à 30 s ici).
    public static func bouncePort(switchID: String, port: String, duration: Int, vdom: String = "") -> FortiWriteRequest {
        let seconds = min(max(duration, PortActionSettings.bounceRange.lowerBound), PortActionSettings.bounceRange.upperBound)
        return FortiWriteRequest(path: bouncePortPath, query: vdomQuery(vdom),
                                 body: json(["mkey": switchID, "port": port, "duration": seconds]))
    }

    /// Requête d'une action (seuls le cycle PoE et le redémarrage existent).
    public static func request(_ kind: PortActionKind, switchID: String, port: String, settings: PortActionSettings,
                               vdom: String = "") -> FortiWriteRequest {
        switch kind {
        case .poeCycle: return poeReset(switchID: switchID, port: port, vdom: vdom)
        case .portRestart: return bouncePort(switchID: switchID, port: port, duration: settings.bounceSeconds, vdom: vdom)
        }
    }

    static func vdomQuery(_ vdom: String) -> [URLQueryItem] {
        let clean = vdom.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? [] : [URLQueryItem(name: "vdom", value: clean)]
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Lit la réponse : nil si l'action est acceptée, sinon l'erreur expliquée.
    public static func interpret(_ response: FortiHTTPResponse, path: String) -> PortActionError? {
        func fromStatus(_ status: Int, message: String?) -> PortActionError? {
            switch status {
            case 200..<300: return nil
            case 401: return .tokenRejected
            case 403: return .readOnlyToken
            case 404, 405: return .unsupportedByFortiOS(path: path)
            default:
                let detail = message.map { "\u{00A0}: \($0)" } ?? ""
                return .fortiGate("La FortiGate a refusé l’action (HTTP \(status))\(detail).")
            }
        }
        if let error = fromStatus(response.status, message: nil) { return error }
        if let embedded = FortiParsers.embeddedError(response.body) {
            if let status = embedded.status, let error = fromStatus(status, message: embedded.message) { return error }
            return .fortiGate("La FortiGate a signalé une erreur\u{00A0}: \(embedded.message)")
        }
        // 2xx sans « status: success » explicite : FortiOS l'ajoute toujours, un corps vide reste accepté.
        return nil
    }

    /// Envoie l'action et lit la réponse ; les erreurs réseau sont traduites comme pour la lecture.
    public static func perform(_ request: FortiWriteRequest, transport: FortiWriteTransport) async throws {
        let response: FortiHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as FortiGateError {
            if error == .tokenRejected { throw PortActionError.tokenRejected }
            throw PortActionError.fortiGate(error.errorDescription ?? "Connexion impossible à la FortiGate.")
        }
        if let error = interpret(response, path: request.path) { throw error }
    }
}

/// Transport réel : URLSession éphémère, certificat vérifié par son empreinte (comme la lecture),
/// aucune redirection suivie (le jeton ne part jamais ailleurs).
public final class FortiURLSessionWriter: FortiWriteTransport, @unchecked Sendable {
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

    public func send(_ request: FortiWriteRequest) async throws -> FortiHTTPResponse {
        // Le VDOM vient de la requête (déjà dans `query`) : l'adresse est construite sans en rajouter.
        var bare = config
        bare.vdom = ""
        guard config.isValid, let url = FortiURLSessionTransport.url(config: bare, path: request.path, query: request.query) else {
            throw FortiGateError.invalidAddress
        }
        guard !token.isEmpty else { throw FortiGateError.missingToken }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw FortiGateError.invalidResponse(path: request.path) }
            return FortiHTTPResponse(status: http.statusCode, body: data)
        } catch let error as FortiGateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if let rejection = delegate.rejection { throw rejection }
            throw FortiGateError.from(urlError: error)
        } catch {
            if let rejection = delegate.rejection { throw rejection }
            throw FortiGateError.cannotConnect("erreur inattendue.")
        }
    }
}

/// Retrouve, dans les lectures des FortiGate, le FortiSwitch d'un relevé « via FortiGate ».
public enum FortiPortLocator {
    /// FortiSwitch nommé `switchName` dans les lectures des sites ; le site (`controllerName` du
    /// relevé) départage deux switchs de même nom sur deux FortiGate.
    public static func reference(switchName: String, site: String?, in sites: [FortiSiteReport]) -> FortiPortRef? {
        let wanted = switchName.lowercased()
        let ordered = sites.filter { site == nil || $0.label == site } + sites.filter { site != nil && $0.label != site }
        for report in ordered {
            if let sw = report.report.switches.first(where: { $0.name.lowercased() == wanted || $0.switchID.lowercased() == wanted
                || (!$0.serial.isEmpty && $0.serial.lowercased() == wanted) }) {
                return FortiPortRef(controllerID: report.controllerID, controllerName: report.label, switchID: sw.switchID, serial: sw.serial)
            }
        }
        return nil
    }
}
