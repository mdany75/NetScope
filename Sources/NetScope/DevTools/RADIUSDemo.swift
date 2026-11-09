import Foundation
import NetScopeCore

/// Test RADIUS en démonstration (note 117) : résultats fixes, aucun paquet envoyé.
/// Captures : NETSCOPE_OUTIL_DEMO=radius ouvre l'outil ; NETSCOPE_RADIUS_DEMO=accepte (défaut),
/// refuse, defi, invalide, muet, erreur ou vide choisit le résultat.
enum RADIUSDemo {
    static let server = "10.182.10.20"
    static let username = "test.netscope"

    static var scenario: String { ProcessInfo.processInfo.environment["NETSCOPE_RADIUS_DEMO"] ?? "accepte" }

    static func result() -> RADIUSResult? {
        func make(_ outcome: RADIUSOutcome, attributes: [(String, String)] = [], sent: Int = 1, duration: TimeInterval = 0.042, signed: Bool? = true) -> RADIUSResult {
            RADIUSResult(server: server, address: IPv4Address(10, 182, 10, 20), port: RADIUSRequest.defaultPort, username: username, outcome: outcome,
                         attributes: attributes.enumerated().map { RADIUSAttribute(id: $0.offset, name: $0.element.0, value: $0.element.1) },
                         sent: sent, duration: duration, responseSigned: signed)
        }
        switch scenario {
        case "vide": return nil
        case "refuse":
            return make(.rejected(message: "Compte ou mot de passe incorrect"), attributes: [("Reply-Message", "Compte ou mot de passe incorrect")], signed: false)
        case "defi":
            return make(.challenge(message: "Saisir le code à 6 chiffres"), attributes: [("Reply-Message", "Saisir le code à 6 chiffres"), ("State", "7A3F0C21")])
        case "invalide": return make(.invalidResponse(.responseAuthenticator), signed: nil)
        case "muet": return make(.silent, sent: 3, duration: 9.0, signed: nil)
        case "erreur": return make(.networkError("Port UDP 1812 fermé\u{00A0}: l’appareil répond, mais aucun service RADIUS n’y écoute."), duration: 0.003, signed: nil)
        default:
            return make(.accepted, attributes: [
                ("Service-Type", "Framed (2)"),
                ("Tunnel-Type", "VLAN (13)"),
                ("Tunnel-Medium-Type", "802 (Ethernet) (6)"),
                ("Tunnel-Private-Group-Id", "VLAN 60"),
                ("Filter-Id", "RESEAU-INVITES"),
                ("Session-Timeout", "28800\u{00A0}s"),
                ("Class", "41 octets"),
            ])
        }
    }
}
