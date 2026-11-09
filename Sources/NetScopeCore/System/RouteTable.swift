import Darwin
import Foundation

// Note 119 : table de routage de ce Mac, en consultation seule.

public enum RouteFamily: String, CaseIterable, Hashable, Sendable {
    case ipv4 = "IPv4", ipv6 = "IPv6"
}

public enum RouteScope: String, Hashable, Sendable {
    case host = "Hôte", network = "Réseau", multicast = "Multicast", linkLocal = "Lien local"
}

public enum RouteMask: Hashable, Sendable {
    case prefix(Int)
    /// Masque non contigu, que seul un préfixe ne peut pas décrire (« 0xffff00ff »).
    case noncontiguous(String)
}

public enum RouteGateway: Hashable, Sendable {
    /// Adresse IP, avec sa zone éventuelle (« fe80::1%en0 »).
    case address(String)
    /// Réseau directement raccordé à l'interface numéro N (« link#8 »).
    case link(Int)
    case mac(MACAddress)

    public var text: String {
        switch self {
        case let .address(text): return text
        case let .link(index): return "link#\(index)"
        case let .mac(mac): return mac.description
        }
    }
}

public enum RouteExpiry: Hashable, Sendable {
    case seconds(Int)
    /// Délai écoulé (« ! » de netstat).
    case elapsed
}

public struct RouteEntry: Hashable, Sendable {
    public let family: RouteFamily
    /// Adresse complète, sans zone ni préfixe (« 192.168.1.0 », « fe80:: »).
    public let destination: String
    public let mask: RouteMask
    public let gateway: RouteGateway
    public let rawFlags: String
    public let flags: [String]
    public let interface: String
    public let expiry: RouteExpiry?
    public let isDefault: Bool
    public let scope: RouteScope
    /// Tri numérique : famille, octets de l'adresse, puis préfixe. Que des chiffres de largeur
    /// fixe : les tableaux comparent en `localizedStandard`, qui lirait mal de l'hexadécimal.
    public let sortKey: String

    /// Une route par défaut sans « I » est celle que le système utilise ; les autres sont
    /// réservées à leur interface.
    public var isPrimaryDefault: Bool { isDefault && !rawFlags.contains("I") }

    /// « 192.168.1.0/24 » ; une adresse seule pour un hôte.
    public var destinationText: String {
        switch mask {
        case let .prefix(length):
            return scope == .host || length == (family == .ipv4 ? 32 : 128) ? destination : "\(destination)/\(length)"
        case let .noncontiguous(mask):
            return "\(destination)&\(mask)"
        }
    }

    /// « active » vaut pour presque toutes les routes : il ne reste que s'il est seul.
    public var flagsText: String {
        let telling = flags.filter { $0 != "active" }
        return (telling.isEmpty ? flags : telling).joined(separator: " · ")
    }

    /// Chaque mot de la recherche doit se retrouver dans la destination, la passerelle,
    /// l'interface, la portée ou les drapeaux traduits.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = [destinationText, gateway.text, interface, scope.rawValue, flagsText, isDefault ? "default défaut" : ""]
            .joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

public enum RouteTable {
    /// Lit la table du système ; nil si netstat n'a pas pu s'exécuter.
    /// `-n` est indispensable : sans lui, netstat ferait des résolutions DNS inverses.
    public static func readLocal() -> [RouteEntry]? {
        ScanShell.run("/usr/sbin/netstat", ["-rn"]).map(parse(netstat:))
    }

    /// Analyse la sortie de « netstat -rn ». Les colonnes viennent de l'en-tête de chaque section,
    /// car elles changent selon la version de macOS (Refs et Use ont disparu) ; Expire, vide sur
    /// la plupart des lignes, ferme la marche. Toute ligne illisible est ignorée.
    public static func parse(netstat text: String) -> [RouteEntry] {
        var family: RouteFamily?
        var columns: [String] = []
        var entries: [RouteEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }
            if tokens.count == 1, first.hasSuffix(":") {
                family = first == "Internet:" ? .ipv4 : first == "Internet6:" ? .ipv6 : nil
                columns = []
            } else if first == "Destination" {
                columns = tokens
            } else if let family {
                let fields = Dictionary(zip(columns, tokens), uniquingKeysWith: { current, _ in current })
                if let entry = entry(family: family, fields: fields) { entries.append(entry) }
            }
        }
        return entries
    }

    private static func entry(family: RouteFamily, fields: [String: String]) -> RouteEntry? {
        guard let rawDestination = fields["Destination"], let rawGateway = fields["Gateway"],
              let rawFlags = fields["Flags"], let interface = fields["Netif"],
              let target = target(rawDestination, family: family, isHost: rawFlags.contains("H")) else { return nil }
        return RouteEntry(family: family, destination: address(target.bytes), mask: target.mask,
                          gateway: gateway(rawGateway), rawFlags: rawFlags,
                          flags: rawFlags.map { flagMeanings[$0] ?? "drapeau \($0)" }, interface: interface,
                          expiry: fields["Expire"].flatMap(expiry), isDefault: rawDestination == "default",
                          scope: scope(target.bytes, mask: target.mask, rawFlags: rawFlags),
                          sortKey: sortKey(target.bytes, mask: target.mask))
    }

    // MARK: Destination

    private static func target(_ raw: String, family: RouteFamily, isHost: Bool) -> (bytes: [UInt8], mask: RouteMask)? {
        switch family {
        case .ipv4: return ipv4Target(raw, isHost: isHost)
        case .ipv6: return ipv6Target(raw)
        }
    }

    /// netstat raccourcit les réseaux : « 192.168.1 », « 127 », « 10.8/16 », et n'écrit le préfixe
    /// que s'il diffère de celui de la classe de l'adresse.
    private static func ipv4Target(_ raw: String, isHost: Bool) -> (bytes: [UInt8], mask: RouteMask)? {
        if raw == "default" { return ([0, 0, 0, 0], .prefix(0)) }
        var text = Substring(raw)
        var explicitMask: RouteMask?
        if let slash = text.firstIndex(of: "/") {
            guard let length = Int(text[text.index(after: slash)...]), (0...32).contains(length) else { return nil }
            explicitMask = .prefix(length)
            text = text[..<slash]
        } else if let ampersand = text.range(of: "&") {
            explicitMask = .noncontiguous(String(text[ampersand.upperBound...]))
            text = text[..<ampersand.lowerBound]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            bytes.append(byte)
        }
        let written = bytes.count
        bytes += [UInt8](repeating: 0, count: 4 - written)
        return (bytes, explicitMask ?? .prefix(isHost || written == 4 ? 32 : classfulPrefix(bytes[0])))
    }

    private static func classfulPrefix(_ firstOctet: UInt8) -> Int {
        firstOctet < 128 ? 8 : firstOctet < 192 ? 16 : 24
    }

    /// « fe80::%en0/64 », « fe80::1%lo0 » : la zone répète l'interface, elle ne sert pas ici.
    private static func ipv6Target(_ raw: String) -> (bytes: [UInt8], mask: RouteMask)? {
        if raw == "default" { return ([UInt8](repeating: 0, count: 16), .prefix(0)) }
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var length = 128
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...128).contains(value) else { return nil }
            length = value
        }
        let text = String(parts[0].prefix { $0 != "%" })
        var storage = in6_addr()
        guard inet_pton(AF_INET6, text, &storage) == 1 else { return nil }
        return (withUnsafeBytes(of: storage) { Array($0) }, .prefix(length))
    }

    /// Forme canonique, via inet_ntop pour l'IPv6.
    private static func address(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return bytes.map(String.init).joined(separator: ".") }
        var storage = in6_addr()
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &storage, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(cString: buffer)
    }

    private static func scope(_ bytes: [UInt8], mask: RouteMask, rawFlags: String) -> RouteScope {
        let isIPv4 = bytes.count == 4
        let isMulticast = isIPv4 ? (224...239).contains(bytes[0]) : bytes[0] == 0xFF
        if isMulticast || rawFlags.contains("m") { return .multicast }
        let isLinkLocal = isIPv4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        if isLinkLocal { return .linkLocal }
        return mask == .prefix(bytes.count * 8) ? .host : .network
    }

    private static func sortKey(_ bytes: [UInt8], mask: RouteMask) -> String {
        var length = 0
        if case let .prefix(value) = mask { length = value }
        return (bytes.count == 4 ? "4" : "6") + bytes.map { String(format: "%03d", $0) }.joined() + String(format: "%03d", length)
    }

    // MARK: Autres colonnes

    private static func gateway(_ raw: String) -> RouteGateway {
        if raw.hasPrefix("link#"), let index = Int(raw.dropFirst(5)) { return .link(index) }
        if raw.contains(":"), let mac = MACAddress(raw) { return .mac(mac) }
        return .address(raw.lowercased())
    }

    private static func expiry(_ raw: String) -> RouteExpiry? {
        raw == "!" ? .elapsed : Int(raw).map(RouteExpiry.seconds)
    }

    /// Lettres de la page de manuel de netstat (macOS).
    static let flagMeanings: [Character: String] = [
        "U": "active",
        "G": "via passerelle",
        "H": "hôte",
        "S": "statique",
        "C": "clonante",
        "c": "clonante par protocole",
        "L": "adresse de liaison",
        "W": "clonée",
        "I": "liée à l’interface",
        "i": "référence l’interface",
        "m": "multicast",
        "b": "diffusion",
        "D": "dynamique",
        "M": "modifiée",
        "R": "rejet",
        "B": "trou noir",
        "r": "routeur",
        "Y": "proxy",
        "X": "résolution externe",
        "g": "portée globale",
        "1": "protocole 1",
        "2": "protocole 2",
        "3": "protocole 3",
    ]
}
