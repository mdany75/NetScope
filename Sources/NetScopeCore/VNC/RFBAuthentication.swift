import CommonCrypto
import CryptoKit
import Foundation

/// Authentifications VNC : mot de passe VNC (DES, RFC 6143 § 7.2.2) et compte macOS (Apple Remote
/// Desktop, type 30 : Diffie-Hellman, MD5, AES-128). Fonctions pures, testées sur des octets fixes.
public enum RFBAuthentication {
    // MARK: Mot de passe VNC (DES)

    /// Clé DES tirée du mot de passe : 8 premiers octets (complétés par des zéros), bits de chaque
    /// octet inversés (particularité historique de VNC, que la RFC décrit sans la nommer).
    public static func vncKey(password: String) -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        return key.map(reverseBits)
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte, output: UInt8 = 0
        for _ in 0..<8 {
            output = output << 1 | (input & 1)
            input >>= 1
        }
        return output
    }

    /// Réponse au défi de 16 octets : DES-ECB des deux blocs avec la clé du mot de passe.
    public static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else { throw RFBError.protocolViolation("défi d’authentification de \(challenge.count) octets") }
        return try desECB(key: vncKey(password: password), data: challenge, encrypt: true)
    }

    /// DES en mode ECB (CommonCrypto), sans remplissage ; `data` : multiple de 8 octets.
    public static func desECB(key: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        try commonCrypto(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, data: data, encrypt: encrypt)
    }

    /// AES-128 en mode ECB (CommonCrypto), sans remplissage ; `data` : multiple de 16 octets.
    public static func aes128ECB(key: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        try commonCrypto(algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, data: data, encrypt: encrypt)
    }

    private static func commonCrypto(algorithm: CCAlgorithm, key: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, CCOptions(kCCOptionECBMode),
                    key, key.count, nil, data, data.count, out.baseAddress, outputCount, &moved)
        }
        guard status == kCCSuccess else { throw RFBError.protocolViolation("chiffrement impossible (CommonCrypto \(status))") }
        return Array(output.prefix(moved))
    }

    // MARK: Apple Remote Desktop (type 30)

    /// Paramètres Diffie-Hellman envoyés par le serveur macOS.
    public struct ARDParameters: Equatable, Sendable {
        public var generator: RFBBigUInt
        public var keyLength: Int
        public var prime: RFBBigUInt
        public var serverPublicKey: RFBBigUInt

        public init(generator: RFBBigUInt, keyLength: Int, prime: RFBBigUInt, serverPublicKey: RFBBigUInt) {
            self.generator = generator
            self.keyLength = keyLength
            self.prime = prime
            self.serverPublicKey = serverPublicKey
        }
    }

    /// Les 128 octets d'identifiants : nom d'utilisateur (octets 0 à 63) puis mot de passe (64 à
    /// 127), chacun terminé par un zéro ; le reste est aléatoire (`filler`).
    public static func ardCredentialBlock(username: String, password: String, filler: [UInt8]) throws -> [UInt8] {
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count < 64 else { throw RFBError.authenticationFailed("nom d’utilisateur trop long (63 octets au plus)") }
        guard pass.count < 64 else { throw RFBError.authenticationFailed("mot de passe trop long (63 octets au plus)") }
        var block = filler.count >= 128 ? Array(filler.prefix(128)) : filler + [UInt8](repeating: 0, count: 128 - filler.count)
        block.replaceSubrange(0..<user.count, with: user)
        block[user.count] = 0
        block.replaceSubrange(64..<(64 + pass.count), with: pass)
        block[64 + pass.count] = 0
        return block
    }

    /// Réponse ARD : identifiants chiffrés (AES-128-ECB, clé = MD5 du secret partagé), suivis de la
    /// clé publique du client. `privateKey` : clé privée Diffie-Hellman (aléatoire en usage normal).
    public static func ardResponse(_ parameters: ARDParameters, username: String, password: String,
                                   privateKey: [UInt8], filler: [UInt8]) throws -> [UInt8] {
        guard parameters.keyLength > 0, parameters.keyLength <= 1024 else {
            throw RFBError.protocolViolation("clé Diffie-Hellman de \(parameters.keyLength) octets")
        }
        guard parameters.prime.limbs.first.map({ $0 & 1 == 1 }) ?? false else {
            throw RFBError.protocolViolation("module Diffie-Hellman invalide")
        }
        let secret = RFBBigUInt(bigEndian: privateKey)
        let clientPublic = RFBBigUInt.modPow(parameters.generator, secret, parameters.prime)
        let shared = RFBBigUInt.modPow(parameters.serverPublicKey, secret, parameters.prime)
        let key = Array(Insecure.MD5.hash(data: shared.bigEndianBytes(length: parameters.keyLength)))
        let block = try ardCredentialBlock(username: username, password: password, filler: filler)
        let encrypted = try aes128ECB(key: key, data: block, encrypt: true)
        return encrypted + clientPublic.bigEndianBytes(length: parameters.keyLength)
    }

    /// Octets aléatoires du système.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}
