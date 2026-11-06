import Foundation

// Note 70 : lecteur de certificat X.509 (DER) pur, sans Security ni réseau. Il lit ce que les
// fonctions de Security ne donnent pas simplement (algorithme et taille de la clé, signature,
// extensions) et se teste sur des certificats recopiés. Réutilisable par l'empreinte des services
// (note 68) : `X509Certificate(der:)` ou `X509Certificate.parsePEM(_:)`.

/// Erreur de lecture d'un certificat.
public enum X509Error: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case let .malformed(detail): return "Certificat illisible\u{00A0}: \(detail)"
        }
    }
}

/// Nom distinctif (sujet ou émetteur) : attributs dans l'ordre du certificat.
public struct X509Name: Hashable, Sendable {
    public struct Attribute: Hashable, Sendable {
        public var oid: String
        public var value: String

        public init(oid: String, value: String) {
            self.oid = oid
            self.value = value
        }

        /// Abréviation usuelle (« CN », « O », « OU »…), sinon l'OID.
        public var shortName: String { X509OID.attributeNames[oid] ?? oid }
    }

    public var attributes: [Attribute]
    /// Octets DER du nom (comparaison exacte sujet = émetteur).
    public var der: Data

    public init(attributes: [Attribute], der: Data = Data()) {
        self.attributes = attributes
        self.der = der
    }

    public func value(_ oid: String) -> String? { attributes.first { $0.oid == oid }?.value }

    public var commonName: String? { value(X509OID.commonName) }
    public var organization: String? { value(X509OID.organization) }
    public var organizationalUnit: String? { value(X509OID.organizationalUnit) }
    public var country: String? { value(X509OID.country) }

    /// « CN=nas.exemple.ca, O=Exemple Inc, C=CA » : forme lisible, du plus précis au plus large.
    public var text: String {
        attributes.reversed().map { "\($0.shortName)=\($0.value)" }.joined(separator: ", ")
    }

    /// Résumé court : nom commun, sinon organisation, sinon la forme complète.
    public var summary: String {
        if let commonName, let organization, organization != commonName { return "\(commonName) · \(organization)" }
        return commonName ?? organization ?? text
    }
}

/// Nom alternatif du sujet (extension SAN).
public enum X509AltName: Hashable, Sendable {
    case dns(String)
    case ip(String)
    case email(String)
    case uri(String)
    case other(tag: Int)

    public var text: String {
        switch self {
        case let .dns(name): return name
        case let .ip(address): return address
        case let .email(address): return address
        case let .uri(uri): return uri
        case let .other(tag): return "[\(tag)]"
        }
    }

    /// « DNS », « IP », « Courriel », « URI ».
    public var kind: String {
        switch self {
        case .dns: return "DNS"
        case .ip: return "IP"
        case .email: return "Courriel"
        case .uri: return "URI"
        case .other: return "Autre"
        }
    }
}

/// Clé publique du certificat : algorithme et taille.
public struct X509PublicKey: Hashable, Sendable {
    public enum Algorithm: Hashable, Sendable {
        case rsa, ec, ed25519, ed448, dsa
        case other(String)
    }

    public var algorithm: Algorithm
    /// Taille en bits (module RSA, courbe elliptique), si connue.
    public var bits: Int?
    /// Courbe elliptique (« P-256 »), pour une clé EC.
    public var curve: String?

    public init(algorithm: Algorithm, bits: Int?, curve: String? = nil) {
        self.algorithm = algorithm
        self.bits = bits
        self.curve = curve
    }

    /// « RSA 2048 bits », « ECDSA P-256 », « Ed25519 ».
    public var label: String {
        switch algorithm {
        case .rsa: return "RSA" + (bits.map { " \($0)\u{00A0}bits" } ?? "")
        case .ec: return "ECDSA " + (curve ?? bits.map { "\($0)\u{00A0}bits" } ?? "")
        case .ed25519: return "Ed25519"
        case .ed448: return "Ed448"
        case .dsa: return "DSA" + (bits.map { " \($0)\u{00A0}bits" } ?? "")
        case let .other(oid): return "Clé \(oid)"
        }
    }

    /// Clé jugée faible aujourd'hui (RSA ou DSA sous 2048 bits, courbe sous 256 bits).
    public var isWeak: Bool {
        switch algorithm {
        case .rsa, .dsa: return (bits ?? 2048) < 2048
        case .ec: return (bits ?? 256) < 256
        default: return false
        }
    }
}

/// Certificat X.509 lu depuis son encodage DER.
public struct X509Certificate: Hashable, Sendable, Identifiable {
    public var der: Data
    /// Version X.509 (1 à 3).
    public var version: Int
    /// Numéro de série en hexadécimal (« 5A:3C:9E:01 »).
    public var serialNumber: String
    public var signatureAlgorithmOID: String
    public var subject: X509Name
    public var issuer: X509Name
    public var notBefore: Date
    public var notAfter: Date
    public var publicKey: X509PublicKey
    public var subjectAltNames: [X509AltName]
    /// Contrainte de base « autorité de certification » (nil si l'extension est absente).
    public var isCA: Bool?
    /// Usages étendus (OID) ; vide si l'extension est absente.
    public var extendedKeyUsages: [String]
    /// Empreinte SHA-256 du DER, « AB:CD:… » en majuscules.
    public var sha256Fingerprint: String

    public var id: String { sha256Fingerprint }

    // MARK: Lecture

    public init(der: Data) throws {
        self.der = der
        let bytes = [UInt8](der)
        var reader = DERReader(bytes)
        let certificate = try reader.read()
        guard certificate.tag == DERTag.sequence, reader.isAtEnd else { throw X509Error.malformed("enveloppe") }
        let parts = try certificate.children(bytes)
        guard parts.count >= 3 else { throw X509Error.malformed("parties manquantes") }
        let tbs = try parts[0].children(bytes)
        var index = 0
        guard index < tbs.count else { throw X509Error.malformed("TBSCertificate vide") }
        // [0] EXPLICIT version (absente : v1).
        if tbs[index].tag == 0xA0 {
            let inner = try tbs[index].children(bytes)
            guard let integer = inner.first, integer.tag == DERTag.integer else { throw X509Error.malformed("version") }
            version = Int(integer.content(bytes).last ?? 0) + 1
            index += 1
        } else {
            version = 1
        }
        guard tbs.count >= index + 6 else { throw X509Error.malformed("TBSCertificate incomplet") }
        let serial = tbs[index]
        guard serial.tag == DERTag.integer else { throw X509Error.malformed("numéro de série") }
        var serialBytes = serial.content(bytes)
        while serialBytes.count > 1, serialBytes.first == 0 { serialBytes.removeFirst() }
        serialNumber = serialBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        signatureAlgorithmOID = try Self.algorithmOID(parts[1], bytes)
        issuer = try Self.name(tbs[index + 2], bytes)
        let validity = try tbs[index + 3].children(bytes)
        guard validity.count == 2 else { throw X509Error.malformed("validité") }
        notBefore = try Self.time(validity[0], bytes)
        notAfter = try Self.time(validity[1], bytes)
        subject = try Self.name(tbs[index + 4], bytes)
        publicKey = try Self.publicKey(tbs[index + 5], bytes)
        subjectAltNames = []
        isCA = nil
        extendedKeyUsages = []
        // [3] EXPLICIT extensions (v3).
        if let extensions = tbs[(index + 6)...].first(where: { $0.tag == 0xA3 }) {
            guard let list = try extensions.children(bytes).first else { throw X509Error.malformed("extensions") }
            for item in try list.children(bytes) {
                let fields = try item.children(bytes)
                guard let oidNode = fields.first, oidNode.tag == DERTag.oid, let value = fields.last, value.tag == DERTag.octetString
                else { continue }
                let oid = DERReader.oid(oidNode.content(bytes))
                let inner = Array(value.content(bytes))
                switch oid {
                case X509OID.subjectAltName: subjectAltNames = (try? Self.altNames(inner)) ?? []
                case X509OID.basicConstraints: isCA = (try? Self.basicConstraints(inner)) ?? false
                case X509OID.extendedKeyUsage: extendedKeyUsages = (try? Self.keyUsages(inner)) ?? []
                default: break
                }
            }
        }
        sha256Fingerprint = FortiCertificatePin.fingerprint(der: der)
    }

    /// Certificats d'un texte PEM (« -----BEGIN CERTIFICATE----- »), dans l'ordre.
    public static func parsePEM(_ text: String) -> [X509Certificate] {
        var result: [X509Certificate] = []
        var collecting = false
        var body = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                collecting = true
                body = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                collecting = false
                if let data = Data(base64Encoded: body), let certificate = try? X509Certificate(der: data) {
                    result.append(certificate)
                }
            } else if collecting {
                body += line
            }
        }
        return result
    }

    /// Forme PEM du certificat (lignes de 64 caractères).
    public var pem: String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
    }

    // MARK: Lecture simplifiée

    /// Nom de l'algorithme de signature (« SHA-256 avec RSA »).
    public var signatureAlgorithm: String { X509OID.signatureNames[signatureAlgorithmOID] ?? signatureAlgorithmOID }

    /// Signature faible (MD5, SHA-1).
    public var hasWeakSignature: Bool { X509OID.weakSignatures.contains(signatureAlgorithmOID) }

    /// Sujet et émetteur identiques : auto-signé (ou racine).
    public var isSelfIssued: Bool { subject.der.isEmpty ? subject == issuer : subject.der == issuer.der }

    public var dnsNames: [String] { subjectAltNames.compactMap { if case let .dns(name) = $0 { return name } else { return nil } } }
    public var ipAddresses: [String] { subjectAltNames.compactMap { if case let .ip(address) = $0 { return address } else { return nil } } }

    /// Usage « authentification de serveur TLS » permis (extension absente : tout usage permis).
    public var allowsServerAuth: Bool {
        extendedKeyUsages.isEmpty || extendedKeyUsages.contains(X509OID.serverAuth) || extendedKeyUsages.contains(X509OID.anyExtendedKeyUsage)
    }

    /// Jours entiers restants avant l'expiration (négatif une fois expiré).
    public func daysRemaining(at now: Date = Date()) -> Int {
        Int((notAfter.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    /// Durée de validité totale, en jours.
    public var lifetimeDays: Int { Int((notAfter.timeIntervalSince(notBefore) / 86_400).rounded()) }

    /// Le nom (ou l'adresse IP) est couvert par le certificat (SAN, sinon CN en repli).
    public func matches(host: String) -> Bool { TLSHostname.matches(host, certificate: self) }

    // MARK: Décodage des parties

    private static func algorithmOID(_ node: DERNode, _ bytes: [UInt8]) throws -> String {
        guard node.tag == DERTag.sequence, let oid = try node.children(bytes).first, oid.tag == DERTag.oid else {
            throw X509Error.malformed("algorithme")
        }
        return DERReader.oid(oid.content(bytes))
    }

    private static func name(_ node: DERNode, _ bytes: [UInt8]) throws -> X509Name {
        guard node.tag == DERTag.sequence else { throw X509Error.malformed("nom distinctif") }
        var attributes: [X509Name.Attribute] = []
        for set in try node.children(bytes) where set.tag == DERTag.set {
            for pair in try set.children(bytes) {
                let fields = try pair.children(bytes)
                guard fields.count == 2, fields[0].tag == DERTag.oid else { continue }
                attributes.append(X509Name.Attribute(oid: DERReader.oid(fields[0].content(bytes)),
                                                     value: DERReader.string(fields[1].tag, fields[1].content(bytes))))
            }
        }
        return X509Name(attributes: attributes, der: Data(bytes[node.start..<node.end]))
    }

    private static func time(_ node: DERNode, _ bytes: [UInt8]) throws -> Date {
        guard let text = String(bytes: node.content(bytes), encoding: .ascii),
              let date = DERReader.date(text, generalized: node.tag == DERTag.generalizedTime) else {
            throw X509Error.malformed("date de validité")
        }
        return date
    }

    private static func publicKey(_ node: DERNode, _ bytes: [UInt8]) throws -> X509PublicKey {
        let fields = try node.children(bytes)
        guard fields.count == 2, fields[0].tag == DERTag.sequence, fields[1].tag == DERTag.bitString else {
            throw X509Error.malformed("clé publique")
        }
        let algorithm = try fields[0].children(bytes)
        guard let oidNode = algorithm.first, oidNode.tag == DERTag.oid else { throw X509Error.malformed("algorithme de la clé") }
        let oid = DERReader.oid(oidNode.content(bytes))
        // BIT STRING : premier octet = bits inutilisés.
        let key = Array(fields[1].content(bytes).dropFirst())
        switch oid {
        case X509OID.rsaEncryption, X509OID.rsaPSS:
            var reader = DERReader(key)
            let sequence = try reader.read()
            let integers = try sequence.children(key)
            guard let modulus = integers.first, modulus.tag == DERTag.integer else { return X509PublicKey(algorithm: .rsa, bits: nil) }
            return X509PublicKey(algorithm: .rsa, bits: DERReader.bitLength(modulus.content(key)))
        case X509OID.ecPublicKey:
            let curveOID = algorithm.count > 1 && algorithm[1].tag == DERTag.oid ? DERReader.oid(algorithm[1].content(bytes)) : ""
            let curve = X509OID.curves[curveOID]
            // Point non compressé : 04 || X || Y.
            let bits = curve?.bits ?? (key.first == 4 ? (key.count - 1) / 2 * 8 : nil)
            return X509PublicKey(algorithm: .ec, bits: bits, curve: curve?.name ?? (curveOID.isEmpty ? nil : curveOID))
        case X509OID.ed25519: return X509PublicKey(algorithm: .ed25519, bits: 256)
        case X509OID.ed448: return X509PublicKey(algorithm: .ed448, bits: 456)
        case X509OID.dsa:
            let parameters = algorithm.count > 1 ? (try? algorithm[1].children(bytes)) : nil
            return X509PublicKey(algorithm: .dsa, bits: parameters?.first.map { DERReader.bitLength($0.content(bytes)) })
        default:
            return X509PublicKey(algorithm: .other(oid), bits: nil)
        }
    }

    private static func altNames(_ bytes: [UInt8]) throws -> [X509AltName] {
        var reader = DERReader(bytes)
        let sequence = try reader.read()
        return try sequence.children(bytes).map { node in
            let content = node.content(bytes)
            switch node.tag {
            case 0x82: return .dns(String(decoding: content, as: UTF8.self))
            case 0x87:
                if content.count == 4 { return .ip(content.map(String.init).joined(separator: ".")) }
                if content.count == 16 {
                    let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(content[$0]) << 8 | UInt16(content[$0 + 1]), radix: 16) }
                    return .ip(groups.joined(separator: ":"))
                }
                return .other(tag: 7)
            case 0x81: return .email(String(decoding: content, as: UTF8.self))
            case 0x86: return .uri(String(decoding: content, as: UTF8.self))
            default: return .other(tag: Int(node.tag & 0x1F))
            }
        }
    }

    private static func basicConstraints(_ bytes: [UInt8]) throws -> Bool {
        var reader = DERReader(bytes)
        let sequence = try reader.read()
        guard let first = try sequence.children(bytes).first, first.tag == DERTag.boolean else { return false }
        return first.content(bytes).first.map { $0 != 0 } ?? false
    }

    private static func keyUsages(_ bytes: [UInt8]) throws -> [String] {
        var reader = DERReader(bytes)
        let sequence = try reader.read()
        return try sequence.children(bytes).filter { $0.tag == DERTag.oid }.map { DERReader.oid($0.content(bytes)) }
    }
}

// MARK: - OID utiles

public enum X509OID {
    public static let commonName = "2.5.4.3"
    public static let country = "2.5.4.6"
    public static let organization = "2.5.4.10"
    public static let organizationalUnit = "2.5.4.11"
    public static let subjectAltName = "2.5.29.17"
    public static let basicConstraints = "2.5.29.19"
    public static let extendedKeyUsage = "2.5.29.37"
    public static let serverAuth = "1.3.6.1.5.5.7.3.1"
    public static let clientAuth = "1.3.6.1.5.5.7.3.2"
    public static let anyExtendedKeyUsage = "2.5.29.37.0"
    public static let rsaEncryption = "1.2.840.113549.1.1.1"
    public static let rsaPSS = "1.2.840.113549.1.1.10"
    public static let ecPublicKey = "1.2.840.10045.2.1"
    public static let ed25519 = "1.3.101.112"
    public static let ed448 = "1.3.101.113"
    public static let dsa = "1.2.840.10040.4.1"

    static let attributeNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.4": "SN", "2.5.4.5": "serialNumber", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST",
        "2.5.4.9": "street", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.12": "title", "2.5.4.42": "GN",
        "1.2.840.113549.1.9.1": "emailAddress", "0.9.2342.19200300.100.1.25": "DC", "0.9.2342.19200300.100.1.1": "UID",
    ]

    static let signatureNames: [String: String] = [
        "1.2.840.113549.1.1.4": "MD5 avec RSA",
        "1.2.840.113549.1.1.5": "SHA-1 avec RSA",
        "1.2.840.113549.1.1.10": "RSASSA-PSS",
        "1.2.840.113549.1.1.11": "SHA-256 avec RSA",
        "1.2.840.113549.1.1.12": "SHA-384 avec RSA",
        "1.2.840.113549.1.1.13": "SHA-512 avec RSA",
        "1.2.840.10045.4.1": "ECDSA avec SHA-1",
        "1.2.840.10045.4.3.2": "ECDSA avec SHA-256",
        "1.2.840.10045.4.3.3": "ECDSA avec SHA-384",
        "1.2.840.10045.4.3.4": "ECDSA avec SHA-512",
        "1.3.101.112": "Ed25519",
        "1.3.101.113": "Ed448",
        "1.2.840.10040.4.3": "DSA avec SHA-1",
    ]

    static let weakSignatures: Set<String> = ["1.2.840.113549.1.1.4", "1.2.840.113549.1.1.5", "1.2.840.10045.4.1", "1.2.840.10040.4.3"]

    static let curves: [String: (name: String, bits: Int)] = [
        "1.2.840.10045.3.1.7": ("P-256", 256),
        "1.3.132.0.34": ("P-384", 384),
        "1.3.132.0.35": ("P-521", 521),
        "1.3.132.0.10": ("secp256k1", 256),
        "1.2.840.10045.3.1.1": ("P-192", 192),
        "1.3.132.0.33": ("P-224", 224),
    ]
}

// MARK: - Lecture DER

enum DERTag {
    static let boolean: UInt8 = 0x01
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let oid: UInt8 = 0x06
    static let utcTime: UInt8 = 0x17
    static let generalizedTime: UInt8 = 0x18
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
}

/// Élément TLV : étiquette, début de l'élément entier, début et fin du contenu.
struct DERNode {
    let tag: UInt8
    let start: Int
    let contentStart: Int
    let end: Int

    func content(_ bytes: [UInt8]) -> ArraySlice<UInt8> { bytes[contentStart..<end] }

    /// Éléments contenus (SEQUENCE, SET, étiquette construite).
    func children(_ bytes: [UInt8]) throws -> [DERNode] {
        guard tag & 0x20 != 0 else { throw X509Error.malformed("élément simple lu comme une liste") }
        var reader = DERReader(bytes, from: contentStart, to: end)
        var nodes: [DERNode] = []
        while !reader.isAtEnd { nodes.append(try reader.read()) }
        return nodes
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var position: Int
    private let limit: Int

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        position = start
        limit = min(end ?? bytes.count, bytes.count)
    }

    var isAtEnd: Bool { position >= limit }

    mutating func read() throws -> DERNode {
        let start = position
        guard position + 2 <= limit else { throw X509Error.malformed("fin inattendue") }
        let tag = bytes[position]
        guard tag & 0x1F != 0x1F else { throw X509Error.malformed("étiquette longue non prise en charge") }
        var length = Int(bytes[position + 1])
        position += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, position + count <= limit else { throw X509Error.malformed("longueur") }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard length >= 0, position + length <= limit else { throw X509Error.malformed("longueur hors limites") }
        let node = DERNode(tag: tag, start: start, contentStart: position, end: position + length)
        position += length
        return node
    }

    /// OID en notation pointée (« 1.2.840.113549.1.1.11 »).
    static func oid(_ content: ArraySlice<UInt8>) -> String {
        guard let first = content.first else { return "" }
        var parts: [String] = []
        let head = Int(first)
        parts.append(head >= 80 ? "2" : "\(head / 40)")
        var value = head >= 80 ? head - 80 : head % 40
        parts.append("\(value)")
        value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append("\(value)")
                value = 0
            }
        }
        return parts.joined(separator: ".")
    }

    /// Texte d'une chaîne ASN.1 (UTF8String, PrintableString, IA5String, BMPString, T61String…).
    static func string(_ tag: UInt8, _ content: ArraySlice<UInt8>) -> String {
        switch tag {
        case 0x1E: // BMPString : UTF-16 gros-boutiste.
            let units = stride(from: content.startIndex, to: content.endIndex - 1, by: 2).map {
                UInt16(content[$0]) << 8 | UInt16(content[$0 + 1])
            }
            return String(decoding: units, as: UTF16.self)
        case 0x14: // T61String : souvent du Latin-1 en pratique.
            return String(bytes: content, encoding: .isoLatin1) ?? String(decoding: content, as: UTF8.self)
        default:
            return String(decoding: content, as: UTF8.self)
        }
    }

    /// UTCTime (AAMMJJHHMMSSZ, années 1950 à 2049) ou GeneralizedTime (AAAAMMJJHHMMSSZ).
    static func date(_ text: String, generalized: Bool) -> Date? {
        var digits = text
        guard digits.hasSuffix("Z") else { return nil }
        digits.removeLast()
        if let dot = digits.firstIndex(of: ".") { digits = String(digits[..<dot]) }
        let yearLength = generalized ? 4 : 2
        guard digits.count == yearLength + 10 || digits.count == yearLength + 8, digits.allSatisfy(\.isNumber) else { return nil }
        let chars = Array(digits)
        func number(_ from: Int, _ count: Int) -> Int { Int(String(chars[from..<from + count])) ?? 0 }
        var year = number(0, yearLength)
        if !generalized { year += year >= 50 ? 1900 : 2000 }
        var components = DateComponents()
        components.year = year
        components.month = number(yearLength, 2)
        components.day = number(yearLength + 2, 2)
        components.hour = number(yearLength + 4, 2)
        components.minute = number(yearLength + 6, 2)
        components.second = digits.count == yearLength + 10 ? number(yearLength + 8, 2) : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }

    /// Nombre de bits significatifs d'un entier non signé (module RSA).
    static func bitLength(_ content: ArraySlice<UInt8>) -> Int {
        var bytes = Array(content)
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        guard let first = bytes.first, first != 0 else { return 0 }
        return (bytes.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }
}
