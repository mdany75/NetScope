import Darwin
import Foundation

// SNMP v3 avec le modèle de sécurité USM (RFC 3412, 3414, 3826, 7860) : découverte du moteur
// de l'agent, puis requête authentifiée (et chiffrée) ; les rapports d'erreur de l'agent
// (utilisateur inconnu, mauvais condensé, déchiffrement…) sont reconnus et expliqués.

/// Niveau de sécurité SNMP v3.
public enum SNMPv3Level: String, CaseIterable, Codable, Sendable {
    case noAuthNoPriv, authNoPriv, authPriv

    var flags: UInt8 {
        switch self {
        case .noAuthNoPriv: return 0
        case .authNoPriv: return 0x01
        case .authPriv: return 0x03
        }
    }
}

/// Identifiant SNMP v3 complet (les mots de passe viennent du Trousseau, jamais d'un fichier).
public struct SNMPv3Credentials: Sendable, Hashable {
    public var user: String
    public var level: SNMPv3Level
    public var auth: SNMPAuthProtocol
    public var authPassword: String
    public var priv: SNMPPrivProtocol
    public var privPassword: String
    public var context: String

    public init(user: String, level: SNMPv3Level, auth: SNMPAuthProtocol = .sha256, authPassword: String = "",
                priv: SNMPPrivProtocol = .aes128, privPassword: String = "", context: String = "") {
        self.user = user
        self.level = level
        self.auth = auth
        self.authPassword = authPassword
        self.priv = priv
        self.privPassword = privPassword
        self.context = context
    }
}

/// Paramètres de sécurité USM (msgSecurityParameters).
public struct SNMPUSMParameters: Equatable, Sendable {
    public var engineID: [UInt8]
    public var boots: Int32
    public var time: Int32
    public var user: String
    public var authParams: [UInt8]
    public var privParams: [UInt8]

    public init(engineID: [UInt8] = [], boots: Int32 = 0, time: Int32 = 0, user: String = "",
                authParams: [UInt8] = [], privParams: [UInt8] = []) {
        self.engineID = engineID
        self.boots = boots
        self.time = time
        self.user = user
        self.authParams = authParams
        self.privParams = privParams
    }
}

/// Compteurs usmStats renvoyés dans un rapport (RFC 3414 5).
public enum SNMPUSMReport: String, Sendable, Equatable {
    case unsupportedSecLevel, notInTimeWindow, unknownUserName, unknownEngineID, wrongDigest, decryptionError

    static let base: SNMPOID = "1.3.6.1.6.3.15.1.1"

    init?(oid: SNMPOID) {
        guard let suffix = oid.suffix(after: SNMPUSMReport.base), let first = suffix.first else { return nil }
        switch first {
        case 1: self = .unsupportedSecLevel
        case 2: self = .notInTimeWindow
        case 3: self = .unknownUserName
        case 4: self = .unknownEngineID
        case 5: self = .wrongDigest
        case 6: self = .decryptionError
        default: return nil
        }
    }

    public var explanation: String {
        switch self {
        case .unsupportedSecLevel: return "niveau de sécurité refusé pour cet utilisateur (essayez authPriv ou authNoPriv)"
        case .notInTimeWindow: return "horloge du moteur SNMP hors fenêtre (resynchronisation impossible)"
        case .unknownUserName: return "utilisateur SNMP v3 inconnu de l’agent"
        case .unknownEngineID: return "identifiant de moteur (engineID) inconnu"
        case .wrongDigest: return "authentification refusée : mot de passe ou protocole d’authentification incorrect"
        case .decryptionError: return "déchiffrement impossible : mot de passe ou protocole de confidentialité incorrect"
        }
    }
}

/// Message SNMP v3 décodé.
public struct SNMPv3Message: Equatable, Sendable {
    public var msgID: Int32
    public var flags: UInt8
    public var usm: SNMPUSMParameters
    public var contextEngineID: [UInt8]
    public var contextName: String
    /// PDU en clair (nil si chiffrée et non déchiffrable).
    public var pdu: SNMPPDU?
    /// scopedPDU chiffré (octets bruts), quand le message porte le drapeau priv.
    public var encrypted: [UInt8]?

    public var isAuthenticated: Bool { flags & 0x01 != 0 }
    public var isEncrypted: Bool { flags & 0x02 != 0 }
}

public enum SNMPv3Codec {
    static let securityModelUSM: Int64 = 3
    static let maxSize: Int64 = 65_507

    // MARK: Encodage

    /// Encode un message ; avec des clés, l'authentifie (HMAC) et le chiffre.
    public static func encode(msgID: Int32, pdu: SNMPPDU, usm: SNMPUSMParameters, level: SNMPv3Level, reportable: Bool = true,
                              contextEngineID: [UInt8], contextName: String,
                              auth: SNMPAuthProtocol? = nil, authKey: [UInt8] = [],
                              priv: SNMPPrivProtocol? = nil, privKey: [UInt8] = [], salt: UInt64 = 0) throws -> [UInt8] {
        let flags = level.flags | (reportable ? 0x04 : 0)
        let scoped = SNMPBER.sequence([
            SNMPBER.encode(.octetString(contextEngineID)),
            SNMPBER.encode(.octetString(Array(contextName.utf8))),
            encodePDU(pdu),
        ])
        var params = usm
        var scopedField = scoped
        if level == .authPriv, let priv {
            let result = try priv.encrypt(scoped, key: privKey, boots: usm.boots, time: usm.time, salt: salt)
            scopedField = SNMPBER.encode(.octetString(result.cipher))
            params.privParams = result.privParams
        } else {
            params.privParams = []
        }
        let macLength = (level != .noAuthNoPriv ? auth?.macLength : nil) ?? 0
        params.authParams = [UInt8](repeating: 0, count: macLength)

        let secContent = usmContent(params)
        let secTLV = SNMPBER.encode(.octetString(SNMPBER.tlv(SNMPTag.sequence, secContent)))
        let header = SNMPBER.sequence([
            SNMPBER.encode(.integer(Int64(msgID))),
            SNMPBER.encode(.integer(maxSize)),
            SNMPBER.encode(.octetString([flags])),
            SNMPBER.encode(.integer(securityModelUSM)),
        ])
        let version = SNMPBER.encode(.integer(3))
        var message = SNMPBER.sequence([version, header, secTLV, scopedField])
        if macLength > 0, let auth {
            let offset = try authParamsOffset(in: message)
            let mac = Array(auth.hmac(key: authKey, message).prefix(macLength))
            message.replaceSubrange(offset..<(offset + macLength), with: mac)
        }
        return message
    }

    static func usmContent(_ params: SNMPUSMParameters) -> [UInt8] {
        SNMPBER.encode(.octetString(params.engineID))
            + SNMPBER.encode(.integer(Int64(params.boots)))
            + SNMPBER.encode(.integer(Int64(params.time)))
            + SNMPBER.encode(.octetString(Array(params.user.utf8)))
            + SNMPBER.encode(.octetString(params.authParams))
            + SNMPBER.encode(.octetString(params.privParams))
    }

    static func encodePDU(_ pdu: SNMPPDU) -> [UInt8] {
        let bindings = pdu.varbinds.map { SNMPBER.sequence([SNMPBER.encode(.oid($0.oid)), SNMPBER.encode($0.value)]) }
        return SNMPBER.sequence([
            SNMPBER.encode(.integer(Int64(pdu.requestID))),
            SNMPBER.encode(.integer(Int64(pdu.errorStatus))),
            SNMPBER.encode(.integer(Int64(pdu.errorIndex))),
            SNMPBER.sequence(bindings),
        ], tag: pdu.type.rawValue)
    }

    /// Position absolue du contenu de msgAuthenticationParameters dans le message.
    static func authParamsOffset(in message: [UInt8]) throws -> Int {
        var outer = SNMPBERReader(message)
        var body = try outer.readConstructed(expecting: SNMPTag.sequence).reader
        _ = try body.readInteger()
        _ = try body.readConstructed(expecting: SNMPTag.sequence)
        let sec = try body.readHeader()
        guard sec.tag == SNMPTag.octetString else { throw SNMPDecodingError("paramètres de sécurité absents") }
        var secReader = SNMPBERReader(Array(message[sec.range]))
        var usm = try secReader.readConstructed(expecting: SNMPTag.sequence).reader
        _ = try usm.readOctetString()
        _ = try usm.readInteger()
        _ = try usm.readInteger()
        _ = try usm.readOctetString()
        let authHeader = try usm.readHeader()
        return sec.range.lowerBound + authHeader.range.lowerBound
    }

    // MARK: Décodage

    /// Décode un message v3 ; avec les clés, vérifie l'authentification et déchiffre.
    public static func decode(_ bytes: [UInt8], auth: SNMPAuthProtocol? = nil, authKey: [UInt8] = [],
                              priv: SNMPPrivProtocol? = nil, privKey: [UInt8] = []) throws -> SNMPv3Message {
        var outer = SNMPBERReader(bytes)
        var body = try outer.readConstructed(expecting: SNMPTag.sequence).reader
        let version = try body.readInteger()
        guard version == 3 else { throw SNMPDecodingError("version \(version) au lieu de SNMP v3") }
        var header = try body.readConstructed(expecting: SNMPTag.sequence).reader
        let msgID = try header.readInteger()
        _ = try header.readInteger()
        let flagBytes = try header.readOctetString()
        let model = try header.readInteger()
        guard model == securityModelUSM else { throw SNMPDecodingError("modèle de sécurité \(model) inconnu") }
        let flags = flagBytes.first ?? 0
        let secRaw = try body.readOctetString()
        var secReader = SNMPBERReader(secRaw)
        var usmReader = try secReader.readConstructed(expecting: SNMPTag.sequence).reader
        let engineID = try usmReader.readOctetString()
        let boots = try usmReader.readInteger()
        let time = try usmReader.readInteger()
        let user = try usmReader.readOctetString()
        let authParams = try usmReader.readOctetString()
        let privParams = try usmReader.readOctetString()
        let usm = SNMPUSMParameters(engineID: engineID, boots: Int32(clamping: boots), time: Int32(clamping: time),
                                    user: String(decoding: user, as: UTF8.self), authParams: authParams, privParams: privParams)

        if flags & 0x01 != 0, let auth, !authKey.isEmpty {
            guard authParams.count == auth.macLength else { throw SNMPv3Error.badResponseDigest }
            var zeroed = bytes
            let offset = try authParamsOffset(in: bytes)
            zeroed.replaceSubrange(offset..<(offset + authParams.count), with: [UInt8](repeating: 0, count: authParams.count))
            let expected = Array(auth.hmac(key: authKey, zeroed).prefix(auth.macLength))
            guard expected == authParams else { throw SNMPv3Error.badResponseDigest }
        }

        var message = SNMPv3Message(msgID: Int32(clamping: msgID), flags: flags, usm: usm, contextEngineID: [], contextName: "")
        var scopedBytes: [UInt8]
        if flags & 0x02 != 0 {
            let cipher = try body.readOctetString()
            message.encrypted = cipher
            guard let priv, !privKey.isEmpty else { return message }
            do {
                scopedBytes = try priv.decrypt(cipher, key: privKey, boots: usm.boots, time: usm.time, privParams: privParams)
            } catch {
                throw SNMPv3Error.responseDecryption
            }
        } else {
            let scopedHeader = try body.readHeader()
            guard scopedHeader.tag == SNMPTag.sequence else { throw SNMPDecodingError("scopedPDU attendu") }
            scopedBytes = SNMPBER.tlv(SNMPTag.sequence, Array(bytes[scopedHeader.range]))
        }
        do {
            var scopedOuter = SNMPBERReader(scopedBytes)
            var scoped = try scopedOuter.readConstructed(expecting: SNMPTag.sequence).reader
            message.contextEngineID = try scoped.readOctetString()
            message.contextName = String(decoding: try scoped.readOctetString(), as: UTF8.self)
            message.pdu = try decodePDU(&scoped)
        } catch {
            if flags & 0x02 != 0 { throw SNMPv3Error.responseDecryption }
            throw error
        }
        return message
    }

    static func decodePDU(_ reader: inout SNMPBERReader) throws -> SNMPPDU {
        let (tag, pduReader) = try reader.readConstructed()
        guard let type = SNMPPDUType(rawValue: tag) else { throw SNMPDecodingError("PDU inconnue 0x\(String(tag, radix: 16))") }
        var pdu = pduReader
        let requestID = try pdu.readInteger()
        let errorStatus = try pdu.readInteger()
        let errorIndex = try pdu.readInteger()
        var list = try pdu.readConstructed(expecting: SNMPTag.sequence).reader
        var varbinds: [SNMPVarBind] = []
        while !list.isAtEnd {
            var bind = try list.readConstructed(expecting: SNMPTag.sequence).reader
            varbinds.append(SNMPVarBind(oid: try bind.readOID(), value: try bind.readValue()))
        }
        return SNMPPDU(type: type, requestID: Int32(clamping: requestID), errorStatus: Int(errorStatus),
                       errorIndex: Int(errorIndex), varbinds: varbinds)
    }

    /// Compteur usmStats d'un rapport, s'il y en a un.
    public static func report(in pdu: SNMPPDU) -> SNMPUSMReport? {
        guard pdu.type == .report else { return nil }
        return pdu.varbinds.lazy.compactMap { SNMPUSMReport(oid: $0.oid) }.first
    }
}

public enum SNMPv3Error: Error, Equatable, LocalizedError {
    case missingUser
    case shortPassword(String)
    case report(SNMPUSMReport)
    case badResponseDigest
    case responseDecryption
    case noEngineID

    public var errorDescription: String? {
        switch self {
        case .missingUser: return "Saisissez l’utilisateur SNMP v3."
        case .shortPassword(let which): return "Mot de passe \(which) trop court : 8 caractères au moins (RFC 3414)."
        case .report(let report): return "L’agent refuse : \(report.explanation)."
        case .badResponseDigest: return "Réponse dont l’authentification ne correspond pas : mot de passe ou protocole d’authentification incorrect."
        case .responseDecryption: return "Réponse impossible à déchiffrer : mot de passe ou protocole de confidentialité incorrect."
        case .noEngineID: return "L’agent n’a pas donné son identifiant de moteur (engineID) : SNMP v3 désactivé ?"
        }
    }
}


extension SNMPv3Credentials {
    /// Vérifie l'identifiant avant tout envoi (utilisateur, mots de passe de 8 caractères au moins).
    public func validate() throws {
        guard !user.isEmpty else { throw SNMPv3Error.missingUser }
        if level != .noAuthNoPriv, authPassword.utf8.count < 8 { throw SNMPv3Error.shortPassword("d’authentification") }
        if level == .authPriv, privPassword.utf8.count < 8 { throw SNMPv3Error.shortPassword("de confidentialité") }
    }

    /// « netscope-ro · authPriv · SHA-256/AES-128 » (sans aucun secret).
    public var summary: String {
        var parts = [user.isEmpty ? "utilisateur à saisir" : user, level.rawValue]
        switch level {
        case .noAuthNoPriv: break
        case .authNoPriv: parts.append(auth.rawValue)
        case .authPriv: parts.append("\(auth.rawValue)/\(priv.rawValue)")
        }
        return parts.joined(separator: " · ")
    }

    /// Options équivalentes de net-snmp (« -v3 -l authPriv -u … -a SHA-256 -x AES »), sans les mots de passe.
    public var netSNMPOptions: String {
        var parts = ["-v3", "-l \(level.rawValue)", "-u \(user.isEmpty ? "<utilisateur>" : user)"]
        if level != .noAuthNoPriv { parts.append("-a \(auth.rawValue)") }
        if level == .authPriv { parts.append("-x \(priv == .aes128 ? "AES" : priv.rawValue)") }
        if !context.isEmpty { parts.append("-n \(context)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Session v3 (moteur de l'agent et clés en cache)

/// Requêtes SNMP v3 de toute nature (GET, GETNEXT, GETBULK) : découverte du moteur de l'agent
/// (engineID, boots, time) gardée en cache par agent, clés localisées gardées en cache par moteur
/// (le calcul sur 1 Mo de la RFC 3414 n'est fait qu'une fois), resynchronisation de l'horloge
/// (notInTimeWindow) et nouvelle découverte après un redémarrage de l'agent (unknownEngineID).
public enum SNMPv3Session {
    /// Moteur connu d'un agent : identifiant, démarrages et heure à l'instant `at`.
    struct Engine {
        var id: [UInt8]
        var boots: Int32
        var time: Int32
        var at: Date

        /// Heure du moteur estimée maintenant (RFC 3414 2.3 : fenêtre de 150 s).
        func estimatedTime(now: Date = Date()) -> Int32 {
            let elapsed = max(0, now.timeIntervalSince(at))
            return Int32(clamping: Int64(time) + Int64(elapsed.rounded(.down)))
        }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var engines: [String: Engine] = [:]
        var keys: [String: [UInt8]] = [:]
    }

    private static let cache = Cache()

    /// Oublie les moteurs et les clés en mémoire (identifiants modifiés, tests).
    public static func reset() {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.engines = [:]
        cache.keys = [:]
    }

    private static func engineKey(_ target: SNMPTarget) -> String { "\(target.host):\(target.port)" }

    private static func cachedEngine(_ target: SNMPTarget) -> Engine? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.engines[engineKey(target)]
    }

    private static func store(_ engine: Engine?, for target: SNMPTarget) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.engines[engineKey(target)] = engine
    }

    /// Clé localisée (authentification ou confidentialité) mise en cache ; l'empreinte SHA-256 du mot
    /// de passe sert de clé de cache, jamais le mot de passe lui-même.
    static func localizedKey(kind: String, password: String, engineID: [UInt8], compute: () -> [UInt8]) -> [UInt8] {
        let id = kind + "|" + SNMPCryptoBytes.hex(SNMPAuthProtocol.sha256.hash(Array(password.utf8))) + "|" + SNMPCryptoBytes.hex(engineID)
        cache.lock.lock()
        if let key = cache.keys[id] {
            cache.lock.unlock()
            return key
        }
        cache.lock.unlock()
        let key = compute()
        cache.lock.lock()
        cache.keys[id] = key
        cache.lock.unlock()
        return key
    }

    static func authKey(_ credentials: SNMPv3Credentials, engineID: [UInt8]) -> [UInt8] {
        guard credentials.level != .noAuthNoPriv else { return [] }
        return localizedKey(kind: "auth-\(credentials.auth.rawValue)", password: credentials.authPassword, engineID: engineID) {
            credentials.auth.localizedKey(password: credentials.authPassword, engineID: engineID)
        }
    }

    static func privKey(_ credentials: SNMPv3Credentials, engineID: [UInt8]) -> [UInt8] {
        guard credentials.level == .authPriv else { return [] }
        let kind = "priv-\(credentials.priv.rawValue)-\(credentials.auth.rawValue)"
        return localizedKey(kind: kind, password: credentials.privPassword, engineID: engineID) {
            credentials.priv.key(password: credentials.privPassword, engineID: engineID, auth: credentials.auth)
        }
    }

    /// Découverte (RFC 3414 4) : requête vide non authentifiée → rapport avec engineID, boots et time.
    static func discover(_ target: SNMPTarget) throws -> Engine {
        let discoveryID = SNMPClient.newRequestID()
        let discovery = try SNMPv3Codec.encode(msgID: discoveryID, pdu: SNMPPDU(type: .getRequest, requestID: discoveryID, varbinds: []),
                                               usm: SNMPUSMParameters(), level: .noAuthNoPriv, contextEngineID: [], contextName: "")
        let reply = try exchange(discovery, msgID: discoveryID, target: target) { try SNMPv3Codec.decode($0) }
        guard !reply.usm.engineID.isEmpty else { throw SNMPv3Error.noEngineID }
        let engine = Engine(id: reply.usm.engineID, boots: reply.usm.boots, time: reply.usm.time, at: Date())
        store(engine, for: target)
        return engine
    }

    /// Construit le message v3 d'une PDU (aucun réseau : utilisé aussi par les tests).
    public static func encodeRequest(_ pdu: SNMPPDU, msgID: Int32, credentials: SNMPv3Credentials, engineID: [UInt8],
                                     boots: Int32, time: Int32, salt: UInt64) throws -> [UInt8] {
        let usm = SNMPUSMParameters(engineID: engineID, boots: boots, time: time, user: credentials.user)
        return try SNMPv3Codec.encode(msgID: msgID, pdu: pdu, usm: usm, level: credentials.level,
                                      contextEngineID: engineID, contextName: credentials.context,
                                      auth: credentials.auth, authKey: authKey(credentials, engineID: engineID),
                                      priv: credentials.priv, privKey: privKey(credentials, engineID: engineID), salt: salt)
    }

    /// Décode et vérifie une réponse v3 (aucun réseau). Un rapport non authentifié est rendu tel quel.
    public static func decodeResponse(_ bytes: [UInt8], credentials: SNMPv3Credentials, engineID: [UInt8]) throws -> SNMPv3Message {
        let plain = try SNMPv3Codec.decode(bytes)
        guard plain.isAuthenticated, credentials.level != .noAuthNoPriv else { return plain }
        return try SNMPv3Codec.decode(bytes, auth: credentials.auth, authKey: authKey(credentials, engineID: engineID),
                                      priv: credentials.priv, privKey: privKey(credentials, engineID: engineID))
    }

    /// Envoie une PDU en v3 (bloquant) et rend la réponse de l'agent, error-status non vérifié.
    public static func request(_ pdu: SNMPPDU, credentials: SNMPv3Credentials, target: SNMPTarget) throws -> SNMPPDU {
        try credentials.validate()
        let cached = cachedEngine(target)
        var engine = try cached ?? discover(target)
        var rediscovered = cached == nil
        var resynchronized = false
        while true {
            let msgID = SNMPClient.newRequestID()
            var sent = pdu
            sent.requestID = msgID
            let bytes = try encodeRequest(sent, msgID: msgID, credentials: credentials, engineID: engine.id, boots: engine.boots,
                                          time: engine.estimatedTime(), salt: UInt64.random(in: 0...UInt64.max))
            let engineID = engine.id
            let reply: SNMPv3Message
            do {
                reply = try exchange(bytes, msgID: msgID, target: target) {
                    try decodeResponse($0, credentials: credentials, engineID: engineID)
                }
            } catch SNMPError.timeout(let host) {
                // Agent muet avec un moteur venu du cache : il a peut-être changé (remplacé, réinitialisé).
                if !rediscovered {
                    store(nil, for: target)
                    rediscovered = true
                    engine = try discover(target)
                    continue
                }
                throw SNMPError.timeout(host)
            }
            guard let response = reply.pdu else { throw SNMPv3Error.responseDecryption }
            if let report = SNMPv3Codec.report(in: response) {
                switch report {
                case .notInTimeWindow where !resynchronized:
                    // Le rapport donne l'heure du moteur : un seul nouvel essai.
                    resynchronized = true
                    engine = Engine(id: engine.id, boots: reply.usm.boots, time: reply.usm.time, at: Date())
                    store(engine, for: target)
                    continue
                case .unknownEngineID where !rediscovered:
                    rediscovered = true
                    engine = try discover(target)
                    continue
                default:
                    throw SNMPv3Error.report(report)
                }
            }
            // Une vraie réponse à une requête authentifiée doit être signée (et chiffrée en authPriv) :
            // sinon rien n'a été vérifié (agent mal configuré ou réponse usurpée).
            if credentials.level != .noAuthNoPriv, !reply.isAuthenticated { throw SNMPv3Error.badResponseDigest }
            if credentials.level == .authPriv, !reply.isEncrypted { throw SNMPv3Error.responseDecryption }
            guard response.type == .response else { throw SNMPError.unexpectedResponse }
            if reply.usm.engineID == engine.id, reply.usm.boots >= engine.boots {
                store(Engine(id: engine.id, boots: reply.usm.boots, time: reply.usm.time, at: Date()), for: target)
            }
            var answer = response
            answer.requestID = pdu.requestID
            return answer
        }
    }

    /// Envoi bloquant avec délai et renvois ; garde la première réponse au même msgID.
    static func exchange(_ bytes: [UInt8], msgID: Int32, target: SNMPTarget,
                         decode: ([UInt8]) throws -> SNMPv3Message) throws -> SNMPv3Message {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SNMPError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        address.sin_addr = in_addr(s_addr: target.host.value.bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw SNMPError.socket(String(cString: strerror(errno))) }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        for _ in 0...min(max(0, target.retries), 5) {
            let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if sent < 0, errno == ECONNREFUSED { throw SNMPError.unreachable(target.host.description) }
            guard sent == bytes.count else { throw SNMPError.socket(String(cString: strerror(errno))) }
            let deadline = Date().addingTimeInterval(min(max(target.timeout, 0.1), 60))
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(max(1, remaining * 1000)))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw SNMPError.socket(String(cString: strerror(errno)))
                }
                if ready == 0 { break }
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if count < 0 {
                    if errno == ECONNREFUSED { throw SNMPError.unreachable(target.host.description) }
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SNMPError.socket(String(cString: strerror(errno)))
                }
                let data = Array(buffer[0..<count])
                // Datagramme d'un autre échange (ou d'une autre version) : ignoré.
                guard let header = try? SNMPv3Codec.decode(data), header.msgID == msgID else { continue }
                return try decode(data)
            }
        }
        throw SNMPError.timeout(target.host.description)
    }
}

/// Client SNMP v3 : GET, GETNEXT, GETBULK et parcours, sur le même client que la v2c.
public final class SNMPv3Client: Sendable {
    public let host: IPv4Address
    public let port: UInt16
    public let credentials: SNMPv3Credentials
    public let timeout: TimeInterval
    public let retries: Int

    public init(host: IPv4Address, port: UInt16 = 161, credentials: SNMPv3Credentials, timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.timeout = timeout
        self.retries = retries
    }

    /// Client générique (v3 seulement, sans repli v2c).
    public var client: SNMPClient {
        SNMPClient(target: SNMPTarget(host: host, port: port, community: "", v3: credentials, timeout: timeout, retries: retries))
    }

    public func get(_ oids: [SNMPOID]) async throws -> [SNMPVarBind] {
        try credentials.validate()
        return try await client.get(oids)
    }

    public func getNext(_ oids: [SNMPOID]) async throws -> [SNMPVarBind] {
        try credentials.validate()
        return try await client.getNext(oids)
    }

    public func getBulk(_ oids: [SNMPOID], nonRepeaters: Int = 0, maxRepetitions: Int = 25) async throws -> [SNMPVarBind] {
        try credentials.validate()
        return try await client.getBulk(oids, nonRepeaters: nonRepeaters, maxRepetitions: maxRepetitions)
    }

    public func walk(_ root: SNMPOID, maxRepetitions: Int = 25, limit: Int = 20_000) async throws -> [SNMPVarBind] {
        try credentials.validate()
        return try await client.walk(root, maxRepetitions: maxRepetitions, limit: limit)
    }
}
