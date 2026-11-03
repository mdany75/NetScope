import Darwin
import Foundation

/// Nom d'un hôte à partir de son adresse.
public protocol ScanNameResolving: Sendable {
    func name(for ip: IPv4Address, timeout: Duration) async -> String?
}

/// Résolveur qui sait dire d'où vient le nom (et, pour NetBIOS, le groupe et la MAC annoncée).
public protocol ScanNameDetailResolving: ScanNameResolving {
    func details(for ip: IPv4Address, timeout: Duration) async -> NameDetails
}

extension NameResolverChain: ScanNameDetailResolving {}

/// DNS inverse par getnameinfo (NI_NAMEREQD), abandonné après le délai. Les noms mDNS et
/// NetBIOS passent par `NameResolverChain`, qui l'utilise en premier.
public struct ScanReverseDNS: ScanNameDetailResolving {
    public func details(for ip: IPv4Address, timeout: Duration) async -> NameDetails {
        let name = await self.name(for: ip, timeout: timeout)
        return NameDetails(hostname: name, source: name == nil ? nil : .dns, dnsName: name)
    }

    /// File des délais, distincte des files globales : si beaucoup de getnameinfo bloquent les
    /// fils globaux, les délais tombent quand même à l'heure.
    private static let timerQueue = DispatchQueue(label: "netscope.rdns.timer")

    /// getnameinfo bloque un fil jusqu'à la réponse du DNS, même après le délai : au plus 8 à la fois,
    /// sur une file à part, pour ne jamais épuiser les fils GCD partagés (sondes, minuteries, sockets)
    /// quand le DNS ne répond pas aux requêtes PTR.
    private static let lookupQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "netscope.rdns.lookup"
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .utility
        return queue
    }()

    public init() {}

    public func name(for ip: IPv4Address, timeout: Duration = .seconds(2)) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            // getnameinfo est bloquant : il tourne à part ; s'il dépasse le délai, son résultat est ignoré.
            ScanReverseDNS.lookupQueue.addOperation {
                // Délai déjà écoulé pendant l'attente dans la file : inutile d'interroger le DNS.
                guard !once.isClaimed else { return }
                let name = ScanReverseDNS.lookup(ip)
                if once.claim() { continuation.resume(returning: name) }
            }
            ScanReverseDNS.timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(timeout.scanNanoseconds, UInt64(Int.max))))) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func lookup(_ ip: IPv4Address) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = ip.value.bigEndian
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        return clean(String(cString: host), for: ip)
    }

    /// Retire le point final ; rejette une réponse qui ne fait que répéter l'adresse.
    static func clean(_ name: String, for ip: IPv4Address) -> String? {
        var result = name.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix(".") { result.removeLast() }
        if result.isEmpty || result == ip.description { return nil }
        return result
    }
}

/// Résolveur qui ne trouve rien (profil sans résolution de noms, tests).
public struct ScanNoNames: ScanNameResolving {
    public init() {}
    public func name(for ip: IPv4Address, timeout: Duration) async -> String? { nil }
}
