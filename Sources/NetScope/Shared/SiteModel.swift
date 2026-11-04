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
        if let saved = files.loadList() {
            list = saved
        } else {
            // Première ouverture de la 0.12.0 : plages, inventaire, noms et FortiGate deviennent
            // ceux de « Site principal » ; l'ancien inventaire est gardé en copie de sécurité.
            let state = StateStore.standard.load()
            do {
                let result = try SiteMigration.migrateIfNeeded(files: files, ranges: state?.ranges ?? AppState.defaultRanges,
                                                               customNames: state?.customNames ?? [:],
                                                               controllers: FortiGateStore.savedControllers())
                list = result?.list ?? SiteList()
                if let result, let count = result.migratedRecords {
                    migrationMessage = "Vos plages et votre inventaire (\(count) fiche\(count > 1 ? "s" : "")) sont maintenant ceux du site «\u{00A0}\(SiteMigration.firstSiteName)\u{00A0}». Copie de sécurité\u{00A0}: \(SiteFiles.legacyBackupName)."
                }
            } catch {
                NSLog("NetScope : migration des sites impossible : %@", error.localizedDescription)
                list = SiteList()
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
        guard !scan.isBusy else {
            scan.show("Arrêtez le scan ou la sonde de ports avant de changer de site.", tone: .warning)
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
            if let gateway = state.activeInterface?.gateway, let mac = state.device(withID: gateway.description)?.mac,
               list.sites[index].hints.gatewayMACs.isEmpty {
                // Premier scan du site : la MAC de sa passerelle le reconnaîtra ensuite (« Détecter mon site »).
                list.sites[index].hints.learn(gatewayMAC: mac)
            }
            SiteFortiGate.refreshHints(&list.sites[index], controllers: FortiGateStore.shared.controllers)
            save()
        }
        shelf.shelve(collect(from: state), for: activeKey)
    }

    /// Avant un scan : si les plages ne sont plus celles du site actif, on demande (le scan irait
    /// dans l'inventaire de ce site). Faux : le scan n'est pas lancé.
    func confirmScan(_ state: AppState) -> Bool {
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
        list.update(site)
        // Plages du site actif modifiées dans les Réglages : le Scanner les reprend.
        if site.id == list.activeID { state.ranges = site.ranges }
        save()
        if site.id == list.activeID {
            FortiGateStore.shared.siteChanged(state: state)
            RapportModel.shared.siteChanged(activeSite)
        }
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
        if id == list.activeID {
            guard !ScanController.shared.isBusy else {
                ScanController.shared.show("Arrêtez le scan avant de supprimer le site actif.", tone: .warning)
                return
            }
            InvModel.shared.switchSite(to: SiteFiles.noSiteKey, url: files?.inventoryURL(for: SiteFiles.noSiteKey), demoStore: nil, discardCurrent: true)
            list.activeID = nil
            apply(shelf.take(SiteFiles.noSiteKey), to: state)
            FortiGateStore.shared.siteChanged(state: state)
            RapportModel.shared.siteChanged(nil)
        }
        list.remove(id)
        shelf.forget(key)
        files?.removeFolder(for: key)
        save()
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
        guard let files else { return }
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
        if let mac, let index = list.index(of: id) {
            list.sites[index].hints.learn(gatewayMAC: mac)
            save()
        }
        activate(id, state: state)
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
