import Foundation

/// Ce que la résolution de noms a trouvé pour une adresse.
public struct NameDetails: Hashable, Sendable {
    /// Origine du nom retenu.
    public enum Source: String, Hashable, Sendable, Codable {
        case dns, mdns, netbios, snmp

        public var label: String {
            switch self {
            case .dns: return "DNS inverse"
            case .mdns: return "mDNS (Bonjour)"
            case .netbios: return "NetBIOS"
            case .snmp: return "SNMP"
            }
        }
    }

    /// Meilleur nom trouvé (« Macmini-de-Dany.local », « DESKTOP-4F2K »…).
    public var hostname: String?
    public var source: Source?
    /// Réponses de chaque méthode (pour l'affichage détaillé).
    public var dnsName: String?
    public var mdnsName: String?
    public var netbiosName: String?
    /// Groupe de travail ou domaine NetBIOS.
    public var netbiosDomain: String?
    /// Adresse MAC annoncée par NetBIOS (utile quand l'ARP ne l'a pas).
    public var netbiosMAC: MACAddress?

    public init(hostname: String? = nil, source: Source? = nil, dnsName: String? = nil, mdnsName: String? = nil,
                netbiosName: String? = nil, netbiosDomain: String? = nil, netbiosMAC: MACAddress? = nil) {
        self.hostname = hostname
        self.source = source
        self.dnsName = dnsName
        self.mdnsName = mdnsName
        self.netbiosName = netbiosName
        self.netbiosDomain = netbiosDomain
        self.netbiosMAC = netbiosMAC
    }

    /// Nom à afficher, sans « .local ».
    public var displayName: String? { hostname.map { NamesFormat.display($0) } }
}

/// Résolution de noms automatique : DNS inverse, mDNS et NetBIOS interrogés en parallèle.
///
/// Priorité : DNS inverse s'il n'est pas un nom générique d'opérateur, sinon mDNS, sinon
/// NetBIOS, sinon le nom DNS générique (mieux que rien).
public struct NameResolverChain: ScanNameResolving {
    public let reverseDNS: (any ScanNameResolving)?
    public let mdns: NamesMDNS?
    public let netbios: NamesNetBIOS?
    /// Délai global maximal, quel que soit le délai demandé.
    public let maxTimeout: Duration

    private static let timerQueue = DispatchQueue(label: "netscope.names.chain.timer")

    public init(reverseDNS: (any ScanNameResolving)? = ScanReverseDNS(), mdns: NamesMDNS? = NamesMDNS(),
                netbios: NamesNetBIOS? = NamesNetBIOS(), maxTimeout: Duration = .milliseconds(1500)) {
        self.reverseDNS = reverseDNS
        self.mdns = mdns
        self.netbios = netbios
        self.maxTimeout = maxTimeout
    }

    /// Meilleur nom ; rend la main dès que les méthodes prioritaires ont répondu.
    public func name(for ip: IPv4Address, timeout: Duration = .milliseconds(1500)) async -> String? {
        await resolve(ip, timeout: timeout, waitForAll: false).hostname
    }

    /// Toutes les réponses (attend chaque méthode, au plus le délai) et le nom retenu avec sa source.
    public func details(for ip: IPv4Address, timeout: Duration = .milliseconds(1500)) async -> NameDetails {
        await resolve(ip, timeout: timeout, waitForAll: true)
    }

    /// Nom générique d'opérateur : contient l'adresse (« 192-168-1-5 », « 5.1.168.192.dyn… »,
    /// « c0a80105 ») ou commence par « ip-12 », « dhcp-12 », « host12 », « pool-12 »…
    public static func isGenericName(_ name: String, for ip: IPv4Address) -> Bool {
        let lower = name.lowercased()
        let o = ip.octets
        let forward = ["\(o.0)", "\(o.1)", "\(o.2)", "\(o.3)"]
        for separator in ["-", ".", "_"] {
            if lower.contains(forward.joined(separator: separator)) { return true }
            if lower.contains(forward.reversed().joined(separator: separator)) { return true }
        }
        if lower.contains(String(format: "%08x", ip.value)) { return true }
        let padded = String(format: "%03d%03d%03d%03d", o.0, o.1, o.2, o.3)
        if lower.contains(padded) { return true }
        let first = lower.split(separator: ".").first.map(String.init) ?? lower
        let prefixes = ["ip", "host", "dhcp", "dyn", "dynamic", "pool", "dsl", "adsl", "cpe", "customer",
                        "client", "static", "unknown", "unassigned", "broadband", "cable"]
        for prefix in prefixes where first.hasPrefix(prefix) {
            var rest = first.dropFirst(prefix.count)
            if let separator = rest.first, "-_".contains(separator) { rest = rest.dropFirst() }
            if let digit = rest.first, digit.isNumber { return true }
        }
        return false
    }

    private func resolve(_ ip: IPv4Address, timeout: Duration, waitForAll: Bool) async -> NameDetails {
        let effective = min(timeout, maxTimeout)
        let reverseDNS = reverseDNS, mdns = mdns, netbios = netbios
        return await withCheckedContinuation { (continuation: CheckedContinuation<NameDetails, Never>) in
            let race = NamesRace(ip: ip, waitForAll: waitForAll) { continuation.resume(returning: $0) }
            if let reverseDNS {
                Task { race.setDNS(await reverseDNS.name(for: ip, timeout: effective)) }
            } else {
                race.setDNS(nil)
            }
            if let mdns {
                Task { race.setMDNS(await mdns.name(for: ip, timeout: effective)) }
            } else {
                race.setMDNS(nil)
            }
            if let netbios {
                Task { race.setNetBIOS(await netbios.status(for: ip, timeout: effective)) }
            } else {
                race.setNetBIOS(nil)
            }
            // Filet de sécurité : rend ce qui est arrivé, même si une méthode dépasse son délai.
            let grace = Int(min((effective + .milliseconds(250)).scanNanoseconds, UInt64(Int.max)))
            Self.timerQueue.asyncAfter(deadline: .now() + .nanoseconds(grace)) { race.finishNow() }
        }
    }
}

/// Réponses des trois méthodes, à mesure qu'elles arrivent ; décide dès que possible.
private final class NamesRace: @unchecked Sendable {
    private enum Slot<Value> {
        case pending
        case done(Value?)

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        var value: Value? {
            if case .done(let value) = self { return value }
            return nil
        }
    }

    private let ip: IPv4Address
    private let waitForAll: Bool
    private let onFinish: (NameDetails) -> Void
    private let lock = NSLock()
    private var finished = false
    private var dns: Slot<String> = .pending
    private var mdns: Slot<String> = .pending
    private var netbios: Slot<NetBIOSNodeStatus> = .pending

    init(ip: IPv4Address, waitForAll: Bool, onFinish: @escaping (NameDetails) -> Void) {
        self.ip = ip
        self.waitForAll = waitForAll
        self.onFinish = onFinish
    }

    func setDNS(_ name: String?) { update { dns = .done(name.flatMap { NamesFormat.clean($0, for: ip) }) } }
    func setMDNS(_ name: String?) { update { mdns = .done(name.flatMap { NamesFormat.clean($0, for: ip) }) } }
    func setNetBIOS(_ status: NetBIOSNodeStatus?) { update { netbios = .done(status) } }

    func finishNow() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let details = makeDetails()
        lock.unlock()
        onFinish(details)
    }

    private func update(_ body: () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        body()
        guard isDecided else {
            lock.unlock()
            return
        }
        finished = true
        let details = makeDetails()
        lock.unlock()
        onFinish(details)
    }

    private var dnsIsGood: Bool {
        guard let name = dns.value else { return false }
        return !NameResolverChain.isGenericName(name, for: ip)
    }

    /// Le résultat ne peut plus changer (ou, pour `details`, tout est arrivé).
    private var isDecided: Bool {
        if waitForAll { return dns.isDone && mdns.isDone && netbios.isDone }
        if dnsIsGood { return true }
        guard dns.isDone else { return false }
        if mdns.value != nil { return true }
        guard mdns.isDone else { return false }
        return netbios.isDone
    }

    private func makeDetails() -> NameDetails {
        let status = netbios.value
        var details = NameDetails(dnsName: dns.value, mdnsName: mdns.value, netbiosName: status?.hostname,
                                  netbiosDomain: status?.domain, netbiosMAC: status?.mac)
        if dnsIsGood, let name = dns.value {
            (details.hostname, details.source) = (name, .dns)
        } else if let name = mdns.value {
            (details.hostname, details.source) = (name, .mdns)
        } else if let name = status?.hostname {
            (details.hostname, details.source) = (name, .netbios)
        } else if let name = dns.value {
            (details.hostname, details.source) = (name, .dns)
        }
        return details
    }
}
