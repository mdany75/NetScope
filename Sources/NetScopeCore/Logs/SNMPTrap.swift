import Foundation

// Note 43 : traps SNMP v1 (RFC 1157, Trap-PDU) et v2c (RFC 3416, SNMPv2-Trap et InformRequest),
// décodées en BER à partir des octets reçus. SNMPv3 n'est pas pris en charge (refus expliqué).
// La communauté reçue sert seulement à la vérification facultative : elle n'est jamais gardée
// dans le journal (les communautés vivent au Trousseau).

/// Une trap reçue.
public struct SNMPTrap: Hashable, Sendable {
    /// 0 : SNMPv1, 1 : SNMPv2c.
    public var version: Int
    public var community: String
    /// OID de la notification (snmpTrapOID.0 en v2c, déduit de generic/specific en v1, RFC 3584).
    public var trapOID: SNMPOID
    /// v1 : entreprise, adresse de l'agent, generic-trap et specific-trap.
    public var enterprise: SNMPOID?
    public var agentAddress: IPv4Address?
    public var genericTrap: Int?
    public var specificTrap: Int?
    /// sysUpTime de l'agent (centièmes de seconde).
    public var uptime: UInt32?
    /// Données de la trap (sans sysUpTime.0 ni snmpTrapOID.0 en v2c).
    public var varbinds: [SNMPVarBind]
    /// InformRequest (v2c) : l'émetteur attend un accusé de réception.
    public var isInform: Bool
    public var requestID: Int32?

    public var versionLabel: String { version == 0 ? "SNMPv1" : "SNMPv2c" }
}

/// Décodage BER des traps.
public enum SNMPTrapDecoder {
    public static let sysUpTime = SNMPOID(stringLiteral: "1.3.6.1.2.1.1.3.0")
    public static let snmpTrapOID = SNMPOID(stringLiteral: "1.3.6.1.6.3.1.1.4.1.0")
    /// Préfixe des traps génériques (RFC 3584, section 3.1) : coldStart = .1 … egpNeighborLoss = .6.
    public static let genericPrefix = SNMPOID(stringLiteral: "1.3.6.1.6.3.1.1.5")
    static let trapV1Tag: UInt8 = 0xA4

    public static func decode(_ bytes: [UInt8]) throws -> SNMPTrap {
        var outer = SNMPBERReader(bytes)
        var message = try outer.readConstructed(expecting: SNMPTag.sequence).reader
        let version = try message.readInteger()
        guard version == 0 || version == 1 else {
            throw SNMPDecodingError(version == 3 ? "trap SNMPv3 (non prise en charge\u{00A0}: utilisez v2c)" : "version \(version) inconnue")
        }
        let community = String(decoding: try message.readOctetString(), as: UTF8.self)
        let (tag, pdu) = try message.readConstructed()
        var reader = pdu
        switch tag {
        case trapV1Tag:
            let enterprise = try reader.readOID()
            let agent = try reader.readValue()
            let generic = Int(try reader.readInteger())
            let specific = Int(try reader.readInteger())
            let stamp = try reader.readValue()
            let varbinds = try readVarbinds(&reader)
            var agentAddress: IPv4Address?
            if case .ipAddress(let ip) = agent { agentAddress = ip }
            var uptime: UInt32?
            if case .timeTicks(let ticks) = stamp { uptime = ticks }
            let oid = (0...5).contains(generic) ? genericPrefix.appending(UInt32(generic + 1))
                : enterprise.appending(0, UInt32(clamping: max(0, specific)))
            return SNMPTrap(version: 0, community: community, trapOID: oid, enterprise: enterprise, agentAddress: agentAddress,
                            genericTrap: generic, specificTrap: specific, uptime: uptime, varbinds: varbinds,
                            isInform: false, requestID: nil)
        case SNMPPDUType.trap.rawValue, SNMPPDUType.informRequest.rawValue:
            guard version == 1 else { throw SNMPDecodingError("PDU v2 dans un message v1") }
            let requestID = try reader.readInteger()
            _ = try reader.readInteger()
            _ = try reader.readInteger()
            var varbinds = try readVarbinds(&reader)
            var uptime: UInt32?
            if let index = varbinds.firstIndex(where: { $0.oid == sysUpTime }) {
                if case .timeTicks(let ticks) = varbinds[index].value { uptime = ticks }
                varbinds.remove(at: index)
            }
            guard let index = varbinds.firstIndex(where: { $0.oid == snmpTrapOID }), case .oid(let oid) = varbinds[index].value else {
                throw SNMPDecodingError("snmpTrapOID.0 absent")
            }
            varbinds.remove(at: index)
            return SNMPTrap(version: 1, community: community, trapOID: oid, uptime: uptime, varbinds: varbinds,
                            isInform: tag == SNMPPDUType.informRequest.rawValue,
                            requestID: Int32(clamping: requestID))
        default:
            throw SNMPDecodingError("ce n’est pas une trap (PDU 0x\(String(tag, radix: 16)))")
        }
    }

    static func readVarbinds(_ reader: inout SNMPBERReader) throws -> [SNMPVarBind] {
        var list = try reader.readConstructed(expecting: SNMPTag.sequence).reader
        var result: [SNMPVarBind] = []
        while !list.isAtEnd {
            var bind = try list.readConstructed(expecting: SNMPTag.sequence).reader
            let oid = try bind.readOID()
            result.append(SNMPVarBind(oid: oid, value: try bind.readValue()))
        }
        return result
    }

    // MARK: Encodage

    /// Accusé de réception d'un InformRequest : Response avec le même request-id et les mêmes données.
    public static func informResponse(to trap: SNMPTrap) -> [UInt8]? {
        guard trap.isInform, let requestID = trap.requestID else { return nil }
        var varbinds = [SNMPVarBind(oid: sysUpTime, value: .timeTicks(trap.uptime ?? 0)),
                        SNMPVarBind(oid: snmpTrapOID, value: .oid(trap.trapOID))]
        varbinds += trap.varbinds
        return SNMPMessage(version: 1, community: trap.community,
                           pdu: SNMPPDU(type: .response, requestID: requestID, varbinds: varbinds)).encoded()
    }

    /// Trap v2c (pour l'essai envoyé à soi-même et les tests).
    public static func encodeV2(community: String, trapOID: SNMPOID, uptime: UInt32, varbinds: [SNMPVarBind],
                                requestID: Int32 = 1, inform: Bool = false) -> [UInt8] {
        let all = [SNMPVarBind(oid: sysUpTime, value: .timeTicks(uptime)), SNMPVarBind(oid: snmpTrapOID, value: .oid(trapOID))] + varbinds
        return SNMPMessage(version: 1, community: community,
                           pdu: SNMPPDU(type: inform ? .informRequest : .trap, requestID: requestID, varbinds: all)).encoded()
    }

    /// Trap v1 (Trap-PDU).
    public static func encodeV1(community: String, enterprise: SNMPOID, agent: IPv4Address, generic: Int, specific: Int,
                                uptime: UInt32, varbinds: [SNMPVarBind]) -> [UInt8] {
        let binds = SNMPBER.sequence(varbinds.map { SNMPBER.sequence([SNMPBER.encode(.oid($0.oid)), SNMPBER.encode($0.value)]) })
        let pdu = SNMPBER.sequence([SNMPBER.encode(.oid(enterprise)), SNMPBER.encode(.ipAddress(agent)),
                                    SNMPBER.encode(.integer(Int64(generic))), SNMPBER.encode(.integer(Int64(specific))),
                                    SNMPBER.encode(.timeTicks(uptime)), binds], tag: trapV1Tag)
        return SNMPBER.sequence([SNMPBER.encode(.integer(0)), SNMPBER.encode(.octetString(Array(community.utf8))), pdu])
    }
}

// MARK: - Traps connues

/// Une trap connue : nom MIB, libellé français et gravité retenue dans le journal.
public struct SNMPTrapKind: Sendable, Hashable {
    public var oid: SNMPOID
    public var name: String
    public var label: String
    public var severity: LogSeverity

    init(_ oid: String, _ name: String, _ label: String, _ severity: LogSeverity) {
        self.oid = SNMPOID(stringLiteral: oid)
        self.name = name
        self.label = label
        self.severity = severity
    }
}

/// Catalogue des traps reconnues : génériques (RFC 3418, IF-MIB), FORTINET-CORE-MIB
/// (1.3.6.1.4.1.12356.100.1.3.0) et FORTINET-FORTIGATE-MIB (1.3.6.1.4.1.12356.101.2.0).
public enum SNMPTrapCatalog {
    public static let coldStart = "1.3.6.1.6.3.1.1.5.1"
    public static let linkDown = "1.3.6.1.6.3.1.1.5.3"
    public static let linkUp = "1.3.6.1.6.3.1.1.5.4"
    public static let authenticationFailure = "1.3.6.1.6.3.1.1.5.5"

    public static let known: [SNMPTrapKind] = [
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.1", "coldStart", "Démarrage à froid (redémarrage)", .warning),
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.2", "warmStart", "Redémarrage à chaud", .notice),
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.3", "linkDown", "Lien tombé", .error),
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.4", "linkUp", "Lien rétabli", .notice),
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.5", "authenticationFailure", "Échec d’authentification SNMP", .warning),
        SNMPTrapKind("1.3.6.1.6.3.1.1.5.6", "egpNeighborLoss", "Voisin EGP perdu", .error),
        // FORTINET-CORE-MIB
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.101", "fnTrapCpuThreshold", "Processeur au-delà du seuil", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.102", "fnTrapMemThreshold", "Mémoire au-delà du seuil", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.103", "fnTrapLogDiskThreshold", "Disque des journaux presque plein", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.104", "fnTrapTempHigh", "Température trop élevée", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.105", "fnTrapVoltageOutOfRange", "Tension hors limites", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.106", "fnTrapPowerSupplyFailure", "Panne d’alimentation", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.108", "fnTrapFanFailure", "Panne de ventilateur", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.201", "fnTrapIpChange", "Adresse IP d’interface changée", .notice),
        SNMPTrapKind("1.3.6.1.4.1.12356.100.1.3.0.999", "fnTrapTest", "Trap d’essai", .info),
        // FORTINET-FORTIGATE-MIB
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.301", "fgTrapVpnTunUp", "Tunnel VPN monté", .notice),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.302", "fgTrapVpnTunDown", "Tunnel VPN tombé", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.401", "fgTrapHaSwitch", "Bascule HA (nouveau membre principal)", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.402", "fgTrapHaStateChange", "Changement d’état HA", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.403", "fgTrapHaHBFail", "Battement de cœur HA perdu", .critical),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.404", "fgTrapHaMemberDown", "Membre HA tombé", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.405", "fgTrapHaMemberUp", "Membre HA revenu", .notice),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.503", "fgTrapIpsSignature", "Attaque détectée (signature IPS)", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.504", "fgTrapIpsAnomaly", "Anomalie détectée (IPS)", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.505", "fgTrapIpsPkgUpdate", "Signatures IPS mises à jour", .info),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.506", "fgTrapIpsFailOpen", "IPS en mode «\u{00A0}fail open\u{00A0}»", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.601", "fgTrapAvVirus", "Virus détecté", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.605", "fgTrapAvEnterConserve", "Antivirus en mode économie de mémoire", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.606", "fgTrapAvBypass", "Antivirus contourné", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.701", "fgTrapFazDisconnect", "FortiAnalyzer déconnecté", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.801", "fgTrapWcApUp", "Borne FortiAP connectée", .notice),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.802", "fgTrapWcApDown", "Borne FortiAP déconnectée", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.901", "fgTrapFcSwUp", "FortiSwitch connecté", .notice),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.902", "fgTrapFcSwDown", "FortiSwitch déconnecté", .error),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.1102", "fgTrapPerCpuHigh", "Un cœur du processeur saturé", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.1201", "fgTrapDeviceNew", "Nouvel appareil détecté", .info),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.1301", "fgTrapDhcp", "Événement DHCP (étendue)", .warning),
        SNMPTrapKind("1.3.6.1.4.1.12356.101.2.0.1401", "fgTrapPoolUsage", "Pool d’adresses presque épuisé", .warning),
    ]

    private static let byOID: [SNMPOID: SNMPTrapKind] = Dictionary(known.map { ($0.oid, $0) }, uniquingKeysWith: { a, _ in a })

    public static func kind(_ oid: SNMPOID) -> SNMPTrapKind? { byOID[oid] }

    // Objets lus dans les données (IF-MIB, SNMPv2-MIB).
    static let ifIndex = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.1")
    static let ifDescr = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.2")
    static let ifAdminStatus = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.7")
    static let ifOperStatus = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.8")
    static let ifName = SNMPOID(stringLiteral: "1.3.6.1.2.1.31.1.1.1.1")
    static let ifAlias = SNMPOID(stringLiteral: "1.3.6.1.2.1.31.1.1.1.18")
    static let sysName = SNMPOID(stringLiteral: "1.3.6.1.2.1.1.5.0")

    /// Texte d'une valeur (chaîne lisible, sinon hexadécimal court).
    public static func text(_ value: SNMPValue) -> String {
        switch value {
        case .octetString(let bytes):
            if let string = String(bytes: bytes, encoding: .utf8), string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }) {
                return string
            }
            return bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: ":") + (bytes.count > 32 ? "…" : "")
        case .timeTicks(let ticks):
            return SNMPTrapCatalog.uptime(ticks)
        default:
            return value.stringValue ?? String(describing: value)
        }
    }

    /// « 3 j 04:12:09 » (centièmes de seconde).
    public static func uptime(_ ticks: UInt32) -> String {
        let seconds = Int(ticks / 100)
        let days = seconds / 86_400
        let clock = String(format: "%02d:%02d:%02d", seconds % 86_400 / 3600, seconds % 3600 / 60, seconds % 60)
        return days > 0 ? "\(days)\u{00A0}j \(clock)" : clock
    }

    /// Message du journal pour une trap reçue de `host` (la communauté n'est pas gardée).
    public static func message(for trap: SNMPTrap, from host: String, received: Date) -> LogMessage {
        let kind = kind(trap.trapOID)
        var fields: [String: String] = ["trap": kind?.name ?? trap.trapOID.description]
        var portName: String?
        var index: String?
        var hostname: String?
        var extras: [String] = []
        for bind in trap.varbinds {
            let value = text(bind.value)
            fields[bind.oid.description] = value
            if bind.oid.hasPrefix(ifIndex) { index = value }
            else if bind.oid.hasPrefix(ifName) { portName = value }
            else if bind.oid.hasPrefix(ifDescr) { portName = portName ?? value }
            else if bind.oid.hasPrefix(ifAlias), !value.isEmpty { fields["ifAlias"] = value }
            else if bind.oid == sysName { hostname = value }
            else if case .octetString = bind.value, !value.isEmpty, value.count <= 64 { extras.append(value) }
            if index == nil, bind.oid.hasPrefix(ifAdminStatus) || bind.oid.hasPrefix(ifOperStatus), let last = bind.oid.components.last {
                index = String(last)
            }
        }
        if let agent = trap.agentAddress, agent.value != 0 { fields["agent"] = agent.description }
        if let uptime = trap.uptime { fields["sysUpTime"] = SNMPTrapCatalog.uptime(uptime) }
        var text = kind?.label ?? "Trap \(trap.trapOID)"
        if let kind, kind.name == "linkDown" || kind.name == "linkUp" {
            var port = portName.map { "port \($0)" } ?? index.map { "ifIndex \($0)" }
            if let name = portName, let index { port = "port \(name) (ifIndex \(index))" }
            if let port { text += "\u{00A0}: " + port }
            if let alias = fields["ifAlias"] { text += " «\u{00A0}\(alias)\u{00A0}»" }
        } else if kind?.name == "coldStart" || kind?.name == "warmStart", let uptime = trap.uptime {
            text += " (en marche depuis \(SNMPTrapCatalog.uptime(uptime)))"
        } else if !extras.isEmpty {
            text += "\u{00A0}: " + extras.prefix(3).joined(separator: " · ")
        }
        if kind == nil, let generic = trap.genericTrap, generic == 6, let specific = trap.specificTrap, let enterprise = trap.enterprise {
            text = "Trap d’entreprise \(enterprise) (spécifique \(specific))" + (extras.isEmpty ? "" : "\u{00A0}: " + extras.prefix(3).joined(separator: " · "))
        }
        if trap.isInform { fields["inform"] = "oui" }
        let raw = (["\(trap.versionLabel) \(trap.isInform ? "inform" : "trap") \(trap.trapOID)"]
                   + trap.varbinds.map { "\($0.oid) = \(SNMPTrapCatalog.text($0.value))" }).joined(separator: "\n")
        return LogMessage(date: received, received: received, source: .trap, severity: kind?.severity ?? .info,
                          host: host, hostname: hostname, app: trap.versionLabel, eventID: kind?.name ?? trap.trapOID.description,
                          message: LogMessage.clip(text, LogMessage.messageLimit), fields: fields,
                          raw: LogMessage.clip(raw, LogMessage.rawLimit))
    }
}
