import Foundation
import NetScopeCore
import SwiftUI

/// Inventaire permanent partagé par les écrans Inventaire, Analyse et Carte du réseau.
/// Il se nourrit de `AppState.devices` : chaque fin de scan est fusionnée dans `InventoryStore`.
/// En démonstration ou pendant les captures, rien n'est lu ni écrit sur le disque.
@MainActor
final class InvModel: ObservableObject {
    static let shared = InvModel()

    @Published private(set) var store: InventoryStore
    /// Fiche ouverte dans l'écran Inventaire.
    @Published var selectedKey: String?
    /// Site de cette fiche (nil : site actif) : « Voir » depuis l'Analyse d'un autre site.
    @Published var selectedSite: String?
    /// Message bref affiché sous la barre d'outils (« Fiche enregistrée »).
    @Published var toast: String?
    /// Note 10 : le message porte un bouton « Annuler » (dernier retrait, déplacement).
    @Published var toastUndo = false
    /// « Voir les archives » (Réglages) : l'écran Inventaire s'ouvre sur la vue « Archivés ».
    @Published var requestedArchives = false
    /// Types choisis à la main pour des appareils sans MAC et encore sans fiche, par IP, pour cette
    /// session seulement (note 20 ; voir Shared/DeviceTypeMenu.swift).
    @Published var sessionTypes: [String: DeviceType] = [:]

    let isEphemeral: Bool
    /// Inventaire du site actif (note 28 : un fichier par site, sites/<id>/inventory.json).
    private var url: URL?
    /// Site dont l'inventaire est chargé (`SiteFiles.key`).
    private(set) var siteKey: String
    /// Démonstration : inventaires des autres sites, gardés en mémoire.
    private var demoStores: [String: InventoryStore] = [:]
    private var lastSignature: Int?
    private var pending: Task<Void, Never>?
    /// Appareils en attente de fusion et site auquel ils appartiennent.
    private var pendingDevices: (devices: [Device], site: String)?
    private var toastTask: Task<Void, Never>?
    /// Suppressions de la session, par site : les appareils du Scanner vus avant la suppression ne
    /// recréent pas la fiche (`InvRemoval.holds`) ; un scan qui les revoit les remet.
    var held: [String: [InvRemoval]] = [:]
    /// Renommages de site (plages libres enregistrées comme site), pour qu'une annulation
    /// enregistrée avant aille au nouveau site : (génération, ancienne clé, nouvelle clé).
    private var renames: [(generation: Int, from: String, to: String)] = []
    private var generation = 0
    /// Autres sites dont l'inventaire est illisible (affichés vides, avec un message).
    private(set) var unreadableSites: Set<String> = []
    /// Note 36 : écritures différées et regroupées, sur une file de fond (toujours atomiques).
    private let writer = InventoryWriter(onError: { url, error in
        NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
    })

    init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        let sites = SiteModel.shared
        siteKey = sites.activeKey
        url = isEphemeral ? nil : sites.activeInventoryURL
        store = url.map(Self.load) ?? InventoryStore()
    }

    /// Lit un inventaire ; un fichier illisible est mis de côté plutôt qu'écrasé.
    private static func load(_ url: URL) -> InventoryStore {
        do {
            return try InventoryStore.load(from: url)
        } catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("NetScope : inventaire illisible, mis de côté dans %@ : %@", aside.path, error.localizedDescription)
            return InventoryStore()
        }
    }

    // MARK: Sites (note 28)

    /// Fusion en attente faite tout de suite (dans le site de ses appareils), puis enregistrement
    /// immédiat (changement de site, fermeture de NetScope).
    func flushAndSave() {
        pending?.cancel()
        pending = nil
        if let waiting = pendingDevices {
            pendingDevices = nil
            ingest(waiting.devices, site: waiting.site)
        }
        save()
        writer.flush()
    }

    /// Écrit tout de suite les enregistrements différés (sauvegarde, dossier de site déplacé).
    func flushPendingWrites() {
        writer.flush()
    }

    /// Charge l'inventaire d'un autre site : celui du site quitté est d'abord enregistré (sauf
    /// `discardCurrent` : site supprimé). La fiche ouverte et les types de session sont oubliés.
    func switchSite(to key: String, url newURL: URL?, demoStore: InventoryStore?, discardCurrent: Bool = false) {
        if discardCurrent {
            pending?.cancel()
            pending = nil
            pendingDevices = nil
            // Site supprimé : une écriture différée ne doit pas recréer son dossier.
            if let url { writer.cancel(url) }
        } else {
            flushAndSave()
        }
        if isEphemeral, !discardCurrent { demoStores[siteKey] = store }
        siteKey = key
        url = newURL
        if isEphemeral {
            store = demoStores[key] ?? demoStore ?? InventoryStore()
        } else {
            store = newURL.map(Self.load) ?? InventoryStore()
        }
        selectedKey = nil
        sessionTypes = [:]
        lastSignature = nil
    }

    /// Les plages libres deviennent un site : même inventaire, nouveau fichier.
    func renameSite(to key: String, url newURL: URL?) {
        pending?.cancel()
        pending = nil
        if let waiting = pendingDevices {
            pendingDevices = nil
            ingest(waiting.devices, site: waiting.site, saving: false)
        }
        // Une écriture différée vers l'ancien fichier part d'abord (SiteModel l'a déjà faite avant de
        // déplacer le dossier) ; la suite va au nouveau fichier.
        writer.flush()
        renames.append((generation, siteKey, key))
        generation += 1
        if let kept = held.removeValue(forKey: siteKey) { held[key, default: []] += kept }
        siteKey = key
        url = newURL
        save()
    }

    /// Clé actuelle d'un site désigné à la génération donnée (renommages appliqués depuis).
    private func currentKey(_ key: String, since start: Int) -> String {
        var key = key
        for rename in renames where rename.generation >= start && rename.from == key { key = rename.to }
        return key
    }

    /// Appareils rechargés avec leur site : ils sont déjà dans son inventaire.
    func markIngested(_ devices: [Device]) {
        lastSignature = devices.isEmpty ? nil : Self.signature(devices)
    }

    // MARK: Fusion des scans

    /// Fusionne les appareils de l'état partagé ; `immediately` false : attend la fin du scan
    /// (1,5 s sans nouveau résultat) avant de fusionner.
    func observe(_ devices: [Device], immediately: Bool) {
        pending?.cancel()
        // Le site des appareils est retenu dès maintenant : la fusion va toujours au site du scan.
        let site = siteKey
        if immediately {
            pendingDevices = nil
            ingest(devices, site: site)
            return
        }
        pendingDevices = (devices, site)
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingDevices = nil
            self.ingest(devices, site: site)
        }
    }

    private func ingest(_ devices: [Device], site: String, saving: Bool = true, at date: Date = Date()) {
        guard !devices.isEmpty else { return }
        // Site changé entre-temps (le changement de site fusionne d'abord) : jamais dans
        // l'inventaire d'un autre site.
        guard site == siteKey else {
            NSLog("NetScope : fusion ignorée, appareils d’un autre site (%@)", site)
            return
        }
        let signature = Self.signature(devices)
        guard signature != lastSignature else { return }
        lastSignature = signature
        // Appareils supprimés pendant la session et pas revus depuis : la fiche ne revient pas.
        let holds = held[site] ?? []
        let devices = holds.isEmpty ? devices : devices.filter { device in !holds.contains { $0.holds(device) } }
        if isEphemeral && store.isEmpty && Launcher.isDemo && siteKey == SitesDemo.siegeKey {
            InvDemo.seed(&store, devices: devices, now: date)
        } else {
            let produced = store.merge(devices, at: date)
            // Conflit d'adresse IP relevé par la fusion : événement commun (notification, autres canaux).
            for event in produced where event.kind == .conflitIP && !event.baseline {
                NetScopeEventCenter.shared.publish(NetScopeEvent(
                    id: "conflit-" + event.id.uuidString, kind: .ipConflict, title: event.title, detail: event.detail,
                    date: event.date, link: .device(event.ip.description), source: "conflit-\(event.ip)"))
            }
        }
        if saving { save() }
        // Note 60 : lectures SNMP d'appareils qui n'avaient pas encore de fiche.
        InvHardwareFeed.shared.inventoryMerged(site: site)
    }

    /// Empreinte des champs observés (un nom personnalisé changé ailleurs ne relance pas de fusion).
    private static func signature(_ devices: [Device]) -> Int {
        var hasher = Hasher()
        for device in devices {
            hasher.combine(device.ip)
            hasher.combine(device.mac)
            hasher.combine(device.isOnline)
            hasher.combine(device.hostname)
            hasher.combine(device.switchName)
            hasher.combine(device.switchPort)
            hasher.combine(device.openPorts)
            hasher.combine(device.lastSeen)
        }
        return hasher.finalize()
    }

    /// Enregistrement différé et regroupé (note 36) : l'inventaire est écrit sur une file de fond
    /// moins d'une seconde après le dernier changement.
    private func save() {
        guard !isEphemeral, let url else { return }
        writer.schedule(store, to: url)
    }

    // MARK: Inventaires des autres sites (lecture et écriture ciblée)

    /// Inventaires des autres sites lus depuis leur fichier, avec la date du fichier lu.
    private var readCache: [String: (date: Date?, store: InventoryStore)] = [:]

    /// Inventaire d'un site, pour l'affichage : celui du site actif en direct ; un autre site est
    /// lu depuis sites/<id>/inventory.json (relu seulement si le fichier a changé), jamais rechargé
    /// comme site actif. En démonstration : les inventaires gardés en mémoire.
    func inventory(for key: String) -> InventoryStore {
        if key == siteKey { return store }
        if isEphemeral {
            if let kept = demoStores[key] { return kept }
            let demo = SitesDemo.inventory(for: key) ?? InventoryStore()
            demoStores[key] = demo
            return demo
        }
        guard let fileURL = SiteModel.shared.inventoryURL(for: key) else { return InventoryStore() }
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if let cached = readCache[key], cached.date == date { return cached.store }
        let loaded: InventoryStore
        do {
            loaded = try InventoryStore.load(from: fileURL)
            unreadableSites.remove(key)
        } catch {
            NSLog("NetScope : inventaire du site %@ illisible : %@", key, error.localizedDescription)
            loaded = InventoryStore()
            unreadableSites.insert(key)
        }
        readCache[key] = (date, loaded)
        return loaded
    }

    /// Note 36 : lit en parallèle les inventaires des autres sites qui ne sont pas encore en mémoire
    /// (ou dont le fichier a changé), avant que l'écran les demande un par un (« Tous les sites » :
    /// 20 fichiers lus ensemble plutôt qu'à la suite).
    func prefetch(_ keys: [String]) {
        guard !isEphemeral else { return }
        var wanted: [(key: String, url: URL, date: Date?)] = []
        for key in keys where key != siteKey {
            guard let fileURL = SiteModel.shared.inventoryURL(for: key) else { continue }
            let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            if let cached = readCache[key], cached.date == date { continue }
            wanted.append((key, fileURL, date))
        }
        guard wanted.count > 1 else { return }
        let results = InventoryStore.loadAll(wanted.map(\.url))
        for (item, result) in zip(wanted, results) {
            switch result {
            case .success(let loaded):
                unreadableSites.remove(item.key)
                readCache[item.key] = (item.date, loaded)
            case .failure(let error):
                NSLog("NetScope : inventaire du site %@ illisible : %@", item.key, error.localizedDescription)
                unreadableSites.insert(item.key)
                readCache[item.key] = (item.date, InventoryStore())
            }
        }
    }

    /// Le site existe-t-il encore (site actif, plages libres, ou site de la liste) ?
    private func siteExists(_ key: String) -> Bool {
        key == siteKey || key == SiteFiles.noSiteKey || SiteModel.shared.site(forKey: key) != nil
    }

    /// Modifie l'inventaire d'UN site, et lui seul : le site actif en mémoire (puis enregistré),
    /// un autre site dans son fichier (lu juste avant, écrit juste après). nil, sans rien changer,
    /// si le site n'existe plus, si son fichier manque ou est illisible, ou si l'écriture échoue :
    /// un message le dit.
    @discardableResult
    func mutate<T>(site key: String, _ body: (inout InventoryStore) -> T) -> T? {
        if key == siteKey {
            let result = body(&store)
            save()
            return result
        }
        let name = SiteModel.shared.name(forKey: key)
        var other: InventoryStore
        if isEphemeral {
            other = inventory(for: key)
        } else {
            // Site supprimé, ou plages libres devenues un site : aucun fichier recréé à sa place.
            guard siteExists(key), let fileURL = SiteModel.shared.inventoryURL(for: key),
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                show("Inventaire introuvable (site supprimé ou déplacé)\u{00A0}: rien n’est modifié")
                return nil
            }
            do {
                writer.flush()
                other = try InventoryStore.load(from: fileURL)
            } catch {
                // Fichier illisible : on n'écrit rien par-dessus.
                NSLog("NetScope : inventaire du site %@ illisible, rien n’est modifié : %@", key, error.localizedDescription)
                show("Inventaire de «\u{00A0}\(name)\u{00A0}» illisible\u{00A0}: rien n’est modifié")
                return nil
            }
        }
        var changed = other
        let result = body(&changed)
        if !isEphemeral, let fileURL = SiteModel.shared.inventoryURL(for: key) {
            do {
                try changed.save(to: fileURL)
            } catch {
                NSLog("NetScope : enregistrement impossible de %@ : %@", fileURL.path, error.localizedDescription)
                show("Enregistrement impossible de l’inventaire de «\u{00A0}\(name)\u{00A0}»\u{00A0}: rien n’est modifié")
                return nil
            }
        }
        objectWillChange.send()
        if isEphemeral { demoStores[key] = changed } else { readCache[key] = nil }
        SiteModel.shared.setInventoryCount(changed.count, for: key)
        return result
    }

    // MARK: Suppression (plusieurs appareils, un ou plusieurs sites)

    /// Ce qu'une suppression a retiré dans chaque site, pour « Annuler ».
    struct Removal {
        var parts: [(site: String, removal: InvRemoval)]
        /// Génération des clés de site (un renommage ultérieur est suivi).
        var generation: Int
        var count: Int { parts.reduce(0) { $0 + $1.removal.count } }
    }

    /// Supprime les appareils désignés par leurs identifiants composés (« site|fiche ») : chaque
    /// site n'est touché que pour ses propres fiches. `exclude` : les appareils ne sont plus suivis ;
    /// `archive` (note 10) : ils vont dans les archives de leur site au lieu d'être supprimés.
    func remove(_ ids: [String], exclude: Bool, archive: Bool = false) -> Removal {
        var parts: [(String, InvRemoval)] = []
        for group in SiteScope.grouped(ids) {
            let site = group.site
            guard let removal = mutate(site: site, { $0.removeRecords(group.keys, exclude: exclude, archive: archive) }) else { continue }
            if !removal.isEmpty {
                parts.append((site, removal))
                if !exclude { held[site, default: []].append(removal) }
            }
            if site == siteKey, let selected = selectedKey, group.keys.contains(selected) { selectedKey = nil }
        }
        return Removal(parts: parts, generation: generation)
    }

    /// Annule une suppression, site par site ; renvoie ce qui a vraiment été remis.
    func restore(_ removal: Removal) -> InvRestoreResult {
        var total = InvRestoreResult()
        for part in removal.parts {
            let site = currentKey(part.site, since: removal.generation)
            held[site]?.removeAll { $0 == part.removal }
            guard let result = mutate(site: site, { $0.restore(part.removal) }) else { continue }
            total.restored += result.restored
            total.merged += result.merged
        }
        return total
    }

    /// Identifiants « site|fiche » d'une suppression, avec les clés de site actuelles (Rétablir
    /// après « Enregistrer comme site »).
    func currentIDs(_ ids: [String], since removal: Removal) -> [String] {
        ids.map { id in
            guard let parts = SiteScope.split(id) else { return id }
            return SiteScope.id(site: currentKey(parts.site, since: removal.generation), key: parts.key)
        }
    }

    /// « Suivre de nouveau » un appareil exclu d'un site.
    /// Faux si l'inventaire du site n'a pas pu être modifié (un message le dit déjà).
    @discardableResult
    func include(_ key: String, site: String) -> Bool {
        mutate(site: site) { $0.include(key) } != nil
    }

    // MARK: Fiches

    func record(_ key: String?) -> InvRecord? {
        key.flatMap { store.record($0) }
    }

    func setAnnotations(_ annotations: InvAnnotations, for key: String, site: String? = nil) {
        mutate(site: site ?? siteKey) { $0.setAnnotations(annotations, for: key) }
    }

    /// Retient le type choisi à la main (nil : type détecté) ; `all` : appareils du scan, fusionnés
    /// d'abord pour que chaque fiche existe. Renvoie le nombre d'appareils sans fiche (choix de session).
    @discardableResult
    func setManualType(_ type: DeviceType?, for devices: [Device], all: [Device]) -> Int {
        observe(all, immediately: true)
        var sessionOnly = 0
        for device in devices {
            if store.setManualType(type, for: device) {
                // La fiche fait foi : un ancien choix de session ne doit plus la masquer.
                if device.mac == nil { sessionTypes[device.id] = nil }
            } else {
                sessionTypes[device.id] = type
                sessionOnly += 1
            }
        }
        save()
        return sessionOnly
    }

    func toggleFavorite(_ key: String, site: String? = nil) {
        mutate(site: site ?? siteKey) { store in
            guard let record = store.record(key) else { return }
            store.setFavorite(!record.annotations.isFavorite, for: key)
        }
    }

    func setFavorite(_ keys: [String]) {
        for key in keys { store.setFavorite(true, for: key) }
        save()
    }

    /// Alerte signalée par un outil ; faux si elle était déjà à traiter.
    @discardableResult
    func addAlert(_ event: InvEvent) -> Bool {
        let added = store.addAlert(event)
        if added { save() }
        return added
    }

    func setEventStatus(_ status: InvEventStatus, for id: UUID, site: String? = nil) {
        mutate(site: site ?? siteKey) { $0.setEventStatus(status, for: id) }
    }

    func absorb(_ duplicate: InvDuplicate, site: String? = nil) {
        let site = site ?? siteKey
        mutate(site: site) { $0.absorb(duplicate.absorb, into: duplicate.keep) }
        if site == siteKey, selectedKey == duplicate.absorb { selectedKey = duplicate.keep }
    }

    /// Importe un CSV ; renvoie le compte rendu à afficher.
    func importCSV(_ text: String) -> String {
        do {
            let parsed = InvCSV.rows(try InvCSV.parse(text), forSite: SiteModel.shared.activeName)
            let result = store.importRows(parsed.rows)
            save()
            let others = parsed.otherSites
            let skippedSites = others == 0 ? ""
                : " · \(others) ligne\(others > 1 ? "s" : "") d’autres sites écartée\(others > 1 ? "s" : "") (seul le site actif est importé)"
            return "Import CSV : \(result.created) fiche\(result.created > 1 ? "s" : "") créée\(result.created > 1 ? "s" : ""), "
                + "\(result.updated) complétée\(result.updated > 1 ? "s" : ""), \(result.skipped) inchangée\(result.skipped > 1 ? "s" : "")" + skippedSites
        } catch {
            return "Import impossible : \(error.localizedDescription)"
        }
    }

    func show(_ message: String, undo: Bool = false) {
        toast = message
        toastUndo = undo
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastUndo = false
        }
    }

    // MARK: Alertes

    /// Alertes (hors référence) depuis `since`, de la plus récente à la plus ancienne.
    func alerts(since: Date) -> [InvEvent] {
        store.events.filter { $0.isAlert && $0.date >= since }.sorted { $0.date > $1.date }
    }

    /// Alertes critiques ou importantes à traiter sur 24 h (compteur de la barre latérale, Analyse).
    var pendingAlertCount: Int {
        alerts(since: Date().addingTimeInterval(-86_400))
            .filter { $0.status == .aTraiter && $0.severity != .info }.count
    }

    func updateBadge(_ state: AppState) {
        let count = pendingAlertCount
        if state.sidebarBadges[.analyse] != (count > 0 ? count : nil) {
            state.sidebarBadges[.analyse] = count > 0 ? count : nil
        }
    }
}

extension View {
    /// Branche un écran sur l'inventaire : fusion à l'affichage, puis après chaque scan.
    @MainActor
    func feedsInventory(_ state: AppState) -> some View {
        let model = InvModel.shared
        return onAppear {
            model.observe(state.devices, immediately: true)
            model.updateBadge(state)
        }
        .onChange(of: state.devices) { _, devices in
            model.observe(devices, immediately: false)
        }
        // Le nombre d'événements plafonne à `maxEvents` et ne bouge pas quand une alerte est acceptée :
        // on suit directement le compteur.
        .onChange(of: model.pendingAlertCount) { _, _ in
            model.updateBadge(state)
        }
    }
}
