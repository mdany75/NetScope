import Foundation
import NetScopeCore

// Note 28 : sites (préréglages du Scanner), inventaire et résultats propres à chaque site,
// détection par la passerelle, FortiGate du site, switchs SNMP associés, CSV, migration et
// sauvegarde. Données fixes ; seuls des fichiers temporaires sont écrits, aucun réseau.

/// Valeur présente, sinon échec du test.
private func siteRequire<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}

func registerSiteTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    let gatewayA = MACAddress("04:D5:90:3A:7B:11")!
    let gatewayB = MACAddress("00:09:0F:AA:10:01")!

    func range(_ text: String, _ label: String = "Plage", vlan: Int? = nil) -> ScanRangeConfig {
        ScanRangeConfig(text: text, label: label, vlan: vlan)
    }
    func ip(_ text: String) -> IPRange { try! IPRange(parsing: text) }
    func device(_ address: String, _ mac: String?, host: String? = nil, online: Bool = true) -> Device {
        Device(ip: IPv4Address(address)!, mac: mac.flatMap(MACAddress.init), hostname: host, isOnline: online,
               firstSeen: now, lastSeen: now, deviceType: .poste)
    }
    func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    suite.add("Sites : modèle, lecture tolérante, nom unique, dupliquer sans inventaire") {
        var hints = SiteHints()
        hints.learn(gatewayMAC: gatewayA)
        hints.learn(serial: "FGT60FTK2209A1B2", hostname: "FGT-SIEGE")
        let siege = Site(name: "Siège", ranges: [range("10.182.122.0/24", "Bureau", vlan: 1)], fortiGateIDs: [UUID()],
                         switchHosts: ["10.182.122.2"], hints: hints, created: now)
        var list = SiteList(sites: [siege], activeID: siege.id)
        list.add(Site(name: "siège", created: now))
        try expectEqual(list.sites[1].name, "siège (2)", "nom déjà pris (casse ignorée)")
        let data = try siteRequire(list.encoded(), "encodage")
        let back = try siteRequire(SiteList.decode(data), "relecture")
        try expectEqual(back, list, "aller-retour JSON")

        // Champs absents, mal typés, plage illisible, MAC illisible : ignorés sans perdre le reste.
        let raw = #"{"sites":[{"id":"\#(siege.id.uuidString)","name":"Siège","ranges":[{"text":"10.0.0.0/24"},{"id":"\#(UUID().uuidString)","text":"10.1.0.0/24","label":"B","isEnabled":true}],"hints":{"gatewayMACs":["zz","04:d5:90:3a:7b:11"]},"switchHosts":["10.0.0.2","pas une ip"],"fortiGateIDs":"x"},{"name":42},{"id":"\#(siege.id.uuidString)","name":"Doublon"}],"activeID":"inconnu"}"#
        let lenient = try siteRequire(SiteList.decode(Data(raw.utf8)), "lecture tolérante")
        try expectEqual(lenient.sites.count, 3, "trois sites (dont un sans nom)")
        try expectEqual(lenient.sites[0].ranges.map(\.text), ["10.1.0.0/24"], "plage incomplète ignorée")
        try expectEqual(lenient.sites[0].hints.gatewayMACs, [gatewayA], "MAC illisible ignorée")
        try expectEqual(lenient.sites[0].switchHosts, ["10.0.0.2"], "switch illisible ignoré")
        try expect(lenient.sites[2].id != siege.id, "identifiant en double renouvelé")
        let again = try siteRequire(SiteList.decode(Data(raw.utf8)), "deuxième lecture")
        try expectEqual(again.sites[2].id, lenient.sites[2].id, "identifiant renouvelé stable d'une lecture à l'autre (dossier retrouvé)")
        try expectEqual(lenient.activeID, nil, "site actif inconnu : aucun")
        try expectEqual(lenient.sites[1].displayName, "Site sans nom", "nom absent")

        let copy = try siteRequire(list.duplicate(siege.id, now: now), "dupliquer")
        try expectEqual(copy.name, "Siège (copie)", "nom de la copie")
        try expectEqual(copy.ranges.map(\.text), siege.ranges.map(\.text), "mêmes plages")
        try expect(copy.ranges[0].id != siege.ranges[0].id, "nouvelles plages (identifiants)")
        try expect(copy.hints.isEmpty, "indices non copiés (une passerelle ne désigne qu'un site)")
        try expectEqual(copy.inventoryCount, nil, "inventaire non copié")
        list.remove(siege.id)
        try expectEqual(list.activeID, nil, "site actif supprimé : aucun site actif")
    }

    suite.add("Sites : plages non enregistrées et mêmes plages sur deux sites") {
        let a = [range("192.168.1.0/24", "Postes", vlan: 1)]
        var b = a
        b[0].id = UUID()
        try expect(Site.sameRanges(a, b), "mêmes plages, identifiants différents")
        b[0].label = "Autre"
        try expect(!Site.sameRanges(a, b), "libellé changé : modification à enregistrer")
        try expect(Site.sameAddresses(a, b), "mêmes adresses à scanner")
        let one = Site(name: "Clinique Exemple", ranges: a, created: now)
        let two = Site(name: "Groupe X · Laval", ranges: b, created: now)
        let list = SiteList(sites: [one, two])
        try expectEqual(list.sharingRanges(with: one.id).map(\.id), [two.id], "deux sites sur 192.168.1.0/24")
        try expectEqual(list.sitesOverlapping([ip("192.168.1.10")]).count, 2, "l'adresse est dans les deux")
        let partial = Site(name: "Bureau Québec", ranges: [range("10.30.0.0/24"), range("192.168.1.0/24", "Invités")], created: now)
        let three = SiteList(sites: [one, two, partial])
        try expectEqual(three.sharingRanges(with: one.id).map(\.id), [two.id], "mêmes plages exactement")
        try expectEqual(three.sharingAddresses(with: one.id).map(\.id), [partial.id, two.id], "une plage en commun suffit, noms en ordre alphabétique")
    }

    suite.add("Sites : ordre alphabétique, jamais l'ordre de création") {
        let shared = [range("192.168.1.0/24")]
        let names = ["Zénith Centre", "atelier Nord", "Égide Sud", "Eden Est", "Ouest 12"]
        let list = SiteList(sites: names.map { Site(name: $0, ranges: shared, switchHosts: ["10.0.0.2"], created: now) })
        let sorted = ["atelier Nord", "Eden Est", "Égide Sud", "Ouest 12", "Zénith Centre"]
        try expectEqual(list.sortedByName.map(\.displayName), sorted, "accents et majuscules ne dérangent pas le tri")
        try expectEqual(list.sites(forSwitch: "10.0.0.2").map(\.displayName), sorted, "sites d'un switch triés")
        let first = try siteRequire(list.sites.first, "premier site")
        try expectEqual(list.sharingAddresses(with: first.id).map(\.displayName), sorted.filter { $0 != first.displayName }, "sites aux adresses communes triés")
    }

    suite.add("Sites : détection par la passerelle, jamais par la seule IP") {
        let shared = [range("192.168.1.0/24")]
        let clinique = Site(name: "Clinique Exemple", ranges: shared, hints: SiteHints(gatewayMACs: [gatewayA], ssid: "Clinique"), created: now)
        let groupe = Site(name: "Groupe X · Laval", ranges: shared,
                          hints: SiteHints(fortiGateSerials: ["FGT40FTK23001802"], fortiGateHostnames: ["FGT-LAVAL"], ssid: "Groupe"), created: now)
        let siege = Site(name: "Siège", ranges: [range("10.182.122.0/24")], created: now)
        let sites = [clinique, groupe, siege]
        let address = IPv4Address("192.168.1.50")!, gateway = IPv4Address("192.168.1.1")!

        var o = SiteObservation(address: address, gateway: gateway, gatewayMAC: gatewayA)
        try expectEqual(SiteDetector.detect(o, in: sites), .matched(clinique.id, by: .gatewayMAC), "MAC de la passerelle")
        o = SiteObservation(address: address, gateway: gateway, gatewayMAC: gatewayB, fortiGateSerial: "fgt40ftk23001802")
        try expectEqual(SiteDetector.detect(o, in: sites), .matched(groupe.id, by: .fortiGateSerial), "série (casse ignorée)")
        o = SiteObservation(address: address, gateway: gateway, fortiGateHostname: "FGT-LAVAL")
        try expectEqual(SiteDetector.detect(o, in: sites), .matched(groupe.id, by: .fortiGateHostname), "nom de la FortiGate")

        // Même plage, aucun indice : on demande, aucun choix automatique.
        o = SiteObservation(address: address, gateway: gateway, gatewayMAC: gatewayB)
        let asked = SiteDetector.detect(o, in: sites)
        try expectEqual(asked.matchedID, nil, "pas de choix par l'IP")
        try expectEqual(Set(asked.candidates), [clinique.id, groupe.id], "les deux sites proposés")
        // Un seul site contient l'adresse : on demande quand même (l'IP seule ne suffit pas).
        let alone = SiteDetector.detect(SiteObservation(address: IPv4Address("10.182.122.135")!, gateway: IPv4Address("10.182.122.1")!), in: sites)
        try expectEqual(alone.candidates, [siege.id], "candidat unique")
        try expectEqual(alone.matchedID, nil, "toujours une question")
        // Le SSID départage les sites aux mêmes plages.
        o = SiteObservation(address: address, gateway: gateway, ssid: "Groupe")
        try expectEqual(SiteDetector.detect(o, in: sites), .matched(groupe.id, by: .ssid), "SSID")
        // Indices contradictoires (même MAC sur deux sites) : on demande.
        var twin = clinique
        twin.id = UUID()
        twin.hints.ssid = nil
        var copy = clinique
        copy.hints.ssid = nil
        let contradictory = SiteDetector.detect(SiteObservation(address: address, gatewayMAC: gatewayA), in: [copy, twin])
        try expectEqual(contradictory.candidates.count, 2, "même MAC sur deux sites")
        try expectEqual(contradictory.matchedID, nil, "aucun choix")
        try expectEqual(SiteDetector.detect(SiteObservation(address: IPv4Address("172.16.0.5")!), in: sites), .none, "aucun site")
    }

    suite.add("Sites : FortiGate du site actif ; par plage seulement sans site") {
        let siegeGate = FortiGateController(site: "Siège", host: "10.182.122.1", ranges: ["10.182.0.0/16"])
        let cliniqueGate = FortiGateController(site: "Clinique Exemple", host: "192.168.1.1", ranges: ["192.168.1.0/24"])
        let groupeGate = FortiGateController(site: "Groupe X", host: "192.168.1.254", ranges: ["192.168.1.0/24"])
        let all = [siegeGate, cliniqueGate, groupeGate]
        let groupe = Site(name: "Groupe X · Laval", ranges: [range("192.168.1.0/24")], fortiGateIDs: [groupeGate.id], created: now)
        // Même plage chez deux clients : la FortiGate du site actif, pas la première de la liste.
        var s = SiteFortiGate.select(site: groupe, controllers: all, scanned: [ip("192.168.1.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [groupeGate.id], "FortiGate du site actif")
        try expectEqual(s.picks.first?.reason, .activeSite, "raison")
        // Site sans FortiGate : aucune, jamais celle d'un autre client.
        let none = Site(name: "Sans FortiGate", ranges: [range("192.168.1.0/24")], created: now)
        s = SiteFortiGate.select(site: none, controllers: all, scanned: [ip("192.168.1.0/24")], macAddress: nil)
        try expect(s.isEmpty, "aucune FortiGate")
        // Aucun site actif : l'ancien choix par plage (note 25).
        s = SiteFortiGate.select(site: nil, controllers: all, scanned: [ip("10.182.122.0/24")], macAddress: nil)
        try expectEqual(s.controllerIDs, [siegeGate.id], "choix par plage sans site")
        try expectEqual(s.picks.first?.reason, .scannedRange, "raison par plage")
        // FortiGate désactivée : ignorée même si elle est associée.
        var disabled = groupeGate
        disabled.isEnabled = false
        s = SiteFortiGate.select(site: groupe, controllers: [siegeGate, disabled], scanned: [], macAddress: nil)
        try expect(s.isEmpty, "FortiGate désactivée")
        try expectEqual(SiteFortiGate.matching([siegeGate, cliniqueGate], ranges: [ip("10.182.122.0/24")]), [siegeGate.id], "FortiGate des plages")
        try expectEqual(SiteFortiGate.matching([siegeGate], ranges: []), [siegeGate.id], "seule FortiGate")
    }

    suite.add("Sites : création depuis les FortiGate (nom, plages, série, nom d'hôte)") {
        var laval = FortiGateController(site: "Entrepôt Laval", host: "10.20.0.1", ranges: ["10.20.0.0/24", "10.0.0.0/8"])
        laval.lastStatus = FortiControllerStatus(kind: .ok, hostname: "FGT-LAVAL", serial: "FGT40FTK23001802")
        let quebec = FortiGateController(site: "Bureau Québec", host: "10.30.0.1", ranges: ["10.30.0.0/24"])
        let existing = SiteList(sites: [Site(name: "Bureau Québec", fortiGateIDs: [quebec.id], created: now)])
        let created = SiteFortiGate.sitesToCreate(from: [laval, quebec], existing: existing, now: now)
        try expectEqual(created.count, 1, "Québec déjà associée à un site")
        let site = created[0]
        try expectEqual(site.name, "Entrepôt Laval", "nom du site de la FortiGate")
        try expectEqual(site.fortiGateIDs, [laval.id], "FortiGate associée")
        try expectEqual(site.ranges.map(\.text), ["10.20.0.0/24", "10.0.0.0/24"], "plages couvertes (un /8 donne son premier /24)")
        try expectEqual(site.ranges.map(\.isEnabled), [true, false], "extrait décoché")
        try expectEqual(site.hints.fortiGateSerials, ["FGT40FTK23001802"], "série relue")
        try expectEqual(site.hints.fortiGateHostnames, ["FGT-LAVAL"], "nom d'hôte relu")
        // Le numéro de série relu est gardé dans l'état de la FortiGate (lecture tolérante).
        let data = try JSONEncoder().encode(laval.lastStatus)
        try expectEqual(try JSONDecoder().decode(FortiControllerStatus.self, from: data).serial, "FGT40FTK23001802", "série enregistrée")
    }

    suite.add("Sites : import et export CSV site;plages;fortigate sans secret") {
        let gate = FortiGateController(site: "Siège", host: "10.182.122.1", ranges: ["10.182.0.0/16"])
        let csv = """
        \u{FEFF}site;plages;fortigate
        Siège;10.182.122.0/24 (Bureau, VLAN 1) | 192.168.50.0/24 (Caméras, VLAN 40);Siège
        "Clinique Exemple";"192.168.1.0/24 (Postes) | 10.0.0.9, 10.0.0.12 (Imprimantes, décochée)";192.168.1.1
        ;10.0.0.0/24;
        Mauvais;10.0.0.300/24;
        Vlan;10.1.0.0/24 (VLAN 5000);
        """
        let parsed = SiteCSV.parse(csv)
        try expectEqual(parsed.rows.count, 2, "deux lignes valides")
        try expectEqual(parsed.errors.map(\.line), [4, 5, 6], "lignes refusées")
        let siege = parsed.rows[0]
        try expectEqual(siege.ranges.map(\.text), ["10.182.122.0/24", "192.168.50.0/24"], "plages")
        try expectEqual(siege.ranges.map(\.label), ["Bureau", "Caméras"], "libellés")
        try expectEqual(siege.ranges.map(\.vlan), [1, 40], "VLAN")
        let clinique = parsed.rows[1]
        try expectEqual(clinique.ranges[1].text, "10.0.0.9, 10.0.0.12", "liste d'adresses")
        try expectEqual(clinique.ranges[1].isEnabled, false, "plage décochée")

        let existing = SiteList(sites: [Site(name: "siège", ranges: [range("10.0.0.0/24")], created: now)])
        let merged = SiteCSV.merge(parsed.rows, into: existing, controllers: [gate], now: now)
        try expectEqual(merged.added, 1, "Clinique créée")
        try expectEqual(merged.updated, 1, "Siège mis à jour (casse ignorée)")
        try expectEqual(merged.list.sites[0].fortiGateIDs, [gate.id], "FortiGate par son site")
        try expectEqual(merged.unknownFortiGates, ["192.168.1.1"], "FortiGate inconnue signalée")

        let export = SiteCSV.export(merged.list.sites, controllers: [gate])
        try expect(export.hasPrefix("site;plages;fortigate\n"), "en-tête")
        try expect(export.contains("10.182.122.0/24 (Bureau, VLAN 1) | 192.168.50.0/24 (Caméras, VLAN 40)"), "plages exportées")
        try expect(!export.lowercased().contains("jeton") && !export.lowercased().contains("token"), "aucun secret")
        let again = SiteCSV.parse(export)
        try expectEqual(again.errors, [], "relecture sans erreur")
        try expectEqual(again.rows.map(\.name), ["siège", "Clinique Exemple"], "aller-retour (nom du site existant gardé)")
        try expectEqual(again.rows[1].ranges.map(\.isEnabled), [true, false], "case cochée gardée")
    }

    suite.add("Sites : inventaire propre à chaque site (même IP, même MAC : deux fiches)") {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        let a = SiteFiles.key(for: UUID()), b = SiteFiles.key(for: UUID())
        var storeA = InventoryStore()
        storeA.merge([device("192.168.1.10", "94:DD:F8:18:15:7D", host: "poste-clinique")], at: now)
        _ = storeA.setManualType(.camera, for: device("192.168.1.10", "94:DD:F8:18:15:7D"))
        try files.saveInventory(storeA, for: a)
        var storeB = InventoryStore()
        storeB.merge([device("192.168.1.10", "94:DD:F8:18:15:7D", host: "poste-groupe")], at: now)
        try files.saveInventory(storeB, for: b)

        let readA = try files.loadInventory(for: a), readB = try files.loadInventory(for: b)
        try expectEqual(readA.count, 1, "une fiche au site A")
        try expectEqual(readB.count, 1, "une fiche au site B")
        try expectEqual(readA.record(forIP: IPv4Address("192.168.1.10")!)?.hostname, "poste-clinique", "fiche du site A")
        try expectEqual(readB.record(forIP: IPv4Address("192.168.1.10")!)?.hostname, "poste-groupe", "fiche du site B, non fusionnée")
        try expectEqual(readA.manualType(for: device("192.168.1.10", "94:DD:F8:18:15:7D")), .camera, "type choisi à la main au site A")
        try expectEqual(readB.manualType(for: device("192.168.1.10", "94:DD:F8:18:15:7D")), nil, "pas au site B")
        // Fusion d'un scan dans le site du scan seulement.
        var target = try files.loadInventory(for: b)
        target.merge([device("192.168.1.11", nil)], at: now.addingTimeInterval(60))
        try files.saveInventory(target, for: b)
        try expectEqual(files.inventoryCount(for: a), 1, "site A inchangé")
        try expectEqual(files.inventoryCount(for: b), 2, "fusion au site B")
        // Suppression d'un site : son dossier disparaît, l'autre reste.
        files.removeFolder(for: a)
        try expect(!FileManager.default.fileExists(atPath: files.inventoryURL(for: a).path), "inventaire du site supprimé")
        try expectEqual(files.inventoryCount(for: b), 2, "l'autre site garde son inventaire")
    }

    suite.add("Sites : résultats mis de côté et rechargés par site (même IP sans fusion)") {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        let a = SiteFiles.key(for: UUID()), b = SiteFiles.key(for: UUID())
        var shelf = SiteResultsShelf(files: files)
        let network = NetworkContext(interface: "en0", subnet: try Subnet(parsing: "192.168.1.0/24"), gateway: IPv4Address("192.168.1.1")!)
        let switchResult = SwitchAutoResult(date: now, ranges: [ip("192.168.1.0/24")], network: network,
                                            switches: [.init(name: "SW-CLINIQUE", host: IPv4Address("192.168.1.2")!, located: [IPv4Address("192.168.1.10")!])],
                                            locatedHosts: [IPv4Address("192.168.1.10")!], communitiesTried: 2)
        let resultsA = SiteResults(devices: [device("192.168.1.10", "94:DD:F8:18:15:7D", host: "poste-clinique")],
                                   customNames: ["192.168.1.10": "Accueil"], newIDs: ["192.168.1.10"],
                                   lastScanRanges: ["192.168.1.0/24"], startedAt: now, finishedAt: now.addingTimeInterval(30),
                                   switchResult: SiteSwitchRecord(switchResult),
                                   locations: [SiteLocationRecord(ip: IPv4Address("192.168.1.10")!, network: network)])
        shelf.shelve(resultsA, for: a)
        let fresh = shelf.take(b)
        try expect(fresh.isEmpty, "site B : rien à reprendre")
        shelf.shelve(SiteResults(devices: [device("192.168.1.10", "5C:F9:38:02:7A:41", host: "poste-groupe")]), for: b)
        try expectEqual(shelf.take(a).devices.first?.hostname, "poste-clinique", "retour au site A")
        try expectEqual(shelf.take(b).devices.first?.hostname, "poste-groupe", "site B séparé (même IP)")

        // Sur le disque : un nouveau lancement retrouve les résultats du site.
        var reopened = SiteResultsShelf(files: files)
        let back = reopened.take(a)
        try expectEqual(back.devices.map(\.hostname), ["poste-clinique"], "appareils relus")
        try expectEqual(back.customNames, ["192.168.1.10": "Accueil"], "noms personnalisés relus")
        try expectEqual(back.parsedScanRanges, [ip("192.168.1.0/24")], "plages du dernier scan")
        try expectEqual(back.switchResult?.result, switchResult, "bilan des switchs relu")
        try expectEqual(back.locationsByNetwork.first?.hosts, [IPv4Address("192.168.1.10")!], "emplacements relus")
        reopened.forget(a)
        try expectEqual(reopened.take(a).devices.count, 1, "oubli en mémoire : relu du disque")
    }

    suite.add("Sites : switchs affichés (site actif, sans site dans les plages, hors plages masqué)") {
        let siegeGate = UUID(), lavalGate = UUID()
        let siege = Site(name: "Siège", ranges: [range("10.182.122.0/24")], fortiGateIDs: [siegeGate], switchHosts: ["10.182.122.2"], created: now)
        let laval = Site(name: "Entrepôt Laval", ranges: [range("10.20.0.0/24")], fortiGateIDs: [lavalGate], switchHosts: ["10.20.0.2"], created: now)
        let candidates: [SiteSwitchFilter.Candidate] = [
            .init(host: "10.182.122.2"),              // SNMP associé au Siège
            .init(host: "10.182.122.3"),              // SNMP sans site, dans les plages
            .init(host: "172.16.9.2"),                // SNMP sans site, hors plages
            .init(host: "10.20.0.2"),                 // SNMP d'un autre site
            .init(host: "10.255.1.2", controllerID: siegeGate),
            .init(host: "0.1.1.2", controllerID: lavalGate),
        ]
        let shown = SiteSwitchFilter.visible(candidates, activeSite: siege, sites: [siege, laval], scanRanges: [ip("10.182.122.0/24")])
        try expectEqual(shown, ["10.182.122.2", "10.182.122.3", "10.255.1.2"], "switchs du Siège seulement")
        // Sans scan : les plages du site servent.
        let noScan = SiteSwitchFilter.visible(candidates, activeSite: siege, sites: [siege, laval], scanRanges: [])
        try expectEqual(noScan, shown, "plages du site")
        // Aucun site actif : FortiSwitch tous, SNMP dans les plages scannées seulement.
        let free = SiteSwitchFilter.visible(candidates, activeSite: nil, sites: [siege, laval], scanRanges: [ip("10.20.0.0/24")])
        try expectEqual(free, ["10.20.0.2", "10.255.1.2", "0.1.1.2"], "sans site")
    }

    suite.add("Sites : migration sans perte vers « Site principal »") {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        var legacy = InventoryStore()
        legacy.merge([device("10.182.122.111", "94:DD:F8:18:15:7D", host: "imprimante"), device("10.182.122.20", nil)], at: now)
        _ = legacy.setManualType(.imprimante, for: device("10.182.122.20", nil))
        try legacy.save(to: files.legacyInventoryURL)
        let gate = FortiGateController(site: "Siège", host: "10.182.122.1", ranges: ["10.182.0.0/16"],
                                       lastStatus: FortiControllerStatus(kind: .ok, hostname: "FGT-SIEGE", serial: "FGT60FTK2209A1B2"))
        let other = FortiGateController(site: "Laval", host: "10.20.0.1", ranges: ["10.20.0.0/16"])
        let ranges = [range("10.182.122.0/24", "Bureau", vlan: 1), range("10.10.0.1-50", "Serveurs")]
        let id = UUID()
        let result = try siteRequire(try SiteMigration.migrateIfNeeded(files: files, ranges: ranges, customNames: ["10.182.122.20": "Poste accueil"],
                                                                          controllers: [gate, other], newID: id, now: now), "migration faite")
        let site = try siteRequire(result.list.active, "site actif")
        try expectEqual(site.name, "Site principal", "nom")
        try expectEqual(site.ranges, ranges, "plages reprises telles quelles")
        try expectEqual(site.fortiGateIDs, [gate.id], "FortiGate correspondante rattachée")
        try expectEqual(site.hints.fortiGateSerials, ["FGT60FTK2209A1B2"], "série reprise")
        try expectEqual(result.migratedRecords, 2, "deux fiches reprises")
        let moved = try files.loadInventory(for: SiteFiles.key(for: id))
        try expectEqual(moved.count, 2, "inventaire du site")
        try expectEqual(moved.manualType(for: device("10.182.122.20", nil)), .imprimante, "type choisi à la main repris")
        try expect(FileManager.default.fileExists(atPath: files.legacyBackupURL.path), "copie de sécurité gardée")
        try expect(!FileManager.default.fileExists(atPath: files.legacyInventoryURL.path), "ancien fichier renommé")
        try expectEqual(try InventoryStore.load(from: files.legacyBackupURL).count, 2, "copie de sécurité intacte")
        try expectEqual(files.loadResults(for: SiteFiles.key(for: id))?.customNames, ["10.182.122.20": "Poste accueil"], "noms repris")
        try expectEqual(files.loadList()?.activeID, id, "sites.json écrit")
        // Deuxième lancement : rien n'est refait.
        let second = try SiteMigration.migrateIfNeeded(files: files, ranges: [], customNames: [:], controllers: [])
        try expect(second == nil, "une seule fois")
    }

    suite.add("Sites : sites.json illisible jamais pris pour une première ouverture") {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        if case .missing = files.readList() {} else { throw TestFailure(message: "liste absente attendue", file: #fileID, line: #line) }
        let a = UUID(), b = UUID()
        var store = InventoryStore()
        store.merge([device("192.168.1.10", nil), device("192.168.1.11", nil)], at: now)
        try files.saveInventory(store, for: SiteFiles.key(for: a))
        try files.saveInventory(InventoryStore(), for: SiteFiles.key(for: b))
        try Data("{\"sites\": [".utf8).write(to: files.listURL)
        if case .unreadable = files.readList() {} else { throw TestFailure(message: "liste illisible attendue", file: #fileID, line: #line) }
        try expect(files.loadList() == nil, "loadList : rien de lu")
        // La migration ne touche pas à un sites.json présent, même illisible.
        let none = try SiteMigration.migrateIfNeeded(files: files, ranges: [range("10.0.0.0/24")], customNames: [:], controllers: [])
        try expect(none == nil, "aucune migration sur un fichier illisible")
        try expectEqual(try Data(contentsOf: files.listURL), Data("{\"sites\": [".utf8), "fichier illisible intact")
        let aside = try siteRequire(files.setAsideUnreadableList(now: now), "mis de côté")
        try expect(aside.lastPathComponent.hasPrefix("sites.illisible-"), "nom de la copie")
        try expect(!FileManager.default.fileExists(atPath: files.listURL.path), "sites.json retiré")
        let recovered = files.recoveredList(now: now)
        try expectEqual(Set(recovered.sites.map(\.id)), [a, b], "un site par dossier, même identifiant")
        try expectEqual(recovered.sites.map(\.name).sorted(), ["Site récupéré", "Site récupéré (2)"], "noms uniques")
        try expectEqual(recovered.site(a)?.inventoryCount, 2, "nombre de fiches repris")
        try expect(recovered.activeID != nil, "un site actif")
        try expectEqual(files.siteFolderIDs().count, 2, "dossier sans-site ignoré, UUID seulement")
    }

    suite.add("Sites : migration sûre (reprise, sites.json perdu, notes d'appareils)") {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        var legacy = InventoryStore()
        legacy.merge([device("10.0.0.5", "94:DD:F8:18:15:7D")], at: now)
        try legacy.save(to: files.legacyInventoryURL)
        try Data(#"{"94:dd:f8:18:15:7d":"Toner remplacé"}"#.utf8).write(to: files.legacyNotesURL)
        // Essai précédent interrompu : le même identifiant est repris.
        let earlier = UUID()
        try earlier.uuidString.write(to: files.migrationMarkerURL, atomically: true, encoding: .utf8)
        let result = try siteRequire(try SiteMigration.migrateIfNeeded(files: files, ranges: [range("10.0.0.0/24")], customNames: [:],
                                                                          controllers: [], now: now), "migration faite")
        try expectEqual(result.siteID, earlier, "identifiant de l'essai interrompu repris")
        try expect(!FileManager.default.fileExists(atPath: files.migrationMarkerURL.path), "marqueur retiré après succès")
        try expectEqual(files.loadList()?.activeID, earlier, "sites.json écrit")
        try expect(FileManager.default.fileExists(atPath: files.legacyBackupURL.path), "ancien inventaire renommé après sites.json")
        let notes = try Data(contentsOf: files.notesURL(for: SiteFiles.key(for: earlier)))
        try expectEqual(try JSONDecoder().decode([String: String].self, from: notes), ["94:dd:f8:18:15:7d": "Toner remplacé"], "notes du site")
        try expect(!FileManager.default.fileExists(atPath: files.legacyNotesURL.path), "anciennes notes renommées")
        try expect(FileManager.default.fileExists(atPath: files.legacyNotesBackupURL.path), "copie de sécurité des notes")
        try expectEqual(BackupEngine.label(for: "sites/\(earlier.uuidString)/notes-appareils.json"), "notes des appareils (site)", "libellé des notes")

        // sites.json supprimé après coup (ancien inventaire déjà renommé) : on récupère les
        // dossiers des sites au lieu de créer un « Site principal » vide.
        try FileManager.default.removeItem(at: files.listURL)
        let recovered = try siteRequire(try SiteMigration.migrateIfNeeded(files: files, ranges: [], customNames: [:], controllers: []), "récupération")
        try expectEqual(result.list.sites.count, 1, "un site migré")
        try expectEqual(recovered.recoveredSites, 1, "un site récupéré")
        try expectEqual(recovered.list.sites.first?.id, earlier, "même dossier, même site")
        try expectEqual(recovered.list.sites.first?.inventoryCount, 1, "son inventaire")

        // Notes déjà propres au site : l'ancien fichier ne les écrase pas.
        try Data(#"{"10.0.0.9":"autre"}"#.utf8).write(to: files.legacyNotesURL)
        let copied = try SiteMigration.migrateDeviceNotes(files: files, into: SiteFiles.key(for: earlier))
        try expect(!copied, "notes du site gardées")
        try expect(!FileManager.default.fileExists(atPath: files.legacyNotesURL.path), "ancien fichier mis de côté")
    }

    suite.add("Sites : un switch d'un autre site n'est jamais interrogé automatiquement") {
        let laval = Site(name: "Laval", ranges: [range("192.168.1.0/24")], switchHosts: ["192.168.1.2"], created: now)
        let siege = Site(name: "Siège", ranges: [range("192.168.1.0/24")], switchHosts: ["192.168.1.3"], created: now)
        let hosts = ["192.168.1.2", "192.168.1.3", "192.168.1.4"]
        let atSiege = SiteSwitchFilter.pollable(hosts, activeSite: siege, sites: [laval, siege], scanRanges: [ip("192.168.1.0/24")])
        try expectEqual(atSiege, ["192.168.1.3", "192.168.1.4"], "le switch de Laval est écarté, même ajouté à la main")
        let atLaval = SiteSwitchFilter.pollable(hosts, activeSite: laval, sites: [laval, siege], scanRanges: [])
        try expectEqual(atLaval, ["192.168.1.2", "192.168.1.4"], "au site Laval, son switch")
        let free = SiteSwitchFilter.pollable(hosts, activeSite: nil, sites: [laval, siege], scanRanges: [ip("10.0.0.0/24")])
        try expectEqual(free, ["192.168.1.4"], "sans site : un switch de site hors des plages scannées est écarté")
        try expectEqual(SiteHintKind.ssid.labelWithArticle, "le SSID", "article du libellé")
        try expectEqual(SiteHintKind.fortiGateSerial.labelWithArticle, "le numéro de série de la FortiGate", "article du libellé")
    }

    suite.add("Sites : préfixe site: de la recherche relié au vrai site") {
        let item = DeviceSearchItem(device("192.168.1.10", nil), site: nil, siteName: "Clinique Exemple")
        try expect(SearchQuery("site:clinique", schema: .scanner).matches(item), "nom du site")
        try expect(!SearchQuery("site:laval", schema: .scanner).matches(item), "autre site")
        let forti = DeviceSearchItem(device("10.20.0.5", nil), site: "Entrepôt Laval", siteName: "Groupe X · Laval")
        try expect(SearchQuery("site:groupe", schema: .scanner).matches(forti), "site du client")
        try expect(SearchQuery("site:entrepôt", schema: .scanner).matches(forti), "site de la FortiGate gardé")
    }

    suite.add("Sites : la sauvegarde inclut les inventaires de tous les sites") {
        let base = try temporaryBase()
        let out = try temporaryBase()
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: out)
        }
        let files = SiteFiles(base: base)
        let a = UUID(), b = UUID()
        try files.saveList(SiteList(sites: [Site(id: a, name: "Siège", created: now), Site(id: b, name: "Clinique Exemple", created: now)], activeID: a))
        var store = InventoryStore()
        store.merge([device("192.168.1.10", nil)], at: now)
        try files.saveInventory(store, for: SiteFiles.key(for: a))
        try files.saveInventory(store, for: SiteFiles.key(for: b))
        files.saveResults(SiteResults(devices: [device("192.168.1.10", nil)]), for: SiteFiles.key(for: b))
        let source = BackupSource(dataDirectory: base, preferences: nil, keychain: [], appVersion: "0.12.0", appBuild: "1")
        let info = try BackupEngine.create(source, in: out, format: .dossier, kind: .manuelle, date: now)
        let contents = try BackupEngine.read(info.url)
        let paths = Set(contents.manifest.files.map(\.path))
        try expect(paths.contains("sites.json"), "liste des sites")
        try expect(paths.contains("sites/\(a.uuidString)/inventory.json"), "inventaire du Siège")
        try expect(paths.contains("sites/\(b.uuidString)/inventory.json"), "inventaire de la Clinique")
        try expect(paths.contains("sites/\(b.uuidString)/resultats.json"), "résultats de la Clinique")
        try expectEqual(BackupEngine.label(for: "sites/\(a.uuidString)/inventory.json"), "inventaire (site)", "libellé")
    }
}
