import Foundation

// Note 75 : application d'un flux devinée par son protocole et son port de service (les flux ne
// portent pas le nom de l'application, contrairement à FortiView), et sens d'un flux : quel bout
// est l'appareil du réseau local, quel bout est la destination.

/// Application déduite du port de service.
public struct FlowApplication: Hashable, Sendable, Codable {
    /// « HTTPS », « DNS », « TCP/8443 ».
    public var name: String
    /// « Web », « Infrastructure », « Partage de fichiers »…
    public var category: String
    /// Risque 1 (faible) à 5 (critique), comme FortiView ; nil s'il n'y a rien à signaler.
    public var risk: Int?

    public init(name: String, category: String, risk: Int? = nil) {
        self.name = name
        self.category = category
        self.risk = risk
    }
}

public enum FlowApplications {
    /// Nom du protocole IP.
    public static func protocolName(_ proto: UInt8) -> String {
        switch proto {
        case 1: return "ICMP"
        case 2: return "IGMP"
        case 6: return "TCP"
        case 17: return "UDP"
        case 47: return "GRE"
        case 50: return "ESP"
        case 51: return "AH"
        case 58: return "ICMPv6"
        case 89: return "OSPF"
        case 112: return "VRRP"
        case 132: return "SCTP"
        default: return "IP/\(proto)"
        }
    }

    private struct Known {
        var name: String
        var category: String
        var risk: Int?
    }

    /// Ports de service connus : (protocole, port) ; protocole 0 : TCP et UDP.
    private static let known: [UInt32: Known] = {
        var map: [UInt32: Known] = [:]
        func add(_ proto: UInt8, _ ports: [UInt16], _ name: String, _ category: String, risk: Int? = nil) {
            for port in ports { map[UInt32(proto) << 16 | UInt32(port)] = Known(name: name, category: category, risk: risk) }
        }
        add(6, [80, 8080], "HTTP", "Web")
        add(6, [443, 8443], "HTTPS", "Web")
        add(17, [443], "QUIC", "Web")
        add(0, [53], "DNS", "Infrastructure")
        add(6, [853], "DNS sur TLS", "Infrastructure")
        add(17, [67, 68], "DHCP", "Infrastructure")
        add(17, [123], "NTP", "Infrastructure")
        add(17, [161, 162], "SNMP", "Supervision")
        add(0, [514, 5514], "Syslog", "Supervision")
        add(0, [2055, 4739, 6343], "Flux (NetFlow, IPFIX, sFlow)", "Supervision")
        add(0, [88], "Kerberos", "Annuaire")
        add(0, [389], "LDAP", "Annuaire")
        add(6, [636, 3269], "LDAPS", "Annuaire")
        add(6, [3268], "Catalogue global AD", "Annuaire")
        add(6, [135], "RPC Microsoft", "Annuaire")
        add(6, [445, 139], "SMB", "Partage de fichiers")
        add(17, [137, 138], "NetBIOS", "Partage de fichiers")
        add(6, [2049], "NFS", "Partage de fichiers")
        add(6, [548], "AFP", "Partage de fichiers")
        add(6, [21, 20], "FTP", "Transfert de fichiers")
        add(6, [22], "SSH", "Accès distant")
        add(6, [23], "Telnet", "Accès distant", risk: 3)
        add(0, [3389], "Bureau à distance (RDP)", "Accès distant", risk: 3)
        add(6, [5900, 5901], "VNC", "Accès distant", risk: 3)
        add(0, [21115, 21116, 21117, 21118, 21119], "RustDesk", "Accès distant")
        add(6, [5938], "TeamViewer", "Accès distant", risk: 3)
        add(6, [7070], "AnyDesk", "Accès distant", risk: 3)
        add(6, [25, 587, 465], "SMTP", "Courriel")
        add(6, [993, 143], "IMAP", "Courriel")
        add(6, [995, 110], "POP3", "Courriel")
        add(0, [5060, 5061], "SIP", "Voix sur IP")
        add(17, [3478, 3479, 3480, 3481], "Teams et visio (STUN)", "Collaboration")
        add(17, [8801, 8802, 8803, 8804, 8805, 8806, 8807, 8808, 8809, 8810], "Zoom", "Collaboration")
        add(6, [1433], "SQL Server", "Base de données")
        add(6, [3306], "MySQL", "Base de données")
        add(6, [5432], "PostgreSQL", "Base de données")
        add(6, [1521], "Oracle", "Base de données")
        add(0, [500, 4500], "VPN IPsec (IKE)", "VPN")
        add(0, [1194], "OpenVPN", "VPN")
        add(17, [51820], "WireGuard", "VPN")
        add(6, [10443], "VPN SSL FortiGate", "VPN")
        add(6, [541, 8013], "FortiGuard et FortiManager", "Supervision")
        add(6, [554], "RTSP (caméras)", "Vidéo")
        add(6, [8000, 37777], "Enregistreur vidéo", "Vidéo")
        add(6, [9100, 631, 515], "Impression", "Impression")
        add(17, [5353], "Bonjour (mDNS)", "Infrastructure")
        add(17, [1900], "SSDP (UPnP)", "Infrastructure")
        add(6, [3128], "Mandataire HTTP", "Proxy", risk: 4)
        add(6, [1080], "Mandataire SOCKS", "Proxy", risk: 4)
        add(6, [9001, 9030], "Tor", "Proxy", risk: 5)
        add(0, [6881, 6882, 6883, 6884, 6885, 6886, 6887, 6888, 6889, 51413], "BitTorrent", "P2P", risk: 5)
        add(6, [3333, 4444, 14444], "Minage de cryptomonnaie", "Cryptomining", risk: 5)
        add(6, [3074], "Xbox Live", "Jeux", risk: 4)
        add(17, [3074], "Xbox Live", "Jeux", risk: 4)
        add(0, [27015, 27016, 27017, 27018, 27019, 27020], "Steam", "Jeux", risk: 4)
        return map
    }()

    private static func lookup(_ proto: UInt8, _ port: UInt16) -> Known? {
        guard proto == 6 || proto == 17 else { return nil }
        return known[UInt32(proto) << 16 | UInt32(port)] ?? known[UInt32(port)]
    }

    /// Port de service d'un flux : le port connu, sinon le plus petit (0 hors TCP et UDP).
    public static func servicePort(proto: UInt8, sourcePort: UInt16, destinationPort: UInt16) -> UInt16 {
        guard proto == 6 || proto == 17 else { return 0 }
        let srcKnown = lookup(proto, sourcePort) != nil
        let dstKnown = lookup(proto, destinationPort) != nil
        if dstKnown && !srcKnown { return destinationPort }
        if srcKnown && !dstKnown { return sourcePort }
        if srcKnown && dstKnown { return min(sourcePort, destinationPort) }
        return min(sourcePort, destinationPort)
    }

    /// Application d'un protocole et d'un port de service.
    public static func application(proto: UInt8, port: UInt16) -> FlowApplication {
        if let known = lookup(proto, port) { return FlowApplication(name: known.name, category: known.category, risk: known.risk) }
        switch proto {
        case 1, 58: return FlowApplication(name: "ICMP (ping)", category: "Infrastructure")
        case 50, 51: return FlowApplication(name: "VPN IPsec (ESP)", category: "VPN")
        case 47: return FlowApplication(name: "GRE", category: "VPN")
        case 6, 17: return FlowApplication(name: "\(protocolName(proto))/\(port)", category: port < 1024 ? "Service" : "Autre")
        default: return FlowApplication(name: protocolName(proto), category: "Autre")
        }
    }

    // MARK: Adresses

    /// Adresse du réseau local : privée (RFC 1918), CGNAT (100.64/10) ou lien local.
    public static func isLocal(_ ip: IPv4Address) -> Bool {
        let v = ip.value
        return v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 22 == 0x191 || v >> 16 == 0xA9FE
    }

    /// Multidiffusion ou diffusion.
    static func isGroup(_ ip: IPv4Address) -> Bool {
        ip.value >> 28 == 0xE || ip.value == .max
    }

    /// Côté local et côté distant d'un flux, et vrai si le flux va du local vers le distant.
    /// - local → Internet : la source est locale (envoi) ;
    /// - Internet → local : la destination est locale (réception) ;
    /// - entre deux adresses locales : le bout qui porte le port de service est le serveur (distant).
    public static func orient(_ record: FlowRecord) -> (local: IPv4Address, remote: IPv4Address, outbound: Bool)? {
        guard let src = record.source, let dst = record.destination else { return nil }
        let srcLocal = isLocal(src)
        let dstLocal = isLocal(dst) && !isGroup(dst)
        if srcLocal && !dstLocal { return (src, dst, true) }
        if dstLocal && !srcLocal { return (dst, src, false) }
        let service = servicePort(proto: record.proto, sourcePort: record.sourcePort, destinationPort: record.destinationPort)
        if service != 0, service == record.sourcePort, service != record.destinationPort { return (dst, src, false) }
        return (src, dst, true)
    }
}
