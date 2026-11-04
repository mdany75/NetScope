import Foundation

// Note 39 : état du WAN de chaque FortiGate. Modèle de la lecture (interfaces WAN, mesures des
// sondes SD-WAN, configuration des SLA, tunnels VPN IPsec, utilisateurs VPN SSL) et seuils. Tout
// est lu par l'API REST de FortiOS en lecture seule (GET) ; rien ici n'accède au réseau.

/// Interface WAN de la FortiGate (rôle « wan », membre SD-WAN ou nom « wanN »), avec son état.
public struct WANInterfaceStatus: Codable, Hashable, Sendable, Identifiable {
    /// Nom de l'interface (« wan1 », « port2 », « wan1.300 »).
    public var name: String
    /// Nom donné sur la FortiGate (« Bell Fibre »).
    public var alias: String?
    /// Rôle (« wan », « lan », « dmz », « undefined »), si la configuration a été lue.
    public var role: String?
    /// Type (« physical », « vlan », « aggregate », « tunnel »…), si connu.
    public var type: String?
    /// Adressage (« static », « dhcp », « pppoe »).
    public var mode: String?
    /// Interface activée par l'administrateur (configuration) ; nil si inconnu.
    public var adminUp: Bool?
    /// Lien physique actif (état) ; nil si inconnu.
    public var linkUp: Bool?
    public var speedMbps: UInt64?
    public var ip: IPv4Address?
    public var prefix: Int?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var rxErrors: UInt64?
    public var txErrors: UInt64?
    /// Débit mesuré, en bits par seconde (SD-WAN, sinon calculé entre deux lectures).
    public var rxBps: Double?
    public var txBps: Double?
    /// Bande passante estimée de l'abonnement, en kb/s (configuration).
    public var estimatedDownKbps: Int?
    public var estimatedUpKbps: Int?
    /// Passerelle du membre SD-WAN.
    public var gateway: IPv4Address?
    /// Zone SD-WAN (« virtual-wan-link », « underlay »), si l'interface est membre.
    public var sdwanZone: String?
    public var isSDWANMember: Bool
    /// Sessions sur ce membre SD-WAN.
    public var sessions: Int?
    /// Dernier changement d'état du membre SD-WAN.
    public var stateChanged: Date?

    public init(name: String, alias: String? = nil, role: String? = nil, type: String? = nil, mode: String? = nil,
                adminUp: Bool? = nil, linkUp: Bool? = nil, speedMbps: UInt64? = nil, ip: IPv4Address? = nil, prefix: Int? = nil,
                rxBytes: UInt64? = nil, txBytes: UInt64? = nil, rxErrors: UInt64? = nil, txErrors: UInt64? = nil,
                rxBps: Double? = nil, txBps: Double? = nil, estimatedDownKbps: Int? = nil, estimatedUpKbps: Int? = nil,
                gateway: IPv4Address? = nil, sdwanZone: String? = nil, isSDWANMember: Bool = false, sessions: Int? = nil,
                stateChanged: Date? = nil) {
        self.name = name
        self.alias = alias
        self.role = role
        self.type = type
        self.mode = mode
        self.adminUp = adminUp
        self.linkUp = linkUp
        self.speedMbps = speedMbps
        self.ip = ip
        self.prefix = prefix
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxErrors = rxErrors
        self.txErrors = txErrors
        self.rxBps = rxBps
        self.txBps = txBps
        self.estimatedDownKbps = estimatedDownKbps
        self.estimatedUpKbps = estimatedUpKbps
        self.gateway = gateway
        self.sdwanZone = sdwanZone
        self.isSDWANMember = isSDWANMember
        self.sessions = sessions
        self.stateChanged = stateChanged
    }

    public var id: String { name }

    /// « Bell Fibre (wan1) », ou « wan1 ».
    public var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty, alias.lowercased() != name.lowercased() {
            return "\(alias) (\(name))"
        }
        return name
    }

    /// Nom court pour une phrase d'alerte : l'alias, sinon le nom.
    public var shortName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty { return alias }
        return name
    }

    /// « 203.0.113.10/29 », « — ».
    public var addressLabel: String {
        guard let ip else { return "—" }
        return prefix.map { "\(ip)/\($0)" } ?? ip.description
    }
}

/// Mesure d'une sonde SD-WAN (health-check) sur un membre : latence, gigue, perte, SLA.
public struct WANHealthMeasure: Codable, Hashable, Sendable, Identifiable {
    /// Nom de la sonde (« Google_DNS », « Default_Office_365 »).
    public var checkName: String
    /// Interface membre (« wan1 »).
    public var interface: String
    /// « up », « down », « error » (le membre ne participe pas), « disable ».
    public var status: String?
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    public var packetsSent: Int?
    public var packetsReceived: Int?
    /// Identifiants des SLA respectés (« sla_targets_met »), nil si la version ne les donne pas.
    public var slaTargetsMet: [Int]?
    public var stateChanged: Date?
    /// Débit du membre vu par la sonde, en bits par seconde.
    public var rxBps: Double?
    public var txBps: Double?
    public var sessions: Int?

    public init(checkName: String, interface: String, status: String? = nil, latencyMs: Double? = nil, jitterMs: Double? = nil,
                lossPercent: Double? = nil, packetsSent: Int? = nil, packetsReceived: Int? = nil, slaTargetsMet: [Int]? = nil,
                stateChanged: Date? = nil, rxBps: Double? = nil, txBps: Double? = nil, sessions: Int? = nil) {
        self.checkName = checkName
        self.interface = interface
        self.status = status
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.slaTargetsMet = slaTargetsMet
        self.stateChanged = stateChanged
        self.rxBps = rxBps
        self.txBps = txBps
        self.sessions = sessions
    }

    public var id: String { "\(checkName)|\(interface)" }

    /// Vrai : la sonde répond ; faux : elle ne répond plus ; nil : le membre ne participe pas
    /// (« error », « disable ») ou état illisible.
    public var isUp: Bool? {
        switch status?.lowercased() {
        case "up", "alive", "ok": return true
        case "down", "dead": return false
        default: return nil
        }
    }

    /// Le membre participe à cette sonde (ni « error » ni « disable »).
    public var participates: Bool { isUp != nil }
}

/// Objectif de SLA d'une sonde SD-WAN (seuils configurés sur la FortiGate).
public struct WANSLATarget: Codable, Hashable, Sendable {
    public var id: Int
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?

    public init(id: Int, latencyMs: Double? = nil, jitterMs: Double? = nil, lossPercent: Double? = nil) {
        self.id = id
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
    }

    /// « latence ≤ 100 ms, gigue ≤ 30 ms, perte ≤ 2 % ».
    public var label: String {
        var parts: [String] = []
        if let latencyMs { parts.append("latence ≤ \(MonFormat.number(latencyMs))\u{00A0}ms") }
        if let jitterMs { parts.append("gigue ≤ \(MonFormat.number(jitterMs))\u{00A0}ms") }
        if let lossPercent { parts.append("perte ≤ \(MonFormat.percent(lossPercent))") }
        return parts.isEmpty ? "SLA \(id)" : parts.joined(separator: ", ")
    }
}

/// Sonde SD-WAN configurée (cmdb system/sdwan, ou system/virtual-wan-link en 6.4).
public struct WANHealthCheckConfig: Codable, Hashable, Sendable {
    public var name: String
    /// Serveurs interrogés (« 8.8.8.8 », « www.office.com »).
    public var servers: [String]
    /// « ping », « http », « dns », « tcp-echo »…
    public var proto: String?
    /// Interfaces membres de la sonde (vide : tous les membres).
    public var members: [String]
    public var sla: [WANSLATarget]

    public init(name: String, servers: [String] = [], proto: String? = nil, members: [String] = [], sla: [WANSLATarget] = []) {
        self.name = name
        self.servers = servers
        self.proto = proto
        self.members = members
        self.sla = sla
    }
}

/// Phase 2 (sélecteur) d'un tunnel IPsec.
public struct WANPhase2: Codable, Hashable, Sendable {
    public var name: String
    /// « up », « down ».
    public var status: String?
    /// Réseaux protégés (« 10.182.0.0/16 »).
    public var source: String?
    public var destination: String?
    public var incomingBytes: UInt64?
    public var outgoingBytes: UInt64?
    /// Secondes avant la renégociation de la clé.
    public var expiresIn: Int?

    public init(name: String, status: String? = nil, source: String? = nil, destination: String? = nil,
                incomingBytes: UInt64? = nil, outgoingBytes: UInt64? = nil, expiresIn: Int? = nil) {
        self.name = name
        self.status = status
        self.source = source
        self.destination = destination
        self.incomingBytes = incomingBytes
        self.outgoingBytes = outgoingBytes
        self.expiresIn = expiresIn
    }

    public var isUp: Bool { status?.lowercased() == "up" }
}

/// État d'un tunnel IPsec.
public enum WANTunnelState: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Serveur d'accès distant (« dialup ») sans client connecté : normal, pas une panne.
    case idle
    case up
    /// Une partie des phases 2 seulement est montée.
    case partial
    case down

    public static func < (a: WANTunnelState, b: WANTunnelState) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .idle: return "En attente"
        case .up: return "Monté"
        case .partial: return "Partiel"
        case .down: return "Tombé"
        }
    }
}

/// Tunnel VPN IPsec (monitor/vpn/ipsec).
public struct WANTunnel: Codable, Hashable, Sendable, Identifiable {
    /// Nom de la phase 1 (« VPN-QUEBEC »).
    public var name: String
    /// Passerelle distante (« 203.0.113.30 »).
    public var remoteGateway: String?
    /// « automatic », « manual », « dialup ».
    public var type: String?
    /// Tunnel parent d'une instance d'accès distant (« dialup »).
    public var parent: String?
    public var comments: String?
    /// État donné directement par la version (« up », « down »), quand il existe.
    public var status: String?
    public var connectionCount: Int?
    public var incomingBytes: UInt64?
    public var outgoingBytes: UInt64?
    /// Dernière montée du tunnel (« creation_time »).
    public var upSince: Date?
    public var phase2: [WANPhase2]

    public init(name: String, remoteGateway: String? = nil, type: String? = nil, parent: String? = nil, comments: String? = nil,
                status: String? = nil, connectionCount: Int? = nil, incomingBytes: UInt64? = nil, outgoingBytes: UInt64? = nil,
                upSince: Date? = nil, phase2: [WANPhase2] = []) {
        self.name = name
        self.remoteGateway = remoteGateway
        self.type = type
        self.parent = parent
        self.comments = comments
        self.status = status
        self.connectionCount = connectionCount
        self.incomingBytes = incomingBytes
        self.outgoingBytes = outgoingBytes
        self.upSince = upSince
        self.phase2 = phase2
    }

    public var id: String { name }

    /// Serveur d'accès distant (FortiClient, nomades) : il attend les clients.
    public var isDialupServer: Bool {
        let t = type?.lowercased() ?? ""
        return parent == nil && (t.contains("dialup") || t.contains("dial-up") || t == "dynamic")
    }

    public var phase2Up: Int { phase2.filter(\.isUp).count }

    public var state: WANTunnelState {
        if phase2.isEmpty {
            if isDialupServer { return .idle }
            switch status?.lowercased() {
            case "up"?: return .up
            default: return .down
            }
        }
        let up = phase2Up
        if up == phase2.count { return .up }
        if up > 0 { return .partial }
        return isDialupServer ? .idle : .down
    }

    /// « Vers Bureau Québec » (commentaire), sinon la passerelle distante.
    public var peerLabel: String {
        if let comments = comments?.trimmingCharacters(in: .whitespaces), !comments.isEmpty { return comments }
        return remoteGateway ?? "—"
    }
}

/// Utilisateur connecté au VPN SSL (monitor/vpn/ssl).
public struct WANSSLUser: Codable, Hashable, Sendable {
    public var user: String
    public var remoteHost: String?
    public var loginAt: Date?

    public init(user: String, remoteHost: String? = nil, loginAt: Date? = nil) {
        self.user = user
        self.remoteHost = remoteHost
        self.loginAt = loginAt
    }
}

/// Lecture du WAN d'une FortiGate.
public struct WANReadReport: Codable, Hashable, Sendable {
    public var system: FortiGateSystem?
    /// Interfaces WAN seulement (rôle « wan », membres SD-WAN, « wanN »).
    public var interfaces: [WANInterfaceStatus]
    public var health: [WANHealthMeasure]
    public var healthConfig: [WANHealthCheckConfig]
    public var tunnels: [WANTunnel]
    /// Utilisateurs VPN SSL ; nil si non lu (adresse absente ou refusée).
    public var sslUsers: [WANSSLUser]?
    /// Faux : les sondes SD-WAN n'ont pas pu être lues (adresse absente ou refusée).
    public var sdwanRead: Bool
    /// Faux : les tunnels IPsec n'ont pas pu être lus.
    public var tunnelsRead: Bool
    /// Parties absentes ou refusées, expliquées en clair.
    public var notes: [String]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(system: FortiGateSystem? = nil, interfaces: [WANInterfaceStatus] = [], health: [WANHealthMeasure] = [],
                healthConfig: [WANHealthCheckConfig] = [], tunnels: [WANTunnel] = [], sslUsers: [WANSSLUser]? = nil,
                sdwanRead: Bool = true, tunnelsRead: Bool = true, notes: [String] = [], calls: [FortiCallRecord] = [],
                readAt: Date = Date()) {
        self.system = system
        self.interfaces = interfaces
        self.health = health
        self.healthConfig = healthConfig
        self.tunnels = tunnels
        self.sslUsers = sslUsers
        self.sdwanRead = sdwanRead
        self.tunnelsRead = tunnelsRead
        self.notes = notes
        self.calls = calls
        self.readAt = readAt
    }

    public func interface(named name: String) -> WANInterfaceStatus? {
        interfaces.first { $0.name.lowercased() == name.lowercased() }
    }
}

/// Lecture réussie du WAN d'une FortiGate d'un site.
public struct WANSiteReport: Codable, Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: WANReadReport

    public init(controllerID: UUID, site: String, report: WANReadReport) {
        self.controllerID = controllerID
        self.site = site
        self.report = report
    }
}

/// Seuils d'un lien WAN dégradé (mesures des sondes SD-WAN).
public struct WANThresholds: Codable, Hashable, Sendable {
    public var latencyMs: Double
    public var jitterMs: Double
    public var lossPercent: Double

    public init(latencyMs: Double = 150, jitterMs: Double = 30, lossPercent: Double = 2) {
        self.latencyMs = max(1, latencyMs)
        self.jitterMs = max(1, jitterMs)
        self.lossPercent = min(100, max(0.1, lossPercent))
    }

    public static let standard = WANThresholds()

    /// « latence > 150 ms, gigue > 30 ms ou perte > 2 % ».
    public var label: String {
        "latence > \(MonFormat.number(latencyMs))\u{00A0}ms, gigue > \(MonFormat.number(jitterMs))\u{00A0}ms ou perte > \(MonFormat.percent(lossPercent))"
    }
}

extension WANThresholds {
    private enum Keys: String, CodingKey { case latencyMs, jitterMs, lossPercent }

    /// Décodage tolérant : un seuil absent prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = WANThresholds.standard
        self.init(latencyMs: (try? c.decodeIfPresent(Double.self, forKey: .latencyMs)) ?? d.latencyMs,
                  jitterMs: (try? c.decodeIfPresent(Double.self, forKey: .jitterMs)) ?? d.jitterMs,
                  lossPercent: (try? c.decodeIfPresent(Double.self, forKey: .lossPercent)) ?? d.lossPercent)
    }
}
