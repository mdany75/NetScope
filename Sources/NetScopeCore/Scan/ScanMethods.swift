import Foundation

/// Méthodes de découverte d'un profil de scan (Réglages › Profils de scan).
///
/// Les valeurs par défaut reproduisent exactement le comportement des versions précédentes
/// (ICMP, ARP, DNS inverse, mDNS, NetBIOS, SNMP ; ni sonde TCP/UDP de présence ni écoute LLDP) :
/// un profil enregistré sans méthodes, ou avec une partie seulement, garde ce comportement.
public struct ScanMethods: Codable, Hashable, Sendable {
    /// Ping ICMP de toutes les adresses.
    public var icmp = true
    /// Lecture de la table ARP après les pings (même segment).
    public var arp = true
    /// Connexion TCP sur `tcpPorts` pour les adresses muettes au ping (connexion complète : le SYN
    /// demi-ouvert demanderait les droits d'administrateur).
    public var tcp = false
    public var tcpPorts: [UInt16] = ScanMethods.defaultTCPPorts
    /// Datagramme UDP sur `udpPorts` pour les adresses toujours muettes (réponse ou « port injoignable »).
    public var udp = false
    public var udpPorts: [UInt16] = ScanMethods.defaultUDPPorts
    /// Noms : DNS inverse, mDNS (Bonjour), NetBIOS.
    public var reverseDNS = true
    public var mdns = true
    public var netbios = true
    /// Découverte SNMP des switchs et routeurs (communautés des Identifiants).
    public var snmp = true
    /// Écoute passive des annonces LLDP/CDP du switch voisin pendant le scan (accès /dev/bpf).
    public var lldp = false

    public static let defaultTCPPorts: [UInt16] = [22, 80, 443, 445, 3389]
    public static let defaultUDPPorts: [UInt16] = [53, 123, 137, 161, 1900, 5353]

    public init() {}

    /// Méthodes par défaut d'un profil (identiques pour tous : le comportement d'avant).
    public static func defaults(for profile: ScanProfile) -> ScanMethods { ScanMethods() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = ScanMethods()
        icmp = try container.decodeIfPresent(Bool.self, forKey: .icmp) ?? base.icmp
        arp = try container.decodeIfPresent(Bool.self, forKey: .arp) ?? base.arp
        tcp = try container.decodeIfPresent(Bool.self, forKey: .tcp) ?? base.tcp
        tcpPorts = ScanMethods.clean(try container.decodeIfPresent([UInt16].self, forKey: .tcpPorts)) ?? base.tcpPorts
        udp = try container.decodeIfPresent(Bool.self, forKey: .udp) ?? base.udp
        udpPorts = ScanMethods.clean(try container.decodeIfPresent([UInt16].self, forKey: .udpPorts)) ?? base.udpPorts
        reverseDNS = try container.decodeIfPresent(Bool.self, forKey: .reverseDNS) ?? base.reverseDNS
        mdns = try container.decodeIfPresent(Bool.self, forKey: .mdns) ?? base.mdns
        netbios = try container.decodeIfPresent(Bool.self, forKey: .netbios) ?? base.netbios
        snmp = try container.decodeIfPresent(Bool.self, forKey: .snmp) ?? base.snmp
        lldp = try container.decodeIfPresent(Bool.self, forKey: .lldp) ?? base.lldp
    }

    private static func clean(_ ports: [UInt16]?) -> [UInt16]? {
        guard let ports else { return nil }
        let valid = Array(Set(ports.filter { $0 > 0 })).sorted()
        return valid.isEmpty ? nil : valid
    }

    /// Au moins une méthode trouve des hôtes (ICMP, ARP, TCP ou UDP).
    public var findsHosts: Bool { icmp || arp || (tcp && !tcpPorts.isEmpty) || (udp && !udpPorts.isEmpty) }

    /// Au moins une méthode de noms.
    public var resolvesNames: Bool { reverseDNS || mdns || netbios }

    /// Étiquettes courtes du profil (cartes des Réglages, infobulle du Scanner).
    public var tags: [String] {
        var tags: [String] = []
        if icmp { tags.append("ICMP") }
        if arp { tags.append("ARP") }
        if tcp { tags.append("Présence TCP") }
        if udp { tags.append("UDP") }
        let names = [reverseDNS ? "DNS" : nil, mdns ? "mDNS" : nil, netbios ? "NetBIOS" : nil].compactMap { $0 }
        if !names.isEmpty { tags.append(names.joined(separator: " · ")) }
        if snmp { tags.append("SNMP") }
        if lldp { tags.append("LLDP/CDP") }
        return tags
    }

    /// Chaîne de noms correspondant aux méthodes cochées (nil si aucune).
    public func nameResolver() -> NameResolverChain? {
        guard resolvesNames else { return nil }
        return NameResolverChain(reverseDNS: reverseDNS ? ScanReverseDNS() : nil,
                                 mdns: mdns ? NamesMDNS() : nil,
                                 netbios: netbios ? NamesNetBIOS() : nil)
    }
}

/// Méthodes de chaque profil, enregistrées ensemble (JSON) : un profil absent garde ses méthodes
/// par défaut, un profil enregistré avant la 0.8 (sans méthodes) aussi.
public struct ScanProfileMethods: Codable, Equatable, Sendable {
    public var byProfile: [String: ScanMethods]

    public init(byProfile: [String: ScanMethods] = [:]) {
        self.byProfile = byProfile
    }

    public func methods(for profile: ScanProfile) -> ScanMethods {
        byProfile[profile.rawValue] ?? ScanMethods.defaults(for: profile)
    }

    public mutating func set(_ methods: ScanMethods, for profile: ScanProfile) {
        if methods == ScanMethods.defaults(for: profile) {
            byProfile[profile.rawValue] = nil
        } else {
            byProfile[profile.rawValue] = methods
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byProfile = try container.decodeIfPresent([String: ScanMethods].self, forKey: .byProfile) ?? [:]
    }

    /// Lecture tolérante : données absentes ou illisibles → méthodes par défaut.
    public static func decode(_ data: Data?) -> ScanProfileMethods {
        guard let data, let value = try? JSONDecoder().decode(ScanProfileMethods.self, from: data) else { return ScanProfileMethods() }
        return value
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// Plan d'un scan : ce que le moteur et l'application feront réellement, d'après le profil,
/// ses méthodes et les réglages des switchs.
public struct ScanPlan: Equatable, Sendable {
    public var ping: Bool
    public var arp: Bool
    public var presenceTCPPorts: [UInt16]
    public var presenceUDPPorts: [UInt16]
    public var reverseDNS: Bool
    public var mdns: Bool
    public var netbios: Bool
    /// Ports TCP sondés sur les hôtes trouvés.
    public var ports: [UInt16]
    public var snmp: Bool
    public var lldp: Bool

    /// - Parameters:
    ///   - autoDiscoverSwitches: réglage « Découverte automatique des switchs » (Réglages › Switchs).
    public init(options: ScanOptions, autoDiscoverSwitches: Bool) {
        let methods = options.methods
        ping = methods.icmp
        arp = methods.arp && options.useARP
        presenceTCPPorts = methods.tcp ? methods.tcpPorts : []
        presenceUDPPorts = methods.udp ? methods.udpPorts : []
        reverseDNS = options.resolveNames && methods.reverseDNS
        mdns = options.resolveNames && methods.mdns
        netbios = options.resolveNames && methods.netbios
        ports = options.ports
        // Le profil Complet force la découverte SNMP… sauf si sa méthode SNMP est décochée.
        snmp = methods.snmp && (autoDiscoverSwitches || options.profile.alwaysDiscoversSwitches)
        lldp = methods.lldp
    }

    public var resolvesNames: Bool { reverseDNS || mdns || netbios }
    public var probesPresence: Bool { !presenceTCPPorts.isEmpty || !presenceUDPPorts.isEmpty }

    /// Étapes prévues, dans l'ordre (barre d'avancement du Scanner).
    public var phases: [ScanPhase] {
        var phases: [ScanPhase] = []
        if ping || probesPresence { phases.append(.ping) }
        if arp { phases.append(.arp) }
        if resolvesNames || !ports.isEmpty { phases.append(.details) }
        if snmp { phases += [.switches, .locations] }
        return phases
    }

    /// Plan qui ne trouvera aucun hôte (toutes les méthodes de présence décochées).
    public var findsNothing: Bool { !ping && !arp && !probesPresence }
}
