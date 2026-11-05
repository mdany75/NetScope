import Darwin
import Foundation
@testable import NetScopeCore

// Note 59 : SNMP v3 partout et Navigateur SNMP. Vecteurs fixes (RFC 3414, RFC 7860), encodage et
// décodage GETNEXT/GETBULK en v3, parcours (fin de sous-arborescence, endOfMibView, tooBig,
// limite), noms de la MIB, choix de l'identifiant v3 du site, et un faux agent v3 qui sait
// parcourir ses tables, sur 127.0.0.1 seulement. Aucun autre trafic.

private let rfcEngine: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]

private func text(_ value: String) -> SNMPValue { .octetString(Array(value.utf8)) }

/// Petite MIB d'essai : system, ifName/ifOperStatus sur 30 ports, une entité et une ligne hors des tables.
private func sampleTable() -> [SNMPVarBind] {
    var rows: [SNMPVarBind] = [
        SNMPVarBind(oid: SNMPOIDs.sysDescr, value: text("Cisco IOS Software, C9300 Software")),
        SNMPVarBind(oid: SNMPOIDs.sysObjectID, value: .oid("1.3.6.1.4.1.9.1.2494")),
        SNMPVarBind(oid: SNMPOIDs.sysUpTime, value: .timeTicks(360_000)),
        SNMPVarBind(oid: SNMPOIDs.sysName, value: text("SW-V3")),
    ]
    for i in 1...30 {
        rows.append(SNMPVarBind(oid: SNMPOIDs.ifDescr.appending(UInt32(i)), value: text("GigabitEthernet1/0/\(i)")))
        rows.append(SNMPVarBind(oid: SNMPOIDs.ifType.appending(UInt32(i)), value: .integer(6)))
        rows.append(SNMPVarBind(oid: SNMPOIDs.ifOperStatus.appending(UInt32(i)), value: .integer(i % 3 == 0 ? 2 : 1)))
        rows.append(SNMPVarBind(oid: SNMPOIDs.ifName.appending(UInt32(i)), value: text("Gi1/0/\(i)")))
    }
    rows.append(SNMPVarBind(oid: SNMPEntityOIDs.cell(SNMPEntityOIDs.physicalClass, index: 1001), value: .integer(3)))
    rows.append(SNMPVarBind(oid: SNMPEntityOIDs.cell(SNMPEntityOIDs.serialNum, index: 1001), value: text("FOC2331X0QZ")))
    rows.append(SNMPVarBind(oid: SNMPEntityOIDs.cell(SNMPEntityOIDs.modelName, index: 1001), value: text("C9300-48P")))
    rows.append(SNMPVarBind(oid: "1.3.6.1.2.1.105.1.3.1.1.2.1", value: .gauge32(740)))
    return rows
}

func registerSNMPv3WalkTests(_ suite: TestSuite) {
    suite.add("SNMP v3 : clés localisées SHA-2 (RFC 7860, « maplesyrup », engineID …02)") {
        // Valeurs recalculées par une implémentation indépendante (hashlib de Python), comme la RFC 3414 A.3.
        let expected: [(SNMPAuthProtocol, String)] = [
            (.sha224, "0bd8827c6e29f8065e08e09237f177e410f69b90e1782be682075674"),
            (.sha256, "8982e0e549e866db361a6b625d84cccc11162d453ee8ce3a6445c2d6776f0f8b"),
            (.sha384, "3b298f16164a11184279d5432bf169e2d2a48307de02b3d3f7e2b4f36eb6f0455a53689a3937eea07319a633d2ccba78"),
            (.sha512, "22a5a36cedfcc085807a128d7bc6c2382167ad6c0dbc5fdff856740f3d84c099ad1ea87a8db096714d9788bd544047c9021e4229ce27e4c0a69250adfcffbb0b"),
        ]
        for (proto, hex) in expected {
            try expectEqual(SNMPCryptoBytes.hex(proto.localizedKey(password: "maplesyrup", engineID: rfcEngine)), hex, "Kul \(proto.rawValue)")
        }
        try expectEqual([SNMPAuthProtocol.sha224, .sha256, .sha384, .sha512].map(\.macLength), [16, 24, 32, 48], "longueurs du HMAC (RFC 7860)")
        // Le cache de la session rend exactement la même clé que le calcul direct.
        let credentials = SNMPv3Credentials(user: "u", level: .authPriv, auth: .sha256, authPassword: "maplesyrup",
                                            priv: .aes256, privPassword: "maplesyrup")
        try expectEqual(SNMPv3Session.authKey(credentials, engineID: rfcEngine),
                        SNMPAuthProtocol.sha256.localizedKey(password: "maplesyrup", engineID: rfcEngine), "clé d'authentification en cache")
        try expectEqual(SNMPv3Session.privKey(credentials, engineID: rfcEngine).count, 32, "clé AES-256 allongée")
    }

    suite.add("SNMP v3 : GETNEXT authNoPriv SHA-256, message identique au vecteur calculé à part") {
        let credentials = SNMPv3Credentials(user: "netscope", level: .authNoPriv, auth: .sha256, authPassword: "maplesyrup")
        let pdu = SNMPPDU(type: .getNextRequest, requestID: 1234, varbinds: [SNMPVarBind(oid: "1.3.6.1.2.1.1.5")])
        let bytes = try SNMPv3Session.encodeRequest(pdu, msgID: 1234, credentials: credentials, engineID: rfcEngine,
                                                    boots: 3, time: 900, salt: 0)
        // BER et HMAC-SHA-256-192 recalculés par un script Python indépendant (hashlib, hmac).
        let vector = "308180020103300f020204d2020300ffe3040105020103043d303b040c0000000000000000000000020201030202038404086e657473636f7065"
            + "041895f0e5147c17c7948a591a5bfcc757af7959c839d30f3c320400302b040c0000000000000000000000020400a119020204d2020100020100"
            + "300d300b06072b0601020101050500"
        try expectEqual(SNMPCryptoBytes.hex(bytes), vector, "message v3 octet pour octet")
        let decoded = try SNMPv3Session.decodeResponse(bytes, credentials: credentials, engineID: rfcEngine)
        try expectEqual(decoded.pdu?.type, .getNextRequest, "GETNEXT décodé")
        try expectEqual(SNMPCryptoBytes.hex(decoded.usm.authParams), "95f0e5147c17c7948a591a5bfcc757af7959c839d30f3c32", "HMAC tronqué à 24 octets")
        var tampered = bytes
        tampered[tampered.count - 3] ^= 0x01
        try expectThrows(SNMPv3Error.badResponseDigest, "message modifié refusé") {
            _ = try SNMPv3Session.decodeResponse(tampered, credentials: credentials, engineID: rfcEngine)
        }
    }

    suite.add("SNMP v3 : GETBULK authPriv (SHA-256/AES-128, SHA-1/DES), aller-retour et paramètres USM") {
        let engine: [UInt8] = [0x80, 0x00, 0x00, 0x09, 0x03, 0x00, 0x70, 0x0F, 0x6A, 0x91, 0x4C, 0x02]
        for (auth, priv) in [(SNMPAuthProtocol.sha256, SNMPPrivProtocol.aes128), (.sha1, .des), (.sha512, .aes256)] {
            let credentials = SNMPv3Credentials(user: "netscope-ro", level: .authPriv, auth: auth, authPassword: "authpass123",
                                                priv: priv, privPassword: "privpass123", context: "vlan-30")
            let bulk = SNMPPDU.getBulk(requestID: 77, nonRepeaters: 1, maxRepetitions: 25, oids: [SNMPOIDs.sysUpTime, SNMPOIDs.ifName])
            let bytes = try SNMPv3Session.encodeRequest(bulk, msgID: 77, credentials: credentials, engineID: engine,
                                                        boots: 12, time: 4_000, salt: 0x0102_0304_0506_0708)
            try expect(!bytes.windows(7).contains(Array("vlan-30".utf8)), "contexte chiffré")
            let message = try SNMPv3Session.decodeResponse(bytes, credentials: credentials, engineID: engine)
            try expectEqual(message.flags, 0x07, "auth, priv, reportable")
            try expectEqual(message.usm.user, "netscope-ro", "utilisateur en clair")
            try expectEqual(message.usm.authParams.count, auth.macLength, "longueur du HMAC")
            try expectEqual(message.usm.privParams.count, 8, "sel de 8 octets")
            try expectEqual(message.contextName, "vlan-30", "contexte retrouvé")
            try expectEqual(message.contextEngineID, engine, "contextEngineID = engineID de l'agent")
            guard let pdu = message.pdu else { throw TestFailure(message: "PDU déchiffrée absente", file: #fileID, line: #line) }
            try expectEqual(pdu.type, .getBulkRequest, "GETBULK \(auth.rawValue)/\(priv.rawValue)")
            try expectEqual(pdu.errorStatus, 1, "non-repeaters")
            try expectEqual(pdu.errorIndex, 25, "max-repetitions")
            try expectEqual(pdu.varbinds.map(\.oid), [SNMPOIDs.sysUpTime, SNMPOIDs.ifName], "OID demandés")
            // Mauvaise clé de confidentialité : déchiffrement refusé.
            var wrong = credentials
            wrong.privPassword = "pas-le-bon-mdp"
            do {
                let garbled = try SNMPv3Session.decodeResponse(bytes, credentials: wrong, engineID: engine)
                try expect(garbled.pdu?.varbinds.map(\.oid) != bulk.varbinds.map(\.oid), "contenu illisible avec une autre clé")
            } catch let error as SNMPv3Error {
                try expectEqual(error, .responseDecryption, "déchiffrement refusé")
            }
        }
        // noAuthNoPriv : rien de signé ni de chiffré.
        let open = SNMPv3Credentials(user: "lecture", level: .noAuthNoPriv)
        let bytes = try SNMPv3Session.encodeRequest(SNMPPDU(type: .getNextRequest, requestID: 5, varbinds: [SNMPVarBind(oid: "1.3.6.1.2.1.1")]),
                                                    msgID: 5, credentials: open, engineID: engine, boots: 1, time: 2, salt: 0)
        let plain = try SNMPv3Codec.decode(bytes)
        try expectEqual(plain.flags, 0x04, "seulement reportable")
        try expect(plain.usm.authParams.isEmpty && plain.usm.privParams.isEmpty, "aucun paramètre de sécurité")
        try expectEqual(open.netSNMPOptions, "-v3 -l noAuthNoPriv -u lecture", "options net-snmp")
        try expectThrows(SNMPv3Error.shortPassword("d’authentification"), "mot de passe trop court") {
            try SNMPv3Credentials(user: "x", level: .authNoPriv, authPassword: "court").validate()
        }
    }

    suite.add("Parcours SNMP : fin de sous-arborescence, endOfMibView, tooBig, limite, GETNEXT") {
        let agent = SNMPTableAgent(sampleTable())
        let names = try await SNMPWalker.walk(SNMPOIDs.ifName, mode: .bulk(maxRepetitions: 7)) { agent.answer($0) }
        try expectEqual(names.binds.count, 30, "30 lignes ifName")
        try expectEqual(names.end, .subtree, "arrêt à la première ligne hors de ifName")
        try expectEqual(names.requests, 5, "rafales de 7 : 5 requêtes")
        // La dernière table de l'agent : endOfMibView.
        let poe = try await SNMPWalker.walk("1.3.6.1.2.1.105", mode: .defaultBulk) { agent.answer($0) }
        try expectEqual(poe.binds.count, 1, "une ligne PoE")
        try expectEqual(poe.end, .endOfMib, "fin de la MIB de l'agent")
        // Datagramme trop gros : la rafale est réduite de moitié jusqu'à passer.
        let small = SNMPTableAgent(sampleTable(), maxBindsPerResponse: 4)
        let descr = try await SNMPWalker.walk(SNMPOIDs.ifDescr, mode: .bulk(maxRepetitions: 25)) { small.answer($0) }
        try expectEqual(descr.binds.count, 30, "tooBig : toutes les lignes quand même")
        // Limite de lignes.
        let limited = try await SNMPWalker.walk(SNMPOIDs.ifName, mode: .bulk(maxRepetitions: 25), limit: 12) { agent.answer($0) }
        try expectEqual(limited.binds.count, 12, "limite de 12")
        try expect(limited.truncated, "limite signalée")
        let exact = try await SNMPWalker.walk(SNMPOIDs.ifName, mode: .bulk(maxRepetitions: 25), limit: 30) { agent.answer($0) }
        try expect(!exact.truncated, "30 lignes pour une limite de 30 : rien de tronqué")
        // GETNEXT : une ligne par requête.
        let next = try await SNMPWalker.walk("1.3.6.1.2.1.1", mode: .getNext) { agent.answer($0) }
        try expectEqual(next.binds.map(\.oid), [SNMPOIDs.sysDescr, SNMPOIDs.sysObjectID, SNMPOIDs.sysUpTime, SNMPOIDs.sysName], "system")
        try expectEqual(next.requests, 5, "quatre lignes et la sortie du groupe")
        // Agent défectueux qui renvoie toujours le même OID : arrêt sans boucler.
        let stuck = try await SNMPWalker.walk("1.3.6.1.2.1.2", mode: .getNext) { pdu in
            SNMPPDU(type: .response, requestID: pdu.requestID, varbinds: [SNMPVarBind(oid: SNMPOIDs.ifDescr.appending(1), value: .integer(1))])
        }
        try expectEqual(stuck.binds.count, 1, "une ligne puis arrêt")
        try expectEqual(stuck.end, .notIncreasing, "OID qui ne progresse pas")
        // Agent v1 : noSuchName termine le parcours.
        let v1 = try await SNMPWalker.walk("1.3.6.1.2.1.99", mode: .getNext) { pdu in
            SNMPPDU(type: .response, requestID: pdu.requestID, errorStatus: SNMPErrorStatus.noSuchName.rawValue, errorIndex: 1, varbinds: pdu.varbinds)
        }
        try expect(v1.binds.isEmpty && v1.end == .endOfMib, "noSuchName : fin")
        // Autre erreur de l'agent : remontée.
        do {
            _ = try await SNMPWalker.walk("1.3.6.1.2.1.1", mode: .getNext) { pdu in
                SNMPPDU(type: .response, requestID: pdu.requestID, errorStatus: SNMPErrorStatus.genErr.rawValue, errorIndex: 1, varbinds: [])
            }
            throw TestFailure(message: "genErr attendu", file: #fileID, line: #line)
        } catch let error as SNMPError {
            try expectEqual(error, .agent(status: 5, index: 1), "genErr")
        }
    }

    suite.add("Navigateur SNMP : GET, GETNEXT, noSuchObject, noSuchInstance, parcours d'une feuille") {
        let agent = SNMPTableAgent(sampleTable())
        let get = try await SNMPBrowse.run(SNMPOIDs.sysName, operation: .get) { agent.answer($0) }
        try expectEqual(get.binds.first?.value.stringValue, "SW-V3", "GET sysName.0")
        let missingInstance = try await SNMPBrowse.run(SNMPOIDs.ifName.appending(99), operation: .get) { agent.answer($0) }
        try expectEqual(missingInstance.binds.first?.value, .noSuchInstance, "ifName.99 : noSuchInstance")
        let missingObject = try await SNMPBrowse.run("1.3.6.1.4.1.99999.1.0", operation: .get) { agent.answer($0) }
        try expectEqual(missingObject.binds.first?.value, .noSuchObject, "objet inconnu : noSuchObject")
        let row = SNMPBrowserRow(position: 0, bind: missingObject.binds[0])
        try expect(row.isException && row.valueText.contains("noSuchObject"), "ligne explicite")
        let next = try await SNMPBrowse.run(SNMPOIDs.sysUpTime, operation: .getNext) { agent.answer($0) }
        try expectEqual(next.binds.first?.oid, SNMPOIDs.sysName, "GETNEXT après sysUpTime")
        let last = try await SNMPBrowse.run("1.3.6.1.2.1.105.1.3.1.1.2.1", operation: .getNext) { agent.answer($0) }
        try expectEqual(last.binds.first?.value, .endOfMibView, "GETNEXT après la dernière ligne : endOfMibView")
        try expectEqual(last.end, .endOfMib, "fin signalée")
        let leaf = try await SNMPBrowse.run(SNMPOIDs.sysName, operation: .walk) { agent.answer($0) }
        try expectEqual(leaf.binds.map(\.oid), [SNMPOIDs.sysName], "parcours d'une feuille : la valeur elle-même")
        let collected = SNMPBatchCollector()
        let walked = try await SNMPBrowse.run(SNMPOIDs.ifOperStatus, operation: .walk, mode: .bulk(maxRepetitions: 8), limit: 20,
                                              onBatch: { collected.add($0) }) { agent.answer($0) }
        try expectEqual(collected.count, 20, "lignes remises au fur et à mesure")
        try expect(walked.truncated, "limite de 20 atteinte")
    }

    suite.add("Navigateur SNMP : noms connus, saisie d'OID, valeurs lisibles, CSV") {
        try expectEqual(SNMPMIB.name(for: SNMPOIDs.ifDescr.appending(12)), "ifDescr.12", "ifDescr.12")
        try expectEqual(SNMPMIB.name(for: SNMPOIDs.sysName), "sysName.0", "sysName.0")
        try expectEqual(SNMPMIB.name(for: "1.0.8802.1.1.2.1.4.1.1.9.0.12.3"), "lldpRemSysName.0.12.3", "LLDP")
        try expectEqual(SNMPMIB.lookup("1.3.6.1.2.1.105.1.1.1.6.1.4")?.object.mib, "POWER-ETHERNET-MIB", "MIB PoE")
        try expectEqual(SNMPMIB.parse("sysName.0"), SNMPOIDs.sysName, "nom et index")
        try expectEqual(SNMPMIB.parse(".1.3.6.1.2.1.1.5.0"), SNMPOIDs.sysName, "point initial")
        try expectEqual(SNMPMIB.parse("IF-MIB::ifDescr.3"), SNMPOIDs.ifDescr.appending(3), "notation net-snmp")
        try expectEqual(SNMPMIB.parse("ifxtable"), "1.3.6.1.2.1.31.1.1", "casse ignorée")
        for preset in SNMPMIB.presets {
            try expectEqual(SNMPMIB.parse(preset.name), preset.oid, "raccourci « \(preset.name) » reconnu")
        }
        try expect(SNMPMIB.parse("pas-un-oid") == nil && SNMPMIB.parse("") == nil, "saisie refusée")
        try expectEqual(SNMPMIB.presets.map(\.name), ["system", "ifTable", "ifXTable", "ENTITY-MIB", "LLDP-MIB", "BRIDGE-MIB",
                                                     "Q-BRIDGE-MIB", "POWER-ETHERNET-MIB", "HOST-RESOURCES"], "raccourcis")
        try expectEqual(SNMPBrowserFormat.display(.integer(2), oid: SNMPOIDs.ifOperStatus.appending(3)), "down (2)", "énumération")
        try expectEqual(SNMPBrowserFormat.display(.octetString([0x94, 0xDD, 0xF8, 0x18, 0x15, 0x7D])), "94:DD:F8:18:15:7D", "MAC")
        try expectEqual(SNMPBrowserFormat.display(.timeTicks(105_330_500)), "(105330500) 12\u{00A0}j 4\u{00A0}h 35\u{00A0}min 05\u{00A0}s", "durée")
        try expectEqual(SNMPBrowserFormat.display(.counter64(3_410_000_000)), "3\u{202F}410\u{202F}000\u{202F}000", "grand compteur")
        try expectEqual(SNMPBrowserFormat.display(.oid("1.3.6.1.2.1.31.1.1")), "1.3.6.1.2.1.31.1.1 (ifXTable)", "OID nommé")
        try expectEqual(SNMPBrowserFormat.typeLabel(.gauge32(1)), "Gauge32", "type")
        let rows = [SNMPBrowserRow(position: 0, bind: SNMPVarBind(oid: SNMPOIDs.sysDescr, value: text("Cisco; IOS \"XE\""))),
                    SNMPBrowserRow(position: 1, bind: SNMPVarBind(oid: SNMPOIDs.sysUpTime, value: .timeTicks(100)))]
        let csv = SNMPBrowserFormat.csv(rows)
        try expect(csv.hasPrefix("OID;Nom;MIB;Type;Valeur;Hexadécimal\r\n"), "en-tête CSV")
        try expect(csv.contains("1.3.6.1.2.1.1.1.0;sysDescr.0;SNMPv2-MIB;OCTET STRING;\"Cisco; IOS \"\"XE\"\"\";"), "champ protégé")
        let hostile = SNMPBrowserFormat.csv([SNMPBrowserRow(position: 0, bind: SNMPVarBind(oid: SNMPOIDs.sysContact,
                                                                                         value: text("=HYPERLINK(\"http://x\")")))])
        try expect(hostile.contains(";\"'=HYPERLINK(\"\"http://x\"\")\";"), "formule neutralisée")
        try expect(!hostile.contains(";=HYPERLINK"), "aucune cellule ne commence par =")
        try expectEqual(SNMPBrowserFormat.text([rows[1]]), "sysUpTime.0\tTimeTicks\t(100) 0\u{00A0}min 01\u{00A0}s", "copie")
        try expect(rows[0].oidSort < rows[1].oidSort, "tri numérique des OID")
        try expect(SNMPBrowserRow(position: 0, bind: SNMPVarBind(oid: "1.3.6.1.2.1.2.2.1.2.10", value: .null)).oidSort
                   > SNMPBrowserRow(position: 0, bind: SNMPVarBind(oid: "1.3.6.1.2.1.2.2.1.2.9", value: .null)).oidSort, "10 après 9")
    }

    suite.add("SNMP v3 par site : site du switch, site actif, plages en double") {
        func site(_ name: String, _ ranges: [String], switches: [String] = []) -> Site {
            Site(name: name, ranges: ranges.map { ScanRangeConfig(text: $0, label: name) }, switchHosts: switches)
        }
        let siege = site("Siège", ["10.182.122.0/24"], switches: ["10.182.122.2"])
        let laval = site("Laval", ["192.168.50.0/24"])
        let quebec = site("Québec", ["192.168.50.0/24"])
        let sansV3 = site("Atelier", ["172.16.0.0/24"])
        let global = SNMPv3Credentials(user: "commun", level: .authPriv, authPassword: "authpass123", privPassword: "privpass123")
        var perSite: [UUID: SNMPv3Credentials] = [:]
        for item in [siege, laval, quebec] {
            perSite[item.id] = SNMPv3Credentials(user: "ro-\(item.name)", level: .authPriv, authPassword: "authpass123", privPassword: "privpass123")
        }
        let sites = [siege, laval, quebec, sansV3]
        func user(_ host: String, active: UUID?) -> String? {
            SNMPv3SiteResolver.credentials(for: IPv4Address(host)!, sites: sites, activeID: active, perSite: perSite, fallback: global)?.user
        }
        try expectEqual(user("10.182.122.2", active: laval.id), "ro-Siège", "switch déclaré par le Siège, même depuis Laval")
        try expectEqual(user("10.182.122.40", active: nil), "ro-Siège", "seul site qui contient l'adresse")
        try expectEqual(user("192.168.50.10", active: quebec.id), "ro-Québec", "plage en double : le site actif")
        try expectEqual(user("192.168.50.10", active: nil), "commun", "plage en double sans site actif : identifiant commun")
        try expectEqual(user("172.16.0.5", active: sansV3.id), "commun", "site sans utilisateur v3 : identifiant commun")
        try expectEqual(user("8.8.8.8", active: siege.id), "commun", "hors de tout site")
        let none = SNMPv3SiteResolver.credentials(for: IPv4Address("8.8.8.8")!, sites: sites, activeID: nil, perSite: [:], fallback: nil)
        try expect(none == nil, "aucun v3 : communauté seule")
        let target = SNMPTarget(host: IPv4Address("10.0.0.1")!, community: "", v3: global)
        try expect(target.hasCredentials, "v3 seul suffit")
        try expectEqual(target.withContext(vlan: 30).v3?.context, "vlan-30", "contexte Cisco en v3")
        try expectEqual(SNMPTarget(host: IPv4Address("10.0.0.1")!, community: "lecture").withContext(vlan: 30).community, "lecture@30", "contexte en v2c")
        try expect(!SNMPTarget(host: IPv4Address("10.0.0.1")!, community: "").hasCredentials, "sans identifiant")
        var context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [])
        try expect(context.snmpTarget(IPv4Address("10.0.0.1")!) == nil, "sonde sans identifiant")
        context.snmpV3 = { _ in global }
        try expectEqual(context.snmpTarget(IPv4Address("10.0.0.1")!)?.v3?.user, "commun", "sonde en v3")
    }

    suite.add("SNMP v3 : parcours, relevé de switch et fiche matériel contre un faux agent v3 sur 127.0.0.1") {
        SNMPv3Session.reset()
        SNMPVersionMemo.shared.reset()
        let credentials = SNMPv3Credentials(user: "netscope-ro", level: .authPriv, auth: .sha256, authPassword: "authpass123",
                                            priv: .aes128, privPassword: "privpass123")
        let agent = try FakeSNMPv3TableAgent(credentials: credentials, table: sampleTable())
        defer { agent.stop() }
        let localhost = IPv4Address(127, 0, 0, 1)
        let client = SNMPClient(target: SNMPTarget(host: localhost, port: agent.port, community: "", v3: credentials, timeout: 1, retries: 1))
        let names = try await client.walk(SNMPOIDs.ifName, maxRepetitions: 7)
        try expectEqual(names.count, 30, "30 lignes en GETBULK v3")
        try expectEqual(names.last?.value.stringValue, "Gi1/0/30", "dernière ligne")
        try expectEqual(agent.discoveries, 1, "moteur découvert une seule fois")
        try expect(agent.bulkRequests >= 5, "plusieurs GETBULK chiffrés (\(agent.bulkRequests))")
        let next = try await client.getNext([SNMPOIDs.sysUpTime])
        try expectEqual(next.first?.oid, SNMPOIDs.sysName, "GETNEXT v3")
        let snapshot = try await SNMPSwitchPoller(client: client).snapshot()
        try expectEqual(snapshot.system.name, "SW-V3", "relevé complet en v3")
        try expectEqual(snapshot.physicalPorts.count, 30, "30 ports")
        let hardware = try await SNMPHardwareReader.read(v3: SNMPv3Client(host: localhost, port: agent.port, credentials: credentials, timeout: 1))
        try expectEqual(hardware?.serial, "FOC2331X0QZ", "ENTITY-MIB parcourue en v3 (index 1001)")
        try expectEqual(hardware?.model, "C9300-48P", "modèle")
        try expectEqual(agent.discoveries, 1, "moteur toujours en cache")
        // Agent redémarré (nouvel engineID) : le client le redécouvre et continue.
        agent.changeEngine()
        let again = try await client.get([SNMPOIDs.sysName])
        try expectEqual(again.first?.value.stringValue, "SW-V3", "après changement de moteur")
        try expectEqual(agent.discoveries, 2, "nouvelle découverte")
        // Mauvais mot de passe : erreur expliquée.
        var wrong = credentials
        wrong.authPassword = "pas-le-bon-mdp"
        do {
            _ = try await SNMPClient(target: SNMPTarget(host: localhost, port: agent.port, community: "", v3: wrong, timeout: 1, retries: 0))
                .get([SNMPOIDs.sysName])
            throw TestFailure(message: "mauvais mot de passe accepté", file: #fileID, line: #line)
        } catch let error as SNMPv3Error {
            try expectEqual(error, .report(.wrongDigest), "wrongDigest")
        }
    }

    suite.add("SNMP v3 : repli en v2c sur un agent qui ignore la v3, et découverte de fin de scan en v3") {
        SNMPv3Session.reset()
        SNMPVersionMemo.shared.reset()
        let credentials = SNMPv3Credentials(user: "netscope-ro", level: .authPriv, auth: .sha256, authPassword: "authpass123",
                                            priv: .aes128, privPassword: "privpass123")
        let v2 = try SNMPTestAgent(community: "lecture", table: sampleTable())
        defer { v2.stop() }
        let localhost = IPv4Address(127, 0, 0, 1)
        let mixed = SNMPTarget(host: localhost, port: v2.port, community: "lecture", v3: credentials, timeout: 0.3, retries: 0)
        let got = try await SNMPClient(target: mixed).get([SNMPOIDs.sysName])
        try expectEqual(got.first?.value.stringValue, "SW-V3", "réponse obtenue en v2c")
        try expect(SNMPVersionMemo.shared.prefersV2c(mixed), "v2c retenue pour cet agent")
        try expectEqual(mixed.versionLabel, "v2c (repli)", "libellé")
        let start = Date()
        _ = try await SNMPClient(target: mixed).get([SNMPOIDs.sysDescr])
        try expect(Date().timeIntervalSince(start) < 0.25, "requête suivante directement en v2c")

        let v3 = try FakeSNMPv3TableAgent(credentials: credentials, table: sampleTable())
        defer { v3.stop() }
        let ports: [IPv4Address: UInt16] = [IPv4Address(10, 9, 0, 1): v2.port, IPv4Address(10, 9, 0, 2): v3.port]
        let discovery = SNMPDiscovery(communities: ["lecture"], timeout: 0.3, retries: 0,
                                      endpoint: { (localhost, ports[$0] ?? 9) },
                                      v3: { $0 == IPv4Address(10, 9, 0, 2) ? credentials : nil })
        let found = await discovery.discover(Array(ports.keys))
        try expectEqual(found.map(\.host), [IPv4Address(10, 9, 0, 1), IPv4Address(10, 9, 0, 2)], "deux équipements")
        try expectEqual(found.map(\.versionLabel), ["v2c", "v3"], "le second en v3")
        try expectEqual(found.last?.sysName, "SW-V3", "sysName lu en v3")
        try expectEqual(found.last?.target().v3?.user, "netscope-ro", "relevé suivant en v3")
        try expectEqual(found.last?.kind, .switch, "classé switch")
    }
}

/// Lignes reçues par `onBatch` (appelé hors du fil du test).
final class SNMPBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [SNMPVarBind] = []
    func add(_ batch: [SNMPVarBind]) { lock.lock(); rows += batch; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return rows.count }
}

/// Faux agent SNMP v3 qui parcourt une table (GET, GETNEXT, GETBULK), sur 127.0.0.1 : découverte,
/// un utilisateur, rapports usmStats ; l'engineID peut changer (agent remplacé).
final class FakeSNMPv3TableAgent: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let credentials: SNMPv3Credentials
    private let table: SNMPTableAgent
    private let lock = NSLock()
    private var engine: [UInt8] = [0x80, 0x00, 0x1F, 0x88, 0x04, 0x57, 0x41, 0x4C, 0x4B, 0x30, 0x31]
    private var discoveryCount = 0
    private var bulkCount = 0
    private let running = OnceFlagTest()
    private let finished = DispatchSemaphore(value: 0)

    var discoveries: Int { lock.lock(); defer { lock.unlock() }; return discoveryCount }
    var bulkRequests: Int { lock.lock(); defer { lock.unlock() }; return bulkCount }

    init(credentials: SNMPv3Credentials, table: [SNMPVarBind]) throws {
        self.credentials = credentials
        self.table = SNMPTableAgent(table)
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw TestSkipped(reason: "socket UDP indisponible") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = IPv4Address(127, 0, 0, 1).value.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Bool in
                Darwin.bind(sock, raw, length) == 0 && getsockname(sock, raw, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(sock)
            throw TestSkipped(reason: "écoute UDP locale impossible")
        }
        fd = sock
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in self.loop() }
    }

    func stop() {
        running.stop()
        finished.wait()
        Darwin.close(fd)
    }

    func changeEngine() {
        lock.lock(); engine[engine.count - 1] &+= 1; lock.unlock()
    }

    private var currentEngine: [UInt8] { lock.lock(); defer { lock.unlock() }; return engine }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while running.isRunning {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, raw, &length) }
                }
            }
            guard count > 0, let reply = answer(Array(buffer[0..<count])) else { continue }
            _ = withUnsafePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    reply.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, raw, length) }
                }
            }
        }
        finished.signal()
    }

    private func report(_ suffix: UInt32, to request: SNMPv3Message) -> [UInt8]? {
        let engine = currentEngine
        let pdu = SNMPPDU(type: .report, requestID: request.pdu?.requestID ?? request.msgID,
                          varbinds: [SNMPVarBind(oid: SNMPOID([1, 3, 6, 1, 6, 3, 15, 1, 1, suffix, 0]), value: .counter32(1))])
        return try? SNMPv3Codec.encode(msgID: request.msgID, pdu: pdu, usm: SNMPUSMParameters(engineID: engine, boots: 5, time: 1_200),
                                       level: .noAuthNoPriv, reportable: false, contextEngineID: engine, contextName: "")
    }

    private func answer(_ bytes: [UInt8]) -> [UInt8]? {
        // Message v2c (ou autre) : ignoré, comme un agent configuré en v3 seulement.
        guard let request = try? SNMPv3Codec.decode(bytes) else { return nil }
        let engine = currentEngine
        if request.usm.engineID.isEmpty {
            lock.lock(); discoveryCount += 1; lock.unlock()
            return report(4, to: request)                                       // unknownEngineID : découverte
        }
        guard request.usm.engineID == engine else { return report(4, to: request) }
        guard request.usm.user == credentials.user else { return report(3, to: request) }
        let decoded: SNMPv3Message
        do {
            decoded = try SNMPv3Session.decodeResponse(bytes, credentials: credentials, engineID: engine)
        } catch SNMPv3Error.badResponseDigest {
            return report(5, to: request)
        } catch {
            return report(6, to: request)
        }
        guard let pdu = decoded.pdu else { return report(6, to: request) }
        if pdu.type == .getBulkRequest { lock.lock(); bulkCount += 1; lock.unlock() }
        let response = table.answer(pdu)
        let usm = SNMPUSMParameters(engineID: engine, boots: 5, time: 1_200, user: credentials.user)
        return try? SNMPv3Codec.encode(msgID: decoded.msgID, pdu: response, usm: usm, level: credentials.level, reportable: false,
                                       contextEngineID: engine, contextName: decoded.contextName,
                                       auth: credentials.auth, authKey: SNMPv3Session.authKey(credentials, engineID: engine),
                                       priv: credentials.priv, privKey: SNMPv3Session.privKey(credentials, engineID: engine),
                                       salt: 99)
    }
}
