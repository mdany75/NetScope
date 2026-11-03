import Foundation

/// Adresse IPv4, stockée sur 32 bits (ordre naturel : 10.0.0.1 = 0x0A000001).
public struct IPv4Address: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// Lit une adresse en notation pointée stricte (« 192.168.1.10 ») ; nil si invalide.
    /// Les zéros en tête sont refusés (« 010.0.0.1 » est ambigu : octal ou décimal).
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            result = result << 8 | octet
        }
        value = result
    }

    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    public var description: String {
        let o = octets
        return "\(o.0).\(o.1).\(o.2).\(o.3)"
    }

    /// Adresse précédente ou suivante (nil aux bornes).
    public var next: IPv4Address? { value == .max ? nil : IPv4Address(value + 1) }
    public var previous: IPv4Address? { value == 0 ? nil : IPv4Address(value - 1) }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool { lhs.value < rhs.value }

    // Codable : sous forme de texte, plus lisible dans les fichiers JSON.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = IPv4Address(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Adresse IPv4 invalide : \(text)")
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension IPv4Address {
    /// Masque de sous-réseau correspondant à un préfixe (0…32).
    public static func mask(prefix: Int) -> IPv4Address {
        precondition((0...32).contains(prefix), "préfixe hors limites")
        return IPv4Address(prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix))
    }

    /// Longueur de préfixe d'un masque contigu (255.255.255.0 → 24) ; nil si le masque n'est pas contigu.
    public var prefixLength: Int? {
        let count = (~value).leadingZeroBitCount
        return IPv4Address.mask(prefix: count) == self ? count : nil
    }
}
