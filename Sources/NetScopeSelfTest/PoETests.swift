import Foundation
import NetScopeCore

// Tests de « Suis-je sur un port PoE ? » (note 12) : TLV PoE de LLDP (802.3, 802.3at, 802.3bt,
// LLDP-MED) et de CDP écrits à la main d'après les normes, et analyse SNMP de POWER-ETHERNET-MIB
// et des MIB Cisco/HPE sur des réponses fixes. Aucun accès réseau.

/// Charge d'un TLV 802.3 Power via MDI 802.3bt : PSE Type 3, classe 6, 51 W alloués sur 4 paires.
private let btInfo: [UInt8] = [
    0x0F, 0x01, 0x05,       // PSE, pris en charge, activé, choix des paires ; paires signal ; classe 4 (base)
    0x13,                   // Type 2 PSE (base at), source principale, priorité basse
    0x01, 0xFE, 0x01, 0xFE, // demandés 51,0 W, alloués 51,0 W
    0x00, 0x00, 0x00, 0x00, // demandés mode A / B
    0x00, 0x00, 0x00, 0x00, // alloués mode A / B
    0x8C, 0x06,             // 4 paires (signature simple), paires étendues, classe 6
    0x04,                   // type étendu 2 : Type 3 PSE
    0x02, 0xD0,             // PSE : 72,0 W au maximum
    0x00, 0x00, 0x00, 0x00, // autoclass, mise hors tension
]

private func lldpOrgTLV(_ oui: [UInt8], _ subtype: UInt8, _ info: [UInt8]) -> [UInt8] {
    let length = 4 + info.count
    let header = UInt16(127) << 9 | UInt16(length)
    return [UInt8(header >> 8), UInt8(header & 0xFF)] + oui + [subtype] + info
}

/// Trame LLDP d'un Catalyst 9300 (port PoE 802.3bt + LLDP-MED PSE).
private func poeLLDPFrame() -> [UInt8] {
    var frame: [UInt8] = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E, 0x70, 0x0F, 0x6A, 0x91, 0x4C, 0x0C, 0x88, 0xCC]
    frame += [0x02, 0x07, 0x04, 0x70, 0x0F, 0x6A, 0x91, 0x4C, 0x00]   // Chassis ID (MAC)
    frame += [0x04, 0x09, 0x05] + Array("Gi1/0/12".utf8)               // Port ID
    frame += [0x06, 0x02, 0x00, 0x78]                                   // TTL
    frame += [0x0A, 0x0A] + Array("SW-CORE-01".utf8)                    // System Name
    frame += lldpOrgTLV([0x00, 0x12, 0x0F], 2, btInfo)
    frame += lldpOrgTLV([0x00, 0x12, 0xBB], 4, [0x12, 0x02, 0x58])      // MED : PSE, principale, haute, 60 W
    frame += [0x00, 0x00]
    return frame
}

private func cdpTLV(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
    let length = UInt16(value.count + 4)
    return [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF)] + value
}

private func poeBind(_ root: SNMPOID, _ group: UInt32, _ port: UInt32, _ value: SNMPValue) -> SNMPVarBind {
    SNMPVarBind(oid: SNMPOID(root.components + [group, port]), value: value)
}

func registerPoETests(_ suite: TestSuite) {
    suite.add("PoE LLDP : 802.3bt (Type 3, classe 6, 4 paires, watts)") {
        let poe = try PoEDecoder.powerViaMDI(btInfo).unwrap("TLV 802.3bt")
        try expectEqual(poe.role, .pse, "rôle PSE")
        try expectEqual(poe.isPoEPort, true, "port PoE")
        try expectEqual(poe.isPowerDelivered, true, "courant fourni")
        try expectEqual(poe.standard, .bt, "norme")
        try expectEqual(poe.powerType, 3, "type")
        try expectEqual(poe.typeLabel, "802.3bt (Type 3)", "libellé du type")
        try expectEqual(poe.powerClass, 6, "classe étendue")
        try expectEqual(poe.requestedW, 51, "demandés")
        try expectEqual(poe.allocatedW, 51, "alloués")
        try expectEqual(poe.pseMaxAvailableW, 72, "maximum du PSE")
        try expectEqual(poe.poweringStatus, "4 paires (signature simple)", "état d'alimentation")
        try expectEqual(poe.priority, .low, "priorité")
        try expectEqual(poe.powerSource, "Principale", "source")
        try expectEqual(poe.pairsControllable, true, "choix des paires")
        try expectEqual(poe.summary, "802.3bt · 51\u{00A0}W alloués", "résumé")
        try expectEqual(poe.powerLabel, "51\u{00A0}W demandés · 51\u{00A0}W alloués · max 72\u{00A0}W", "puissance")
    }

    suite.add("PoE LLDP : signature double (watts des modes A et B additionnés), Type 4") {
        var info = btInfo
        info[4] = 0; info[5] = 0; info[6] = 0; info[7] = 0                       // totaux à zéro
        info[8] = 0x01; info[9] = 0x2C; info[10] = 0x01; info[11] = 0x2C        // 30 + 30 W demandés
        info[12] = 0x01; info[13] = 0x2C; info[14] = 0x00; info[15] = 0xFA      // 30 + 25 W alloués
        info[16] = 0xCC; info[17] = 0x0F                                          // 4 paires (double), classe double
        info[18] = 0x06                                                           // Type 4 PSE
        let poe = try PoEDecoder.powerViaMDI(info).unwrap("TLV double")
        try expectEqual(poe.requestedW, 60, "demandés A + B")
        try expectEqual(poe.allocatedW, 55, "alloués A + B")
        try expectEqual(poe.powerType, 4, "Type 4")
        try expectEqual(poe.powerClass, 4, "classe de base gardée (0xF : signature double)")
        try expectEqual(poe.poweringStatus, "4 paires (signature double)", "état")
    }

    suite.add("PoE LLDP : port sans PoE, PoE désactivé, 802.3af seul, at sans charge") {
        let none = try PoEDecoder.powerViaMDI([0x01, 0x01, 0x00]).unwrap("sans PoE")
        try expectEqual(none.isPoEPort, false, "pas un port PoE")
        try expectEqual(none.isPowerDelivered, false, "rien fourni")
        try expectEqual(none.summary, "Pas de PoE", "résumé sans PoE")
        let disabled = try PoEDecoder.powerViaMDI([0x03, 0x01, 0x00]).unwrap("désactivé")
        try expectEqual(disabled.isPoEPort, true, "port PoE désactivé")
        try expectEqual(disabled.isPowerDelivered, false, "désactivé : rien fourni")
        try expectEqual(disabled.summary, "802.3af · désactivé", "résumé désactivé")
        let af = try PoEDecoder.powerViaMDI([0x07, 0x01, 0x01]).unwrap("af")
        try expectEqual(af.isPoEPort, true, "port af")
        try expectEqual(af.isPowerDelivered, nil, "af : la base ne dit pas si le courant passe")
        try expectEqual(af.summary, "802.3af · classe 0", "résumé af")
        try expectEqual(af.powerClass, 0, "classe 0")
        let at = try PoEDecoder.powerViaMDI([0x07, 0x01, 0x05, 0x10, 0x00, 0x00, 0x00, 0x00]).unwrap("at")
        try expectEqual(at.typeLabel, "802.3at (Type 2)", "Type 2")
        try expectEqual(at.isPowerDelivered, false, "0 W alloués : rien fourni")
        try expectEqual(at.summary, "802.3at · non utilisé", "résumé")
        let type1 = try PoEDecoder.powerViaMDI([0x07, 0x01, 0x02, 0x90, 0x00, 0x28, 0x00, 0x28]).unwrap("Type 1")
        try expectEqual(type1.standard, .af, "Type 1 = niveau af")
        try expectEqual(type1.allocatedW, 4, "4 W")
        try expectEqual(type1.isPowerDelivered, true, "4 W alloués : fourni")
        // Côté appareil alimenté (PD) : ce n'est pas un port de switch PoE.
        let pd = try PoEDecoder.powerViaMDI([0x06, 0x01, 0x04]).unwrap("PD")
        try expectEqual(pd.role, .pd, "rôle PD")
        try expectEqual(pd.isPoEPort, false, "un PD n'est pas une source")
        try expect(PoEDecoder.powerViaMDI([0x07, 0x01]) == nil, "TLV tronqué refusé")
    }

    suite.add("PoE LLDP-MED : Extended Power-via-MDI (PSE et PD)") {
        let pse = try PoEDecoder.medExtendedPower([0x12, 0x00, 0x96]).unwrap("MED PSE")
        try expectEqual(pse.role, .pse, "PSE")
        try expectEqual(pse.availableW, 15, "15 W disponibles")
        try expectEqual(pse.priority, .high, "priorité haute")
        try expectEqual(pse.powerSource, "Principale", "source")
        try expectEqual(pse.isPoEPort, true, "port PoE")
        try expectEqual(pse.isPowerDelivered, nil, "MED ne dit pas si le courant passe")
        try expectEqual(pse.summary, "LLDP-MED · 15\u{00A0}W", "résumé")
        let pd = try PoEDecoder.medExtendedPower([0x51, 0x00, 0x82]).unwrap("MED PD")
        try expectEqual(pd.role, .pd, "PD")
        try expectEqual(pd.requestedW, 13, "13 W demandés")
        try expectEqual(pd.powerSource, "PSE", "alimenté par le PSE")
        try expectEqual(pd.isPoEPort, false, "un PD n'est pas un port de switch")
        try expect(PoEDecoder.medExtendedPower([0x92, 0x00, 0x82]) == nil, "type réservé refusé")
    }

    suite.add("PoE LLDP : trame complète (802.3bt et MED fusionnés dans le voisin)") {
        let neighbor = try NeighborFrameDecoder.decode(poeLLDPFrame()).unwrap("trame")
        let power = try neighbor.power.unwrap("PoE décodé")
        try expectEqual(power.sources, [.lldp8023, .lldpMED], "deux sources")
        try expectEqual(power.allocatedW, 51, "802.3bt prioritaire")
        try expectEqual(power.availableW, 60, "MED : disponible")
        try expectEqual(power.priority, .low, "priorité 802.3 gardée")
        try expectEqual(neighbor.poe, "802.3bt · 51\u{00A0}W alloués", "résumé du voisin")
        // Trame d'exemple Aruba : 802.3at, 0 W.
        let aruba = try NeighborFrameDecoder.decode(sampleLLDPFrame()).unwrap("Aruba")
        try expectEqual(aruba.power?.isPoEPort, true, "Aruba : port PoE")
        try expectEqual(aruba.power?.isPowerDelivered, false, "Aruba : rien fourni")
        // Encodage puis décodage du voisin (dernière capture gardée) : le détail PoE survit.
        let data = try JSONEncoder().encode(neighbor)
        try expectEqual(try JSONDecoder().decode(NetworkNeighbor.self, from: data).power, power, "aller-retour JSON")
    }

    suite.add("PoE CDP : Power, Power Available, Power Requested, fusion avec LLDP") {
        let available = try PoEDecoder.cdpPowerAvailable([0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x3C, 0x8C, 0xFF, 0xFF, 0xFF, 0xFF])
            .unwrap("Power Available")
        try expectEqual(available.availableW, 15.5, "15,5 W")
        try expectEqual(available.isPoEPort, true, "port PoE")
        try expectEqual(available.summary, "CDP · 15,5\u{00A0}W disponibles", "résumé")
        let requested = try PoEDecoder.cdpPowerRequested([0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x1F, 0x40]).unwrap("Power Requested")
        try expectEqual(requested.requestedW, 8, "8 W demandés")
        try expectEqual(requested.isPoEPort, nil, "une demande seule ne dit rien du port")
        // Trame CDP complète : Power (0x0010) et Power Available (0x001A).
        var cdp: [UInt8] = [0x02, 0xB4, 0x00, 0x00]
        cdp += cdpTLV(0x0001, Array("SW-CORE-01".utf8))
        cdp += cdpTLV(0x0003, Array("GigabitEthernet1/0/12".utf8))
        cdp += cdpTLV(0x0010, [0x00, 0x00])
        cdp += cdpTLV(0x001A, [0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x75, 0x30, 0xFF, 0xFF, 0xFF, 0xFF])
        let neighbor = try CDPDecoder.decode(cdp).unwrap("CDP")
        try expectEqual(neighbor.power?.availableW, 30, "30 W disponibles")
        try expectEqual(neighbor.power?.deviceConsumptionW, 0, "consommation du switch")
        try expectEqual(neighbor.poe, "CDP · 30\u{00A0}W disponibles", "résumé")
        // Fusion : LLDP l'emporte, CDP complète.
        let merged = try PoEDecoder.powerViaMDI(btInfo).unwrap("bt").merged(with: available)
        try expectEqual(merged.sources, [.lldp8023, .cdp], "sources")
        try expectEqual(merged.allocatedW, 51, "LLDP gardé")
        try expectEqual(merged.availableW, 15.5, "CDP ajouté")
        try expectEqual(PoEPowerInfo.answer(nil), "Non annoncé", "réponse inconnue")
    }

    suite.add("PoE SNMP : POWER-ETHERNET-MIB et watts Cisco sur réponses fixes") {
        var interfaces = (1...4).map { SNMPInterface(index: 10_100 + $0, name: "Gi1/0/\($0)", operStatus: .up, speedMbps: 1000) }
        interfaces.append(SNMPInterface(index: 10_200, name: "Te1/1/1", speedMbps: 10_000))
        interfaces.append(SNMPInterface(index: 1, name: "Vlan1", type: 53))
        var columns = SNMPPoEParser.Columns()
        columns.adminEnable = ([1, 2, 3, 4] as [UInt32]).map { poeBind(SNMPOIDs.pethPsePortAdminEnable, 1, $0, .integer($0 == 4 ? 2 : 1)) }
        columns.detection = ([(1, 3), (2, 2), (3, 4), (4, 1)] as [(UInt32, Int64)]).map { poeBind(SNMPOIDs.pethPsePortDetectionStatus, 1, $0.0, .integer($0.1)) }
        columns.classification = ([(1, 5), (2, 1), (3, 1), (4, 1)] as [(UInt32, Int64)]).map { poeBind(SNMPOIDs.pethPsePortPowerClassifications, 1, $0.0, .integer($0.1)) }
        columns.priority = [poeBind(SNMPOIDs.pethPsePortPowerPriority, 1, 1, .integer(1))]
        columns.ciscoConsumption = ([(1, 18_400), (2, 0), (3, 1200), (9, 5000)] as [(UInt32, UInt32)]).map { poeBind(SNMPOIDs.cpeExtPsePortPwrConsumption, 1, $0.0, .gauge32($0.1)) }
        columns.ciscoAllocated = [poeBind(SNMPOIDs.cpeExtPsePortPwrAllocated, 1, 1, .gauge32(30_000))]
        columns.mainPower = [SNMPVarBind(oid: SNMPOID(SNMPOIDs.pethMainPsePower.components + [1]), value: .gauge32(740))]
        columns.mainConsumption = [SNMPVarBind(oid: SNMPOID(SNMPOIDs.pethMainPseConsumptionPower.components + [1]), value: .gauge32(412))]
        columns.mainOperStatus = [SNMPVarBind(oid: SNMPOID(SNMPOIDs.pethMainPseOperStatus.components + [1]), value: .integer(1))]
        let ports = SNMPPoEParser.ports(columns, interfaces: interfaces)
        try expectEqual(ports.count, 4, "quatre ports PSE (la ligne Cisco orpheline est ignorée)")
        try expectEqual(ports.map(\.ifIndex), [10_101, 10_102, 10_103, 10_104], "rattachés par nom g/0/p")
        let first = ports[0]
        try expectEqual(first.isDelivering, true, "port 1 alimente")
        try expectEqual(first.powerClass, 4, "classe 4")
        try expectEqual(first.priority, .critical, "priorité critique")
        try expectEqual(first.consumptionW, 18.4, "18,4 W")
        try expectEqual(first.allocatedW, 30, "30 W alloués")
        try expectEqual(first.wattsSource, "Cisco", "source des watts")
        try expectEqual(first.summary, "Classe 4 · 18,4\u{00A0}W", "résumé")
        try expectEqual(first.shortLabel, "Oui · 18,4\u{00A0}W", "colonne")
        try expectEqual(ports[1].summary, "Aucune charge PoE", "port 2 en recherche")
        try expectEqual(ports[1].shortLabel, "Non (port PoE)", "colonne port 2")
        try expectEqual(ports[2].detection, .fault, "port 3 en défaut")
        try expectEqual(ports[2].consumptionMW, 0, "un port qui n'alimente pas ne consomme rien")
        try expectEqual(ports[3].adminEnabled, false, "port 4 désactivé")
        try expectEqual(ports[3].shortLabel, "PoE désactivé", "colonne port 4")
        let main = try SNMPPoEParser.main(columns).unwrap("bloc principal")
        try expectEqual(main.budgetW, 740, "budget")
        try expectEqual(main.usedW, 412, "consommation")
        try expectEqual(main.operStatus, 1, "en marche")
    }

    suite.add("PoE SNMP : HPE (watts HP-ICF), ports sans nom g/p, switch sans PoE") {
        let interfaces = (1...6).map { SNMPInterface(index: $0, name: "\($0)", operStatus: .up) }
        var columns = SNMPPoEParser.Columns()
        columns.detection = [poeBind(SNMPOIDs.pethPsePortDetectionStatus, 1, 5, .integer(3)),
                             poeBind(SNMPOIDs.pethPsePortDetectionStatus, 1, 6, .integer(2)),
                             poeBind(SNMPOIDs.pethPsePortDetectionStatus, 2, 1, .integer(3))]
        columns.hpePower = [poeBind(SNMPOIDs.hpicfPoePethPsePortPower, 1, 5, .integer(6_100))]
        let ports = SNMPPoEParser.ports(columns, interfaces: interfaces)
        try expectEqual(ports.map(\.ifIndex), [5, 6, nil], "p-ième port physique du groupe 1 ; groupe 2 sans correspondance")
        try expectEqual(ports[0].consumptionW, 6.1, "6,1 W (HPE)")
        try expectEqual(ports[0].wattsSource, "HPE", "source HPE")
        try expectEqual(ports[0].isEnabled, true, "admin inconnu : activé")
        try expect(SNMPPoEParser.ports(SNMPPoEParser.Columns(), interfaces: interfaces).isEmpty, "aucune réponse : aucun port")
        try expect(SNMPPoEParser.main(SNMPPoEParser.Columns()) == nil, "aucun bloc")
    }

    suite.add("PoE SNMP : rattachement d'un appareil à son port (Gi, GigabitEthernet, Wi-Fi, SVI)") {
        let interfaces = [SNMPInterface(index: 12, name: "Gi1/0/12", descr: "GigabitEthernet1/0/12", operStatus: .up),
                          SNMPInterface(index: 22, name: "Gi1/0/22", descr: "GigabitEthernet1/0/22", operStatus: .up),
                          SNMPInterface(index: 100, name: "Vlan1", descr: "Vlan1", type: 53, operStatus: .up)]
        let snapshot = SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                                          interfaces: interfaces, poePorts: [12],
                                          poeDetails: [SNMPPoEPort(group: 1, port: 12, ifIndex: 12, adminEnabled: true,
                                                                   detection: .deliveringPower, powerClass: 4, consumptionMW: 13_400,
                                                                   wattsSource: "Cisco")])
        let ap = try SNMPPoELookup.status(switchName: "SW-CORE-01", portName: "Gi1/0/12", in: [snapshot]).unwrap("AP")
        try expectEqual(ap.isPoEPort, true, "port PoE")
        try expectEqual(ap.isPowered, true, "alimenté")
        try expectEqual(ap.detailLabel, "Alimenté par PoE · classe 4 · 13,4\u{00A0}W (Cisco)", "fiche")
        let long = try SNMPPoELookup.status(switchName: "sw-core-01.bureau.local", portName: "GigabitEthernet1/0/12", in: [snapshot])
            .unwrap("nom long")
        try expectEqual(long.portName, "Gi1/0/12", "nom court retrouvé")
        let pc = try SNMPPoELookup.status(switchName: "SW-CORE-01", portName: "Gi1/0/22", in: [snapshot]).unwrap("poste")
        try expectEqual(pc.isPoEPort, false, "port hors pethPsePortTable : pas PoE")
        try expectEqual(pc.shortLabel, "Non (sans PoE)", "colonne")
        try expectEqual(pc.detailLabel, "Non · le port Gi1/0/22 ne fournit pas de PoE", "fiche sans PoE")
        try expect(SNMPPoELookup.status(switchName: "FortiAP-231F", portName: "Wi-Fi", in: [snapshot]) == nil, "Wi-Fi : sans objet")
        try expect(SNMPPoELookup.status(switchName: "SW-CORE-01", portName: "Vlan1 (SVI)", in: [snapshot]) == nil, "SVI : sans objet")
        try expect(SNMPPoELookup.status(switchName: "SW-AUTRE", portName: "1/1", in: [snapshot]) == nil, "switch non relevé")
        // Relevé ancien (sans détail) : seuls les ports qui alimentent sont connus.
        var old = snapshot
        old.poeDetails = nil
        let oldAP = try SNMPPoELookup.status(switchName: "SW-CORE-01", portName: "Gi1/0/12", in: [old]).unwrap("ancien")
        try expectEqual(oldAP.isPowered, true, "ancien relevé : alimenté")
        let oldPC = try SNMPPoELookup.status(switchName: "SW-CORE-01", portName: "Gi1/0/22", in: [old]).unwrap("ancien poste")
        try expectEqual(oldPC.isPoEPort, nil, "ancien relevé : impossible à dire")
        try expectEqual(oldPC.shortLabel, "Inconnu", "colonne inconnue")
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
