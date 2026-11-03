import Foundation

// Messages SNMP v2c (RFC 3416) : message = SEQUENCE { version, communauté, PDU }.

public struct SNMPVarBind: Hashable, Sendable {
    public let oid: SNMPOID
    public let value: SNMPValue

    public init(oid: SNMPOID, value: SNMPValue = .null) {
        self.oid = oid
        self.value = value
    }
}

public enum SNMPPDUType: UInt8, Sendable {
    case getRequest = 0xA0
    case getNextRequest = 0xA1
    case response = 0xA2
    case setRequest = 0xA3
    case getBulkRequest = 0xA5
    case informRequest = 0xA6
    case trap = 0xA7
    case report = 0xA8
}

/// Codes d'erreur d'une réponse (RFC 3416, error-status).
public enum SNMPErrorStatus: Int, Sendable {
    case noError = 0, tooBig, noSuchName, badValue, readOnly, genErr, noAccess, wrongType, wrongLength,
         wrongEncoding, wrongValue, noCreation, inconsistentValue, resourceUnavailable, commitFailed,
         undoFailed, authorizationError, notWritable, inconsistentName

    public var label: String {
        switch self {
        case .noError: return "aucune erreur"
        case .tooBig: return "réponse trop grande"
        case .noSuchName: return "objet inconnu"
        case .genErr: return "erreur générale de l’agent"
        case .noAccess, .authorizationError: return "accès refusé"
        default: return "erreur \(rawValue)"
        }
    }
}

public struct SNMPPDU: Hashable, Sendable {
    public var type: SNMPPDUType
    public var requestID: Int32
    /// error-status, ou non-repeaters pour GetBulk.
    public var errorStatus: Int
    /// error-index, ou max-repetitions pour GetBulk.
    public var errorIndex: Int
    public var varbinds: [SNMPVarBind]

    public init(type: SNMPPDUType, requestID: Int32, errorStatus: Int = 0, errorIndex: Int = 0, varbinds: [SNMPVarBind]) {
        self.type = type
        self.requestID = requestID
        self.errorStatus = errorStatus
        self.errorIndex = errorIndex
        self.varbinds = varbinds
    }

    public static func getBulk(requestID: Int32, nonRepeaters: Int = 0, maxRepetitions: Int, oids: [SNMPOID]) -> SNMPPDU {
        SNMPPDU(type: .getBulkRequest, requestID: requestID, errorStatus: nonRepeaters, errorIndex: maxRepetitions,
                varbinds: oids.map { SNMPVarBind(oid: $0) })
    }
}

public struct SNMPMessage: Hashable, Sendable {
    /// 0 = v1, 1 = v2c. Seule la v2c est utilisée ; la v3 n'est pas implémentée.
    public var version: Int
    public var community: String
    public var pdu: SNMPPDU

    public static let versionV2c = 1

    public init(version: Int = SNMPMessage.versionV2c, community: String, pdu: SNMPPDU) {
        self.version = version
        self.community = community
        self.pdu = pdu
    }

    public func encoded() -> [UInt8] {
        let bindings = pdu.varbinds.map { bind in
            SNMPBER.sequence([SNMPBER.encode(.oid(bind.oid)), SNMPBER.encode(bind.value)])
        }
        let pduBytes = SNMPBER.sequence([
            SNMPBER.encode(.integer(Int64(pdu.requestID))),
            SNMPBER.encode(.integer(Int64(pdu.errorStatus))),
            SNMPBER.encode(.integer(Int64(pdu.errorIndex))),
            SNMPBER.sequence(bindings),
        ], tag: pdu.type.rawValue)
        return SNMPBER.sequence([
            SNMPBER.encode(.integer(Int64(version))),
            SNMPBER.encode(.octetString(Array(community.utf8))),
            pduBytes,
        ])
    }

    public init(decoding bytes: [UInt8]) throws {
        var outer = SNMPBERReader(bytes)
        var message = try outer.readConstructed(expecting: SNMPTag.sequence).reader
        let version = try message.readInteger()
        guard version == 0 || version == 1 else {
            throw SNMPDecodingError(version == 3 ? "message SNMP v3 (non pris en charge)" : "version \(version) inconnue")
        }
        let community = try message.readOctetString()
        let (tag, pduReader) = try message.readConstructed()
        guard let type = SNMPPDUType(rawValue: tag) else { throw SNMPDecodingError("PDU inconnue 0x\(String(tag, radix: 16))") }
        var reader = pduReader
        let requestID = try reader.readInteger()
        let errorStatus = try reader.readInteger()
        let errorIndex = try reader.readInteger()
        var list = try reader.readConstructed(expecting: SNMPTag.sequence).reader
        var varbinds: [SNMPVarBind] = []
        while !list.isAtEnd {
            var bind = try list.readConstructed(expecting: SNMPTag.sequence).reader
            let oid = try bind.readOID()
            let value = try bind.readValue()
            varbinds.append(SNMPVarBind(oid: oid, value: value))
        }
        guard requestID >= Int64(Int32.min), requestID <= Int64(Int32.max) else { throw SNMPDecodingError("request-id hors limites") }
        self.version = Int(version)
        self.community = String(decoding: community, as: UTF8.self)
        self.pdu = SNMPPDU(type: type, requestID: Int32(requestID), errorStatus: Int(errorStatus),
                           errorIndex: Int(errorIndex), varbinds: varbinds)
    }
}
