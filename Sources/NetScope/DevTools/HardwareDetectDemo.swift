import Foundation
import NetScopeCore

/// Note 60 : fiches matériel de la démonstration (mode --demo), lues « sur » les équipements du
/// Siège par le vrai moteur (sysDescr et ENTITY-MIB analysés, rapprochement des équipements de la
/// FortiGate). Aucun accès réseau.
///
/// - SW-CORE-01 (Cisco) : ENTITY-MIB, numéro identique au numéro saisi ;
/// - SW-ETG2-01 (Aruba) : ENTITY-MIB et sysDescr, numéro saisi différent (faute de frappe) ;
/// - imprimante HP (.140) : sysDescr seul, numéro à reprendre ; imprimante Brother : version seule ;
/// - FortiGate et borne FortiAP de l'accueil : inventaire firmware de la FortiGate du Siège.
@MainActor
enum HardwareDetectDemo {
    private struct SNMPReading {
        let ip: String
        let sysName: String
        let descr: String
        let entity: SNMPEntityRow?
        let minutesAgo: Double
    }

    private static let readings: [SNMPReading] = [
        SNMPReading(ip: "10.182.122.2", sysName: "SW-CORE-01",
                    descr: "Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)",
                    entity: SNMPEntityRow(index: 1000, physicalClass: SNMPEntityRow.chassis, descr: "C9300-48P", softwareRev: "17.09.04a",
                                          serial: "FOC2419X0AB", mfgName: "Cisco Systems Inc", modelName: "C9300-48P"),
                    minutesAgo: 4),
        SNMPReading(ip: "10.182.122.3", sysName: "SW-ETG2-01",
                    descr: "Aruba JL259A 2930F-24G-4SFP Switch, revision WC.16.11.0012, ROM WC.16.01.0009 (/ws/swbuildm/rel_ukiah_qaoff/code/build/bom(swbuildm_rel_ukiah_qaoff_rel_ukiah))",
                    entity: SNMPEntityRow(index: 1, physicalClass: SNMPEntityRow.chassis, serial: "SG03KMX0F1", mfgName: "Aruba"),
                    minutesAgo: 4),
        SNMPReading(ip: "10.182.122.140", sysName: "NPI7A4410",
                    descr: "HP ETHERNET MULTI-ENVIRONMENT,SN:VNB3R12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn",
                    entity: nil, minutesAgo: 6),
        SNMPReading(ip: "10.182.122.111", sysName: "BRN94DDF818157D",
                    descr: "Brother NC-8300w, Firmware Ver.1.07  ,MID 8C5-K9F,FID 2", entity: nil, minutesAgo: 6),
    ]

    /// Fiches détectées dans l'inventaire du Siège (après le scan de démonstration).
    static func seed(_ store: inout InventoryStore, now: Date) {
        for reading in readings {
            guard let ip = IPv4Address(reading.ip),
                  let info = SNMPHardwareInfo.combine(descr: reading.descr, entity: reading.entity) else { continue }
            store.applySNMPHardware(info, host: ip, sysName: reading.sysName, at: now.addingTimeInterval(-reading.minutesAgo * 60))
        }
        store.applyDetected(fortiGateCandidates(now: now))
        // Le numéro saisi du switch d'étage a une faute de frappe : « diffère du numéro saisi ».
        if let record = store.record(forIP: IPv4Address("10.182.122.3")!) {
            var notes = record.annotations
            notes.hardware = InvHardware(supplier: "CDW Canada", serialNumber: "SG03KMX0F7")
            store.setAnnotations(notes, for: record.key, at: now.addingTimeInterval(-85 * 86_400), recordEvent: false)
        }
    }

    /// FortiGate, FortiSwitch et FortiAP du Siège, tels que la FortiGate les décrit.
    private static func fortiGateCandidates(now: Date) -> [InvHardwareCandidate] {
        let report = FirmwareSiteReport(controllerID: FortiGateSitesDemo.siegeID, site: "Siège",
                                        report: FirmwareDemo.siege(now: now.addingTimeInterval(-25 * 60)))
        return InvHardwareMatcher.candidates(from: report, fortigateIP: IPv4Address("10.182.122.1"))
    }

    /// « Lire la fiche matériel » en démonstration : la même lecture, datée de maintenant.
    static func reading(for record: InvRecord, now: Date) -> InvDetectedHardware? {
        if let reading = readings.first(where: { $0.ip == record.ip.description }),
           let info = SNMPHardwareInfo.combine(descr: reading.descr, entity: reading.entity) {
            return InvDetectedHardware(snmp: info, readAt: now)
        }
        let matches = InvHardwareMatcher.match(fortiGateCandidates(now: now), in: [record])
        guard var hardware = matches.first?.hardware else { return nil }
        hardware.readAt = now
        return hardware
    }
}
