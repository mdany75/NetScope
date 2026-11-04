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
        // Chemin rapide (note 36) : « aa:bb:cc:dd:ee:ff » exact, la forme écrite par NetScope
        // (inventaires, résultats) et renvoyée par la FortiGate. Même résultat que la lecture complète.
        if let fast = MACAddress.parseCanonical(text) {
            self = fast
            return
        }
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

    /// Écrit directement les chiffres hexadécimaux (note 36 : `String(format:)` six fois par
    /// adresse coûtait cher dans les recherches et les fusions de milliers d'appareils).
    public func formatted(_ style: Style = .colon) -> String {
        let digits: StaticString = style == .upperColon ? "0123456789ABCDEF" : "0123456789abcdef"
        let separator: UInt8
        switch style {
        case .colon, .upperColon: separator = UInt8(ascii: ":")
        case .hyphen: separator = UInt8(ascii: "-")
        case .cisco: separator = UInt8(ascii: ".")
        case .bare: separator = 0
        }
        let length = separator == 0 ? 12 : (style == .cisco ? 14 : 17)
        let value = self.value
        return digits.withUTF8Buffer { hex in
            String(unsafeUninitializedCapacity: length) { out in
                var position = 0
                for index in 0..<6 {
                    if index > 0, separator != 0, style != .cisco || index % 2 == 0 {
                        out[position] = separator
                        position += 1
                    }
                    let byte = Int((value >> UInt64(8 * (5 - index))) & 0xFF)
                    out[position] = hex[byte >> 4]
                    out[position + 1] = hex[byte & 0x0F]
                    position += 2
                }
                return position
            }
        }
    }

    /// « aa:bb:cc:dd:ee:ff » (minuscules ou majuscules, deux chiffres par octet), sinon nil.
    private static func parseCanonical(_ text: String) -> MACAddress? {
        var value: UInt64 = 0
        var count = 0
        for byte in text.utf8 {
            let position = count
            count += 1
            guard count <= 17 else { return nil }
            if position % 3 == 2 {
                guard byte == UInt8(ascii: ":") else { return nil }
                continue
            }
            let nibble: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt64(nibble)
        }
        return count == 17 ? MACAddress(value: value) : nil
    }

    public var description: String { formatted(.colon) }

    /// Préfixe constructeur (24 premiers bits).
    public var ouiValue: UInt32 { UInt32(value >> 24) }

    /// Préfixe constructeur, « aa:bb:cc ».
    public var oui: String { String(formatted(.colon).prefix(8)) }

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
