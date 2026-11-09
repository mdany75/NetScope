import Foundation

/// Serveur et compte à essayer. Le secret partagé et le mot de passe n'y figurent jamais : ils
/// passent en paramètres de `RADIUSClient.test`.
public struct RADIUSRequest: Sendable {
    public static let defaultPort: UInt16 = 1812

    public var server: String
    public var port: UInt16
    public var username: String
    public var nasIdentifier: String

    public init(server: String, port: UInt16 = RADIUSRequest.defaultPort, username: String, nasIdentifier: String = "NetScope") {
        self.server = server
        self.port = port
        self.username = username
        self.nasIdentifier = nasIdentifier
    }
}

public enum RADIUSInvalidReason: Equatable, Sendable {
    case responseAuthenticator
    case messageAuthenticator
    case malformed
    case unexpectedCode(UInt8)
}

public enum RADIUSOutcome: Equatable, Sendable {
    case accepted
    case rejected(message: String?)
    case challenge(message: String?)
    case invalidResponse(RADIUSInvalidReason)
    case silent
    case networkError(String)

    public var label: String {
        switch self {
        case .accepted: return "Accepté"
        case .rejected: return "Refusé"
        case .challenge: return "Défi du serveur"
        case .invalidResponse: return "Réponse invalide"
        case .silent: return "Aucune réponse"
        case .networkError: return "Erreur réseau"
        }
    }

    /// Vrai si le Response Authenticator a prouvé que le secret saisi est celui du serveur.
    public var provesSecret: Bool {
        switch self {
        case .accepted, .rejected, .challenge: return true
        case .invalidResponse, .silent, .networkError: return false
        }
    }
}

public struct RADIUSAttribute: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var value: String

    public init(id: Int, name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

public struct RADIUSResult: Sendable {
    public var server: String
    public var address: IPv4Address?
    public var port: UInt16
    public var username: String
    public var outcome: RADIUSOutcome
    public var attributes: [RADIUSAttribute]
    public var sent: Int
    public var duration: TimeInterval
    /// nil sans réponse authentifiée ; sinon, le serveur a-t-il signé (Message-Authenticator) ?
    public var responseSigned: Bool?

    public init(server: String, address: IPv4Address? = nil, port: UInt16, username: String, outcome: RADIUSOutcome,
                attributes: [RADIUSAttribute] = [], sent: Int = 0, duration: TimeInterval = 0, responseSigned: Bool? = nil) {
        self.server = server
        self.address = address
        self.port = port
        self.username = username
        self.outcome = outcome
        self.attributes = attributes
        self.sent = sent
        self.duration = duration
        self.responseSigned = responseSigned
    }
}

public enum RADIUSFormat {
    private static func quoted(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return " Message du serveur\u{00A0}: «\u{00A0}\(message)\u{00A0}»."
    }

    public static func explanation(_ result: RADIUSResult) -> String {
        switch result.outcome {
        case .accepted:
            return "Le serveur a accepté ce compte et signé sa réponse avec le bon secret\u{00A0}: le serveur, le secret partagé et le compte fonctionnent."
        case let .rejected(message):
            return "La réponse est authentifiée, donc le secret partagé est le bon, mais le serveur refuse ce compte\u{00A0}: mot de passe erroné, compte désactivé, ou stratégie réseau (NPS) qui n’autorise pas PAP ou ce client. Le journal du serveur dit lequel." + quoted(message)
        case let .challenge(message):
            return "Le secret partagé est le bon, mais le serveur demande une étape de plus (Access-Challenge), par exemple un code à usage unique. L’essai s’arrête là\u{00A0}: le compte n’est ni accepté ni refusé." + quoted(message)
        case let .invalidResponse(reason):
            switch reason {
            case .responseAuthenticator:
                return "Une réponse est arrivée, mais son Response Authenticator est faux\u{00A0}: le secret saisi n’est pas celui du serveur, ou la réponse ne vient pas de lui. Elle n’a pas été crue."
            case .messageAuthenticator:
                return "Le Message-Authenticator de la réponse est faux\u{00A0}: la réponse a été altérée ou le serveur la signe mal. Elle n’a pas été crue."
            case .malformed:
                return "La réponse est mal formée (attributs incohérents)\u{00A0}: elle n’a pas été crue."
            case let .unexpectedCode(code):
                return "Le serveur a répondu avec un code inattendu (\(code)) à une demande d’accès."
            }
        case .silent:
            return "Aucune réponse après \(result.sent)\u{00A0}envois identiques. Un mauvais secret partagé produit souvent ce silence\u{00A0}: le serveur jette la demande sans rien dire. Autres causes\u{00A0}: ce Mac n’est pas déclaré comme client RADIUS sur le serveur, le port est filtré, ou le service est arrêté. Le journal du serveur (NPS, FreeRADIUS) dit lequel."
        case let .networkError(text):
            return text
        }
    }

    /// Texte à copier : jamais de secret ni de mot de passe, qui ne sont pas dans le résultat.
    public static func report(_ result: RADIUSResult) -> String {
        var lines = ["Test RADIUS (PAP) · \(result.server):\(result.port)",
                     "Compte\u{00A0}: \(result.username)",
                     "Résultat\u{00A0}: \(result.outcome.label)",
                     explanation(result),
                     "Durée\u{00A0}: \(ToolFormat.seconds(result.duration)) · envois\u{00A0}: \(result.sent)"]
        lines += result.attributes.map { "\($0.name) = \($0.value)" }
        return lines.joined(separator: "\n")
    }
}
