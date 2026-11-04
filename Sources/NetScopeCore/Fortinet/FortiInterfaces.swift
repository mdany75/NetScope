import Foundation

// Note 25 : sous-réseaux des interfaces de la FortiGate, proposés au « Tester » comme plages
// couvertes. Lecture tolérante de /api/v2/cmdb/system/interface (« ip »: « a.b.c.d m.m.m.m ») et
// de /api/v2/monitor/system/interface (« ip » et « mask » à part, dictionnaire par nom).

/// Sous-réseau d'une interface de la FortiGate.
public struct FortiInterfaceSubnet: Hashable, Sendable, Identifiable {
    /// Nom de l'interface (« internal », « vlan30 », « fortilink »), suivi de « (secondaire) » pour
    /// une adresse secondaire.
    public var name: String
    public var alias: String?
    public var address: IPv4Address
    public var subnet: Subnet
    /// Interface FortiLink (réseau des FortiSwitch, 10.255.1.0/24 par défaut).
    public var isFortiLink: Bool
    /// Rôle donné sur la FortiGate (« lan », « wan », « dmz »), si connu.
    public var role: String?
    /// Type (« physical », « vlan », « aggregate », « tunnel »), si connu.
    public var type: String?

    public init(name: String, alias: String? = nil, address: IPv4Address, subnet: Subnet, isFortiLink: Bool = false,
                role: String? = nil, type: String? = nil) {
        self.name = name
        self.alias = alias
        self.address = address
        self.subnet = subnet
        self.isFortiLink = isFortiLink
        self.role = role
        self.type = type
    }

    public var id: String { "\(name)|\(subnet)" }

    /// Coché par défaut au « Tester » : réseau privé, ni FortiLink ni interface WAN.
    public var isSuggested: Bool {
        guard !isFortiLink, subnet.isPrivate else { return false }
        return role?.lowercased() != "wan"
    }

    /// « vlan30 · Quais » ou « internal ».
    public var label: String {
        if let alias, !alias.isEmpty, alias != name { return "\(name) · \(alias)" }
        return name
    }
}

public extension FortiPaths {
    static let interfacesConfig = "/api/v2/cmdb/system/interface"
    static let interfacesMonitor = "/api/v2/monitor/system/interface"
}

public extension FortiParsers {
    /// Sous-réseaux des interfaces ; nil si le corps n'est pas du JSON. Les interfaces sans adresse,
    /// la boucle locale, les adresses /32 (tunnels) et le lien local 169.254/16 sont ignorés ; un même
    /// sous-réseau n'apparaît qu'une fois.
    static func interfaceSubnets(_ data: Data) -> [FortiInterfaceSubnet]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [FortiInterfaceSubnet] = []
        var seen = Set<Subnet>()
        func add(_ item: FortiObject, name: String, ip: Any?, mask: Any?, secondary: Bool) {
            guard let (address, prefix) = FortiParse.addressAndPrefix(ip, mask: mask) else { return }
            guard prefix >= 1, prefix <= 30, address.value != 0 else { return }
            let first = address.octets.0
            guard first != 127, !(first == 169 && address.octets.1 == 254), first < 224 else { return }
            let type = item.string("type")?.lowercased()
            if type == "loopback" { return }
            let subnet = Subnet(address: address, prefix: prefix)
            guard seen.insert(subnet).inserted else { return }
            let fortilink = (item.bool("fortilink", "is_fortilink", "fortilink_enabled") ?? false)
                || name.lowercased().contains("fortilink") || type == "fortilink"
            result.append(FortiInterfaceSubnet(name: secondary ? "\(name) (secondaire)" : name,
                                               alias: item.string("alias", "description"), address: address, subnet: subnet,
                                               isFortiLink: fortilink, role: item.string("role"), type: type))
        }
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            let name = item.string("name", "_key", "interface") ?? "interface"
            add(item, name: name, ip: item.any("ip", "ipv4", "ip_address", "ipv4_address", "address"),
                mask: item.any("mask", "netmask", "cidr_netmask", "prefix", "prefix_length"), secondary: false)
            // Monitor 7.x : « ipv4_addresses »: [{ "ip": …, "cidr_netmask": 24 }].
            for extra in item.list("ipv4_addresses", "ipv4-addresses") {
                add(item, name: name, ip: extra.any("ip", "address"), mask: extra.any("cidr_netmask", "netmask", "mask"), secondary: false)
            }
            // cmdb : adresses secondaires (« secondaryip »: [{ "ip": "a.b.c.d m.m.m.m" }]).
            for extra in item.list("secondaryip", "secondary-ip", "secondary_ip") {
                add(item, name: name, ip: extra.any("ip", "address"), mask: extra.any("mask", "netmask"), secondary: true)
            }
        }
        return result
    }
}

public extension FortiParse {
    /// « 10.0.0.1 255.255.255.0 », « 10.0.0.1/24 », « 10.0.0.1/255.255.255.0 », ou l'adresse seule
    /// avec un masque à part (24, « 24 », « 255.255.255.0 »).
    static func addressAndPrefix(_ ip: Any?, mask: Any?) -> (IPv4Address, Int)? {
        guard let text = FortiJSON.string(ip) else { return nil }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        guard let first = parts.first, let address = IPv4Address(first) else { return nil }
        func prefix(_ value: Any?) -> Int? {
            if let n = FortiJSON.int(value), (0...32).contains(n), !(FortiJSON.string(value)?.contains(".") ?? false) { return n }
            if let s = FortiJSON.string(value) {
                if let n = Int(s), (0...32).contains(n) { return n }
                if let m = IPv4Address(s) { return m.prefixLength }
            }
            return nil
        }
        if parts.count >= 2, let p = prefix(parts[1]) { return (address, p) }
        if let p = prefix(mask) { return (address, p) }
        return nil
    }
}

public extension FortiGateReader {
    /// Sous-réseaux des interfaces (pour proposer les plages couvertes) : la configuration
    /// (cmdb, droit « Network » en lecture), sinon l'état (monitor). Lecture seule, GET.
    func interfaces() async throws -> (subnets: [FortiInterfaceSubnet], calls: [FortiCallRecord]) {
        var calls: [FortiCallRecord] = []
        let config = try await fetch(FortiPaths.interfacesConfig)
        calls.append(config.record)
        if config.error == nil, let body = config.response?.body, let list = FortiParsers.interfaceSubnets(body), !list.isEmpty {
            return (list, calls)
        }
        let monitor = try await fetch(FortiPaths.interfacesMonitor)
        calls.append(monitor.record)
        if monitor.error == nil, let body = monitor.response?.body, let list = FortiParsers.interfaceSubnets(body) {
            return (list, calls)
        }
        return ([], calls)
    }
}
