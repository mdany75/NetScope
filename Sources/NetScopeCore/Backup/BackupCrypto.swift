import CommonCrypto
import CryptoKit
import Foundation
import Security

// Note 38 : sauvegarde chiffrée par mot de passe. L'archive .zip habituelle (manifeste, fichiers,
// préférences, et en option les secrets du Trousseau) est chiffrée en AES-GCM 256 bits avec une
// clé dérivée du mot de passe (PBKDF2-HMAC-SHA256, 600 000 itérations, sel aléatoire de 16 octets).
//
// Forme du fichier (.netscope-backup) :
//   « NETSCOPE-CHIFFRE » (16 octets) · longueur de l'en-tête (4 octets, gros-boutiste)
//   · en-tête JSON en clair (format, version, paramètres de dérivation, nonce, contrôle du mot de
//     passe, date, type, nombres de fichiers) · données chiffrées · étiquette GCM (16 octets).
// Tout ce qui précède les données chiffrées est authentifié (données associées de l'AES-GCM) :
// changer un paramètre de l'en-tête, comme un seul octet chiffré, fait échouer l'ouverture.
// Le mot de passe n'est jamais écrit dans le fichier ; le contrôle (HMAC d'une clé dérivée à part)
// distingue un mauvais mot de passe d'un fichier modifié, sans rien révéler de plus que l'étiquette.

/// Un secret du Trousseau (service, compte, valeur) rangé dans la partie chiffrée d'une sauvegarde.
public struct BackupSecret: Codable, Hashable, Sendable {
    public var service: String
    public var account: String
    public var value: Data
    /// À quoi il sert (« Jeton de l’API REST de la FortiGate · Siège »), pour l'écran de restauration.
    public var usage: String

    public init(service: String, account: String, value: Data, usage: String) {
        self.service = service
        self.account = account
        self.value = value
        self.usage = usage
    }

    /// Nom sans la valeur (manifeste, écran).
    public var item: BackupKeychainItem { BackupKeychainItem(service: service, account: account, usage: usage) }
}

/// Lecture et écriture des secrets (le Trousseau de macOS, ou un faux Trousseau dans les tests).
public protocol BackupSecretStore {
    /// Secrets de NetScope à sauvegarder (jamais le mot de passe des sauvegardes lui-même).
    func readSecrets() throws -> [BackupSecret]
    /// Enregistre (ou remplace) un secret.
    func write(_ secret: BackupSecret) throws
}

/// Chiffrement demandé pour une sauvegarde.
public struct BackupEncryption: Sendable {
    public var password: String
    /// Range les secrets de `BackupSource.secrets` dans la partie chiffrée.
    public var includeSecrets: Bool
    public var iterations: Int

    public init(password: String, includeSecrets: Bool, iterations: Int = BackupCrypto.defaultIterations) {
        self.password = password
        self.includeSecrets = includeSecrets
        self.iterations = iterations
    }
}

/// En-tête en clair d'une sauvegarde chiffrée : de quoi dériver la clé et lister la sauvegarde
/// sans mot de passe (date, type, nombres), jamais un nom de fichier, de compte ni de secret.
public struct BackupEncryptedHeader: Codable, Equatable, Sendable {
    public static let formatName = "netscope-sauvegarde-chiffree"
    public static let currentVersion = 1

    public struct KeyDerivation: Codable, Equatable, Sendable {
        public var algorithm: String
        public var iterations: Int
        public var salt: Data

        public init(algorithm: String = BackupCrypto.kdfName, iterations: Int, salt: Data) {
            self.algorithm = algorithm
            self.iterations = iterations
            self.salt = salt
        }
    }

    public var format = BackupEncryptedHeader.formatName
    public var version = BackupEncryptedHeader.currentVersion
    public var keyDerivation: KeyDerivation
    public var cipher = BackupCrypto.cipherName
    public var nonce: Data
    /// HMAC-SHA256 de contrôle : vérifie le mot de passe avant d'ouvrir les données.
    public var passwordCheck: Data
    public var createdAt: Date
    public var kind: BackupKind
    public var appVersion: String
    public var appBuild: String
    public var fileCount: Int
    public var preferenceCount: Int
    /// Nombre de secrets du Trousseau dans la partie chiffrée (0 : aucun).
    public var secretCount: Int

    public init(keyDerivation: KeyDerivation, nonce: Data, passwordCheck: Data, createdAt: Date, kind: BackupKind,
                appVersion: String, appBuild: String, fileCount: Int, preferenceCount: Int, secretCount: Int) {
        self.keyDerivation = keyDerivation
        self.nonce = nonce
        self.passwordCheck = passwordCheck
        self.createdAt = createdAt
        self.kind = kind
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.fileCount = fileCount
        self.preferenceCount = preferenceCount
        self.secretCount = secretCount
    }

    public var includesSecrets: Bool { secretCount > 0 }
}

public enum BackupCryptoError: Error, LocalizedError, Equatable {
    case notEncrypted
    case passwordRequired
    case emptyPassword
    case wrongPassword
    /// Le mot de passe est bon, mais le fichier a été modifié ou abîmé depuis sa création.
    case tampered
    case unsupported(String)
    case malformed(String)
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .notEncrypted: return "Cette sauvegarde n’est pas chiffrée."
        case .passwordRequired: return "Cette sauvegarde est chiffrée : saisissez son mot de passe."
        case .emptyPassword: return "Choisissez un mot de passe pour chiffrer la sauvegarde."
        case .wrongPassword: return "Mot de passe incorrect : rien n’a été restauré."
        case .tampered: return "Sauvegarde modifiée ou endommagée depuis sa création (vérification d’intégrité échouée) : rien n’a été restauré."
        case .unsupported(let why): return "Sauvegarde chiffrée illisible par cette version de NetScope : \(why)."
        case .malformed(let why): return "Sauvegarde chiffrée endommagée : \(why)."
        case .system(let why): return "Chiffrement impossible : \(why)."
        }
    }
}

public enum BackupCrypto {
    /// Début de tout fichier chiffré (16 octets ASCII).
    public static let magic = Data("NETSCOPE-CHIFFRE".utf8)
    public static let kdfName = "PBKDF2-HMAC-SHA256"
    public static let cipherName = "AES-GCM-256"
    /// Recommandation OWASP 2023 pour PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000
    /// Bornes acceptées à la lecture : ni dérivation affaiblie, ni fichier qui bloquerait l'app.
    public static let iterationRange = 100_000...20_000_000
    public static let saltBytes = 16
    public static let nonceBytes = 12
    public static let tagBytes = 16
    static let maxHeaderBytes = 64 * 1024

    private static let encryptionInfo = Data("netscope-sauvegarde/chiffrement".utf8)
    private static let checkInfo = Data("netscope-sauvegarde/controle".utf8)
    private static let checkMessage = Data("netscope-sauvegarde/mot-de-passe".utf8)

    /// Vrai si les données commencent par la signature d'une sauvegarde chiffrée.
    public static func isEncrypted(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    /// Vrai si le fichier commence par la signature (lit seulement les premiers octets).
    public static func isEncryptedFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: magic.count)) ?? Data()
        return head == magic
    }

    // MARK: Dérivation

    /// Mot de passe normalisé (forme NFC) : le même mot de passe tapé sur un autre Mac ou un autre
    /// clavier (« é » composé ou non) donne la même clé.
    static func passwordBytes(_ password: String) -> [UInt8] {
        Array(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// PBKDF2-HMAC-SHA256 (CommonCrypto), 32 octets.
    public static func pbkdf2(password: String, salt: Data, iterations: Int, length: Int = 32) throws -> Data {
        let bytes = passwordBytes(password)
        // Tampon d'un tableau vide sans adresse : erreur plutôt que plantage.
        guard !bytes.isEmpty else { throw BackupCryptoError.emptyPassword }
        var output = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeBufferPointer { passwordBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                passwordBuffer.baseAddress!.withMemoryRebound(to: Int8.self, capacity: max(1, bytes.count)) { passwordPointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, bytes.count,
                                         saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         &output, length)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.system("dérivation de la clé (code \(status))") }
        return Data(output)
    }

    /// Clé de chiffrement et clé de contrôle, tirées de la clé maîtresse PBKDF2 par HKDF.
    static func keys(password: String, salt: Data, iterations: Int) throws -> (encryption: SymmetricKey, check: SymmetricKey) {
        let master = SymmetricKey(data: try pbkdf2(password: password, salt: salt, iterations: iterations))
        let encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: encryptionInfo, outputByteCount: 32)
        let check = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: checkInfo, outputByteCount: 32)
        return (encryption, check)
    }

    static func passwordCheck(_ key: SymmetricKey, salt: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: checkMessage + salt, using: key))
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw BackupCryptoError.system("générateur aléatoire indisponible")
        }
        return Data(bytes)
    }

    // MARK: Chiffrement

    /// Chiffre `plaintext` ; `header` donne les informations en clair (date, type, nombres), le sel,
    /// le nonce et le contrôle sont tirés ici.
    public static func seal(_ plaintext: Data, password: String, iterations: Int = defaultIterations,
                            createdAt: Date, kind: BackupKind, appVersion: String, appBuild: String,
                            fileCount: Int, preferenceCount: Int, secretCount: Int) throws -> Data {
        guard !password.isEmpty else { throw BackupCryptoError.emptyPassword }
        guard iterationRange.contains(iterations) else { throw BackupCryptoError.system("nombre d’itérations hors bornes") }
        let salt = try randomBytes(saltBytes)
        let nonceData = try randomBytes(nonceBytes)
        let keys = try keys(password: password, salt: salt, iterations: iterations)
        let header = BackupEncryptedHeader(keyDerivation: .init(iterations: iterations, salt: salt), nonce: nonceData,
                                           passwordCheck: passwordCheck(keys.check, salt: salt), createdAt: createdAt, kind: kind,
                                           appVersion: appVersion, appBuild: appBuild, fileCount: fileCount,
                                           preferenceCount: preferenceCount, secretCount: secretCount)
        let headerData = try BackupEngine.encoder().encode(header)
        var prefix = magic
        prefix.append(bigEndian(UInt32(headerData.count)))
        prefix.append(headerData)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(plaintext, using: keys.encryption, nonce: try AES.GCM.Nonce(data: nonceData), authenticating: prefix)
        } catch {
            throw BackupCryptoError.system(error.localizedDescription)
        }
        return prefix + box.ciphertext + box.tag
    }

    /// En-tête en clair (sans mot de passe) et position des données chiffrées.
    public static func header(of data: Data) throws -> (header: BackupEncryptedHeader, prefixLength: Int) {
        guard isEncrypted(data) else { throw BackupCryptoError.notEncrypted }
        let bytes = [UInt8](data.prefix(magic.count + 4))
        guard bytes.count == magic.count + 4 else { throw BackupCryptoError.malformed("en-tête tronqué") }
        let length = bytes[magic.count...].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maxHeaderBytes, data.count >= magic.count + 4 + length + tagBytes else {
            throw BackupCryptoError.malformed("en-tête tronqué")
        }
        let start = data.startIndex + magic.count + 4
        let header: BackupEncryptedHeader
        do {
            header = try BackupEngine.decoder().decode(BackupEncryptedHeader.self, from: data[start..<(start + length)])
        } catch {
            throw BackupCryptoError.malformed("en-tête illisible")
        }
        guard header.format == BackupEncryptedHeader.formatName else { throw BackupCryptoError.malformed("format inconnu") }
        guard header.version <= BackupEncryptedHeader.currentVersion else {
            throw BackupCryptoError.unsupported("format chiffré \(header.version), plus récent : mettez NetScope à jour")
        }
        guard header.keyDerivation.algorithm == kdfName else { throw BackupCryptoError.unsupported("dérivation «\u{00A0}\(header.keyDerivation.algorithm)\u{00A0}»") }
        guard header.cipher == cipherName else { throw BackupCryptoError.unsupported("chiffrement «\u{00A0}\(header.cipher)\u{00A0}»") }
        guard iterationRange.contains(header.keyDerivation.iterations) else { throw BackupCryptoError.unsupported("nombre d’itérations hors bornes") }
        guard header.keyDerivation.salt.count == saltBytes, header.nonce.count == nonceBytes, header.passwordCheck.count == 32 else {
            throw BackupCryptoError.malformed("paramètres de l’en-tête invalides")
        }
        return (header, magic.count + 4 + length)
    }

    /// Déchiffre : mot de passe vérifié d'abord, puis intégrité de tout le fichier (en-tête compris).
    /// Rien n'est renvoyé si une seule vérification échoue.
    public static func open(_ data: Data, password: String) throws -> (header: BackupEncryptedHeader, plaintext: Data) {
        let (header, prefixLength) = try header(of: data)
        guard !password.isEmpty else { throw BackupCryptoError.passwordRequired }
        let salt = header.keyDerivation.salt
        let keys = try keys(password: password, salt: salt, iterations: header.keyDerivation.iterations)
        guard HMAC<SHA256>.isValidAuthenticationCode(header.passwordCheck, authenticating: checkMessage + salt, using: keys.check) else {
            throw BackupCryptoError.wrongPassword
        }
        let start = data.startIndex
        let prefix = data[start..<(start + prefixLength)]
        let body = data[(start + prefixLength)...]
        guard body.count >= tagBytes else { throw BackupCryptoError.tampered }
        let ciphertext = body.prefix(body.count - tagBytes)
        let tag = body.suffix(tagBytes)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: header.nonce), ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: keys.encryption, authenticating: prefix)
            return (header, plaintext)
        } catch {
            throw BackupCryptoError.tampered
        }
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}

// MARK: - Force du mot de passe

/// Estimation simple de la force d'un mot de passe (longueur, variété, motifs évidents), pour
/// l'indicateur de l'écran : une aide à choisir, pas une garantie.
public struct BackupPasswordStrength: Equatable, Sendable {
    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case vide, tropCourt, faible, moyen, bon, excellent

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .vide: return "Aucun mot de passe"
            case .tropCourt: return "Trop court"
            case .faible: return "Faible"
            case .moyen: return "Moyen"
            case .bon: return "Bon"
            case .excellent: return "Excellent"
            }
        }
    }

    /// Longueur minimale acceptée pour chiffrer.
    public static let minimumLength = 8
    /// Mots de passe et fragments trop courants : ils ne comptent presque pas.
    static let commonFragments = ["password", "motdepasse", "netscope", "azerty", "qwerty", "123456", "abcdef",
                                  "admin", "letmein", "bonjour", "soleil", "fortinet", "fortigate", "welcome"]

    public var level: Level
    /// Entropie estimée, en bits.
    public var bits: Double
    public var hint: String

    /// Vrai si ce mot de passe peut servir à chiffrer.
    public var isAcceptable: Bool { level >= .faible }

    public static func evaluate(_ password: String) -> BackupPasswordStrength {
        let characters = Array(password)
        guard !characters.isEmpty else { return .init(level: .vide, bits: 0, hint: "Au moins \(minimumLength) caractères.") }
        if characters.count < minimumLength {
            return .init(level: .tropCourt, bits: 0, hint: "Au moins \(minimumLength) caractères (\(characters.count) pour l’instant).")
        }
        var pool = 0
        if characters.contains(where: { $0.isLowercase }) { pool += 26 }
        if characters.contains(where: { $0.isUppercase }) { pool += 26 }
        if characters.contains(where: { $0.isNumber }) { pool += 10 }
        if characters.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { pool += 33 }
        if characters.contains(where: { $0.isWhitespace }) { pool += 1 }
        if characters.contains(where: { $0.unicodeScalars.contains { $0.value > 0x7F } }) { pool += 40 }
        // Caractères répétés à la suite (« aaaa ») et motifs courants : comptés une seule fois.
        var effective = 0.0
        var previous: Character?
        for character in characters {
            effective += character == previous ? 0.25 : 1
            previous = character
        }
        let lower = password.lowercased()
        var common = false
        for fragment in commonFragments where lower.contains(fragment) {
            effective -= Double(fragment.count) * 0.8
            common = true
        }
        effective = max(1, effective)
        let unique = Set(characters).count
        let bits = effective * log2(Double(max(pool, 2))) * (unique <= 3 ? 0.4 : 1)
        let level: Level
        switch bits {
        case ..<36: level = .faible
        case ..<60: level = .moyen
        case ..<80: level = .bon
        default: level = .excellent
        }
        let hint: String
        if common {
            hint = "Évitez les mots courants («\u{00A0}motdepasse\u{00A0}», «\u{00A0}netscope\u{00A0}», «\u{00A0}123456\u{00A0}»…)."
        } else if level < .bon {
            hint = "Allongez-le ou mélangez majuscules, chiffres et symboles ; une phrase de quatre ou cinq mots convient bien."
        } else {
            hint = "Gardez-le en lieu sûr (gestionnaire de mots de passe) : sans lui, la sauvegarde est perdue."
        }
        return .init(level: level, bits: bits, hint: hint)
    }
}
