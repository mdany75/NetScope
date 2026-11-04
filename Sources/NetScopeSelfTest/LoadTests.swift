import Foundation
import NetScopeCore

// Note 36 : essais de charge sans réseau. Données fictives de LoadFixtures (aucun appel réseau ;
// seuls des fichiers temporaires sont écrits). Chaque mesure a un seuil, fixé pour la version
// de débogage (`swift build`) sur un Mac Apple Silicon : la version publiée (optimisée) est
// plusieurs fois plus rapide.
//
// Les essais rapides tournent toujours (moins de 10 s au total) ; les gros (20 sites complets,
// historique long) seulement avec NETSCOPE_CHARGE=1 :
//   swift build && NETSCOPE_CHARGE=1 ./.build/debug/NetScopeSelfTest

/// Temps mesurés, imprimés en tableau à la fin des essais de charge.
final class LoadTimings: @unchecked Sendable {
    static let shared = LoadTimings()
    private let lock = NSLock()
    private(set) var rows: [(name: String, seconds: Double, limit: Double)] = []
    /// Début des essais de charge (durée totale imprimée avec le tableau).
    var started: UInt64?

    func add(_ name: String, _ seconds: Double, limit: Double) {
        lock.lock()
        rows.append((name, seconds, limit))
        lock.unlock()
    }

    func printTable(title: String) {
        lock.lock()
        let copy = rows
        rows = []
        lock.unlock()
        guard !copy.isEmpty else { return }
        print("")
        print("  \(title)")
        print("  " + "Mesure".padding(toLength: 62, withPad: " ", startingAt: 0) + "Temps (ms)  Seuil (ms)")
        for row in copy {
            let ms = String(format: "%10.1f", row.seconds * 1000)
            let limit = String(format: "%11.0f", row.limit * 1000)
            print("  " + row.name.padding(toLength: 62, withPad: " ", startingAt: 0) + ms + " " + limit)
        }
        if let started {
            print(String(format: "  Durée des essais de charge (génération des données comprise) : %.1f s",
                         Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))
        }
        print("")
    }
}

/// Chronomètre `body` et échoue si le seuil (en secondes) est dépassé.
@discardableResult
func timed<T>(_ name: String, limit: Double, file: String = #fileID, line: Int = #line, _ body: () throws -> T) throws -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try body()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    LoadTimings.shared.add(name, seconds, limit: limit)
    try expect(seconds <= limit, "\(name) : \(String(format: "%.0f", seconds * 1000)) ms, seuil \(String(format: "%.0f", limit * 1000)) ms",
               file: file, line: line)
    return result
}

func timedAsync<T>(_ name: String, limit: Double, file: String = #fileID, line: Int = #line,
                   _ body: () async throws -> T) async throws -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try await body()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    LoadTimings.shared.add(name, seconds, limit: limit)
    try expect(seconds <= limit, "\(name) : \(String(format: "%.0f", seconds * 1000)) ms, seuil \(String(format: "%.0f", limit * 1000)) ms",
               file: file, line: line)
    return result
}

func registerLoadTests(_ suite: TestSuite) {
    let heavy = ProcessInfo.processInfo.environment["NETSCOPE_CHARGE"] == "1"
    let now = LoadFixtures.now

    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-charge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Essais rapides (toujours)

    suite.add("Charge : inventaire d’un site de 5 000 appareils (fusion, écriture, lecture)") {
        LoadTimings.shared.started = DispatchTime.now().uptimeNanoseconds
        var seedRandom = LoadRandom(seed: 36)
        let site = LoadFixtures.site(0, devices: 5_000, random: &seedRandom)
        var store = InventoryStore()
        try timed("Fusion du 1er scan (5 000 appareils, inventaire vide)", limit: 1.0) {
            store.merge(site.devices, at: now, coverage: .ranges(site.ranges))
        }
        var random = LoadRandom(seed: 9)
        let next = LoadFixtures.nextScan(site.devices, step: 1, random: &random)
        let produced = try timed("Fusion d’un scan de 5 000 appareils (inventaire de 5 000)", limit: 1.0) {
            store.merge(next, at: now.addingTimeInterval(3_600), coverage: .ranges(site.ranges))
        }
        try expect(produced.contains { $0.kind == .changementIP }, "changements d'IP relevés")
        try expect(produced.contains { $0.kind == .horsLigne }, "appareils hors ligne relevés")
        try expect(store.count >= site.devices.count && store.count <= next.count + 300, "une fiche par appareil")

        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("inventory.json")
        try timed("Écriture de l’inventaire d’un site (5 000 fiches)", limit: 0.8) { try store.save(to: url) }
        let loaded = try timed("Lecture de l’inventaire d’un site (5 000 fiches)", limit: 0.8) { try InventoryStore.load(from: url) }
        try expectEqual(loaded.count, store.count, "relu à l'identique (fiches)")
        try expectEqual(loaded.events.count, store.events.count, "relu à l'identique (événements)")

        // Une fiche modifiée : l'inventaire entier est réécrit (avant la note 36, à chaque changement).
        let key = store.sortedRecords[100].key
        try timed("Une fiche modifiée puis enregistrée", limit: 0.8) {
            var notes = store.record(key)!.annotations
            notes.notes = "Changé"
            store.setAnnotations(notes, for: key, at: now)
            try store.save(to: url)
        }

        // Depuis la note 36 : dix changements rapprochés, une seule écriture différée, hors du fil
        // de l'appelant (InvModel).
        let writer = InventoryWriter(delay: 30)
        let changed = store.sortedRecords[200..<210].map(\.key)
        try timed("10 fiches modifiées (enregistrement différé, côté écran)", limit: 0.15) {
            for (n, other) in changed.enumerated() {
                var notes = store.record(other)!.annotations
                notes.owner = "Responsable \(n)"
                store.setAnnotations(notes, for: other, at: now)
                writer.schedule(store, to: url)
            }
        }
        try timed("Écriture regroupée des 10 changements (file de fond)", limit: 0.8) { writer.flush() }
        try expectEqual(writer.writeCount, 1, "une seule écriture pour dix changements")
        try expectEqual(try InventoryStore.load(from: url).record(changed[9])?.annotations.owner,
                        "Responsable 9", "dernière version écrite")

        // Lecture de l'écran Inventaire à chaque rendu : la deuxième fois, tout vient de la mémoire.
        let inventory = [SiteInventory(key: site.key, name: site.name, store: store)]
        _ = SiteScope.records(inventory)
        try timed("Lignes de l’Inventaire relues au rendu suivant (mémoire)", limit: 0.02) {
            for _ in 0..<10 { _ = SiteScope.records(inventory) }
        }
        try timed("Doublons, conflits et événements relus au rendu suivant", limit: 0.05) {
            _ = store.probableDuplicates()
            for _ in 0..<10 {
                _ = store.probableDuplicates()
                _ = store.conflictIPs
                _ = store.events(for: key)
            }
        }
    }

    suite.add("Charge : Carte du réseau, recherche, sites et rapport") {
        var random = LoadRandom(seed: 36)
        let sites = (0..<4).map { LoadFixtures.site($0, devices: 5_000, random: &random) }
        let stores = sites.map { site -> InventoryStore in
            var store = InventoryStore()
            store.merge(site.devices, at: now, coverage: .ranges(site.ranges))
            return store
        }
        let devices = sites[0].devices

        // Carte du réseau.
        let scoped = try timed("Appareils du dernier scan (TopoScope, plages dont un /16)", limit: 0.3) {
            TopoScope.lastScan(devices, since: now.addingTimeInterval(-7_200), ranges: sites[0].ranges)
        }
        try expectEqual(scoped.count, devices.count, "tous du dernier scan")
        let graph = try timed("Graphe de la Carte (TopoGraph.build, 5 000 appareils)", limit: 0.5) {
            TopoGraph.build(devices: devices, gateway: nil, conflictIPs: stores[0].conflictIPs)
        }
        try expect(graph.nodes.count > 10, "nœuds de la carte")
        let layout = try timed("Disposition de la Carte (TopoGraph.layout)", limit: 0.3) { graph.layout() }
        try expectEqual(layout.positions.count, graph.nodes.count, "chaque nœud placé")

        // Lecture combinée de 4 sites (20 000 lignes) et recherche multiple.
        let inventories = zip(sites, stores).map { SiteInventory(key: $0.key, name: $0.name, store: $1) }
        let rows = try timed("Lecture combinée de 4 sites (SiteScope.records, 20 000 lignes)", limit: 0.4) {
            SiteScope.records(inventories)
        }
        try expectEqual(rows.count, stores.reduce(0) { $0 + $1.count }, "une ligne par fiche et par site")
        let free = try timed("Recherche d’un mot sur 20 000 lignes (« dell »)", limit: 0.6) {
            SearchQuery("dell", schema: .inventaire).filter(rows)
        }
        try expect(!free.isEmpty, "mot trouvé")
        let again = try timed("Recherche d’un autre mot sur les mêmes lignes (texte gardé)", limit: 0.2) {
            SearchQuery("brother", schema: .inventaire).filter(rows)
        }
        try expect(!again.isEmpty, "autre mot trouvé")
        let multi = try timed("Recherche multiple sur 20 000 lignes (fab:, etat:, ip:, -tag:)", limit: 0.3) {
            SearchQuery("fab:apple etat:\"en ligne\" ip:10.100. -tag:compta", schema: .inventaire).filter(rows)
        }
        try expect(!multi.isEmpty && multi.allSatisfy { $0.record.ip.description.hasPrefix("10.100.") }, "critères appliqués")
        let site = try timed("Recherche site: sur 20 000 lignes", limit: 0.3) {
            SearchQuery("site:laval", schema: .inventaire).filter(rows)
        }
        try expectEqual(site.count, stores[1].count, "lignes du site Laval seulement")

        // Choix d'un site parmi 20.
        let all = LoadFixtures.siteNames.enumerated().map { (key: "site-\($0.offset + 1)", name: $0.element) }
        try timed("Choix d’un site parmi 20 (1 000 fois : analyse, résolution, bascule)", limit: 0.3) {
            for n in 0..<1_000 {
                let wanted = SiteSelection.parse(all[n % 20].name, sites: all) ?? .active
                let keys = wanted.resolve(activeKey: "site-1", available: all.map(\.key))
                _ = SiteSelection.sites(keys).toggling(all[(n + 3) % 20].key, activeKey: "site-1", available: all.map(\.key))
            }
        }

        // Rapport multisite (4 sites).
        let inputs = zip(sites, stores).map { site, store in
            ReportSiteInput(name: site.name, input: ReportInput(devices: site.devices, records: store.sortedRecords,
                                                                ranges: site.rangeTexts.map { ReportRange(label: "Plage", text: $0) },
                                                                scanDate: now, now: now))
        }
        let document = try timed("Rapport multisite (4 sites, 20 000 appareils)", limit: 1.0) {
            ReportBuilder.buildMultisite(config: ReportConfig(template: .audit, client: "Groupe Charge", technician: "Essai",
                                                              date: "2026-11-04"), sites: inputs)
        }
        try expect(document.sections.count > 4 * 3, "sections de chaque site")
    }

    suite.add("Charge : décodage des réponses d’une FortiGate (10 FortiSwitch, 30 FortiAP, 5 000 appareils)") {
        var random = LoadRandom(seed: 36)
        let site = LoadFixtures.site(0, devices: 5_000, random: &random)
        let responses = LoadFixtures.fortiResponses(for: site)
        let reader = FortiGateReader(transport: FortiFakeTransport(responses))
        let report = try await timedAsync("Lecture FortiGate (switchs, ARP, DHCP, appareils détectés)", limit: 1.0) {
            try await reader.read(now: now)
        }
        try expectEqual(report.switches.count, 10, "10 FortiSwitch")
        try expect(report.arp.count > 4_000, "table ARP complète")
        let wifi = try await timedAsync("Lecture Wi-Fi FortiGate (30 FortiAP et leurs clients)", limit: 0.4) {
            try await reader.readWifi(now: now)
        }
        try expectEqual(wifi.aps.count, 30, "30 FortiAP")
        let applied = try timed("Emplacement des 5 000 appareils par la FortiGate", limit: 0.6) {
            FortiLocate.apply(report, to: site.devices.map { var d = $0; d.switchName = nil; d.switchPort = nil; return d }, snmp: [])
        }
        try expect(applied.located > 3_000, "appareils placés sur leur port")
    }

    suite.add("Charge : changement de site (mise de côté et rechargement)") {
        var random = LoadRandom(seed: 36)
        let sites = (0..<2).map { LoadFixtures.site($0, devices: 5_000, random: &random) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = SiteFiles(base: folder)
        var stores: [InventoryStore] = []
        for site in sites {
            let built = LoadFixtures.inventory(for: site, scans: 2)
            try files.saveInventory(built.store, for: site.key)
            files.saveResults(SiteResults(devices: built.lastScan, lastScanRanges: site.rangeTexts, finishedAt: now), for: site.key)
            stores.append(built.store)
        }
        var shelf = SiteResultsShelf(files: files)
        try timed("Changement de site (résultats et inventaire, 5 000 + 5 000)", limit: 1.5) {
            // Site quitté : résultats de côté et inventaire enregistré ; site choisi : relu.
            shelf.shelve(SiteResults(devices: sites[0].devices, finishedAt: now), for: sites[0].key)
            try files.saveInventory(stores[0], for: sites[0].key)
            let other = try files.loadInventory(for: sites[1].key)
            let results = shelf.take(sites[1].key)
            try expectEqual(other.count, stores[1].count, "inventaire du site choisi")
            try expect(results.devices.count >= sites[1].devices.count, "résultats du site choisi")
        }
    }

    // MARK: Gros essais (NETSCOPE_CHARGE=1)

    if heavy {
        suite.add("Charge complète : 20 sites, 2 000 à 5 000 appareils, historique") {
            let sites = LoadFixtures.sites(20)
            let total = sites.reduce(0) { $0 + $1.devices.count }
            print("       \(sites.count) sites, \(total) appareils, \(sites.reduce(0) { $0 + $1.ranges.count }) plages")
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = SiteFiles(base: folder)
            var built: [(store: InventoryStore, lastScan: [Device])] = []
            try timed("Inventaires des 20 sites (6 scans fusionnés chacun)", limit: 40) {
                built = sites.map { LoadFixtures.inventory(for: $0, scans: 6) }
            }
            try timed("Écriture des 20 inventaires", limit: 8) {
                for (site, item) in zip(sites, built) { try files.saveInventory(item.store, for: site.key) }
            }
            let biggest = zip(sites, built).max { $0.1.store.count < $1.1.store.count }!
            try timed("Écriture du plus gros inventaire (\(biggest.1.store.count) fiches)", limit: 1) {
                try files.saveInventory(biggest.1.store, for: biggest.0.key)
            }
            var loaded: [InventoryStore] = []
            try timed("Lecture des 20 inventaires, l’un après l’autre", limit: 8) {
                loaded = try sites.map { try files.loadInventory(for: $0.key) }
            }
            let parallel = try timed("Lecture des 20 inventaires en parallèle (« Tous les sites »)", limit: 3) {
                InventoryStore.loadAll(sites.map { files.inventoryURL(for: $0.key) })
            }
            try expectEqual(try parallel.map { try $0.get().count }, loaded.map(\.count), "lecture parallèle identique")
            let inventories = zip(sites, loaded).map { SiteInventory(key: $0.key, name: $0.name, store: $1) }
            let rows = try timed("Lecture combinée de 20 sites (SiteScope.records)", limit: 1.5) { SiteScope.records(inventories) }
            try timed("Recherche multiple sur \(rows.count) lignes", limit: 1) {
                _ = SearchQuery("fab:dell etat:\"hors ligne\" -vlan:20", schema: .inventaire).filter(rows)
            }
            try timed("Alertes de 20 sites (SiteScope.alerts)", limit: 0.5) { _ = SiteScope.alerts(inventories, since: .distantPast) }
            let inputs = zip(sites, built).map { site, item in
                ReportSiteInput(name: site.name, input: ReportInput(devices: item.lastScan, records: item.store.sortedRecords,
                                                                    scanDate: LoadFixtures.now, now: LoadFixtures.now))
            }
            try timed("Rapport multisite (20 sites)", limit: 4) {
                _ = ReportBuilder.buildMultisite(config: ReportConfig(template: .audit, client: "Groupe Charge", date: "2026-11-04"), sites: inputs)
            }
            for site in sites.prefix(3) {
                let reader = FortiGateReader(transport: FortiFakeTransport(LoadFixtures.fortiResponses(for: site)))
                _ = try await timedAsync("Lecture FortiGate de « \(site.name) » (\(site.devices.count) appareils)", limit: 1.5) {
                    try await reader.read(now: LoadFixtures.now)
                }
            }
            // Historique long : 40 scans d'un site de 5 000 appareils.
            var random = LoadRandom(seed: 99)
            let big = LoadFixtures.site(0, devices: 5_000, random: &random)
            var long = InventoryStore()
            var devices = big.devices
            try timed("40 scans successifs d’un site de 5 000 appareils", limit: 30) {
                for step in 0..<40 {
                    if step > 0 { devices = LoadFixtures.nextScan(devices, step: step, random: &random) }
                    long.merge(devices, at: LoadFixtures.now.addingTimeInterval(Double(step) * 3_600), coverage: .ranges(big.ranges))
                }
            }
            try expect(long.snapshots.count >= 2 && long.snapshots.reduce(0) { $0 + $1.entries.count } <= InventoryStore.maxSnapshotEntries,
                       "instantanés plafonnés (\(long.snapshots.count))")
            let url = folder.appendingPathComponent("long.json")
            try timed("Écriture d’un inventaire à long historique (\(long.snapshots.count) instantanés)", limit: 2) { try long.save(to: url) }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            print("       inventaire à long historique : \(size / 1_000_000) Mo, \(long.events.count) événements")
            try timed("Lecture d’un inventaire à long historique", limit: 2) { _ = try InventoryStore.load(from: url) }
        }
    }

    suite.add("Charge : tableau des temps") {
        LoadTimings.shared.printTable(title: heavy ? "Essais de charge (rapides et complets)" : "Essais de charge rapides (NETSCOPE_CHARGE=1 pour les gros)")
    }
}
