import Foundation

// Note 69 : scan de ports UDP ciblé. Un paquet vide ne fait répondre presque aucun service UDP :
// chaque port reçoit une sonde propre à son protocole (UDPProbePayload), et la réponse est lue
// (UDPProbeReader) pour dire ce qui écoute et ce qui est à corriger (UDPFinding).

/// Services UDP sondés, dans l'ordre des ports.
public enum UDPService: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case dns, tftp, ntp, netbios, snmp, ipmi, ssdp, sip, mdns

    /// Services en ordre alphabétique.
    public static var ordered: [UDPService] { allCases.sortedFrench(by: \.label) }

    public var id: String { rawValue }

    /// Port standard.
    public var port: UInt16 {
        switch self {
        case .dns: return 53
        case .tftp: return 69
        case .ntp: return 123
        case .netbios: return 137
        case .snmp: return 161
        case .ipmi: return 623
        case .ssdp: return 1900
        case .sip: return 5060
        case .mdns: return 5353
        }
    }

    /// Nom court de la colonne Service (comme le scan TCP).
    public var serviceName: String {
        switch self {
        case .dns: return "dns"
        case .tftp: return "tftp"
        case .ntp: return "ntp"
        case .netbios: return "netbios-ns"
        case .snmp: return "snmp"
        case .ipmi: return "ipmi"
        case .ssdp: return "ssdp"
        case .sip: return "sip"
        case .mdns: return "mdns"
        }
    }

    /// Libellé du choix des sondes.
    public var label: String {
        switch self {
        case .dns: return "DNS"
        case .tftp: return "TFTP"
        case .ntp: return "NTP"
        case .netbios: return "NetBIOS"
        case .snmp: return "SNMP"
        case .ipmi: return "IPMI (BMC)"
        case .ssdp: return "SSDP (UPnP)"
        case .sip: return "SIP"
        case .mdns: return "mDNS (Bonjour)"
        }
    }

    /// Ce que la sonde envoie (infobulle, journal).
    public var probeDescription: String {
        switch self {
        case .dns: return "requête version.bind (CH TXT) et A localhost"
        case .tftp: return "lecture (RRQ) d’un fichier inexistant, réponse d’erreur attendue"
        case .ntp: return "requête client (mode 3)\u{00A0}; modes 6 et 7 si les tests de sécurité NTP sont cochés"
        case .netbios: return "état du nœud (NBSTAT)"
        case .snmp: return "découverte SNMP v3 (sans secret)\u{00A0}; GetRequest sysDescr en v2c si une communauté est choisie"
        case .ipmi: return "Get Channel Authentication Capabilities (RMCP)"
        case .ssdp: return "M-SEARCH upnp:rootdevice en envoi direct"
        case .sip: return "OPTIONS"
        case .mdns: return "requête directe _services._dns-sd._udp.local"
        }
    }

    /// Le service répond d'un autre port que celui interrogé (TFTP : nouveau port de transfert ;
    /// SSDP : beaucoup d'appareils UPnP répondent d'un port éphémère).
    public var repliesFromOtherPort: Bool { self == .tftp || self == .ssdp }

    public static func forPort(_ port: UInt16) -> UDPService? {
        allCases.first { $0.port == port }
    }
}

/// État d'un port UDP.
public enum UDPPortState: String, Codable, Sendable, Hashable {
    /// Une réponse est arrivée.
    case open
    /// Aucune réponse : service muet, sonde ignorée ou pare-feu (indiscernables en UDP).
    case openFiltered
    /// ICMP « port injoignable » reçu : rien n'écoute.
    case closed
    /// ICMP « hôte ou réseau injoignable, administrativement interdit » : un pare-feu répond.
    case filtered

    public var label: String {
        switch self {
        case .open: return "ouvert"
        case .openFiltered: return "ouvert|filtré"
        case .closed: return "fermé"
        case .filtered: return "filtré"
        }
    }

    /// Ordre de tri : ouverts d'abord.
    public var rank: Int {
        switch self {
        case .open: return 0
        case .openFiltered: return 1
        case .filtered: return 2
        case .closed: return 3
        }
    }

    /// État d'après ce que la socket a vu (pur, testé sans réseau).
    public static func classify(replies: Int, refused: Bool, unreachable: Bool) -> UDPPortState {
        if replies > 0 { return .open }
        if refused { return .closed }
        if unreachable { return .filtered }
        return .openFiltered
    }
}

/// Constat de sécurité tiré d'une réponse.
public struct UDPFinding: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case snmpPublic, snmpV2c, ipmiExposed, ipmiAnonymous, sipExposed, ntpMode6, ntpMode7, tftpOpen
    }

    public enum Severity: String, Codable, Sendable, Comparable {
        case eleve, moyen, faible

        public var label: String {
            switch self {
            case .eleve: return "Élevé"
            case .moyen: return "Moyen"
            case .faible: return "Faible"
            }
        }

        private var order: Int { self == .eleve ? 0 : self == .moyen ? 1 : 2 }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.order < rhs.order }
    }

    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String

    public var id: String { kind.rawValue }

    public init(kind: Kind, severity: Severity, title: String, detail: String) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
    }

    // Textes communs (lecteurs et démonstration).

    public static let snmpPublic = UDPFinding(
        kind: .snmpPublic, severity: .eleve, title: "SNMP «\u{00A0}public\u{00A0}» ouvert",
        detail: "L’agent répond à la communauté par défaut «\u{00A0}public\u{00A0}»\u{00A0}: n’importe qui sur le réseau lit sa configuration (interfaces, ARP, routes). Changer la communauté ou passer en SNMP v3.")
    public static let snmpV2c = UDPFinding(
        kind: .snmpV2c, severity: .faible, title: "SNMP v2c actif",
        detail: "La communauté circule en clair sur le réseau\u{00A0}; préférer SNMP v3 (authentification et chiffrement).")
    public static let ipmiExposed = UDPFinding(
        kind: .ipmiExposed, severity: .eleve, title: "IPMI exposé",
        detail: "Contrôleur de gestion (BMC) joignable en IPMI\u{00A0}: IPMI 2.0 laisse lire le hachage d’un mot de passe à qui connaît un nom d’utilisateur (RAKP). Le réserver à un VLAN d’administration.")
    public static let ipmiAnonymous = UDPFinding(
        kind: .ipmiAnonymous, severity: .eleve, title: "IPMI\u{00A0}: connexion anonyme permise",
        detail: "Le BMC accepte un utilisateur vide ou anonyme\u{00A0}: le désactiver dans la configuration du BMC (iDRAC, iLO, IPMI).")
    public static let sipExposed = UDPFinding(
        kind: .sipExposed, severity: .moyen, title: "SIP exposé",
        detail: "Le service SIP répond à OPTIONS sans authentification\u{00A0}: vérifier qu’il n’est pas joignable depuis Internet (balayages et fraude téléphonique).")
    public static let ntpMode6 = UDPFinding(
        kind: .ntpMode6, severity: .moyen, title: "NTP mode 6 (ntpq) actif",
        detail: "Le serveur NTP répond aux requêtes de contrôle\u{00A0}: version et configuration lisibles à distance, petite amplification possible. Ajouter «\u{00A0}restrict default noquery\u{00A0}».")
    public static let ntpMode7 = UDPFinding(
        kind: .ntpMode7, severity: .eleve, title: "NTP mode 7 (monlist) actif",
        detail: "Le serveur NTP répond aux requêtes privées (ntpdc)\u{00A0}: monlist sert aux attaques par amplification (CVE-2013-5211). Mettre ntpd à jour ou ajouter «\u{00A0}disable monitor\u{00A0}».")
    public static let tftpOpen = UDPFinding(
        kind: .tftpOpen, severity: .faible, title: "Serveur TFTP joignable",
        detail: "TFTP n’a ni mot de passe ni chiffrement\u{00A0}: tout fichier dont on devine le nom (configurations, firmwares) se lit. À n’ouvrir que le temps d’un transfert.")
}

/// Réponse lue par UDPProbeReader.
public struct UDPReading: Hashable, Sendable {
    /// Résumé d'une ligne (« BIND 9.18.24 », « strate 2 · réf. 10.0.0.1 »).
    public var summary: String
    public var details: [String]
    public var findings: [UDPFinding]
    /// Faux si la réponse n'a pas été reconnue (le port reste ouvert).
    public var recognized: Bool

    public init(summary: String, details: [String] = [], findings: [UDPFinding] = [], recognized: Bool = true) {
        self.summary = summary
        self.details = details
        self.findings = findings
        self.recognized = recognized
    }
}

/// Résultat d'un port UDP.
public struct UDPProbeResult: Identifiable, Hashable, Sendable, Codable {
    public var service: UDPService
    public var port: UInt16
    public var state: UDPPortState
    /// Délai de la première réponse.
    public var rttMs: Double?
    public var summary: String?
    public var details: [String]
    public var findings: [UDPFinding]
    /// Octets reçus en tout.
    public var responseBytes: Int

    public var id: UInt16 { port }

    public init(service: UDPService, port: UInt16? = nil, state: UDPPortState, rttMs: Double? = nil, summary: String? = nil,
                details: [String] = [], findings: [UDPFinding] = [], responseBytes: Int = 0) {
        self.service = service
        self.port = port ?? service.port
        self.state = state
        self.rttMs = rttMs
        self.summary = summary
        self.details = details
        self.findings = findings
        self.responseBytes = responseBytes
    }
}

/// Bilan d'un scan UDP ciblé.
public struct UDPScanSummary: Sendable, Hashable {
    public var host: String
    public var results: [UDPProbeResult]
    public var duration: TimeInterval
    public var wasCancelled: Bool
    public var date: Date

    public init(host: String, results: [UDPProbeResult], duration: TimeInterval, wasCancelled: Bool = false, date: Date = Date()) {
        self.host = host
        self.results = results.sorted { $0.port < $1.port }
        self.duration = duration
        self.wasCancelled = wasCancelled
        self.date = date
    }

    public var open: [UDPProbeResult] { results.filter { $0.state == .open } }

    public func count(_ state: UDPPortState) -> Int { results.filter { $0.state == state }.count }

    /// Constats de tous les ports, les plus graves d'abord (sans doublon).
    public var findings: [UDPFinding] {
        var seen = Set<UDPFinding.Kind>()
        return results.flatMap(\.findings).filter { seen.insert($0.kind).inserted }
            .sorted { ($0.severity, $0.kind.rawValue) < ($1.severity, $1.kind.rawValue) }
    }

    /// « 3 ouverts, 4 ouverts|filtrés, 2 fermés ».
    public var summary: String {
        let open = count(.open)
        var parts = [open <= 1 ? "\(open) ouvert" : "\(open) ouverts"]
        let silent = count(.openFiltered)
        if silent > 0 { parts.append(silent == 1 ? "1 ouvert|filtré" : "\(silent) ouverts|filtrés") }
        let filtered = count(.filtered)
        if filtered > 0 { parts.append(filtered == 1 ? "1 filtré" : "\(filtered) filtrés") }
        let closed = count(.closed)
        if closed > 0 { parts.append(closed == 1 ? "1 fermé" : "\(closed) fermés") }
        return parts.joined(separator: ", ")
    }

    /// Export CSV (séparateur « ; »).
    public var csv: String {
        func clean(_ text: String) -> String { text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ") }
        let lines = results.map { result in
            [String(result.port), "udp", result.state.label, result.service.serviceName, clean(result.summary ?? ""),
             result.rttMs.map { String(format: "%.1f", $0) } ?? "", clean(result.findings.map(\.title).joined(separator: ", "))]
                .joined(separator: ";")
        }
        return (["port;proto;etat;service;reponse;delai_ms;constats"] + lines).joined(separator: "\n")
    }
}

/// Réglages d'un scan UDP ciblé.
public struct UDPProbeOptions: Sendable, Hashable {
    /// Attente d'une réponse après chaque envoi.
    public var timeout: TimeInterval
    /// Envois par port (UDP perd des paquets : deux essais par défaut).
    public var attempts: Int
    /// Communauté SNMP v2c à essayer (nil : découverte v3 seulement, aucun secret envoyé).
    public var snmpCommunity: String?
    /// Requêtes NTP de contrôle (mode 6) et privées (mode 7, monlist).
    public var ntpControlChecks: Bool
    /// Ports sondés en même temps (peu : les hôtes limitent leurs messages ICMP).
    public var concurrency: Int

    public init(timeout: TimeInterval = 1.5, attempts: Int = 2, snmpCommunity: String? = nil,
                ntpControlChecks: Bool = true, concurrency: Int = 3) {
        self.timeout = timeout
        self.attempts = attempts
        self.snmpCommunity = snmpCommunity
        self.ntpControlChecks = ntpControlChecks
        self.concurrency = concurrency
    }
}

// MARK: - Communauté du site

/// Communauté SNMP v2c générale du site (secret du Trousseau, envoyée en clair) : jamais à un
/// hôte hors du réseau. Elle ne part que vers une adresse privée (RFC 1918) ou une adresse des
/// plages du site actif ; ailleurs, la sonde SNMP se limite à la découverte v3.
public enum UDPCommunityPolicy {
    public static let withheldNote = "communauté non envoyée\u{00A0}: hôte hors des plages du site, SNMP v3 seulement"

    public static func maySendSiteCommunity(to address: IPv4Address, siteRanges: [String]) -> Bool {
        if AddressScope.of(address) == .privee { return true }
        return siteRanges.contains { text in (try? IPRange(parsing: text))?.contains(address) ?? false }
    }
}
