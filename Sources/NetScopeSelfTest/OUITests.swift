import Foundation
import NetScopeCore

// Base des fabricants : registre IEEE (MA-L, MA-M, MA-S), nettoyage des noms, chargement.
// Aucun accès réseau : les fichiers CSV sont fabriqués ici, la base réelle est lue dans le dépôt.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func registerOUITests(_ suite: TestSuite) {
    suite.add("OUI : plus long préfixe (MA-S, puis MA-M, puis MA-L)") {
        let db = OUIDatabase(entries: [
            "8C:1F:64": "Parent MA-L",
            "8C1F64A": "Bloc MA-M",
            "8C1F64AFA": "Bloc MA-S",
        ])
        try expectEqual(db.count, 3, "trois préfixes de longueurs différentes")
        try expectEqual(db.vendor(for: MACAddress("8c:1f:64:af:a1:23")!), "Bloc MA-S", "36 bits d'abord")
        try expectEqual(db.vendor(for: MACAddress("8c:1f:64:a0:00:01")!), "Bloc MA-M", "puis 28 bits")
        try expectEqual(db.vendor(for: MACAddress("8c:1f:64:10:00:01")!), "Parent MA-L", "puis 24 bits")
        try expectEqual(db.vendor(for: MACAddress("8c:1f:65:af:a1:23")!), nil, "préfixe voisin absent")
    }

    suite.add("OUI : nettoyage des noms (mêmes exemples que scripts/make-oui.py)") {
        let url = repositoryRoot.appendingPathComponent("scripts/oui-name-examples.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var checked = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try expectEqual(parts.count, 2, "ligne d'exemple : \(line)")
            try expectEqual(OUIRegistry.cleanName(parts[0]) ?? "", parts[1], parts[0])
            checked += 1
        }
        try expect(checked >= 10, "au moins dix exemples (\(checked))")
        try expectEqual(OUIRegistry.cleanName("HUAWEI TECHNOLOGIES CO.,LTD"), "Huawei", "alias")
        try expectEqual(OUIRegistry.cleanName("QUERCUS TECHNOLOGIES, S.L."), "Quercus Technologies", "casse et suffixe")
        try expectEqual(OUIRegistry.cleanName("  Private "), nil, "« Private » ignoré")
        try expectEqual(OUIRegistry.cleanName(""), nil, "nom vide ignoré")
    }

    suite.add("OUI : lecture CSV (guillemets, virgules, retours à la ligne)") {
        let csv = "Registry,Assignment,Organization Name,Organization Address\r\n"
            + "MA-L,286FB9,\"Nokia Shanghai Bell Co., Ltd.\",\"No.388 Ning Qiao Road,Jin Qiao\"\r\n"
            + "MA-L,00000C,\"Cisco Systems, Inc\",\"170 West Tasman Dr.\nSan Jose\"\n"
            + "MA-L,AABBCC,\"Nom \"\"cité\"\", Inc.\",\n"
            + "MA-M,741AE09,Private,\n"
        let rows = OUIRegistry.parseCSV(Data(csv.utf8))
        try expectEqual(rows.count, 5, "cinq lignes")
        try expectEqual(rows[1], ["MA-L", "286FB9", "Nokia Shanghai Bell Co., Ltd.", "No.388 Ning Qiao Road,Jin Qiao"], "virgules entre guillemets")
        try expectEqual(rows[2][3], "170 West Tasman Dr.\nSan Jose", "retour à la ligne entre guillemets")
        try expectEqual(rows[3][2], "Nom \"cité\", Inc.", "guillemets doublés")
        try expectEqual(rows[4], ["MA-M", "741AE09", "Private", ""], "champ final vide")

        let entries = try OUIRegistry.entries(fromCSV: Data(csv.utf8), digits: 6, fileName: "oui.csv")
        try expectEqual(entries.map(\.0), ["286FB9", "00000C", "AABBCC"], "préfixes de 6 chiffres seulement")
        try expectEqual(entries.map(\.1), ["Nokia", "Cisco", "Nom \"cité\""], "noms courts")
        try expectThrows(OUIRegistry.Failure.unexpectedHeader("oui.csv"), "page d'erreur refusée") {
            _ = try OUIRegistry.entries(fromCSV: Data("<html>erreur</html>".utf8), digits: 6, fileName: "oui.csv")
        }
        try expectThrows(OUIRegistry.Failure.tooFewRows("oui.csv", 3), "registre tronqué refusé") {
            _ = try OUIRegistry.entries(fromCSV: Data(csv.utf8), digits: 6, fileName: "oui.csv", minimumRows: 20_000)
        }
    }

    suite.add("OUI : conversion et installation d'un registre (dossier temporaire)") {
        let header = "Registry,Assignment,Organization Name,Organization Address\n"
        var oui = header
        for index in 0..<20_100 { oui += "MA-L,\(String(format: "%06lX", 0x100000 + index)),\"Fabricant \(index), Inc.\",Adresse\n" }
        oui += "MA-L,3C22FB,\"Apple, Inc.\",1 Infinite Loop\n"
        var mam = header
        for index in 0..<1_000 { mam += "MA-M,\(String(format: "%07lX", 0xA000000 + index)),FABRICANT M\(index) LTD,\n" }
        var oui36 = header
        for index in 0..<1_000 { oui36 += "MA-S,\(String(format: "%09lX", 0x8C1F64000 + index)),\"Bloc \(index) GmbH\",\n" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-oui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("NetScope/oui.tsv")
        let updater = OUIUpdater(destination: destination)
        let date = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let source = try updater.install(csv: ["oui.csv": Data(oui.utf8), "mam.csv": Data(mam.utf8), "oui36.csv": Data(oui36.utf8)], date: date)
        try expectEqual(source.count, 22_101, "préfixes convertis")
        try expectEqual(source.date, "2026-11-03", "date de l'en-tête")
        let db = try OUIDatabase(contentsOf: destination, overlayBuiltIn: false)
        try expectEqual(db.count, 22_101, "base relue")
        try expectEqual(db.vendor(for: MACAddress("3c:22:fb:01:02:03")!), "Apple", "MA-L")
        try expectEqual(db.vendor(for: MACAddress("a0:00:00:51:02:03")!), "Fabricant M5", "MA-M remis en casse normale")
        try expectEqual(db.vendor(for: MACAddress("8c:1f:64:00:a1:23")!), "Bloc 10", "MA-S")
        try expectEqual(db.source.description, "IEEE, 22\u{202F}101 préfixes, 2026-11-03", "description de la source")
        let text = try String(contentsOf: destination, encoding: .utf8)
        try expect(text.hasPrefix("# Registre IEEE MA-L/MA-M/MA-S, converti le 2026-11-03\n"), "en-tête de commentaire")

        try expectThrows(OUIUpdater.Failure.registry("oui.csv ne compte que 1 préfixes : registre incomplet."), "registre tronqué refusé") {
            _ = try updater.install(csv: ["oui.csv": Data((header + "MA-L,3C22FB,Apple,\n").utf8),
                                          "mam.csv": Data(mam.utf8), "oui36.csv": Data(oui36.utf8)])
        }
        try expectEqual(try OUIDatabase(contentsOf: destination).count >= 22_101, true, "l'ancienne base reste en place")
    }

    suite.add("OUI : base réelle Resources/oui.tsv (plus de 50 000 préfixes)") {
        let url = OUIDatabase.repositoryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw TestSkipped(reason: "Resources/oui.tsv absent") }
        let ieee = try OUIDatabase(contentsOf: url, overlayBuiltIn: false)
        try expect(ieee.count > 50_000, "plus de 50 000 préfixes (\(ieee.count))")
        try expect(ieee.source.date != nil, "date de conversion dans l'en-tête")
        // Préfixes connus de la petite table : l'IEEE seul donne déjà les mêmes noms courts.
        let cases: [(String, String)] = [
            ("3c:22:fb:7e:05:b1", "Apple"), ("f0:18:98:00:00:01", "Apple"), ("00:00:0c:12:34:56", "Cisco"),
            ("58:ac:78:00:00:01", "Cisco"), ("94:dd:f8:18:15:7d", "Brother"), ("00:80:77:00:00:01", "Brother"),
            ("04:d5:90:3a:7b:11", "Fortinet"), ("00:09:0f:00:00:01", "Fortinet"), ("b0:7b:25:44:a1:6c", "Dell"),
            ("bc:ad:28:6f:01:5a", "Hikvision"), ("00:11:32:01:02:03", "Synology"), ("24:0a:c4:00:11:22", "Espressif"),
        ]
        for (text, vendor) in cases {
            try expectEqual(ieee.vendor(for: MACAddress(text)!), vendor, text)
        }
        try expectEqual(ieee.vendor(for: MACAddress("8c:1f:64:af:a1:23")!), "Data Electronic Devices", "bloc MA-S réel")
        try expectEqual(ieee.vendor(for: MACAddress("c8:5c:e2:70:00:01")!), "Synergy Systems and Solutions", "bloc MA-M réel")

        let merged = try OUIDatabase(contentsOf: url)
        try expectEqual(merged.vendor(for: MACAddress("88:3a:30:5d:e1:40")!), "HPE Aruba", "la petite table prime sur 24 bits")
        try expectEqual(merged.vendor(for: MACAddress("8c:1f:64:af:a1:23")!), "Data Electronic Devices", "MA-S avant la petite table")
        try expectEqual(merged.label(for: MACAddress("3a:1f:c7:02:9b:e4")!), OUIDatabase.randomizedLabel, "adresse aléatoire")
        try expectEqual(merged.label(for: MACAddress("02:60:8c:00:00:01")!), OUIDatabase.randomizedLabel,
                        "préfixe IEEE ancien au bit local : adresse aléatoire")
        try expectEqual(merged.label(for: MACAddress("52:54:00:12:34:56")!), "QEMU / KVM", "préfixe local de la petite table")
    }

    suite.add("OUI : temps de chargement de la base réelle (< 150 ms)") {
        let url = OUIDatabase.repositoryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw TestSkipped(reason: "Resources/oui.tsv absent") }
        _ = try OUIDatabase(contentsOf: url) // fichier mis en cache par le système
        var best = Double.infinity
        var count = 0
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let db = try OUIDatabase(contentsOf: url)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            count = db.count
        }
        print(String(format: "       chargement de %d préfixes : %.1f ms", count, best))
        try expect(best < 150, String(format: "chargement en %.1f ms", best))
    }

    suite.add("OUI : base partagée chargée paresseusement, sans erreur entre fils") {
        let db = OUIDatabase.builtIn
        try expect(db.count >= 150, "base partagée chargée (\(db.count))")
        try expectEqual(db.vendor(for: MACAddress("3c:22:fb:7e:05:b1")!), "Apple", "Apple")
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { db.label(for: MACAddress("94:dd:f8:18:15:7d")!) } }
            var all: [String] = []
            for await label in group { all.append(label) }
            return all
        }
        try expectEqual(Set(results), ["Brother"], "lectures concurrentes")
        let custom = OUIDatabase(entries: ["AA-BB-CC": "Essai"])
        try expectEqual(custom.reload(), custom.source, "une table fournie ne se recharge pas")
        try expectEqual(custom.source.description, "Table fournie, 1 préfixes", "description d'une table fournie")
    }

    suite.add("OUI : type d'appareil d'après des mots entiers du fabricant") {
        let guess = { (vendor: String) in ScanDeviceClassifier.guess(ports: [], vendor: vendor, hostname: nil, mac: nil) }
        try expectEqual(guess("Intel"), .poste, "Intel")
        try expectEqual(guess("Intelbras"), .inconnu, "Intelbras n'est pas Intel")
        try expectEqual(guess("Shenzhen MiaoMing Intelligent"), .inconnu, "« Intelligent » n'est pas Intel")
        try expectEqual(guess("Digiboard Eletronica da Amazonia"), .inconnu, "« Amazonia » n'est pas Amazon")
        try expectEqual(guess("Blink by Amazon"), .iot, "Amazon")
        try expectEqual(guess("Stereotaxis"), .inconnu, "« Stereotaxis » n'est pas Axis")
        try expectEqual(guess("HPE Aruba"), .routeur, "Aruba")
        try expectEqual(guess("TP-Link"), .routeur, "TP-Link")
    }

    suite.add("OUI : conversion Swift identique à scripts/make-oui.py (NETSCOPE_IEEE_CSV_DIR)") {
        guard let folder = ProcessInfo.processInfo.environment["NETSCOPE_IEEE_CSV_DIR"] else {
            throw TestSkipped(reason: "NETSCOPE_IEEE_CSV_DIR non défini (dossier des trois CSV du registre)")
        }
        var csv: [String: Data] = [:]
        for file in OUIRegistry.files {
            csv[file.name] = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(file.name))
        }
        let swiftText = try OUIRegistry.convert(csv).text
        let pythonText = try String(contentsOf: OUIDatabase.repositoryFileURL, encoding: .utf8)
        let swiftLines = swiftText.split(separator: "\n").dropFirst()
        let pythonLines = pythonText.split(separator: "\n").dropFirst()
        for (a, b) in zip(swiftLines, pythonLines) where a != b {
            throw TestFailure(message: "première différence — Swift : \(a) ; Python : \(b)", file: #fileID, line: #line)
        }
        try expectEqual(swiftLines.count, pythonLines.count, "même nombre de lignes")
    }
}
