import Foundation

/// Erreurs du calculateur de sous-réseaux.
public enum SubnetError: Error, Equatable, LocalizedError, Sendable {
    case invalidNotation(String)
    case invalidPrefix(String)
    case nonContiguousMask(String)
    case splitPrefixTooShort(current: Int, requested: Int)
    case tooManySubnets(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidNotation(let text):
            return "« \(text) » n’est pas un réseau valide (exemple : 10.182.122.0/24)."
        case .invalidPrefix(let text):
            return "Le préfixe « \(text) » doit être compris entre 0 et 32."
        case .nonContiguousMask(let text):
            return "Le masque « \(text) » n’est pas contigu (exemple valide : 255.255.255.0)."
        case .splitPrefixTooShort(let current, let requested):
            return "Le découpage demande un préfixe plus long que /\(current) (demandé : /\(requested))."
        case .tooManySubnets(let count):
            return "Le découpage produirait \(count) sous-réseaux ; la limite est de \(Subnet.maxSplitCount)."
        }
    }
}

/// Portée d'une adresse : privée (RFC 1918), publique, etc.
public enum AddressScope: String, Sendable, Codable {
    case privee, publique, bouclage, liaisonLocale, cgnat, multicast, reservee

    public var label: String {
        switch self {
        case .privee: return "Privé (RFC 1918)"
        case .publique: return "Public"
        case .bouclage: return "Bouclage"
        case .liaisonLocale: return "Liaison locale (APIPA)"
        case .cgnat: return "Partagé (CGNAT, RFC 6598)"
        case .multicast: return "Multidiffusion"
        case .reservee: return "Réservé"
        }
    }

    public static func of(_ address: IPv4Address) -> AddressScope {
        func within(_ base: String, _ prefix: Int) -> Bool {
            Subnet(address: IPv4Address(base)!, prefix: prefix).contains(address)
        }
        if within("10.0.0.0", 8) || within("172.16.0.0", 12) || within("192.168.0.0", 16) { return .privee }
        if within("127.0.0.0", 8) { return .bouclage }
        if within("169.254.0.0", 16) { return .liaisonLocale }
        if within("100.64.0.0", 10) { return .cgnat }
        if within("224.0.0.0", 4) { return .multicast }
        if within("0.0.0.0", 8) || within("240.0.0.0", 4) { return .reservee }
        return .publique
    }
}

/// Réseau IPv4 (adresse de réseau + longueur de préfixe) et ses grandeurs dérivées.
public struct Subnet: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Limite du découpage en sous-réseaux.
    public static let maxSplitCount = 65_536

    /// Adresse de réseau (bits d'hôte à zéro).
    public let network: IPv4Address
    public let prefix: Int

    /// L'adresse est ramenée à l'adresse de réseau (10.0.0.5/24 → 10.0.0.0/24).
    public init(address: IPv4Address, prefix: Int) {
        precondition((0...32).contains(prefix), "préfixe hors limites")
        self.prefix = prefix
        network = IPv4Address(address.value & IPv4Address.mask(prefix: prefix).value)
    }

    /// Lit « 10.0.0.0/24 », « 10.0.0.0/255.255.255.0 » ou « 10.0.0.0 255.255.255.0 ».
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let separators: [Character] = ["/", " "]
        guard let index = trimmed.firstIndex(where: { separators.contains($0) }) else {
            throw SubnetError.invalidNotation(trimmed)
        }
        let addressText = String(trimmed[..<index])
        let suffix = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespaces)
        guard let address = IPv4Address(addressText) else { throw SubnetError.invalidNotation(trimmed) }
        if suffix.contains(".") {
            guard let mask = IPv4Address(suffix) else { throw SubnetError.invalidNotation(trimmed) }
            guard let length = mask.prefixLength else { throw SubnetError.nonContiguousMask(suffix) }
            self.init(address: address, prefix: length)
        } else {
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let length = Int(suffix), (0...32).contains(length) else {
                throw SubnetError.invalidPrefix(suffix)
            }
            self.init(address: address, prefix: length)
        }
    }

    public var description: String { "\(network)/\(prefix)" }

    public var mask: IPv4Address { IPv4Address.mask(prefix: prefix) }
    public var wildcard: IPv4Address { IPv4Address(~mask.value) }
    public var broadcast: IPv4Address { IPv4Address(network.value | wildcard.value) }

    /// Nombre total d'adresses du bloc (2^(32 − préfixe)).
    public var totalAddresses: UInt64 { UInt64(1) << UInt64(32 - prefix) }

    /// Nombre d'hôtes utilisables : sans réseau ni broadcast, sauf /31 (RFC 3021) et /32.
    public var hostCount: UInt64 {
        switch prefix {
        case 32: return 1
        case 31: return 2
        default: return totalAddresses - 2
        }
    }

    public var firstHost: IPv4Address { prefix >= 31 ? network : IPv4Address(network.value + 1) }
    public var lastHost: IPv4Address { prefix >= 31 ? broadcast : IPv4Address(broadcast.value - 1) }

    /// Classe historique (A à E), d'après le premier octet.
    public var addressClass: String {
        let first = network.octets.0
        switch first {
        case 0...127: return "A"
        case 128...191: return "B"
        case 192...223: return "C"
        case 224...239: return "D"
        default: return "E"
        }
    }

    public var scope: AddressScope { AddressScope.of(network) }
    public var isPrivate: Bool { scope == .privee }

    /// Masque en binaire, octet par octet : « 11111111.11111111.11111111.00000000 ».
    public var binaryMask: String { Subnet.binary(mask) }

    public static func binary(_ address: IPv4Address) -> String {
        let o = address.octets
        return [o.0, o.1, o.2, o.3].map { byte in
            let bits = String(byte, radix: 2)
            return String(repeating: "0", count: 8 - bits.count) + bits
        }.joined(separator: ".")
    }

    public func contains(_ address: IPv4Address) -> Bool {
        address.value & mask.value == network.value
    }

    /// Découpe le réseau en sous-réseaux de préfixe plus long (/24 en /26 → 4 sous-réseaux).
    public func split(into newPrefix: Int) throws -> [Subnet] {
        guard (0...32).contains(newPrefix) else { throw SubnetError.invalidPrefix(String(newPrefix)) }
        guard newPrefix >= prefix else { throw SubnetError.splitPrefixTooShort(current: prefix, requested: newPrefix) }
        let count = 1 << (newPrefix - prefix)
        guard count <= Subnet.maxSplitCount else { throw SubnetError.tooManySubnets(count) }
        let step = UInt64(1) << UInt64(32 - newPrefix)
        return (0..<count).map { index in
            Subnet(address: IPv4Address(UInt32(UInt64(network.value) + UInt64(index) * step)), prefix: newPrefix)
        }
    }
}
