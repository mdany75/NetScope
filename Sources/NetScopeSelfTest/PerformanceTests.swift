import Foundation
import NetScopeCore

// Note 36 : les accélérations ne changent rien aux résultats. Chemins rapides (MAC, IPv4, pliage
// des textes) comparés aux anciennes lectures, mémoire de l'inventaire (copies, modifications),
// écriture différée (regroupement, annulation, atomicité), plafond des instantanés, lecture en
// parallèle. Données fixes, aucun réseau ; seuls des fichiers temporaires sont écrits.

func registerPerformanceTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func device(_ ip: String, _ mac: String?, host: String? = nil, online: Bool = true, port: String? = nil, at date: Date? = nil) -> Device {
        Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), hostname: host, isOnline: online,
               switchName: port == nil ? nil : "SW-01", switchPort: port, firstSeen: date ?? now, lastSeen: date ?? now, deviceType: .poste)
    }

    suite.add("Performances : adresses MAC écrites et lues comme avant (tous les formats)") {
        var random = LoadRandom(seed: 5)
        let values: [UInt64] = [0, 0xFFFF_FFFF_FFFF, 0x0A0B_0C0D_0E0F, 0x3C22_FB7E_05B1] + (0..<500).map { _ in random.next() & 0xFFFF_FFFF_FFFF }
        for value in values {
            let mac = MACAddress(value: value)
            let pairs = mac.bytes.map { String(format: "%02x", $0) }
            try expectEqual(mac.formatted(.colon), pairs.joined(separator: ":"), "format deux-points")
            try expectEqual(mac.formatted(.upperColon), pairs.joined(separator: ":").uppercased(), "format majuscules")
            try expectEqual(mac.formatted(.hyphen), pairs.joined(separator: "-"), "format Windows")
            try expectEqual(mac.formatted(.bare), pairs.joined(), "format sans séparateur")
            let bare = pairs.joined()
            let cisco = [bare.prefix(4), bare.dropFirst(4).prefix(4), bare.suffix(4)].map(String.init).joined(separator: ".")
            try expectEqual(mac.formatted(.cisco), cisco, "format Cisco")
            try expectEqual(mac.oui, pairs.prefix(3).joined(separator: ":"), "préfixe OUI")
            try expectEqual(MACAddress(mac.formatted(.colon)), mac, "relue (minuscules)")
            try expectEqual(MACAddress(mac.formatted(.upperColon)), mac, "relue (majuscules)")
            try expectEqual(MACAddress(mac.formatted(.cisco)), mac, "relue (Cisco)")
        }
        for bad in ["aa:bb:cc:dd:ee:fg", "aa:bb:cc:dd:ee:fff", "aa:bb:cc:dd:ee:ff:00", "aa:bb:cc:dd:ee:ff:", "aabb:cc:dd:ee:ff", "", "::::::"] {
            try expect(MACAddress(bad) == nil, "refusée : \(bad)")
        }
        try expectEqual(MACAddress("0:1a:2b:3:4:5")?.formatted(), "00:1a:2b:03:04:05", "octets sans zéro (arp -a)")
        try expectEqual(MACAddress("aa:bb:cc:dd:ee:f")?.formatted(), "aa:bb:cc:dd:ee:0f", "dernier octet sans zéro")
        try expectEqual(MACAddress(" AA-BB-CC-DD-EE-FF ")?.formatted(), "aa:bb:cc:dd:ee:ff", "espaces et tirets")
    }

    suite.add("Performances : adresses IPv4 lues avec les mêmes règles strictes") {
        for value: UInt32 in [0, 1, 255, 256, 0x0A64_0001, 0xC0A8_0101, 0xFFFF_FFFF] {
            let ip = IPv4Address(value)
            try expectEqual(IPv4Address(ip.description), ip, "relue : \(ip)")
        }
        for good in ["0.0.0.0", "10.100.0.1", "192.168.1.10", "255.255.255.255", " 10.0.0.1 "] {
            try expect(IPv4Address(good) != nil, "acceptée : \(good)")
        }
        for bad in ["010.0.0.1", "10.00.0.1", "256.1.1.1", "1.2.3", "1.2.3.4.5", "1..2.3", "1.2.3.", ".1.2.3", "1.2.3.4a", "", "1.2.3.1000", "١.٢.٣.٤"] {
            try expect(IPv4Address(bad) == nil, "refusée : \(bad)")
        }
    }

    suite.add("Performances : textes pliés comme avant (ASCII, accents, mémoire)") {
        func reference(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let samples = ["Dell", "SRV-BACKUP", "10.100.2.3", "aa:bb:CC", "vlan 20", "Caméra IP", "Point d’accès", "Entrepôt Laval",
                       "ＡＢＣ", "Prise\u{00A0}E-02", "ÉTÉ", "", "MiXeD 123 !?", "Straße"]
        for text in samples {
            try expectEqual(SearchText.fold(text), reference(text), "pli de « \(text) »")
            try expectEqual(SearchText.fold(text), reference(text), "pli relu en mémoire de « \(text) »")
        }
    }

    suite.add("Performances : mémoire de l’inventaire exacte après chaque changement et pour chaque copie") {
        var store = InventoryStore()
        store.merge([device("10.0.0.5", "3C:22:FB:00:00:05", host: "poste-a"),
                     device("10.0.0.2", "3C:22:FB:00:00:02", host: "poste-b"),
                     device("10.0.0.9", nil, host: "nas")], at: now)
        let original = store
        try expectEqual(store.sortedRecords.map(\.ip.description), ["10.0.0.2", "10.0.0.5", "10.0.0.9"], "tri par IP")
        let firstKey = store.sortedRecords[0].key
        try expectEqual(store.events(for: firstKey).count, 1, "événement de détection")

        // Nouveau scan : changement d'IP et nouvel appareil.
        store.merge([device("10.0.0.3", "3C:22:FB:00:00:02", host: "poste-b"),
                     device("10.0.0.5", "3C:22:FB:00:00:05", host: "poste-a"),
                     device("10.0.0.1", "3C:22:FB:00:00:01", host: "poste-c")], at: now.addingTimeInterval(600))
        try expectEqual(store.sortedRecords.map(\.ip.description), ["10.0.0.1", "10.0.0.3", "10.0.0.5", "10.0.0.9"], "tri mis à jour")
        try expectEqual(store.events(for: firstKey).map(\.kind), [.nouveau, .changementIP], "événements mis à jour")
        try expectEqual(store.record(forIP: IPv4Address("10.0.0.3")!)?.key, firstKey, "fiche par IP mise à jour")
        try expect(store.record(forIP: IPv4Address("10.0.0.2")!) == nil, "ancienne IP libérée")
        // La copie d'avant garde ses propres résultats.
        try expectEqual(original.sortedRecords.count, 3, "copie d'avant inchangée")
        try expectEqual(original.record(forIP: IPv4Address("10.0.0.2")!)?.key, firstKey, "copie d'avant : ancienne IP")

        // Doublons : recalculés quand une fiche change.
        try expect(store.probableDuplicates().isEmpty, "aucun doublon")
        store.merge([device("10.0.0.40", "3C:22:FB:00:00:40", host: "poste-a")], at: now.addingTimeInterval(1_200))
        store.merge([device("10.0.0.5", "3C:22:FB:00:00:05", host: "poste-a", online: false)], at: now.addingTimeInterval(1_300))
        try expectEqual(store.probableDuplicates().count, 1, "doublon relevé après la fusion")

        // Lignes de l'Inventaire : texte de recherche gardé, même résultat que sans mémoire.
        let inventory = [SiteInventory(key: "a", name: "Siège", store: store)]
        let cached = SiteScope.records(inventory)
        let plain = store.sortedRecords.map { SiteScopedRecord(siteKey: "a", siteName: "Siège", record: $0) }
        try expectEqual(cached, plain, "mêmes lignes (le texte plié ne compte pas dans l'égalité)")
        for text in ["poste", "POSTE-A", "10.0.0", "3c22fb", "3c-22-fb", "vlan", "poste -nas", "\"poste-b\"", "site:siège nas", "étiquette"] {
            try expectEqual(SearchQuery(text, schema: .inventaire).filter(cached).map(\.id),
                            SearchQuery(text, schema: .inventaire).filter(plain).map(\.id), "recherche « \(text) »")
        }
        // Un mot ne chevauche pas deux colonnes.
        try expect(SearchQuery("poste-a10.0", schema: .inventaire).filter(cached).isEmpty, "pas de correspondance à cheval")
        // La ligne modifiée oublie son texte gardé.
        var row = cached[0]
        row.record.annotations.customName = "Imprimante accueil"
        try expect(SearchQuery("accueil", schema: .inventaire).matches(row), "texte recalculé après modification")
    }

    suite.add("Performances : écriture différée regroupée, annulée, atomique") {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("sites/a/inventory.json")
        var store = InventoryStore()
        store.merge([device("10.0.0.5", "3C:22:FB:00:00:05", host: "poste-a")], at: now)

        // Écriture après le délai, sans flush.
        let quick = InventoryWriter(delay: 0.05)
        quick.schedule(store, to: url)
        try expect(quick.hasPending, "en attente")
        var waited = 0
        while quick.writeCount == 0 && waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        try expectEqual(quick.writeCount, 1, "écrite après le délai")
        try expectEqual(try InventoryStore.load(from: url).count, 1, "fichier lisible")

        // Regroupement : seule la dernière version est écrite.
        let writer = InventoryWriter(delay: 60)
        for n in 0..<5 {
            store.setAnnotations(InvAnnotations(customName: "Nom \(n)"), for: store.sortedRecords[0].key, at: now)
            writer.schedule(store, to: url)
        }
        writer.flush()
        try expectEqual(writer.writeCount, 1, "une écriture pour cinq changements")
        try expectEqual(try InventoryStore.load(from: url).sortedRecords.first?.annotations.customName, "Nom 4", "dernière version")
        writer.flush()
        try expectEqual(writer.writeCount, 1, "rien de plus à écrire")

        // Annulation (site supprimé) : rien n'est recréé.
        let gone = base.appendingPathComponent("sites/b/inventory.json")
        writer.schedule(store, to: gone)
        writer.cancel(gone)
        writer.flush()
        try expect(!FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path), "dossier du site supprimé non recréé")

        // Aucun fichier temporaire laissé à côté (écriture atomique).
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        try expectEqual(names, ["inventory.json"], "un seul fichier, complet")

        // Échec d'écriture signalé, sans plantage.
        let failures = LoadTimings()
        let blocked = base.appendingPathComponent("fichier")
        try Data("x".utf8).write(to: blocked)
        let failing = InventoryWriter(delay: 60, onError: { _, _ in failures.add("échec", 0, limit: 0) })
        failing.schedule(store, to: blocked.appendingPathComponent("inventory.json"))
        failing.flush()
        try expectEqual(failing.writeCount, 0, "aucune écriture réussie")
        try expectEqual(failures.rows.count, 1, "échec signalé")
    }

    suite.add("Performances : instantanés d’un petit site gardés comme avant (100 scans)") {
        var store = InventoryStore()
        let devices = (1...100).map { device("10.0.0.\($0)", String(format: "3C:22:FB:00:01:%02X", $0), host: "poste-\($0)") }
        for step in 0..<105 {
            var scan = devices
            // Un appareil change d'état à chaque scan : chaque instantané diffère du précédent.
            scan[step % 100].isOnline = step % 2 == 0
            store.merge(scan, at: now.addingTimeInterval(Double(step) * 3_600))
        }
        try expectEqual(store.snapshots.count, InventoryStore.maxSnapshots, "100 instantanés gardés (petit site)")
    }

    suite.add("Performances : lecture en parallèle identique à la lecture une par une") {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        var urls: [URL] = []
        for n in 0..<6 {
            var store = InventoryStore()
            store.merge((1...(10 + n)).map { device("10.0.\(n).\($0)", nil, host: "h\($0)") }, at: now)
            let url = base.appendingPathComponent("s\(n).json")
            try store.save(to: url)
            urls.append(url)
        }
        let broken = base.appendingPathComponent("illisible.json")
        try Data("{".utf8).write(to: broken)
        urls.append(broken)
        let results = InventoryStore.loadAll(urls)
        try expectEqual(results.count, 7, "un résultat par fichier, dans l'ordre")
        for n in 0..<6 { try expectEqual(try results[n].get().count, 10 + n, "inventaire \(n)") }
        if case .success = results[6] { throw TestFailure(message: "fichier illisible signalé", file: #fileID, line: #line) }
    }
}
