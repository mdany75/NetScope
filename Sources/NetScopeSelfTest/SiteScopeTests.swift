import Foundation
import NetScopeCore

// 0.12.0, ajouts de Dany : suppression d'appareils de l'inventaire (simple, multiple, « Ne plus
// suivre », annulation, sites non touchés) et choix d'un ou plusieurs sites (lecture combinée de
// plusieurs inventaires sans fusion à IP égale, rapport multisite). Données fixes, aucun réseau ;
// seuls des fichiers temporaires sont écrits.

func registerSiteScopeTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)

    func device(_ address: String, _ mac: String?, host: String? = nil, online: Bool = true, at date: Date? = nil) -> Device {
        Device(ip: IPv4Address(address)!, mac: mac.flatMap(MACAddress.init), hostname: host, isOnline: online,
               firstSeen: date ?? now, lastSeen: date ?? now, deviceType: .poste)
    }
    /// Deux scans : le second produit des événements (changement d'IP de l'imprimante).
    func store() -> InventoryStore {
        var store = InventoryStore()
        store.merge([device("10.0.0.1", "04:D5:90:3A:7B:11", host: "fgt"),
                     device("10.0.0.20", "94:DD:F8:18:15:7D", host: "imprimante"),
                     device("10.0.0.30", "B0:7B:25:20:00:07", host: "poste-7"),
                     device("10.0.0.40", nil, host: "camera")], at: now.addingTimeInterval(-3_600))
        store.merge([device("10.0.0.1", "04:D5:90:3A:7B:11", host: "fgt"),
                     device("10.0.0.21", "94:DD:F8:18:15:7D", host: "imprimante"),
                     device("10.0.0.30", "B0:7B:25:20:00:07", host: "poste-7"),
                     device("10.0.0.40", nil, host: "camera")], at: now)
        return store
    }
    let printer = InventoryStore.key(mac: MACAddress("94:DD:F8:18:15:7D")!)
    let desktop = InventoryStore.key(mac: MACAddress("B0:7B:25:20:00:07")!)
    let camera = InventoryStore.key(ip: IPv4Address("10.0.0.40")!)

    // MARK: Suppression

    suite.add("Inventaire : supprimer un appareil retire sa fiche et ses événements") {
        var inventory = store()
        try expect(!inventory.events(for: printer).isEmpty, "l'imprimante a des événements")
        let snapshots = inventory.snapshots.count
        let removal = inventory.removeRecords([printer], exclude: false, at: now)
        try expectEqual(removal.count, 1, "une fiche retirée")
        try expect(inventory.record(printer) == nil, "fiche retirée")
        try expect(inventory.events(for: printer).isEmpty, "événements retirés (modèle de removeRecord)")
        try expect(!removal.events.isEmpty, "événements gardés pour l'annulation")
        try expectEqual(inventory.snapshots.count, snapshots, "instantanés de scan gardés")
        try expectEqual(inventory.count, 3, "les autres fiches restent")
        // Sans « Ne plus suivre », l'appareil revient au prochain scan.
        inventory.merge([device("10.0.0.21", "94:DD:F8:18:15:7D", host: "imprimante")], at: now.addingTimeInterval(60))
        try expect(inventory.record(printer) != nil, "revenu au scan suivant")
    }

    suite.add("Inventaire : supprimer plusieurs appareils, clés inconnues ou en double ignorées") {
        var inventory = store()
        let removal = inventory.removeRecords([printer, desktop, printer, "mac:00:00:00:00:00:99", camera], exclude: false, at: now)
        try expectEqual(removal.count, 3, "trois fiches retirées")
        try expectEqual(inventory.count, 1, "la passerelle reste")
        try expect(removal.addedExclusions.isEmpty, "aucune exclusion sans la case")
    }

    suite.add("Inventaire : « Ne plus suivre » empêche le retour au prochain scan") {
        var inventory = store()
        inventory.removeRecords([printer, camera], exclude: true, at: now)
        try expectEqual(inventory.excluded.map(\.key).sorted(), [camera, printer].sorted(), "deux exclusions")
        try expectEqual(inventory.excluded.first { $0.key == printer }?.name, "imprimante", "nom retenu")
        let later = now.addingTimeInterval(120)
        let produced = inventory.merge([device("10.0.0.1", "04:D5:90:3A:7B:11", host: "fgt", at: later),
                                        device("10.0.0.22", "94:DD:F8:18:15:7D", host: "imprimante", at: later),
                                        device("10.0.0.40", nil, host: "camera", at: later),
                                        device("10.0.0.30", "B0:7B:25:20:00:07", host: "poste-7", at: later)], at: later)
        try expect(inventory.record(printer) == nil, "MAC exclue : pas de nouvelle fiche, même à une autre IP")
        try expect(inventory.record(camera) == nil, "sans MAC : exclue par son adresse")
        try expect(!produced.contains { $0.key == printer || $0.key == camera }, "aucun événement pour les exclus")
        // Lecture du fichier : l'exclusion est enregistrée.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-exclusions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try inventory.save(to: url)
        let reloaded = try InventoryStore.load(from: url)
        try expect(reloaded.isExcluded(key: printer), "exclusion relue")
        // Suivre de nouveau.
        var again = reloaded
        again.include(printer)
        again.merge([device("10.0.0.22", "94:DD:F8:18:15:7D", host: "imprimante", at: later)], at: later.addingTimeInterval(60))
        try expect(again.record(printer) != nil, "suivi de nouveau : revenu")
        // Ancien fichier (sans le champ) : lu sans exclusion.
        var legacy = store()
        legacy.include("rien")
        try legacy.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        try expect(!text.contains("exclusions"), "aucun champ vide écrit")
        let legacyRead = try InventoryStore.load(from: url)
        try expect(legacyRead.excluded.isEmpty, "ancien format relu")
    }

    suite.add("Inventaire : annuler la suppression remet fiches, événements et exclusions") {
        let original = store()
        var inventory = original
        let removal = inventory.removeRecords([printer, desktop], exclude: true, at: now)
        inventory.restore(removal)
        try expectEqual(inventory.records, original.records, "fiches remises")
        try expectEqual(inventory.events, original.events, "événements remis à leur place")
        try expect(inventory.excluded.isEmpty, "exclusions retirées")
        // Une exclusion déjà là avant n'est pas retirée par l'annulation d'une autre suppression.
        var twice = original
        twice.removeRecords([camera], exclude: true, at: now)
        let second = twice.removeRecords([printer], exclude: true, at: now)
        twice.restore(second)
        try expectEqual(twice.excluded.map(\.key), [camera], "l'exclusion précédente reste")
    }

    suite.add("Inventaire : la suppression d'un site ne touche pas les autres sites") {
        // Deux sites aux mêmes adresses et à la même MAC : deux inventaires distincts.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SiteFiles(base: base)
        try files.saveInventory(store(), for: "siege")
        try files.saveInventory(store(), for: "laval")
        var siege = try files.loadInventory(for: "siege")
        siege.removeRecords([printer], exclude: true, at: now)
        try files.saveInventory(siege, for: "siege")
        let laval = try files.loadInventory(for: "laval")
        try expect(laval.record(printer) != nil, "Laval garde sa fiche")
        try expect(laval.excluded.isEmpty, "Laval n'exclut rien")
        let siegeRead = try files.loadInventory(for: "siege")
        try expect(siegeRead.record(printer) == nil, "Siège : fiche retirée")
        let groups = SiteScope.grouped([SiteScope.id(site: "siege", key: printer), SiteScope.id(site: "laval", key: desktop),
                                        SiteScope.id(site: "siege", key: camera), SiteScope.id(site: "siege", key: printer)])
        try expectEqual(groups.map(\.site), ["siege", "laval"], "groupes dans l'ordre des sites")
        try expectEqual(groups.first?.keys, [printer, camera], "clés du Siège sans doublon")
    }

    // MARK: Plusieurs sites

    suite.add("Sites : lecture combinée de plusieurs inventaires, jamais fusionnés à IP égale") {
        let inventories = [SiteInventory(key: "siege", name: "Siège", store: store()),
                           SiteInventory(key: "laval", name: "Entrepôt Laval", store: store())]
        let rows = SiteScope.records(inventories)
        try expectEqual(rows.count, 8, "4 fiches par site, aucune fusion")
        try expectEqual(Set(rows.map(\.id)).count, 8, "identifiants distincts")
        let gateways = rows.filter { $0.record.ip == IPv4Address("10.0.0.1")! }
        try expectEqual(gateways.map(\.siteName), ["Siège", "Entrepôt Laval"], "même IP et même MAC : deux lignes")
        try expectEqual(SiteScope.split(gateways[1].id)?.site, "laval", "identifiant composé site|fiche")
        try expectEqual(SiteScope.split(gateways[1].id)?.key, gateways[1].record.key, "clé de fiche retrouvée")
        // Préfixe site: de la recherche.
        let query = SearchQuery("site:laval ip:10.0.0.1", schema: .inventaire)
        try expectEqual(rows.filter { query.matches($0) }.map(\.siteKey), ["laval"], "site:laval")
        let alerts = SiteScope.alerts(inventories, since: now.addingTimeInterval(-86_400))
        try expect(!alerts.isEmpty, "alertes des deux sites")
        try expectEqual(Set(alerts.map(\.id)).count, alerts.count, "alertes distinctes par site")
        try expectEqual(alerts.map(\.siteKey), alerts.map(\.siteKey).sorted { $0 > $1 }, "regroupées par site (Siège puis Laval)")
        let analyse = SearchQuery("site:siège", schema: .analyse)
        let item = InvEventSearchItem(alerts[0].event, deviceName: "", siteName: alerts[0].siteName)
        try expect(analyse.matches(item), "site: dans l'Analyse")
    }

    suite.add("Sites : choix d'un, de plusieurs ou de tous les sites") {
        let available = ["a", "b", "c"]
        try expectEqual(SiteSelection.active.resolve(activeKey: "b", available: available), ["b"], "site actif")
        try expectEqual(SiteSelection.all.resolve(activeKey: "b", available: available), ["b", "a", "c"], "tous, actif d'abord")
        try expectEqual(SiteSelection.sites(["c", "a"]).resolve(activeKey: "b", available: available), ["a", "c"], "ordre des sites")
        try expectEqual(SiteSelection.sites(["supprimé"]).resolve(activeKey: "b", available: available), ["b"], "site disparu : actif")
        try expectEqual(SiteSelection(stored: SiteSelection.sites(["a", "c"]).stored), .sites(["a", "c"]), "enregistrement")
        try expectEqual(SiteSelection(stored: "tous"), .all, "tous enregistré")
        try expectEqual(SiteSelection.active.toggling("a", activeKey: "b", available: available), .sites(["b", "a"]), "ajout")
        try expectEqual(SiteSelection.sites(["b", "a"]).toggling("a", activeKey: "b", available: available), .active, "retour à l'actif")
        try expectEqual(SiteSelection.sites(["b", "a"]).toggling("c", activeKey: "b", available: available), .all, "tous cochés")
        let sites = [(key: "s", name: "Siège"), (key: "l", name: "Entrepôt Laval"), (key: "q", name: "Bureau Québec")]
        try expectEqual(SiteSelection.parse("siege,laval", sites: sites), .sites(["s", "l"]), "NETSCOPE_SITES_VUE")
        try expectEqual(SiteSelection.parse("Tous", sites: sites), .all, "« tous »")
        try expect(SiteSelection.parse("inconnu", sites: sites) == nil, "aucun site")
    }

    suite.add("Rapports : rapport multisite, une section par site, rien de fusionné") {
        let siege = ReportInput(devices: [device("10.0.0.1", "04:D5:90:3A:7B:11", host: "fgt"),
                                          device("10.0.0.20", "94:DD:F8:18:15:7D", host: "imprimante")],
                                records: store().sortedRecords, scanDate: now, now: now)
        let laval = ReportInput(devices: [device("10.0.0.1", "00:09:0F:AA:10:01", host: "fgt-laval")], scanDate: now, now: now)
        let config = ReportConfig(client: "Groupe Exemple", site: "", technician: "Dany", date: "2026-11-03")
        let document = ReportBuilder.buildMultisite(config: config, sites: [ReportSiteInput(name: "Siège", input: siege),
                                                                            ReportSiteInput(name: "Entrepôt Laval", input: laval)])
        try expectEqual(document.sections.first?.heading, "Sites du rapport", "tableau des sites d'abord")
        try expectEqual(document.site, "Siège, Entrepôt Laval", "sites dans l'en-tête")
        try expect(document.title.hasSuffix("Siège, Entrepôt Laval"), "sites dans le titre")
        let single = ReportBuilder.build(config: config, input: siege)
        let perSite = document.sections.filter { $0.site == "Siège" }
        try expectEqual(perSite.count, single.sections.count, "chaque partie pour le Siège")
        try expectEqual(document.sections.filter { $0.site == "Entrepôt Laval" }.count, single.sections.count, "et pour Laval")
        try expectEqual(Set(document.sections.map(\.id)).count, document.sections.count, "identifiants de section distincts")
        try expect(perSite.allSatisfy { $0.heading.hasPrefix("Siège — ") }, "titres préfixés par le site")
        guard case .table(let table)? = document.sections.first?.blocks.last else { throw TestFailure(message: "tableau des sites absent", file: #fileID, line: #line) }
        try expectEqual(table.rows.map { $0.cells[1].text }, ["2", "1"], "appareils comptés par site, même IP non fusionnée")
        try expect(document.problems.allSatisfy { $0.title.hasPrefix("Siège — ") || $0.title.hasPrefix("Entrepôt Laval — ") },
                   "problèmes rattachés à leur site")
        let one = ReportBuilder.buildMultisite(config: config, sites: [ReportSiteInput(name: "Siège", input: siege)])
        try expectEqual(one.sections.map(\.heading), single.sections.map(\.heading), "un seul site : rapport ordinaire")
        try expectEqual(one.site, "Siège", "nom du site repris")
        let json = try ReportExport.json(document)
        try expect(String(decoding: json, as: UTF8.self).contains("Entrepôt Laval|resume"), "JSON : sections distinctes")
    }
}
