import Foundation

// Note 73 : cycle PoE par SNMP en écriture, sur un switch qui n'est pas géré par une FortiGate.
// POWER-ETHERNET-MIB (RFC 3621) : pethPsePortAdminEnable.groupe.port (TruthValue : 1 = true,
// 2 = false) mis à false, attente, puis remis à true. Les identifiants d'écriture (communauté v2c
// ou utilisateur v3) sont distincts de ceux de lecture et gardés au Trousseau par l'app ; aucun
// n'apparaît dans un message d'erreur ni au journal.

/// Identifiants SNMP d'écriture (jamais écrits ailleurs qu'au Trousseau).
public struct SNMPWriteCredentials: Codable, Equatable, Sendable {
    public enum Version: String, Codable, CaseIterable, Sendable {
        case v2c, v3
        public var label: String { self == .v2c ? "SNMP v2c" : "SNMP v3" }
    }

    public var version: Version
    /// Communauté d'écriture (v2c).
    public var community: String
    public var v3User: String
    public var v3Level: SNMPv3Level
    public var v3Auth: SNMPAuthProtocol
    public var v3AuthPassword: String
    public var v3Priv: SNMPPrivProtocol
    public var v3PrivPassword: String
    public var v3Context: String

    public init(version: Version = .v2c, community: String = "", v3User: String = "", v3Level: SNMPv3Level = .authPriv,
                v3Auth: SNMPAuthProtocol = .sha256, v3AuthPassword: String = "", v3Priv: SNMPPrivProtocol = .aes128,
                v3PrivPassword: String = "", v3Context: String = "") {
        self.version = version
        self.community = community
        self.v3User = v3User
        self.v3Level = v3Level
        self.v3Auth = v3Auth
        self.v3AuthPassword = v3AuthPassword
        self.v3Priv = v3Priv
        self.v3PrivPassword = v3PrivPassword
        self.v3Context = v3Context
    }

    public var v3Credentials: SNMPv3Credentials {
        SNMPv3Credentials(user: v3User, level: v3Level, auth: v3Auth, authPassword: v3AuthPassword,
                          priv: v3Priv, privPassword: v3PrivPassword, context: v3Context)
    }

    /// Problème de saisie (nil : utilisable). `readCommunity` : la communauté de lecture, qui ne
    /// doit pas servir à écrire.
    public func problem(readCommunity: String? = nil) -> String? {
        switch version {
        case .v2c:
            let clean = community.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { return "Saisissez la communauté d’écriture." }
            if clean.lowercased() == "public" { return "«\u{00A0}public\u{00A0}» n’est pas une communauté d’écriture\u{00A0}: utilisez la communauté RW dédiée du switch." }
            if let readCommunity, !readCommunity.isEmpty, clean == readCommunity {
                return "La communauté d’écriture doit être distincte de celle de lecture."
            }
            return nil
        case .v3:
            if v3User.trimmingCharacters(in: .whitespaces).isEmpty { return "Saisissez l’utilisateur SNMP v3 d’écriture." }
            if v3Level == .noAuthNoPriv { return "Un utilisateur d’écriture doit au moins être authentifié (authNoPriv ou authPriv)." }
            if v3AuthPassword.utf8.count < 8 { return "Mot de passe d’authentification trop court (8 caractères au moins)." }
            if v3Level == .authPriv, v3PrivPassword.utf8.count < 8 { return "Mot de passe de confidentialité trop court (8 caractères au moins)." }
            return nil
        }
    }

    /// « SNMP v2c (communauté d’écriture) », « SNMP v3 · netscope-rw (authPriv) ».
    public var summary: String {
        switch version {
        case .v2c: return "SNMP v2c (communauté d’écriture)"
        case .v3: return "SNMP v3 · \(v3User) (\(v3Level.rawValue))"
        }
    }
}

/// Construction des SET de pethPsePortAdminEnable (testable sans réseau).
public enum SNMPPoEWrite {
    /// TruthValue (SNMPv2-TC).
    public static let truthTrue: Int64 = 1
    public static let truthFalse: Int64 = 2

    /// pethPsePortAdminEnable.groupe.port.
    public static func adminEnableOID(group: Int, port: Int) -> SNMPOID {
        SNMPOIDs.pethPsePortAdminEnable.appending(UInt32(max(0, group)), UInt32(max(0, port)))
    }

    /// Lien variable-valeur du SET (true : PoE autorisé, false : PoE coupé).
    public static func binding(group: Int, port: Int, enabled: Bool) -> SNMPVarBind {
        SNMPVarBind(oid: adminEnableOID(group: group, port: port), value: .integer(enabled ? truthTrue : truthFalse))
    }

    /// PDU SetRequest.
    public static func setPDU(group: Int, port: Int, enabled: Bool, requestID: Int32) -> SNMPPDU {
        SNMPPDU(type: .setRequest, requestID: requestID, varbinds: [binding(group: group, port: port, enabled: enabled)])
    }

    /// Message v2c complet (octets envoyés en UDP 161).
    public static func v2cMessage(community: String, group: Int, port: Int, enabled: Bool, requestID: Int32) -> [UInt8] {
        SNMPMessage(community: community, pdu: setPDU(group: group, port: port, enabled: enabled, requestID: requestID)).encoded()
    }

    /// Traduit une erreur SNMP du SET (sans jamais citer la communauté).
    public static func translate(_ error: Error, host: String) -> PortActionError {
        if let error = error as? PortActionError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? SNMPError {
            switch error {
            case .timeout: return .snmpNoResponse(host)
            case .agent(let status, _):
                let label = SNMPErrorStatus(rawValue: status)?.label ?? "erreur \(status)"
                switch SNMPErrorStatus(rawValue: status) {
                case .noAccess?, .authorizationError?, .notWritable?, .readOnly?, .noSuchName?, .noCreation?:
                    return .snmpWriteRefused(label)
                default:
                    return .snmp("Le switch a répondu par une erreur au SET\u{00A0}: \(label).")
                }
            default:
                return .snmp(error.errorDescription ?? "Erreur SNMP.")
            }
        }
        if let error = error as? SNMPv3Error { return .snmp(error.errorDescription ?? "Erreur SNMP v3.") }
        return .snmp(error.localizedDescription)
    }
}

/// Écrit l'état d'autorisation du PoE d'un port (protocole : remplacé par un faux dans les tests).
public protocol PoEPortWriter: Sendable {
    func setPoE(enabled: Bool) async throws
}

/// Écriture réelle par SNMP v2c ou v3 (une socket UDP par requête).
public struct SNMPPoEPortWriter: PoEPortWriter {
    public let host: IPv4Address
    public let group: Int
    public let port: Int
    public let credentials: SNMPWriteCredentials
    public let timeout: TimeInterval

    public init(host: IPv4Address, group: Int, port: Int, credentials: SNMPWriteCredentials, timeout: TimeInterval = 3) {
        self.host = host
        self.group = group
        self.port = port
        self.credentials = credentials
        self.timeout = timeout
    }

    public func setPoE(enabled: Bool) async throws {
        let bind = SNMPPoEWrite.binding(group: group, port: port, enabled: enabled)
        do {
            switch credentials.version {
            case .v2c:
                let client = SNMPClient(target: SNMPTarget(host: host, community: credentials.community, timeout: timeout, retries: 1))
                _ = try await client.request(SNMPPDU(type: .setRequest, requestID: Int32.random(in: 1...Int32.max), varbinds: [bind]))
            case .v3:
                let client = SNMPv3Client(host: host, credentials: credentials.v3Credentials, timeout: timeout, retries: 1)
                _ = try await client.set([bind])
            }
        } catch {
            throw SNMPPoEWrite.translate(error, host: host.description)
        }
    }
}

// MARK: - SET en SNMP v3

extension SNMPv3Client {
    /// Écrit les objets donnés (SetRequest) par le client v3 commun : moteur en cache, reprise de
    /// l'heure de l'agent, réponse signée (et chiffrée en authPriv) exigée, error-status vérifié.
    /// Le SET de PoE est idempotent : un renvoi après un délai dépassé ne change rien de plus.
    public func set(_ binds: [SNMPVarBind]) async throws -> [SNMPVarBind] {
        try credentials.validate()
        let pdu = SNMPPDU(type: .setRequest, requestID: SNMPClient.newRequestID(), varbinds: binds)
        return try await client.request(pdu).varbinds
    }
}
