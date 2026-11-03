import Darwin
import Foundation

/// Réseau local : interfaces, passerelle par défaut, serveurs DNS et plage suggérée.
/// Tout est lu sur la machine (getifaddrs, table de routage, resolv.conf) : aucun trafic.
public enum ScanNetwork {
    /// Plage proposée par « Détecter mon réseau ».
    public struct Suggestion: Hashable, Sendable {
        public var interface: LocalInterface
        public var subnet: Subnet
        /// Libellé proposé pour la plage (« Wi-Fi », « Réseau local »).
        public var label: String
    }

    /// Passerelle par défaut : route 0.0.0.0/0 de la table de routage, repli sur « route -n get default ».
    public static func defaultGateway() -> IPv4Address? {
        if let buffer = ScanRouting.dump(flags: RTF_GATEWAY), let gateway = parseDefaultGateway(buffer) {
            return gateway
        }
        guard let output = ScanShell.run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        return parseRouteGetOutput(output)
    }

    /// Route par défaut d'un tampon sysctl. Les routes propres à une interface (RTF_IFSCOPE)
    /// ne sont retenues qu'à défaut d'une route générale.
    static func parseDefaultGateway(_ buffer: [UInt8]) -> IPv4Address? {
        var scoped: IPv4Address?
        for message in ScanRouting.messages(buffer) where message.flags & RTF_UP != 0 && message.flags & RTF_GATEWAY != 0 {
            guard let destination = ScanRouteMessage.ipv4(message.addresses[Int(RTAX_DST)]), destination.value == 0,
                  let gateway = ScanRouteMessage.ipv4(message.addresses[Int(RTAX_GATEWAY)]) else { continue }
            // Masque absent ou nul : route par défaut.
            if let mask = message.addresses[Int(RTAX_NETMASK)], mask.count >= 8, mask[4...7].contains(where: { $0 != 0 }) { continue }
            if message.flags & RTF_IFSCOPE != 0 {
                if scoped == nil { scoped = gateway }
            } else {
                return gateway
            }
        }
        return scoped
    }

    /// « gateway: 10.182.122.1 » dans la sortie de « route -n get default ».
    static func parseRouteGetOutput(_ text: String) -> IPv4Address? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "gateway", let ip = IPv4Address(parts[1]) { return ip }
        }
        return nil
    }

    /// Serveurs DNS IPv4 de /etc/resolv.conf.
    public static func dnsServers(path: String = "/etc/resolv.conf") -> [IPv4Address] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parseResolvConf(text)
    }

    static func parseResolvConf(_ text: String) -> [IPv4Address] {
        var servers: [IPv4Address] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver", let ip = IPv4Address(String(fields[1])),
                  !servers.contains(ip) else { continue }
            servers.append(ip)
        }
        return servers
    }

    /// Plage à scanner pour une interface : son réseau, ramené à son /24 s'il dépasse un /16
    /// (limite de sécurité de `IPRange`).
    public static func suggestedSubnet(for interface: LocalInterface) -> Subnet {
        let subnet = interface.subnet
        if subnet.prefix < 16 || subnet.prefix > 30 {
            return Subnet(address: interface.address, prefix: 24)
        }
        return subnet
    }

    /// Plages suggérées pour les interfaces actives (Wi-Fi et Ethernet d'abord), passerelle comprise.
    public static func suggestions() async -> [Suggestion] {
        let gateway = defaultGateway()
        let interfaces = await LocalInterfaces.listWithKinds()
        let ordered = interfaces.filter { $0.kind != .autre } + interfaces.filter { $0.kind == .autre }
        return ordered.map { interface in
            var copy = interface
            if copy.gateway == nil, let gateway, copy.subnet.contains(gateway) { copy.gateway = gateway }
            let label: String
            switch interface.kind {
            case .wifi: label = "Wi-Fi"
            case .ethernet: label = "Ethernet"
            case .autre: label = "Réseau local"
            }
            return Suggestion(interface: copy, subnet: suggestedSubnet(for: interface), label: label)
        }
    }
}
