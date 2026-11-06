import Darwin
import Foundation

// IPv6 (0.31.0) : voisins IPv6 lus dans la table NDP du système (sysctl, aucun paquet),
// rattachés aux appareils par leur MAC, et adresses IPv6 de ce Mac (getifaddrs).

/// Un voisin IPv6 de la table NDP.
public struct IPv6Neighbor: Hashable, Sendable, Identifiable {
    public var address: IPv6Address
    public var mac: MACAddress
    /// Index de l'interface (0 : inconnu).
    public var interfaceIndex: Int
    /// Nom BSD (« en0 ») quand il est connu.
    public var interfaceName: String?
    /// Vrai si le voisin est un routeur (annonce RA vue par le système).
    public var isRouter: Bool

    public var id: String { address.description + "|" + mac.description }

    public init(address: IPv6Address, mac: MACAddress, interfaceIndex: Int = 0, interfaceName: String? = nil, isRouter: Bool = false) {
        self.address = address
        self.mac = mac
        self.interfaceIndex = interfaceIndex
        self.interfaceName = interfaceName
        self.isRouter = isRouter
    }
}

/// Lecture de la table des voisins IPv6.
public protocol IPv6NeighborReading: Sendable {
    func read() -> [IPv6Neighbor]
}

/// Table NDP : sysctl(CTL_NET, PF_ROUTE, 0, AF_INET6, NET_RT_FLAGS, RTF_LLINFO).
public struct NDPTable: IPv6NeighborReading {
    public init() {}

    public func read() -> [IPv6Neighbor] {
        guard let buffer = ScanRouting.dump(flags: RTF_LLINFO, family: AF_INET6) else { return [] }
        let own = Set(LocalIPv6.addresses().map(\.address))
        return NDPTable.parse(buffer).filter { !own.contains($0.address) }.map { neighbor in
            var copy = neighbor
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            if neighbor.interfaceIndex > 0, if_indextoname(UInt32(neighbor.interfaceIndex), &name) != nil {
                copy.interfaceName = String(cString: name)
            }
            return copy
        }
    }

    /// Adresse d'une sockaddr_in6 brute (28 octets : longueur, famille, port, flowinfo, adresse
    /// à l'octet 8). Pour le lien local, le noyau range l'index d'interface dans les octets 2 et 3
    /// (héritage KAME) : ils sont remis à zéro.
    static func ipv6(_ raw: [UInt8]?) -> IPv6Address? {
        guard let raw, raw.count >= 24, raw[1] == UInt8(AF_INET6) else { return nil }
        var bytes = Array(raw[8..<24])
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            bytes[2] = 0
            bytes[3] = 0
        }
        return IPv6Address(bytes: bytes)
    }

    /// Lit un tampon sysctl : destination sockaddr_in6, passerelle sockaddr_dl. Les entrées sans
    /// adresse matérielle (incomplètes), multicast ou de diffusion sont ignorées ; une MAC vue
    /// plusieurs fois garde toutes ses adresses (lien local, ULA, globales, temporaires).
    public static func parse(_ buffer: [UInt8]) -> [IPv6Neighbor] {
        var seen = Set<IPv6Address>()
        var result: [IPv6Neighbor] = []
        for message in ScanRouting.messages(buffer) {
            guard let address = ipv6(message.addresses[Int(RTAX_DST)]),
                  address.scope != .multicast, address.scope != .unspecified, address.scope != .loopback,
                  let mac = ScanRouteMessage.link(message.addresses[Int(RTAX_GATEWAY)]),
                  mac.value != 0, !mac.isBroadcast, !mac.isMulticast,
                  seen.insert(address).inserted else { continue }
            result.append(IPv6Neighbor(address: address, mac: mac, interfaceIndex: Int(message.interfaceIndex),
                                       isRouter: message.flags & RTF_ROUTER != 0))
        }
        return result.sorted { $0.mac != $1.mac ? $0.mac < $1.mac : IPv6Address.displayOrder($0.address, $1.address) }
    }

    /// Repli de lecture : sortie de « ndp -an » (« fe80::1%en0  4:d5:90:3a:7b:11  en0 23h59m58s S R »).
    public static func parseCommandOutput(_ text: String) -> [IPv6Neighbor] {
        var result: [IPv6Neighbor] = []
        var seen = Set<IPv6Address>()
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3, let (address, _) = IPv6Address.parseZoned(tokens[0]),
                  address.scope != .multicast, let mac = MACAddress(tokens[1]),
                  mac.value != 0, !mac.isMulticast, seen.insert(address).inserted else { continue }
            let flags = tokens.count > 4 ? tokens[4...].joined(separator: " ") : ""
            result.append(IPv6Neighbor(address: address, mac: mac, interfaceName: tokens[2],
                                       isRouter: flags.split(separator: " ").contains("R")))
        }
        return result
    }
}

/// Rattachement des voisins IPv6 aux appareils IPv4, par la MAC.
public enum IPv6Attachment {
    /// Adresses IPv6 de chaque MAC, triées (lien local, ULA, globales).
    public static func addressesByMAC(_ neighbors: [IPv6Neighbor]) -> [MACAddress: [IPv6Address]] {
        var table: [MACAddress: [IPv6Address]] = [:]
        for neighbor in neighbors { table[neighbor.mac, default: []].append(neighbor.address) }
        return table.mapValues { Array(Set($0)).sorted(by: IPv6Address.displayOrder) }
    }

    /// Appareils complétés : les adresses IPv6 lues s'ajoutent à celles déjà connues (une adresse
    /// temporaire disparue de la table reste jusqu'au prochain scan complet). Rend le nombre
    /// d'appareils modifiés.
    @discardableResult
    public static func attach(_ neighbors: [IPv6Neighbor], to devices: inout [Device]) -> Int {
        let table = addressesByMAC(neighbors)
        var changed = 0
        for index in devices.indices {
            guard let mac = devices[index].mac, let found = table[mac] else { continue }
            let merged = Array(Set((devices[index].ipv6 ?? []) + found)).sorted(by: IPv6Address.displayOrder)
            if merged != devices[index].ipv6 {
                devices[index].ipv6 = merged
                changed += 1
            }
        }
        return changed
    }

    /// Voisins sans appareil IPv4 connu (MAC jamais vue par le scan) : appareils IPv6 seulement.
    public static func unmatched(_ neighbors: [IPv6Neighbor], devices: [Device]) -> [IPv6Neighbor] {
        let known = Set(devices.compactMap(\.mac))
        return neighbors.filter { !known.contains($0.mac) }
    }
}

/// Une adresse IPv6 de ce Mac.
public struct LocalIPv6Address: Hashable, Sendable {
    public var interface: String
    public var address: IPv6Address
    public var prefixLength: Int

    public init(interface: String, address: IPv6Address, prefixLength: Int) {
        self.interface = interface
        self.address = address
        self.prefixLength = prefixLength
    }

    /// « 2001:db8:a00:10::5/64 ».
    public var cidr: String { "\(address)/\(prefixLength)" }
}

/// État IPv6 de ce Mac sur l'interface active (bas de la barre latérale).
public struct IPv6HostStatus: Equatable, Sendable {
    public enum Level: Int, Sendable {
        case none, linkOnly, localOnly, global

        public var label: String {
            switch self {
            case .none: return "absente"
            case .linkOnly: return "lien local seulement"
            case .localOnly: return "ULA seulement"
            case .global: return "globale"
            }
        }
    }

    public var interface: String?
    /// Adresses de l'interface, triées (lien local, ULA, globales).
    public var addresses: [LocalIPv6Address]

    public init(interface: String?, addresses: [LocalIPv6Address]) {
        self.interface = interface
        self.addresses = addresses
            .filter { interface == nil || $0.interface == interface }
            .sorted { IPv6Address.displayOrder($0.address, $1.address) }
    }

    public var level: Level {
        let scopes = Set(addresses.map(\.address.scope))
        if scopes.contains(.global) || scopes.contains(.documentation) { return .global }
        if scopes.contains(.uniqueLocal) { return .localOnly }
        if scopes.contains(.linkLocal) { return .linkOnly }
        return .none
    }

    /// Adresse la plus utile à montrer : globale, sinon ULA, sinon lien local.
    public var mainAddress: IPv6Address? {
        addresses.map(\.address).max { lhs, rhs in rank(lhs) < rank(rhs) }
    }

    private func rank(_ address: IPv6Address) -> Int {
        switch address.scope {
        case .global, .documentation: return 3
        case .uniqueLocal: return 2
        case .linkLocal: return 1
        default: return 0
        }
    }

    /// Préfixe /64 annoncé (globale ou ULA), s'il y en a un.
    public var routedPrefix: IPv6Prefix? {
        addresses.first { $0.address.scope != .linkLocal }.map { IPv6Prefix(address: $0.address, length: $0.prefixLength) }
    }

    /// « IPv6 globale · 2 adresses » ou « IPv6 absente ».
    public var summary: String {
        let count = addresses.count
        guard count > 0 else { return "IPv6 absente" }
        return "IPv6 \(level.label) · \(count) adresse\(count > 1 ? "s" : "")"
    }
}

public enum LocalIPv6 {
    /// Adresses IPv6 des interfaces actives (hors bouclage et tunnels), lues avec getifaddrs.
    public static func addresses() -> [LocalIPv6Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [LocalIPv6Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let raw = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(addr), count: MemoryLayout<sockaddr_in6>.size))
            guard let address = NDPTable.ipv6(raw) else { continue }
            var prefix = 64
            if let mask = entry.ifa_netmask {
                let maskRaw = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(mask), count: MemoryLayout<sockaddr_in6>.size))
                prefix = maskRaw[8..<24].reduce(0) { $0 + $1.nonzeroBitCount }
            }
            result.append(LocalIPv6Address(interface: name, address: address, prefixLength: prefix))
        }
        return result
    }

    /// État IPv6 de l'interface donnée (toutes si nil).
    public static func status(interface: String?) -> IPv6HostStatus {
        IPv6HostStatus(interface: interface, addresses: addresses())
    }
}
