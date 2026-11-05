import Foundation
import NetScopeCore

/// Démonstration (--demo) du Navigateur SNMP : la MIB d'un Catalyst 9300-48P fictif (SW-CORE-01,
/// 10.182.122.2), servie par l'agent en mémoire du moteur. Aucun paquet n'est envoyé.
/// Captures : NETSCOPE_OUTIL_DEMO=snmp ouvre l'outil ; NETSCOPE_SNMP_OID=ifXTable (ou un OID)
/// choisit le parcours affiché.
enum SNMPBrowserDemo {
    static let host = "10.182.122.2"

    static let agent = SNMPTableAgent(rows())

    /// OID montré à l'ouverture (variable NETSCOPE_SNMP_OID, sinon le groupe system).
    static var initialOID: String {
        ProcessInfo.processInfo.environment["NETSCOPE_SNMP_OID"] ?? "system"
    }

    /// Parcours immédiat (sans délai) pour l'état affiché à l'ouverture.
    static func walk(_ root: SNMPOID, limit: Int) -> (binds: [SNMPVarBind], end: SNMPWalkEnd) {
        let under = agent.rows.filter { $0.oid.hasPrefix(root) && $0.oid != root }
        if under.isEmpty, let row = agent.rows.first(where: { $0.oid == root }) { return ([row], .subtree) }
        let end: SNMPWalkEnd = under.count > limit ? .limit : (agent.rows.last.map { $0.oid.hasPrefix(root) } == true ? .endOfMib : .subtree)
        return (Array(under.prefix(limit)), end)
    }

    private static func text(_ value: String) -> SNMPValue { .octetString(Array(value.utf8)) }

    private static func rows() -> [SNMPVarBind] {
        var rows: [SNMPVarBind] = []
        func add(_ oid: SNMPOID, _ value: SNMPValue) { rows.append(SNMPVarBind(oid: oid, value: value)) }

        // system
        let system: SNMPOID = "1.3.6.1.2.1.1"
        add(system.appending(1, 0), text("Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)"))
        add(system.appending(2, 0), .oid("1.3.6.1.4.1.9.1.2494"))
        add(system.appending(3, 0), .timeTicks(105_330_500))
        add(system.appending(4, 0), text("Service TI · 418 555-0142"))
        add(system.appending(5, 0), text("SW-CORE-01"))
        add(system.appending(6, 0), text("Siège · salle des serveurs B01, baie 2"))
        add(system.appending(7, 0), .integer(6))
        add(system.appending(8, 0), .timeTicks(4_210))
        let modules: [(String, String)] = [
            ("1.3.6.1.6.3.1", "The MIB module for SNMPv2 entities"),
            ("1.3.6.1.6.3.10.3.1.1", "The SNMP Management Architecture MIB"),
            ("1.3.6.1.6.3.11.3.1.1", "The MIB for Message Processing and Dispatching"),
            ("1.3.6.1.6.3.15.2.1.1", "The management information definitions for the SNMP User-based Security Model"),
            ("1.3.6.1.6.3.16.2.2.1", "The View-based Access Control Model for SNMP"),
            ("1.3.6.1.2.1.49", "The MIB module for managing TCP implementations"),
        ]
        for (index, module) in modules.enumerated() {
            let i = UInt32(index + 1)
            add(system.appending(9, 1, 2, i), .oid(SNMPOID(module.0) ?? "1.3.6.1"))
            add(system.appending(9, 1, 3, i), text(module.1))
            add(system.appending(9, 1, 4, i), .timeTicks(4_210))
        }

        // IF-MIB : 48 ports Gi, 4 ports Te, Vlan1, Vlan30.
        struct Port { var index: UInt32; var descr: String; var name: String; var alias: String; var type: Int64; var up: Bool; var speed: UInt32 }
        var ports: [Port] = []
        let aliases = [1: "Uplink FGT-SIEGE", 3: "AP-SIEGE-01", 7: "Imprimante RH", 12: "Poste réception", 14: "Caméra quai",
                       21: "Téléphone 2104", 33: "NAS-01", 47: "Uplink SW-ETG2-01"]
        for i in 1...48 {
            let up = aliases[i] != nil || i % 4 != 0
            ports.append(Port(index: UInt32(i), descr: "GigabitEthernet1/0/\(i)", name: "Gi1/0/\(i)", alias: aliases[i] ?? "",
                              type: 6, up: up && i != 40, speed: up ? 1_000_000_000 : 10_000_000))
        }
        for i in 1...4 {
            ports.append(Port(index: UInt32(48 + i), descr: "TenGigabitEthernet1/1/\(i)", name: "Te1/1/\(i)", alias: i == 1 ? "Lien fibre SW-ETG2-01" : "",
                              type: 6, up: i == 1, speed: 4_294_967_295))
        }
        ports.append(Port(index: 101, descr: "Vlan1", name: "Vl1", alias: "", type: 53, up: true, speed: 1_000_000_000))
        ports.append(Port(index: 130, descr: "Vlan30", name: "Vl30", alias: "Téléphonie", type: 53, up: true, speed: 1_000_000_000))
        let ifEntry: SNMPOID = "1.3.6.1.2.1.2.2.1"
        let ifX: SNMPOID = "1.3.6.1.2.1.31.1.1.1"
        add("1.3.6.1.2.1.2.1.0", .integer(Int64(ports.count)))
        for port in ports {
            let i = port.index
            let seed = UInt64(i) * 7_919
            add(ifEntry.appending(1, i), .integer(Int64(i)))
            add(ifEntry.appending(2, i), text(port.descr))
            add(ifEntry.appending(3, i), .integer(port.type))
            add(ifEntry.appending(4, i), .integer(port.type == 53 ? 1500 : 9198))
            add(ifEntry.appending(5, i), .gauge32(port.speed))
            add(ifEntry.appending(6, i), .octetString([0x70, 0x0F, 0x6A, 0x91, 0x4C, UInt8(truncatingIfNeeded: i)]))
            add(ifEntry.appending(7, i), .integer(port.index == 40 ? 2 : 1))
            add(ifEntry.appending(8, i), .integer(port.up ? 1 : 2))
            add(ifEntry.appending(9, i), .timeTicks(port.up ? 4_400 + UInt32(i) * 13 : 98_000_000))
            add(ifEntry.appending(10, i), .counter32(port.up ? UInt32(truncatingIfNeeded: seed * 104_729) : 0))
            add(ifEntry.appending(13, i), .counter32(port.up ? UInt32(i % 5) : 0))
            add(ifEntry.appending(14, i), .counter32(i == 14 ? 1_284 : 0))
            add(ifEntry.appending(16, i), .counter32(port.up ? UInt32(truncatingIfNeeded: seed * 65_537) : 0))
            add(ifX.appending(1, i), text(port.name))
            add(ifX.appending(6, i), .counter64(port.up ? seed * 1_048_573 * 977 : 0))
            add(ifX.appending(10, i), .counter64(port.up ? seed * 524_287 * 991 : 0))
            add(ifX.appending(15, i), .gauge32(port.up ? (port.speed > 1_000_000_000 ? 10_000 : 1_000) : 0))
            add(ifX.appending(18, i), text(port.alias))
        }

        // ENTITY-MIB : pile d'un membre, alimentation, ventilateurs, module réseau.
        let ent: SNMPOID = "1.3.6.1.2.1.47.1.1.1.1"
        let entities: [(UInt32, String, Int64, String, String, String, String)] = [
            (1, "c93xx Stack", 11, "", "", "", ""),
            (1000, "Cisco Catalyst 9300 48-port PoE+ Switch", 3, "C9300-48P", "FOC2331X0QZ", "17.09.04a", "V02"),
            (1001, "Switch 1 - Power Supply A", 6, "PWR-C1-715WAC-P", "DTN2318V1KL", "", "V01"),
            (1002, "Switch 1 - FAN 1", 7, "", "", "", ""),
            (1003, "Switch 1 - FAN 2", 7, "", "", "", ""),
            (1064, "8x10G Uplink Module", 9, "C9300-NM-8X", "FOC2329Y1AB", "", "V01"),
        ]
        for (index, descr, cls, model, serial, software, hardware) in entities {
            add(ent.appending(2, index), text(descr))
            add(ent.appending(4, index), .integer(index == 1 ? 0 : (index == 1000 ? 1 : 1000)))
            add(ent.appending(5, index), .integer(cls))
            add(ent.appending(7, index), text(descr.components(separatedBy: " - ").last ?? descr))
            add(ent.appending(8, index), text(hardware))
            add(ent.appending(10, index), text(software))
            add(ent.appending(11, index), text(serial))
            add(ent.appending(12, index), text(cls == 11 ? "" : "Cisco Systems Inc."))
            add(ent.appending(13, index), text(model))
            add(ent.appending(16, index), .integer(model.isEmpty ? 2 : 1))
        }

        // BRIDGE-MIB et Q-BRIDGE-MIB : quelques MAC apprises.
        add("1.3.6.1.2.1.17.1.1.0", .octetString([0x70, 0x0F, 0x6A, 0x91, 0x4C, 0x00]))
        add("1.3.6.1.2.1.17.1.2.0", .integer(52))
        let macs: [([UInt8], UInt32, UInt32)] = [
            ([0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D], 7, 20), ([0x00, 0x1B, 0x63, 0x84, 0x45, 0xE6], 12, 20),
            ([0xBC, 0x24, 0x11, 0x5A, 0x0C, 0x31], 14, 40), ([0x00, 0x0B, 0x82, 0x9E, 0x22, 0x10], 21, 30),
            ([0x00, 0x11, 0x32, 0x0A, 0xB4, 0x7C], 33, 20), ([0x70, 0x4C, 0xA5, 0x31, 0x08, 0x42], 1, 1),
        ]
        for (mac, port, vlan) in macs {
            let index = mac.map(UInt32.init)
            add(("1.3.6.1.2.1.17.4.3.1.1" as SNMPOID).appending(index), .octetString(mac))
            add(("1.3.6.1.2.1.17.4.3.1.2" as SNMPOID).appending(index), .integer(Int64(port)))
            add(("1.3.6.1.2.1.17.4.3.1.3" as SNMPOID).appending(index), .integer(3))
            add(("1.3.6.1.2.1.17.7.1.2.2.1.2" as SNMPOID).appending([vlan] + index), .integer(Int64(port)))
        }

        // LLDP-MIB : voisins.
        let rem: SNMPOID = "1.0.8802.1.1.2.1.4.1.1"
        let neighbors: [(UInt32, String, String, String)] = [
            (1, "FGT-SIEGE", "port1", "FortiGate-100F v7.2.8"), (3, "AP-SIEGE-01", "eth0", "FortiAP-231F v7.2.4"),
            (47, "SW-ETG2-01", "Gi1/0/48", "Cisco IOS Software, C2960X"), (49, "SW-ETG2-01", "Te1/0/1", "Cisco IOS Software, C2960X"),
        ]
        for (index, (local, name, port, descr)) in neighbors.enumerated() {
            let key: [UInt32] = [0, local, UInt32(index + 1)]
            add(rem.appending(7).appending(key), text(port))
            add(rem.appending(8).appending(key), text(port))
            add(rem.appending(9).appending(key), text(name))
            add(rem.appending(10).appending(key), text(descr))
            add(rem.appending(12).appending(key), .octetString([name.hasPrefix("FGT") ? 0x10 : (name.hasPrefix("AP") ? 0x08 : 0x28), 0x00]))
        }

        // POWER-ETHERNET-MIB : 48 ports, budget principal.
        let pse: SNMPOID = "1.3.6.1.2.1.105.1.1.1"
        for i in UInt32(1)...48 {
            let powered = [3, 14, 21, 22, 23, 24].contains(Int(i))
            add(pse.appending(3, 1, i), .integer(1))
            add(pse.appending(6, 1, i), .integer(powered ? 3 : 2))
            add(pse.appending(7, 1, i), .integer(i == 3 ? 2 : 3))
            add(pse.appending(10, 1, i), .integer(powered ? (i == 3 ? 5 : 3) : 1))
        }
        add("1.3.6.1.2.1.105.1.3.1.1.2.1", .gauge32(715))
        add("1.3.6.1.2.1.105.1.3.1.1.3.1", .integer(1))
        add("1.3.6.1.2.1.105.1.3.1.1.4.1", .gauge32(96))

        // HOST-RESOURCES-MIB (l'IOS XE en publie une partie).
        add("1.3.6.1.2.1.25.1.1.0", .timeTicks(105_329_800))
        add("1.3.6.1.2.1.25.2.2.0", .integer(8_388_608))
        let storage: [(UInt32, String, Int64, Int64, Int64)] = [(1, "Processor memory", 1024, 1_843_200, 731_400), (2, "flash:", 4096, 2_829_312, 1_097_216)]
        for (index, descr, unit, size, used) in storage {
            add(("1.3.6.1.2.1.25.2.3.1.2" as SNMPOID).appending(index), .oid(index == 1 ? "1.3.6.1.2.1.25.2.1.2" : "1.3.6.1.2.1.25.2.1.4"))
            add(("1.3.6.1.2.1.25.2.3.1.3" as SNMPOID).appending(index), text(descr))
            add(("1.3.6.1.2.1.25.2.3.1.4" as SNMPOID).appending(index), .integer(unit))
            add(("1.3.6.1.2.1.25.2.3.1.5" as SNMPOID).appending(index), .integer(size))
            add(("1.3.6.1.2.1.25.2.3.1.6" as SNMPOID).appending(index), .integer(used))
        }
        add("1.3.6.1.2.1.25.3.3.1.2.1", .integer(7))
        return rows
    }
}
