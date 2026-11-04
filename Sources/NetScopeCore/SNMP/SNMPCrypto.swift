import CommonCrypto
import Foundation

// Cryptographie du modèle de sécurité USM de SNMP v3 (RFC 3414, 3826, 7860) : condensés,
// HMAC, dérivation et localisation des clés, chiffrement DES-CBC et AES-CFB.
// CommonCrypto (bibliothèque système de macOS) fournit SHA-1/SHA-2 et les chiffrements ;
// MD5, marqué « obsolète » par CommonCrypto, est calculé ici en Swift pur.

/// Protocole d'authentification SNMP v3.
public enum SNMPAuthProtocol: String, CaseIterable, Codable, Sendable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha224 = "SHA-224"
    case sha256 = "SHA-256"
    case sha384 = "SHA-384"
    case sha512 = "SHA-512"

    /// Libellé tel qu'il est enregistré dans les Réglages (« SHA-256 »).
    public init?(label: String) {
        let clean = label.uppercased().replacingOccurrences(of: " ", with: "")
        switch clean {
        case "MD5", "HMAC-MD5": self = .md5
        case "SHA", "SHA1", "SHA-1": self = .sha1
        case "SHA224", "SHA-224": self = .sha224
        case "SHA256", "SHA-256": self = .sha256
        case "SHA384", "SHA-384": self = .sha384
        case "SHA512", "SHA-512": self = .sha512
        default: return nil
        }
    }

    /// Longueur du code d'authentification transmis (msgAuthenticationParameters), RFC 7860.
    public var macLength: Int {
        switch self {
        case .md5, .sha1: return 12
        case .sha224: return 16
        case .sha256: return 24
        case .sha384: return 32
        case .sha512: return 48
        }
    }

    /// Taille de bloc de la fonction de hachage (HMAC).
    var blockSize: Int {
        switch self {
        case .sha384, .sha512: return 128
        default: return 64
        }
    }

    /// Condensé de `data`.
    public func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .md5: return SNMPMD5.digest(data)
        case .sha1:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &out) }
            return out
        case .sha224:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &out) }
            return out
        case .sha256:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &out) }
            return out
        case .sha384:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA384($0.baseAddress, CC_LONG(data.count), &out) }
            return out
        case .sha512:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &out) }
            return out
        }
    }

    /// HMAC (RFC 2104) de `message` avec la clé `key`.
    public func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var key = key
        if key.count > blockSize { key = hash(key) }
        key += [UInt8](repeating: 0, count: blockSize - key.count)
        let inner = hash(key.map { $0 ^ 0x36 } + message)
        return hash(key.map { $0 ^ 0x5C } + inner)
    }

    /// Clé Ku tirée du mot de passe (RFC 3414 A.2) : condensé du mot de passe répété sur 1 Mo.
    public func passwordToKey(_ password: String) -> [UInt8] {
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty else { return [] }
        let total = 1_048_576
        var buffer = [UInt8](repeating: 0, count: total)
        for index in 0..<total { buffer[index] = bytes[index % bytes.count] }
        return hash(buffer)
    }

    /// Clé localisée Kul = H(Ku ‖ engineID ‖ Ku) (RFC 3414 2.6).
    public func localize(_ key: [UInt8], engineID: [UInt8]) -> [UInt8] {
        hash(key + engineID + key)
    }

    /// Clé localisée directement depuis le mot de passe.
    public func localizedKey(password: String, engineID: [UInt8]) -> [UInt8] {
        localize(passwordToKey(password), engineID: engineID)
    }
}

/// Protocole de confidentialité SNMP v3.
public enum SNMPPrivProtocol: String, CaseIterable, Codable, Sendable {
    case des = "DES"
    case aes128 = "AES-128"
    case aes192 = "AES-192"
    case aes256 = "AES-256"

    public init?(label: String) {
        let clean = label.uppercased().replacingOccurrences(of: " ", with: "")
        switch clean {
        case "DES", "CBC-DES": self = .des
        case "AES", "AES128", "AES-128": self = .aes128
        case "AES192", "AES-192": self = .aes192
        case "AES256", "AES-256": self = .aes256
        default: return nil
        }
    }

    var keyLength: Int {
        switch self {
        case .des, .aes128: return 16
        case .aes192: return 24
        case .aes256: return 32
        }
    }

    /// Clé de confidentialité localisée, allongée au besoin (AES-192/256 avec SHA-1 ou MD5) par la
    /// méthode de Blumenthal (celle de net-snmp) : Kul ‖ H(Kul) ‖ H(H(Kul))…
    public func key(password: String, engineID: [UInt8], auth: SNMPAuthProtocol) -> [UInt8] {
        var key = auth.localizedKey(password: password, engineID: engineID)
        var last = key
        while key.count < keyLength {
            last = auth.hash(last)
            key += last
        }
        return Array(key.prefix(keyLength))
    }

    /// Chiffre le scopedPDU ; renvoie les octets chiffrés et msgPrivacyParameters (sel de 8 octets).
    public func encrypt(_ plain: [UInt8], key: [UInt8], boots: Int32, time: Int32, salt: UInt64) throws -> (cipher: [UInt8], privParams: [UInt8]) {
        let saltBytes = SNMPCryptoBytes.uint64(salt)
        switch self {
        case .des:
            // RFC 3414 8.1.1.1 : sel = engineBoots ‖ compteur local ; IV = pré-IV ⊕ sel.
            let desSalt = SNMPCryptoBytes.uint32(UInt32(bitPattern: boots)) + Array(saltBytes.suffix(4))
            let iv = zip(key[8..<16], desSalt).map { $0 ^ $1 }
            var padded = plain
            if padded.count % 8 != 0 { padded += [UInt8](repeating: 0, count: 8 - padded.count % 8) }
            let cipher = try SNMPCipher.run(encrypt: true, algorithm: CCAlgorithm(kCCAlgorithmDES), mode: CCMode(kCCModeCBC),
                                            key: Array(key[0..<8]), iv: iv, data: padded)
            return (cipher, desSalt)
        case .aes128, .aes192, .aes256:
            // RFC 3826 3.1.2.1 : IV = engineBoots ‖ engineTime ‖ sel 64 bits.
            let iv = SNMPCryptoBytes.uint32(UInt32(bitPattern: boots)) + SNMPCryptoBytes.uint32(UInt32(bitPattern: time)) + saltBytes
            let cipher = try SNMPCipher.run(encrypt: true, algorithm: CCAlgorithm(kCCAlgorithmAES), mode: CCMode(kCCModeCFB),
                                            key: Array(key.prefix(keyLength)), iv: iv, data: plain)
            return (cipher, saltBytes)
        }
    }

    /// Déchiffre un scopedPDU reçu.
    public func decrypt(_ cipher: [UInt8], key: [UInt8], boots: Int32, time: Int32, privParams: [UInt8]) throws -> [UInt8] {
        guard privParams.count == 8 else { throw SNMPDecodingError("paramètres de confidentialité invalides") }
        switch self {
        case .des:
            guard cipher.count % 8 == 0 else { throw SNMPDecodingError("longueur chiffrée DES invalide") }
            let iv = zip(key[8..<16], privParams).map { $0 ^ $1 }
            return try SNMPCipher.run(encrypt: false, algorithm: CCAlgorithm(kCCAlgorithmDES), mode: CCMode(kCCModeCBC),
                                      key: Array(key[0..<8]), iv: iv, data: cipher)
        case .aes128, .aes192, .aes256:
            let iv = SNMPCryptoBytes.uint32(UInt32(bitPattern: boots)) + SNMPCryptoBytes.uint32(UInt32(bitPattern: time)) + privParams
            return try SNMPCipher.run(encrypt: false, algorithm: CCAlgorithm(kCCAlgorithmAES), mode: CCMode(kCCModeCFB),
                                      key: Array(key.prefix(keyLength)), iv: iv, data: cipher)
        }
    }
}

enum SNMPCryptoBytes {
    static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func uint64(_ value: UInt64) -> [UInt8] {
        uint32(UInt32(value >> 32)) + uint32(UInt32(value & 0xFFFF_FFFF))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Chiffrement par CommonCrypto (sans bourrage : le bourrage DES est fait à la main).
enum SNMPCipher {
    static func run(encrypt: Bool, algorithm: CCAlgorithm, mode: CCMode, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        let status = CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), mode, algorithm,
                                             CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0, 0, &cryptor)
        guard status == kCCSuccess, let cryptor else { throw SNMPDecodingError("chiffrement indisponible (\(status))") }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count + 32)
        var moved = 0
        let update = CCCryptorUpdate(cryptor, data, data.count, &output, output.count, &moved)
        guard update == kCCSuccess else { throw SNMPDecodingError("chiffrement impossible (\(update))") }
        var final = 0
        let finish = CCCryptorFinal(cryptor, &output[moved], output.count - moved, &final)
        guard finish == kCCSuccess else { throw SNMPDecodingError("chiffrement impossible (\(finish))") }
        return Array(output[0..<(moved + final)])
    }
}

/// MD5 (RFC 1321), en Swift : utilisé seulement par SNMP v3 (HMAC-MD5-96), jamais pour la sécurité locale.
enum SNMPMD5 {
    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let table: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for index in 0..<8 { data.append(UInt8((bitLength >> (8 * UInt64(index))) & 0xFF)) }

        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xEFCD_AB89, c0: UInt32 = 0x98BA_DCFE, d0: UInt32 = 0x1032_5476
        var words = [UInt32](repeating: 0, count: 16)
        var chunk = 0
        while chunk < data.count {
            for index in 0..<16 {
                let base = chunk + index * 4
                words[index] = UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ table[i] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
            chunk += 64
        }
        return [a0, b0, c0, d0].flatMap { value in (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
    }
}
