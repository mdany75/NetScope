import Foundation
import NetScopeCore

// Note 10 (Inventaire, phase 3) : ajout à la main et rapprochement, ajout automatique ou choisi,
// archives, exclusions, déplacement entre sites, garanties, pièces jointes et migration des fichiers
// d'avant la 0.20.0. Données fixes, aucun accès réseau ; seuls un dossier et un fichier temporaires.

private let p0 = Date(timeIntervalSince1970: 1_790_000_000)

private func device(_ ip: String, _ mac: String?, host: String? = nil, online: Bool = true, vendor: String? = nil,
                    sw: String? = nil, port: String? = nil, seen: Date = p0) -> Device {
    Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), vendor: vendor, hostname: host, isOnline: online,
           switchName: sw, switchPort: port, firstSeen: seen, lastSeen: seen, deviceType: .poste)
}

private let m1 = "94:DD:F8:18:15:7D"
private let m2 = "5C:F9:38:02:7A:41"
private let m3 = "B0:7B:25:44:A1:6C"

private func day(_ text: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
}

func registerInventoryPhase3Tests(_ suite: TestSuite) {
    suite.add("Inventaire phase 3 : ajout à la main puis rapprochement par la MAC") {
        var store = InventoryStore()
        let key = try store.addManual(InvManualDraft(name: "Imprimante entrepôt", ip: IPv4Address("10.0.0.50"),
                                                     mac: MACAddress(m1), vendor: "Zebra", type: .imprimante,
                                                     location: "Quai 2", wallJack: "Q2-04", switchName: "SW-QUAI",
                                                     switchPort: "1/12", owner: "Expédition", notes: "Hors réseau l’hiver",
                                                     tags: ["Stock", " stock ", "Quai"]), at: p0)
        try expect(key.hasPrefix(InventoryStore.manualPrefix), "clé « man: » tant qu'aucun scan ne l'a vue")
        let made = store.record(key)!
        try expect(made.isManual && made.isAwaitingScan && !made.isOnline, "ajouté à la main, jamais scanné")
        try expectEqual(made.annotations.tags, ["Stock", "Quai"], "étiquettes nettoyées, sans doublon")
        try expectEqual(made.vendorLabel, "Zebra", "fabricant saisi")
        try expectEqual(made.type, .imprimante, "type saisi")
        try expectEqual(made.switchLocation, "SW-QUAI · 1/12", "switch et port saisis")
        try expect(!made.isGone(now: p0.addingTimeInterval(90 * 86_400)), "jamais « disparu » avant le premier scan")

        // Premier scan du site : seules des fiches à la main → scan de référence, pas d'alerte.
        let events = store.merge([device("10.0.0.77", m1, host: "ZT410-QUAI", vendor: "Zebra Technologies",
                                         sw: "SW-QUAI", port: "1/14"),
                                  device("10.0.0.80", m2, host: "autre")], at: p0.addingTimeInterval(3600))
        try expect(events.allSatisfy { !$0.isAlert }, "premier scan : aucune alerte")
        let macKey = InventoryStore.key(mac: MACAddress(m1)!)
        try expect(store.record(key) == nil, "l'ancienne clé disparaît")
        let matched = try expectRecord(store, macKey)
        try expect(matched.isManual && !matched.isAwaitingScan, "rapproché, toujours « ajouté à la main »")
        try expectEqual(matched.annotations.customName, "Imprimante entrepôt", "nom saisi gardé")
        try expectEqual(matched.annotations.location, "Quai 2", "local gardé")
        try expectEqual(matched.annotations.owner, "Expédition", "responsable gardé")
        try expectEqual(matched.vendorLabel, "Zebra", "fabricant saisi gardé")
        try expectEqual(matched.hostname, "ZT410-QUAI", "nom d'hôte du scan")
        try expectEqual(matched.ip.description, "10.0.0.77", "IP du scan")
        try expectEqual(matched.switchPort, "1/14", "port relevé par le scan")
        try expect(matched.isOnline, "en ligne")
        try expectEqual(store.count, 2, "pas de doublon : deux fiches")
        let history = store.events(for: macKey).map(\.title)
        try expect(history.contains("Ajouté à la main") && history.contains("Rapproché d’un appareil scanné"),
                   "chronologie : ajout puis rapprochement")
        try expect(!history.contains { $0.hasPrefix("De retour") }, "pas de « De retour en ligne »")
    }

    suite.add("Inventaire phase 3 : rapprochement par l'IP, jamais d'un autre appareil ni d'un autre site") {
        var site = InventoryStore()
        site.merge([device("10.0.0.2", m3, host: "base")], at: p0)
        let noMAC = try site.addManual(InvManualDraft(name: "Caméra quai", ip: IPv4Address("10.0.0.60")), at: p0)
        let otherMAC = try site.addManual(InvManualDraft(name: "Lecteur", ip: IPv4Address("10.0.0.61"), mac: MACAddress(m2)), at: p0)
        // Un autre site (autre inventaire) voit la même IP : rien ne change ici.
        var otherSite = InventoryStore()
        otherSite.merge([device("10.0.0.60", m1, host: "camera-autre-site")], at: p0)
        try expect(site.record(noMAC) != nil, "l'autre site ne rapproche rien ici")

        site.merge([device("10.0.0.2", m3, host: "base"), device("10.0.0.60", m1, host: "CAM-QUAI"),
                    device("10.0.0.61", "00:1A:2B:44:10:EE", host: "intrus")], at: p0.addingTimeInterval(600))
        try expect(site.record(noMAC) == nil, "rapprochée par l'IP")
        let camera = try expectRecord(site, InventoryStore.key(mac: MACAddress(m1)!))
        try expectEqual(camera.displayName, "Caméra quai", "nom saisi")
        try expectEqual(camera.mac?.formatted(.upperColon), m1, "MAC apprise du scan")
        try expect(site.record(otherMAC)?.isAwaitingScan == true, "même IP mais autre MAC : pas rapprochée")
        try expect(site.record(InventoryStore.key(mac: MACAddress("00:1A:2B:44:10:EE")!)) != nil, "l'autre appareil a sa fiche")
        try expectEqual(otherSite.count, 1, "l'autre site n'a que sa fiche")
    }

    suite.add("Inventaire phase 3 : modifier, dupliquer, refuser une MAC en double, sans IP") {
        var store = InventoryStore()
        store.merge([device("10.0.0.10", m1, host: "poste")], at: p0)
        do {
            try store.addManual(InvManualDraft(name: "Copie", mac: MACAddress(m1)), at: p0)
            throw TestFailure(message: "MAC en double acceptée", file: #fileID, line: #line)
        } catch let error as InvManualError {
            try expectEqual(error, .duplicateMAC(key: InventoryStore.key(mac: MACAddress(m1)!), name: "poste"), "MAC déjà là")
        }
        try expectThrows(InvManualError.empty, "formulaire vide") { try store.addManual(InvManualDraft(), at: p0) }

        let key = try store.addManual(InvManualDraft(name: "Portable en stock", type: .poste, tags: ["Stock"]), at: p0)
        var record = store.record(key)!
        try expect(!record.hasAddress && record.addressLabel == "—", "sans adresse IP")
        try expectEqual(record.displayName, "Portable en stock", "nom")
        var draft = InvManualDraft(record: record)
        draft.ip = IPv4Address("10.0.0.90")
        draft.mac = MACAddress(m2)
        draft.location = "Armoire TI"
        try store.updateManual(key, with: draft, at: p0.addingTimeInterval(60))
        record = store.record(key)!
        try expectEqual(record.ip.description, "10.0.0.90", "IP modifiée")
        try expectEqual(record.ipHistory.map(\.ip.description), ["10.0.0.90"], "historique d'IP recommencé")
        try expectEqual(record.annotations.location, "Armoire TI", "local modifié")
        try expectEqual(store.events(for: key).last?.title, "Fiche modifiée", "événement")

        let copy = store.duplicate(key, at: p0.addingTimeInterval(120))!
        let copied = store.record(copy)!
        try expect(copied.mac == nil && !copied.hasAddress, "copie sans IP ni MAC")
        try expectEqual(copied.displayName, "Portable en stock (copie)", "nom de la copie")
        try expectEqual(copied.annotations.location, "Armoire TI", "champs saisis copiés")

        // Une fiche vue par un scan ne change ni d'IP ni de MAC à la main.
        let scanned = InventoryStore.key(mac: MACAddress(m1)!)
        try expectThrows(InvManualError.notEditable, "fiche scannée") {
            try store.updateManual(scanned, with: InvManualDraft(name: "x"), at: p0)
        }
        // Supprimer : comme toute fiche (annulable).
        let removal = store.removeRecords([copy], exclude: false, at: p0.addingTimeInterval(200))
        try expect(store.record(copy) == nil, "supprimée")
        store.restore(removal)
        try expect(store.record(copy) != nil, "annulation")
    }

    suite.add("Inventaire phase 3 : ajout automatique désactivé, « Ajouter à l'inventaire »") {
        var store = InventoryStore()
        store.merge([device("10.0.0.10", m1, host: "connu")], at: p0)
        store.setAutoAdd(false)
        try expect(!store.autoAdd, "option du site")
        let events = store.merge([device("10.0.0.10", m1, host: "connu-renomme"),
                                  device("10.0.0.20", m2, host: "nouveau")], at: p0.addingTimeInterval(600))
        try expectEqual(store.count, 1, "aucune fiche créée")
        try expect(!events.contains { $0.kind == .nouveau }, "pas d'événement « Nouvel appareil »")
        try expectEqual(store.record(InventoryStore.key(mac: MACAddress(m1)!))?.hostname, "connu-renomme", "fiche existante mise à jour")
        let scan = [device("10.0.0.10", m1), device("10.0.0.20", m2, host: "nouveau")]
        try expectEqual(store.notInInventory(scan).map(\.ip.description), ["10.0.0.20"], "hors inventaire")

        // Conflit IP : l'appareil hors inventaire compte toujours.
        store.merge([device("10.0.0.10", m1), device("10.0.0.10", m3, host: "intrus")], at: p0.addingTimeInterval(900))
        try expect(store.record(InventoryStore.key(mac: MACAddress(m1)!))?.hasConflict == true, "conflit relevé")

        let result = store.addScanned([device("10.0.0.20", m2, host: "nouveau")], at: p0.addingTimeInterval(1200))
        try expectEqual(result.added, 1, "ajouté depuis le Scanner")
        try expectEqual(store.events(for: InventoryStore.key(mac: MACAddress(m2)!)).last?.title,
                        "Ajouté à l’inventaire depuis le Scanner", "événement")
        let again = store.addScanned([device("10.0.0.20", m2)], at: p0.addingTimeInterval(1300))
        try expectEqual(again.already, 1, "déjà là")
        store.setAutoAdd(true)
        try expect(store.autoAdd, "rétabli")
    }

    suite.add("Inventaire phase 3 : archiver, restaurer, revu par un scan, supprimer définitivement") {
        var store = InventoryStore()
        store.merge([device("10.0.0.10", m1, host: "vieux-nas"), device("10.0.0.11", m2, host: "poste")], at: p0)
        let key = InventoryStore.key(mac: MACAddress(m1)!)
        var notes = store.record(key)!.annotations
        notes.notes = "À recycler"
        store.setAnnotations(notes, for: key, at: p0)
        let removal = store.removeRecords([key], exclude: false, archive: true, at: p0.addingTimeInterval(60))
        try expect(removal.isArchive, "archivage")
        try expectEqual(store.archivedCount, 1, "une archive")
        try expect(store.record(key) == nil, "hors de la liste")
        try expectEqual(store.archivedEntry(key)?.record.annotations.notes, "À recycler", "fiche gardée")
        try expect(store.archivedEntry(key)?.events.isEmpty == false, "historique gardé")
        // Annuler : la fiche revient, l'archive disparaît.
        store.restore(removal)
        try expect(store.record(key) != nil && store.archivedCount == 0, "annulation de l'archivage")

        // Archivé puis revu par un scan : remis avec sa fiche d'avant.
        store.removeRecords([key], exclude: false, archive: true, at: p0.addingTimeInterval(120))
        store.merge([device("10.0.0.12", m1, host: "vieux-nas")], at: p0.addingTimeInterval(3600))
        let back = try expectRecord(store, key)
        try expectEqual(back.annotations.notes, "À recycler", "notes reprises")
        try expectEqual(store.archivedCount, 0, "plus archivé")
        try expect(store.events(for: key).contains { $0.title.contains("restaurée depuis les archives") }, "événement")

        // Archivé et « Ne plus réajouter » : un scan ne le remet pas.
        store.removeRecords([key], exclude: true, archive: true, at: p0.addingTimeInterval(4000))
        store.merge([device("10.0.0.12", m1)], at: p0.addingTimeInterval(5000))
        try expect(store.record(key) == nil && store.archivedCount == 1, "exclu : reste archivé")
        // Restaurer à la main lève l'exclusion.
        let restored = store.restoreArchived([key], at: p0.addingTimeInterval(5100))
        try expectEqual(restored.restored, 1, "restauré")
        try expect(!store.isExcluded(key: key), "exclusion levée")

        // Ajout automatique désactivé : un appareil archivé revu reste archivé.
        store.removeRecords([key], exclude: false, archive: true, at: p0.addingTimeInterval(6000))
        store.setAutoAdd(false)
        store.merge([device("10.0.0.12", m1)], at: p0.addingTimeInterval(7000))
        try expect(store.record(key) == nil && store.archivedCount == 1, "reste archivé")
        try expectEqual(store.addScanned([device("10.0.0.12", m1)], at: p0.addingTimeInterval(7100)).restored, 1,
                        "« Ajouter à l'inventaire » le restaure")

        // Supprimer définitivement des archives, puis annuler.
        store.removeRecords([key], exclude: false, archive: true, at: p0.addingTimeInterval(8000))
        let purged = store.purgeArchived([key])
        try expectEqual(purged.count, 1, "supprimé des archives")
        try expectEqual(store.archivedCount, 0, "archives vides")
        store.putBackArchived(purged)
        try expectEqual(store.archivedCount, 1, "annulation")
    }

    suite.add("Inventaire phase 3 : liste d'exclusion écrite à la main") {
        var store = InventoryStore()
        store.merge([device("10.0.0.10", m1)], at: p0)
        try expect(!store.exclude(mac: MACAddress(m1)!, name: "suivi"), "MAC d'une fiche suivie : refusée")
        try expect(store.exclude(mac: MACAddress(m2)!, name: " Téléphone invité ", at: p0), "MAC ajoutée")
        try expect(!store.exclude(mac: MACAddress(m2)!, name: "x"), "déjà exclue")
        try expectEqual(store.excluded.first?.name, "Téléphone invité", "nom nettoyé")
        store.merge([device("10.0.0.20", m2)], at: p0.addingTimeInterval(600))
        try expect(store.record(InventoryStore.key(mac: MACAddress(m2)!)) == nil, "un scan ne l'ajoute pas")
        store.include(InventoryStore.key(mac: MACAddress(m2)!))
        try expect(store.excluded.isEmpty, "retirée de la liste")
    }

    suite.add("Inventaire phase 3 : déplacer vers un autre site, sans jamais fusionner") {
        var siege = InventoryStore()
        var laval = InventoryStore()
        siege.merge([device("10.0.0.10", m1, host: "portable"), device("10.0.0.11", m2, host: "imprimante")], at: p0)
        laval.merge([device("10.20.0.5", m2, host: "imprimante-laval")], at: p0)
        let k1 = InventoryStore.key(mac: MACAddress(m1)!)
        let k2 = InventoryStore.key(mac: MACAddress(m2)!)
        var notes = siege.record(k1)!.annotations
        notes.hardware = InvHardware(warrantyEnd: day("2027-01-31"), serialNumber: "SN-1")
        siege.setAnnotations(notes, for: k1, at: p0)

        // Même MAC sur deux sites : signalée, pas fusionnée.
        let shared = SiteScope.sharedMACs([SiteInventory(key: "a", name: "Siège", store: siege),
                                           SiteInventory(key: "b", name: "Laval", store: laval)])
        try expectEqual(shared[MACAddress(m2)!] ?? [], ["a", "b"], "MAC signalée sur deux sites")
        try expect(shared[MACAddress(m1)!] == nil, "MAC propre au Siège")

        let refusals = laval.transferRefusals(for: [siege.record(k1)!, siege.record(k2)!])
        try expectEqual(refusals.map(\.key), [k2], "même MAC déjà à Laval : refusée")
        let taken = siege.takeForTransfer([k1, k2])
        try expectEqual(siege.count, 0, "retirées du Siège")
        let refused = laval.receive(taken, from: "Siège", at: p0.addingTimeInterval(60))
        try expectEqual(refused.keys, [k2], "refus rendu")
        siege.giveBack(refused)
        try expect(siege.record(k2) != nil, "l'imprimante reste au Siège")
        try expectEqual(laval.count, 2, "Laval : sa fiche et le portable")
        try expectEqual(laval.record(k2)?.hostname, "imprimante-laval", "la fiche de Laval n'est pas touchée")
        let moved = try expectRecord(laval, k1)
        try expectEqual(moved.annotations.hardware?.serialNumber, "SN-1", "garantie déplacée")
        try expect(laval.events(for: k1).contains { $0.title == "Déplacé depuis «\u{00A0}Siège\u{00A0}»" }, "événement")
        try expect(laval.events(for: k1).contains { $0.kind == .nouveau }, "historique déplacé")
        try expect(siege.events(for: k1).isEmpty, "plus d'historique au Siège")

        // Annuler le déplacement.
        let undo = laval.undoReceive([k1])
        siege.giveBack(undo)
        try expect(siege.record(k1) != nil && laval.record(k1) == nil, "déplacement annulé")
        try expect(!siege.events(for: k1).contains { $0.title.hasPrefix("Déplacé") }, "événement retiré")
    }

    suite.add("Inventaire phase 3 : garanties, prix et étiquettes") {
        let now = day("2026-11-04")
        var hardware = InvHardware(purchaseDate: day("2023-11-20"), warrantyEnd: day("2026-11-28"), supplier: "CDW",
                                   serialNumber: "E78123K4N", price: 1249.99)
        try expectEqual(hardware.warranty(now: now), .expiringSoon(days: 24), "bientôt échue")
        try expect(hardware.warranty(now: now).isAlert, "alerte")
        try expect(hardware.warranty(now: now).label.contains("24\u{00A0}j"), "libellé")
        hardware.warrantyEnd = day("2028-06-30")
        try expect(!hardware.warranty(now: now).isAlert, "active")
        hardware.warrantyEnd = day("2026-10-01")
        try expectEqual(hardware.warranty(now: now), .expired(days: 34), "échue")
        try expectEqual(InvHardware().warranty(now: now), .unknown, "non renseignée")
        try expect(InvHardware(supplier: "  ").cleaned == nil, "vide")
        try expectEqual(InvHardware.parsePrice("1 249,99 $"), 1249.99, "prix à la française")
        try expectEqual(InvHardware.parsePrice("1,249.99"), 1249.99, "prix à l'anglaise")
        try expect(InvHardware.parsePrice("abc") == nil && InvHardware.parsePrice("") == nil, "prix illisible")
        try expect(InvHardware.priceLabel(1249.99).contains("249,99"), "prix affiché")

        var store = InventoryStore()
        store.merge([device("10.0.0.10", m1, host: "a"), device("10.0.0.11", m2, host: "b"), device("10.0.0.12", m3, host: "c")], at: p0)
        for (mac, end, tags) in [(m1, "2026-12-20", ["Critique"]), (m2, "2026-11-10", ["critique", "Quai"]), (m3, "2029-01-01", [])] {
            let key = InventoryStore.key(mac: MACAddress(mac)!)
            var notes = store.record(key)!.annotations
            notes.hardware = InvHardware(warrantyEnd: day(end))
            notes.tags = tags
            store.setAnnotations(notes, for: key, at: p0)
            try expect(store.events(for: key).last?.detail.contains("garantie") == true, "« garantie » dans la chronologie")
        }
        try expectEqual(store.expiringWarranties(now: now).map(\.hostname), ["b", "a"], "les plus proches d'abord")
        try expectEqual(store.allTags, ["Critique", "Quai"], "étiquettes sans doublon")
        let rows = SiteScope.expiringWarranties([SiteInventory(key: "s", name: "Siège", store: store)], now: now)
        try expectEqual(rows.map(\.siteName), ["Siège", "Siège"], "rapports : lignes avec leur site")
    }

    suite.add("Inventaire phase 3 : pièces jointes dans un dossier temporaire") {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-pj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = InvAttachmentFiles(base: base, useTrash: false)
        let source = base.appendingPathComponent("source/Facture Catalyst.pdf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("facture".utf8).write(to: source)

        var store = InventoryStore()
        store.merge([device("10.0.0.2", m1, host: "SW-CORE-01")], at: p0)
        let key = InventoryStore.key(mac: MACAddress(m1)!)
        let folder = InvAttachmentFiles.folderName(for: store.record(key)!, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!)
        try expectEqual(folder, "SW-CORE-01-1A2B3C4D", "dossier lisible")
        try expectEqual(InvAttachmentFiles.folderName(for: InvRecord(key: "k", mac: nil, ip: IPv4Address("10.0.0.3")!,
                                                                     firstSeen: p0, lastSeen: p0,
                                                                     annotations: InvAnnotations(customName: "Écran / hall")),
                                                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
                        "Ecran-hall-00000000", "accents et « / » retirés")

        let first = try files.add(source, site: "siege", folder: folder, at: p0)
        let second = try files.add(source, site: "siege", folder: folder, at: p0)
        try expectEqual(first.storedName, "Facture Catalyst.pdf", "nom d'origine")
        try expectEqual(second.storedName, "Facture Catalyst 2.pdf", "nom rendu unique")
        try expectEqual(first.size, 7, "taille")
        try expect(store.addAttachment(first, folder: folder, to: key) && store.addAttachment(second, folder: folder, to: key), "sur la fiche")
        try expectEqual(store.record(key)?.attachmentList.count, 2, "deux pièces")
        try expectEqual(store.record(key)?.attachmentFolder, folder, "dossier retenu")

        let removed = store.removeAttachment(second.id, from: key)!
        try files.remove(removed, site: "siege", folder: folder)
        try expect(!FileManager.default.fileExists(atPath: files.url(of: second, site: "siege", folder: folder).path), "fichier retiré")
        try files.moveFolder(folder, from: "siege", to: "laval")
        try expect(FileManager.default.fileExists(atPath: files.url(of: first, site: "laval", folder: folder).path), "dossier déplacé avec l'appareil")
        try expect(!FileManager.default.fileExists(atPath: files.folderURL(site: "siege", folder: folder).path), "plus au Siège")
        try files.removeFolder(site: "laval", folder: folder)
        try expect(!FileManager.default.fileExists(atPath: files.folderURL(site: "laval", folder: folder).path), "dossier retiré")
        try expectEqual(InvAttachmentFiles(base: base, useTrash: false).url(of: InvAttachment(fileName: "x", storedName: "../../etc", size: 0, added: p0),
                                                                        site: "s", folder: "f").lastPathComponent, "-..-etc", "nom sûr")
    }

    suite.add("Inventaire phase 3 : dossier de pièces jointes d'un site supprimé ou adopté") {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-pj-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = InvAttachmentFiles(base: base, useTrash: false)
        let source = base.appendingPathComponent("source/contrat.pdf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("contrat".utf8).write(to: source)
        let piece = try files.add(source, site: "aucun-site", folder: "Imprimante-1", at: p0)
        try files.moveSite(from: "aucun-site", to: "nouveau")
        try expect(FileManager.default.fileExists(atPath: files.url(of: piece, site: "nouveau", folder: "Imprimante-1").path), "suit le nouveau site")
        try expect(!FileManager.default.fileExists(atPath: files.siteURL("aucun-site").path), "plus aux plages libres")
        // Arrivée déjà occupée : rien n'est écrasé.
        _ = try files.add(source, site: "aucun-site", folder: "Imprimante-1", at: p0)
        _ = try files.add(source, site: "aucun-site", folder: "Camera-2", at: p0)
        try files.moveSite(from: "aucun-site", to: "nouveau")
        try expect(FileManager.default.fileExists(atPath: files.folderURL(site: "nouveau", folder: "Camera-2").path), "dossier libre déplacé")
        try expect(FileManager.default.fileExists(atPath: files.folderURL(site: "aucun-site", folder: "Imprimante-1").path), "homonyme laissé au départ")
        try files.trashSite("nouveau")
        try expect(!FileManager.default.fileExists(atPath: files.siteURL("nouveau").path), "site supprimé : dossier retiré")
        try files.trashSite("inexistant")
    }

    suite.add("Inventaire phase 3 : brouillon de la fiche posé sur une version modifiée entre-temps") {
        let base = InvAnnotations(customName: "Imprimante", location: "Accueil")
        var draft = base
        draft.tags = ["Stock"]
        var latest = base
        latest.customName = "Imprimante quai 2"
        latest.location = "Quai 2"
        let merged = draft.rebased(from: base, onto: latest)
        try expectEqual(merged.customName, "Imprimante quai 2", "nom changé par « Modifier… » gardé")
        try expectEqual(merged.location, "Quai 2", "local gardé")
        try expectEqual(merged.tags, ["Stock"], "étiquette du brouillon appliquée")
    }

    suite.add("Inventaire phase 3 : fusion de deux fiches qui ont chacune leurs pièces jointes") {
        var store = InventoryStore()
        store.merge([device("10.0.0.2", m1, host: "SW-CORE-01"), device("10.0.0.3", m2, host: "SW-2")], at: p0)
        let keep = InventoryStore.key(mac: MACAddress(m1)!)
        let other = InventoryStore.key(mac: MACAddress(m2)!)
        let a = InvAttachment(fileName: "a.pdf", storedName: "a.pdf", size: 1, added: p0)
        let b = InvAttachment(fileName: "b.pdf", storedName: "b.pdf", size: 1, added: p0)
        store.addAttachment(a, folder: "dossier-A", to: keep)
        store.addAttachment(b, folder: "dossier-B", to: other)
        store.absorb(other, into: keep, at: p0)
        let record = store.record(keep)!
        try expectEqual(record.attachmentList.map(\.fileName), ["a.pdf", "b.pdf"], "aucune pièce perdue")
        try expectEqual(record.folder(of: record.attachmentList[0]), "dossier-A", "pièce gardée dans son dossier")
        try expectEqual(record.folder(of: record.attachmentList[1]), "dossier-B", "pièce absorbée dans son dossier d'origine")
        try expectEqual(record.attachmentFolders, ["dossier-A", "dossier-B"], "deux dossiers à déplacer ou retirer")
    }

    suite.add("Inventaire phase 3 : migration sans perte d'un inventaire de la 0.18") {
        // Fichier tel qu'écrit par la 0.18.0 (ni réglages, ni archives, ni champs de la 0.20.0).
        let old = """
        {"events":[{"baseline":true,"date":"2026-08-06T12:00:00Z","detail":"10.0.0.10","id":"6B1D0C52-6C0C-4C4B-9F32-1D5D7D1E0001",\
        "ip":"10.0.0.10","key":"mac:94:dd:f8:18:15:7d","kind":"nouveau","severity":"info","status":"aTraiter","title":"Première détection"}],\
        "exclusions":{"mac:5c:f9:38:02:7a:41":{"date":"2026-09-01T12:00:00Z","ip":"10.0.0.20","key":"mac:5c:f9:38:02:7a:41",\
        "mac":"5C:F9:38:02:7A:41","name":"Téléphone invité"}},"lastMerge":"2026-09-02T12:00:00Z",\
        "records":{"mac:94:dd:f8:18:15:7d":{"annotations":{"assetNumber":"INV-00412","customName":"Imprimante accueil",\
        "isFavorite":true,"location":"2e étage","notes":"Firmware 1.07","owner":"Réception","tags":["Imprimante"],"wallJack":"P2-14"},\
        "conflictWith":[],"detectedType":"imprimante","firstSeen":"2026-08-06T12:00:00Z","hostname":"BRW94DDF8",\
        "ip":"10.0.0.10","ipHistory":[{"from":"2026-08-06T12:00:00Z","ip":"10.0.0.10"}],"isImported":false,"isOnline":true,\
        "key":"mac:94:dd:f8:18:15:7d","lastSeen":"2026-09-02T12:00:00Z","mac":"94:DD:F8:18:15:7D","openPorts":[80,9100],\
        "portHistory":[],"switchName":"SW-ETG2-01","switchPort":"1/14","vendor":"Brother"}},"snapshots":[],"version":1}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-migration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(old.utf8).write(to: url)
        let store = try InventoryStore.load(from: url)
        let key = "mac:94:dd:f8:18:15:7d"
        let record = try expectRecord(store, key)
        try expectEqual(record.displayName, "Imprimante accueil", "nom")
        try expectEqual(record.annotations.assetNumber, "INV-00412", "n° d'actif")
        try expectEqual(record.annotations.wallJack, "P2-14", "prise")
        try expect(record.annotations.isFavorite, "favori")
        try expectEqual(record.openPorts, [80, 9100], "ports")
        try expect(record.manual == nil && record.attachments == nil && record.annotations.hardware == nil
                   && record.annotations.customVendor == nil, "nouveaux champs vides")
        try expectEqual(record.vendorLabel, "Brother", "fabricant du scan")
        try expect(store.autoAdd, "ajout automatique activé par défaut")
        try expectEqual(store.archivedCount, 0, "aucune archive")
        try expectEqual(store.excluded.map(\.name), ["Téléphone invité"], "exclusion gardée")
        try expectEqual(store.events.count, 1, "événement gardé")

        // Réécrit puis relu : identique ; sans réglages ni archives, aucune clé nouvelle n'est écrite.
        try store.save(to: url)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try expect(!text.contains("\"settings\"") && !text.contains("\"archive\"") && !text.contains("\"manual\""),
                   "fichier sans clé nouvelle")
        let again = try InventoryStore.load(from: url)
        try expectEqual(again.record(key), record, "fiche identique")
        try expectEqual(again.events, store.events, "événements identiques")

        // Avec les nouveautés : réglages, archive, garantie, pièce jointe et fiche à la main relus à l'identique.
        var richer = again
        richer.setAutoAdd(false)
        var notes = record.annotations
        notes.hardware = InvHardware(purchaseDate: day("2023-11-20"), warrantyEnd: day("2026-11-28"), supplier: "CDW",
                                     serialNumber: "E78123K4N", price: 349)
        richer.setAnnotations(notes, for: key, at: p0)
        richer.addAttachment(InvAttachment(fileName: "Contrat.pdf", storedName: "Contrat.pdf", size: 1024, added: p0),
                             folder: "Imprimante-accueil-1A2B3C4D", to: key)
        let manual = try richer.addManual(InvManualDraft(name: "Imprimante d’étiquettes", tags: ["Stock"]), at: p0)
        richer.merge([device("10.0.0.30", m3, host: "vieux")], at: p0)
        richer.setAutoAdd(true)
        richer.merge([device("10.0.0.30", m3, host: "vieux")], at: p0.addingTimeInterval(10))
        richer.removeRecords([InventoryStore.key(mac: MACAddress(m3)!)], exclude: false, archive: true, at: p0.addingTimeInterval(20))
        richer.setAutoAdd(false)
        try richer.save(to: url)
        let reread = try InventoryStore.load(from: url)
        try expect(!reread.autoAdd, "réglage relu")
        try expectEqual(reread.archivedCount, 1, "archive relue")
        try expectEqual(reread.record(key)?.annotations.hardware?.serialNumber, "E78123K4N", "garantie relue")
        try expectEqual(reread.record(key)?.attachmentList.map(\.fileName), ["Contrat.pdf"], "pièce jointe relue")
        try expect(reread.record(manual)?.isAwaitingScan == true, "fiche à la main relue")
    }
}

private func expectRecord(_ store: InventoryStore, _ key: String, file: String = #fileID, line: Int = #line) throws -> InvRecord {
    guard let record = store.record(key) else {
        throw TestFailure(message: "fiche \(key) absente", file: file, line: line)
    }
    return record
}
