import Foundation

// Requêtes métier sur un switch : système, interfaces, table MAC (BRIDGE-MIB / Q-BRIDGE-MIB),
// voisins LLDP, PoE (POWER-ETHERNET-MIB) et table ARP du switch.

/// OID utilisés.
public enum SNMPOIDs {
    // SNMPv2-MIB, groupe system
    public static let sysDescr: SNMPOID = "1.3.6.1.2.1.1.1.0"
    public static let sysObjectID: SNMPOID = "1.3.6.1.2.1.1.2.0"
    public static let sysUpTime: SNMPOID = "1.3.6.1.2.1.1.3.0"
    public static let sysContact: SNMPOID = "1.3.6.1.2.1.1.4.0"
    public static let sysName: SNMPOID = "1.3.6.1.2.1.1.5.0"
    public static let sysLocation: SNMPOID = "1.3.6.1.2.1.1.6.0"

    // IF-MIB, ifTable
    public static let ifDescr: SNMPOID = "1.3.6.1.2.1.2.2.1.2"
    public static let ifType: SNMPOID = "1.3.6.1.2.1.2.2.1.3"
    public static let ifAdminStatus: SNMPOID = "1.3.6.1.2.1.2.2.1.7"
    public static let ifOperStatus: SNMPOID = "1.3.6.1.2.1.2.2.1.8"
    public static let ifLastChange: SNMPOID = "1.3.6.1.2.1.2.2.1.9"
    public static let ifInErrors: SNMPOID = "1.3.6.1.2.1.2.2.1.14"
    // IF-MIB, ifXTable
    public static let ifName: SNMPOID = "1.3.6.1.2.1.31.1.1.1.1"
    public static let ifHCInOctets: SNMPOID = "1.3.6.1.2.1.31.1.1.1.6"
    public static let ifHCOutOctets: SNMPOID = "1.3.6.1.2.1.31.1.1.1.10"
    public static let ifHighSpeed: SNMPOID = "1.3.6.1.2.1.31.1.1.1.15"
    public static let ifAlias: SNMPOID = "1.3.6.1.2.1.31.1.1.1.18"

    // BRIDGE-MIB
    /// Nombre de ports de pont (dot1dBaseNumPorts.0) : présent et non nul sur un switch.
    public static let dot1dBaseNumPorts: SNMPOID = "1.3.6.1.2.1.17.1.2.0"
    public static let dot1dBasePortIfIndex: SNMPOID = "1.3.6.1.2.1.17.1.4.1.2"
    public static let dot1dTpFdbPort: SNMPOID = "1.3.6.1.2.1.17.4.3.1.2"
    // Q-BRIDGE-MIB
    public static let dot1qTpFdbPort: SNMPOID = "1.3.6.1.2.1.17.7.1.2.2.1.2"
    public static let dot1qPvid: SNMPOID = "1.3.6.1.2.1.17.7.1.4.5.1.1"
    /// dot1qVlanFdbId (index : timeMark.vlan) : base de filtrage utilisée par chaque VLAN.
    public static let dot1qVlanFdbId: SNMPOID = "1.3.6.1.2.1.17.7.1.4.2.1.3"
    // CISCO-VTP-MIB, vtpVlanState (index : domaine.vlan) : VLAN à interroger par « communauté@vlan ».
    public static let vtpVlanState: SNMPOID = "1.3.6.1.4.1.9.9.46.1.3.1.1.2"

    // LLDP-MIB (lldpRemTable, index : timeMark.localPortNum.remIndex)
    public static let lldpRemPortId: SNMPOID = "1.0.8802.1.1.2.1.4.1.1.7"
    public static let lldpRemPortDesc: SNMPOID = "1.0.8802.1.1.2.1.4.1.1.8"
    public static let lldpRemSysName: SNMPOID = "1.0.8802.1.1.2.1.4.1.1.9"
    public static let lldpRemSysDesc: SNMPOID = "1.0.8802.1.1.2.1.4.1.1.10"
    public static let lldpRemSysCapEnabled: SNMPOID = "1.0.8802.1.1.2.1.4.1.1.12"
    // lldpLocPortTable (index : localPortNum)
    public static let lldpLocPortId: SNMPOID = "1.0.8802.1.1.2.1.3.7.1.3"
    public static let lldpLocPortDesc: SNMPOID = "1.0.8802.1.1.2.1.3.7.1.4"

    // POWER-ETHERNET-MIB
    public static let pethPsePortDetectionStatus: SNMPOID = "1.3.6.1.2.1.105.1.1.1.6"
    public static let pethMainPsePower: SNMPOID = "1.3.6.1.2.1.105.1.3.1.1.2"
    public static let pethMainPseConsumptionPower: SNMPOID = "1.3.6.1.2.1.105.1.3.1.1.4"

    // IP-MIB, ipNetToMediaPhysAddress (index : ifIndex.a.b.c.d)
    public static let ipNetToMediaPhysAddress: SNMPOID = "1.3.6.1.2.1.4.22.1.2"
    // IP-MIB (RFC 4293), ipNetToPhysicalPhysAddress (index : ifIndex.type.[longueur.]adresse)
    public static let ipNetToPhysicalPhysAddress: SNMPOID = "1.3.6.1.2.1.4.35.1.4"

    // Printer-MIB, prtGeneralConfigChanges.1 : présent seulement sur une imprimante.
    public static let prtGeneralConfigChanges: SNMPOID = "1.3.6.1.2.1.43.5.1.1.1.1"
}

// MARK: - Modèles

public struct SNMPSystemInfo: Hashable, Sendable, Codable {
    public var name: String
    public var descr: String
    public var objectID: String?
    /// sysUpTime, en centièmes de seconde.
    public var uptimeTicks: UInt32?
    public var location: String?
    public var contact: String?

    public init(name: String, descr: String, objectID: String? = nil, uptimeTicks: UInt32? = nil,
                location: String? = nil, contact: String? = nil) {
        self.name = name
        self.descr = descr
        self.objectID = objectID
        self.uptimeTicks = uptimeTicks
        self.location = location
        self.contact = contact
    }

    /// Marque déduite de sysObjectID (numéro d'entreprise) ou de sysDescr.
    public var brand: String? {
        if let objectID, let oid = SNMPOID(objectID), oid.hasPrefix("1.3.6.1.4.1"), oid.components.count > 6 {
            switch oid.components[6] {
            case 9: return "Cisco"
            case 11 where oid.hasPrefix("1.3.6.1.4.1.11.2.3.9"): return "HP"
            case 11, 47196: return "Aruba"
            case 14823: return "Aruba"
            case 2636: return "Juniper"
            case 41112, 4413: return "Ubiquiti"
            case 12356: return "Fortinet"
            case 674, 6027: return "Dell"
            case 171: return "D-Link"
            case 890: return "Zyxel"
            case 4526: return "Netgear"
            case 11863: return "TP-Link"
            case 29671: return "Cisco Meraki"
            case 25506: return "HPE"
            case 1916: return "Extreme"
            case 30065: return "Arista"
            case 14988: return "MikroTik"
            default: break
            }
        }
        let text = descr.lowercased()
        let known: [(String, String)] = [("cisco", "Cisco"), ("aruba", "Aruba"), ("procurve", "HPE"), ("juniper", "Juniper"),
                                         ("junos", "Juniper"), ("ubiquiti", "Ubiquiti"), ("unifi", "Ubiquiti"), ("edgeswitch", "Ubiquiti"),
                                         ("fortiswitch", "Fortinet"), ("netgear", "Netgear"), ("tp-link", "TP-Link"), ("mikrotik", "MikroTik"),
                                         ("routeros", "MikroTik"), ("dell", "Dell"), ("arista", "Arista"),
                                         ("d-link", "D-Link"), ("zyxel", "Zyxel"), ("fortigate", "Fortinet")]
        return known.first { text.contains($0.0) }?.1
    }

    /// Première ligne de sysDescr, raccourcie (modèle et version du logiciel).
    public var summary: String {
        let first = descr.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? descr
        return first.count > 90 ? String(first.prefix(89)) + "…" : first
    }

    /// « 142 j 06 h » ; « 3 h 12 min » sous une journée.
    public var uptimeText: String? {
        uptimeTicks.map { SNMPFormat.duration(seconds: Int($0 / 100)) }
    }
}

/// État opérationnel d'une interface (ifOperStatus).
public enum SNMPOperStatus: Int, Sendable, Codable {
    case up = 1, down, testing, unknown, dormant, notPresent, lowerLayerDown

    public var label: String {
        switch self {
        case .up: return "Actif"
        case .down: return "Inactif"
        case .testing: return "Test"
        case .unknown: return "Inconnu"
        case .dormant: return "En veille"
        case .notPresent: return "Absent"
        case .lowerLayerDown: return "Couche inférieure inactive"
        }
    }
}

public struct SNMPInterface: Hashable, Sendable, Codable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var descr: String
    public var alias: String
    public var type: Int?
    /// ifAdminStatus : true si activée.
    public var adminUp: Bool
    public var operStatus: SNMPOperStatus
    /// ifHighSpeed, en Mb/s.
    public var speedMbps: UInt64?
    /// ifLastChange, en centièmes de seconde depuis le démarrage.
    public var lastChangeTicks: UInt32?
    public var inErrors: UInt64?
    public var inOctets: UInt64?
    public var outOctets: UInt64?

    public init(index: Int, name: String, descr: String = "", alias: String = "", type: Int? = 6, adminUp: Bool = true,
                operStatus: SNMPOperStatus = .down, speedMbps: UInt64? = nil, lastChangeTicks: UInt32? = nil,
                inErrors: UInt64? = nil, inOctets: UInt64? = nil, outOctets: UInt64? = nil) {
        self.index = index
        self.name = name
        self.descr = descr
        self.alias = alias
        self.type = type
        self.adminUp = adminUp
        self.operStatus = operStatus
        self.speedMbps = speedMbps
        self.lastChangeTicks = lastChangeTicks
        self.inErrors = inErrors
        self.outOctets = outOctets
        self.inOctets = inOctets
    }

    public var isUp: Bool { adminUp && operStatus == .up }

    /// Port physique Ethernet (ethernetCsmacd, gigabitEthernet…), hors interfaces virtuelles.
    public var isPhysical: Bool {
        // « Vlan1 », « Po1 », « lo0 », « Trk1 » : interfaces logiques (sans « / » dans le nom).
        // Les préfixes courts ne comptent que suivis d'un chiffre : « Port 1 » reste un port physique.
        let virtualWords = ["vlan", "port-channel", "loopback", "null", "tunnel", "stack", "bridge", "dynamic", "default"]
        let virtualShort = ["vl", "po", "lo", "trk", "lag", "ae", "bond", "br", "cpu", "mgmt", "nve", "irb"]
        let lower = name.lowercased()
        if !lower.contains("/") {
            if virtualWords.contains(where: { lower.hasPrefix($0) }) { return false }
            let isVirtual = virtualShort.contains { prefix in
                guard lower.hasPrefix(prefix) else { return false }
                let rest = lower.dropFirst(prefix.count).drop { $0 == " " }
                return rest.isEmpty || rest.first!.isNumber
            }
            if isVirtual { return false }
        }
        guard let type else { return true }
        // ethernetCsmacd, iso88023Csmacd, fastEther, fastEtherFX, gigabitEthernet.
        return [6, 7, 62, 69, 117].contains(type)
    }

    /// Port de module (SFP/SFP+) : noms Te/Tw/Fo/Hu, xe-/et-, ou vitesse de 10 Gb/s et plus.
    public var isModular: Bool {
        let lower = name.lowercased()
        let prefixes = ["te", "tw", "fo", "hu", "xe-", "et-", "sfp", "xg", "tengig", "twentyfive", "fortygig", "hundredgig"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        return (speedMbps ?? 0) >= 10_000
    }

    /// Libellé court pour la façade : dernier nombre du nom (« Gi1/0/12 » → « 12 »).
    public var shortLabel: String {
        let digits = name.split(whereSeparator: { !$0.isNumber })
        return digits.last.map(String.init) ?? String(index)
    }
}

public struct SNMPFDBEntry: Hashable, Sendable, Codable {
    public var mac: MACAddress
    public var vlan: Int?
    public var bridgePort: Int
    public var ifIndex: Int?

    public init(mac: MACAddress, vlan: Int?, bridgePort: Int, ifIndex: Int?) {
        self.mac = mac
        self.vlan = vlan
        self.bridgePort = bridgePort
        self.ifIndex = ifIndex
    }
}

/// Capacités LLDP (bits de lldpRemSysCapEnabled).
public struct SNMPLLDPCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let other = SNMPLLDPCapabilities(rawValue: 1 << 0)
    public static let repeater = SNMPLLDPCapabilities(rawValue: 1 << 1)
    public static let bridge = SNMPLLDPCapabilities(rawValue: 1 << 2)
    public static let accessPoint = SNMPLLDPCapabilities(rawValue: 1 << 3)
    public static let router = SNMPLLDPCapabilities(rawValue: 1 << 4)
    public static let telephone = SNMPLLDPCapabilities(rawValue: 1 << 5)
    public static let docsis = SNMPLLDPCapabilities(rawValue: 1 << 6)
    public static let station = SNMPLLDPCapabilities(rawValue: 1 << 7)

    /// Décodage de la chaîne BITS : le bit 0 est le bit de poids fort du premier octet.
    public init(bits bytes: [UInt8]) {
        var value: UInt16 = 0
        for bit in 0..<16 {
            let byte = bit / 8
            guard byte < bytes.count else { break }
            if bytes[byte] & (0x80 >> UInt8(bit % 8)) != 0 { value |= 1 << UInt16(bit) }
        }
        rawValue = value
    }

    public var labels: [String] {
        var result: [String] = []
        if contains(.router) { result.append("Routeur") }
        if contains(.bridge) { result.append("Pont (bridge)") }
        if contains(.accessPoint) { result.append("Point d’accès") }
        if contains(.telephone) { result.append("Téléphone") }
        if contains(.repeater) { result.append("Répéteur") }
        if contains(.station) { result.append("Station") }
        if contains(.docsis) { result.append("Câble DOCSIS") }
        if contains(.other) { result.append("Autre") }
        return result
    }

    /// Équipement d'infrastructure : un port vers lui est un uplink. Un téléphone IP annonce souvent
    /// « Bridge, Telephone » (son petit switch pour le poste branché derrière) : ce n'en est pas un.
    public var isInfrastructure: Bool {
        if contains(.router) { return true }
        return (contains(.bridge) || contains(.repeater)) && !contains(.telephone)
    }
}

public struct SNMPLLDPNeighbor: Hashable, Sendable, Codable {
    public var localPortNum: Int
    /// Interface locale déduite (ifIndex), si la correspondance a été trouvée.
    public var ifIndex: Int?
    public var sysName: String
    public var portID: String
    public var portDescr: String?
    public var sysDescr: String?
    public var capabilities: SNMPLLDPCapabilities?

    public init(localPortNum: Int, ifIndex: Int? = nil, sysName: String, portID: String, portDescr: String? = nil,
                sysDescr: String? = nil, capabilities: SNMPLLDPCapabilities? = nil) {
        self.localPortNum = localPortNum
        self.ifIndex = ifIndex
        self.sysName = sysName
        self.portID = portID
        self.portDescr = portDescr
        self.sysDescr = sysDescr
        self.capabilities = capabilities
    }
}

/// Résultat d'un relevé complet d'un switch.
public struct SNMPSwitchSnapshot: Hashable, Sendable, Codable, Identifiable {
    public var id: String { host.description }
    public var host: IPv4Address
    public var system: SNMPSystemInfo
    public var interfaces: [SNMPInterface]
    public var fdb: [SNMPFDBEntry]
    public var neighbors: [SNMPLLDPNeighbor]
    /// VLAN natif / d'accès par ifIndex (dot1qPvid).
    public var pvid: [Int: Int]
    /// Ports qui délivrent du PoE (ifIndex).
    public var poePorts: Set<Int>
    /// Budget et consommation PoE, en watts.
    public var poeBudgetW: Int?
    public var poeUsedW: Int?
    /// PoE détaillé par port (POWER-ETHERNET-MIB et MIB propriétaires) ; nil dans un relevé
    /// antérieur à ce détail, vide si le switch ne répond pas à la MIB.
    public var poeDetails: [SNMPPoEPort]?
    /// Table ARP du switch : MAC → IP (switchs de niveau 3).
    public var arp: [MACAddress: IPv4Address]
    public var polledAt: Date
    /// Contrôleur qui a fourni ce relevé (FortiGate pour un FortiSwitch géré par FortiLink) ;
    /// nil pour un relevé SNMP direct.
    public var controllerName: String?
    /// Adresse FortiLink réelle quand `host` est une adresse de remplacement (note 25 : deux sites
    /// dont les FortiSwitch ont la même adresse FortiLink, 10.255.1.2 par exemple).
    public var fortiLinkIP: IPv4Address?
    /// Note 60 : modèle, numéro de série et version du logiciel (ENTITY-MIB, sinon sysDescr) ;
    /// nil dans un relevé antérieur à la 0.23.0 ou sans réponse utile.
    public var hardware: SNMPHardwareInfo?
    /// Note 77 : marque du contrôleur qui a fourni ce relevé (« UniFi », « Omada », « Meraki ») ;
    /// nil pour un FortiSwitch lu par la FortiGate ou un relevé SNMP.
    public var controllerKind: String?

    public init(host: IPv4Address, system: SNMPSystemInfo, interfaces: [SNMPInterface], fdb: [SNMPFDBEntry] = [],
                neighbors: [SNMPLLDPNeighbor] = [], pvid: [Int: Int] = [:], poePorts: Set<Int> = [],
                poeBudgetW: Int? = nil, poeUsedW: Int? = nil, poeDetails: [SNMPPoEPort]? = nil,
                arp: [MACAddress: IPv4Address] = [:], polledAt: Date = Date(), controllerName: String? = nil,
                fortiLinkIP: IPv4Address? = nil) {
        self.host = host
        self.system = system
        self.interfaces = interfaces
        self.fdb = fdb
        self.neighbors = neighbors
        self.pvid = pvid
        self.poePorts = poePorts
        self.poeBudgetW = poeBudgetW
        self.poeUsedW = poeUsedW
        self.poeDetails = poeDetails
        self.arp = arp
        self.polledAt = polledAt
        self.controllerName = controllerName
        self.fortiLinkIP = fortiLinkIP
        self.hardware = nil
    }

    /// Relevé fourni par un contrôleur (FortiGate) et non par SNMP.
    public var isViaController: Bool { controllerName != nil }

    /// Source affichée d'un relevé de contrôleur : « FortiGate », ou la marque (note 77).
    public var controllerSourceLabel: String { controllerKind ?? "FortiGate" }

    public var displayName: String { system.name.isEmpty ? host.description : system.name }

    /// Ports physiques, dans l'ordre des ifIndex.
    public var physicalPorts: [SNMPInterface] {
        interfaces.filter(\.isPhysical).sorted { $0.index < $1.index }
    }

    public func interface(_ ifIndex: Int) -> SNMPInterface? {
        interfaces.first { $0.index == ifIndex }
    }

    public func entries(on ifIndex: Int) -> [SNMPFDBEntry] {
        fdb.filter { $0.ifIndex == ifIndex }
    }

    public func neighbor(on ifIndex: Int) -> SNMPLLDPNeighbor? {
        neighbors.first { $0.ifIndex == ifIndex }
    }

    /// Nombre d'adresses MAC apprises par interface.
    public var macCountByInterface: [Int: Int] {
        var counts: [Int: Int] = [:]
        for entry in fdb { if let i = entry.ifIndex { counts[i, default: 0] += 1 } }
        return counts
    }

    /// Ports d'uplink : un voisin LLDP d'infrastructure (ou de capacités inconnues), ou au moins
    /// `macThreshold` adresses MAC sans voisin qui s'annonce comme simple poste, AP ou téléphone.
    public func uplinkInterfaces(macThreshold: Int = 8) -> Set<Int> {
        var result: Set<Int> = []
        var endpointPorts: Set<Int> = []
        for neighbor in neighbors {
            guard let i = neighbor.ifIndex else { continue }
            if let caps = neighbor.capabilities, !caps.isEmpty, !caps.isInfrastructure {
                endpointPorts.insert(i)
            } else {
                result.insert(i)
            }
        }
        for (i, count) in macCountByInterface where count >= macThreshold && !endpointPorts.contains(i) {
            result.insert(i)
        }
        return result
    }
}

/// Emplacement d'un appareil.
public struct SNMPLocation: Hashable, Sendable {
    public var switchHost: IPv4Address
    public var switchName: String
    public var ifIndex: Int
    public var portName: String
    public var vlan: Int?
    public var isUplink: Bool

    public init(switchHost: IPv4Address, switchName: String, ifIndex: Int, portName: String, vlan: Int?, isUplink: Bool) {
        self.switchHost = switchHost
        self.switchName = switchName
        self.ifIndex = ifIndex
        self.portName = portName
        self.vlan = vlan
        self.isUplink = isUplink
    }
}

public enum SNMPLocator {
    /// Ports d'uplink de chaque switch, en tenant compte des autres switchs relevés (switchs chaînés) :
    /// - les règles propres au switch (`uplinkInterfaces`) : voisin LLDP d'infrastructure, beaucoup de MAC ;
    /// - un voisin LLDP qui porte le nom d'un autre switch relevé, quelles que soient ses capacités ;
    /// - un port où le switch apprend l'adresse MAC d'un autre switch relevé (d'après les tables ARP) ;
    /// - un port où convergent des MAC qu'un autre switch voit sur au moins deux ports différents :
    ///   un port d'accès ne mène qu'à un seul port de l'autre switch, un lien entre switchs en agrège plusieurs.
    public static func uplinks(in snapshots: [SNMPSwitchSnapshot], macThreshold: Int = 8) -> [IPv4Address: Set<Int>] {
        func normalized(_ name: String) -> String {
            name.lowercased().split(separator: ".").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let names = Set(snapshots.map { normalized($0.system.name) }.filter { !$0.isEmpty })
        let hosts = Set(snapshots.map(\.host))
        var switchMACs: Set<MACAddress> = []
        for snapshot in snapshots {
            for (mac, ip) in snapshot.arp where hosts.contains(ip) && ip != snapshot.host { switchMACs.insert(mac) }
        }
        // MAC → ports (ifIndex) où chaque switch l'apprend.
        var portsByMAC: [IPv4Address: [MACAddress: Set<Int>]] = [:]
        for snapshot in snapshots {
            var map: [MACAddress: Set<Int>] = [:]
            for entry in snapshot.fdb { if let i = entry.ifIndex { map[entry.mac, default: []].insert(i) } }
            portsByMAC[snapshot.host] = map
        }
        var result: [IPv4Address: Set<Int>] = [:]
        for snapshot in snapshots {
            var set = snapshot.uplinkInterfaces(macThreshold: macThreshold)
            let own = normalized(snapshot.system.name)
            for neighbor in snapshot.neighbors {
                let name = normalized(neighbor.sysName)
                if let i = neighbor.ifIndex, !name.isEmpty, name != own, names.contains(name) { set.insert(i) }
            }
            var macsByPort: [Int: Set<MACAddress>] = [:]
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex else { continue }
                if switchMACs.contains(entry.mac) { set.insert(i) }
                macsByPort[i, default: []].insert(entry.mac)
            }
            for other in snapshots where other.host != snapshot.host {
                guard let theirs = portsByMAC[other.host] else { continue }
                for (port, macs) in macsByPort where !set.contains(port) {
                    var reached: Set<Int> = []
                    for mac in macs { reached.formUnion(theirs[mac] ?? []) }
                    if reached.count >= 2 { set.insert(port) }
                }
            }
            result[snapshot.host] = set
        }
        return result
    }

    /// Toutes les positions où la MAC est apprise, ports d'accès d'abord.
    public static func sightings(of mac: MACAddress, in snapshots: [SNMPSwitchSnapshot], macThreshold: Int = 8) -> [SNMPLocation] {
        var result: [SNMPLocation] = []
        let uplinkMap = uplinks(in: snapshots, macThreshold: macThreshold)
        for snapshot in snapshots {
            let uplinks = uplinkMap[snapshot.host] ?? []
            for entry in snapshot.fdb where entry.mac == mac {
                guard let i = entry.ifIndex else { continue }
                let name = snapshot.interface(i)?.name ?? "port \(entry.bridgePort)"
                result.append(SNMPLocation(switchHost: snapshot.host, switchName: snapshot.displayName, ifIndex: i,
                                           portName: name, vlan: entry.vlan ?? snapshot.pvid[i], isUplink: uplinks.contains(i)))
            }
        }
        // Ports d'accès d'abord ; à égalité, le port qui porte le moins d'adresses.
        return result.sorted { a, b in
            if a.isUplink != b.isUplink { return !a.isUplink }
            let ca = snapshots.first { $0.host == a.switchHost }?.macCountByInterface[a.ifIndex] ?? 0
            let cb = snapshots.first { $0.host == b.switchHost }?.macCountByInterface[b.ifIndex] ?? 0
            return ca < cb
        }
    }

    /// Port d'accès où la MAC est apprise ; nil si elle n'est vue que sur des uplinks.
    public static func locate(_ mac: MACAddress, in snapshots: [SNMPSwitchSnapshot], macThreshold: Int = 8) -> SNMPLocation? {
        sightings(of: mac, in: snapshots, macThreshold: macThreshold).first { !$0.isUplink }
    }
}

// MARK: - Analyse des index

public enum SNMPParse {
    /// Index Q-BRIDGE (dot1qTpFdbTable) : fdbId.m1.m2.m3.m4.m5.m6 ; fdbId est le VLAN sur la plupart des switchs.
    public static func qBridgeIndex(_ suffix: [UInt32]) -> (vlan: Int, mac: MACAddress)? {
        guard suffix.count == 7, let mac = macFromComponents(Array(suffix[1...])) else { return nil }
        return (Int(suffix[0]), mac)
    }

    /// Index BRIDGE-MIB (dot1dTpFdbTable) : les 6 octets de la MAC.
    public static func bridgeIndex(_ suffix: [UInt32]) -> MACAddress? {
        guard suffix.count == 6 else { return nil }
        return macFromComponents(suffix)
    }

    /// Index LLDP (lldpRemTable) : timeMark.localPortNum.remIndex.
    public static func lldpIndex(_ suffix: [UInt32]) -> (timeMark: UInt32, localPort: Int, remIndex: Int)? {
        guard suffix.count == 3 else { return nil }
        return (suffix[0], Int(suffix[1]), Int(suffix[2]))
    }

    /// Index ipNetToMediaTable : ifIndex.a.b.c.d.
    public static func arpIndex(_ suffix: [UInt32]) -> (ifIndex: Int, ip: IPv4Address)? {
        guard suffix.count == 5, suffix[1...].allSatisfy({ $0 <= 255 }) else { return nil }
        return (Int(suffix[0]), IPv4Address(UInt8(suffix[1]), UInt8(suffix[2]), UInt8(suffix[3]), UInt8(suffix[4])))
    }

    /// Index ipNetToPhysicalTable pour IPv4 : ifIndex.1.4.a.b.c.d (ou ifIndex.1.a.b.c.d sans longueur).
    public static func arpPhysicalIndex(_ suffix: [UInt32]) -> (ifIndex: Int, ip: IPv4Address)? {
        guard suffix.count >= 6, suffix[1] == 1 else { return nil }  // 1 = ipv4
        let address: ArraySlice<UInt32>
        if suffix.count == 7, suffix[2] == 4 { address = suffix[3...] }
        else if suffix.count == 6 { address = suffix[2...] }
        else { return nil }
        guard address.allSatisfy({ $0 <= 255 }) else { return nil }
        let a = Array(address)
        return (Int(suffix[0]), IPv4Address(UInt8(a[0]), UInt8(a[1]), UInt8(a[2]), UInt8(a[3])))
    }

    /// Adresse MAC d'une ligne ARP : 6 octets, ni nulle, ni diffusion, ni multidiffusion.
    static func arpMAC(_ value: SNMPValue) -> MACAddress? {
        guard let bytes = value.bytesValue, bytes.count == 6 else { return nil }
        let mac = MACAddress(bytes: bytes)
        guard mac.value != 0, !mac.isBroadcast, !mac.isMulticast else { return nil }
        return mac
    }

    static func macFromComponents(_ values: [UInt32]) -> MACAddress? {
        guard values.count == 6, values.allSatisfy({ $0 <= 255 }) else { return nil }
        return MACAddress(bytes: values.map { UInt8($0) })
    }

    /// Identifiant de port LLDP : texte lisible, sinon MAC, sinon hexadécimal.
    public static func portIDText(_ value: SNMPValue) -> String {
        guard let bytes = value.bytesValue else { return value.stringValue ?? "" }
        if bytes.count == 6, bytes.contains(where: { $0 < 0x20 || $0 > 0x7E }) {
            return MACAddress(bytes: bytes).formatted(.upperColon)
        }
        if let text = String(bytes: bytes, encoding: .utf8), text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\t" }) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Dernier composant de l'OID d'une ligne (l'ifIndex dans ifTable/ifXTable).
    static func lastIndex(_ bind: SNMPVarBind, under root: SNMPOID) -> Int? {
        guard let suffix = bind.oid.suffix(after: root), suffix.count == 1 else { return nil }
        return Int(suffix[0])
    }
}

public enum SNMPFormat {
    /// « 142 j 06 h », « 3 h 12 min », « 45 s ».
    public static func duration(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days) j " + String(format: "%02d", hours) + " h" }
        if hours > 0 { return "\(hours) h " + String(format: "%02d", minutes) + " min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }

    /// Vitesse lisible : « 1 Gb/s », « 100 Mb/s », « 10 Gb/s ».
    public static func speed(mbps: UInt64?) -> String {
        guard let mbps, mbps > 0 else { return "—" }
        if mbps >= 1000, mbps % 1000 == 0 { return "\(mbps / 1000)\u{00A0}Gb/s" }
        if mbps >= 1000 { return String(format: "%.1f", Double(mbps) / 1000).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Gb/s" }
        return "\(mbps)\u{00A0}Mb/s"
    }

    /// Volume lisible en unités décimales françaises : « 3,41 To », « 48,2 Go ».
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        let units = ["o", "ko", "Mo", "Go", "To", "Po"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let text: String
        if unit == 0 { text = String(value) }
        else if amount >= 100 { text = String(format: "%.0f", amount) }
        else if amount >= 10 { text = String(format: "%.1f", amount) }
        else { text = String(format: "%.2f", amount) }
        return text.replacingOccurrences(of: ".", with: ",") + "\u{00A0}" + units[unit]
    }
}

// MARK: - Relevé d'un switch

/// Interroge un switch : chaque table manquante (MIB non prise en charge) donne simplement un résultat vide.
public struct SNMPSwitchPoller: Sendable {
    public let client: SNMPClient

    public init(target: SNMPTarget) {
        client = SNMPClient(target: target)
    }

    public init(client: SNMPClient) {
        self.client = client
    }

    /// Lit sysName, sysDescr, sysObjectID, sysUpTime, sysLocation et sysContact (une seule requête GET).
    public func system() async throws -> SNMPSystemInfo {
        let oids = [SNMPOIDs.sysDescr, SNMPOIDs.sysObjectID, SNMPOIDs.sysUpTime, SNMPOIDs.sysContact, SNMPOIDs.sysName, SNMPOIDs.sysLocation]
        let binds = try await client.get(oids)
        func value(_ oid: SNMPOID) -> SNMPValue? {
            binds.first { $0.oid == oid && !$0.value.isException }?.value
        }
        var ticks: UInt32?
        if case .timeTicks(let t)? = value(SNMPOIDs.sysUpTime) { ticks = t }
        return SNMPSystemInfo(name: value(SNMPOIDs.sysName)?.stringValue ?? "",
                              descr: value(SNMPOIDs.sysDescr)?.stringValue ?? "",
                              objectID: value(SNMPOIDs.sysObjectID)?.stringValue,
                              uptimeTicks: ticks,
                              location: value(SNMPOIDs.sysLocation)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                              contact: value(SNMPOIDs.sysContact)?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Parcours tolérant : une erreur de l'agent sur une table donne une liste vide.
    private func column(_ root: SNMPOID) async throws -> [SNMPVarBind] {
        do {
            return try await client.walk(root)
        } catch SNMPError.agent {
            return []
        }
    }

    /// Table facultative (ajoutée par certains équipements seulement) : une erreur de l'agent ou un
    /// délai dépassé donne une liste vide au lieu de faire échouer tout le relevé.
    private func optionalColumn(_ root: SNMPOID) async throws -> [SNMPVarBind] {
        do {
            return try await client.walk(root)
        } catch SNMPError.agent {
            return []
        } catch SNMPError.timeout {
            return []
        }
    }

    private func intColumn(_ root: SNMPOID) async throws -> [Int: SNMPValue] {
        var result: [Int: SNMPValue] = [:]
        for bind in try await column(root) {
            if let i = SNMPParse.lastIndex(bind, under: root) { result[i] = bind.value }
        }
        return result
    }

    public func interfaces() async throws -> [SNMPInterface] {
        let descr = try await intColumn(SNMPOIDs.ifDescr)
        let type = try await intColumn(SNMPOIDs.ifType)
        let admin = try await intColumn(SNMPOIDs.ifAdminStatus)
        let oper = try await intColumn(SNMPOIDs.ifOperStatus)
        let lastChange = try await intColumn(SNMPOIDs.ifLastChange)
        let errors = try await intColumn(SNMPOIDs.ifInErrors)
        let name = try await intColumn(SNMPOIDs.ifName)
        let alias = try await intColumn(SNMPOIDs.ifAlias)
        let speed = try await intColumn(SNMPOIDs.ifHighSpeed)
        let inOctets = try await intColumn(SNMPOIDs.ifHCInOctets)
        let outOctets = try await intColumn(SNMPOIDs.ifHCOutOctets)
        return SNMPSwitchPoller.buildInterfaces(descr: descr, type: type, admin: admin, oper: oper, lastChange: lastChange,
                                                errors: errors, name: name, alias: alias, speed: speed,
                                                inOctets: inOctets, outOctets: outOctets)
    }

    static func buildInterfaces(descr: [Int: SNMPValue], type: [Int: SNMPValue], admin: [Int: SNMPValue], oper: [Int: SNMPValue],
                                lastChange: [Int: SNMPValue], errors: [Int: SNMPValue], name: [Int: SNMPValue], alias: [Int: SNMPValue],
                                speed: [Int: SNMPValue], inOctets: [Int: SNMPValue], outOctets: [Int: SNMPValue]) -> [SNMPInterface] {
        let indexes = Set(descr.keys).union(name.keys)
        return indexes.sorted().map { i in
            var ticks: UInt32?
            if case .timeTicks(let t)? = lastChange[i] { ticks = t }
            let d = descr[i]?.stringValue ?? ""
            return SNMPInterface(index: i,
                                 name: name[i]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? d,
                                 descr: d,
                                 alias: alias[i]?.stringValue ?? "",
                                 type: type[i]?.intValue.map(Int.init),
                                 adminUp: (admin[i]?.intValue ?? 1) == 1,
                                 operStatus: SNMPOperStatus(rawValue: Int(oper[i]?.intValue ?? 4)) ?? .unknown,
                                 speedMbps: speed[i]?.uint64Value,
                                 lastChangeTicks: ticks,
                                 inErrors: errors[i]?.uint64Value,
                                 inOctets: inOctets[i]?.uint64Value,
                                 outOctets: outOctets[i]?.uint64Value)
        }
    }

    /// Port de pont → ifIndex (dot1dBasePortIfIndex).
    public func bridgePorts() async throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (port, value) in try await intColumn(SNMPOIDs.dot1dBasePortIfIndex) {
            if let i = value.intValue { result[port] = Int(i) }
        }
        return result
    }

    /// Table MAC : Q-BRIDGE (avec le VLAN) si elle existe ; sinon, sur un Cisco, BRIDGE-MIB VLAN par VLAN
    /// (« communauté@vlan ») ; sinon BRIDGE-MIB simple, sans VLAN.
    public func fdb(bridgePorts: [Int: Int]) async throws -> [SNMPFDBEntry] {
        var entries: [SNMPFDBEntry] = []
        let fdbToVLAN = try await vlanByFdbId()
        for bind in try await column(SNMPOIDs.dot1qTpFdbPort) {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.dot1qTpFdbPort), let parsed = SNMPParse.qBridgeIndex(suffix),
                  let port = bind.value.intValue, port > 0 else { continue }
            // L'index est l'identifiant de base de filtrage (fdbId) : le VLAN sur la plupart des switchs,
            // sinon traduit par dot1qVlanFdbId ; une base partagée par plusieurs VLAN ne dit pas le VLAN.
            let vlan: Int?
            if let mapped = fdbToVLAN[parsed.vlan] { vlan = mapped.count == 1 ? mapped.first : nil } else { vlan = parsed.vlan }
            entries.append(SNMPFDBEntry(mac: parsed.mac, vlan: vlan, bridgePort: Int(port), ifIndex: bridgePorts[Int(port)] ?? Int(port)))
        }
        if !entries.isEmpty { return entries }
        entries = try await perVLANBridgeFdb()
        if !entries.isEmpty { return entries }
        return try await bridgeFdb(client: client, bridgePorts: bridgePorts, vlan: nil)
    }

    /// fdbId → VLAN qui l'utilisent (dot1qVlanFdbId) ; vide si la table manque.
    func vlanByFdbId() async throws -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for bind in try await optionalColumn(SNMPOIDs.dot1qVlanFdbId) {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.dot1qVlanFdbId), suffix.count == 2,
                  let fdbId = bind.value.intValue else { continue }
            result[Int(fdbId), default: []].insert(Int(suffix[1]))
        }
        return result
    }

    private func bridgeFdb(client: SNMPClient, bridgePorts: [Int: Int], vlan: Int?) async throws -> [SNMPFDBEntry] {
        var entries: [SNMPFDBEntry] = []
        let binds: [SNMPVarBind]
        do { binds = try await client.walk(SNMPOIDs.dot1dTpFdbPort) } catch SNMPError.agent { binds = [] }
        for bind in binds {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.dot1dTpFdbPort), let mac = SNMPParse.bridgeIndex(suffix),
                  let port = bind.value.intValue, port > 0 else { continue }
            entries.append(SNMPFDBEntry(mac: mac, vlan: vlan, bridgePort: Int(port), ifIndex: bridgePorts[Int(port)] ?? Int(port)))
        }
        return entries
    }

    /// VLAN actifs d'après CISCO-VTP-MIB (sans les VLAN réservés 1002 à 1005).
    public func vtpVLANs() async throws -> [Int] {
        var result: Set<Int> = []
        for bind in try await column(SNMPOIDs.vtpVlanState) {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.vtpVlanState), suffix.count == 2, bind.value.intValue == 1 else { continue }
            let vlan = Int(suffix[1])
            if vlan >= 1, vlan <= 4094, !(1002...1005).contains(vlan) { result.insert(vlan) }
        }
        return result.sorted()
    }

    /// Cisco : la table BRIDGE-MIB de chaque VLAN se lit avec la communauté « communauté@vlan »
    /// (en SNMP v3, avec le contexte « vlan-N »).
    /// Un VLAN qui ne répond pas est simplement ignoré.
    func perVLANBridgeFdb(limit: Int = 256) async throws -> [SNMPFDBEntry] {
        let vlans = try await vtpVLANs()
        guard !vlans.isEmpty else { return [] }
        var entries: [SNMPFDBEntry] = []
        var answered = false
        var silent = 0
        for vlan in vlans.prefix(limit) {
            try Task.checkCancellation()
            // v2c : « communauté@vlan » ; v3 : contexte « vlan-N » (même convention chez Cisco).
            let context = SNMPClient(target: client.target.withContext(vlan: vlan))
            do {
                var ports: [Int: Int] = [:]
                for bind in try await context.walk(SNMPOIDs.dot1dBasePortIfIndex) {
                    if let port = SNMPParse.lastIndex(bind, under: SNMPOIDs.dot1dBasePortIfIndex), let i = bind.value.intValue { ports[port] = Int(i) }
                }
                entries += try await bridgeFdb(client: context, bridgePorts: ports, vlan: vlan)
                answered = true
                silent = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Le premier VLAN muet : l'indexation par communauté n'est pas prise en charge, inutile d'insister.
                if !answered { return [] }
                // Chaque VLAN muet coûte le délai et les renvois : trois de suite, on garde ce qu'on a.
                silent += 1
                if silent >= 3 { break }
            }
        }
        return entries
    }

    /// VLAN d'accès par ifIndex.
    public func pvid(bridgePorts: [Int: Int]) async throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (port, value) in try await intColumn(SNMPOIDs.dot1qPvid) {
            if let vlan = value.intValue { result[bridgePorts[port] ?? port] = Int(vlan) }
        }
        return result
    }

    /// Voisins LLDP, rattachés aux interfaces locales (ifName/ifDescr, sinon ifIndex ou port de pont).
    public func lldpNeighbors(interfaces: [SNMPInterface], bridgePorts: [Int: Int]) async throws -> [SNMPLLDPNeighbor] {
        struct Key: Hashable { var localPort: Int; var remIndex: Int }
        var rows: [Key: SNMPLLDPNeighbor] = [:]
        func visit(_ root: SNMPOID, _ apply: (inout SNMPLLDPNeighbor, SNMPValue) -> Void) async throws {
            for bind in try await column(root) {
                guard let suffix = bind.oid.suffix(after: root), let index = SNMPParse.lldpIndex(suffix) else { continue }
                // Clé composée : remIndex peut dépasser 10 000 sur certains switchs.
                let key = Key(localPort: index.localPort, remIndex: index.remIndex)
                var row = rows[key] ?? SNMPLLDPNeighbor(localPortNum: index.localPort, sysName: "", portID: "")
                apply(&row, bind.value)
                rows[key] = row
            }
        }
        try await visit(SNMPOIDs.lldpRemSysName) { $0.sysName = $1.stringValue ?? "" }
        guard !rows.isEmpty else { return [] }
        try await visit(SNMPOIDs.lldpRemPortId) { $0.portID = SNMPParse.portIDText($1) }
        try await visit(SNMPOIDs.lldpRemPortDesc) { $0.portDescr = $1.stringValue }
        try await visit(SNMPOIDs.lldpRemSysDesc) { $0.sysDescr = $1.stringValue }
        try await visit(SNMPOIDs.lldpRemSysCapEnabled) { row, value in
            if let bytes = value.bytesValue { row.capabilities = SNMPLLDPCapabilities(bits: bytes) }
        }
        var localNames: [Int: String] = [:]
        for (port, value) in try await intColumn(SNMPOIDs.lldpLocPortId) { localNames[port] = SNMPParse.portIDText(value) }
        var localDescr: [Int: String] = [:]
        for (port, value) in try await intColumn(SNMPOIDs.lldpLocPortDesc) { localDescr[port] = value.stringValue }
        return rows.values.map { row in
            var neighbor = row
            neighbor.ifIndex = SNMPSwitchPoller.resolveLocalPort(row.localPortNum, localID: localNames[row.localPortNum],
                                                                 localDescr: localDescr[row.localPortNum],
                                                                 interfaces: interfaces, bridgePorts: bridgePorts)
            return neighbor
        }
        .sorted { ($0.ifIndex ?? $0.localPortNum) < ($1.ifIndex ?? $1.localPortNum) }
    }

    /// Correspondance lldpLocPortNum → ifIndex (elle varie selon le constructeur).
    public static func resolveLocalPort(_ port: Int, localID: String?, localDescr: String?, interfaces: [SNMPInterface],
                                        bridgePorts: [Int: Int]) -> Int? {
        for text in [localID, localDescr].compactMap({ $0?.lowercased() }) where !text.isEmpty {
            if let match = interfaces.first(where: { $0.name.lowercased() == text || $0.descr.lowercased() == text }) {
                return match.index
            }
        }
        if let i = bridgePorts[port], interfaces.contains(where: { $0.index == i }) { return i }
        if interfaces.contains(where: { $0.index == port }) { return port }
        return nil
    }

    /// PoE : détail par port (état, classe, priorité, watts Cisco ou HPE), ports qui délivrent du
    /// courant, budget et consommation du premier bloc d'alimentation.
    public func poe(interfaces: [SNMPInterface], brand: String? = nil)
        async throws -> (ports: Set<Int>, budget: Int?, used: Int?, details: [SNMPPoEPort]) {
        var columns = SNMPPoEParser.Columns()
        columns.detection = try await column(SNMPOIDs.pethPsePortDetectionStatus)
        if !columns.detection.isEmpty {
            columns.adminEnable = try await optionalColumn(SNMPOIDs.pethPsePortAdminEnable)
            columns.classification = try await optionalColumn(SNMPOIDs.pethPsePortPowerClassifications)
            columns.priority = try await optionalColumn(SNMPOIDs.pethPsePortPowerPriority)
            // Watts par port : seulement sur les marques qui les publient (une table absente coûte un délai).
            switch brand {
            case "Cisco":
                columns.ciscoConsumption = try await optionalColumn(SNMPOIDs.cpeExtPsePortPwrConsumption)
                columns.ciscoAllocated = try await optionalColumn(SNMPOIDs.cpeExtPsePortPwrAllocated)
            case "HP", "HPE", "Aruba":
                columns.hpePower = try await optionalColumn(SNMPOIDs.hpicfPoePethPsePortPower)
            default:
                break
            }
        }
        columns.mainPower = try await column(SNMPOIDs.pethMainPsePower)
        columns.mainConsumption = try await column(SNMPOIDs.pethMainPseConsumptionPower)
        columns.mainOperStatus = try await optionalColumn(SNMPOIDs.pethMainPseOperStatus)
        let details = SNMPPoEParser.ports(columns, interfaces: interfaces)
        let main = SNMPPoEParser.main(columns)
        let ports = Set(details.filter(\.isDelivering).compactMap(\.ifIndex))
        return (ports, main?.budgetW, main?.usedW, details)
    }

    /// Table ARP du switch (MAC → IP).
    public func arp() async throws -> [MACAddress: IPv4Address] {
        var result: [MACAddress: IPv4Address] = [:]
        for (ip, mac) in try await arpTable().sorted(by: { $0.key > $1.key }) { result[mac] = ip }
        return result
    }

    /// Table ARP (IP → MAC) : ipNetToMediaTable, complétée par ipNetToPhysicalTable (RFC 4293),
    /// seule présente sur certains équipements récents.
    public func arpTable() async throws -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        for bind in try await column(SNMPOIDs.ipNetToMediaPhysAddress) {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.ipNetToMediaPhysAddress), let index = SNMPParse.arpIndex(suffix),
                  let mac = SNMPParse.arpMAC(bind.value) else { continue }
            result[index.ip] = mac
        }
        for bind in try await optionalColumn(SNMPOIDs.ipNetToPhysicalPhysAddress) {
            guard let suffix = bind.oid.suffix(after: SNMPOIDs.ipNetToPhysicalPhysAddress), let index = SNMPParse.arpPhysicalIndex(suffix),
                  let mac = SNMPParse.arpMAC(bind.value), result[index.ip] == nil else { continue }
            result[index.ip] = mac
        }
        return result
    }

    /// Relevé complet. `readHardware` faux : la fiche matériel (ENTITY-MIB, qui ne change pas d'un
    /// relevé à l'autre) n'est pas relue, `previousHardware` est recopiée.
    public func snapshot(readHardware: Bool = true, previousHardware: SNMPHardwareInfo? = nil) async throws -> SNMPSwitchSnapshot {
        let system = try await system()
        let interfaces = try await interfaces()
        let bridge = try await bridgePorts()
        let fdb = try await fdb(bridgePorts: bridge)
        let pvid = try await pvid(bridgePorts: bridge)
        let neighbors = try await lldpNeighbors(interfaces: interfaces, bridgePorts: bridge)
        let poe = try await poe(interfaces: interfaces, brand: system.brand)
        let arp = try await arp()
        var snapshot = SNMPSwitchSnapshot(host: client.target.host, system: system, interfaces: interfaces, fdb: fdb, neighbors: neighbors,
                                          pvid: pvid, poePorts: poe.ports, poeBudgetW: poe.budget, poeUsedW: poe.used,
                                          poeDetails: poe.details, arp: arp)
        // Note 60 : fiche matériel (ENTITY-MIB facultative : une erreur donne seulement sysDescr).
        snapshot.hardware = readHardware ? try await SNMPHardwareReader.read(client: client, system: system) : previousHardware
        return snapshot
    }
}
