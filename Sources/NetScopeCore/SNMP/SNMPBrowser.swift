import Foundation

// Navigateur SNMP (note 59) : noms connus des OID courants, raccourcis vers les tables utiles,
// mise en forme des valeurs (type, texte, hexadécimal, énumérations courantes) et export CSV.
// Tout est pur : la lecture elle-même passe par SNMPClient (ou l'agent en mémoire de la démo).

/// Objet nommé d'une MIB courante.
public struct SNMPMIBObject: Hashable, Sendable {
    public var oid: SNMPOID
    public var name: String
    public var mib: String

    public init(_ oid: SNMPOID, _ name: String, _ mib: String) {
        self.oid = oid
        self.name = name
        self.mib = mib
    }
}

/// Raccourci de la liste « OID courants » : une table ou un groupe à parcourir.
public struct SNMPBrowserPreset: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var oid: SNMPOID
    public var summary: String

    public init(_ name: String, _ oid: SNMPOID, _ summary: String) {
        self.name = name
        self.oid = oid
        self.summary = summary
    }
}

public enum SNMPMIB {
    /// Objets connus (groupes, tables et colonnes), du plus court au plus long n'importe : la
    /// recherche prend le préfixe le plus long.
    public static let objects: [SNMPMIBObject] = {
        var list: [SNMPMIBObject] = []
        func add(_ mib: String, _ base: String, _ names: [(UInt32, String)]) {
            let root = SNMPOID(base) ?? SNMPOID([])
            for (column, name) in names { list.append(SNMPMIBObject(root.appending(column), name, mib)) }
        }
        func one(_ mib: String, _ oid: String, _ name: String) {
            if let value = SNMPOID(oid) { list.append(SNMPMIBObject(value, name, mib)) }
        }
        let mib2 = "SNMPv2-MIB"
        one(mib2, "1.3.6.1.2.1", "mib-2")
        one(mib2, "1.3.6.1.2.1.1", "system")
        add(mib2, "1.3.6.1.2.1.1", [(1, "sysDescr"), (2, "sysObjectID"), (3, "sysUpTime"), (4, "sysContact"), (5, "sysName"),
                                    (6, "sysLocation"), (7, "sysServices"), (8, "sysORLastChange"), (9, "sysORTable")])
        add(mib2, "1.3.6.1.2.1.1.9.1", [(1, "sysORIndex"), (2, "sysORID"), (3, "sysORDescr"), (4, "sysORUpTime")])
        one(mib2, "1.3.6.1.2.1.11", "snmp")
        add(mib2, "1.3.6.1.2.1.11", [(1, "snmpInPkts"), (3, "snmpInBadVersions"), (4, "snmpInBadCommunityNames"), (30, "snmpEnableAuthenTraps")])

        let ifMIB = "IF-MIB"
        one(ifMIB, "1.3.6.1.2.1.2", "interfaces")
        one(ifMIB, "1.3.6.1.2.1.2.1", "ifNumber")
        one(ifMIB, "1.3.6.1.2.1.2.2", "ifTable")
        one(ifMIB, "1.3.6.1.2.1.2.2.1", "ifEntry")
        add(ifMIB, "1.3.6.1.2.1.2.2.1", [(1, "ifIndex"), (2, "ifDescr"), (3, "ifType"), (4, "ifMtu"), (5, "ifSpeed"), (6, "ifPhysAddress"),
                                         (7, "ifAdminStatus"), (8, "ifOperStatus"), (9, "ifLastChange"), (10, "ifInOctets"),
                                         (11, "ifInUcastPkts"), (12, "ifInNUcastPkts"), (13, "ifInDiscards"), (14, "ifInErrors"),
                                         (15, "ifInUnknownProtos"), (16, "ifOutOctets"), (17, "ifOutUcastPkts"), (18, "ifOutNUcastPkts"),
                                         (19, "ifOutDiscards"), (20, "ifOutErrors"), (21, "ifOutQLen"), (22, "ifSpecific")])
        one(ifMIB, "1.3.6.1.2.1.31", "ifMIB")
        one(ifMIB, "1.3.6.1.2.1.31.1.1", "ifXTable")
        one(ifMIB, "1.3.6.1.2.1.31.1.1.1", "ifXEntry")
        add(ifMIB, "1.3.6.1.2.1.31.1.1.1", [(1, "ifName"), (2, "ifInMulticastPkts"), (3, "ifInBroadcastPkts"), (4, "ifOutMulticastPkts"),
                                            (5, "ifOutBroadcastPkts"), (6, "ifHCInOctets"), (7, "ifHCInUcastPkts"), (8, "ifHCInMulticastPkts"),
                                            (9, "ifHCInBroadcastPkts"), (10, "ifHCOutOctets"), (11, "ifHCOutUcastPkts"),
                                            (12, "ifHCOutMulticastPkts"), (13, "ifHCOutBroadcastPkts"), (14, "ifLinkUpDownTrapEnable"),
                                            (15, "ifHighSpeed"), (16, "ifPromiscuousMode"), (17, "ifConnectorPresent"), (18, "ifAlias"),
                                            (19, "ifCounterDiscontinuityTime")])

        let ip = "IP-MIB"
        one(ip, "1.3.6.1.2.1.4", "ip")
        one(ip, "1.3.6.1.2.1.4.20.1", "ipAddrEntry")
        add(ip, "1.3.6.1.2.1.4.20.1", [(1, "ipAdEntAddr"), (2, "ipAdEntIfIndex"), (3, "ipAdEntNetMask")])
        one(ip, "1.3.6.1.2.1.4.22.1", "ipNetToMediaEntry")
        add(ip, "1.3.6.1.2.1.4.22.1", [(1, "ipNetToMediaIfIndex"), (2, "ipNetToMediaPhysAddress"), (3, "ipNetToMediaNetAddress"),
                                       (4, "ipNetToMediaType")])
        one(ip, "1.3.6.1.2.1.4.35.1", "ipNetToPhysicalEntry")
        add(ip, "1.3.6.1.2.1.4.35.1", [(4, "ipNetToPhysicalPhysAddress"), (6, "ipNetToPhysicalType"), (7, "ipNetToPhysicalState")])

        let bridge = "BRIDGE-MIB"
        one(bridge, "1.3.6.1.2.1.17", "dot1dBridge")
        add(bridge, "1.3.6.1.2.1.17.1", [(1, "dot1dBaseBridgeAddress"), (2, "dot1dBaseNumPorts"), (3, "dot1dBaseType"), (4, "dot1dBasePortTable")])
        add(bridge, "1.3.6.1.2.1.17.1.4.1", [(1, "dot1dBasePort"), (2, "dot1dBasePortIfIndex")])
        one(bridge, "1.3.6.1.2.1.17.2", "dot1dStp")
        add(bridge, "1.3.6.1.2.1.17.2", [(1, "dot1dStpProtocolSpecification"), (2, "dot1dStpPriority"), (5, "dot1dStpDesignatedRoot"),
                                         (6, "dot1dStpRootCost"), (7, "dot1dStpRootPort")])
        add(bridge, "1.3.6.1.2.1.17.2.15.1", [(1, "dot1dStpPort"), (3, "dot1dStpPortState"), (5, "dot1dStpPortPathCost")])
        one(bridge, "1.3.6.1.2.1.17.4.3", "dot1dTpFdbTable")
        add(bridge, "1.3.6.1.2.1.17.4.3.1", [(1, "dot1dTpFdbAddress"), (2, "dot1dTpFdbPort"), (3, "dot1dTpFdbStatus")])
        let qbridge = "Q-BRIDGE-MIB"
        one(qbridge, "1.3.6.1.2.1.17.7", "qBridgeMIB")
        add(qbridge, "1.3.6.1.2.1.17.7.1.2.2.1", [(2, "dot1qTpFdbPort"), (3, "dot1qTpFdbStatus")])
        add(qbridge, "1.3.6.1.2.1.17.7.1.4.2.1", [(3, "dot1qVlanFdbId"), (4, "dot1qVlanCurrentEgressPorts"), (5, "dot1qVlanCurrentUntaggedPorts"),
                                                 (6, "dot1qVlanStatus")])
        add(qbridge, "1.3.6.1.2.1.17.7.1.4.3.1", [(1, "dot1qVlanStaticName"), (2, "dot1qVlanStaticEgressPorts"),
                                                 (4, "dot1qVlanStaticUntaggedPorts"), (5, "dot1qVlanStaticRowStatus")])
        add(qbridge, "1.3.6.1.2.1.17.7.1.4.5.1", [(1, "dot1qPvid")])

        let host = "HOST-RESOURCES-MIB"
        one(host, "1.3.6.1.2.1.25", "host")
        add(host, "1.3.6.1.2.1.25.1", [(1, "hrSystemUptime"), (2, "hrSystemDate"), (5, "hrSystemNumUsers"), (6, "hrSystemProcesses"),
                                       (7, "hrSystemMaxProcesses")])
        add(host, "1.3.6.1.2.1.25.2", [(2, "hrMemorySize"), (3, "hrStorageTable")])
        add(host, "1.3.6.1.2.1.25.2.3.1", [(1, "hrStorageIndex"), (2, "hrStorageType"), (3, "hrStorageDescr"),
                                           (4, "hrStorageAllocationUnits"), (5, "hrStorageSize"), (6, "hrStorageUsed"),
                                           (7, "hrStorageAllocationFailures")])
        add(host, "1.3.6.1.2.1.25.2.1", [(1, "hrStorageOther"), (2, "hrStorageRam"), (3, "hrStorageVirtualMemory"), (4, "hrStorageFixedDisk")])
        add(host, "1.3.6.1.2.1.25.3.2.1", [(1, "hrDeviceIndex"), (2, "hrDeviceType"), (3, "hrDeviceDescr"), (5, "hrDeviceStatus")])
        add(host, "1.3.6.1.2.1.25.3.3.1", [(1, "hrProcessorFrwID"), (2, "hrProcessorLoad")])
        add(host, "1.3.6.1.2.1.25.4.2.1", [(1, "hrSWRunIndex"), (2, "hrSWRunName"), (4, "hrSWRunPath"), (7, "hrSWRunStatus")])

        let entity = "ENTITY-MIB"
        one(entity, "1.3.6.1.2.1.47", "entityMIB")
        one(entity, "1.3.6.1.2.1.47.1.1.1", "entPhysicalTable")
        add(entity, "1.3.6.1.2.1.47.1.1.1.1", [(2, "entPhysicalDescr"), (3, "entPhysicalVendorType"), (4, "entPhysicalContainedIn"),
                                               (5, "entPhysicalClass"), (6, "entPhysicalParentRelPos"), (7, "entPhysicalName"),
                                               (8, "entPhysicalHardwareRev"), (9, "entPhysicalFirmwareRev"), (10, "entPhysicalSoftwareRev"),
                                               (11, "entPhysicalSerialNum"), (12, "entPhysicalMfgName"), (13, "entPhysicalModelName"),
                                               (14, "entPhysicalAlias"), (15, "entPhysicalAssetID"), (16, "entPhysicalIsFRU")])

        let poe = "POWER-ETHERNET-MIB"
        one(poe, "1.3.6.1.2.1.105", "powerEthernetMIB")
        one(poe, "1.3.6.1.2.1.105.1.1.1", "pethPsePortEntry")
        add(poe, "1.3.6.1.2.1.105.1.1.1", [(3, "pethPsePortAdminEnable"), (4, "pethPsePortPowerPairsControlAbility"),
                                           (5, "pethPsePortPowerPairs"), (6, "pethPsePortDetectionStatus"), (7, "pethPsePortPowerPriority"),
                                           (8, "pethPsePortMPSAbsentCounter"), (9, "pethPsePortType"), (10, "pethPsePortPowerClassifications"),
                                           (11, "pethPsePortInvalidSignatureCounter"), (12, "pethPsePortPowerDeniedCounter"),
                                           (13, "pethPsePortOverLoadCounter"), (14, "pethPsePortShortCounter")])
        one(poe, "1.3.6.1.2.1.105.1.3.1.1", "pethMainPseEntry")
        add(poe, "1.3.6.1.2.1.105.1.3.1.1", [(2, "pethMainPsePower"), (3, "pethMainPseOperStatus"), (4, "pethMainPseConsumptionPower"),
                                             (5, "pethMainPseUsageThreshold")])

        let lldp = "LLDP-MIB"
        one(lldp, "1.0.8802.1.1.2", "lldpMIB")
        add(lldp, "1.0.8802.1.1.2.1.3", [(1, "lldpLocChassisIdSubtype"), (2, "lldpLocChassisId"), (3, "lldpLocSysName"), (4, "lldpLocSysDesc")])
        add(lldp, "1.0.8802.1.1.2.1.3.7.1", [(2, "lldpLocPortIdSubtype"), (3, "lldpLocPortId"), (4, "lldpLocPortDesc")])
        one(lldp, "1.0.8802.1.1.2.1.4.1", "lldpRemTable")
        add(lldp, "1.0.8802.1.1.2.1.4.1.1", [(4, "lldpRemChassisIdSubtype"), (5, "lldpRemChassisId"), (6, "lldpRemPortIdSubtype"),
                                             (7, "lldpRemPortId"), (8, "lldpRemPortDesc"), (9, "lldpRemSysName"), (10, "lldpRemSysDesc"),
                                             (11, "lldpRemSysCapSupported"), (12, "lldpRemSysCapEnabled")])
        add(lldp, "1.0.8802.1.1.2.1.4.2.1", [(3, "lldpRemManAddrIfSubtype"), (4, "lldpRemManAddrIfId")])

        one("Printer-MIB", "1.3.6.1.2.1.43", "printmib")
        one("SNMP-FRAMEWORK-MIB", "1.3.6.1.6.3.10.2.1", "snmpEngine")
        add("SNMP-FRAMEWORK-MIB", "1.3.6.1.6.3.10.2.1", [(1, "snmpEngineID"), (2, "snmpEngineBoots"), (3, "snmpEngineTime"),
                                                         (4, "snmpEngineMaxMessageSize")])
        one("SNMPv2-SMI", "1.3.6.1.4.1", "enterprises")
        one("CISCO-SMI", "1.3.6.1.4.1.9", "cisco")
        one("FORTINET-CORE-MIB", "1.3.6.1.4.1.12356", "fortinet")
        one("HP-SMI", "1.3.6.1.4.1.11", "hp")
        return list
    }()

    private static let byOID: [SNMPOID: SNMPMIBObject] = Dictionary(objects.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byName: [String: SNMPMIBObject] = Dictionary(objects.map { ($0.name.lowercased(), $0) },
                                                                     uniquingKeysWith: { first, _ in first })

    /// Objet connu le plus précis qui contient `oid`, avec le reste (l'index de la ligne).
    public static func lookup(_ oid: SNMPOID) -> (object: SNMPMIBObject, index: [UInt32])? {
        var components = oid.components
        while !components.isEmpty {
            if let object = byOID[SNMPOID(components)] {
                return (object, Array(oid.components.dropFirst(components.count)))
            }
            components.removeLast()
        }
        return nil
    }

    /// « ifDescr.12 », « sysName.0 » ; nil si rien n'est connu.
    public static func name(for oid: SNMPOID) -> String? {
        guard let found = lookup(oid) else { return nil }
        guard !found.index.isEmpty else { return found.object.name }
        return found.object.name + "." + found.index.map(String.init).joined(separator: ".")
    }

    /// Lit un OID saisi : « 1.3.6.1.2.1.1 », « .1.3.6.1.2.1.1.5.0 », « sysName.0 », « ifTable », « IF-MIB::ifDescr.3 ».
    public static func parse(_ text: String) -> SNMPOID? {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = clean.range(of: "::") { clean = String(clean[range.upperBound...]) }
        if clean.hasPrefix(".") { clean.removeFirst() }
        guard !clean.isEmpty else { return nil }
        if let oid = SNMPOID(clean), oid.components.count >= 2 { return oid }
        let parts = clean.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let object = byName[String(parts[0]).lowercased()] else { return nil }
        guard parts.count == 2 else { return object.oid }
        let suffix = parts[1].split(separator: ".").map { UInt32($0) }
        guard !suffix.isEmpty, suffix.allSatisfy({ $0 != nil }) else { return nil }
        return object.oid.appending(suffix.compactMap { $0 })
    }

    /// Raccourcis proposés dans le Navigateur SNMP.
    public static let presets: [SNMPBrowserPreset] = [
        SNMPBrowserPreset("system", "1.3.6.1.2.1.1", "Nom, description, uptime, contact et emplacement"),
        SNMPBrowserPreset("ifTable", "1.3.6.1.2.1.2.2", "Interfaces : état, vitesse, compteurs (IF-MIB)"),
        SNMPBrowserPreset("ifXTable", "1.3.6.1.2.1.31.1.1", "Noms courts, alias, compteurs 64 bits (IF-MIB)"),
        SNMPBrowserPreset("ENTITY-MIB", "1.3.6.1.2.1.47.1.1.1", "Châssis, modules, numéros de série, versions"),
        SNMPBrowserPreset("LLDP-MIB", "1.0.8802.1.1.2.1.4.1", "Voisins LLDP : nom, port, description"),
        SNMPBrowserPreset("BRIDGE-MIB", "1.3.6.1.2.1.17.4.3", "Table MAC (sans VLAN)"),
        SNMPBrowserPreset("Q-BRIDGE-MIB", "1.3.6.1.2.1.17.7.1.2.2", "Table MAC par VLAN"),
        SNMPBrowserPreset("POWER-ETHERNET-MIB", "1.3.6.1.2.1.105.1", "PoE : ports, classes, budget"),
        SNMPBrowserPreset("HOST-RESOURCES", "1.3.6.1.2.1.25", "Processeur, mémoire, disques, logiciels"),
    ]
}

// MARK: - Lignes du Navigateur

/// Opération du Navigateur SNMP.
public enum SNMPBrowserOperation: String, CaseIterable, Hashable, Sendable, Identifiable {
    case get, getNext, walk
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .get: return "GET"
        case .getNext: return "GETNEXT"
        case .walk: return "Parcours"
        }
    }

    /// Commande net-snmp équivalente.
    public var netSNMPCommand: String {
        switch self {
        case .get: return "snmpget"
        case .getNext: return "snmpgetnext"
        case .walk: return "snmpbulkwalk"
        }
    }
}

/// Une ligne de résultat : OID, nom connu, type, valeur affichée.
public struct SNMPBrowserRow: Hashable, Sendable, Identifiable {
    public var id: Int { position }
    /// Rang dans la réponse (ordre de l'agent).
    public var position: Int
    public var oid: SNMPOID
    public var value: SNMPValue

    public init(position: Int, bind: SNMPVarBind) {
        self.position = position
        self.oid = bind.oid
        self.value = bind.value
    }

    public var oidText: String { oid.description }
    public var name: String { SNMPMIB.name(for: oid) ?? "" }
    public var mib: String { SNMPMIB.lookup(oid)?.object.mib ?? "" }
    public var typeLabel: String { SNMPBrowserFormat.typeLabel(value) }
    public var valueText: String { SNMPBrowserFormat.display(value, oid: oid) }
    public var hexText: String { value.bytesValue.map { SNMPBrowserFormat.hex($0, separator: " ") } ?? "" }
    public var isException: Bool { value.isException }
    /// Clé de tri de l'OID (composante par composante, pas en texte).
    public var oidSort: String { oid.components.map { String(format: "%010u", $0) }.joined(separator: ".") }
}

public enum SNMPBrowserFormat {
    public static func typeLabel(_ value: SNMPValue) -> String {
        switch value {
        case .integer: return "INTEGER"
        case .octetString: return "OCTET STRING"
        case .null: return "NULL"
        case .oid: return "OID"
        case .ipAddress: return "IpAddress"
        case .counter32: return "Counter32"
        case .gauge32: return "Gauge32"
        case .timeTicks: return "TimeTicks"
        case .opaque: return "Opaque"
        case .counter64: return "Counter64"
        case .noSuchObject: return "noSuchObject"
        case .noSuchInstance: return "noSuchInstance"
        case .endOfMibView: return "endOfMibView"
        }
    }

    /// Valeur lisible : texte, hexadécimal (MAC sur 6 octets), durée, énumérations courantes.
    public static func display(_ value: SNMPValue, oid: SNMPOID? = nil) -> String {
        switch value {
        case .integer(let number):
            if let oid, let label = enumeration(oid: oid, value: number) { return "\(label) (\(number))" }
            return grouped(Int64(number))
        case .octetString(let bytes):
            if bytes.isEmpty { return "« »" }
            if bytes.count == 6, !isPrintable(bytes) { return hex(bytes, separator: ":").uppercased() }
            if isPrintable(bytes), let text = SNMPValue.octetString(bytes).stringValue {
                return text.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
            }
            return hex(bytes, separator: " ").uppercased()
        case .null: return "NULL"
        case .oid(let target):
            if let name = SNMPMIB.name(for: target) { return "\(target) (\(name))" }
            return target.description
        case .ipAddress(let ip): return ip.description
        case .counter32(let number): return grouped(Int64(number))
        case .gauge32(let number):
            if let oid, SNMPMIB.lookup(oid)?.object.name == "ifHighSpeed" { return "\(grouped(Int64(number)))\u{00A0}Mb/s" }
            return grouped(Int64(number))
        case .timeTicks(let ticks): return "(\(ticks)) \(duration(ticks))"
        case .opaque(let bytes): return hex(bytes, separator: " ").uppercased()
        case .counter64(let number): return grouped(number)
        case .noSuchObject: return "Aucun objet à cet OID (noSuchObject)"
        case .noSuchInstance: return "Aucune instance à cet OID (noSuchInstance)"
        case .endOfMibView: return "Fin de la MIB (endOfMibView)"
        }
    }

    /// « 12 j 4 h 20 min 05 s » (centièmes de seconde SNMP).
    public static func duration(_ ticks: UInt32) -> String {
        let total = Int(ticks / 100)
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60, seconds = total % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)\u{00A0}j") }
        if days > 0 || hours > 0 { parts.append("\(hours)\u{00A0}h") }
        parts.append("\(String(format: days > 0 || hours > 0 ? "%02d" : "%d", minutes))\u{00A0}min")
        parts.append("\(String(format: "%02d", seconds))\u{00A0}s")
        return parts.joined(separator: " ")
    }

    static func grouped<T: BinaryInteger>(_ value: T) -> String {
        let text = String(value)
        let negative = text.hasPrefix("-")
        var digits = Array(negative ? text.dropFirst() : Substring(text))
        var result: [Character] = []
        while digits.count > 3 {
            result = ["\u{202F}"] + digits.suffix(3) + result
            digits.removeLast(3)
        }
        return (negative ? "-" : "") + String(digits + result)
    }

    public static func hex(_ bytes: [UInt8], separator: String) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: separator)
    }

    static func isPrintable(_ bytes: [UInt8]) -> Bool {
        var trimmed = bytes[...]
        while trimmed.last == 0 { trimmed = trimmed.dropLast() }
        guard !trimmed.isEmpty else { return false }
        if String(bytes: Array(trimmed), encoding: .utf8) == nil { return false }
        return trimmed.allSatisfy { $0 >= 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// Libellés des énumérations les plus courantes (état des ports, type d'interface, classe d'entité, PoE).
    static func enumeration(oid: SNMPOID, value: Int64) -> String? {
        guard let name = SNMPMIB.lookup(oid)?.object.name else { return nil }
        switch name {
        case "ifAdminStatus":
            return [1: "up", 2: "down", 3: "testing"][value]
        case "ifOperStatus":
            return [1: "up", 2: "down", 3: "testing", 4: "unknown", 5: "dormant", 6: "notPresent", 7: "lowerLayerDown"][value]
        case "ifType":
            return [1: "other", 6: "ethernetCsmacd", 24: "softwareLoopback", 53: "propVirtual", 71: "ieee80211", 131: "tunnel",
                    135: "l2vlan", 136: "l3ipvlan", 161: "ieee8023adLag", 117: "gigabitEthernet"][value]
        case "entPhysicalClass":
            return [1: "other", 2: "unknown", 3: "chassis", 4: "backplane", 5: "container", 6: "powerSupply", 7: "fan",
                    8: "sensor", 9: "module", 10: "port", 11: "stack", 12: "cpu"][value]
        case "pethPsePortDetectionStatus":
            return [1: "disabled", 2: "searching", 3: "deliveringPower", 4: "fault", 5: "test", 6: "otherFault"][value]
        case "pethPsePortAdminEnable", "entPhysicalIsFRU", "ifPromiscuousMode", "ifConnectorPresent", "ifLinkUpDownTrapEnable",
             "snmpEnableAuthenTraps":
            return [1: "true", 2: "false"][value]
        case "pethPsePortPowerPriority":
            return [1: "critical", 2: "high", 3: "low"][value]
        case "pethMainPseOperStatus":
            return [1: "on", 2: "off", 3: "faulty"][value]
        case "dot1dStpPortState":
            return [1: "disabled", 2: "blocking", 3: "listening", 4: "learning", 5: "forwarding", 6: "broken"][value]
        case "dot1dTpFdbStatus", "dot1qTpFdbStatus":
            return [1: "other", 2: "invalid", 3: "learned", 4: "self", 5: "mgmt"][value]
        case "hrDeviceStatus":
            return [1: "unknown", 2: "running", 3: "warning", 4: "testing", 5: "down"][value]
        case "ipNetToMediaType", "ipNetToPhysicalType":
            return [1: "other", 2: "invalid", 3: "dynamic", 4: "static", 5: "local"][value]
        default:
            return nil
        }
    }

    /// Export CSV (séparateur « ; », comme Excel en français) : OID, nom, MIB, type, valeur, hexadécimal.
    public static func csv(_ rows: [SNMPBrowserRow]) -> String {
        func field(_ text: String) -> String {
            guard text.contains(";") || text.contains("\"") || text.contains("\n") || text.contains("\r") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["OID;Nom;MIB;Type;Valeur;Hexadécimal"]
        for row in rows {
            lines.append([row.oidText, row.name, row.mib, row.typeLabel, row.valueText, row.hexText].map(field).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Lignes copiées (tabulations), comme la sortie de snmpwalk.
    public static func text(_ rows: [SNMPBrowserRow]) -> String {
        rows.map { row in
            let name = row.name.isEmpty ? row.oidText : row.name
            return "\(name)\t\(row.typeLabel)\t\(row.valueText)"
        }.joined(separator: "\n")
    }
}

extension SNMPClient {
    /// Lecture du Navigateur SNMP : GET, GETNEXT ou parcours de `oid`. Un parcours qui ne trouve rien
    /// sous `oid` (OID d'une valeur simple, comme sysName.0) lit la valeur elle-même, comme snmpwalk.
    public func browse(_ oid: SNMPOID, operation: SNMPBrowserOperation, mode: SNMPWalkMode = .defaultBulk, limit: Int = 1_000,
                       onBatch: (@Sendable ([SNMPVarBind]) -> Void)? = nil) async throws -> SNMPWalkResult {
        try await SNMPBrowse.run(oid, operation: operation, mode: mode, limit: limit, onBatch: onBatch) { pdu in
            try await self.request(pdu, checkStatus: false)
        }
    }
}

public enum SNMPBrowse {
    /// Même lecture avec une requête fournie (client, agent en mémoire des tests et de la démo).
    public static func run(_ oid: SNMPOID, operation: SNMPBrowserOperation, mode: SNMPWalkMode = .defaultBulk, limit: Int = 1_000,
                           onBatch: (@Sendable ([SNMPVarBind]) -> Void)? = nil,
                           fetch: (SNMPPDU) async throws -> SNMPPDU) async throws -> SNMPWalkResult {
        switch operation {
        case .get, .getNext:
            let pdu = SNMPPDU(type: operation == .get ? .getRequest : .getNextRequest, requestID: SNMPClient.newRequestID(),
                              varbinds: [SNMPVarBind(oid: oid)])
            let response = try await fetch(pdu)
            if response.errorStatus == SNMPErrorStatus.noSuchName.rawValue {
                // Agent v1 : « objet inconnu » devient une ligne explicite.
                let bind = SNMPVarBind(oid: oid, value: operation == .get ? .noSuchObject : .endOfMibView)
                onBatch?([bind])
                return SNMPWalkResult(binds: [bind], end: .endOfMib, requests: 1)
            }
            if response.errorStatus != 0 { throw SNMPError.agent(status: response.errorStatus, index: response.errorIndex) }
            onBatch?(response.varbinds)
            let end: SNMPWalkEnd = response.varbinds.contains { $0.value == .endOfMibView } ? .endOfMib : .subtree
            return SNMPWalkResult(binds: response.varbinds, end: end, requests: 1)
        case .walk:
            var result = try await SNMPWalker.walk(oid, mode: mode, limit: limit, onBatch: onBatch, fetch: fetch)
            if result.binds.isEmpty {
                let response = try await fetch(SNMPPDU(type: .getRequest, requestID: SNMPClient.newRequestID(),
                                                       varbinds: [SNMPVarBind(oid: oid)]))
                result.requests += 1
                if response.errorStatus == 0, let bind = response.varbinds.first, bind.oid == oid, !bind.value.isException {
                    result.binds = [bind]
                    onBatch?([bind])
                }
            }
            return result
        }
    }
}
