import Foundation

// IPv6 (0.31.0) : adresse sur 128 bits, analyse (formes courte, complète, IPv4 incluse),
// écriture canonique RFC 5952, portée (lien local, ULA, globale…) et identifiant EUI-64.
// Calcul pur : aucun paquet, aucun appel système.

/// Portée d'une adresse IPv6.
public enum IPv6Scope: Int, Comparable, Sendable, CaseIterable {
    case linkLocal, uniqueLocal, global, documentation, multicast, loopback, unspecified, ipv4Mapped, reserved

    public static func < (lhs: IPv6Scope, rhs: IPv6Scope) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .linkLocal: return "Lien local"
        case .uniqueLocal: return "Locale unique (ULA)"
        case .global: return "Globale"
        case .documentation: return "Documentation"
        case .multicast: return "Multidiffusion"
        case .loopback: return "Bouclage"
        case .unspecified: return "Non spécifiée"
        case .ipv4Mapped: return "IPv4 mappée"
        case .reserved: return "Réservée"
        }
    }

    /// Libellé court pour une pastille (« Lien local », « ULA », « Globale »).
    public var shortLabel: String {
        switch self {
        case .uniqueLocal: return "ULA"
        default: return label
        }
    }

    /// Bloc de référence (« fe80::/10 »).
    public var block: String {
        switch self {
        case .linkLocal: return "fe80::/10"
        case .uniqueLocal: return "fc00::/7 · RFC 4193"
        case .global: return "2000::/3"
        case .documentation: return "2001:db8::/32 · RFC 3849"
        case .multicast: return "ff00::/8"
        case .loopback: return "::1/128"
        case .unspecified: return "::/128"
        case .ipv4Mapped: return "::ffff:0:0/96"
        case .reserved: return "hors des blocs attribués"
        }
    }
}

/// Adresse IPv6 (128 bits, deux moitiés de 64 bits, ordre réseau).
public struct IPv6Address: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// 16 octets ; nil si la longueur ne convient pas.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for index in 0..<8 { hi = hi << 8 | UInt64(bytes[index]) }
        for index in 8..<16 { lo = lo << 8 | UInt64(bytes[index]) }
        self.init(high: hi, low: lo)
    }

    /// Huit groupes de 16 bits.
    public init?(groups: [UInt16]) {
        guard groups.count == 8 else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for index in 0..<4 { hi = hi << 16 | UInt64(groups[index]) }
        for index in 4..<8 { lo = lo << 16 | UInt64(groups[index]) }
        self.init(high: hi, low: lo)
    }

    /// Analyse « 2001:db8::1 », « 2001:0db8:0000:0000:0000:0000:0000:0001 », « ::ffff:192.0.2.1 ».
    /// Les crochets et la zone (« %en0 ») sont refusés ici : voir `parseZoned`.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 45, text.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String, allowIPv4: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var result: [UInt16] = []
            for (index, piece) in pieces.enumerated() {
                if piece.contains(".") {
                    // IPv4 incluse : seulement en dernier.
                    guard allowIPv4, index == pieces.count - 1, let v4 = IPv4Address(piece) else { return nil }
                    result.append(UInt16(v4.value >> 16))
                    result.append(UInt16(v4.value & 0xFFFF))
                } else {
                    guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }
        if halves.count == 2 {
            guard let head = groups(halves[0], allowIPv4: false),
                  let tail = groups(halves[1], allowIPv4: true),
                  head.count + tail.count <= 7 else { return nil }
            self.init(groups: head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail)
        } else {
            guard let all = groups(text, allowIPv4: true), all.count == 8 else { return nil }
            self.init(groups: all)
        }
    }

    /// Analyse une saisie avec zone et crochets éventuels : « fe80::1%en0 », « [2001:db8::1] ».
    public static func parseZoned(_ text: String) -> (address: IPv6Address, zone: String?)? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var zone: String?
        if let percent = text.firstIndex(of: "%") {
            let name = String(text[text.index(after: percent)...])
            guard !name.isEmpty, name.count <= 15, name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            zone = name
            text = String(text[..<percent])
        }
        guard let address = IPv6Address(text) else { return nil }
        return (address, zone)
    }

    public static let unspecified = IPv6Address(high: 0, low: 0)
    public static let loopback = IPv6Address(high: 0, low: 1)
    /// ff02::1, tous les nœuds du lien.
    public static let allNodes = IPv6Address(high: 0xFF02_0000_0000_0000, low: 1)

    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
    }

    public var groups: [UInt16] {
        (0..<4).map { UInt16(truncatingIfNeeded: high >> (48 - 16 * $0)) }
            + (0..<4).map { UInt16(truncatingIfNeeded: low >> (48 - 16 * $0)) }
    }

    /// Forme canonique RFC 5952 : minuscules, sans zéros de tête, la plus longue suite d'au moins
    /// deux groupes nuls remplacée par « :: » (la première à égalité) ; IPv4 mappée en notation pointée.
    public var description: String {
        let g = groups
        if scope == .ipv4Mapped {
            return "::ffff:\(IPv4Address(UInt32(g[6]) << 16 | UInt32(g[7])))"
        }
        var bestStart = -1, bestLength = 0, start = -1
        for index in 0...8 {
            if index < 8, g[index] == 0 {
                if start < 0 { start = index }
            } else if start >= 0 {
                let length = index - start
                if length > bestLength { bestStart = start; bestLength = length }
                start = -1
            }
        }
        let hex = g.map { String($0, radix: 16) }
        guard bestLength >= 2 else { return hex.joined(separator: ":") }
        let head = hex[0..<bestStart].joined(separator: ":")
        let tail = hex[(bestStart + bestLength)...].joined(separator: ":")
        return head + "::" + tail
    }

    /// Forme complète : huit groupes de quatre chiffres (« 2001:0db8:0000:… »).
    public var expanded: String {
        groups.map { value in
            let raw = String(value, radix: 16)
            return String(repeating: "0", count: 4 - raw.count) + raw
        }.joined(separator: ":")
    }

    public var scope: IPv6Scope {
        if high == 0 && low == 0 { return .unspecified }
        if high == 0 && low == 1 { return .loopback }
        if high == 0 && low >> 32 == 0xFFFF { return .ipv4Mapped }
        let top = high >> 48
        if top & 0xFFC0 == 0xFE80 { return .linkLocal }
        if top & 0xFE00 == 0xFC00 { return .uniqueLocal }
        if top & 0xFF00 == 0xFF00 { return .multicast }
        if high >> 32 == 0x2001_0DB8 { return .documentation }
        if top & 0xE000 == 0x2000 { return .global }
        return .reserved
    }

    /// Ordre d'affichage : lien local, ULA, globales, puis le reste ; à portée égale, croissant.
    public static func displayOrder(_ lhs: IPv6Address, _ rhs: IPv6Address) -> Bool {
        let (a, b) = (lhs.displayRank, rhs.displayRank)
        return a != b ? a < b : lhs < rhs
    }

    private var displayRank: Int {
        switch scope {
        case .linkLocal: return 0
        case .uniqueLocal: return 1
        case .global, .documentation: return 2
        default: return 3
        }
    }

    public static func < (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    // MARK: EUI-64

    /// Identifiant d'interface EUI-64 modifié (RFC 4291, annexe A) : bit U/L inversé, ff:fe au milieu.
    public static func interfaceIdentifier(mac: MACAddress) -> UInt64 {
        let b = mac.bytes
        let raw: [UInt8] = [b[0] ^ 0x02, b[1], b[2], 0xFF, 0xFE, b[3], b[4], b[5]]
        return raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Adresse formée d'un préfixe /64 et de l'EUI-64 d'une MAC (fe80::/64 par défaut).
    public static func eui64(mac: MACAddress, prefix: IPv6Address = IPv6Address(high: 0xFE80_0000_0000_0000, low: 0)) -> IPv6Address {
        IPv6Address(high: prefix.high, low: interfaceIdentifier(mac: mac))
    }

    /// MAC d'origine si l'identifiant d'interface est un EUI-64 (« ff:fe » au milieu), sinon nil
    /// (adresse temporaire ou « stable opaque », RFC 7217).
    public var embeddedMAC: MACAddress? {
        guard (low >> 24) & 0xFFFF == 0xFFFE else { return nil }
        let b = (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        return MACAddress(bytes: [b[0] ^ 0x02, b[1], b[2], b[5], b[6], b[7]])
    }

    // MARK: Codable (texte canonique)

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = IPv6Address(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Adresse IPv6 illisible : \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Préfixe IPv6 (« 2001:db8:a00::/48 ») : réseau, plage, nombre d'adresses et découpage.
public struct IPv6Prefix: Hashable, Sendable, CustomStringConvertible {
    /// Adresse saisie (peut être un hôte du préfixe).
    public let entered: IPv6Address
    public let length: Int

    public enum ParseError: Error, Equatable, LocalizedError {
        case missingLength, invalidAddress, invalidLength

        public var errorDescription: String? {
            switch self {
            case .missingLength: return "Longueur de préfixe manquante\u{00A0}: ajoutez /64, par exemple."
            case .invalidAddress: return "Adresse IPv6 illisible (forme courte ou complète attendue)."
            case .invalidLength: return "La longueur du préfixe va de 0 à 128."
            }
        }
    }

    public init(address: IPv6Address, length: Int) {
        entered = address
        self.length = min(max(length, 0), 128)
    }

    public init(parsing text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            if parts.count == 1, IPv6Address(String(parts[0])) != nil { throw ParseError.missingLength }
            throw ParseError.invalidAddress
        }
        guard let address = IPv6Address(String(parts[0]).trimmingCharacters(in: .whitespaces)) else { throw ParseError.invalidAddress }
        guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), (0...128).contains(length) else { throw ParseError.invalidLength }
        self.init(address: address, length: length)
    }

    /// Masques des deux moitiés.
    static func masks(_ length: Int) -> (UInt64, UInt64) {
        let hi: UInt64 = length >= 64 ? .max : (length == 0 ? 0 : .max << UInt64(64 - length))
        let lo: UInt64 = length <= 64 ? 0 : (length == 128 ? .max : .max << UInt64(128 - length))
        return (hi, lo)
    }

    public var network: IPv6Address {
        let (hi, lo) = Self.masks(length)
        return IPv6Address(high: entered.high & hi, low: entered.low & lo)
    }

    public var last: IPv6Address {
        let (hi, lo) = Self.masks(length)
        return IPv6Address(high: entered.high | ~hi, low: entered.low | ~lo)
    }

    public var hostBits: Int { 128 - length }

    public func contains(_ address: IPv6Address) -> Bool {
        let (hi, lo) = Self.masks(length)
        return address.high & hi == network.high && address.low & lo == network.low
    }

    /// « 2001:db8:a00::/48 ».
    public var description: String { "\(network)/\(length)" }

    /// Nombre d'adresses : exact jusqu'à 2⁶³, sinon en puissance de deux (« 2⁸⁰ »).
    public var addressCountText: String { Self.powerText(hostBits) }

    /// 2^n en clair (« 256 », « 18 446 744 073 709 551 616 » au-delà de 2⁶³ en puissance).
    public static func powerText(_ exponent: Int) -> String {
        guard exponent < 64 else { return "2" + superscript(exponent) }
        return grouped(UInt64(1) << UInt64(exponent))
    }

    static func superscript(_ value: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        return String(String(value).compactMap { $0.wholeNumberValue.map { digits[$0] } })
    }

    /// Chiffres groupés par trois avec une espace fine insécable (« 65 536 »).
    static func grouped(_ value: UInt64) -> String {
        let raw = String(value)
        var result = ""
        for (index, character) in raw.enumerated() {
            if index > 0, (raw.count - index) % 3 == 0 { result.append("\u{202F}") }
            result.append(character)
        }
        return result
    }

    /// Usage habituel d'une longueur de préfixe.
    public var usage: String {
        switch length {
        case 128: return "une seule adresse (hôte)"
        case 127: return "lien point à point (RFC 6164)"
        case 65...126: return "plus petit qu’un /64\u{00A0}: SLAAC impossible"
        case 64: return "un réseau local (SLAAC)"
        case 57...63: return "quelques réseaux /64"
        case 56: return "attribution courante d’un site résidentiel"
        case 49...55: return "bloc de sous-réseaux"
        case 48: return "attribution courante d’un site d’entreprise"
        case 33...47: return "bloc de sites"
        case 32: return "attribution courante d’un fournisseur (LIR)"
        default: return "très grand bloc"
        }
    }

    /// Nombre de sous-réseaux de longueur `newLength` (texte).
    public func subnetCountText(newLength: Int) -> String {
        guard newLength >= length, newLength <= 128 else { return "0" }
        return Self.powerText(newLength - length)
    }

    /// Les `limit` premiers sous-réseaux de longueur `newLength` ; vide si elle ne convient pas.
    public func subnets(newLength: Int, limit: Int = 16) -> [IPv6Prefix] {
        guard newLength >= length, newLength <= 128, limit > 0 else { return [] }
        let bits = newLength - length
        let count = bits >= 62 ? limit : min(limit, 1 << bits)
        let shift = 128 - newLength
        let base = network
        var result: [IPv6Prefix] = []
        for index in 0..<count {
            let i = UInt64(index)
            var addHigh: UInt64 = 0, addLow: UInt64 = 0
            if shift >= 128 {
                // /0 découpé en /0 : un seul.
            } else if shift >= 64 {
                addHigh = i << UInt64(shift - 64)
            } else {
                addLow = i << UInt64(shift)
                addHigh = shift == 0 ? 0 : i >> UInt64(64 - shift)
            }
            let (low, carry) = base.low.addingReportingOverflow(addLow)
            let high = base.high &+ addHigh &+ (carry ? 1 : 0)
            result.append(IPv6Prefix(address: IPv6Address(high: high, low: low), length: newLength))
        }
        return result
    }
}
