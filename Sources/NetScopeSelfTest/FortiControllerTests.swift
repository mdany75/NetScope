import Foundation
import NetScopeCore

// Note 25 : plusieurs FortiGate (une par site), choix par plage IP, import et export CSV,
// migration de la 0.9.0, sous-réseaux des interfaces, fusion des relevés. Aucun réseau.

func registerFortiControllerTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)

    func controller(_ site: String, _ host: String, _ ranges: [String], enabled: Bool = true) -> FortiGateController {
        FortiGateController(site: site, host: host, ranges: ranges, isEnabled: enabled)
    }
    func range(_ text: String) -> IPRange { try! IPRange(parsing: text) }

    suite.add("FortiGate multisite : plages couvertes (CIDR, début-fin, masque, précision)") {
        let list = try FortiCoveredRange.parseList("10.20.0.0/16, 10.30.0.10-50; 10.40.0.5 192.168.1.0 255.255.255.0")
        try expectEqual(list.map(\.text), ["10.20.0.0/16", "10.30.0.10-10.30.0.50", "10.40.0.5", "192.168.1.0/24"], "formes lues")
        try expectEqual(list[0].first, IPv4Address("10.20.0.0")!, "réseau compris")
        try expectEqual(list[0].last, IPv4Address("10.20.255.255")!, "broadcast compris")
        try expectEqual(list[0].precision, 16, "précision d'un /16")
        try expectEqual(list[1].precision, 26, "41 adresses : comme un /26")
        try expectEqual(list[2].precision, 32, "adresse seule")
        try expectEqual(try FortiCoveredRange.parse("10.0.0.0/8").size, 16_777_216, "grande plage permise (pas de limite de scan)")
        try expectThrows(FortiRangeError.invalid("10.0.0.300/24"), "adresse illisible") { _ = try FortiCoveredRange.parse("10.0.0.300/24") }
        try expectThrows(FortiRangeError.reversed("10.0.0.50-10.0.0.10"), "à l'envers") { _ = try FortiCoveredRange.parse("10.0.0.50-10.0.0.10") }
        let lenient = FortiCoveredRange.parseLenient(["10.1.0.0/16", "n’importe quoi", "10.1.0.0/16"])
        try expectEqual(lenient.ranges.count, 1, "doublon retiré")
        try expectEqual(lenient.invalid, ["n’importe quoi"], "plage illisible signalée")
    }

    suite.add("FortiGate multisite : choix par plage scannée (contient, chevauche, plusieurs sites)") {
        let siege = controller("Siège", "10.182.122.1", ["10.182.0.0/16", "192.168.50.0/24"])
        let laval = controller("Entrepôt Laval", "10.20.0.1", ["10.20.0.0/16"])
        let quebec = controller("Bureau Québec", "10.30.0.1", ["10.30.0.0/16"])
        let all = [siege, laval, quebec]
        // La plage scannée est contenue dans une plage couverte.
        var s = FortiControllerSelector.select(all, scanned: [range("10.182.122.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [siege.id], "contient")
        try expectEqual(s.picks.first?.reason, .scannedRange, "raison")
        try expectEqual(s.picks.first?.coveredRanges, ["10.182.0.0/16"], "plage utilisée")
        // La plage scannée déborde (chevauche) : la FortiGate est quand même interrogée.
        s = FortiControllerSelector.select(all, scanned: [range("10.19.255.0-10.20.0.20")], macAddress: nil)
        try expectEqual(s.controllerIDs, [laval.id], "chevauche")
        // Deux sites scannés : les deux FortiGate, dans l'ordre de la liste ; une plage hors de tout site.
        s = FortiControllerSelector.select(all, scanned: [range("10.30.1.0/24"), range("10.182.122.0/24"), range("172.16.0.0/24")],
                                           macAddress: IPv4Address("10.20.0.135"))
        try expectEqual(s.controllerIDs, [siege.id, quebec.id], "chaque FortiGate concernée")
        try expectEqual(s.uncovered, ["172.16.0.0/24"], "plage sans FortiGate")
        // Contrôleur désactivé : jamais choisi.
        var off = laval
        off.isEnabled = false
        s = FortiControllerSelector.select([siege, off], scanned: [range("10.20.1.0/24")], macAddress: nil)
        try expect(s.isEmpty, "désactivé ignoré")
    }

    suite.add("FortiGate multisite : IP du Mac en secours, aucune FortiGate, réglages 0.9.0") {
        let siege = controller("Siège", "10.182.122.1", ["10.182.0.0/16"])
        let laval = controller("Entrepôt Laval", "10.20.0.1", ["10.20.0.0/16"])
        var s = FortiControllerSelector.select([siege, laval], scanned: [range("172.16.5.0/24")], macAddress: IPv4Address("10.20.3.40"))
        try expectEqual(s.controllerIDs, [laval.id], "plage scannée non couverte : FortiGate de l'IP du Mac")
        try expectEqual(s.picks.first?.reason, .macAddress, "raison : IP du Mac")
        try expectEqual(s.picks.first?.scannedRanges, ["10.20.3.40"], "adresse du Mac notée")
        s = FortiControllerSelector.select([siege, laval], scanned: [], macAddress: IPv4Address("10.20.3.40"))
        try expectEqual(s.controllerIDs, [laval.id], "sans plage scannée (Relire) : IP du Mac")
        s = FortiControllerSelector.select([siege, laval], scanned: [range("172.16.5.0/24")], macAddress: IPv4Address("192.168.1.10"))
        try expect(s.isEmpty, "aucune FortiGate : SNMP seulement")
        try expectEqual(s.uncovered, ["172.16.5.0/24"], "plage non couverte")
        try expect(FortiControllerSelector.select([], scanned: [range("10.0.0.0/24")], macAddress: nil).isEmpty, "liste vide")
        // 0.9.0 : une seule FortiGate sans plage, interrogée comme avant.
        let legacy = controller("Site principal", "10.182.122.1", [])
        s = FortiControllerSelector.select([legacy], scanned: [range("10.182.122.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [legacy.id], "sans plage nulle part : la FortiGate de la 0.9.0")
        try expectEqual(s.picks.first?.reason, .noRanges, "raison : plages à renseigner")
        // Dès qu'un site a des plages, une FortiGate sans plage n'est plus choisie d'office.
        s = FortiControllerSelector.select([legacy, laval], scanned: [range("10.182.122.0/24")], macAddress: nil)
        try expect(s.isEmpty, "sans plage : non choisie quand d'autres en ont")
    }

    suite.add("FortiGate multisite : la plage la plus précise gagne, conflits signalés") {
        let siege = controller("Siège", "10.182.122.1", ["10.0.0.0/8"])
        let laval = controller("Entrepôt Laval", "10.20.0.1", ["10.20.0.0/16"])
        let quai = controller("Quai Laval", "10.20.9.1", ["10.20.9.0/24"])
        let all = [siege, laval, quai]
        var s = FortiControllerSelector.select(all, scanned: [range("10.20.9.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [quai.id], "/24 avant /16 avant /8")
        s = FortiControllerSelector.select(all, scanned: [range("10.20.8.0/23")], macAddress: nil)
        try expectEqual(s.controllerIDs, [laval.id, quai.id], "plage à cheval : chaque partie à la plus précise")
        try expectEqual(s.pick(for: laval.id)?.scannedRanges, ["10.20.8.0/23"], "plage scannée notée")
        try expect(s.uncovered.isEmpty, "tout est couvert")
        // Plage couverte en partie : la partie sans FortiGate est signalée.
        let small = controller("Petit", "10.0.0.1", ["10.0.0.0/24"])
        s = FortiControllerSelector.select([small], scanned: [range("10.0.0.0/23")], macAddress: nil)
        try expectEqual(s.controllerIDs, [small.id], "couverte en partie : choisie")
        try expectEqual(s.uncovered, ["10.0.1.0/24"], "partie non couverte signalée")
        s = FortiControllerSelector.select([controller("Milieu", "10.0.0.1", ["10.0.0.10-10.0.0.20"])], scanned: [range("10.0.0.0/24")], macAddress: nil)
        try expectEqual(s.uncovered, ["10.0.0.0-10.0.0.9", "10.0.0.21-10.0.0.255"], "deux trous non alignés")
        s = FortiControllerSelector.select(all, scanned: [range("10.50.0.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [siege.id], "hors des plages précises : la plus large")
        let conflicts = FortiControllerSelector.conflicts(all)
        try expectEqual(conflicts.count, 3, "trois chevauchements")
        try expect(conflicts.allSatisfy { $0.kind == .nested && !$0.isAmbiguous }, "imbriqués : pas d'ambiguïté")
        // Même plage chez deux sites : vrai conflit, la première de la liste l'emporte.
        let twin = controller("Doublon", "10.20.0.2", ["10.20.0.0/16"])
        s = FortiControllerSelector.select([laval, twin], scanned: [range("10.20.1.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [laval.id], "à égalité : la première")
        try expectEqual(s.conflicts.first?.kind, .identical, "conflit signalé")
        try expect(s.conflicts.first?.message.contains("Conflit") == true, "message : \(s.conflicts.first?.message ?? "")")
        let partial = FortiControllerSelector.conflicts([controller("A", "10.0.0.1", ["10.0.0.0-10.0.0.99"]),
                                                         controller("B", "10.0.0.2", ["10.0.0.50-10.0.0.200"])])
        try expectEqual(partial.first?.kind, .partial, "chevauchement partiel")
        try expect(FortiControllerSelector.conflicts([siege, controller("Autre", "172.16.0.1", ["172.16.0.0/12"])]).isEmpty, "sans chevauchement")
    }

    suite.add("FortiGate multisite : modèle Codable tolérant, jeton jamais dans le JSON") {
        let id = UUID(uuidString: "6B1E0C77-55AA-4C1E-9E0F-1D2A3B4C5D6E")!
        var c = FortiGateController(id: id, site: "Siège", host: "10.182.122.1", port: 8443, vdom: "root", ranges: ["10.182.0.0/16"],
                                    pinnedFingerprint: "AB:CD", lastStatus: FortiControllerStatus(kind: .ok, date: now, switchCount: 3))
        let data = FortiControllerList.encode([c])!
        let text = String(decoding: data, as: UTF8.self)
        try expect(!text.lowercased().contains("token") && !text.contains("jeton") && !text.contains(FortiFixtures.token), "aucun jeton : \(text)")
        let back = FortiControllerList.decode(data)
        try expectEqual(back, [c], "aller-retour")
        // Champs absents, mal typés, plages en texte, entrée illisible, identifiant en double.
        let messy = """
        [{"id":"\(id.uuidString)","site":"Laval","host":"10.20.0.1","port":"10443","ranges":"10.20.0.0/16, 10.21.0.0/16",
          "isEnabled":"oui","lastStatus":{"kind":"nouveau-genre","message":"x"}},
         42,
         {"id":"\(id.uuidString)","host":"10.30.0.1","timeout":-3}]
        """
        let decoded = FortiControllerList.decode(Data(messy.utf8)) ?? []
        try expectEqual(decoded.count, 2, "entrée illisible ignorée")
        try expectEqual(decoded[0].port, 10443, "port en texte")
        try expectEqual(decoded[0].ranges, ["10.20.0.0/16", "10.21.0.0/16"], "plages en texte")
        let masked = FortiControllerList.decode(Data(#"[{"host":"10.1.0.1","ranges":"10.0.0.0 255.255.255.0, 10.9.0.0/16"}]"#.utf8)) ?? []
        try expectEqual(masked.first?.coveredRanges.map(\.text), ["10.0.0.0/24", "10.9.0.0/16"], "plages en texte avec masque à part")
        try expectEqual(FortiCoveredRange.parseLenient(FortiCoveredRange.splitBlocks("10.0.0.0 255.255.255.0\n10.1.0.0/24; 10.2.0.5")).ranges.map(\.text),
                        ["10.0.0.0/24", "10.1.0.0/24", "10.2.0.5"], "blocs : adresse et masque gardés ensemble")
        try expectEqual(decoded[0].isEnabled, true, "booléen illisible : activé")
        try expectEqual(decoded[0].lastStatus?.kind, .untested, "état inconnu : à tester")
        try expect(decoded[1].id != id, "identifiant en double : nouveau compte de jeton")
        try expectEqual(decoded[1].port, 443, "port par défaut")
        try expectEqual(decoded[1].timeout, 8, "délai aberrant corrigé")
        try expectEqual(decoded[1].displayName, "10.30.0.1", "sans site : l'adresse")
        try expect(FortiControllerList.decode(Data("{}".utf8)) == nil, "pas une liste")
        c.host = "10.182.122.1:10443"
        try expectEqual(c.addressLabel, "10.182.122.1:10443", "port dans l'adresse")
        try expectEqual(c.keychainAccount, id.uuidString, "compte du Trousseau = identifiant")
    }

    suite.add("FortiGate multisite : migration de la 0.9.0 (réglages, empreinte, jeton déplacé)") {
        let legacy = try JSONEncoder().encode(FortiGateConfig(host: "10.182.122.1", port: 8443, vdom: "root", pinnedFingerprint: "3F:A9:51"))
        let newID = UUID()
        let result = FortiControllerMigration.migrateSettings(existing: nil, legacy: legacy, newID: newID)
        try expectEqual(result.controllers.count, 1, "une entrée")
        try expectEqual(result.migratedID, newID, "migrée")
        let first = result.controllers[0]
        try expectEqual(first.host, "10.182.122.1", "adresse")
        try expectEqual(first.port, 8443, "port")
        try expectEqual(first.vdom, "root", "VDOM")
        try expectEqual(first.pinnedFingerprint, "3F:A9:51", "empreinte gardée")
        try expectEqual(first.site, FortiControllerMigration.legacySiteName, "nom du site")
        try expect(first.ranges.isEmpty, "plages à renseigner")
        // Jeton : copié vers le compte du contrôleur, ancien compte effacé.
        let store = FortiMemorySecretStore(["jeton": FortiFixtures.token, "autre": "x"])
        try expect(FortiControllerMigration.migrateToken(to: newID, store: store), "jeton déplacé")
        try expectEqual(store.secret(for: newID.uuidString), FortiFixtures.token, "nouveau compte")
        try expectEqual(store.secret(for: "jeton"), nil, "ancien compte effacé")
        try expectEqual(store.secret(for: "autre"), "x", "autres comptes intacts")
        // Rejouée : rien ne change, rien ne se perd.
        try expect(FortiControllerMigration.migrateToken(to: newID, store: store), "deuxième passage")
        try expectEqual(store.secret(for: newID.uuidString), FortiFixtures.token, "toujours là")
        // Jeton déjà présent au nouveau compte : jamais écrasé.
        let both = FortiMemorySecretStore(["jeton": "ancien", newID.uuidString: "neuf"])
        _ = FortiControllerMigration.migrateToken(to: newID, store: both)
        try expectEqual(both.secret(for: newID.uuidString), "neuf", "pas écrasé")
        // Sans jeton 0.9.0.
        try expect(!FortiControllerMigration.migrateToken(to: newID, store: FortiMemorySecretStore()), "rien à déplacer")
        // Liste déjà enregistrée : l'ancienne FortiGate n'est pas recréée.
        let saved = FortiControllerList.encode([FortiGateController(site: "Siège", host: "10.1.1.1")])!
        let again = FortiControllerMigration.migrateSettings(existing: saved, legacy: legacy)
        try expectEqual(again.controllers.map(\.host), ["10.1.1.1"], "liste existante gardée")
        try expectEqual(again.migratedID, nil, "pas de nouvelle migration")
        try expect(FortiControllerMigration.migrateSettings(existing: nil, legacy: nil).controllers.isEmpty, "rien à migrer")
        let empty = try JSONEncoder().encode(FortiGateConfig())
        try expect(FortiControllerMigration.migrateSettings(existing: nil, legacy: empty).controllers.isEmpty, "0.9.0 sans adresse")
    }

    suite.add("FortiGate multisite : sauvegardes sans jeton, comptes à ressaisir par site") {
        let siege = FortiGateController(site: "Siège", host: "10.182.122.1")
        let laval = FortiGateController(site: "Entrepôt Laval", host: "10.20.0.1")
        let items = [BackupKeychainItem(service: "com.danymenard.netscope.fortigate", account: siege.keychainAccount,
                                        usage: BackupKeychainScan.usage(for: "com.danymenard.netscope.fortigate")),
                     BackupKeychainItem(service: "com.danymenard.netscope.fortigate", account: laval.keychainAccount, usage: "x"),
                     BackupKeychainItem(service: "com.danymenard.netscope.snmp", account: "identifiants", usage: "SNMP")]
        let described = BackupKeychainScan.describe(items, fortiGates: [siege, laval])
        try expectEqual(described[0].usage, "Jeton de l’API REST de la FortiGate · Siège", "site du jeton")
        try expectEqual(described[1].usage, "Jeton de l’API REST de la FortiGate · Entrepôt Laval", "deuxième site")
        try expectEqual(described[2].usage, "SNMP", "autres services intacts")
        // Les réglages enregistrés (préférences sauvegardées) ne contiennent aucun jeton.
        let json = FortiControllerList.encode([siege, laval])!
        let prefs: [String: Any] = ["NetScope.fortigate.controleurs": json]
        let kept = BackupEngine.filterPreferences(prefs).kept
        try expect(kept["NetScope.fortigate.controleurs"] != nil, "liste sauvegardée")
        try expect(!String(decoding: json, as: UTF8.self).contains(FortiFixtures.token), "jeton absent")
    }

    suite.add("FortiGate multisite : import CSV (séparateurs, en-tête, erreurs expliquées)") {
        let text = """
        site;adresse;port;vdom;plages
        Siège;10.182.122.1;443;root;10.182.0.0/16, 192.168.50.0/24
        Entrepôt Laval;10.20.0.1;;;10.20.0.0/16 10.21.0.0/16
        # commentaire
        Bureau Québec;https://10.30.0.1:10443/;;;10.30.0.0/16
        ;10.40.0.1;443;;10.40.0.0/16
        Usine;10.40.0.1;99999;;10.40.0.0/16
        Atelier;pas une adresse!;443;;
        Labo;10.50.0.1;443;;10.50.0.0/33
        "Dépôt; nord";10.60.0.1;443;;10.60.0.0/16;jeton-secret
        """
        let result = FortiControllerCSV.parse(text)
        try expectEqual(result.rows.map(\.site), ["Siège", "Entrepôt Laval", "Bureau Québec", "Dépôt; nord"], "lignes valides gardées")
        try expectEqual(result.rows[0].ranges, ["10.182.0.0/16", "192.168.50.0/24"], "plages séparées par des virgules")
        try expectEqual(result.rows[1].ranges, ["10.20.0.0/16", "10.21.0.0/16"], "plages séparées par des espaces")
        try expectEqual(result.rows[1].port, 443, "port par défaut")
        try expectEqual(result.rows[2].host, "10.30.0.1", "adresse nettoyée")
        try expectEqual(result.rows[2].port, 10443, "port tiré de l'adresse")
        try expectEqual(result.errors.map(\.line), [6, 7, 8, 9], "lignes en erreur numérotées")
        try expect(result.errors[0].message.contains("site"), "site vide : \(result.errors[0].text)")
        try expect(result.errors[1].message.contains("port"), "port : \(result.errors[1].text)")
        try expect(result.errors[2].message.contains("adresse"), "adresse : \(result.errors[2].text)")
        try expect(result.errors[3].message.contains("10.50.0.0/33"), "plage : \(result.errors[3].text)")
        try expect(!result.notes.isEmpty, "colonne de trop signalée (jeton ignoré)")
        try expect(!"\(result.rows)".contains("jeton-secret"), "jeton jamais importé")
        // Virgule comme séparateur, sans en-tête ; les plages gardent leurs virgules.
        let comma = FortiControllerCSV.parse("Siège,10.182.122.1,443,root,10.182.0.0/16,192.168.50.0/24\r\nLaval,10.20.0.1\n")
        try expectEqual(comma.rows.count, 2, "virgule")
        try expectEqual(comma.rows[0].ranges, ["10.182.0.0/16", "192.168.50.0/24"], "plages après la quatrième colonne")
        try expectEqual(comma.rows[1].vdom, "", "colonnes absentes")
        try expect(comma.errors.isEmpty, "aucune erreur")
        // Fusion : même adresse mise à jour (jeton et empreinte gardés), sinon ajout.
        var existing = FortiGateController(site: "Ancien nom", host: "10.182.122.1", pinnedFingerprint: "AB")
        existing.lastStatus = FortiControllerStatus(kind: .ok)
        let merged = FortiControllerCSV.merge(result.rows, into: [existing])
        try expectEqual(merged.added, 3, "ajoutés")
        try expectEqual(merged.updated, 1, "mis à jour")
        try expectEqual(merged.controllers[0].id, existing.id, "même identifiant (même jeton)")
        try expectEqual(merged.controllers[0].site, "Siège", "site mis à jour")
        try expectEqual(merged.controllers[0].pinnedFingerprint, "AB", "empreinte gardée")
    }

    suite.add("FortiGate multisite : export CSV sans jeton, relu à l'identique") {
        let list = [FortiGateController(site: "Siège", host: "10.182.122.1", vdom: "root", ranges: ["10.182.0.0/16", "192.168.50.0/24"],
                                        pinnedFingerprint: "3F:A9"),
                    FortiGateController(site: "Dépôt; nord", host: "10.60.0.1", port: 10443, ranges: []),
                    FortiGateController(site: "=Formule", host: "10.70.0.1"),
                    FortiGateController(site: "-Annexe", host: "10.80.0.1")]
        let csv = FortiControllerCSV.export(list)
        try expect(csv.hasPrefix(FortiControllerCSV.header + "\n"), "en-tête")
        try expect(!csv.contains("3F:A9") && !csv.lowercased().contains("jeton") && !csv.contains(FortiFixtures.token), "ni jeton ni empreinte : \(csv)")
        try expect(csv.contains("Siège;10.182.122.1;443;root;10.182.0.0/16 192.168.50.0/24"), "ligne : \(csv)")
        try expect(csv.contains("'=Formule"), "formule neutralisée")
        let back = FortiControllerCSV.parse(csv)
        try expect(back.errors.isEmpty, "relu sans erreur : \(back.errors.map(\.text))")
        try expect(csv.contains("'-Annexe"), "tiret de tête neutralisé")
        try expectEqual(back.rows.map(\.site), ["Siège", "Dépôt; nord", "=Formule", "-Annexe"], "sites relus sans l'apostrophe ajoutée")
        // Deuxième aller-retour : le nom ne change plus.
        let again = FortiControllerCSV.parse(FortiControllerCSV.export(FortiControllerCSV.merge(back.rows, into: []).controllers))
        try expectEqual(again.rows.map(\.site), back.rows.map(\.site), "noms stables d'un aller-retour à l'autre")
        try expectEqual(FortiControllerCSV.parse("'Atelier;10.90.0.1").rows.first?.site, "'Atelier", "apostrophe ordinaire gardée")
        try expectEqual(back.rows[1].port, 10443, "port relu")
        try expectEqual(back.rows[0].ranges, list[0].ranges, "plages relues")
    }

    suite.add("FortiGate multisite : sous-réseaux des interfaces (cmdb, monitor, FortiLink)") {
        let cmdb = """
        {"http_method":"GET","results":[
          {"name":"wan1","ip":"203.0.113.10 255.255.255.248","type":"physical","role":"wan"},
          {"name":"internal","ip":"10.182.122.1 255.255.255.0","type":"hard-switch","role":"lan","alias":"Bureau",
           "secondary-IP":"enable","secondaryip":[{"id":1,"ip":"10.182.123.1 255.255.255.0"}]},
          {"name":"vlan30","ip":"10.182.130.1 255.255.254.0","type":"vlan","role":"lan","alias":"Quais"},
          {"name":"fortilink","ip":"10.255.1.1 255.255.255.0","type":"aggregate","fortilink":"enable"},
          {"name":"dmz","ip":"0.0.0.0 0.0.0.0","type":"physical"},
          {"name":"lo-mgmt","ip":"10.99.99.1 255.255.255.255","type":"loopback"},
          {"name":"ssl.root","ip":"0.0.0.0 0.0.0.0","type":"tunnel"},
          {"name":"vlan40","ip":"192.168.50.1/24","type":"vlan"},
          {"name":"copie","ip":"10.182.122.2 255.255.255.0","type":"vlan"}
        ],"status":"success"}
        """
        let list = FortiParsers.interfaceSubnets(Data(cmdb.utf8)) ?? []
        try expectEqual(list.map(\.subnet.description),
                        ["203.0.113.8/29", "10.182.122.0/24", "10.182.123.0/24", "10.182.130.0/23", "10.255.1.0/24", "192.168.50.0/24"],
                        "sous-réseaux (vides, boucle et doublons ignorés)")
        try expectEqual(list.filter(\.isSuggested).map(\.subnet.description),
                        ["10.182.122.0/24", "10.182.123.0/24", "10.182.130.0/23", "192.168.50.0/24"], "cochés par défaut : LAN privés")
        try expect(list.first { $0.name == "fortilink" }?.isFortiLink == true, "FortiLink repéré")
        try expectEqual(list.first { $0.subnet.description == "10.182.130.0/23" }?.label, "vlan30 · Quais", "libellé avec l'alias")
        try expect(list.contains { $0.name == "internal (secondaire)" }, "adresse secondaire")
        // monitor : dictionnaire par nom, masque en nombre ou en texte, ou ipv4_addresses.
        let monitor = """
        {"results":{"port1":{"name":"port1","ip":"10.20.0.1","mask":16,"link":true},
                    "fortilink":{"name":"fortilink","ip":"10.255.1.1","mask":"255.255.255.0"},
                    "vlan7":{"name":"vlan7","ipv4_addresses":[{"ip":"10.21.7.1","cidr_netmask":24}]},
                    "port9":{"name":"port9","ip":"0.0.0.0","mask":0}}}
        """
        let m = FortiParsers.interfaceSubnets(Data(monitor.utf8)) ?? []
        try expectEqual(Set(m.map(\.subnet.description)), ["10.20.0.0/16", "10.255.1.0/24", "10.21.7.0/24"], "monitor")
        try expect(m.first { $0.name == "fortilink" }?.isSuggested == false, "FortiLink non coché")
        try expect(FortiParsers.interfaceSubnets(Data("pas du json".utf8)) == nil, "illisible")
        try expectEqual(FortiParsers.interfaceSubnets(Data(#"{"results":[]}"#.utf8))?.count, 0, "aucune interface")
        // Lecture : cmdb refusée (droit Network absent) → monitor.
        let transport = FortiFakeTransport([FortiPaths.interfacesConfig: (403, #"{"status":"error","http_status":403}"#),
                                            FortiPaths.interfacesMonitor: (200, monitor)])
        let read = try await FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token).interfaces()
        try expectEqual(read.subnets.count, 3, "repli sur monitor")
        try expectEqual(read.calls.map(\.outcome), [.refused, .ok], "appels notés")
        try expectEqual(transport.requested, [FortiPaths.interfacesConfig, FortiPaths.interfacesMonitor], "GET seulement, deux adresses")
    }

    suite.add("FortiGate multisite : fusion de plusieurs FortiGate (site, FortiLink en double, priorité)") {
        let a = try await FortiGateReader(transport: FortiFakeTransport(FortiFixtures.v74())).read(now: now)
        var b = a
        b.system.hostname = "FGT-LAVAL"
        // Même adresse FortiLink, autre switch : chaque site garde le sien.
        b.switches = b.switches.map { sw in
            var copy = sw
            copy.switchID = sw.switchID.replacingOccurrences(of: "FSW", with: "LAV")
            copy.name = copy.switchID
            return copy
        }
        b.detected = []
        b.userDevices = []
        b.dhcp = []
        b.arp = [FortiARPEntry(ip: IPv4Address("10.10.0.31")!, mac: MACAddress("02:00:00:00:00:99")!),
                 FortiARPEntry(ip: IPv4Address("10.20.5.5")!, mac: MACAddress("02:00:00:00:00:55")!)]
        let siege = FortiSiteReport(controllerID: UUID(), site: "Siège", report: a, coveredRanges: try FortiCoveredRange.parseList("10.0.0.0/9 192.168.0.0/16"))
        let laval = FortiSiteReport(controllerID: UUID(), site: "Entrepôt Laval", report: b, coveredRanges: try FortiCoveredRange.parseList("10.20.0.0/16"))
        let snaps = FortiMulti.snapshots([siege, laval])
        try expectEqual(snaps.count, a.switches.count * 2, "tous les FortiSwitch")
        try expectEqual(Set(snaps.map(\.host)).count, snaps.count, "adresses uniques")
        try expectEqual(snaps.first?.controllerName, "Siège", "marqué du site")
        try expectEqual(snaps.last?.controllerName, "Entrepôt Laval", "deuxième site")
        let lavalFirst = snaps[a.switches.count]
        try expectEqual(lavalFirst.fortiLinkIP, IPv4Address("10.255.1.2"), "adresse FortiLink réelle gardée")
        try expect(lavalFirst.host != IPv4Address("10.255.1.2")!, "adresse de remplacement")
        try expect(lavalFirst.host.value < (1 << 24), "remplacement en 0.x.y.z : jamais interrogée")
        // ARP : chaque site pour ses plages ; 10.10.0.31 reste au Siège (Laval ne couvre pas 10.10/16).
        let arp = FortiMulti.arpTable([laval, siege])
        try expectEqual(arp[IPv4Address("10.10.0.31")!], MACAddress("00:50:56:aa:10:31"), "ARP du site qui couvre l'adresse")
        try expectEqual(arp[IPv4Address("10.20.5.5")!], MACAddress("02:00:00:00:00:55"), "ARP de Laval")
        // Emplacement : FortiGate avant SNMP, comme pour un site.
        let cam = MACAddress("bc:ad:28:6f:01:5a")!
        let snmp = SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                                      interfaces: [SNMPInterface(index: 33, name: "Gi1/0/33", operStatus: .up)],
                                      fdb: [SNMPFDBEntry(mac: cam, vlan: 40, bridgePort: 33, ifIndex: 33)])
        let devices = [Device(ip: IPv4Address("192.168.50.21")!, mac: cam, switchName: "SW-CORE-01", switchPort: "Gi1/0/33"),
                       Device(ip: IPv4Address("10.10.0.31")!)]
        let result = FortiMulti.apply([siege, laval], to: devices, snmp: [snmp])
        let byIP = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.id, $0) })
        try expectEqual(byIP["192.168.50.21"]?.switchName, "FSW-QUAI", "FortiGate prioritaire")
        try expectEqual(byIP["10.10.0.31"]?.mac, MACAddress("00:50:56:aa:10:31"), "MAC du bon site")
        // Un seul site : même résultat que la 0.9.0.
        let single = FortiMulti.apply([FortiSiteReport(controllerID: UUID(), site: "", report: a)], to: devices, snmp: [snmp])
        let old = FortiLocate.apply(a, to: devices, snmp: [snmp])
        try expectEqual(single.devices, old.devices, "un site : comme avant")
        try expectEqual(FortiMulti.snapshots([FortiSiteReport(controllerID: UUID(), site: "", report: a)]).first?.controllerName,
                        a.controllerName, "sans site : nom d'hôte de la FortiGate")
    }

    suite.add("FortiGate multisite : lectures en parallèle plafonnées, résultats dans l'ordre") {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var peak = 0
            func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
            func leave() { lock.lock(); running -= 1; lock.unlock() }
        }
        let counter = Counter()
        let output = await FortiMulti.parallel(Array(0..<20), limit: 4) { n -> Int in
            counter.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            counter.leave()
            return n * 2
        }
        try expectEqual(output, Array(0..<20).map { $0 * 2 }, "ordre gardé")
        try expect(counter.peak <= 4, "au plus quatre à la fois : \(counter.peak)")
        try expect(counter.peak >= 2, "en parallèle : \(counter.peak)")
        let none = await FortiMulti.parallel([Int](), limit: 4) { $0 }
        try expect(none.isEmpty, "liste vide")
    }
}
