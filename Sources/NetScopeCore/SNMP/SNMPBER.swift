import Foundation

// Encodage et décodage BER (ASN.1) limités à ce dont SNMP v2c a besoin.

/// Identifiant d'objet SNMP (« 1.3.6.1.2.1.1.5.0 »).
public struct SNMPOID: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let components: [UInt32]

    public init(_ components: [UInt32]) {
        self.components = components
    }

    /// Lecture de la notation pointée ; nil si un composant est illisible.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard let value = UInt32(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    public init(stringLiteral value: String) {
        guard let oid = SNMPOID(value) else { preconditionFailure("OID invalide : \(value)") }
        self = oid
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Vrai si cet OID est `prefix` ou se trouve sous lui.
    public func hasPrefix(_ prefix: SNMPOID) -> Bool {
        components.count >= prefix.components.count && Array(components.prefix(prefix.components.count)) == prefix.components
    }

    /// Composants qui suivent `prefix` (l'index d'une ligne de table) ; nil si l'OID n'est pas sous `prefix`.
    public func suffix(after prefix: SNMPOID) -> [UInt32]? {
        guard hasPrefix(prefix) else { return nil }
        return Array(components.dropFirst(prefix.components.count))
    }

    public func appending(_ more: UInt32...) -> SNMPOID { SNMPOID(components + more) }
    public func appending(_ more: [UInt32]) -> SNMPOID { SNMPOID(components + more) }

    /// Ordre lexicographique de SNMP (celui de GetNext).
    public static func < (lhs: SNMPOID, rhs: SNMPOID) -> Bool {
        for (a, b) in zip(lhs.components, rhs.components) where a != b { return a < b }
        return lhs.components.count < rhs.components.count
    }
}

/// Valeur d'une variable SNMP.
public enum SNMPValue: Hashable, Sendable {
    case integer(Int64)
    case octetString([UInt8])
    case null
    case oid(SNMPOID)
    case ipAddress(IPv4Address)
    case counter32(UInt32)
    case gauge32(UInt32)
    case timeTicks(UInt32)
    case opaque([UInt8])
    case counter64(UInt64)
    // Exceptions de SNMP v2c (RFC 3416).
    case noSuchObject
    case noSuchInstance
    case endOfMibView

    /// Vrai pour les trois exceptions v2c.
    public var isException: Bool {
        switch self {
        case .noSuchObject, .noSuchInstance, .endOfMibView: return true
        default: return false
        }
    }

    /// Valeur entière (INTEGER, compteurs, jauges, TimeTicks).
    public var intValue: Int64? {
        switch self {
        case .integer(let v): return v
        case .counter32(let v), .gauge32(let v), .timeTicks(let v): return Int64(v)
        case .counter64(let v): return v > UInt64(Int64.max) ? Int64.max : Int64(v)
        default: return nil
        }
    }

    public var uint64Value: UInt64? {
        switch self {
        case .counter64(let v): return v
        case .integer(let v): return v >= 0 ? UInt64(v) : nil
        case .counter32(let v), .gauge32(let v), .timeTicks(let v): return UInt64(v)
        default: return nil
        }
    }

    /// Texte d'une OCTET STRING (UTF-8, sinon Latin-1), sans les zéros de fin.
    public var stringValue: String? {
        switch self {
        case .octetString(let bytes):
            var trimmed = bytes
            while trimmed.last == 0 { trimmed.removeLast() }
            return String(bytes: trimmed, encoding: .utf8) ?? String(bytes: trimmed, encoding: .isoLatin1)
        case .integer(let v): return String(v)
        case .oid(let oid): return oid.description
        case .ipAddress(let ip): return ip.description
        default: return nil
        }
    }

    public var bytesValue: [UInt8]? {
        switch self {
        case .octetString(let bytes), .opaque(let bytes): return bytes
        default: return nil
        }
    }
}

/// Erreur de décodage BER.
public struct SNMPDecodingError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { "Réponse SNMP illisible : \(message)" }
}

/// Étiquettes BER utilisées par SNMP.
public enum SNMPTag {
    public static let integer: UInt8 = 0x02
    public static let octetString: UInt8 = 0x04
    public static let null: UInt8 = 0x05
    public static let oid: UInt8 = 0x06
    public static let sequence: UInt8 = 0x30
    public static let ipAddress: UInt8 = 0x40
    public static let counter32: UInt8 = 0x41
    public static let gauge32: UInt8 = 0x42
    public static let timeTicks: UInt8 = 0x43
    public static let opaque: UInt8 = 0x44
    public static let counter64: UInt8 = 0x46
    public static let noSuchObject: UInt8 = 0x80
    public static let noSuchInstance: UInt8 = 0x81
    public static let endOfMibView: UInt8 = 0x82
}

// MARK: - Encodage

public enum SNMPBER {
    /// Longueur BER (forme courte sous 128, sinon forme longue).
    public static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(content.count) + content
    }

    /// Entier signé en complément à deux, sur le moins d'octets possible.
    public static func encodeSigned(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: v), at: 0)
            v >>= 8
        } while !(v == 0 && bytes[0] & 0x80 == 0) && !(v == -1 && bytes[0] & 0x80 != 0)
        return bytes
    }

    /// Entier non signé (compteurs) : un zéro de tête si le bit de poids fort est à 1.
    public static func encodeUnsigned(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    public static func encodeOIDContent(_ oid: SNMPOID) -> [UInt8] {
        let c = oid.components
        guard c.count >= 2 else { return [UInt8(truncatingIfNeeded: (c.first ?? 0) * 40)] }
        var bytes = base128(c[0] * 40 + c[1])
        for value in c.dropFirst(2) { bytes += base128(value) }
        return bytes
    }

    private static func base128(_ value: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var v = value >> 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }

    public static func encode(_ value: SNMPValue) -> [UInt8] {
        switch value {
        case .integer(let v): return tlv(SNMPTag.integer, encodeSigned(v))
        case .octetString(let bytes): return tlv(SNMPTag.octetString, bytes)
        case .null: return [SNMPTag.null, 0]
        case .oid(let oid): return tlv(SNMPTag.oid, encodeOIDContent(oid))
        case .ipAddress(let ip):
            let o = ip.octets
            return tlv(SNMPTag.ipAddress, [o.0, o.1, o.2, o.3])
        case .counter32(let v): return tlv(SNMPTag.counter32, encodeUnsigned(UInt64(v)))
        case .gauge32(let v): return tlv(SNMPTag.gauge32, encodeUnsigned(UInt64(v)))
        case .timeTicks(let v): return tlv(SNMPTag.timeTicks, encodeUnsigned(UInt64(v)))
        case .opaque(let bytes): return tlv(SNMPTag.opaque, bytes)
        case .counter64(let v): return tlv(SNMPTag.counter64, encodeUnsigned(v))
        case .noSuchObject: return [SNMPTag.noSuchObject, 0]
        case .noSuchInstance: return [SNMPTag.noSuchInstance, 0]
        case .endOfMibView: return [SNMPTag.endOfMibView, 0]
        }
    }

    public static func sequence(_ parts: [[UInt8]], tag: UInt8 = SNMPTag.sequence) -> [UInt8] {
        tlv(tag, parts.flatMap { $0 })
    }
}

// MARK: - Décodage

/// Lecteur séquentiel d'éléments BER.
public struct SNMPBERReader {
    public let bytes: [UInt8]
    public private(set) var position: Int
    private let end: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        position = 0
        end = bytes.count
    }

    private init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        position = start
        self.end = end
    }

    public var isAtEnd: Bool { position >= end }

    /// Lit l'en-tête (étiquette, longueur) et renvoie l'étiquette et la plage du contenu.
    public mutating func readHeader() throws -> (tag: UInt8, range: Range<Int>) {
        guard position < end else { throw SNMPDecodingError("fin de message inattendue") }
        let tag = bytes[position]
        position += 1
        guard position < end else { throw SNMPDecodingError("longueur manquante") }
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, position + count <= end else { throw SNMPDecodingError("longueur invalide") }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[position])
                position += 1
            }
        }
        guard position + length <= end else { throw SNMPDecodingError("élément tronqué (étiquette 0x\(String(tag, radix: 16)))") }
        let range = position..<(position + length)
        position += length
        return (tag, range)
    }

    /// Lit un élément construit (SEQUENCE ou PDU) ; renvoie un lecteur de son contenu.
    public mutating func readConstructed(expecting tag: UInt8? = nil) throws -> (tag: UInt8, reader: SNMPBERReader) {
        let header = try readHeader()
        if let tag, header.tag != tag {
            throw SNMPDecodingError("étiquette 0x\(String(header.tag, radix: 16)) au lieu de 0x\(String(tag, radix: 16))")
        }
        return (header.tag, SNMPBERReader(bytes: bytes, start: header.range.lowerBound, end: header.range.upperBound))
    }

    public mutating func readInteger() throws -> Int64 {
        let header = try readHeader()
        guard header.tag == SNMPTag.integer else { throw SNMPDecodingError("INTEGER attendu") }
        return try SNMPBERReader.decodeSigned(Array(bytes[header.range]))
    }

    public mutating func readOctetString() throws -> [UInt8] {
        let header = try readHeader()
        guard header.tag == SNMPTag.octetString else { throw SNMPDecodingError("OCTET STRING attendue") }
        return Array(bytes[header.range])
    }

    public mutating func readOID() throws -> SNMPOID {
        let header = try readHeader()
        guard header.tag == SNMPTag.oid else { throw SNMPDecodingError("OID attendu") }
        return try SNMPBERReader.decodeOID(Array(bytes[header.range]))
    }

    /// Lit une valeur quelconque (varbind).
    public mutating func readValue() throws -> SNMPValue {
        let header = try readHeader()
        let content = Array(bytes[header.range])
        switch header.tag {
        case SNMPTag.integer: return .integer(try SNMPBERReader.decodeSigned(content))
        case SNMPTag.octetString: return .octetString(content)
        case SNMPTag.null: return .null
        case SNMPTag.oid: return .oid(try SNMPBERReader.decodeOID(content))
        case SNMPTag.ipAddress:
            guard content.count == 4 else { throw SNMPDecodingError("IpAddress sur \(content.count) octets") }
            return .ipAddress(IPv4Address(content[0], content[1], content[2], content[3]))
        case SNMPTag.counter32: return .counter32(UInt32(truncatingIfNeeded: try SNMPBERReader.decodeUnsigned(content, maxBytes: 5)))
        case SNMPTag.gauge32: return .gauge32(UInt32(truncatingIfNeeded: try SNMPBERReader.decodeUnsigned(content, maxBytes: 5)))
        case SNMPTag.timeTicks: return .timeTicks(UInt32(truncatingIfNeeded: try SNMPBERReader.decodeUnsigned(content, maxBytes: 5)))
        case SNMPTag.opaque: return .opaque(content)
        case SNMPTag.counter64: return .counter64(try SNMPBERReader.decodeUnsigned(content, maxBytes: 9))
        case SNMPTag.noSuchObject: return .noSuchObject
        case SNMPTag.noSuchInstance: return .noSuchInstance
        case SNMPTag.endOfMibView: return .endOfMibView
        default: throw SNMPDecodingError("type inconnu 0x\(String(header.tag, radix: 16))")
        }
    }

    public static func decodeSigned(_ content: [UInt8]) throws -> Int64 {
        guard !content.isEmpty, content.count <= 8 else { throw SNMPDecodingError("INTEGER de \(content.count) octets") }
        var value: Int64 = content[0] & 0x80 != 0 ? -1 : 0
        for byte in content { value = (value << 8) | Int64(byte) }
        return value
    }

    public static func decodeUnsigned(_ content: [UInt8], maxBytes: Int) throws -> UInt64 {
        guard !content.isEmpty, content.count <= maxBytes else { throw SNMPDecodingError("entier non signé de \(content.count) octets") }
        if content.count == maxBytes, content[0] != 0 { throw SNMPDecodingError("entier non signé trop grand") }
        var value: UInt64 = 0
        for byte in content { value = (value << 8) | UInt64(byte) }
        return value
    }

    public static func decodeOID(_ content: [UInt8]) throws -> SNMPOID {
        guard !content.isEmpty else { throw SNMPDecodingError("OID vide") }
        var values: [UInt32] = []
        var current: UInt64 = 0
        var first = true
        for byte in content {
            current = (current << 7) | UInt64(byte & 0x7F)
            guard current <= UInt64(UInt32.max) else { throw SNMPDecodingError("composant d'OID trop grand") }
            if byte & 0x80 == 0 {
                if first {
                    let v = UInt32(current)
                    if v < 80 {
                        values += [v / 40, v % 40]
                    } else {
                        values += [2, v - 80]
                    }
                    first = false
                } else {
                    values.append(UInt32(current))
                }
                current = 0
            }
        }
        guard content.last! & 0x80 == 0 else { throw SNMPDecodingError("OID tronqué") }
        return SNMPOID(values)
    }
}
