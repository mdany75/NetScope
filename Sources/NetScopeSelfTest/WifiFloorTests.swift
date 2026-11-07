import Foundation
@testable import NetScopeCore

// Note 94 : relevé Wi-Fi sur plan. Étages et mesures fixes ; aucun appel à CoreWLAN ni au réseau.

private func spot(_ x: Double, _ y: Double, _ rssi: Int, ap: String = "AP-A", channel: Int = 36, noise: Int = -92,
                  neighbors: [WifiFloorNeighbor]? = nil) -> WifiFloorMeasure {
    WifiFloorMeasure(point: WifiPlanPoint(x: x, y: y), time: Date(timeIntervalSince1970: 1_800_000_000), ssid: "Bureau",
                     bssid: "70:4C:A5:00:00:0\(ap.count % 10)", apName: ap, band: .ghz5, channel: channel, widthMHz: 80, rssi: rssi,
                     noise: noise, linkRateMbps: 576, neighbors: neighbors)
}

private extension Optional {
    func floorUnwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}

/// Plan de 1 000 × 500 px, échelle : 100 px = 4 m (40 m × 20 m).
private func floor(_ measures: [WifiFloorMeasure], aps: [WifiFloorAP] = []) -> WifiFloor {
    WifiFloor(name: "Rez-de-chaussée", image: Data([0xFF]), imageWidth: 1000, imageHeight: 500,
              scale: WifiFloorScale(a: WifiPlanPoint(x: 0, y: 0.5), b: WifiPlanPoint(x: 0.1, y: 0.5), metres: 4),
              measures: measures, aps: aps)
}

func registerWifiFloorTests(_ suite: TestSuite) {
    suite.add("Relevé sur plan : échelle et distances") {
        let f = floor([])
        try expectEqual(f.metresPerPixel, 0.04, "100 px = 4 m")
        try expectEqual(f.widthMetres, 40, "40 m de large")
        try expectEqual(f.metres(WifiPlanPoint(x: 0, y: 0), WifiPlanPoint(x: 0.3, y: 0.8)), 20, "3-4-5 : 12 m et 16 m → 20 m")
        try expect(WifiFloorScale(a: WifiPlanPoint(x: 0.2, y: 0.2), b: WifiPlanPoint(x: 0.2, y: 0.2), metres: 5)
            .metresPerPixel(width: 100, height: 100) == nil, "points confondus : pas d’échelle")
        var unscaled = f
        unscaled.scale = nil
        try expectEqual(unscaled.effectiveMetresPerPixel, WifiFloor.assumedWidthMetres / 1000, "sans échelle : largeur supposée")
        try expectEqual(WifiPlanPoint(x: 1.4, y: -0.2), WifiPlanPoint(x: 1, y: 0), "point ramené dans le plan")
        try expectEqual(WifiFloorPlans.floorName("  ", index: 3), "Étage 3", "nom par défaut")
    }

    suite.add("Relevé sur plan : interpolation et portée") {
        let f = floor([spot(0.1, 0.5, -50), spot(0.3, 0.5, -70)])
        let samples = f.measures.map { ($0.point, Double($0.rssi)) }
        let middle = try WifiHeatmap.interpolate(samples, at: WifiPlanPoint(x: 0.2, y: 0.5), floor: f).floorUnwrap("milieu")
        try expectEqual(middle, -60, "à mi-chemin : la moyenne")
        let near = try WifiHeatmap.interpolate(samples, at: WifiPlanPoint(x: 0.12, y: 0.5), floor: f).floorUnwrap("près")
        try expect(near > -55, "près de la première mesure : proche de −50 (\(near))")
        try expectEqual(WifiHeatmap.interpolate(samples, at: WifiPlanPoint(x: 0.1, y: 0.5), floor: f), -50, "sur la mesure : sa valeur")
        try expect(WifiHeatmap.interpolate(samples, at: WifiPlanPoint(x: 0.9, y: 0.5), floor: f) == nil, "à 24 m : hors de portée")
        let grid = WifiHeatmap.grid(f, metric: .signal, columns: 40)
        try expectEqual(grid.rows, 20, "cases carrées : 40 × 20")
        try expect(grid.values.contains { $0 == nil } && grid.values.contains { $0 != nil }, "cases couvertes et vides")
        let aps = WifiHeatmap.grid(floor([spot(0.1, 0.5, -50, ap: "AP-A"), spot(0.3, 0.5, -55, ap: "AP-B")]), metric: .borne, columns: 40)
        try expectEqual(aps.categories[aps.index(column: 3, row: 10)], "AP-A", "borne la plus proche (gauche)")
        try expectEqual(aps.categories[aps.index(column: 12, row: 10)], "AP-B", "borne la plus proche (droite)")
        try expectEqual(WifiHeatmap.categories(aps), ["AP-A", "AP-B"], "légende des bornes")
        try expectEqual(WifiHeatMetric.signal.level(-58), 0, "excellent")
        try expectEqual(WifiHeatMetric.signal.level(-80), 3, "zone morte")
        try expectEqual(WifiHeatMetric.snr.value(spot(0, 0, -60, noise: -95)), 35, "SNR")
    }

    suite.add("Relevé sur plan : zones mortes et borne suggérée") {
        let good = (0..<5).map { spot(0.05 + Double($0) * 0.05, 0.5, -52) }
        let dead = [spot(0.85, 0.3, -82), spot(0.9, 0.5, -84), spot(0.85, 0.7, -80)]
        let f = floor(good + dead, aps: [WifiFloorAP(name: "AP-A", point: WifiPlanPoint(x: 0.15, y: 0.5))])
        let analysis = WifiHeatmap.analysis(f, columns: 40)
        try expectEqual(analysis.measureCount, 8, "mesures")
        try expectEqual(analysis.deadZones.count, 1, "une zone morte d’un seul tenant")
        let zone = try analysis.deadZones.first.floorUnwrap("zone")
        try expect(zone.center.x > 0.75, "zone morte à droite (\(zone.center.x))")
        try expect(zone.areaSquareMetres > 20, "surface en m² (\(zone.areaSquareMetres))")
        let suggestion = try analysis.suggestion.floorUnwrap("suggestion")
        try expect(suggestion.x > 0.7, "borne suggérée dans la zone faible (\(suggestion.x))")
        try expect(analysis.goodPercent > 0 && analysis.deadPercent > 0, "parts de surface")
        try expectEqual(analysis.medianRSSI, -52, "signal médian")
        let fine = WifiHeatmap.analysis(floor(good), columns: 40)
        try expect(fine.deadZones.isEmpty && fine.suggestion == nil, "bonne couverture : ni zone morte ni suggestion")
        // Plan de 2 m × 1 m tout entier faible : 2 m², trop petit pour suggérer une borne.
        var tiny = floor([spot(0.5, 0.5, -70)])
        tiny.scale = WifiFloorScale(a: WifiPlanPoint(x: 0, y: 0.5), b: WifiPlanPoint(x: 1, y: 0.5), metres: 2)
        let tinyAnalysis = WifiHeatmap.analysis(tiny, columns: 40)
        try expect(tinyAnalysis.coveredCells > WifiHeatmap.suggestionMinimumCells, "cases faibles nombreuses")
        try expect(tinyAnalysis.suggestion == nil, "zone faible de 2 m² : pas de borne suggérée")
        try expect(WifiHeatmap.summary(fine).contains("aucune zone morte"), "bilan en mots")
        try expectEqual(WifiHeatmap.summary(WifiHeatmap.analysis(floor([]))), "Aucune mesure sur cet étage.", "étage vide")
    }

    suite.add("Relevé sur plan : chevauchement de canaux") {
        try expect(WifiHeatmap.overlaps(band: .ghz24, 1, width: 20, 3, width: 20), "2,4 GHz : 1 et 3 se recouvrent")
        try expect(!WifiHeatmap.overlaps(band: .ghz24, 1, width: 20, 6, width: 20), "2,4 GHz : 1 et 6 non")
        try expect(WifiHeatmap.overlaps(band: .ghz5, 36, width: 80, 44, width: 80), "5 GHz : 36 et 44 à 80 MHz, même bloc")
        try expect(!WifiHeatmap.overlaps(band: .ghz5, 36, width: 20, 44, width: 20), "5 GHz : 36 et 44 à 20 MHz, non")
        let neighbors = [
            WifiFloorNeighbor(ssid: "Voisin", bssid: "A4:2B:B0:11:22:33", band: .ghz5, channel: 40, widthMHz: 40, rssi: -65),
            WifiFloorNeighbor(ssid: "Loin", bssid: "A4:2B:B0:11:22:34", band: .ghz5, channel: 36, widthMHz: 20, rssi: -86),
            WifiFloorNeighbor(ssid: "Ailleurs", bssid: "A4:2B:B0:11:22:35", band: .ghz5, channel: 149, widthMHz: 80, rssi: -60),
        ]
        let f = floor([spot(0.5, 0.5, -55, neighbors: neighbors), spot(0.2, 0.5, -55)])
        let overlaps = WifiHeatmap.channelOverlaps(f)
        try expectEqual(overlaps.count, 1, "un endroit")
        try expectEqual(overlaps.first?.others, ["Voisin"], "voisine forte sur un canal recouvert seulement")
        try expectEqual(overlaps.first?.strongestRSSI, -65, "signal de la voisine")
        // Borne placée qui a appris le BSSID de la voisine : nommée dans le chevauchement et les mesures.
        var named = f
        named.aps = [WifiFloorAP(name: "AP-HALL", point: WifiPlanPoint(x: 0.6, y: 0.5))]
        try expect(named.learn(bssid: "a4:2b:b0:11:22:33", apName: "AP-HALL"), "BSSID appris par la borne placée")
        try expect(!named.learn(bssid: "A4:2B:B0:11:22:33", apName: "AP-INCONNUE"), "aucune borne de ce nom")
        try expectEqual(named.aps[0].bssids, ["A4:2B:B0:11:22:33"], "BSSID en majuscules, une fois")
        try expectEqual(WifiHeatmap.channelOverlaps(named).first?.others, ["AP-HALL"], "voisine nommée par la borne placée")
        try expectEqual(named.apName(bssid: "A4:2B:B0:11:22:33"), "AP-HALL", "mesure nommée par son BSSID")
        try expectEqual(named.apName(bssid: "00:11:22:33:44:55"), nil, "BSSID inconnu")
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"AP-1","point":{"x":0.5,"y":0.5}}"#.utf8)
        try expectEqual(try JSONDecoder().decode(WifiFloorAP.self, from: legacy).bssids, [], "ancien fichier : aucun BSSID")
    }

    suite.add("Relevé sur plan : fichier du site et rapport") {
        var plans = WifiFloorPlans(floors: [floor([spot(0.1, 0.5, -60)])])
        let id = plans.floors[0].id
        plans.add(spot(0.2, 0.5, -64), to: id)
        let data = try plans.encoded().floorUnwrap("encodé")
        let decoded = try WifiFloorPlans.decode(data).floorUnwrap("relu")
        var withoutImages = plans
        for i in withoutImages.floors.indices { withoutImages.floors[i].image = Data() }
        try expectEqual(decoded, withoutImages, "aller-retour JSON (images à part, note 95)")
        try expect(!String(decoding: data, as: UTF8.self).contains("\"image\""), "image hors du JSON")
        var future = plans
        future.version = WifiFloorPlans.currentVersion + 1
        try expect(WifiFloorPlans.decode(future.encoded()!) == nil, "version future : non relue")
        let files = SiteFiles(base: URL(fileURLWithPath: "/tmp/netscope-test"))
        try expect(WifiFloorPlans.url(in: files, siteKey: "abc").path.hasSuffix("sites/abc/wifi-plans.json"), "fichier du site")
        try expect(ConfigSyncPolicy.siteFiles.contains(WifiFloorPlans.fileName), "synchronisé avec le site (note 86)")
        let report = ReportBuilder.floorSurveyBlocks([ReportFloorSurveyFloor.make(decoded.floors[0], image: nil)])
        try expect(report.count >= 3, "texte, bilan et indicateurs")
        if case .note(let text) = ReportBuilder.floorSurveyBlocks([]).first {
            try expect(text.contains("Relevé sur plan"), "section vide : comment faire")
        } else {
            try expect(false, "section vide : une note")
        }
        try expect(ReportSectionKind.documentOrder.contains(.releveWifi), "section dans l’ordre du document")
    }

    suite.add("Relevé sur plan : images à part, ancien fichier migré (note 95)") {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("netscope-plans-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: base) }
        let siteID = UUID().uuidString
        let folder = base.appendingPathComponent("sites/\(siteID)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var plans = WifiFloorPlans(floors: [floor([spot(0.1, 0.5, -60)]), floor([])])
        plans.floors[1].image = Data([0xFF, 0xD8, 0x02])
        // Ancien fichier (0.37.0) : version 1, images dans le JSON.
        var legacy = try JSONSerialization.jsonObject(with: plans.encoded().floorUnwrap("encodé")) as? [String: Any] ?? [:]
        legacy["version"] = 1
        var floors = legacy["floors"] as? [[String: Any]] ?? []
        for i in floors.indices { floors[i]["image"] = plans.floors[i].image.base64EncodedString() }
        legacy["floors"] = floors
        try JSONSerialization.data(withJSONObject: legacy).write(to: folder.appendingPathComponent(WifiFloorPlans.fileName))
        let old = try WifiFloorPlans.read(folder: folder).floorUnwrap("ancien fichier relu")
        try expect(old.needsMigration, "ancien fichier : à migrer")
        try expectEqual(old.plans.floors.map(\.image), plans.floors.map(\.image), "images relues du JSON")
        try old.plans.write(to: folder)
        for f in plans.floors {
            let url = folder.appendingPathComponent(WifiFloorPlans.imagePath(f.id))
            try expectEqual(try Data(contentsOf: url), f.image, "image écrite à part")
        }
        let json = try Data(contentsOf: folder.appendingPathComponent(WifiFloorPlans.fileName))
        try expect(!String(decoding: json, as: UTF8.self).contains("\"image\""), "JSON migré sans image")
        let migrated = try WifiFloorPlans.read(folder: folder).floorUnwrap("relu après migration")
        try expect(!migrated.needsMigration && migrated.missingImages.isEmpty, "migration faite, images trouvées")
        try expectEqual(migrated.plans.floors.map(\.image), plans.floors.map(\.image), "images relues des fichiers")
        // Une mesure ne réécrit pas l'image ; un étage supprimé perd la sienne.
        let imageURL = folder.appendingPathComponent(WifiFloorPlans.imagePath(plans.floors[0].id))
        let before = try manager.attributesOfItem(atPath: imageURL.path)[.modificationDate] as? Date
        var next = migrated.plans
        next.add(spot(0.3, 0.5, -70), to: next.floors[0].id)
        let removed = next.floors.remove(at: 1)
        try next.write(to: folder)
        try expectEqual(try manager.attributesOfItem(atPath: imageURL.path)[.modificationDate] as? Date, before, "image inchangée non réécrite")
        try expect(!manager.fileExists(atPath: folder.appendingPathComponent(WifiFloorPlans.imagePath(removed.id)).path), "image de l’étage supprimé retirée")
        // Image pas encore reçue d'un autre Mac : signalée, jamais effacée.
        try manager.removeItem(at: imageURL)
        let partial = try WifiFloorPlans.read(folder: folder).floorUnwrap("relu sans image")
        try expectEqual(partial.missingImages, [next.floors[0].id], "image manquante signalée")
        // Sauvegardes et synchronisation : l'image est un fichier de données du site.
        let path = "sites/\(siteID)/" + WifiFloorPlans.imagePath(next.floors[0].id)
        try expect(BackupEngine.isSafeRelativePath(path), "image sauvegardée et restaurable")
        try expect(!BackupEngine.isSafeRelativePath("sites/\(siteID)/wifi-plans/oui.jpg"), "autre image refusée")
        try expect(!BackupEngine.isSafeRelativePath("oui.tsv"), "autre fichier refusé")
        try next.write(to: folder)
        try expect(BackupEngine.dataFiles(in: base).files.contains(path), "image recensée")
    }
}
