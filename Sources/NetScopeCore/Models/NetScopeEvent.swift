import Foundation

// Événements de NetScope sous une forme commune (type, gravité, titre, détail, date, lien
// interne), publiés par tous les émetteurs (Surveillance, État des services, Inventaire, Test DHCP,
// Mises à jour, Scanner) dans `NetScopeEventCenter`. Les canaux s'y abonnent : notifications macOS
// (décision par `NotificationPolicy`), et les canaux ajoutés plus tard (courriel, webhook…).

/// Type d'événement, dans l'ordre de la liste de Réglages › Notifications.
public enum NetScopeEventKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Sonde de surveillance hors ligne (N échecs consécutifs).
    case probeDown
    /// Sonde en alerte : latence, perte ou condition du type au-delà du seuil.
    case probeWarning
    /// Sonde revenue à la normale après une panne ou une alerte.
    case probeRecovered
    /// Nouvel appareil (MAC jamais vue) sur une plage suivie par une sonde « Nouveaux appareils ».
    case newDevice
    /// Appareil vu sur un autre switch ou port que prévu (sonde « Port de switch »).
    case deviceMoved
    /// Deux adresses MAC pour une même IP (Inventaire).
    case ipConflict
    /// Offre DHCP d'un serveur hors de la liste autorisée (Test DHCP).
    case rogueDHCP
    /// Nouvel incident d'un service en ligne (page d'état), ou service injoignable d'ici.
    case serviceIncident
    /// Nouvelle version de NetScope trouvée par la vérification automatique.
    case updateAvailable
    /// Fin d'un scan.
    case scanFinished
    /// Rapport planifié produit (note 42), ou en échec.
    case reportReady
    /// Note 78 (0.26.0) : événements dédiés au lieu d'un « sonde en panne » générique.
    /// Licence FortiGuard ou FortiCare bientôt expirée (sonde « Licence »).
    case licenseExpiring
    /// Firmware à mettre à jour (sonde « Firmware »).
    case firmwareOutdated
    /// Message Syslog (ou de la FortiGate) grave (sonde « Syslog »).
    case syslogSevere
    /// Lien WAN ou tunnel VPN en panne (sondes « WAN » et « VPN »).
    case wanDown
    /// Cible du ping continu hors ligne (3 pertes consécutives).
    case pingTargetDown
    /// Cible du ping continu revenue en ligne.
    case pingTargetUp
    /// Notification de test (Réglages › Notifications).
    case test

    public var id: String { rawValue }

    /// Types proposés dans les réglages (la notification de test n'en fait pas partie).
    public static var configurable: [NetScopeEventKind] { allCases.filter { $0 != .test } }

    /// Libellé de la liste des réglages.
    public var label: String {
        switch self {
        case .probeDown: return "Sonde en panne"
        case .probeWarning: return "Sonde en alerte"
        case .probeRecovered: return "Sonde rétablie"
        case .newDevice: return "Nouvel appareil sur une plage surveillée"
        case .deviceMoved: return "Appareil déplacé sur un autre port"
        case .ipConflict: return "Conflit d’adresse IP"
        case .rogueDHCP: return "Serveur DHCP non autorisé"
        case .serviceIncident: return "Nouvel incident d’un service en ligne"
        case .updateAvailable: return "Mise à jour disponible"
        case .scanFinished: return "Fin de scan"
        case .reportReady: return "Rapport planifié produit"
        case .licenseExpiring: return "Licence bientôt expirée"
        case .firmwareOutdated: return "Firmware à mettre à jour"
        case .syslogSevere: return "Message Syslog grave"
        case .wanDown: return "WAN en panne"
        case .pingTargetDown: return "Cible du ping continu hors ligne"
        case .pingTargetUp: return "Cible du ping continu rétablie"
        case .test: return "Notification de test"
        }
    }

    /// Explication courte (sous le libellé).
    public var explanation: String {
        switch self {
        case .probeDown: return "Après le nombre d’échecs consécutifs réglé sur chaque sonde (Surveillance)."
        case .probeWarning: return "Latence, perte ou seuil dépassé, réglés sonde par sonde."
        case .probeRecovered: return "Retour à la normale d’une sonde qui était en panne ou en alerte."
        case .newDevice: return "MAC jamais vue sur une plage suivie par une sonde « Nouveaux appareils »."
        case .deviceMoved: return "Sonde « Port de switch »\u{00A0}: appareil vu sur un autre switch ou port."
        case .ipConflict: return "Deux adresses MAC pour une même IP, relevé par l’Inventaire après un scan."
        case .rogueDHCP: return "Offre reçue d’un serveur hors de la liste autorisée (Test DHCP)."
        case .serviceIncident: return "Panne, incident ou maintenance d’une page d’état, ou service injoignable d’ici."
        case .updateAvailable: return "Nouvelle version de NetScope trouvée par la vérification automatique."
        case .scanFinished: return "Seulement quand NetScope n’est pas au premier plan."
        case .reportReady: return "Fin d’un rapport planifié (Rapports), avec son dossier\u{00A0}; rien n’est envoyé par courriel."
        case .licenseExpiring: return "Sonde «\u{00A0}Licence\u{00A0}»\u{00A0}: FortiGuard ou FortiCare à renouveler dans le délai réglé."
        case .firmwareOutdated: return "Sonde «\u{00A0}Firmware\u{00A0}»\u{00A0}: une version plus récente est publiée."
        case .syslogSevere: return "Sonde «\u{00A0}Syslog\u{00A0}»\u{00A0}: message reçu de gravité égale ou supérieure au seuil."
        case .wanDown: return "Sondes «\u{00A0}WAN\u{00A0}» et «\u{00A0}VPN\u{00A0}»\u{00A0}: lien Internet ou tunnel tombé."
        case .pingTargetDown: return "Ping continu\u{00A0}: 3 paquets perdus de suite sur une cible."
        case .pingTargetUp: return "Ping continu\u{00A0}: retour en ligne d’une cible tombée."
        case .test: return "Envoyée depuis Réglages › Notifications."
        }
    }

    /// Gravité habituelle des événements de ce type.
    public var defaultSeverity: NetScopeEventSeverity {
        switch self {
        case .probeDown, .ipConflict, .rogueDHCP, .wanDown, .pingTargetDown: return .critical
        case .probeWarning, .serviceIncident, .licenseExpiring, .firmwareOutdated, .syslogSevere: return .warning
        case .probeRecovered, .pingTargetUp: return .success
        case .newDevice, .deviceMoved, .updateAvailable, .scanFinished, .reportReady, .test: return .info
        }
    }

    /// Types ajoutés après la première version des réglages : absents d'un fichier enregistré avant
    /// eux, ils prennent leur valeur par défaut au lieu d'être pris pour désactivés.
    public static let introducedLater: Set<NetScopeEventKind> = [.reportReady, .licenseExpiring, .firmwareOutdated,
                                                                  .syslogSevere, .wanDown, .pingTargetDown, .pingTargetUp]

    /// Activé tant que l'utilisateur n'a rien changé.
    public var enabledByDefault: Bool {
        switch self {
        case .deviceMoved, .scanFinished: return false
        default: return true
        }
    }
}

/// Gravité d'un événement, de la moins à la plus grave.
public enum NetScopeEventSeverity: String, Codable, CaseIterable, Sendable, Comparable {
    case info, success, warning, critical

    /// Étiquette en majuscules (« CRITIQUE »).
    public var tag: String {
        switch self {
        case .info: return "INFO"
        case .success: return "RÉTABLI"
        case .warning: return "ALERTE"
        case .critical: return "CRITIQUE"
        }
    }

    private var rank: Int {
        switch self {
        case .info: return 0
        case .success: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: NetScopeEventSeverity, rhs: NetScopeEventSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// Lien interne : ce qu'ouvre un clic sur la notification (ou le lien d'un courriel, d'un webhook).
public enum NetScopeEventLink: Codable, Hashable, Sendable {
    /// Rien de particulier : la fenêtre principale.
    case none
    /// Sonde de surveillance.
    case probe(UUID)
    /// Service en ligne (identifiant du catalogue de l'outil « État des services »).
    case service(String)
    /// Appareil, par son adresse IP.
    case device(String)
    /// Écran de l'application (`Screen.rawValue` : « analyse », « outils »…).
    case screen(String)
    /// Réglages › Mises à jour.
    case updates

    /// Forme texte stable (« netscope://sonde/… »), lisible par un autre canal.
    public var url: String {
        switch self {
        case .none: return "netscope://"
        case .probe(let id): return "netscope://sonde/\(id.uuidString)"
        case .service(let id): return "netscope://service/\(id)"
        case .device(let ip): return "netscope://appareil/\(ip)"
        case .screen(let screen): return "netscope://ecran/\(screen)"
        case .updates: return "netscope://mises-a-jour"
        }
    }

    /// Relit la forme texte (`url`) ; nil si elle n'est pas reconnue.
    public init?(url text: String) {
        let prefix = "netscope://"
        guard text.hasPrefix(prefix) else { return nil }
        let path = String(text.dropFirst(prefix.count))
        if path.isEmpty { self = .none; return }
        if path == "mises-a-jour" { self = .updates; return }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "sonde":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .probe(id)
        case "service": self = .service(parts[1])
        case "appareil": self = .device(parts[1])
        case "ecran": self = .screen(parts[1])
        default: return nil
        }
    }
}

/// Un événement à signaler.
public struct NetScopeEvent: Codable, Hashable, Identifiable, Sendable {
    /// Identifiant stable : deux publications du même fait gardent le même (la notification est remplacée).
    public var id: String
    public var kind: NetScopeEventKind
    public var severity: NetScopeEventSeverity
    /// Titre court (« Imprimante 2e étage hors ligne »).
    public var title: String
    /// Détail (« 10.182.122.40 ne répond plus depuis 3 tentatives. »).
    public var detail: String
    public var date: Date
    public var link: NetScopeEventLink
    /// Source qui regroupe les événements d'une même chose (sonde, service) : fil des notifications.
    public var source: String?
    /// Réglage propre à la source (sonde : « Notification macOS ») ; faux : pas de bannière.
    public var sourceAllowsBanner: Bool
    /// Réglage propre à la source (sonde : « Son ») ; vrai : son demandé même hors événements critiques.
    public var sourceRequestsSound: Bool

    public init(id: String = UUID().uuidString, kind: NetScopeEventKind, severity: NetScopeEventSeverity? = nil,
                title: String, detail: String, date: Date = Date(), link: NetScopeEventLink = .none,
                source: String? = nil, sourceAllowsBanner: Bool = true, sourceRequestsSound: Bool = false) {
        self.id = id
        self.kind = kind
        self.severity = severity ?? kind.defaultSeverity
        self.title = title
        self.detail = detail
        self.date = date
        self.link = link
        self.source = source
        self.sourceAllowsBanner = sourceAllowsBanner
        self.sourceRequestsSound = sourceRequestsSound
    }
}

/// Point de publication des événements. Les émetteurs appellent `publish` ; chaque canal
/// s'abonne une fois sous un nom (`subscribe("notifications-macos") { … }`). Un abonné qui se
/// réinscrit sous le même nom remplace le précédent.
@MainActor
public final class NetScopeEventCenter {
    public static let shared = NetScopeEventCenter()

    public typealias Handler = @MainActor (NetScopeEvent) -> Void

    private var subscribers: [(name: String, handler: Handler)] = []
    /// Derniers événements publiés, du plus récent au plus ancien (au plus `recentLimit`).
    public private(set) var recent: [NetScopeEvent] = []
    public var recentLimit = 50

    public init() {}

    public func subscribe(_ name: String, handler: @escaping Handler) {
        subscribers.removeAll { $0.name == name }
        subscribers.append((name, handler))
    }

    public func unsubscribe(_ name: String) {
        subscribers.removeAll { $0.name == name }
    }

    public var subscriberNames: [String] { subscribers.map(\.name) }

    public func publish(_ event: NetScopeEvent) {
        recent.insert(event, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        for subscriber in subscribers { subscriber.handler(event) }
    }
}
