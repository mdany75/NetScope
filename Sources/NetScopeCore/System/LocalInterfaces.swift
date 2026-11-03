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
}
