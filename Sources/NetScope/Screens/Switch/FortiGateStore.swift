import AppKit
import Foundation
import NetScopeCore

/// Contrôleurs FortiGate (notes 24 et 25) : une FortiGate par site, chacune avec son adresse, son
/// VDOM, ses plages couvertes et l'empreinte de son certificat (préférences, JSON sans secret) et
/// son jeton d'administrateur API REST (Trousseau, service com.danymenard.netscope.fortigate,
/// compte = identifiant du contrôleur). En fin de scan et à la demande, seules les FortiGate
/// choisies par `FortiControllerSelector` sont lues (quatre à la fois au plus) ; leurs FortiSwitch
/// sont confiés à `SwitchStore`, prioritaires sur SNMP.
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de
/// FortiGateDemo et FortiGateSitesDemo.
@MainActor
final class FortiGateStore: ObservableObject {
    static let shared = FortiGateStore()

    nonisolated static let keychain = UpdKeychain(service: "com.danymenard.netscope.fortigate")
    nonisolated private static let listKey = "NetScope.fortigate.controleurs"
    /// Réglages de la FortiGate unique de la 0.9.0 (lus une fois pour la migration).
    private static let legacyConfigKey = "NetScope.fortigate.reglages"
    private static let enabledKey = "NetScope.fortigate.actif"
    /// Contrôleur migré dont le jeton reste à déplacer du compte « jeton » (0.9.0).
    private static let migrationKey = "NetScope.fortigate.migration"

    /// Certificat présenté au premier contact (ou changé), avec l'adresse et le port de la FortiGate
    /// qui l'a présenté : l'empreinte n'est jamais acceptée pour une autre adresse.
    struct PendingCertificate: Equatable {
        var fingerprint: String
        var subject: String
        var changed: Bool
        var host: String
        var port: Int
    }

    /// État en mémoire d'un contrôleur (dernière lecture, erreur, certificat en attente).
    struct Runtime: Equatable {
        var report: FortiGateReport?
        var error: String?
        var pending: PendingCertificate?
        var busy = false
        var calls: [FortiCallRecord] = []
        var lastAttempt: Date?
    }

    /// Résultat d'un « Tester » de la feuille d'édition (rien n'est enregistré).
    struct TestOutcome: Equatable {
        var report: FortiGateReport?
        var interfaces: [FortiInterfaceSubnet] = []
        var error: String?
        var pending: PendingCertificate?
        var calls: [FortiCallRecord] = []
        var date = Date()

        var ok: Bool { report != nil }
    }

    /// Contrôleurs, dans l'ordre de la liste (à égalité de précision, le premier l'emporte).
    @Published private(set) var controllers: [FortiGateController]
    /// Lecture des FortiGate à chaque scan et avec « Interroger les switchs ».
    @Published var isEnabled: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) } }
    }
    /// Contrôleurs dont le jeton est au Trousseau.
    @Published private(set) var tokenIDs: Set<UUID> = []
    @Published private(set) var runtime: [UUID: Runtime] = [:]
    /// FortiGate choisies pour le dernier scan (ou la dernière relecture).
    @Published private(set) var selection = FortiControllerSelection()
    /// Lectures réussies de la dernière relecture, fusionnées dans « Switchs et ports ».
    @Published private(set) var sites: [FortiSiteReport] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isTestingAll = false

    let isDemo: Bool
    private var tokens: [UUID: String] = [:]
    private var tokensLoaded = false
    /// Lecture du Trousseau en cours : les appels simultanés l'attendent au lieu de repartir à vide.
    private var tokensTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Numéro de la lecture la plus récente de chaque contrôleur : seul son résultat compte.
    private var readGeneration: [UUID: Int] = [:]

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            let content = FortiGateSitesDemo.make()
            controllers = content.controllers
            isEnabled = true
            tokenIDs = content.tokenIDs
            tokensLoaded = true
            runtime = content.runtime
            selection = content.selection
            sites = content.sites
            lastRefresh = content.sites.first?.report.readAt
        } else {
            let defaults = UserDefaults.standard
            let result = FortiControllerMigration.migrateSettings(existing: defaults.data(forKey: Self.listKey),
                                                                  legacy: defaults.data(forKey: Self.legacyConfigKey))
            controllers = result.controllers
            isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
            if let id = result.migratedID {
                // La liste enregistrée fait foi désormais (l'ancienne clé, sans secret, est laissée telle
                // quelle) ; le jeton est déplacé à la première lecture du Trousseau.
                defaults.set(id.uuidString, forKey: Self.migrationKey)
                persist()
            }
        }
    }

    // MARK: État

    /// Au moins une FortiGate a une adresse : les panneaux FortiGate méritent d'être montrés.
    var isConfigured: Bool { controllers.contains { $0.config.isValid } }
    var isBusy: Bool { runtime.values.contains { $0.busy } }
    /// Au moins une FortiGate activée prête à être lue.
    var isReady: Bool { controllers.contains { $0.isEnabled && isReady($0) } }
    var enabledControllers: [FortiGateController] { controllers.filter(\.isEnabled) }
    /// Chevauchements entre les plages des FortiGate activées.
    var conflicts: [FortiRangeConflict] { FortiControllerSelector.conflicts(enabledControllers) }

    func controller(_ id: UUID) -> FortiGateController? { controllers.first { $0.id == id } }
    func hasToken(_ id: UUID) -> Bool { tokenIDs.contains(id) }
    func isReady(_ c: FortiGateController) -> Bool { c.config.isValid && hasToken(c.id) && c.pinnedFingerprint != nil }

    /// Raison pour laquelle cette FortiGate ne peut pas être lue (nil si elle est prête).
    func notReadyReason(_ c: FortiGateController) -> String? {
        guard !isDemo else { return nil }
        if !c.config.isValid { return FortiGateError.invalidAddress.errorDescription }
        if !hasToken(c.id) { return "Jeton absent\u{00A0}: enregistrez-le dans Réglages › Switchs › Contrôleurs FortiGate." }
        if runtime[c.id]?.pending != nil { return "Empreinte du certificat à vérifier dans Réglages › Switchs." }
        if c.pinnedFingerprint == nil {
            return "Empreinte du certificat à accepter\u{00A0}: «\u{00A0}Tester\u{00A0}» dans Réglages › Switchs."
        }
        return nil
    }

    /// FortiGate en cours de lecture (noms des sites).
    var busySites: [String] { controllers.filter { runtime[$0.id]?.busy == true }.map(\.displayName) }

    /// Choix pour les plages et l'adresse actuelles (sans rien lire) : pour les bandeaux.
    func previewSelection(state: AppState) -> FortiControllerSelection {
        siteSelection(ranges: state.checkedRanges, state: state)
    }

    /// Note 28 : les FortiGate du site actif ; le choix par plage (note 25) seulement quand aucun
    /// site n'est actif.
    func siteSelection(ranges: [IPRange], state: AppState) -> FortiControllerSelection {
        SiteFortiGate.select(site: SiteModel.shared.activeSite, controllers: controllers, scanned: ranges,
                             macAddress: state.activeInterface?.address)
    }

    /// Changement de site : seules les lectures des FortiGate du nouveau site restent affichées
    /// (FortiSwitch, Wi-Fi FortiAP) ; rien n'est relu sur le réseau, la fin du prochain scan ou
    /// « Relire » s'en charge.
    func siteChanged(state: AppState) {
        // Une lecture lancée pour le site quitté (« Relire », fin de scan) ne s'applique plus.
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        // FortiGate lues pour l'ancien site (pas un « Tester tout » des Réglages) : leur lecture
        // en cours est oubliée, elles ne sont plus occupées.
        if !isTestingAll {
            for id in selection.controllerIDs where runtime[id]?.busy == true {
                readGeneration[id, default: 0] += 1
                runtime[id]?.busy = false
            }
        }
        let chosen = previewSelection(state: state)
        selection = chosen
        let ids = Set(chosen.controllerIDs)
        if isDemo {
            sites = FortiGateSitesDemo.sites(for: chosen)
        } else {
            sites = sites.filter { ids.contains($0.controllerID) }
        }
        SwitchStore.shared.showControllerSites(sites)
        FortiAPStore.shared.keepOnly(ids, selection: chosen)
        DHCPScopeStore.shared.keepOnly(ids, selection: chosen)
    }

    // MARK: Liste et Trousseau

    /// Liste enregistrée, lue sans passer par le fil principal (sauvegardes) : jamais de jeton.
    nonisolated static func savedControllers() -> [FortiGateController] {
        UserDefaults.standard.data(forKey: listKey).flatMap(FortiControllerList.decode) ?? []
    }

    private func persist() {
        guard !isDemo, let data = FortiControllerList.encode(controllers) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
    }

    /// Lit les jetons au Trousseau, hors du fil principal (une seule fois), après avoir déplacé
    /// celui de la 0.9.0 vers le compte du contrôleur migré. Un appel pendant la lecture attend
    /// qu'elle finisse : personne ne voit la liste des jetons encore vide.
    func loadTokens() async {
        guard !isDemo, !tokensLoaded else { return }
        if let running = tokensTask {
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.readTokens()
        }
        tokensTask = task
        await task.value
    }

    private func readTokens() async {
        let saved = UserDefaults.standard.string(forKey: Self.migrationKey).flatMap(UUID.init(uuidString:))
        // Contrôleur migré supprimé entre-temps : le jeton de la 0.9.0 est effacé, pas déplacé.
        let migrating = saved.flatMap { id in controller(id) != nil ? id : nil }
        let dropLegacy = saved != nil && migrating == nil
        let ids = controllers.map(\.id)
        var found = await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
            if let migrating { FortiControllerMigration.migrateToken(to: migrating, store: FortiGateStore.keychain) }
            if dropLegacy { try? FortiGateStore.keychain.delete(FortiControllerMigration.legacyTokenAccount) }
            var result: [UUID: String] = [:]
            for id in ids {
                if let value = FortiGateStore.keychain.string(for: id.uuidString), !value.isEmpty { result[id] = value }
            }
            return result
        }.value
        if saved != nil { UserDefaults.standard.removeObject(forKey: Self.migrationKey) }
        // Contrôleur supprimé pendant la lecture : son compte (jeton migré compris) est effacé.
        for id in found.keys where controller(id) == nil {
            found[id] = nil
            try? Self.keychain.delete(id.uuidString)
        }
        if let migrating, controller(migrating) == nil { try? Self.keychain.delete(migrating.uuidString) }
        // Un jeton saisi pendant la lecture du Trousseau l'emporte.
        tokens = found.merging(tokens) { _, typed in typed }
        tokenIDs = Set(tokens.keys)
        tokensLoaded = true
        tokensTask = nil
    }

    /// Vérifie la forme d'un jeton ; renvoie un message d'erreur.
    nonisolated static func tokenProblem(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Jeton vide." }
        guard trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
            return "Le jeton ne doit contenir que des lettres, des chiffres et les signes «\u{00A0}-\u{00A0}», «\u{00A0}_\u{00A0}» ou «\u{00A0}.\u{00A0}» (copiez-le tel que la FortiGate l’a affiché)."
        }
        return nil
    }

    /// Ajoute ou remplace un contrôleur ; `token` non vide est enregistré au Trousseau. Renvoie un
    /// message d'erreur (rien n'est changé dans ce cas).
    @discardableResult
    func save(_ draft: FortiGateController, token: String?, state: AppState) -> String? {
        var next = draft
        next.site = next.site.trimmingCharacters(in: .whitespacesAndNewlines)
        next.host = next.host.trimmingCharacters(in: .whitespacesAndNewlines)
        next.vdom = next.vdom.trimmingCharacters(in: .whitespacesAndNewlines)
        next.ranges = next.ranges.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard next.config.isValid else { return FortiGateError.invalidAddress.errorDescription }
        let typed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty, let problem = Self.tokenProblem(typed) { return problem }
        let existing = controller(next.id)
        if let existing, !existing.sameTarget(as: next), next.pinnedFingerprint == existing.pinnedFingerprint {
            // Autre FortiGate : l'empreinte acceptée pour l'ancienne adresse ne vaut plus.
            next.pinnedFingerprint = nil
        }
        if !typed.isEmpty, !isDemo {
            do {
                try Self.keychain.set(typed, for: next.keychainAccount)
            } catch {
                return error.localizedDescription
            }
        }
        if !typed.isEmpty {
            tokens[next.id] = typed
            tokenIDs.insert(next.id)
        }
        if let index = controllers.firstIndex(where: { $0.id == next.id }) {
            let previous = controllers[index]
            let changedTarget = !previous.sameTarget(as: next)
            controllers[index] = next
            if changedTarget || previous.coveredRanges != next.coveredRanges || (previous.isEnabled && !next.isEnabled) {
                // Sa lecture ne vaut plus pour « Switchs et ports » : autre appareil, autres plages
                // ou FortiGate désactivée.
                dropSite(next.id, state: state)
            }
            if changedTarget {
                forgetRead(next.id)
            } else if next.pinnedFingerprint != nil {
                // Empreinte acceptée dans la feuille : le certificat n'est plus en attente.
                runtime[next.id]?.pending = nil
            }
        } else {
            controllers.append(next)
        }
        persist()
        return nil
    }

    /// Supprime un contrôleur et son jeton du Trousseau.
    func remove(_ id: UUID, state: AppState) {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        controllers.remove(at: index)
        if !isDemo {
            try? Self.keychain.delete(id.uuidString)
            // Jeton de la 0.9.0 encore à déplacer vers ce contrôleur : effacé avec lui. Pendant une
            // lecture du Trousseau, readTokens s'en charge à son retour.
            if tokensTask == nil, UserDefaults.standard.string(forKey: Self.migrationKey) == id.uuidString {
                try? Self.keychain.delete(FortiControllerMigration.legacyTokenAccount)
                UserDefaults.standard.removeObject(forKey: Self.migrationKey)
            }
        }
        tokens[id] = nil
        tokenIDs.remove(id)
        runtime[id] = nil
        dropSite(id, state: state)
        persist()
    }

    func setEnabled(_ id: UUID, _ value: Bool, state: AppState) {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        controllers[index].isEnabled = value
        if !value { dropSite(id, state: state) }
        persist()
    }

    /// Retire la lecture d'une FortiGate de « Switchs et ports » (supprimée, désactivée, changée).
    private func dropSite(_ id: UUID, state: AppState) {
        selection.picks.removeAll { $0.controllerID == id }
        if sites.contains(where: { $0.controllerID == id }) {
            sites.removeAll { $0.controllerID == id }
            applySites(state: state)
        }
    }

    /// Déplace un contrôleur dans la liste (l'ordre départage deux plages de même précision).
    func move(_ id: UUID, by offset: Int) {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard controllers.indices.contains(target) else { return }
        controllers.swapAt(index, target)
        persist()
    }

    /// Oublie la lecture d'une FortiGate dont l'adresse a changé.
    private func forgetRead(_ id: UUID) {
        readGeneration[id, default: 0] += 1
        runtime[id] = nil
    }

    private func applySites(state: AppState) {
        if sites.isEmpty {
            SwitchStore.shared.clearController()
        } else {
            SwitchStore.shared.applyControllers(sites, state: state)
        }
    }

    // MARK: Import et export CSV

    /// Importe un CSV « site;adresse;port;vdom;plages » ; renvoie le bilan (lignes refusées
    /// expliquées, les autres importées).
    func importCSV(_ text: String, state: AppState) -> (summary: String, errors: [String], notes: [String]) {
        let parsed = FortiControllerCSV.parse(text)
        let merged = FortiControllerCSV.merge(parsed.rows, into: controllers)
        let before = controllers
        controllers = merged.controllers
        // Plages changées par l'import : la lecture de ces FortiGate ne vaut plus.
        for old in before where controller(old.id)?.coveredRanges != old.coveredRanges { dropSite(old.id, state: state) }
        persist()
        var parts: [String] = []
        parts.append("\(merged.added) FortiGate ajoutée\(merged.added > 1 ? "s" : "")")
        parts.append("\(merged.updated) mise\(merged.updated > 1 ? "s" : "") à jour")
        if !parsed.errors.isEmpty { parts.append("\(parsed.errors.count) ligne\(parsed.errors.count > 1 ? "s" : "") refusée\(parsed.errors.count > 1 ? "s" : "")") }
        let missing = controllers.filter { !hasToken($0.id) }.count
        var summary = "Import\u{00A0}: " + parts.joined(separator: ", ") + "."
        if missing > 0 { summary += " Jeton à saisir pour \(missing) FortiGate (jamais importé)." }
        return (summary, parsed.errors.map(\.text), parsed.notes)
    }

    func exportCSV() -> String { FortiControllerCSV.export(controllers) }

    // MARK: Lecture en fin de scan et à la demande

    /// Lecture de fin de scan : attend une relecture déjà lancée, puis lit les FortiGate choisies
    /// pour ces plages.
    func refreshAfterScan(state: AppState, ranges: [IPRange]) async {
        if let running = refreshTask { await running.value }
        let next: Task<Void, Never> = Task { [weak self] in await self?.refresh(state: state, ranges: ranges) }
        refreshTask = next
        await withTaskCancellationHandler { await next.value } onCancel: { next.cancel() }
    }

    /// « Relire » : plages cochées du Scanner, sinon l'adresse du Mac.
    func refreshNow(state: AppState) {
        refreshTask?.cancel()
        let ranges = state.checkedRanges
        refreshTask = Task { [weak self] in await self?.refresh(state: state, ranges: ranges) }
    }

    /// - Parameters:
    ///   - wifi: relire aussi les bornes FortiAP (non : la relecture automatique les a lues il y a
    ///     peu, par exemple pour une sonde de la Surveillance).
    ///   - keepOnFailure: relecture automatique (note 29) : une FortiGate injoignable garde sa
    ///     dernière lecture affichée (avec son heure) au lieu de disparaître de « Switchs et ports ».
    private func refresh(state: AppState, ranges: [IPRange], wifi: Bool = true, keepOnFailure: Bool = false) async {
        guard isEnabled else {
            if !isDemo {
                sites = []
                SwitchStore.shared.clearController()
            }
            return
        }
        // Site de la lecture : s'il change pendant la lecture, rien n'est appliqué (note 28).
        let siteID = SiteModel.shared.activeID
        let chosen = siteSelection(ranges: ranges, state: state)
        selection = chosen
        if isDemo {
            for id in chosen.controllerIDs { runtime[id, default: Runtime()].busy = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
            for id in chosen.controllerIDs { runtime[id]?.busy = false }
            guard !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
            sites = FortiGateSitesDemo.sites(for: chosen)
            lastRefresh = Date()
            applySites(state: state)
            if wifi { FortiAPStore.shared.refresh(selection: chosen, state: state) }
            DHCPScopeStore.shared.refresh(selection: chosen)
            return
        }
        await loadTokens()
        guard !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
        refreshGeneration += 1
        let mine = refreshGeneration
        var jobs: [Job] = []
        for id in chosen.controllerIDs {
            guard let c = controller(id) else { continue }
            if let reason = notReadyReason(c) {
                runtime[id, default: Runtime()].error = reason
                continue
            }
            guard let token = tokens[id] else { continue }
            jobs.append(Job(controller: c, token: token, generation: beginRead(id)))
        }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await FortiGateStore.performRead(config: job.controller.config, token: job.token, withInterfaces: false)
        }
        var fresh: [FortiSiteReport] = []
        for (job, result) in zip(jobs, results) {
            if let report = finishRead(job, result) {
                fresh.append(FortiSiteReport(controllerID: job.controller.id, site: job.controller.displayName, report: report,
                                             coveredRanges: job.controller.coveredRanges))
            }
        }
        guard mine == refreshGeneration, !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
        if keepOnFailure {
            let readIDs = Set(fresh.map(\.controllerID))
            let chosenIDs = Set(chosen.controllerIDs)
            fresh += sites.filter { chosenIDs.contains($0.controllerID) && !readIDs.contains($0.controllerID) }
        }
        sites = fresh
        lastRefresh = Date()
        applySites(state: state)
        // Note 27 : Wi-Fi des mêmes FortiGate, lu à part une fois les switchs appliqués.
        if wifi { FortiAPStore.shared.refresh(selection: chosen, state: state) }
        // Note 37 : étendues DHCP des mêmes FortiGate (configuration des serveurs et baux).
        DHCPScopeStore.shared.refresh(selection: chosen)
    }

    /// « Tester tout » : chaque FortiGate activée, quatre à la fois ; résultat sur chaque ligne.
    /// Les relevés affichés dans « Switchs et ports » ne changent pas.
    func testAll() {
        guard !isTestingAll else { return }
        isTestingAll = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTestingAll = false }
            if self.isDemo {
                let ids = self.enabledControllers.map(\.id)
                for id in ids { self.runtime[id, default: Runtime()].busy = true }
                try? await Task.sleep(nanoseconds: 900_000_000)
                for id in ids { self.runtime[id]?.busy = false }
                return
            }
            await self.loadTokens()
            var jobs: [Job] = []
            for c in self.enabledControllers {
                if !c.config.isValid {
                    self.setStatus(c.id, FortiControllerStatus(kind: .error, message: FortiGateError.invalidAddress.errorDescription ?? "", date: Date()))
                    continue
                }
                guard let token = self.tokens[c.id] else {
                    self.setStatus(c.id, FortiControllerStatus(kind: .missingToken, message: "Jeton absent.", date: Date()))
                    continue
                }
                // Sans empreinte acceptée, le premier contact présente le certificat à accepter.
                jobs.append(Job(controller: c, token: token, generation: self.beginRead(c.id)))
            }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
                await FortiGateStore.performRead(config: job.controller.config, token: job.token, withInterfaces: false)
            }
            for (job, result) in zip(jobs, results) { _ = self.finishRead(job, result) }
        }
    }

    /// Feuille d'édition : lecture complète et sous-réseaux des interfaces du brouillon (avec le
    /// jeton saisi, sinon celui du Trousseau), sans rien enregistrer.
    func test(_ draft: FortiGateController, typedToken: String) async -> TestOutcome {
        if isDemo { return FortiGateSitesDemo.testOutcome(for: draft) }
        await loadTokens()
        let typed = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.config.isValid else { return TestOutcome(error: FortiGateError.invalidAddress.errorDescription) }
        if !typed.isEmpty, let problem = Self.tokenProblem(typed) { return TestOutcome(error: problem) }
        guard let token = typed.isEmpty ? tokens[draft.id] : typed else {
            return TestOutcome(error: FortiGateError.missingToken.errorDescription)
        }
        let target = (draft.config.cleanHost.lowercased(), draft.config.effectivePort)
        // La feuille montre son propre indicateur : `runtime` n'est pas touché (pas d'entrée
        // orpheline pour un brouillon, pas de fin prématurée d'une lecture en cours).
        let result = await Self.performRead(config: draft.config, token: token, withInterfaces: true)
        switch result {
        case .success(let report, let interfaces, let calls):
            return TestOutcome(report: report, interfaces: interfaces, calls: calls)
        case .failure(let error, let calls):
            let (message, pending) = Self.describe(error, token: token, host: target.0, port: target.1)
            AppLog.shared.warning("FortiGate", "Essai de \(target.0):\(target.1) en échec\u{00A0}: \(message)")
            return TestOutcome(error: message, pending: pending, calls: calls)
        case .cancelled:
            return TestOutcome(error: "Essai annulé.")
        }
    }

    /// Note le résultat d'un essai de la feuille sur un contrôleur enregistré, seulement si l'essai
    /// visait la même FortiGate (adresse et port) que celle enregistrée.
    func recordTest(_ outcome: TestOutcome, for id: UUID, target: FortiGateController) {
        guard let saved = controller(id), saved.sameTarget(as: target) else { return }
        var r = runtime[id] ?? Runtime()
        r.lastAttempt = outcome.date
        r.calls = outcome.calls
        r.error = outcome.error
        // Le certificat en attente reste dans la feuille, qui l'accepte ou le refuse.
        r.pending = nil
        if let report = outcome.report { r.report = report }
        runtime[id] = r
        setStatus(id, outcome.report.map { FortiControllerStatus.success($0, date: outcome.date) }
                  ?? FortiControllerStatus(kind: outcome.pending != nil ? .certificate : .error, message: outcome.error ?? "", date: outcome.date))
    }

    // MARK: Lecture d'une FortiGate

    private struct Job: Sendable {
        var controller: FortiGateController
        var token: String
        var generation: Int
    }

    enum ReadResult: Sendable {
        case success(FortiGateReport, [FortiInterfaceSubnet], [FortiCallRecord])
        case failure(FortiGateError, [FortiCallRecord])
        case cancelled
    }

    private func beginRead(_ id: UUID) -> Int {
        readGeneration[id, default: 0] += 1
        var r = runtime[id] ?? Runtime()
        r.busy = true
        r.lastAttempt = Date()
        runtime[id] = r
        return readGeneration[id] ?? 0
    }

    /// Applique le résultat d'une lecture ; renvoie la lecture réussie (nil sinon, ou si une lecture
    /// plus récente de cette FortiGate l'a remplacée).
    private func finishRead(_ job: Job, _ result: ReadResult) -> FortiGateReport? {
        let id = job.controller.id
        guard readGeneration[id] == job.generation, controller(id) != nil else { return nil }
        var r = runtime[id] ?? Runtime()
        r.busy = false
        defer { runtime[id] = r }
        switch result {
        case .success(let report, _, let calls):
            r.report = report
            r.calls = calls
            r.error = nil
            r.pending = nil
            setStatus(id, .success(report, date: Date()))
            return report
        case .failure(let error, let calls):
            let c = job.controller.config
            let (message, pending) = Self.describe(error, token: job.token, host: c.cleanHost.lowercased(), port: c.effectivePort)
            // Note 35 : l'échec va au journal (message déjà sans jeton, masqué une seconde fois), une
            // fois tant qu'il se répète à l'identique d'une relecture à l'autre.
            if r.error != message { AppLog.shared.error("FortiGate", "\(job.controller.displayName) (\(c.cleanHost):\(c.effectivePort))\u{00A0}: \(message)") }
            r.error = message
            r.pending = pending
            r.calls = calls
            setStatus(id, FortiControllerStatus(kind: pending != nil ? .certificate : .error, message: message, date: Date()))
            return nil
        case .cancelled:
            return nil
        }
    }

    private func setStatus(_ id: UUID, _ status: FortiControllerStatus) {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        controllers[index].lastStatus = status
        persist()
    }

    /// Lecture réseau, hors du fil principal (GET seulement). Les interfaces ne sont lues qu'au
    /// « Tester ».
    nonisolated static func performRead(config: FortiGateConfig, token: String, withInterfaces: Bool) async -> ReadResult {
        let transport = FortiURLSessionTransport(config: config, token: token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: token)
        do {
            let report = try await reader.readKeepingCalls()
            var calls = report.calls
            var interfaces: [FortiInterfaceSubnet] = []
            if withInterfaces, let read = try? await reader.interfaces() {
                interfaces = read.subnets
                calls += read.calls
            }
            return .success(report, interfaces, calls)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FortiReadFailure {
            return .failure(failure.error, failure.calls)
        } catch let error as FortiGateError {
            return .failure(error, [])
        } catch {
            return .failure(.cannotConnect("erreur inattendue."), [])
        }
    }

    /// Message affiché (sans le jeton) et certificat à accepter, le cas échéant.
    nonisolated static func describe(_ error: FortiGateError, token: String?, host: String, port: Int) -> (String, PendingCertificate?) {
        switch error {
        case .certificateUnknown(let fingerprint, let subject):
            return ("Premier contact\u{00A0}: vérifiez l’empreinte du certificat puis acceptez-la.",
                    PendingCertificate(fingerprint: fingerprint, subject: subject, changed: false, host: host, port: port))
        case .certificateChanged(_, let presented):
            return (error.errorDescription ?? "Certificat changé.",
                    PendingCertificate(fingerprint: presented, subject: "", changed: true, host: host, port: port))
        default:
            return (FortiRedact.clean(error.errorDescription ?? "Lecture impossible.", token: token), nil)
        }
    }

    // MARK: Certificats (lignes du tableau)

    /// Accepte l'empreinte présentée à « Tester tout », si elle vient bien de l'adresse enregistrée.
    func acceptPendingCertificate(_ id: UUID) {
        guard let index = controllers.firstIndex(where: { $0.id == id }), let pending = runtime[id]?.pending else { return }
        runtime[id]?.pending = nil
        let c = controllers[index].config
        guard pending.host == c.cleanHost.lowercased(), pending.port == c.effectivePort else {
            runtime[id]?.error = "L’adresse de la FortiGate a changé depuis\u{00A0}: testez-la de nouveau pour vérifier son certificat."
            return
        }
        controllers[index].pinnedFingerprint = pending.fingerprint
        controllers[index].lastStatus = FortiControllerStatus(kind: .untested, message: "Empreinte acceptée, à tester.", date: Date())
        runtime[id]?.error = nil
        persist()
    }

    func rejectPendingCertificate(_ id: UUID) {
        runtime[id]?.pending = nil
        runtime[id]?.error = "Certificat refusé\u{00A0}: aucune connexion à cette FortiGate."
    }

    // MARK: Diagnostic

    /// Réponses brutes de la dernière lecture de ce contrôleur, sans le jeton.
    func diagnosticText(_ id: UUID, calls: [FortiCallRecord]? = nil) -> String {
        guard let c = controller(id) else { return "" }
        let r = runtime[id]
        let text = FortiDiagnostic.text(calls: calls ?? r?.calls ?? [], config: c.config, system: r?.report?.system, token: tokens[id],
                                        date: r?.lastAttempt ?? Date())
        // Note 27 : appels Wi-Fi de la dernière lecture des FortiAP (même retrait du jeton).
        let wifiCalls = calls == nil ? FortiAPStore.shared.calls[id] ?? [] : []
        let wifi = wifiCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: wifiCalls, config: c.config, system: nil, token: tokens[id],
                                                                        date: FortiAPStore.shared.lastRefresh ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes Wi-Fi (FortiAP) de la FortiGate")
            // Note 46 : champs de la fiche du client que cette FortiGate ne renvoie pas (« — » dans la fiche).
            + (FortiAPStore.shared.clientFieldsNote(controller: id).map { "\n" + $0 } ?? "")
        // Note 37 : appels des étendues DHCP de la dernière lecture (même retrait du jeton).
        let dhcpCalls = calls == nil ? DHCPScopeStore.shared.calls[id] ?? [] : []
        let dhcp = dhcpCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: dhcpCalls, config: c.config, system: nil, token: tokens[id],
                                                                        date: DHCPScopeStore.shared.lastRefresh ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes des étendues DHCP de la FortiGate")
        // Note 39 : appels du WAN et des VPN de la dernière lecture (même retrait du jeton).
        let wanCalls = calls == nil ? WANStore.shared.calls[id] ?? [] : []
        let wan = wanCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: wanCalls, config: c.config, system: nil, token: tokens[id],
                                                                      date: WANStore.shared.reports[id]?.report.readAt ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes du WAN et des VPN de la FortiGate")
        // Note 41 : appels du firmware et des licences de la dernière lecture (même retrait du jeton).
        let firmwareCalls = calls == nil ? FirmwareStore.shared.calls[id] ?? [] : []
        let firmware = firmwareCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: firmwareCalls, config: c.config, system: nil, token: tokens[id],
                                                                                date: FirmwareStore.shared.reports[id]?.report.readAt ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes du firmware et des licences de la FortiGate")
        // Note 54 : appels FortiView de la dernière lecture du trafic (même retrait du jeton).
        let trafficCalls = calls == nil ? TrafficStore.shared.diagnosticCalls(id) : []
        let traffic = trafficCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: trafficCalls, config: c.config, system: nil, token: tokens[id],
                                                                              date: TrafficStore.shared.lastRefresh ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes du trafic (FortiView) de la FortiGate")
        // Note 43 : appels des journaux d'événements de la dernière lecture (même retrait du jeton).
        let logCalls = calls == nil ? LogStore.shared.diagnosticCalls(id) : []
        let logs = logCalls.isEmpty ? "" : "\n\n" + FortiDiagnostic.text(calls: logCalls, config: c.config, system: nil, token: tokens[id],
                                                                        date: LogStore.shared.fortiLastRead[id] ?? Date())
            .replacingOccurrences(of: "réponses brutes de la FortiGate", with: "réponses brutes des journaux d’événements de la FortiGate")
        return "Site\u{00A0}: \(c.displayName)\n" + text + wifi + dhcp + wan + firmware + traffic + logs
    }

    // MARK: Wi-Fi (note 27)

    /// FortiGate choisies prêtes à lire, avec leur jeton (lecture Wi-Fi de FortiAPStore). Les
    /// autres sont rendues avec la raison pour laquelle elles ne peuvent pas être lues.
    func wifiTargets(for selection: FortiControllerSelection) async -> (ready: [(FortiGateController, String)], blocked: [UUID: String]) {
        await loadTokens()
        var ready: [(FortiGateController, String)] = []
        var blocked: [UUID: String] = [:]
        for id in selection.controllerIDs {
            guard let c = controller(id), c.isEnabled else { continue }
            if let reason = notReadyReason(c) {
                blocked[id] = reason
            } else if let token = tokens[id] {
                ready.append((c, token))
            }
        }
        return (ready, blocked)
    }

    func copyDiagnostic(_ id: UUID, calls: [FortiCallRecord]? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText(id, calls: calls), forType: .string)
    }

    // MARK: Résumé

    var switchCount: Int { sites.reduce(0) { $0 + $1.report.switches.count } }
    var deviceCount: Int { sites.reduce(0) { $0 + $1.report.locatedDevices.count } }
    /// Libellé des FortiGate lues (« Siège », « Siège, Entrepôt Laval »).
    var sitesLabel: String { sites.map(\.label).joined(separator: ", ") }
}

// MARK: - Sites vus sans être actifs (note 48)

extension FortiGateStore {
    /// Noms des FortiGate (pour les remarques des vues par site).
    var controllerNames: [UUID: String] {
        Dictionary(controllers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// Dernières lectures réussies des FortiGate d'un site (en mémoire), sans rien relire : la vue
    /// d'un site qui n'est pas le site actif (Switchs et ports, menu « Site ▾ »).
    func reports(for site: Site) -> [FortiSiteReport] {
        site.fortiGateIDs.compactMap { id in
            guard let c = controller(id), let report = runtime[id]?.report else { return nil }
            return FortiSiteReport(controllerID: id, site: c.displayName, report: report, coveredRanges: c.coveredRanges)
        }
    }

    /// Vrai si une des FortiGate données est en cours de lecture.
    func isReading(_ ids: [UUID]) -> Bool { ids.contains { runtime[$0]?.busy == true } }

    /// « Lire les FortiGate du site » (à la demande, lecture seule par l'API REST) : met à jour leur
    /// dernière lecture sans toucher aux appareils du Scanner ni aux switchs du site actif. Rien
    /// n'est envoyé en démonstration ni pendant les captures.
    func readForView(_ ids: [UUID]) {
        let wanted = ids.filter { id in controller(id)?.isEnabled == true && runtime[id]?.busy != true }
        guard !wanted.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.isDemo {
                for id in wanted { self.runtime[id, default: Runtime()].busy = true }
                try? await Task.sleep(nanoseconds: 600_000_000)
                for id in wanted { self.runtime[id]?.busy = false }
                return
            }
            await self.loadTokens()
            var jobs: [Job] = []
            for id in wanted {
                guard let c = self.controller(id) else { continue }
                if let reason = self.notReadyReason(c) {
                    self.runtime[id, default: Runtime()].error = reason
                    continue
                }
                guard let token = self.tokens[id] else { continue }
                jobs.append(Job(controller: c, token: token, generation: self.beginRead(id)))
            }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
                await FortiGateStore.performRead(config: job.controller.config, token: job.token, withInterfaces: false)
            }
            for (job, result) in zip(jobs, results) { _ = self.finishRead(job, result) }
        }
    }
}

// MARK: - Relecture automatique (note 29)

extension FortiGateStore {
    /// Résultat d'une relecture automatique.
    enum AutoOutcome: Equatable {
        /// Au moins une FortiGate du site lue.
        case success
        /// Toutes en erreur (injoignable, API) : délai croissant.
        case failure
        /// Rien de fait (lecture déjà en cours, lecture désactivée, site changé, annulée).
        case skipped
    }

    /// FortiGate du site actif que la relecture automatique peut lire (activées).
    func autoRefreshIDs(state: AppState) -> [UUID] {
        guard isEnabled else { return [] }
        return previewSelection(state: state).controllerIDs.filter { controller($0)?.isEnabled == true }
    }

    /// Raison courte pour laquelle aucune de ces FortiGate ne peut être relue sans action de
    /// l'utilisateur (nil : au moins une est prête, ou le Trousseau n'est pas encore lu).
    func autoRefreshBlockReason(_ ids: [UUID]) -> String? {
        guard !isDemo, !ids.isEmpty, tokensLoaded else { return nil }
        var reasons: [String] = []
        for id in ids {
            guard let c = controller(id) else { continue }
            if !c.config.isValid {
                reasons.append("adresse de la FortiGate invalide")
            } else if !hasToken(id) {
                reasons.append("jeton de la FortiGate absent")
            } else if runtime[id]?.pending != nil || c.pinnedFingerprint == nil {
                reasons.append("certificat de la FortiGate à accepter")
            } else {
                return nil
            }
        }
        return reasons.first
    }

    /// Relecture automatique : comme « Relire la FortiGate » (FortiSwitch, emplacements, ARP,
    /// DHCP, et les bornes si `includeWifi`), sans relancer de scan. Jamais pendant une autre
    /// lecture de ces FortiGate (bouton, fin de scan, « Tester tout »).
    func autoRefresh(state: AppState, includeWifi: Bool) async -> AutoOutcome {
        let ids = autoRefreshIDs(state: state)
        guard !ids.isEmpty, !isBusy, !isTestingAll else { return .skipped }
        let started = Date()
        let ranges = state.checkedRanges
        let next: Task<Void, Never> = Task { [weak self] in
            await self?.refresh(state: state, ranges: ranges, wifi: includeWifi, keepOnFailure: true)
        }
        refreshTask = next
        await next.value
        // « Relire » ou un changement de site a pris la place de cette lecture.
        guard !next.isCancelled, let last = lastRefresh, last >= started else { return .skipped }
        if isDemo { return .success }
        let read = ids.contains { id in
            guard let r = runtime[id], let attempt = r.lastAttempt, attempt >= started else { return false }
            return r.error == nil && !r.busy
        }
        return read ? .success : .failure
    }

    /// Dernière lecture réussie d'une de ces FortiGate, quelle qu'en soit l'origine (bouton, fin
    /// de scan, relecture automatique).
    func lastSuccess(_ ids: [UUID]) -> Date? {
        ids.compactMap { id -> Date? in
            guard let r = runtime[id], r.error == nil, !r.busy else { return nil }
            return r.report?.readAt
        }.max()
    }
}
