import Foundation

/// Erreurs de la lecture d'une FortiGate, expliquées en français. Aucune ne contient le jeton.
public enum FortiGateError: Error, Equatable, Sendable, LocalizedError {
    case invalidAddress
    case missingToken
    /// 401 : jeton absent, faux, expiré ou administrateur supprimé.
    case tokenRejected
    /// 403 : hôte de confiance qui ne comprend pas ce Mac, ou profil sans droit de lecture.
    case forbidden(path: String)
    /// 404 : adresse absente dans cette version de FortiOS.
    case notFound(path: String)
    /// Autre code HTTP.
    case http(status: Int, path: String)
    /// Premier contact : certificat inconnu, à accepter par son empreinte.
    case certificateUnknown(fingerprint: String, subject: String)
    /// L'empreinte du certificat ne correspond plus à celle qui a été acceptée.
    case certificateChanged(expected: String, presented: String)
    case timeout
    case cannotConnect(String)
    /// Réponse illisible (pas du JSON, ou sans le contenu attendu).
    case invalidResponse(path: String)
    /// FortiOS a répondu 200 avec « status: error ».
    case apiError(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Adresse de la FortiGate invalide\u{00A0}: saisissez son adresse IP ou son nom (sans «\u{00A0}https://\u{00A0}»)."
        case .missingToken:
            return "Jeton d’API absent\u{00A0}: collez le jeton de l’administrateur API REST puis enregistrez-le au Trousseau."
        case .tokenRejected:
            return "Jeton refusé par la FortiGate (HTTP 401)\u{00A0}: il est faux, a été régénéré ou l’administrateur API a été supprimé. Générez un nouveau jeton (System › Administrators › Regenerate) et collez-le ici."
        case .forbidden(let path):
            return "Accès refusé (HTTP 403) pour \(path)\u{00A0}: l’adresse de ce Mac n’est pas dans les hôtes de confiance de l’administrateur API, ou son profil n’a pas le droit «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture."
        case .notFound(let path):
            return "Adresse absente dans cette version de FortiOS (HTTP 404)\u{00A0}: \(path). NetScope essaie une autre adresse quand elle existe."
        case .http(let status, let path):
            if status >= 500 { return "Erreur interne de la FortiGate (HTTP \(status)) pour \(path)\u{00A0}: réessayez dans un instant." }
            if status == 424 { return "Le VDOM demandé n’existe pas ou n’est pas permis à cet administrateur (HTTP 424)." }
            if status == 429 { return "Trop de requêtes (HTTP 429)\u{00A0}: la FortiGate limite l’API, réessayez dans une minute." }
            return "Réponse inattendue de la FortiGate (HTTP \(status)) pour \(path)."
        case .certificateUnknown(let fingerprint, _):
            return "Certificat de la FortiGate inconnu (autosigné)\u{00A0}: vérifiez son empreinte SHA-256 puis acceptez-la. Empreinte présentée\u{00A0}: \(fingerprint)"
        case .certificateChanged(let expected, let presented):
            return "Le certificat de la FortiGate a changé\u{00A0}: connexion refusée. Empreinte acceptée\u{00A0}: \(expected)\u{00A0}; empreinte présentée\u{00A0}: \(presented). Si le certificat a été renouvelé, vérifiez la nouvelle empreinte sur la FortiGate (System › Certificates) avant de l’accepter."
        case .timeout:
            return "Pas de réponse de la FortiGate dans le délai\u{00A0}: vérifiez l’adresse, le port HTTPS d’administration et que l’accès HTTPS est permis sur l’interface jointe."
        case .cannotConnect(let detail):
            return "Connexion impossible à la FortiGate\u{00A0}: \(detail)"
        case .invalidResponse(let path):
            return "Réponse illisible pour \(path)\u{00A0}: ce n’est pas le JSON attendu de l’API REST de FortiOS."
        case .apiError(let path, let message):
            return "La FortiGate a signalé une erreur pour \(path)\u{00A0}: \(message)"
        }
    }

    /// Erreur correspondant à un code HTTP (nil pour 2xx).
    public static func from(status: Int, path: String) -> FortiGateError? {
        switch status {
        case 200..<300: return nil
        case 401: return .tokenRejected
        case 403: return .forbidden(path: path)
        case 404, 405: return .notFound(path: path)
        default: return .http(status: status, path: path)
        }
    }

    /// Erreur réseau de URLSession, traduite.
    public static func from(urlError error: URLError) -> FortiGateError {
        switch error.code {
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .cannotConnect("nom introuvable (DNS).")
        case .cannotConnectToHost: return .cannotConnect("port HTTPS fermé ou accès d’administration HTTPS non permis sur cette interface.")
        case .notConnectedToInternet, .networkConnectionLost: return .cannotConnect("réseau indisponible.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .cannotConnect("négociation TLS impossible (certificat ou protocole refusé).")
        case .cancelled: return .cannotConnect("connexion annulée.")
        default: return .cannotConnect("erreur réseau (\(error.code.rawValue)).")
        }
    }

    /// Erreur qui empêche toute la lecture (les autres n'écartent qu'une donnée facultative).
    public var isBlocking: Bool {
        switch self {
        case .tokenRejected, .certificateUnknown, .certificateChanged, .cannotConnect, .invalidAddress, .missingToken: return true
        default: return false
        }
    }
}
