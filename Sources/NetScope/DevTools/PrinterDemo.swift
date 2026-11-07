import Foundation
import NetScopeCore

/// Note 91 : relevés de démonstration (`--demo`) des deux imprimantes du croquis, passés par le
/// même analyseur que les vraies réponses SNMP (aucun réseau). La HP LaserJet a son toner noir
/// sous le seuil de 15 %.
/// Captures : NETSCOPE_DEVICE=10.182.122.140 montre la carte « Consommables » de la fiche.
enum PrinterDemo {
    static let brotherMAC = "94:DD:F8:18:15:7D"
    static let hpMAC = "00:1A:2B:44:10:EE"

    static func readings(now: Date = Date()) -> [String: PrinterReading] {
        var result: [String: PrinterReading] = [:]
        if let mac = MACAddress(brotherMAC)?.description {
            result[mac] = PrinterMIB.reading(binds(supplies: [
                (3, "Black Toner Cartridge TN-2510", 1_196, 2_600),
                (9, "Drum Unit DR-2510", 7_680, 12_000),
            ], pages: 18_452, errors: [0x00, 0x00]), now: now.addingTimeInterval(-3_600))
        }
        if let mac = MACAddress(hpMAC)?.description {
            result[mac] = PrinterMIB.reading(binds(supplies: [
                (21, "Black Cartridge HP 58A CF258A", 9, 100),
                (1, "Maintenance Kit", 72, 100),
            ], pages: 48_213, errors: [0x20, 0x00], alerts: ["Black cartridge low"]), now: now.addingTimeInterval(-1_200))
        }
        return result
    }

    /// Réponses Printer-MIB et HOST-RESOURCES-MIB d'une imprimante (hrDeviceIndex 1).
    static func binds(supplies: [(type: Int64, descr: String, level: Int64, max: Int64)], pages: Int64,
                      errors: [UInt8], alerts: [String] = []) -> [SNMPVarBind] {
        var binds: [SNMPVarBind] = []
        for (offset, supply) in supplies.enumerated() {
            let index = UInt32(offset + 1)
            let row = PrinterMIBOIDs.supplies
            binds.append(SNMPVarBind(oid: row.appending(PrinterMIBOIDs.supplyClass, 1, index), value: .integer(supply.type == 4 ? 4 : 3)))
            binds.append(SNMPVarBind(oid: row.appending(PrinterMIBOIDs.supplyType, 1, index), value: .integer(supply.type)))
            binds.append(SNMPVarBind(oid: row.appending(PrinterMIBOIDs.supplyDescription, 1, index), value: .octetString(Array(supply.descr.utf8))))
            binds.append(SNMPVarBind(oid: row.appending(PrinterMIBOIDs.supplyMaxCapacity, 1, index), value: .integer(supply.max)))
            binds.append(SNMPVarBind(oid: row.appending(PrinterMIBOIDs.supplyLevel, 1, index), value: .integer(supply.level)))
        }
        binds.append(SNMPVarBind(oid: PrinterMIBOIDs.lifeCount.appending(1, 1), value: .counter32(UInt32(pages))))
        binds.append(SNMPVarBind(oid: PrinterMIBOIDs.hrPrinter.appending(1, 1), value: .integer(3)))
        binds.append(SNMPVarBind(oid: PrinterMIBOIDs.hrPrinter.appending(2, 1), value: .octetString(errors)))
        for (offset, alert) in alerts.enumerated() {
            binds.append(SNMPVarBind(oid: PrinterMIBOIDs.alertDescription.appending(1, UInt32(offset + 1)), value: .octetString(Array(alert.utf8))))
        }
        return binds
    }
}
