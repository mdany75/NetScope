import Foundation

/// Lecteur minimal d'un certificat X.509 (DER) : sujet, émetteur (CN, O, OU), fin de validité,
/// auto-signé. Pur, sans Security : testé sur un certificat recopié. Partageable (note 70).
public struct FPCertificate: Hashable, Sendable {
    public var subject: FPCertName
    public var issuer: FPCertName
    public var notAfter: Date?
    /// Sujet et émetteur identiques (octet pour octet).
    public var isSelfSigned: Bool

    /// Lit un certificat DER ; nil s'il est illisible.
    public static func parse(der: Data) -> FPCertificate? {
        let bytes = [UInt8](der)
        var reader = DERReader(bytes)
        guard let certificate = reader.next(), certificate.tag == 0x30 else { return nil }
        var outer = DERReader(certificate.content)
        guard let tbs = outer.next(), tbs.tag == 0x30 else { return nil }
        var fields = DERReader(tbs.content)
        guard var first = fields.next() else { return nil }
        // [0] version (facultatif), puis numéro de série.
        if first.tag == 0xA0 { guard let serial = fields.next() else { return nil }; first = serial }
        guard first.tag == 0x02,
              let _ = fields.next(),                              // algorithme de signature
              let issuer = fields.next(), issuer.tag == 0x30,
              let validity = fields.next(), validity.tag == 0x30,
              let subject = fields.next(), subject.tag == 0x30 else { return nil }
        var times = DERReader(validity.content)
        _ = times.next()
        let notAfter = times.next().flatMap(decodeTime)
        return FPCertificate(subject: name(subject.content), issuer: name(issuer.content), notAfter: notAfter,
                             isSelfSigned: subject.content == issuer.content)
    }

    // MARK: Nom distinctif

    static func name(_ content: [UInt8]) -> FPCertName {
        var result = FPCertName()
        var sets = DERReader(content)
        while let set = sets.next() {
            var attributes = DERReader(set.content)
            while let attribute = attributes.next() {
                var parts = DERReader(attribute.content)
                guard let oid = parts.next(), oid.tag == 0x06, let value = parts.next(),
                      let text = decodeString(value) else { continue }
                switch oid.content {
                case [0x55, 0x04, 0x03]: result.commonName = result.commonName ?? text
                case [0x55, 0x04, 0x0A]: result.organization = result.organization ?? text
                case [0x55, 0x04, 0x0B]: result.organizationalUnit = result.organizationalUnit ?? text
                default: break
                }
            }
        }
        return result
    }

    static func decodeString(_ element: DERElement) -> String? {
        let text: String?
        switch element.tag {
        case 0x0C, 0x13, 0x16, 0x14, 0x1A: text = String(decoding: element.content, as: UTF8.self)
        case 0x1E:
            var units: [UInt16] = []
            var index = 0
            while index + 1 < element.content.count {
                units.append(UInt16(element.content[index]) << 8 | UInt16(element.content[index + 1]))
                index += 2
            }
            text = String(decoding: units, as: UTF16.self)
        default: text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// UTCTime « 251231235959Z » ou GeneralizedTime « 20491231235959Z ».
    static func decodeTime(_ element: DERElement) -> Date? {
        let text = String(decoding: element.content, as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch element.tag {
        case 0x17:
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            // RFC 5280 : années 50 à 99 → 1950 à 1999.
            formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631_152_000)
        case 0x18: formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        default: return nil
        }
        return formatter.date(from: text)
    }
}

/// Élément DER : étiquette et contenu.
struct DERElement {
    var tag: UInt8
    var content: [UInt8]
}

/// Lecture séquentielle d'éléments DER (longueurs définies seulement).
struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> DERElement? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        var length = Int(bytes[index + 1])
        var cursor = index + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            length = 0
            for offset in 0..<count { length = length << 8 | Int(bytes[cursor + offset]) }
            cursor += count
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        index = cursor + length
        return DERElement(tag: tag, content: Array(bytes[cursor..<(cursor + length)]))
    }
}
