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

    /// Fusion en attente faite tout de suite (dans le site de ses appareils), puis enregistrement.
    func flushAndSave() {
        pending?.cancel()
        pending = nil
        if let waiting = pendingDevices {
            pendingDevices = nil
            ingest(waiting.devices, site: waiting.site)
        }
        save()
    }

    /// Charge l'inventaire d'un autre site : celui du site quitté est d'abord enregistré (sauf
    /// `discardCurrent` : site supprimé). La fiche ouverte et les types de session sont oubliés.
    func switchSite(to key: String, url newURL: URL?, demoStore: InventoryStore?, discardCurrent: Bool = false) {
        if discardCurrent {
            pending?.cancel()
            pending = nil
            pendingDevices = nil
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
        siteKey = key
        url = newURL
        save()
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

    private func save() {
        guard !isEphemeral, let url else { return }
        do {
            try store.save(to: url)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
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
        let loaded = (try? InventoryStore.load(from: fileURL)) ?? InventoryStore()
        readCache[key] = (date, loaded)
        return loaded
    }

    /// Modifie l'inventaire d'UN site, et lui seul : le site actif en mémoire (puis enregistré),
    /// un autre site dans son fichier (lu juste avant, écrit juste après).
    @discardableResult
    func mutate<T>(site key: String, _ body: (inout InventoryStore) -> T) -> T {
        if key == siteKey {
            let result = body(&store)
            save()
            return result
        }
        var other: InventoryStore
        if isEphemeral {
            other = inventory(for: key)
        } else if let fileURL = SiteModel.shared.inventoryURL(for: key) {
            do {
                other = try InventoryStore.load(from: fileURL)
            } catch {
                // Fichier illisible : on n'écrit rien par-dessus.
                NSLog("NetScope : inventaire du site %@ illisible, rien n’est modifié : %@", key, error.localizedDescription)
                var empty = InventoryStore()
                return body(&empty)
            }
        } else {
            other = InventoryStore()
        }
        objectWillChange.send()
        let result = body(&other)
        if isEphemeral {
            demoStores[key] = other
        } else if let fileURL = SiteModel.shared.inventoryURL(for: key) {
            do {
                try other.save(to: fileURL)
            } catch {
                NSLog("NetScope : enregistrement impossible de %@ : %@", fileURL.path, error.localizedDescription)
            }
            readCache[key] = nil
        }
        SiteModel.shared.setInventoryCount(other.count, for: key)
        return result
    }

    // MARK: Suppression (plusieurs appareils, un ou plusieurs sites)

    /// Ce qu'une suppression a retiré dans chaque site, pour « Annuler ».
    struct Removal {
        var parts: [(site: String, removal: InvRemoval)]
        var count: Int { parts.reduce(0) { $0 + $1.removal.count } }
    }

    /// Supprime les appareils désignés par leurs identifiants composés (« site|fiche ») : chaque
    /// site n'est touché que pour ses propres fiches. `exclude` : les appareils ne sont plus suivis.
    func remove(_ ids: [String], exclude: Bool) -> Removal {
        var parts: [(String, InvRemoval)] = []
        for group in SiteScope.grouped(ids) {
            let removal = mutate(site: group.site) { $0.removeRecords(group.keys, exclude: exclude) }
            if !removal.isEmpty { parts.append((group.site, removal)) }
            if group.site == siteKey, let selected = selectedKey, group.keys.contains(selected) { selectedKey = nil }
        }
        return Removal(parts: parts)
    }

    /// Annule une suppression, site par site.
    func restore(_ removal: Removal) {
        for part in removal.parts { mutate(site: part.site) { $0.restore(part.removal) } }
    }

    /// « Suivre de nouveau » un appareil exclu d'un site.
    func include(_ key: String, site: String) {
        mutate(site: site) { $0.include(key) }
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
            let rows = try InvCSV.parse(text)
            let result = store.importRows(rows)
            save()
            return "Import CSV : \(result.created) fiche\(result.created > 1 ? "s" : "") créée\(result.created > 1 ? "s" : ""), "
                + "\(result.updated) complétée\(result.updated > 1 ? "s" : ""), \(result.skipped) inchangée\(result.skipped > 1 ? "s" : "")"
        } catch {
            return "Import impossible : \(error.localizedDescription)"
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
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
