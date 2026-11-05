import Foundation

/// Ports de RustDesk (note 6) : serveur auto-hébergé (hbbs et hbbr) et accès IP direct d'un client.
///
/// - TCP 21115 : hbbs, test du type de NAT ;
/// - TCP 21116 : hbbs, ID et enregistrement des postes (et UDP 21116 : battement de cœur, percée NAT) ;
/// - TCP 21117 : hbbr, relais des sessions ;
/// - TCP 21118 : hbbs, WebSocket (client web) ; sur un poste, accès IP direct quand « Activer
///   l'accès IP direct » est coché dans le client RustDesk ;
/// - TCP 21119 : hbbr, WebSocket du relais.
///
/// Tout est pur (aucun trafic) sauf `PortScanner`, appelé par l'interface seulement sur clic.
public enum RustDeskPorts {
    public static let natTest: UInt16 = 21115
    public static let id: UInt16 = 21116
    public static let relay: UInt16 = 21117
    public static let direct: UInt16 = 21118
    public static let relayWebSocket: UInt16 = 21119

    /// Ports TCP de RustDesk, dans l'ordre.
    public static let tcpPorts: [UInt16] = [21115, 21116, 21117, 21118, 21119]
    /// Ports UDP de RustDesk (hbbs) : jamais vérifiés par un scan TCP.
    public static let udpPorts: [UInt16] = [21116]
    /// Ports ajoutés aux ports vérifiés à chaque scan : 21116 (serveur) et 21118 (accès IP direct).
    public static let quickScanPorts: [UInt16] = [21116, 21118]

    public static func isRustDeskPort(_ port: UInt16) -> Bool { tcpPorts.contains(port) }

    // MARK: Catalogue

    /// Rôle d'un port RustDesk.
    public struct PortInfo: Hashable, Sendable {
        public var port: UInt16
        /// « hbbs », « hbbr » ou « hbbs / client ».
        public var component: String
        /// Nom court (pastilles, colonne Service) : « rustdesk-id ».
        public var service: String
        /// Rôle en clair : « ID et enregistrement des postes ».
        public var role: String
    }

    public static func info(_ port: UInt16) -> PortInfo? {
        switch port {
        case 21115: return PortInfo(port: port, component: "hbbs", service: "rustdesk-nat", role: "test du type de NAT")
        case 21116: return PortInfo(port: port, component: "hbbs", service: "rustdesk-id", role: "ID et enregistrement des postes")
        case 21117: return PortInfo(port: port, component: "hbbr", service: "rustdesk-relais", role: "relais des sessions")
        case 21118: return PortInfo(port: port, component: "hbbs / client", service: "rustdesk-direct",
                                    role: "WebSocket du serveur, ou accès IP direct d’un poste")
        case 21119: return PortInfo(port: port, component: "hbbr", service: "rustdesk-ws", role: "WebSocket du relais")
        default: return nil
        }
    }

    /// Nom d'un port UDP de RustDesk (21116/udp).
    public static func udpServiceName(_ port: UInt16) -> String? {
        port == 21116 ? "rustdesk-hb" : nil
    }

    /// Libellé du bouton de port (« RustDesk 21116 »).
    public static func buttonLabel(_ port: UInt16) -> String { "RustDesk \(port)" }

    /// Infobulle d'un port ouvert, selon le rôle reconnu de l'appareil.
    public static func help(port: UInt16, role: Role?) -> String {
        guard let info = info(port) else { return "" }
        var lines: [String]
        if port == direct, case .client? = role {
            lines = ["TCP 21118 (client RustDesk)\u{00A0}: accès IP direct activé sur ce poste.",
                     "Clic\u{00A0}: ouvrir une session RustDesk directe, sans serveur ni relais."]
        } else {
            lines = ["TCP \(port) (\(info.component))\u{00A0}: \(info.role)."]
            if port == id {
                lines.append("UDP 21116 (battement de cœur et percée NAT) n’est pas vérifié par un scan TCP.")
            }
            lines.append("Clic\u{00A0}: rôle des ports et « Tester le serveur RustDesk ».")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Reconnaissance

    /// Rôle RustDesk d'un appareil d'après ses ports TCP ouverts.
    public enum Role: Hashable, Sendable {
        /// Serveur hbbs (avec ou sans relais sur le même hôte). `confirmed` : 21116 avec 21115 ou 21117 ;
        /// sinon 21116 seul (ou avec le WebSocket 21118), à confirmer par « Tester le serveur RustDesk ».
        case server(confirmed: Bool)
        /// Relais hbbr seul (21117 sans 21116).
        case relay
        /// Poste avec l'accès IP direct (21118 seul, sans aucun port du serveur).
        case client

        public var label: String {
            switch self {
            case .server: return "Serveur RustDesk"
            case .relay: return "Relais RustDesk (hbbr)"
            case .client: return "Client RustDesk (accès IP direct)"
            }
        }

        public var isServer: Bool {
            switch self {
            case .server, .relay: return true
            case .client: return false
            }
        }

        /// Constat de la fiche Appareil.
        public var finding: String {
            switch self {
            case .server(confirmed: true):
                return "Les ports de hbbs (ID 21116) et du test NAT ou du relais répondent. Les clients RustDesk "
                    + "s’enregistrent ici avec la clé publique du serveur."
            case .server(confirmed: false):
                return "Le port 21116 (ID et enregistrement) répond, mais 21115 et 21117 n’ont pas été vérifiés. "
                    + "« Tester le serveur RustDesk » confirme le relais et le test NAT."
            case .relay:
                return "Le relais hbbr (21117) répond sans le serveur d’ID (21116)\u{00A0}: hbbs tourne sur une autre machine."
            case .client:
                return "Le port 21118 répond seul\u{00A0}: « Activer l’accès IP direct » est coché dans RustDesk. "
                    + "Une session directe est possible sans passer par le serveur ; à réserver au réseau local ou au VPN."
            }
        }
    }

    public static func role(openPorts: [UInt16]) -> Role? {
        let open = Set(openPorts)
        if open.contains(id) {
            return .server(confirmed: open.contains(natTest) || open.contains(relay))
        }
        if open.contains(relay) { return .relay }
        if open.contains(direct), open.isDisjoint(with: [natTest, relay, relayWebSocket]) { return .client }
        return nil
    }

    // MARK: Ouvrir dans RustDesk

    /// URL d'une session directe : « rustdesk://connection/new/10.0.0.5 » (port 21118 implicite),
    /// « rustdesk://connection/new/10.0.0.5:21200 » sinon. L'ID d'un accès IP direct est l'adresse
    /// du poste ; la forme `connection/new/<id>` est reconnue par toutes les versions du client.
    public static func directURL(host: String, port: UInt16 = direct) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        let target = port == direct ? trimmed : "\(trimmed):\(port)"
        return URL(string: "rustdesk://connection/new/\(target)")
    }

    // MARK: Test du serveur

    /// Ports vérifiés par « Tester le serveur RustDesk ».
    public static let serverTestPorts: [UInt16] = tcpPorts

    /// Bilan d'un test du serveur (connexions TCP sur 21115 à 21119).
    public struct ServerReport: Sendable, Equatable {
        public enum Verdict: Sendable, Equatable {
            /// ID et relais répondent.
            case ok
            /// ID répond, relais absent : les sessions qui ne passent pas en direct échoueront.
            case noRelay
            /// Relais seul.
            case relayOnly
            /// Ni ID ni relais.
            case unreachable
        }

        public struct Line: Sendable, Equatable, Identifiable {
            public var port: UInt16
            public var state: PortState
            public var rttMs: Double?
            public var id: UInt16 { port }
            /// « hbbs · ID et enregistrement des postes ».
            public var detail: String {
                guard let info = RustDeskPorts.info(port) else { return "" }
                return "\(info.component) · \(info.role)"
            }
            /// Ports facultatifs (WebSocket) : leur absence n'est pas une erreur.
            public var isOptional: Bool { port == RustDeskPorts.direct || port == RustDeskPorts.relayWebSocket }
        }

        public var lines: [Line]

        public init(results: [PortScanResult]) {
            let byPort = Dictionary(results.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
            lines = RustDeskPorts.serverTestPorts.map { port in
                let result = byPort[port]
                return Line(port: port, state: result?.state ?? .filtered, rttMs: result?.rttMs)
            }
        }

        func isOpen(_ port: UInt16) -> Bool { lines.first { $0.port == port }?.state == .open }

        public var verdict: Verdict {
            switch (isOpen(RustDeskPorts.id), isOpen(RustDeskPorts.relay)) {
            case (true, true): return .ok
            case (true, false): return .noRelay
            case (false, true): return .relayOnly
            case (false, false): return .unreachable
            }
        }

        public var title: String {
            switch verdict {
            case .ok: return "Serveur RustDesk joignable"
            case .noRelay: return "Relais injoignable"
            case .relayOnly: return "Serveur d’ID injoignable"
            case .unreachable: return "Serveur RustDesk injoignable"
            }
        }

        public var message: String {
            var text: String
            switch verdict {
            case .ok:
                text = "hbbs (21116) et hbbr (21117) acceptent les connexions TCP."
                if !isOpen(RustDeskPorts.natTest) { text += " Le test NAT (21115) ne répond pas\u{00A0}: le type de NAT des clients sera mal détecté." }
            case .noRelay:
                text = "hbbs répond, mais le relais 21117 non\u{00A0}: les sessions qui ne passent pas en direct échoueront."
            case .relayOnly:
                text = "Seul le relais 21117 répond\u{00A0}: hbbs est arrêté ou sur une autre machine."
            case .unreachable:
                text = "Ni 21116 ni 21117 ne répondent\u{00A0}: service arrêté, pare-feu ou mauvaise adresse."
            }
            return text + " UDP 21116 n’est pas vérifié (TCP seulement)."
        }
    }
}
