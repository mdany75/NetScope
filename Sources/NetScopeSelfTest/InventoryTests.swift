import Foundation
import NetScopeCore

// Scénarios fixes de l'inventaire : aucune entrée-sortie réseau, un seul fichier temporaire.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func dev(_ ip: String, _ mac: String?, host: String? = nil, online: Bool = true, sw: String? = nil,
                 port: String? = nil, vlan: Int? = nil, ports: [UInt16] = [], type: DeviceType = .poste,
                 seen: Date = t0) -> Device {
    Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), hostname: host, isOnline: online,
           openPorts: ports, switchName: sw, switchPort: port, vlan: vlan, firstSeen: seen, lastSeen: seen,
           deviceType: type)
}

private let macA = "94:DD:F8:18:15:7D"
private let macB = "5C:F9:38:02:7A:41"
private let macC = "B0:7B:25:44:A1:6C"

func registerInventoryTests(_ suite: TestSuite) {
    suite.add("Inventaire : premier scan de référence, clés MAC et IP") {
        var store = InventoryStore()
        let events = store.merge([dev("10.0.0.10", macA, host: "imp"), dev("10.0.0.20", nil, host: "sans-mac")], at: t0)
        try expectEqual(store.count, 2, "deux fiches")
        try expect(store.record("mac:94:dd:f8:18:15:7d") != nil, "clé MAC")
        try expect(store.record("ip:10.0.0.20") != nil, "clé IP sans MAC")
        try expectEqual(events.count, 2, "une détection par appareil")
        try expect(events.allSatisfy { $0.baseline && $0.kind == .nouveau && !$0.isAlert }, "référence : pas d'alerte")
        try expectEqual(store.snapshots.count, 1, "un instantané")

        // Un deuxième scan identique n'ajoute ni événement ni instantané.
        let again = store.merge([dev("10.0.0.10", macA, host: "imp"), dev("10.0.0.20", nil, host: "sans-mac")],
                                at: t0.addingTimeInterval(3600))
        try expect(again.isEmpty, "rien de nouveau")
        try expectEqual(store.snapshots.count, 1, "instantané identique ignoré")

        // La fiche connue par IP prend la clé MAC quand la MAC apparaît.
        store.merge([dev("10.0.0.20", macC, host: "sans-mac")], at: t0.addingTimeInterval(7200))
        try expect(store.record("ip:10.0.0.20") == nil && store.record("mac:b0:7b:25:44:a1:6c") != nil, "re-clé IP → MAC")
        try expectEqual(store.count, 2, "toujours deux fiches")

        // Nouvel appareil après la référence : alerte d'information.
        let later = store.merge([dev("10.0.0.30", "00:1A:2B:44:10:EE", host: "NPI7A4410")], at: t0.addingTimeInterval(9000))
        try expectEqual(later.map(\.kind), [.nouveau], "nouvel appareil")
        try expect(later[0].isAlert && later[0].title.contains("NPI7A4410"), "alerte « Nouvel appareil »")
    }

    suite.add("Inventaire : changement d'IP (même MAC)") {
        var store = InventoryStore()
        store.merge([dev("10.182.122.87", macA, host: "Brother")], at: t0)
        let events = store.merge([dev("10.182.122.111", macA, host: "Brother")], at: t0.addingTimeInterval(86_400))
        try expectEqual(events.map(\.kind), [.changementIP], "un changement d'IP")
        try expectEqual(events[0].title, "IP changée : .87 → .111", "titre court")
        let record = store.record(InventoryStore.key(mac: MACAddress(macA)!))!
        try expectEqual(record.ip.description, "10.182.122.111", "IP actuelle")
        try expectEqual(record.ipHistory.map(\.ip.description), ["10.182.122.87", "10.182.122.111"], "historique des IP")
        try expect(record.ipHistory[0].to != nil && record.ipHistory[1].to == nil, "période close puis ouverte")
        try expectEqual(store.count, 1, "toujours une seule fiche")
        let diff = InventoryStore.compare(store.snapshots[0], store.snapshots[1])
        try expectEqual(diff.modified.map(\.before), ["IP 10.182.122.87"], "comparaison : avant")
        try expectEqual(diff.modified.map(\.after), ["IP 10.182.122.111"], "comparaison : après")
        try expect(diff.added.isEmpty && diff.removed.isEmpty, "ni ajout ni disparition")
    }

    suite.add("Inventaire : changement de port de switch") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.117", macC, host: "WKS346", sw: "SW-CORE-01", port: "Gi1/0/7", vlan: 20)], at: t0)
        let events = store.merge([dev("10.0.0.117", macC, host: "WKS346", sw: "SW-CORE-01", port: "Gi1/0/9", vlan: 20)],
                                 at: t0.addingTimeInterval(600))
        try expectEqual(events.map(\.kind), [.changementPort], "un déplacement")
        try expectEqual(events[0].severity, .alerte, "gravité")
        try expectEqual(events[0].title, "Changement de port : WKS346 de SW-CORE-01 Gi1/0/7 à Gi1/0/9", "titre")
        let record = store.record(InventoryStore.key(mac: MACAddress(macC)!))!
        try expectEqual(record.portHistory.map(\.label), ["SW-CORE-01 · Gi1/0/7", "SW-CORE-01 · Gi1/0/9"], "historique des ports")
        try expectEqual(record.switchLocation, "SW-CORE-01 · Gi1/0/9", "emplacement actuel")
    }

    suite.add("Inventaire : conflit IP dans un même scan, puis levé") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.5", macC)], at: t0)
        let scan = [dev("10.0.0.140", macA, host: "NPI7A4410"), dev("10.0.0.140", macB, host: "autre")]
        let events = store.merge(scan, at: t0.addingTimeInterval(60))
        let conflicts = events.filter { $0.kind == .conflitIP }
        try expectEqual(conflicts.count, 1, "un seul événement pour l'adresse")
        try expectEqual(conflicts[0].severity, .critique, "critique")
        try expect(conflicts[0].title.contains("2 MAC"), "titre : 2 MAC")
        try expectEqual(store.conflictIPs, [IPv4Address("10.0.0.140")!], "IP en conflit")
        try expectEqual(store.record(InventoryStore.key(mac: MACAddress(macA)!))!.status(now: t0), .conflit, "statut")
        // Le même conflit au scan suivant ne produit pas de nouvel événement.
        let again = store.merge(scan, at: t0.addingTimeInterval(120))
        try expect(!again.contains { $0.kind == .conflitIP }, "pas de doublon d'événement")
        // L'autre MAC disparaît longtemps : conflit levé.
        store.merge([dev("10.0.0.140", macA, host: "NPI7A4410", seen: t0.addingTimeInterval(7200))], at: t0.addingTimeInterval(7200))
        try expect(store.conflictIPs.isEmpty, "conflit levé")
    }

    suite.add("Inventaire : conflit entre scans rapprochés, adresse reprise sinon") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.50", macA, host: "a")], at: t0)
        // Une autre MAC répond 5 min plus tard sur la même IP : conflit.
        let close = store.merge([dev("10.0.0.50", macB, host: "b", seen: t0.addingTimeInterval(300))], at: t0.addingTimeInterval(300))
        try expect(close.contains { $0.kind == .conflitIP }, "conflit entre scans rapprochés")

        var other = InventoryStore()
        other.merge([dev("10.0.0.50", macA, host: "a")], at: t0)
        // Deux heures plus tard : l'adresse a été réattribuée, l'ancienne fiche passe hors ligne.
        let late = other.merge([dev("10.0.0.50", macB, host: "b", seen: t0.addingTimeInterval(7200))], at: t0.addingTimeInterval(7200))
        try expect(!late.contains { $0.kind == .conflitIP }, "pas de conflit après réattribution")
        let old = other.record(InventoryStore.key(mac: MACAddress(macA)!))!
        try expect(!old.isOnline, "ancienne fiche hors ligne")
        try expect(late.contains { $0.kind == .horsLigne && $0.detail.contains("reprise") }, "adresse reprise")
    }

    suite.add("Inventaire : disparition, retour et « Disparus > 30 j »") {
        var store = InventoryStore()
        let range = try IPRange(parsing: "10.0.0.0/24")
        store.merge([dev("10.0.0.1", macA, type: .routeur), dev("10.0.0.2", macC)], at: t0, coverage: .ranges([range]))
        let gone = store.merge([dev("10.0.0.2", macC, seen: t0.addingTimeInterval(600))], at: t0.addingTimeInterval(600),
                               coverage: .ranges([range]))
        try expectEqual(gone.map(\.kind), [.horsLigne], "passerelle absente : hors ligne")
        try expectEqual(gone[0].severity, .alerte, "équipement réseau : alerte")
        let router = store.record(InventoryStore.key(mac: MACAddress(macA)!))!
        try expect(!router.isOnline && router.offlineSince != nil, "hors ligne depuis")
        try expect(!router.isGone(now: t0.addingTimeInterval(86_400)), "pas encore disparu")
        try expect(router.isGone(now: t0.addingTimeInterval(31 * 86_400)), "disparu après 30 jours")
        try expectEqual(router.status(now: t0.addingTimeInterval(31 * 86_400)), .disparu, "statut disparu")
        // Hors des plages sondées : rien ne change.
        let elsewhere = store.merge([dev("192.168.1.9", macB)], at: t0.addingTimeInterval(700), coverage: .ranges([try IPRange(parsing: "192.168.1.0/24")]))
        try expect(!elsewhere.contains { $0.kind == .horsLigne }, "plage non sondée")
        // Retour.
        let back = store.merge([dev("10.0.0.1", macA, type: .routeur, seen: t0.addingTimeInterval(1800))], at: t0.addingTimeInterval(1800))
        try expectEqual(back.map(\.kind), [.retour], "retour en ligne")
        try expectEqual(back[0].detail, "Hors ligne pendant 20 min", "durée")
        // Un appareil signalé hors ligne par le scan.
        let off = store.merge([dev("10.0.0.2", macC, online: false)], at: t0.addingTimeInterval(2400))
        try expectEqual(off.map(\.kind), [.horsLigne], "hors ligne signalé")
        try expectEqual(off[0].severity, .info, "poste : information")
        let diff = InventoryStore.compare(store.snapshots[store.snapshots.count - 2], store.snapshots.last!)
        try expectEqual(diff.removed.map(\.ip.description), ["10.0.0.2"], "comparaison : disparu")
    }

    suite.add("Inventaire : fiche éditable, favori, champs préservés") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.111", macA, host: "Brother DCP")], at: t0)
        let key = InventoryStore.key(mac: MACAddress(macA)!)
        var notes = store.record(key)!.annotations
        notes.customName = "  Imprimante accueil "
        notes.customType = .imprimante
        notes.tags = ["Imprimante", "Critique"]
        notes.location = "2e étage · Salle 204"
        notes.wallJack = "P2-14"
        notes.owner = "Réception"
        notes.assetNumber = "INV-00412"
        notes.notes = "Réservation DHCP"
        store.setAnnotations(notes, for: key, at: t0.addingTimeInterval(10))
        let record = store.record(key)!
        try expectEqual(record.displayName, "Imprimante accueil", "nom nettoyé")
        try expectEqual(record.type, .imprimante, "type choisi")
        let edits = store.events(for: key).filter { $0.kind == .fiche }
        try expectEqual(edits.count, 1, "événement de fiche")
        try expect(edits[0].detail.contains("nom") && edits[0].detail.contains("prise"), "champs listés")
        store.setFavorite(true, for: key)
        try expect(store.record(key)!.annotations.isFavorite, "favori")
        try expectEqual(store.events(for: key).filter { $0.kind == .fiche }.count, 1, "favori : pas d'événement")
        store.merge([dev("10.0.0.111", macA, host: "BRN-NOUVEAU", type: .inconnu)], at: t0.addingTimeInterval(60))
        let after = store.record(key)!
        try expectEqual(after.annotations.customName, "Imprimante accueil", "nom saisi préservé par le scan")
        try expectEqual(after.hostname, "BRN-NOUVEAU", "nom d'hôte mis à jour")
        try expect(after.matches("p2-14") && after.matches("inv-00412") && after.matches("salle 204"), "recherche : prise, actif, local")
        // Alerte : accepter puis annuler.
        let id = store.events.last!.id
        store.setEventStatus(.accepte, for: id, at: t0)
        try expectEqual(store.events.last!.status, .accepte, "accepté")
        store.setEventStatus(.aTraiter, for: id)
        try expect(store.events.last!.statusDate == nil, "remis à traiter")
    }

    suite.add("Inventaire : comparaison de deux scans") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.1", macA, ports: [22, 443]), dev("10.0.0.2", macB), dev("10.0.0.3", macC, sw: "SW", port: "1/1")], at: t0)
        store.merge([dev("10.0.0.1", macA, ports: [22, 23, 443]), dev("10.0.0.3", macC, sw: "SW", port: "1/2"),
                     dev("10.0.0.4", "00:1A:2B:44:10:EE")], at: t0.addingTimeInterval(3600), coverage: .subnetsOfIncoming)
        let diff = InventoryStore.compare(store.snapshots[0], store.snapshots[1])
        try expectEqual(diff.added.map(\.ip.description), ["10.0.0.4"], "ajouté")
        try expectEqual(diff.removed.map(\.ip.description), ["10.0.0.2"], "disparu")
        try expectEqual(Set(diff.modified.map(\.after)), ["Ports 22, 23, 443", "SW · 1/2"], "modifiés")
    }

    suite.add("Inventaire : enregistrement JSON (fichier temporaire)") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.10", macA, host: "imp", sw: "SW", port: "1/4", vlan: 30)], at: t0)
        store.setFavorite(true, for: InventoryStore.key(mac: MACAddress(macA)!))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("netscope-selftest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("inventory.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.save(to: url)
        let loaded = try InventoryStore.load(from: url)
        try expectEqual(loaded.sortedRecords, store.sortedRecords, "fiches identiques")
        try expectEqual(loaded.events.count, store.events.count, "événements")
        try expectEqual(loaded.snapshots.count, 1, "instantanés")
        let missing = try InventoryStore.load(from: url.deletingLastPathComponent().appendingPathComponent("absent.json"))
        try expect(missing.isEmpty, "fichier absent : base vide")
    }

    suite.add("Inventaire : CSV (export, lecture, import)") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.10", macA, host: "imp"), dev("10.0.0.11", macB, host: "poste")], at: t0)
        var notes = store.record(InventoryStore.key(mac: MACAddress(macA)!))!.annotations
        notes.customName = "Imprimante; accueil"
        notes.notes = "Ligne 1\n« guillemets » \"doubles\""
        notes.tags = ["Imprimante", "Critique"]
        store.setAnnotations(notes, for: InventoryStore.key(mac: MACAddress(macA)!))
        let csv = InvCSV.export(store.sortedRecords, now: t0)
        try expect(csv.hasPrefix("IP;MAC;Nom;"), "en-tête")
        let rows = try InvCSV.parse(csv)
        try expectEqual(rows.count, 2, "deux lignes")
        try expectEqual(rows[0].name, "Imprimante; accueil", "séparateur protégé")
        try expectEqual(rows[0].notes, "Ligne 1\n« guillemets » \"doubles\"", "guillemets et saut de ligne")
        try expectEqual(rows[0].tags, ["Imprimante", "Critique"], "étiquettes")
        try expectEqual(rows[0].type, .poste, "type relu")

        let external = "Adresse IP,MAC,Nom,Type,Local,Prise murale,Responsable,N° d'actif\n" +
            "10.0.0.11,,Poste réception,Poste de travail,1er étage,P1-01,Réception,INV-00341\n" +
            "10.0.0.99,00:1A:2B:44:10:EE,Imprimante HP,Imprimante,2e étage,,,\n" +
            ",,sans adresse,,,,,\n"
        let imported = try InvCSV.parse(external)
        try expectEqual(imported.count, 2, "ligne sans IP ni MAC ignorée")
        let result = store.importRows(imported, at: t0)
        try expectEqual(result.created, 1, "une fiche créée")
        try expectEqual(result.updated, 1, "une fiche complétée")
        let updated = store.record(InventoryStore.key(mac: MACAddress(macB)!))!
        try expectEqual(updated.annotations.wallJack, "P1-01", "prise importée")
        try expectEqual(updated.displayName, "Poste réception", "nom importé")
        let created = store.record(InventoryStore.key(mac: MACAddress("00:1A:2B:44:10:EE")!))!
        try expect(created.isImported && !created.isOnline, "fiche importée hors ligne")
        try expectEqual(created.type, .imprimante, "type importé")
        try expectThrows(InvCSVError.missingColumns, "colonnes manquantes") { _ = try InvCSV.parse("Nom;Local\nx;y\n") }
    }

    suite.add("Inventaire : doublons probables et fusion de fiches") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.160", "3C:22:FB:7E:05:B2", host: "Macmini-de-Dany", online: true, sw: "SW", port: "1/11")], at: t0)
        store.merge([dev("10.0.0.160", "3C:22:FB:7E:05:B2", host: "Macmini-de-Dany", online: false)], at: t0.addingTimeInterval(3600))
        store.merge([dev("10.0.0.135", "3C:22:FB:7E:05:B1", host: "Macmini-de-Dany", seen: t0.addingTimeInterval(7200))], at: t0.addingTimeInterval(7200))
        let duplicates = store.probableDuplicates()
        try expectEqual(duplicates.count, 1, "une paire")
        try expectEqual(duplicates[0].keep, "mac:3c:22:fb:7e:05:b1", "fiche la plus récente conservée")
        store.absorb(duplicates[0].absorb, into: duplicates[0].keep, at: t0.addingTimeInterval(7300))
        try expectEqual(store.count, 1, "une seule fiche")
        let kept = store.record("mac:3c:22:fb:7e:05:b1")!
        try expectEqual(kept.ipHistory.map(\.ip.description), ["10.0.0.160", "10.0.0.135"], "historique des IP réuni")
        try expectEqual(kept.portHistory.count, 1, "historique des ports repris")
        try expect(store.events(for: kept.key).contains { $0.kind == .fusion }, "événement de fusion")
        try expect(store.probableDuplicates().isEmpty, "plus de doublon")
    }

    suite.add("Analyse : carte d'occupation d'un /24") {
        var store = InventoryStore()
        store.merge([dev("10.182.122.1", macA), dev("10.182.122.2", macC, online: false, seen: t0.addingTimeInterval(-3600)),
                     dev("10.182.122.140", "00:1A:2B:44:10:EE"), dev("10.182.122.140", macB),
                     dev("10.182.123.5", "F4:EE:08:3C:72:A1")], at: t0)
        let grid = InvOccupancy(network: IPv4Address("10.182.122.77")!, records: Array(store.records.values), now: t0)
        try expectEqual(grid.network.description, "10.182.122.0/24", "réseau")
        try expectEqual(grid.cells.count, 256, "256 cases")
        try expectEqual(grid.cells[0].state, .reseau, "adresse réseau")
        try expectEqual(grid.cells[255].state, .reseau, "diffusion")
        try expectEqual(grid.cells[1].state, .enLigne, "en ligne")
        try expectEqual(grid.cells[2].state, .horsLigne, "hors ligne récent")
        try expectEqual(grid.cells[140].state, .conflit, "conflit")
        try expectEqual(grid.cells[3].state, .libre, "libre")
        try expectEqual(grid.usedCount, 3, "trois occupées")
        try expectEqual(InvOccupancy.networks(of: Array(store.records.values)).map(\.description),
                        ["10.182.122.0", "10.182.123.0"], "deux /24")
        let old = InvOccupancy(network: IPv4Address("10.182.122.0")!, records: Array(store.records.values),
                               now: t0.addingTimeInterval(30 * 86_400))
        // Case encadrée par défaut = adresse du détail : le conflit .140, rangée .128, colonne 12.
        try expectEqual(grid.defaultFocus, 140, "case par défaut : le conflit")
        try expectEqual(grid.cells[grid.defaultFocus].ip.description, "10.182.122.140", "adresse de la case par défaut")
        let position = InvOccupancy.position(of: grid.defaultFocus)
        try expectEqual(position.row * 16, 128, "rangée .128")
        try expectEqual(position.column, 12, "colonne 12")
        try expectEqual(InvOccupancy.index(row: position.row, column: position.column), 140, "index de la case")
        for index in grid.cells.indices {
            let (row, column) = InvOccupancy.position(of: index)
            try expectEqual(grid.cells[InvOccupancy.index(row: row, column: column)].index, index, "case \(index)")
            try expectEqual(Int(grid.cells[index].ip.value & 0xFF), index, "dernier octet de la case \(index)")
        }
        try expectEqual(old.defaultFocus, 140, "conflit prioritaire")
        try expectEqual(old.cells[2].state, .libre,"hors ligne ancien : libre")
    }

    suite.add("Carte du réseau : hiérarchie passerelle → switchs → groupes") {
        let devices = [
            dev("10.0.0.1", "04:D5:90:3A:7B:11", host: "FortiGate-60F", sw: "SW-CORE-01", port: "Gi1/0/1", type: .routeur),
            dev("10.0.0.2", "70:0F:6A:91:4C:02", host: "SW-CORE-01", sw: "SW-CORE-01", port: "Vlan1", type: .switch),
            dev("10.0.0.3", "88:3A:30:5D:E1:40", host: "SW-ETG2-01", sw: "SW-CORE-01", port: "Gi1/0/47", type: .switch),
            dev("10.0.0.102", "70:4C:A5:1E:22:9A", host: "FortiAP-231F", sw: "SW-CORE-01", port: "Gi1/0/12", type: .pointAcces),
            dev("10.0.0.111", macA, host: "Brother", sw: "SW-ETG2-01", port: "1/14", type: .imprimante),
            dev("10.0.0.113", "8C:16:45:2B:9E:03", host: "PF4", sw: "SW-ETG2-01", port: "1/3", type: .poste),
            dev("10.0.0.117", macC, host: "WKS346", sw: "SW-ETG2-01", port: "1/4", type: .poste),
            dev("10.0.0.133", "D6:4E:81:7A:33:C0", host: "Android", sw: "FortiAP-231F", port: "Wi-Fi", type: .telephone),
            dev("10.0.0.150", "BC:AD:28:6F:01:5A", host: "cam", sw: "SW-NOUVEAU", port: "3", type: .camera),
            dev("10.0.0.160", "B8:A4:4F:2C:19:E0", host: "inconnu", type: .inconnu),
        ]
        let graph = TopoGraph.build(devices: devices, gateway: IPv4Address("10.0.0.1"), conflictIPs: [IPv4Address("10.0.0.111")!])
        try expectEqual(graph.node("passerelle")?.title, "FortiGate-60F", "passerelle détectée")
        try expectEqual(graph.node("passerelle")?.parentID, "internet", "Internet au sommet")
        try expectEqual(graph.node("dev:10.0.0.2")?.parentID, "passerelle", "switch cœur sous la passerelle")
        try expectEqual(graph.node("dev:10.0.0.3")?.parentID, "dev:10.0.0.2", "switch d'étage sous le cœur")
        try expectEqual(graph.node("dev:10.0.0.3")?.uplinkLabel, "Gi1/0/47", "port de l'uplink")
        let postes = graph.children(of: "dev:10.0.0.3").first { $0.kind == .groupe }
        try expectEqual(postes?.title, "Postes ×2", "groupe de postes")
        try expectEqual(postes?.uplinkLabel, "2 ports", "ports du groupe")
        try expectEqual(graph.node("dev:10.0.0.111")?.status, .critique, "imprimante en conflit")
        try expectEqual(graph.node("dev:10.0.0.133")?.parentID, "dev:10.0.0.102", "téléphone sous le point d'accès")
        try expect(graph.node("dev:10.0.0.133")?.isWireless == true, "lien Wi-Fi")
        try expect(graph.node("sw:sw-nouveau")?.isInferred == true, "switch connu par son nom")
        try expectEqual(graph.node("dev:10.0.0.160")?.parentID, "sw:?", "port inconnu : groupe « Switchs »")
        let layout = graph.layout()
        try expectEqual(layout.positions.count, graph.nodes.count, "tous les nœuds placés")
        try expect(layout.positions["internet"]!.y < layout.positions["passerelle"]!.y, "niveaux descendants")
        try expect(graph.links.count == graph.nodes.count - 1, "un lien par nœud sauf la racine")
        // Sans passerelle ni switch connus.
        let bare = TopoGraph.build(devices: [dev("10.0.0.9", macA)], gateway: nil)
        try expectEqual(bare.node("passerelle")?.subtitle, "Non détectée", "passerelle inconnue")
        try expectEqual(bare.node("dev:10.0.0.9")?.parentID, "sw:?", "rattaché au groupe « Switchs »")
    }
    suite.add("Relecture : CSV protégé contre les formules, carte sans nœud en double") {
        var store = InventoryStore()
        store.merge([dev("10.0.0.10", macA, host: "=HYPERLINK(\"http://x\")"), dev("10.0.0.11", macB, host: "poste")], at: t0)
        var notes = store.record(InventoryStore.key(mac: MACAddress(macA)!))!.annotations
        notes.notes = "-liste"
        store.setAnnotations(notes, for: InventoryStore.key(mac: MACAddress(macA)!))
        let csv = InvCSV.export(store.sortedRecords, now: t0)
        try expect(!csv.contains(";=") && !csv.contains(";\"=") && !csv.contains(";-liste"), "aucune cellule ne commence par une formule")
        try expectEqual(InvCSV.quote("+1;2"), "\"'+1;2\"", "apostrophe puis guillemets")
        let rows = try InvCSV.parse(csv)
        try expectEqual(rows[0].hostname, "=HYPERLINK(\"http://x\")", "valeur d'origine relue")
        try expectEqual(rows[0].notes, "-liste", "apostrophe retirée à l'import")

        let twice = [dev("10.0.0.5", macA, type: .poste), dev("10.0.0.5", macB, type: .imprimante, seen: t0.addingTimeInterval(5))]
        let graph = TopoGraph.build(devices: twice, gateway: nil)
        try expectEqual(Set(graph.nodes.map(\.id)).count, graph.nodes.count, "identifiants uniques")
        try expectEqual(graph.links.count, graph.nodes.count - 1, "liens cohérents")
    }
}
