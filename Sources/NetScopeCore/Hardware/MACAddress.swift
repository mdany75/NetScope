import Foundation

/// Adresse MAC (48 bits). Affichage normalisé : « aa:bb:cc:dd:ee:ff ».
public struct MACAddress: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Les 48 bits, dans les bits de poids faible.
    public let value: UInt64

    public enum Style: Sendable {
        /// aa:bb:cc:dd:ee:ff
        case colon
        /// AA:BB:CC:DD:EE:FF
        case upperColon
        /// aa-bb-cc-dd-ee-ff (Windows)
        case hyphen
        /// aabb.ccdd.eeff (Cisco)
        case cisco
        /// aabbccddeeff
        case bare
    }

    public init(value: UInt64) {
        self.value = value & 0xFFFF_FFFF_FFFF
    }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 6, "une adresse MAC compte 6 octets")
        value = bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Accepte « aa:bb:cc:dd:ee:ff », « AA-BB-CC-DD-EE-FF », « aabb.ccdd.eeff », « aabbccddeeff »,
    /// et les octets sans zéro en tête que renvoie `arp -a` sur macOS (« 0:1a:2b:3:4:5 »).
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let hex = Set("0123456789abcdef")
        var bytes: [UInt8] = []
        if trimmed.contains(":") || trimmed.contains("-") {
            let parts = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
                .map(String.init)
            guard parts.count == 6 else { return nil }
            for part in parts {
                guard (1...2).contains(part.count), part.allSatisfy(hex.contains), let byte = UInt8(part, radix: 16) else { return nil }
                bytes.append(byte)
            }
        } else {
            let digits = trimmed.replacingOccurrences(of: ".", with: "")
            if trimmed.contains(".") {
                let groups = trimmed.split(separator: ".", omittingEmptySubsequences: false)
                guard groups.count == 3, groups.allSatisfy({ $0.count == 4 }) else { return nil }
            }
            guard digits.count == 12, digits.allSatisfy(hex.contains) else { return nil }
            var index = digits.startIndex
            for _ in 0..<6 {
                let next = digits.index(index, offsetBy: 2)
                bytes.append(UInt8(digits[index..<next], radix: 16)!)
                index = next
            }
        }
        self.init(bytes: bytes)
    }

    public var bytes: [UInt8] {
        (0..<6).map { UInt8((value >> UInt64(8 * (5 - $0))) & 0xFF) }
    }

    public func formatted(_ style: Style = .colon) -> String {
        let pairs = bytes.map { String(format: "%02x", $0) }
        switch style {
        case .colon: return pairs.joined(separator: ":")
        case .upperColon: return pairs.joined(separator: ":").uppercased()
        case .hyphen: return pairs.joined(separator: "-")
        case .bare: return pairs.joined()
        case .cisco:
            let all = pairs.joined()
            var groups: [String] = []
            var index = all.startIndex
            for _ in 0..<3 {
                let next = all.index(index, offsetBy: 4)
                groups.append(String(all[index..<next]))
                index = next
            }
            return groups.joined(separator: ".")
        }
    }

    public var description: String { formatted(.colon) }

    /// Préfixe constructeur (24 premiers bits).
    public var ouiValue: UInt32 { UInt32(value >> 24) }

    /// Préfixe constructeur, « aa:bb:cc ».
    public var oui: String { bytes.prefix(3).map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Bit « adresse administrée localement » (deuxième bit du premier octet).
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
    /// Bit de groupe (multidiffusion).
    public var isMulticast: Bool { bytes[0] & 0x01 != 0 }
    public var isBroadcast: Bool { value == 0xFFFF_FFFF_FFFF }

    /// Adresse privée aléatoire (iOS, Android, Windows, macOS) : administrée localement et individuelle.
    public var isRandomized: Bool { isLocallyAdministered && !isMulticast }

    public static func < (lhs: MACAddress, rhs: MACAddress) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let mac = MACAddress(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Adresse MAC invalide : \(text)")
        }
        self = mac
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
