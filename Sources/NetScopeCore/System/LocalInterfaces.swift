import Darwin
import Foundation
import Network

/// Interface réseau locale avec une adresse IPv4 (lue avec getifaddrs : aucune requête réseau).
public struct LocalInterface: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case wifi, ethernet, autre

        public var label: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .autre: return "Autre"
            }
        }
    }

    /// Nom BSD (« en0 »).
    public var name: String
    public var address: IPv4Address
    public var netmask: IPv4Address
    public var kind: Kind
    public var gateway: IPv4Address?

    public init(name: String, address: IPv4Address, netmask: IPv4Address, kind: Kind = .autre, gateway: IPv4Address? = nil) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.kind = kind
        self.gateway = gateway
    }

    /// Réseau de l'interface (10.182.122.0/24) ; masque non contigu traité comme /32.
    public var subnet: Subnet {
        Subnet(address: address, prefix: netmask.prefixLength ?? 32)
    }

    /// « en0 · 10.182.122.135 · Wi-Fi »
    public var summary: String { "\(name) · \(address) · \(kind.label)" }

    /// Vrai si l'interface a une adresse IPv4 (0.0.0.0 : interface active sans adresse,
    /// donnée seulement par `LocalInterfaces.linkInterfaces()`).
    public var hasIPv4: Bool { address.value != 0 }

    /// Adresse pour un sélecteur : « 10.182.122.142 », « 169.254.12.7 (liaison locale) » ou « sans adresse ».
    public var addressLabel: String {
        guard hasIPv4 else { return "sans adresse" }
        return AddressScope.of(address) == .liaisonLocale ? "\(address) (liaison locale)" : address.description
    }

    /// « en0 · Wi-Fi » si l'interface a une adresse routable, sinon « en7 · Ethernet · sans adresse »
    /// ou « en7 · Ethernet · 169.254.12.7 (liaison locale) » : on voit tout de suite qu'il n'y a pas de bail.
    public var linkSummary: String {
        if hasIPv4, AddressScope.of(address) != .liaisonLocale { return "\(name) · \(kind.label)" }
        return "\(name) · \(kind.label) · \(addressLabel)"
    }
}

public enum LocalInterfaces {
    /// Interfaces actives avec une adresse IPv4, hors bouclage, liaison locale et tunnels.
    /// L'ordre favorise en0, puis les autres en*.
    public static func list() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let address = ipv4(addr)
            guard AddressScope.of(address) != .liaisonLocale else { continue }
            result.append(LocalInterface(name: name, address: address, netmask: ipv4(mask)))
        }
        return result.sorted { lhs, rhs in
            let l = lhs.name == "en0" ? 0 : (lhs.name.hasPrefix("en") ? 1 : 2)
            let r = rhs.name == "en0" ? 0 : (rhs.name.hasPrefix("en") ? 1 : 2)
            return l != r ? l < r : lhs.name < rhs.name
        }
    }

    /// Interfaces câblées ou Wi-Fi actives (en*, bridge*) pour les outils de couche 2 (capture
    /// LLDP/CDP, test DHCP), même sans adresse IPv4 ou avec une adresse de liaison locale :
    /// c'est justement le cas d'un poste qui n'a pas reçu de bail. Lecture locale (getifaddrs et
    /// SIOCGIFMEDIA), aucun trafic. Une interface en* dont le lien est inactif est écartée ;
    /// une interface bridge* n'est gardée que si elle a une adresse IPv4.
    public static func linkInterfaces() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var linked: [String] = []
        var addresses: [String: (address: IPv4Address, netmask: IPv4Address)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            if addr.pointee.sa_family == UInt8(AF_LINK) {
                if !linked.contains(name) { linked.append(name) }
            } else if addr.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask {
                let address = ipv4(addr)
                // Une adresse routable l'emporte sur une adresse de liaison locale.
                if let known = addresses[name], AddressScope.of(known.address) != .liaisonLocale { continue }
                addresses[name] = (address, ipv4(mask))
            }
        }
        var result: [LocalInterface] = []
        for name in linked {
            let known = addresses[name]
            if name.hasPrefix("bridge"), known == nil { continue }
            if known == nil, mediaIsActive(name) == false { continue }
            result.append(LocalInterface(name: name, address: known?.address ?? IPv4Address(0),
                                         netmask: known?.netmask ?? IPv4Address(0)))
        }
        return sortedForDisplay(result)
    }

    /// `linkInterfaces()` complétées de leur type.
    public static func linkInterfacesWithKinds() async -> [LocalInterface] {
        let kinds = await kinds()
        return linkInterfaces().map { interface in
            var copy = interface
            copy.kind = kinds[interface.name] ?? .autre
            return copy
        }
    }

    /// Interface à proposer par défaut à un outil de couche 2 : Ethernet d'abord, puis une
    /// interface active sans Wi-Fi, puis `preferred`, puis la première.
    public static func preferredLinkInterface(in list: [LocalInterface], preferred: String? = nil) -> LocalInterface? {
        list.first { $0.kind == .ethernet }
            ?? preferred.flatMap { name in list.first { $0.name == name } }
            ?? list.first
    }

    /// Ordre d'affichage : en0, puis les autres en*, puis bridge*.
    static func sortedForDisplay(_ list: [LocalInterface]) -> [LocalInterface] {
        list.sorted { lhs, rhs in
            let l = lhs.name == "en0" ? 0 : (lhs.name.hasPrefix("en") ? 1 : 2)
            let r = rhs.name == "en0" ? 0 : (rhs.name.hasPrefix("en") ? 1 : 2)
            return l != r ? l < r : lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
        }
    }

    /// État du lien lu par SIOCGIFMEDIA (ioctl local) : vrai/faux, ou nil si l'interface ne le donne pas.
    static func mediaIsActive(_ name: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { raw in
            for (i, byte) in name.utf8.prefix(15).enumerated() { raw[i] = byte }
        }
        // SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq) (la macro n'est pas importée en Swift).
        let code: UInt = 0xC000_0000 | ((UInt(MemoryLayout<ifmediareq>.size) & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
        guard ioctl(fd, code, &request) == 0, request.ifm_status & IFM_AVALID != 0 else { return nil }
        return request.ifm_status & IFM_ACTIVE != 0
    }

    /// Interface principale (la première de `list()`).
    public static func primary() -> LocalInterface? { list().first }

    /// Type de chaque interface (Wi-Fi, Ethernet), lu par NWPathMonitor : état local, sans trafic.
    public static func kinds() async -> [String: LocalInterface.Kind] {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "netscope.interfaces")
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                var kinds: [String: LocalInterface.Kind] = [:]
                for interface in path.availableInterfaces {
                    switch interface.type {
                    case .wifi: kinds[interface.name] = .wifi
                    case .wiredEthernet: kinds[interface.name] = .ethernet
                    default: kinds[interface.name] = .autre
                    }
                }
                monitor.cancel()
                continuation.resume(returning: kinds)
            }
            monitor.start(queue: queue)
        }
    }

    /// Dernier changement d'état du lien de chaque interface (`ifi_lastchange` des entrées AF_LINK
    /// de getifaddrs), en microsecondes : une coupure ou un débranchement le fait changer.
    /// Lecture locale, aucun trafic ; la valeur ne sert qu'à être comparée.
    public static func linkStamps() -> [String: UInt64] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var stamps: [String: UInt64] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            let change = data.assumingMemoryBound(to: if_data.self).pointee.ifi_lastchange
            stamps[String(cString: entry.ifa_name)] = UInt64(max(0, Int64(change.tv_sec))) &* 1_000_000 &+ UInt64(max(0, Int64(change.tv_usec)))
        }
        return stamps
    }

    /// Interfaces de `list()` complétées de leur type.
    public static func listWithKinds() async -> [LocalInterface] {
        let kinds = await kinds()
        return list().map { interface in
            var copy = interface
            copy.kind = kinds[interface.name] ?? .autre
            return copy
        }
    }

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> IPv4Address {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            IPv4Address(UInt32(bigEndian: sin.pointee.sin_addr.s_addr))
        }
    }
}

/// Drapeau à usage unique, sûr entre fils d'exécution (la continuation ne reprend qu'une fois).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    /// Vrai si `claim()` a déjà réussi.
    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
