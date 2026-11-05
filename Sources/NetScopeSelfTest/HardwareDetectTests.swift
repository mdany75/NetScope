import Foundation
import NetScopeCore

// Note 60 : fiche matériel remplie automatiquement. sysDescr d'équipements réels connus, varbinds
// ENTITY-MIB fixes, rapprochement des lectures de la FortiGate, fiches de l'inventaire. Aucun réseau.

private let hwNow = Date(timeIntervalSince1970: 1_790_000_000)

private func hwDevice(_ ip: String, _ mac: String?, host: String? = nil, vendor: String? = nil, online: Bool = true,
                      type: DeviceType = .inconnu) -> Device {
    Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), vendor: vendor, hostname: host, isOnline: online,
           firstSeen: hwNow, lastSeen: hwNow, deviceType: type)
}

private func text(_ value: String) -> SNMPValue { .octetString(Array(value.utf8)) }

private func entity(_ column: UInt32, _ index: Int, _ value: SNMPValue) -> SNMPVarBind {
    SNMPVarBind(oid: SNMPEntityOIDs.cell(column, index: index), value: value)
}

func registerHardwareDetectTests(_ suite: TestSuite) {
    suite.add("Fiche matériel : sysDescr d'équipements connus") {
        func check(_ descr: String, vendor: String?, model: String?, version: String?, serial: String? = nil,
                   objectID: String? = nil, file: String = #fileID, line: Int = #line) throws {
            let info = SNMPSysDescr.parse(descr, objectID: objectID)
            try expectEqual(info.vendor, vendor, "fabricant de « \(descr.prefix(40)) »", file: file, line: line)
            try expectEqual(info.model, model, "modèle de « \(descr.prefix(40)) »", file: file, line: line)
            try expectEqual(info.version, version, "version de « \(descr.prefix(40)) »", file: file, line: line)
            try expectEqual(info.serial, serial, "numéro de série de « \(descr.prefix(40)) »", file: file, line: line)
        }
        try check("FortiGate-60F", vendor: "Fortinet", model: "FortiGate-60F", version: nil)
        try check("FortiSwitch-248E-POE v7.2.5,build0453,230920 (GA)", vendor: "Fortinet", model: "FortiSwitch-248E-POE",
                  version: "v7.2.5 build0453")
        try check("Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M), Version 15.2(7)E2, RELEASE SOFTWARE (fc3)\r\n"
                  + "Technical Support: http://www.cisco.com/techsupport\r\nCopyright (c) 1986-2020 by Cisco Systems, Inc.",
                  vendor: "Cisco", model: "Catalyst 2960-X", version: "15.2(7)E2")
        try check("Cisco IOS Software [Amsterdam], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.3.4, RELEASE SOFTWARE (fc3)\n"
                  + "Technical Support: http://www.cisco.com/techsupport",
                  vendor: "Cisco", model: "Catalyst 9000", version: "17.3.4")
        try check("Cisco IOS Software, IOS-XE Software, Catalyst 4500 L3 Switch Software (cat4500e-UNIVERSALK9-M), Version 03.06.06E RELEASE SOFTWARE (fc1)",
                  vendor: "Cisco", model: "Catalyst 4500-E", version: "03.06.06E")
        try check("Cisco NX-OS(tm) n9000, Software (n9000-dk9), Version 9.3(8), RELEASE SOFTWARE Copyright (c) 2002-2021 by Cisco Systems, Inc.",
                  vendor: "Cisco", model: "Nexus 9000", version: "9.3(8)")
        try check("Aruba JL259A 2930F-24G-4SFP Switch, revision WC.16.11.0012, ROM WC.16.01.0009 (/ws/swbuildm/rel_ukiah_qaoff/code/build/bom(swbuildm_rel_ukiah_qaoff_rel_ukiah))",
                  vendor: "Aruba", model: "JL259A 2930F-24G-4SFP", version: "WC.16.11.0012")
        try check("ProCurve J9280A Switch 2510G-48, revision Y.11.16, ROM N.10.02, (/sw/code/build/sbm(t4a))",
                  vendor: "HPE", model: "J9280A 2510G-48", version: "Y.11.16")
        try check("HP J9773A 2530-24G-PoEP Switch, revision YA.16.04.0008, ROM YA.15.20 (/ws/swbuildm/rel_yakima_qaoff/code/build/lakes(swbuildm_rel_yakima_qaoff_rel_yakima))",
                  vendor: "HPE", model: "J9773A 2530-24G-PoEP", version: "YA.16.04.0008")
        try check("Aruba JL658A 6300M 24SFP+ 4SFP56 Swch FL.10.08.1010", vendor: "Aruba", model: "JL658A 6300M 24SFP+ 4SFP56",
                  version: "FL.10.08.1010")
        try check("Juniper Networks, Inc. ex2300-24p Ethernet Switch, kernel JUNOS 20.4R3-S2.6, Build date: 2021-12-14 23:15:57 UTC Copyright (c) 1996-2021 Juniper Networks, Inc.",
                  vendor: "Juniper", model: "EX2300-24P", version: "20.4R3-S2.6")
        try check("USW-24-PoE, 6.5.59.14777, Linux 3.6.5", vendor: "Ubiquiti", model: "USW-24-PoE", version: "6.5.59.14777")
        try check("EdgeSwitch 24-Port 250W, 1.9.3.5236436, Linux 3.6.5, 1.0.0.4857129", vendor: "Ubiquiti",
                  model: "EdgeSwitch 24-Port 250W", version: "1.9.3.5236436")
        try check("RouterOS CRS326-24G-2S+", vendor: "MikroTik", model: "CRS326-24G-2S+", version: nil)
        try check("HP ETHERNET MULTI-ENVIRONMENT,SN:VNB3R12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn",
                  vendor: "HP", model: "HP LaserJet Pro M404dn", version: nil, serial: "VNB3R12345")
        try check("HP ETHERNET MULTI-ENVIRONMENT,ROM none,JETDIRECT,JD153,EEPROM JSI23900012,CIDATE 06/17/2019",
                  vendor: "HP", model: nil, version: "JSI23900012")
        try check("Brother NC-8300w, Firmware Ver.1.07  ,MID 8C5-K9F,FID 2", vendor: "Brother", model: nil, version: "1.07")
        try check("Linux DS920plus 4.4.180+ #42962 SMP Fri Feb 10 15:23:18 CST 2023 x86_64", vendor: "Synology",
                  model: "DS920+", version: nil)
        // Linux quelconque : la version du noyau n'est pas un firmware.
        try check("Linux web01 5.15.0-91-generic #101-Ubuntu SMP Tue Nov 14 13:30:08 UTC 2023 x86_64", vendor: nil, model: nil, version: nil)
        try check("Axis Communications AB, Firmware version 10.12.182", vendor: nil, model: nil, version: "10.12.182")
        try expect(SNMPSysDescr.parse("").isEmpty, "sysDescr vide : rien")
    }

    suite.add("Fiche matériel : ENTITY-MIB, châssis d'une pile Cisco et valeurs de remplissage") {
        let binds: [SNMPVarBind] = [
            entity(SNMPEntityOIDs.physicalClass, 1, .integer(11)),
            entity(SNMPEntityOIDs.physicalClass, 1000, .integer(3)),
            entity(SNMPEntityOIDs.physicalClass, 1001, .integer(9)),
            entity(SNMPEntityOIDs.physicalClass, 2000, .integer(3)),
            entity(SNMPEntityOIDs.descr, 1, text("c93xx Stack")),
            entity(SNMPEntityOIDs.serialNum, 1, text("")),
            entity(SNMPEntityOIDs.descr, 1000, text("C9300-48P")),
            entity(SNMPEntityOIDs.modelName, 1000, text("C9300-48P")),
            entity(SNMPEntityOIDs.serialNum, 1000, text("FOC2331X0QZ ")),
            entity(SNMPEntityOIDs.softwareRev, 1000, text("17.09.04a")),
            entity(SNMPEntityOIDs.firmwareRev, 1000, text("17.9.1r[FC2]")),
            entity(SNMPEntityOIDs.mfgName, 1000, text("Cisco Systems Inc")),
            entity(SNMPEntityOIDs.modelName, 1001, text("C9300-NM-8X")),
            entity(SNMPEntityOIDs.serialNum, 1001, text("N/A")),
            entity(SNMPEntityOIDs.modelName, 2000, text("C9300-48P")),
            entity(SNMPEntityOIDs.serialNum, 2000, text("FOC2402Y1AB")),
            SNMPVarBind(oid: SNMPEntityOIDs.cell(SNMPEntityOIDs.modelName, index: 3000), value: .noSuchInstance),
        ]
        let rows = SNMPEntity.rows(binds)
        try expectEqual(rows.map(\.index), [1, 1000, 1001, 2000], "lignes par index, exception ignorée")
        try expectEqual(rows[2].serial, nil, "« N/A » écarté")
        try expectEqual(rows[1].serial, "FOC2331X0QZ", "numéro rogné")
        let main = try SNMPEntity.principal(rows).unwrap("entité principale")
        try expectEqual(main.index, 1000, "premier châssis, pas la pile")
        try expectEqual(SNMPEntity.candidateIndexes(classes: binds.filter { $0.oid.hasPrefix(SNMPEntityOIDs.column(SNMPEntityOIDs.physicalClass)) }),
                        [1000, 1001], "châssis puis module à détailler")
        let info = try SNMPHardwareInfo.combine(descr: "Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)",
                                                entity: main).unwrap("fiche combinée")
        try expectEqual(info.model, "C9300-48P", "modèle ENTITY-MIB avant sysDescr")
        try expectEqual(info.serial, "FOC2331X0QZ", "numéro de série")
        try expectEqual(info.firmware, "17.09.04a", "softwareRev avant firmwareRev")
        try expectEqual(info.vendor, "Cisco Systems Inc", "fabricant ENTITY-MIB")
        try expectEqual(info.origin, "ENTITY-MIB", "source")

        // Sans châssis utile : le premier module ; numéro tout à zéro écarté.
        let modules = SNMPEntity.rows([
            entity(SNMPEntityOIDs.physicalClass, 1, .integer(3)), entity(SNMPEntityOIDs.serialNum, 1, text("000000")),
            entity(SNMPEntityOIDs.physicalClass, 5, .integer(9)), entity(SNMPEntityOIDs.modelName, 5, text("J9773A")),
            entity(SNMPEntityOIDs.serialNum, 5, text("SG59GHX0B2")),
        ])
        try expectEqual(SNMPEntity.principal(modules)?.index, 5, "premier module quand le châssis est vide")

        // ENTITY-MIB sans modèle : sysDescr complète (deux sources).
        let mixed = try SNMPHardwareInfo.combine(descr: "Aruba JL259A 2930F-24G-4SFP Switch, revision WC.16.11.0012, ROM WC.16.01.0009",
                                                 entity: SNMPEntityRow(index: 1, physicalClass: 3, serial: "SG03KMX0F1")).unwrap("fiche mixte")
        try expectEqual(mixed.model, "JL259A 2930F-24G-4SFP", "modèle de sysDescr")
        try expectEqual(mixed.serial, "SG03KMX0F1", "numéro d'ENTITY-MIB")
        try expectEqual(mixed.firmware, "WC.16.11.0012", "version de sysDescr")
        try expectEqual(mixed.origin, "ENTITY-MIB et sysDescr", "deux sources")

        // Sans ENTITY-MIB : sysDescr seul ; rien d'utile : nil.
        let printer = try SNMPHardwareInfo.combine(descr: "HP ETHERNET MULTI-ENVIRONMENT,SN:VNB3R12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn",
                                                   entity: nil).unwrap("imprimante")
        try expectEqual(printer.origin, "sysDescr", "source sysDescr")
        try expectEqual(printer.serial, "VNB3R12345", "numéro de l'imprimante")
        try expect(SNMPHardwareInfo.combine(descr: "Linux web01 5.15.0", entity: nil) == nil, "rien d'utile : aucune fiche")

        // Lecture v3 (GET aux index devinés) : réponse fixe analysée.
        try expectEqual(SNMPHardwareReader.v3OIDs.count, 2 + 3 * 7, "sysDescr, sysObjectID et sept colonnes par index")
        let v3 = try SNMPHardwareReader.hardware(fromGet: [
            SNMPVarBind(oid: SNMPOIDs.sysDescr, value: text("FortiGate-60F")),
            SNMPVarBind(oid: SNMPOIDs.sysObjectID, value: .oid("1.3.6.1.4.1.12356.101.1.1004")),
            entity(SNMPEntityOIDs.physicalClass, 1, .integer(3)),
            entity(SNMPEntityOIDs.serialNum, 1, text("FGT60FTK2209A1B2")),
            entity(SNMPEntityOIDs.softwareRev, 1, text("v7.2.8,build1639,240313 (GA.M)")),
            SNMPVarBind(oid: SNMPEntityOIDs.cell(SNMPEntityOIDs.physicalClass, index: 1000), value: .noSuchInstance),
        ]).unwrap("fiche v3")
        try expectEqual(v3.model, "FortiGate-60F", "modèle de sysDescr")
        try expectEqual(v3.serial, "FGT60FTK2209A1B2", "numéro ENTITY-MIB")
        try expectEqual(v3.vendor, "Fortinet", "marque")
    }

    suite.add("Fiche matériel : détecté à part du saisi, Reprendre, relecture des anciens fichiers") {
        var store = InventoryStore()
        store.merge([hwDevice("10.0.0.2", "70:0F:6A:91:4C:02", host: "SW-CORE-01", vendor: "Cisco", type: .switch)], at: hwNow)
        let key = InventoryStore.key(mac: MACAddress("70:0F:6A:91:4C:02")!)
        var notes = try store.record(key).unwrap("fiche").annotations
        notes.location = "Salle B01"
        store.setAnnotations(notes, for: key, at: hwNow)
        let before = try store.record(key).unwrap("fiche").annotations

        let info = SNMPHardwareInfo(model: "C9300-48P", serial: "FOC2331X0QZ", firmware: "17.09.04a", vendor: "Cisco", origin: "ENTITY-MIB")
        try expectEqual(store.applySNMPHardware(info, host: IPv4Address("10.0.0.2")!, sysName: "SW-CORE-01", at: hwNow), key, "fiche de l'IP lue")
        var record = try store.record(key).unwrap("fiche")
        try expectEqual(record.annotations, before, "les champs saisis ne bougent pas")
        try expectEqual(record.detectedHardware?.model, "C9300-48P", "modèle détecté")
        try expectEqual(record.detectedHardware?.sourceLabel, "SNMP · ENTITY-MIB", "source affichée")
        try expectEqual(record.serialCheck, .canAdopt("FOC2331X0QZ"), "rien de saisi : Reprendre proposé")
        try expectEqual(record.detectedModelLabel, "C9300-48P", "colonne Modèle")

        try expect(store.adoptDetectedSerial(for: key, at: hwNow), "Reprendre")
        record = try store.record(key).unwrap("fiche")
        try expectEqual(record.enteredSerial, "FOC2331X0QZ", "numéro saisi rempli")
        try expectEqual(record.annotations.location, "Salle B01", "autres champs gardés")
        try expectEqual(record.serialCheck, .same, "identiques")
        try expect(!store.adoptDetectedSerial(for: key, at: hwNow), "plus rien à reprendre")
        try expect(store.events(for: key).contains { $0.kind == .fiche && $0.detail.contains("garantie") }, "modification consignée")

        // Numéro saisi différent : signalé, jamais remplacé.
        notes = record.annotations
        notes.hardware?.serialNumber = "FOC0000AAAA"
        store.setAnnotations(notes, for: key, at: hwNow)
        try expectEqual(store.record(key)?.serialCheck, .differs(entered: "FOC0000AAAA", detected: "FOC2331X0QZ"), "diffère du saisi")
        try expectEqual(store.record(key)?.serialCheck == .same, false, "pas identique")

        // Relecture sysDescr seule (fin de scan, moins fiable) : n'écrase rien de la lecture ENTITY-MIB.
        let later = hwNow.addingTimeInterval(3600)
        let weak = SNMPHardwareInfo(model: "Catalyst 9000", serial: nil, firmware: "17.9.4a", vendor: "Cisco", origin: "sysDescr")
        try expect(!store.setDetectedHardware(InvDetectedHardware(snmp: weak, readAt: later), for: key), "rien de changé")
        try expectEqual(store.record(key)?.detectedHardware?.model, "C9300-48P", "modèle ENTITY-MIB gardé")
        try expectEqual(store.record(key)?.detectedHardware?.firmware, "17.09.04a", "version ENTITY-MIB gardée")
        // Relecture ENTITY-MIB partielle : modèle et numéro gardés, version mise à jour.
        let partial = SNMPHardwareInfo(model: nil, serial: nil, firmware: "17.12.2", vendor: "Cisco", origin: "ENTITY-MIB")
        try expect(store.setDetectedHardware(InvDetectedHardware(snmp: partial, readAt: later), for: key), "changement")
        try expectEqual(store.record(key)?.detectedHardware?.model, "C9300-48P", "modèle gardé")
        try expectEqual(store.record(key)?.detectedHardware?.firmware, "17.12.2", "version à jour")
        try expectEqual(store.record(key)?.detectedHardware?.readAt, later, "date de lecture")
        // Autre numéro de série : appareil remplacé, l'ancienne fiche détectée est oubliée.
        let swapped = InvDetectedHardware(serialNumber: "FOC9999ZZZZ", source: .snmp, detail: "ENTITY-MIB", readAt: later)
        store.setDetectedHardware(swapped, for: key)
        try expectEqual(store.record(key)?.detectedHardware?.model, nil, "modèle de l'ancien appareil oublié")

        // Un scan suivant garde la fiche détectée ; l'aller-retour JSON aussi.
        store.merge([hwDevice("10.0.0.2", "70:0F:6A:91:4C:02", host: "SW-CORE-01", vendor: "Cisco", type: .switch)], at: later)
        try expectEqual(store.record(key)?.detectedHardware?.serialNumber, "FOC9999ZZZZ", "gardée après un scan")
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(InventoryStore.self, from: data)
        try expectEqual(decoded.record(key)?.detectedHardware, store.record(key)?.detectedHardware, "aller-retour JSON")
        // Fichier d'avant la 0.23.0 : pas de clé « detectedHardware ».
        var plain = InventoryStore()
        plain.merge([hwDevice("10.0.0.9", "00:1A:2B:44:10:EE")], at: hwNow)
        let old = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        try expect(!old.contains("detectedHardware"), "ancien format sans la clé")
        let reread = try JSONDecoder().decode(InventoryStore.self, from: Data(old.utf8))
        try expectEqual(reread.count, 1, "ancien fichier relu")
        try expect(reread.sortedRecords.first?.detectedHardware == nil, "rien de détecté")

        // Export CSV : colonnes Modèle, N° de série, Firmware.
        let csv = InvCSV.export(store.sortedRecords, now: later)
        let header = csv.split(separator: "\r\n").first.map(String.init) ?? ""
        try expect(header.hasSuffix(";Modèle;N° de série;Firmware"), "en-tête de l'export")
        try expect(csv.contains(";FOC0000AAAA;"), "numéro saisi exporté avant le détecté")
        let reimported = try InvCSV.parse(csv)
        try expectEqual(reimported.count, 1, "export relu à l'import")
    }

    suite.add("Fiche matériel : rapprochement des équipements de la FortiGate") {
        let report = FirmwareReadReport(
            system: FortiGateSystem(hostname: "FG-SIEGE", model: "FortiGate-60F", serial: "FGT60FTK2209A1B2", version: "v7.2.8", build: 1639),
            currentFortiOS: FortiVersion("v7.2.8 build1639"),
            switches: [FortiManagedSwitch(switchID: "S248EPTF21000123", serial: "S248EPTF21000123", name: "FSW-QUAI",
                                          model: "FS-248E-POE", osVersion: "S248EP-v7.2.5-build0453,230920 (GA)",
                                          fortilinkIP: IPv4Address("10.255.1.2"))],
            accessPoints: [FortiManagedAP(name: "FAP-ACCUEIL", serial: "FP231FTF21004567", model: "FAP-231F",
                                          firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.0.0.102")),
                           FortiManagedAP(name: "FAP-ENTREPOT", serial: "FP231FTF21009999", model: "FAP-231F",
                                          firmware: "FP231F-v7.2.8-build0436", ip: IPv4Address("10.0.0.150"))],
            readAt: hwNow)
        let site = FirmwareSiteReport(controllerID: UUID(), site: "Siège", report: report)
        let candidates = InvHardwareMatcher.candidates(from: site, fortigateIP: IPv4Address("10.0.0.1"))
        try expectEqual(candidates.count, 4, "FortiGate, FortiSwitch, deux FortiAP")
        try expectEqual(candidates.first?.hardware.firmware, "v7.2.8 build1639", "version FortiOS")
        try expectEqual(candidates.first { $0.name == "FSW-QUAI" }?.ip, nil, "adresse FortiLink jamais utilisée")
        try expectEqual(candidates.first { $0.name == "FSW-QUAI" }?.hardware.firmware, "v7.2.5 build0453", "version FortiSwitch")

        var store = InventoryStore()
        store.merge([
            hwDevice("10.0.0.1", "04:D5:90:3A:7B:11", host: "fortigate.local", vendor: "Fortinet", type: .routeur),
            hwDevice("10.0.0.102", "70:4C:A5:1E:22:9A", host: "FortiAP-231F", vendor: "Fortinet", type: .pointAcces),
            // Même IP que la seconde FortiAP, mais un autre fabricant : jamais rapproché sur l'IP seule.
            hwDevice("10.0.0.150", "B0:7B:25:44:A1:6C", host: "WKS150", vendor: "Dell", type: .poste),
            // FortiSwitch vu par le scan sur son adresse de gestion : rapproché par son nom.
            hwDevice("10.0.0.40", "E8:1C:BA:10:20:30", host: "FSW-QUAI.siege.local", vendor: "Fortinet", type: .switch),
            hwDevice("10.0.0.41", "B0:7B:25:44:9F:20", host: "poste-41", vendor: "Dell", type: .poste),
        ], at: hwNow)
        let matches = store.applyDetected(candidates)
        try expectEqual(matches.count, 3, "FortiGate, FortiAP de l'accueil et FortiSwitch")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.1")!)?.detectedHardware?.serialNumber, "FGT60FTK2209A1B2", "FortiGate par son IP")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.1")!)?.detectedHardware?.sourceLabel, "FortiGate · FG-SIEGE", "source")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.102")!)?.detectedHardware?.model, "FAP-231F", "FortiAP par son IP")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.40")!)?.detectedHardware?.model, "FS-248E-POE", "FortiSwitch par son nom")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.40")!)?.detectedHardware?.detail, "FG-SIEGE", "lu par la FortiGate")
        try expect(store.record(forIP: IPv4Address("10.0.0.150")!)?.detectedHardware == nil, "IP d'un autre fabricant : rien")
        try expect(matches.contains { $0.reason == .name } && matches.contains { $0.reason == .ip }, "raisons notées")

        // Numéro de série saisi : rapprochement le plus sûr, même sans IP ni nom.
        var notes = try store.record(forIP: IPv4Address("10.0.0.41")!).unwrap("poste").annotations
        notes.hardware = InvHardware(serialNumber: "fp231f-tf21009999")
        let posteKey = try store.record(forIP: IPv4Address("10.0.0.41")!).unwrap("poste").key
        store.setAnnotations(notes, for: posteKey, at: hwNow)
        let second = store.applyDetected(candidates)
        try expectEqual(second.first { $0.key == posteKey }?.reason, .serial, "numéro saisi (sans tiret ni casse)")

        // Nom ambigu : deux fiches du même nom, aucun rapprochement.
        var twins = InventoryStore()
        twins.merge([hwDevice("10.0.0.60", "00:11:22:33:44:01", host: "FSW-QUAI", vendor: "Fortinet"),
                     hwDevice("10.0.0.61", "00:11:22:33:44:02", host: "fsw-quai", vendor: "Fortinet")], at: hwNow)
        try expect(twins.applyDetected(candidates.filter { $0.name == "FSW-QUAI" }).isEmpty, "nom ambigu : rien")

        // Nom qui contredit l'IP connue : refusé.
        let contradicted = InvHardwareCandidate(name: "FortiAP-231F", ip: IPv4Address("10.0.0.200"), ipVendorHint: "Fortinet",
                                                hardware: InvDetectedHardware(model: "FAP-231F", source: .fortigate, readAt: hwNow))
        try expect(InvHardwareMatcher.match([contradicted], in: store.sortedRecords).isEmpty, "nom et IP contradictoires : rien")

        // Lecture SNMP sur une IP : fiche en ligne d'abord.
        var reused = InventoryStore()
        reused.merge([hwDevice("10.0.0.80", "00:11:22:33:44:80", host: "ancien", online: true)], at: hwNow.addingTimeInterval(-86_400))
        reused.merge([hwDevice("10.0.0.80", "00:11:22:33:44:80", host: "ancien", online: false),
                      hwDevice("10.0.0.80", "00:11:22:33:44:81", host: "nouveau", online: true)], at: hwNow)
        let snmpKey = reused.applySNMPHardware(SNMPHardwareInfo(model: "USW-24-PoE", firmware: "6.5.59", origin: "sysDescr"),
                                               host: IPv4Address("10.0.0.80")!, at: hwNow)
        try expectEqual(snmpKey, InventoryStore.key(mac: MACAddress("00:11:22:33:44:81")!), "fiche en ligne")
    }

    suite.add("Fiche matériel : gardée quand une suppression annulée retrouve la fiche recréée") {
        var store = InventoryStore()
        store.merge([hwDevice("10.0.0.90", "00:11:22:33:44:90", host: "sw-90", vendor: "Cisco", type: .switch)], at: hwNow)
        let key = InventoryStore.key(mac: MACAddress("00:11:22:33:44:90")!)
        store.setDetectedHardware(InvDetectedHardware(model: "C9300-48P", serialNumber: "FOC2233X0AB", firmware: "17.9.4",
                                                      source: .snmp, detail: "ENTITY-MIB", readAt: hwNow), for: key)
        let removal = store.removeRecords([key], exclude: false, at: hwNow.addingTimeInterval(60))
        try expect(store.record(key) == nil, "supprimée")
        // Le scan la recrée avant « Annuler » : la fiche réunie garde la lecture d'avant.
        store.merge([hwDevice("10.0.0.90", "00:11:22:33:44:90", host: "sw-90", vendor: "Cisco", type: .switch)],
                    at: hwNow.addingTimeInterval(120))
        try expect(store.record(key)?.detectedHardware == nil, "fiche recréée sans lecture")
        store.restore(removal)
        try expectEqual(store.record(key)?.detectedHardware?.model, "C9300-48P", "modèle gardé")
        try expectEqual(store.record(key)?.detectedHardware?.serialNumber, "FOC2233X0AB", "numéro de série gardé")
        try expectEqual(store.record(key)?.detectedHardware?.firmware, "17.9.4", "firmware gardé")
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : absent", file: file, line: line) }
        return value
    }
}
