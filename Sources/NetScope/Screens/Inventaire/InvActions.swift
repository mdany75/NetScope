import AppKit
import NetScopeCore
import SwiftUI

// Note 10 (Inventaire, phase 3) : actions de l'inventaire sur un ou plusieurs sites. Tout passe par
// `mutate(site:)` : seul l'inventaire du site concerné est lu et écrit. En démonstration ou pendant
// les captures, rien n'est écrit sur le disque (ni fiche, ni pièce jointe).

extension InvModel {
    /// Pièces jointes : ~/Library/Application Support/NetScope/Inventaire/<site>/<appareil>/.
    var attachmentFiles: InvAttachmentFiles { .standard }

    // MARK: Ajout à la main

    /// Crée une fiche « Ajouté à la main » dans l'inventaire du site ; renvoie sa clé, ou l'erreur à afficher.
    func addManual(_ draft: InvManualDraft, site: String) -> Result<String, Error> {
        var failure: Error?
        let outcome = mutate(site: site) { store -> String? in
            do { return try store.addManual(draft) } catch { failure = error; return nil }
        }
        // Inventaire du site introuvable ou illisible : le dire dans la feuille, pas dans un toast caché.
        guard let outcome else { return .failure(InvManualError.siteUnavailable(name: SiteModel.shared.name(forKey: site))) }
        if let key = outcome { return .success(key) }
        return .failure(failure ?? InvManualError.notEditable)
    }

    func updateManual(_ key: String, draft: InvManualDraft, site: String) -> Error? {
        var failure: Error?
        let done = mutate(site: site) { store -> Bool in
            do { try store.updateManual(key, with: draft); return true } catch { failure = error; return false }
        }
        guard let done else { return InvManualError.siteUnavailable(name: SiteModel.shared.name(forKey: site)) }
        return done ? nil : (failure ?? InvManualError.notEditable)
    }

    /// Duplique une fiche en appareil ajouté à la main ; renvoie la clé de la copie.
    func duplicate(_ key: String, site: String) -> String? {
        mutate(site: site) { $0.duplicate(key) } ?? nil
    }

    // MARK: Ajout automatique, « Ajouter à l'inventaire »

    func autoAdd(site: String) -> Bool { inventory(for: site).autoAdd }

    /// Faux si l'inventaire du site est introuvable ou illisible (rien n'est changé).
    @discardableResult
    func setAutoAdd(_ on: Bool, site: String) -> Bool {
        guard mutate(site: site, { $0.setAutoAdd(on) }) != nil else { return false }
        show(on ? "Ajout automatique activé\u{00A0}: les prochains scans de «\u{00A0}\(SiteModel.shared.name(forKey: site))\u{00A0}» rempliront l’inventaire"
             : "Ajout automatique désactivé\u{00A0}: «\u{00A0}Ajouter à l’inventaire\u{00A0}» depuis le Scanner (clic droit)")
        return true
    }

    /// Appareils du Scanner (site actif) ajoutés à l'inventaire, même si l'ajout automatique est
    /// désactivé ou s'ils étaient exclus : le choix est explicite.
    @discardableResult
    func addToInventory(_ devices: [Device]) -> InvAddResult {
        let result = mutate(site: siteKey) { $0.addScanned(devices) } ?? InvAddResult()
        // Les appareils retirés pendant la session redeviennent des appareils comme les autres.
        held[siteKey]?.removeAll { removal in devices.contains { removal.holds($0) } }
        var parts: [String] = []
        if result.added > 0 { parts.append("\(result.added) ajouté\(result.added > 1 ? "s" : "")") }
        if result.matched > 0 { parts.append("\(result.matched) rapproché\(result.matched > 1 ? "s" : "") d’une fiche ajoutée à la main") }
        if result.restored > 0 { parts.append("\(result.restored) restauré\(result.restored > 1 ? "s" : "") depuis les archives") }
        if result.already > 0 { parts.append("\(result.already) déjà dans l’inventaire") }
        show("Inventaire de «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}»\u{00A0}: " + (parts.isEmpty ? "rien à ajouter" : parts.joined(separator: ", ")))
        return result
    }

    /// Appareils du Scanner pas encore dans l'inventaire du site actif (ni exclus).
    func notInInventory(_ devices: [Device]) -> [Device] { store.notInInventory(devices) }

    // MARK: Archives

    /// Restaure des appareils archivés (identifiants « site|fiche »).
    func restoreArchived(_ ids: [String]) -> InvRestoreResult {
        var total = InvRestoreResult()
        for group in SiteScope.grouped(ids) {
            guard let result = mutate(site: group.site, { $0.restoreArchived(group.keys) }) else { continue }
            total.restored += result.restored
            total.merged += result.merged
        }
        return total
    }

    /// Supprime définitivement des appareils archivés ; leurs pièces jointes vont à la corbeille
    /// de macOS (récupérables). Renvoie ce qui est retiré, pour « Annuler ».
    func purgeArchived(_ ids: [String]) -> [(site: String, entries: [InvArchiveEntry])] {
        var parts: [(String, [InvArchiveEntry])] = []
        for group in SiteScope.grouped(ids) {
            guard let removed = mutate(site: group.site, { $0.purgeArchived(group.keys) }), !removed.isEmpty else { continue }
            parts.append((group.site, removed))
        }
        return parts
    }

    func putBackArchived(_ parts: [(site: String, entries: [InvArchiveEntry])]) {
        for part in parts { mutate(site: part.site) { $0.putBackArchived(part.entries) } }
    }

    /// Dossier de pièces jointes mis à la corbeille, pour « Annuler ».
    struct TrashedFolder {
        var site: String
        var folder: String
        var url: URL
    }

    /// Pièces jointes d'appareils supprimés pour de bon : à la corbeille de macOS (récupérables,
    /// remises par « Annuler ») ; jamais en démonstration.
    func discardAttachments(of records: [InvRecord], site: String) -> [TrashedFolder] {
        guard !isEphemeral else { return [] }
        var trashed: [TrashedFolder] = []
        for record in records {
            for folder in record.attachmentFolders {
                do {
                    if let url = try attachmentFiles.trashFolder(site: site, folder: folder) {
                        trashed.append(TrashedFolder(site: site, folder: folder, url: url))
                    }
                } catch {
                    AppLog.shared.error("Inventaire", "Pièces jointes de \(record.displayName) non retirées\u{00A0}: \(error.localizedDescription)")
                }
            }
        }
        return trashed
    }

    func recoverAttachments(_ folders: [TrashedFolder]) {
        for item in folders {
            do {
                try attachmentFiles.recoverFolder(item.url, site: item.site, folder: item.folder)
            } catch {
                show("Pièces jointes restées dans la corbeille\u{00A0}: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Liste d'exclusion

    @discardableResult
    func exclude(mac: MACAddress, name: String, site: String) -> Bool {
        (mutate(site: site) { $0.exclude(mac: mac, name: name) }) == true
    }

    // MARK: Déplacement vers un autre site

    /// Ce qu'un déplacement a fait, pour « Annuler ».
    struct Move {
        var destination: String
        /// Fiches déplacées, par site de départ.
        var moved: [(site: String, keys: [String])]
        var refusals: [(site: String, refusal: InvTransferRefusal)]
        var count: Int { moved.reduce(0) { $0 + $1.keys.count } }
    }

    /// Déplace des fiches (« site|fiche ») vers un autre site. Jamais de fusion : une fiche dont la
    /// MAC (ou la clé) est déjà dans le site d'arrivée reste où elle est, et le compte rendu le dit.
    /// Les pièces jointes suivent l'appareil.
    func move(_ ids: [String], to destination: String) -> Move {
        var result = Move(destination: destination, moved: [], refusals: [])
        let destinationName = SiteModel.shared.name(forKey: destination)
        for group in SiteScope.grouped(ids) where group.site != destination {
            let source = group.site
            let sourceName = SiteModel.shared.name(forKey: source)
            // Refus connus d'avance : ces fiches ne quittent pas leur site.
            let candidates = group.keys.compactMap { inventory(for: source).record($0) }
            let refused = inventory(for: destination).transferRefusals(for: candidates)
            result.refusals += refused.map { (source, $0) }
            let wanted = group.keys.filter { key in !refused.contains { $0.key == key } }
            guard !wanted.isEmpty, let taken = mutate(site: source, { $0.takeForTransfer(wanted) }), !taken.isEmpty else { continue }
            guard let back = mutate(site: destination, { $0.receive(taken, from: sourceName) }) else {
                // Site d'arrivée illisible : tout revient au site de départ.
                mutate(site: source) { $0.giveBack(taken) }
                continue
            }
            if !back.isEmpty {
                mutate(site: source) { $0.giveBack(back) }
                result.refusals += back.records.map { (source, InvTransferRefusal(key: $0.key, name: $0.displayName, reason: "déjà dans «\u{00A0}\(destinationName)\u{00A0}»")) }
            }
            let movedKeys = taken.keys.filter { key in !back.records.contains { $0.key == key } }
            moveAttachments(of: taken.records.filter { movedKeys.contains($0.key) }, from: source, to: destination)
            if source == siteKey, let selected = selectedKey, movedKeys.contains(selected) { selectedKey = nil }
            result.moved.append((source, movedKeys))
        }
        return result
    }

    /// Annule un déplacement : les fiches reviennent dans leur site de départ.
    @discardableResult
    func undoMove(_ move: Move) -> Int {
        var count = 0
        for part in move.moved {
            guard let transfer = mutate(site: move.destination, { $0.undoReceive(part.keys) }), !transfer.isEmpty else { continue }
            mutate(site: part.site) { $0.giveBack(transfer) }
            moveAttachments(of: transfer.records, from: move.destination, to: part.site)
            count += transfer.records.count
        }
        return count
    }

    private func moveAttachments(of records: [InvRecord], from source: String, to destination: String) {
        guard !isEphemeral else { return }
        for record in records {
            for folder in record.attachmentFolders {
                do {
                    try attachmentFiles.moveFolder(folder, from: source, to: destination)
                } catch {
                    AppLog.shared.error("Inventaire", "Pièces jointes de \(record.displayName) non déplacées\u{00A0}: \(error.localizedDescription)")
                    show("Pièces jointes de «\u{00A0}\(record.displayName)\u{00A0}» restées dans l’ancien site\u{00A0}: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Même MAC sur plusieurs sites

    /// MAC vues dans plusieurs sites (tous les sites, pas seulement ceux affichés) : MAC → sites.
    func sharedMACs() -> [MACAddress: [String]] {
        let keys = SiteModel.shared.sortedSites.map { SiteFiles.key(for: $0.id) }
        let all = ([siteKey] + keys.filter { $0 != siteKey })
        prefetch(all)
        return SiteScope.sharedMACs(all.map { SiteInventory(key: $0, name: SiteModel.shared.name(forKey: $0), store: inventory(for: $0)) })
    }

    // MARK: Pièces jointes

    /// Copie des fichiers dans le dossier de l'appareil et les ajoute à sa fiche.
    func attach(_ urls: [URL], to key: String, site: String) {
        guard let record = inventory(for: site).record(key) else { return }
        let folder = record.attachmentFolder ?? InvAttachmentFiles.folderName(for: record)
        var added: [InvAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if isEphemeral {
                // Démonstration : rien n'est copié, la pièce n'est qu'affichée.
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                added.append(InvAttachment(fileName: url.lastPathComponent, storedName: url.lastPathComponent, size: size, added: Date()))
                continue
            }
            do {
                added.append(try attachmentFiles.add(url, site: site, folder: folder))
            } catch {
                show("Pièce jointe non ajoutée\u{00A0}: \(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        guard !added.isEmpty else { return }
        mutate(site: site) { store in
            for attachment in added { store.addAttachment(attachment, folder: folder, to: key) }
        }
        show(added.count > 1 ? "\(added.count) pièces jointes ajoutées" : "Pièce jointe ajoutée\u{00A0}: \(added[0].fileName)"
             + (isEphemeral ? " (démonstration\u{00A0}: fichier non copié)" : ""))
    }

    func open(_ attachment: InvAttachment, of record: InvRecord, site: String) {
        guard !isEphemeral, let folder = record.folder(of: attachment) else {
            show("Démonstration\u{00A0}: «\u{00A0}\(attachment.fileName)\u{00A0}» n’est pas sur ce Mac")
            return
        }
        let url = attachmentFiles.url(of: attachment, site: site, folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else {
            show("Fichier introuvable\u{00A0}: \(attachment.fileName)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealAttachments(of record: InvRecord, site: String) {
        guard !isEphemeral, let folder = record.attachmentFolder ?? record.attachmentFolders.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([attachmentFiles.folderURL(site: site, folder: folder)])
    }

    /// Retire une pièce jointe de la fiche ; le fichier va à la corbeille de macOS.
    func removeAttachment(_ attachment: InvAttachment, of record: InvRecord, site: String) {
        guard mutate(site: site, { $0.removeAttachment(attachment.id, from: record.key) }) != nil else { return }
        if !isEphemeral, let folder = record.folder(of: attachment) {
            do {
                try attachmentFiles.remove(attachment, site: site, folder: folder)
            } catch {
                AppLog.shared.error("Inventaire", "Pièce jointe \(attachment.fileName) non retirée\u{00A0}: \(error.localizedDescription)")
            }
        }
        show("Pièce jointe retirée\u{00A0}: \(attachment.fileName)" + (isEphemeral ? "" : " (dans la corbeille)"))
    }
}
