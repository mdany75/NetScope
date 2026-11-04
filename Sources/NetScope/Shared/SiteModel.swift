import AppKit
import Foundation
import NetScopeCore
import SwiftUI

/// Sites (note 28) : la liste des sites, le site actif et le passage d'un site à l'autre.
///
/// Chaque site a ses plages, ses FortiGate, ses switchs SNMP, ses indices de détection et son
/// PROPRE inventaire (sites/<id>/inventory.json) et ses propres résultats de scan
/// (sites/<id>/resultats.json). Changer de site met de côté les appareils, le bilan des switchs,
/// l'état du scan et les nouveautés du site quitté, recharge ceux du site choisi et son
/// inventaire : Scanner, Carte, Inventaire, Analyse, Switchs, Wi-Fi FortiAP et Rapports ne
/// mélangent jamais deux sites (Device.id est l'IP : la même IP sur deux sites ne fusionne pas).
///
/// En démonstration et pendant les captures, rien n'est lu ni écrit : les sites viennent de
/// SitesDemo. NETSCOPE_SITE=<nom> choisit le site actif des captures.
@MainActor
final class SiteModel: ObservableObject {
    static let shared = SiteModel()

    @Published private(set) var list: SiteList
    /// « Afficher tous les switchs » de Switchs et ports (le temps de la session).
    @Published var showAllSwitches = false
    /// Question en attente pour le Scanner (choix du site détecté, enregistrement des plages).
    @Published var prompt: SitePrompt?

    let isEphemeral: Bool
    let files: SiteFiles?
    private var shelf: SiteResultsShelf
    private var attached = false
    /// État partagé reçu au lancement (enregistrement des résultats à la fermeture).
    private weak var attachedState: AppState?
    /// Message de la migration, montré une fois dans le Scanner.
    private var migrationMessage: String?
    /// Migration ou lecture de sites.json en échec : la liste n'est jamais réécrite (une liste
    /// vide écraserait les sites), jusqu'au prochain lancement.
    private(set) var saveBlocked = false
    /// Le scan en cours a été lancé par « Scanner sans enregistrer » : ses plages ne sont pas
    /// celles du site, rien n'en est appris (MAC de la passerelle).
    private var scanWithoutSaving = false

    init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        if isEphemeral {
            files = nil
            shelf = SiteResultsShelf(files: nil)
            list = arguments.contains("--demo") ? SitesDemo.list() : SiteList()
            return
        }
        let files = SiteFiles.standard
        self.files = files
        shelf = SiteResultsShelf(files: files)
        switch files.readList() {
        case .loaded(let saved):
            list = saved
        case .unreadable:
            // sites.json présent mais illisible : jamais pris pour une première ouverture (la
            // migration l'écraserait). Il est mis de côté et la liste est refaite à partir des
            // dossiers des sites : aucun inventaire n'est perdu.
            let aside = files.setAsideUnreadableList()
            if aside == nil {
                saveBlocked = true
                list = SiteList()
                migrationMessage = "La liste des sites (\(SiteFiles.listName)) est illisible et n’a pas pu être mise de côté\u{00A0}: elle ne sera pas modifiée. Vérifiez le dossier de données de NetScope."
            } else {
                list = files.recoveredList()
                let count = list.sites.count
                migrationMessage = "La liste des sites était illisible (mise de côté\u{00A0}: \(aside!.lastPathComponent)). "
                    + (count == 0 ? "Aucun inventaire de site à reprendre."
                                  : "\(count) site\(count > 1 ? "s" : "") récupéré\(count > 1 ? "s" : "") avec leur inventaire\u{00A0}: renommez-les et refaites leurs plages dans Réglages › Sites.")
            }
        case .missing:
            // Première ouverture de la 0.12.0 : plages, inventaire, noms et FortiGate deviennent
            // ceux de « Site principal » ; l'ancien inventaire est gardé en copie de sécurité.
            let state = StateStore.standard.load()
            do {
                let result = try SiteMigration.migrateIfNeeded(files: files, ranges: state?.ranges ?? AppState.defaultRanges,
                                                               customNames: state?.customNames ?? [:],
                                                               controllers: FortiGateStore.savedControllers())
                list = result?.list ?? SiteList()
                if let result, result.recoveredSites > 0 {
                    let count = result.recoveredSites
                    migrationMessage = "La liste des sites manquait\u{00A0}: \(count) site\(count > 1 ? "s" : "") récupéré\(count > 1 ? "s" : "") avec leur inventaire. Renommez-les et refaites leurs plages dans Réglages › Sites."
                } else if let result, let count = result.migratedRecords {
                    migrationMessage = "Vos plages et votre inventaire (\(count) fiche\(count > 1 ? "s" : "")) sont maintenant ceux du site «\u{00A0}\(SiteMigration.firstSiteName)\u{00A0}». Copie de sécurité\u{00A0}: \(SiteFiles.legacyBackupName)."
                }
            } catch {
                // Rien n'est écrit tant que la migration n'a pas réussi : elle sera refaite au
                // prochain lancement, avec le même site (l'ancien inventaire est toujours là).
                NSLog("NetScope : migration des sites impossible : %@", error.localizedDescription)
                saveBlocked = true
                list = SiteList()
                migrationMessage = "La migration vers les sites a échoué (\(error.localizedDescription)). Votre inventaire n’est pas touché\u{00A0}; elle sera refaite au prochain lancement."
            }
        }
        // Notes d'appareils d'avant les sites encore présentes : elles vont au premier site (ou au site actif).
        if !saveBlocked {
            let target = list.sites.first { $0.name == SiteMigration.firstSiteName }?.id ?? list.activeID
            do {
                try SiteMigration.migrateDeviceNotes(files: files, into: SiteFiles.key(for: target))
            } catch {
                NSLog("NetScope : notes des appareils non reprises : %@", error.localizedDescription)
            }
        }
    }

    // MARK: Lecture

    var sites: [Site] { list.sites }
    var sortedSites: [Site] { list.sortedByName }
    var activeSite: Site? { list.active }
    var activeID: UUID? { list.activeID }
    var activeKey: String { SiteFiles.key(for: list.activeID) }
    /// « Siège », ou « Aucun site » (plages libres).
    var activeName: String { activeSite?.displayName ?? "Aucun site" }

    func site(_ id: UUID) -> Site? { list.site(id) }

    /// Inventaire du site actif (nil en démonstration).
    var activeInventoryURL: URL? { files?.inventoryURL(for: activeKey) }

    func inventoryURL(for key: String) -> URL? { files?.inventoryURL(for: key) }

    /// Fiches d'inventaire d'un site : en direct pour le site actif, sinon le dernier compte connu.
    func inventoryCount(_ site: Site) -> Int {
        site.id == activeID ? InvModel.shared.store.count : (site.inventoryCount ?? 0)
    }

    /// Les plages du Scanner ne sont plus celles du site actif (case cochée mise à part).
    func hasUnsavedRanges(_ state: AppState) -> Bool {
        guard let site = activeSite else { return false }
        return !Site.sameRanges(state.ranges, site.ranges, checks: false)
    }

    /// Autres sites qui ont exactement les mêmes plages que le site actif.
    var activeTwins: [Site] { activeID.map { list.sharingAddresses(with: $0) } ?? [] }

    // MARK: Lancement

    /// Au lancement : résultats du dernier scan du site actif, message de migration.
    func attach(to state: AppState) {
        guard !attached else { return }
        attached = true
        attachedState = state
        var results = shelf.take(activeKey)
        // Les noms personnalisés du site actif les plus récents sont ceux d'etat.json (écrits à
        // chaque changement) ; resultats.json ne l'est qu'en fin de scan et au changement de site.
        results.customNames = state.customNames
        apply(results, to: state)
        if let migrationMessage {
            ScanController.shared.show(migrationMessage, tone: .neutral)
            self.migrationMessage = nil
        }
        RapportModel.shared.siteChanged(activeSite)
    }

    /// Démonstration : site actif choisi par NETSCOPE_SITE (captures), résultats des autres sites préparés.
    func attachDemo(to state: AppState) {
        guard Launcher.isDemo, !attached else { return }
        attached = true
        for (key, results) in SitesDemo.results() { shelf.preload(results, for: key) }
        if let wanted = ProcessInfo.processInfo.environment["NETSCOPE_SITE"]?.lowercased(),
           let site = list.sites.first(where: { $0.displayName.lowercased() == wanted }) ?? list.sites.first(where: { $0.displayName.lowercased().contains(wanted) }),
           site.id != list.activeID {
            activate(site.id, state: state, confirm: false, announce: false)
        } else {
            FortiGateStore.shared.siteChanged(state: state)
        }
        RapportModel.shared.siteChanged(activeSite)
    }

    // MARK: Changer de site

    /// Passe au site donné (nil : aucun site, plages libres). Refusé pendant un scan ; confirmation
    /// si les plages du Scanner ne sont pas enregistrées dans le site quitté.
    func activate(_ id: UUID?, state: AppState, confirm: Bool = true, announce: Bool = true) {
        guard id != list.activeID else { return }
        let scan = ScanController.shared
        if let reason = busyReason() {
            scan.show("\(reason) avant de changer de site.", tone: .warning)
            return
        }
        if confirm, hasUnsavedRanges(state) {
            switch askUnsaved(leaving: activeName) {
            case .save: updateActiveSite(state)
            case .discard: break
            case .cancel: return
            }
        }
        switchSite(to: id, state: state, adoptCurrent: false)
        guard announce else { return }
        scan.show(id == nil ? "Aucun site actif\u{00A0}: plages libres, FortiGate choisie par plage."
                            : "Site «\u{00A0}\(activeName)\u{00A0}»\u{00A0}: plages, inventaire et résultats du site.", tone: .neutral)
    }

    /// Travail en cours sur le réseau du site actif : scan, sonde de ports, interrogation des
    /// switchs, lecture FortiGate. Ses résultats iraient sinon dans le site choisi (note 28).
    private func busyReason() -> String? {
        if ScanController.shared.isBusy { return "Arrêtez le scan ou la sonde de ports" }
        let switches = SwitchStore.shared
        if switches.isPolling || switches.isDiscovering { return "Attendez la fin de l’interrogation des switchs" }
        if FortiGateStore.shared.isBusy { return "Attendez la fin de la lecture des FortiGate" }
        return nil
    }

    /// Mise de côté du site quitté, puis chargement du site choisi.
    private func switchSite(to id: UUID?, state: AppState, adoptCurrent: Bool) {
        let oldKey = activeKey
        let newKey = SiteFiles.key(for: id)
        // 1. Le site quitté : ses résultats de côté, son inventaire enregistré (une fusion en
        //    attente y va d'abord), son nombre de fiches retenu.
        let current = collect(from: state)
        let inventory = InvModel.shared
        if adoptCurrent {
            files?.adoptNoSiteFolder(into: newKey)
            shelf.forget(oldKey)
            shelf.shelve(current, for: newKey)
            inventory.renameSite(to: newKey, url: files?.inventoryURL(for: newKey))
        } else {
            shelf.shelve(current, for: oldKey)
            inventory.flushAndSave()
            if let oldID = list.activeID, let index = list.index(of: oldID) { list.sites[index].inventoryCount = inventory.store.count }
            inventory.switchSite(to: newKey, url: files?.inventoryURL(for: newKey),
                                 demoStore: isEphemeral ? SitesDemo.inventory(for: newKey) : nil)
        }
        // 2. Le site choisi.
        list.activeID = id
        save()
        if !adoptCurrent {
            if let site = activeSite { state.ranges = site.ranges }
            apply(shelf.take(newKey), to: state)
        }
        FortiGateStore.shared.siteChanged(state: state)
        RapportModel.shared.siteChanged(activeSite)
        inventory.updateBadge(state)
        DeviceNotesStore.shared.switchSite(to: newKey, url: files?.notesURL(for: newKey), adopt: adoptCurrent)
    }

    /// Résultats actuels (appareils, noms, état du scan, bilan des switchs).
    private func collect(from state: AppState) -> SiteResults {
        var results = SiteResults(devices: state.devices, customNames: state.customNames)
        ScanController.shared.shelve(into: &results)
        SwitchStore.shared.shelve(into: &results)
        return results
    }

    private func apply(_ results: SiteResults, to state: AppState) {
        state.replaceCustomNames(results.customNames)
        state.selectedDeviceID = nil
        state.devices = results.devices.map { device in
            var copy = device
            copy.customName = results.customNames[device.id] ?? device.customName
            return copy
        }
        // Appareils déjà fusionnés dans l'inventaire de leur site : pas de nouvelle fusion.
        InvModel.shared.markIngested(state.devices)
        ScanController.shared.restore(results)
        SwitchStore.shared.restore(results)
    }

    /// Fermeture de NetScope : résultats du site actif et fusion d'inventaire en attente enregistrés.
    func saveOnQuit() {
        guard !isEphemeral, let state = attachedState else { return }
        InvModel.shared.flushAndSave()
        shelf.shelve(collect(from: state), for: activeKey)
    }

    /// Fin d'un scan : date du scan, MAC de la passerelle apprise, résultats écrits sur le disque.
    func scanFinished(_ state: AppState) {
        if let id = list.activeID, let index = list.index(of: id) {
            list.sites[index].lastScan = Date()
            // Premier scan du site : la MAC de sa passerelle le reconnaîtra ensuite (« Détecter mon
            // site »). Jamais après « Scanner sans enregistrer » (souvent chez un autre client), ni
            // si les plages ne sont plus celles du site et que la passerelle n'y est pas.
            if !scanWithoutSaving, let gateway = state.activeInterface?.gateway,
               let mac = state.device(withID: gateway.description)?.mac,
               list.sites[index].hints.gatewayMACs.isEmpty,
               !hasUnsavedRanges(state) || list.sites[index].contains(gateway),
               !list.sites.contains(where: { $0.id != id && $0.hints.gatewayMACs.contains(mac) }) {
                list.sites[index].hints.learn(gatewayMAC: mac)
            }
            SiteFortiGate.refreshHints(&list.sites[index], controllers: FortiGateStore.shared.controllers)
            save()
        }
        scanWithoutSaving = false
        shelf.shelve(collect(from: state), for: activeKey)
    }

    /// Avant un scan : si les plages ne sont plus celles du site actif, on demande (le scan irait
    /// dans l'inventaire de ce site). Faux : le scan n'est pas lancé.
    func confirmScan(_ state: AppState) -> Bool {
        scanWithoutSaving = false
        guard hasUnsavedRanges(state), !isEphemeral else { return true }
        let alert = NSAlert()
        alert.messageText = "Les plages ne sont plus celles du site «\u{00A0}\(activeName)\u{00A0}»"
        alert.informativeText = "Le scan sera rangé dans l’inventaire de «\u{00A0}\(activeName)\u{00A0}». Si vous êtes chez un autre client, enregistrez plutôt ces plages comme un nouveau site."
        alert.addButton(withTitle: "Mettre à jour le site et scanner")
        alert.addButton(withTitle: "Nouveau site…")
        alert.addButton(withTitle: "Scanner sans enregistrer")
        alert.addButton(withTitle: "Annuler")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            updateActiveSite(state)
            return true
        case .alertSecondButtonReturn:
            prompt = .saveAs
            state.open(.scanner)
            return false
        case .alertThirdButtonReturn:
            scanWithoutSaving = true
            return true
        default:
            return false
        }
    }

    private enum UnsavedChoice { case save, discard, cancel }

    private func askUnsaved(leaving name: String) -> UnsavedChoice {
        guard !isEphemeral else { return .discard }
        let alert = NSAlert()
        alert.messageText = "Plages non enregistrées dans «\u{00A0}\(name)\u{00A0}»"
        alert.informativeText = "Les plages du Scanner ont changé depuis le dernier enregistrement du site. Elles seront perdues si vous changez de site sans les enregistrer."
        alert.addButton(withTitle: "Mettre à jour le site")
        alert.addButton(withTitle: "Changer sans enregistrer")
        alert.addButton(withTitle: "Annuler")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    // MARK: Modifier les sites

    /// Tout premier lancement : les plages du réseau détecté remplacent celles par défaut du premier site.
    func firstLaunchRangesDetected(_ state: AppState) {
        guard let id = list.activeID, let index = list.index(of: id),
              Site.sameRanges(list.sites[index].ranges, AppState.defaultRanges, checks: false) else { return }
        list.sites[index].ranges = state.ranges
        save()
    }

    /// « Mettre à jour ce site » : les plages du Scanner deviennent celles du site actif.
    func updateActiveSite(_ state: AppState) {
        guard let id = list.activeID, let index = list.index(of: id) else { return }
        list.sites[index].ranges = state.ranges
        save()
        ScanController.shared.show("Plages enregistrées dans le site «\u{00A0}\(activeName)\u{00A0}».")
    }

    /// « Enregistrer les plages comme site… » : nouveau site avec les plages du Scanner. Depuis les
    /// plages libres, le site garde les résultats et l'inventaire en cours ; depuis un autre site,
    /// celui-ci est laissé tel qu'enregistré et le nouveau site part d'un inventaire vide.
    func saveRangesAsSite(name: String, notes: String, fortiGateIDs: [UUID], state: AppState) {
        var site = Site(name: list.uniqueName(name), notes: notes, ranges: state.ranges, fortiGateIDs: fortiGateIDs)
        SiteFortiGate.refreshHints(&site, controllers: FortiGateStore.shared.controllers)
        let fromNoSite = list.activeID == nil
        if fromNoSite, let gateway = state.activeInterface?.gateway, let mac = state.device(withID: gateway.description)?.mac {
            site.hints.learn(gatewayMAC: mac)
        }
        list.sites.append(site)
        if fromNoSite {
            switchSite(to: site.id, state: state, adoptCurrent: true)
        } else {
            switchSite(to: site.id, state: state, adoptCurrent: false)
            // Le nouveau site part de ces plages (le site quitté garde les siennes).
            state.ranges = site.ranges
        }
        save()
        ScanController.shared.show("Site «\u{00A0}\(site.displayName)\u{00A0}» enregistré et choisi.")
    }

    func add(_ site: Site) {
        list.add(site)
        save()
    }

    func update(_ site: Site, state: AppState) {
        let old = list.site(site.id)
        list.update(site)
        save()
        guard site.id == list.activeID else { return }
        // Plages du site actif modifiées dans les Réglages : le Scanner les reprend. Seulement si
        // elles ont changé : des plages du Scanner pas encore enregistrées restent sinon intactes.
        if let old, !Site.sameRanges(old.ranges, site.ranges) { state.ranges = site.ranges }
        if old?.fortiGateIDs != site.fortiGateIDs { FortiGateStore.shared.siteChanged(state: state) }
        RapportModel.shared.siteChanged(activeSite)
    }

    /// Notes du site (Réglages › Sites) : ne touche ni aux plages du Scanner ni aux FortiGate.
    func setNotes(_ notes: String, for id: UUID) {
        guard let index = list.index(of: id), list.sites[index].notes != notes else { return }
        list.sites[index].notes = notes
        save()
        if id == list.activeID { RapportModel.shared.siteChanged(activeSite) }
    }

    func rename(_ id: UUID, to name: String) {
        list.rename(id, to: name)
        save()
        if id == list.activeID { RapportModel.shared.siteChanged(activeSite) }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Site? {
        let copy = list.duplicate(id)
        save()
        return copy
    }

    /// Supprime un site, son inventaire et ses résultats (après confirmation de l'appelant). Le site
    /// actif supprimé laisse place aux plages libres.
    func remove(_ id: UUID, state: AppState) {
        let key = SiteFiles.key(for: id)
        let wasActive = id == list.activeID
        if wasActive {
            if let reason = busyReason() {
                ScanController.shared.show("\(reason) avant de supprimer le site actif.", tone: .warning)
                return
            }
            InvModel.shared.switchSite(to: SiteFiles.noSiteKey, url: files?.inventoryURL(for: SiteFiles.noSiteKey), demoStore: nil, discardCurrent: true)
            list.activeID = nil
            apply(shelf.take(SiteFiles.noSiteKey), to: state)
            FortiGateStore.shared.siteChanged(state: state)
            RapportModel.shared.siteChanged(nil)
            InvModel.shared.updateBadge(state)
            DeviceNotesStore.shared.switchSite(to: SiteFiles.noSiteKey, url: files?.notesURL(for: SiteFiles.noSiteKey), adopt: false)
        }
        list.remove(id)
        shelf.forget(key)
        files?.removeFolder(for: key)
        save()
        if wasActive {
            ScanController.shared.show("Site supprimé\u{00A0}: aucun site actif. Les plages du Scanner restent celles du site supprimé, sans être enregistrées.", tone: .neutral)
        }
    }

    /// Associe un switch SNMP aux sites donnés (aucun, un ou plusieurs).
    func setSwitch(_ host: String, sites ids: Set<UUID>) {
        list.setSwitch(host, sites: ids)
        save()
    }

    func sites(forSwitch host: String) -> [Site] { list.sites(forSwitch: host) }

    /// « Créer depuis les FortiGate » : un site par FortiGate pas encore associée.
    func createFromFortiGates() -> String {
        let created = SiteFortiGate.sitesToCreate(from: FortiGateStore.shared.controllers, existing: list)
        guard !created.isEmpty else {
            return FortiGateStore.shared.controllers.isEmpty
                ? "Aucune FortiGate dans Réglages › Switchs › Contrôleurs FortiGate."
                : "Chaque FortiGate est déjà associée à un site."
        }
        list.sites.append(contentsOf: created)
        save()
        return "\(created.count) site\(created.count > 1 ? "s" : "") créé\(created.count > 1 ? "s" : "") depuis les FortiGate\u{00A0}: "
            + created.map(\.displayName).joined(separator: ", ") + "."
    }

    func importCSV(_ text: String, state: AppState) -> (summary: String, errors: [String]) {
        let parsed = SiteCSV.parse(text)
        let before = activeSite
        let merged = SiteCSV.merge(parsed.rows, into: list, controllers: FortiGateStore.shared.controllers)
        list = merged.list
        save()
        // Plages du site actif changées par l'import : le Scanner les reprend.
        if let site = activeSite, let before, !Site.sameRanges(site.ranges, before.ranges) { state.ranges = site.ranges }
        var parts = ["\(merged.added) site\(merged.added > 1 ? "s" : "") ajouté\(merged.added > 1 ? "s" : "")",
                     "\(merged.updated) mis à jour"]
        if !parsed.errors.isEmpty { parts.append("\(parsed.errors.count) ligne\(parsed.errors.count > 1 ? "s" : "") refusée\(parsed.errors.count > 1 ? "s" : "")") }
        var summary = "Import\u{00A0}: " + parts.joined(separator: ", ") + "."
        if !merged.unknownFortiGates.isEmpty {
            summary += " FortiGate inconnue\(merged.unknownFortiGates.count > 1 ? "s" : "")\u{00A0}: " + merged.unknownFortiGates.joined(separator: ", ") + "."
        }
        return (summary, parsed.errors.map(\.text))
    }

    func exportCSV() -> String { SiteCSV.export(sortedSites, controllers: FortiGateStore.shared.controllers) }

    private func save() {
        objectWillChange.send()
        guard let files, !saveBlocked else { return }
        do {
            try files.saveList(list)
        } catch {
            NSLog("NetScope : enregistrement impossible de sites.json : %@", error.localizedDescription)
        }
    }

    // MARK: Détecter mon site

    /// Lit la passerelle (table ARP locale, aucun trafic), la FortiGate lue récemment et le SSID,
    /// puis désigne le site — jamais par la seule IP. Plusieurs sites possibles : on demande.
    func detect(state: AppState) {
        Task {
            let observation = await observe(state)
            let result = SiteDetector.detect(observation, in: list.sites)
            let scan = ScanController.shared
            switch result {
            case .matched(let id, let hint):
                guard let site = site(id) else { return }
                if id == list.activeID {
                    scan.show("Vous êtes bien au site «\u{00A0}\(site.displayName)\u{00A0}» (\(hint.label)).")
                } else {
                    prompt = .detected(id, hint: hint)
                }
            case .ask(let ids, let reason):
                prompt = .choose(ids, reason: reason, gatewayMAC: observation.gatewayMAC)
            case .none:
                let gateway = observation.gateway.map { " (passerelle \($0))" } ?? ""
                scan.show("Aucun site ne correspond à ce réseau\(gateway)\u{00A0}: enregistrez les plages comme site.", tone: .warning)
            }
        }
    }

    /// Site choisi après une question : il retient la MAC de la passerelle (la prochaine détection
    /// sera automatique), puis devient le site actif.
    func choose(_ id: UUID, learning mac: MACAddress?, state: AppState) {
        activate(id, state: state)
        // Changement refusé ou annulé : rien n'est appris. Une MAC déjà connue d'un autre site
        // n'est pas ajoutée (la détection resterait ambiguë).
        guard list.activeID == id, let mac, let index = list.index(of: id),
              !list.sites.contains(where: { $0.id != id && $0.hints.gatewayMACs.contains(mac) }) else { return }
        list.sites[index].hints.learn(gatewayMAC: mac)
        save()
    }

    private func observe(_ state: AppState) async -> SiteObservation {
        let interface = state.activeInterface
        var observation = SiteObservation(address: interface?.address, gateway: interface?.gateway)
        if isEphemeral {
            observation.gatewayMAC = SitesDemo.observedGatewayMAC
            return observation
        }
        if observation.gateway == nil {
            observation.gateway = await Task.detached(priority: .userInitiated) { ScanNetwork.defaultGateway() }.value
        }
        if let gateway = observation.gateway {
            // Table ARP du Mac (lecture locale) ; à défaut, la MAC relevée par le dernier scan.
            let table = await Task.detached(priority: .userInitiated) { ARPTable().read() }.value
            observation.gatewayMAC = table[gateway] ?? state.device(withID: gateway.description)?.mac
            // FortiGate lue il y a moins de 15 min à l'adresse de la passerelle : son certificat
            // épinglé prouve que c'est bien elle (série et nom d'hôte relus).
            let fortigate = FortiGateStore.shared
            for controller in fortigate.controllers where controller.config.cleanHost == gateway.description {
                if let report = fortigate.runtime[controller.id]?.report, Date().timeIntervalSince(report.readAt) < 15 * 60 {
                    observation.fortiGateSerial = report.system.serial
                    observation.fortiGateHostname = report.system.hostname
                }
            }
        }
        observation.ssid = WifiStore.shared.connection?.network?.ssid
        return observation
    }
}

/// Question posée dans le Scanner.
enum SitePrompt: Identifiable, Equatable {
    /// Site reconnu par un indice : confirmer le changement.
    case detected(UUID, hint: SiteHintKind)
    /// Plusieurs sites possibles (ou un seul, par ses plages) : choisir.
    case choose([UUID], reason: String, gatewayMAC: MACAddress?)
    /// Enregistrer les plages du Scanner comme nouveau site.
    case saveAs

    var id: String {
        switch self {
        case .detected(let id, _): return "detecte-\(id)"
        case .choose(let ids, _, _): return "choix-" + ids.map(\.uuidString).joined()
        case .saveAs: return "enregistrer"
        }
    }
}
