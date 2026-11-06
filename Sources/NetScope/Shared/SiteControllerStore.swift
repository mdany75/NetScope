import AppKit
import Foundation
import NetScopeCore

/// Note 77 : contrôleurs UniFi Network, TP-Link Omada et Cisco Meraki, en lecture seule, comme la
/// FortiGate. Chaque contrôleur appartient à un site (Réglages › Sites › Contrôleur, sans secret
/// dans sites.json) ; son secret (clé d'API, mot de passe, client secret) est au Trousseau, service
/// com.danymenard.netscope.controleurs, compte = identifiant du contrôleur.
///
/// En fin de scan, à « Interroger les switchs » et à « Relire », les contrôleurs activés du site
/// actif sont lus (quatre à la fois au plus) : leurs switchs vont dans « Switchs et ports »
/// (marqués « via UniFi », « via Omada », « via Meraki »), l'emplacement switch/port des appareils
/// filaires et la borne des clients Wi-Fi dans le Scanner, les bornes et clients dans Wi-Fi, et les
/// clients Wi-Fi dans la reconnaissance Wi-Fi (note 84).
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de ControllerDemo.
@MainActor
final class SiteControllerStore: ObservableObject {
    static let shared = SiteControllerStore()

    nonisolated static let keychain = UpdKeychain(service: "com.danymenard.netscope.controleurs")

    /// Certificat présenté au premier contact (ou changé), avec l'adresse qui l'a présenté.
    struct PendingCertificate: Equatable {
        var fingerprint: String
        var subject: String
        var changed: Bool
        var host: String
        var port: Int
    }

    /// État en mémoire d'un contrôleur.
    struct Runtime: Equatable {
        var reading: ControllerSiteReading?
        var error: String?
        var pending: PendingCertificate?
        var busy = false
        var calls: [ControllerCallRecord] = []
        var lastAttempt: Date?
    }

    /// Résultat d'un « Tester » de la feuille d'édition (rien n'est enregistré).
    struct TestOutcome: Equatable {
        var report: ControllerReport?
        var error: String?
        var pending: PendingCertificate?
        var calls: [ControllerCallRecord] = []
        var date = Date()

        var ok: Bool { report != nil }
    }

    /// Lectures réussies des contrôleurs du site actif (les plus récentes).
    @Published private(set) var readings: [ControllerSiteReading] = []
    @Published private(set) var runtime: [UUID: Runtime] = [:]
    /// Contrôleurs dont le secret est au Trousseau.
    @Published private(set) var secretIDs: Set<UUID> = []
    @Published private(set) var lastRefresh: Date?

    let isDemo: Bool
    private var secrets: [UUID: String] = [:]
    private var secretsLoaded = false
    private var secretsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            secretIDs = Set(ControllerDemo.allControllers.map(\.id))
            secretsLoaded = true
        }
    }

    // MARK: État

    /// Contrôleurs du site actif.
    var activeControllers: [SiteController] { SiteModel.shared.activeSite?.controllers ?? [] }
    var isBusy: Bool { runtime.values.contains { $0.busy } }
    /// Au moins un contrôleur activé du site actif peut être lu.
    var hasReadyControllers: Bool { activeControllers.contains { $0.isEnabled && notReadyReason($0) == nil } }
    func hasSecret(_ id: UUID) -> Bool { secretIDs.contains(id) }

    /// Raison pour laquelle le contrôleur ne peut pas être lu (nil : prêt).
    func notReadyReason(_ c: SiteController) -> String? {
        if !c.hasValidAddress { return "adresse invalide." }
        if c.authMode.accountLabel != nil, c.account.trimmingCharacters(in: .whitespaces).isEmpty { return "identifiant à saisir." }
        if secretsLoaded, !hasSecret(c.id) { return "\(c.authMode.secretLabel.lowercased()) à saisir (Trousseau)." }
        if c.usesPinning, c.pinnedFingerprint == nil { return "certificat à accepter (« Tester » dans Réglages › Sites)." }
        return nil
    }

    /// Wi-Fi des contrôleurs du site actif, au format commun (note 84 et écran Wi-Fi).
    var wifiOverview: FortiWifiOverview { ControllerConvert.wifiOverview(readings) }

    /// Lecture d'un contrôleur (dernière réussie du site actif).
    func reading(_ id: UUID) -> ControllerSiteReading? { readings.first { $0.controllerID == id } ?? runtime[id]?.reading }

    // MARK: Trousseau

    /// Lit les secrets une seule fois, hors du fil principal (une demande de macOS ne gèle pas l'app).
    func loadSecrets() async {
        guard !isDemo, !secretsLoaded else { return }
        if secretsTask == nil {
            let ids = SiteModel.shared.sites.flatMap(\.controllers).map(\.id)
            secretsTask = Task { [weak self] in
                let found: [UUID: String] = await Task.detached(priority: .userInitiated) {
                    var map: [UUID: String] = [:]
                    for id in ids {
                        if let value = SiteControllerStore.keychain.secret(for: id.uuidString), !value.isEmpty { map[id] = value }
                    }
                    return map
                }.value
                guard let self else { return }
                // Ce qui a été saisi pendant la lecture l'emporte sur le Trousseau.
                self.secrets = found.merging(self.secrets) { _, new in new }
                self.secretIDs = Set(self.secrets.keys)
                self.secretsLoaded = true
            }
        }
        await secretsTask?.value
    }

    /// Secrets des contrôleurs d'un site supprimé, retirés du Trousseau.
    func forgetSecrets(of site: Site) {
        for c in site.controllers {
            secrets[c.id] = nil
            secretIDs.remove(c.id)
            runtime[c.id] = nil
            readings.removeAll { $0.controllerID == c.id }
            guard !isDemo else { continue }
            let account = c.keychainAccount
            Task.detached { try? SiteControllerStore.keychain.deleteSecret(account) }
        }
    }

    /// Problème du secret saisi (nil : acceptable).
    nonisolated static func secretProblem(_ value: String) -> String? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines) != value { return "Espace au début ou à la fin\u{00A0}: retirez-la." }
        if value.contains(where: { $0.isNewline }) { return "Le secret tient sur une seule ligne." }
        return nil
    }

    // MARK: Enregistrement

    /// Ajoute ou remplace un contrôleur du site ; `secret` non vide : enregistré au Trousseau.
    /// Renvoie un message d'erreur, ou nil.
    func save(_ draft: SiteController, secret: String?, siteID: UUID, state: AppState) -> String? {
        guard let site = SiteModel.shared.site(siteID) else { return "Site introuvable." }
        if let secret, !secret.isEmpty {
            if let problem = Self.secretProblem(secret) { return problem }
            if !isDemo {
                do {
                    try Self.keychain.setSecret(secret, for: draft.keychainAccount)
                } catch {
                    return "Enregistrement au Trousseau impossible\u{00A0}: \(error.localizedDescription)"
                }
            }
            secrets[draft.id] = secret
            secretIDs.insert(draft.id)
        }
        var list = site.controllers
        var copy = draft
        if let index = list.firstIndex(where: { $0.id == draft.id }) {
            // Adresse ou marque changée : l'empreinte acceptée ne vaut plus.
            if !list[index].sameTarget(as: draft), copy.pinnedFingerprint == list[index].pinnedFingerprint { copy.pinnedFingerprint = nil }
            if !list[index].sameTarget(as: draft) || list[index].siteRef != draft.siteRef || list[index].orgRef != draft.orgRef {
                runtime[draft.id] = nil
                readings.removeAll { $0.controllerID == draft.id }
            }
            list[index] = copy
        } else {
            list.append(copy)
        }
        SiteModel.shared.setControllers(list, for: siteID)
        if siteID == SiteModel.shared.activeID { siteChanged(state: state) }
        return nil
    }

    /// Retire un contrôleur du site et son secret.
    func remove(_ id: UUID, siteID: UUID, state: AppState) {
        guard let site = SiteModel.shared.site(siteID) else { return }
        SiteModel.shared.setControllers(site.controllers.filter { $0.id != id }, for: siteID)
        secrets[id] = nil
        secretIDs.remove(id)
        runtime[id] = nil
        readings.removeAll { $0.controllerID == id }
        if !isDemo { Task.detached { try? SiteControllerStore.keychain.deleteSecret(id.uuidString) } }
        if siteID == SiteModel.shared.activeID { siteChanged(state: state) }
    }

    private func setStatus(_ id: UUID, _ status: ControllerStatus) {
        guard !isDemo, let site = SiteModel.shared.sites.first(where: { $0.controllers.contains { $0.id == id } }) else { return }
        var list = site.controllers
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        // Écrit seulement quand l'état change (sites.json n'est pas réécrit à chaque lecture identique).
        if let old = list[index].lastStatus, old.kind == status.kind, old.message == status.message, old.name == status.name,
           old.version == status.version, old.switchCount == status.switchCount, old.apCount == status.apCount { return }
        list[index].lastStatus = status
        SiteModel.shared.setControllers(list, for: site.id)
    }

    // MARK: Changement de site

    /// Site actif changé : ses dernières lectures (gardées en mémoire) sont montrées, sans relire.
    func siteChanged(state: AppState) {
        refreshTask?.cancel()
        refreshTask = nil
        generation += 1
        for id in runtime.keys where runtime[id]?.busy == true { runtime[id]?.busy = false }
        guard let site = SiteModel.shared.activeSite else {
            readings = []
            SwitchStore.shared.applyVendorControllers([], state: state, locate: false)
            return
        }
        if isDemo {
            readings = ControllerDemo.readings(for: site)
            for reading in readings {
                runtime[reading.controllerID, default: Runtime()].reading = reading
                runtime[reading.controllerID]?.lastAttempt = reading.report.readAt
            }
            for c in site.controllers {
                if let error = ControllerDemo.error(for: c.id) { runtime[c.id, default: Runtime()].error = error }
            }
            lastRefresh = readings.map(\.report.readAt).max()
            // Démonstration : les appareils du site reçoivent leur switch, leur port et leur borne.
            SwitchStore.shared.applyVendorControllers(readings, state: state, locate: true)
            return
        }
        let ids = Set(site.controllers.filter(\.isEnabled).map(\.id))
        readings = runtime.values.compactMap(\.reading).filter { ids.contains($0.controllerID) && $0.siteID == site.id }
            .sorted { a, b in
                (site.controllers.firstIndex { $0.id == a.controllerID } ?? 0) < (site.controllers.firstIndex { $0.id == b.controllerID } ?? 0)
            }
        SwitchStore.shared.applyVendorControllers(readings, state: state, locate: false)
    }

    // MARK: Lecture

    /// Lecture de fin de scan (ou après « Interroger les switchs »).
    func refreshAfterScan(state: AppState) async {
        if let running = refreshTask { await running.value }
        let next: Task<Void, Never> = Task { [weak self] in await self?.refresh(state: state) }
        refreshTask = next
        await withTaskCancellationHandler { await next.value } onCancel: { next.cancel() }
    }

    /// « Relire » (Switchs et ports, Wi-Fi).
    func refreshNow(state: AppState) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh(state: state) }
    }

    private struct Job: Sendable {
        var controller: SiteController
        var secret: String
        var siteID: UUID
        var siteName: String
    }

    private enum ReadResult: Sendable {
        case success(ControllerReport)
        case failure(ControllerError, [ControllerCallRecord])
    }

    private func refresh(state: AppState) async {
        guard let site = SiteModel.shared.activeSite else { return }
        let siteID = site.id
        let enabled = site.controllers.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        if isDemo {
            for c in enabled { runtime[c.id, default: Runtime()].busy = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
            for c in enabled { runtime[c.id]?.busy = false }
            guard !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
            siteChanged(state: state)
            lastRefresh = Date()
            return
        }
        await loadSecrets()
        guard !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
        generation += 1
        let mine = generation
        var jobs: [Job] = []
        for c in enabled {
            if let reason = notReadyReason(c) {
                runtime[c.id, default: Runtime()].error = reason
                continue
            }
            guard let secret = secrets[c.id] else { continue }
            runtime[c.id, default: Runtime()].busy = true
            runtime[c.id]?.lastAttempt = Date()
            jobs.append(Job(controller: c, secret: secret, siteID: siteID, siteName: site.displayName))
        }
        guard !jobs.isEmpty else { return }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await SiteControllerStore.performRead(job.controller, secret: job.secret)
        }
        for job in jobs { runtime[job.controller.id]?.busy = false }
        guard mine == generation, !Task.isCancelled, SiteModel.shared.activeID == siteID else { return }
        var fresh: [ControllerSiteReading] = []
        for (job, result) in zip(jobs, results) {
            let id = job.controller.id
            switch result {
            case .success(let report):
                let reading = ControllerSiteReading(controllerID: id, siteID: job.siteID, siteName: job.siteName, report: report)
                runtime[id]?.reading = reading
                runtime[id]?.error = nil
                runtime[id]?.pending = nil
                runtime[id]?.calls = report.calls
                fresh.append(reading)
                setStatus(id, ControllerStatus.success(report, date: report.readAt))
            case .failure(let error, let calls):
                let (message, pending) = Self.describe(error, controller: job.controller, secret: job.secret)
                runtime[id]?.error = message
                runtime[id]?.pending = pending
                runtime[id]?.calls = calls
                AppLog.shared.error("Contrôleurs", "\(job.controller.kind.label) · \(job.controller.addressLabel)\u{00A0}: \(message)")
                setStatus(id, ControllerStatus(kind: pending != nil ? .certificate : .error, message: message, date: Date()))
                // Une lecture qui échoue garde la précédente affichée (avec son heure).
                if let previous = runtime[id]?.reading, previous.siteID == siteID { fresh.append(previous) }
            }
        }
        readings = fresh
        lastRefresh = Date()
        SwitchStore.shared.applyVendorControllers(fresh, state: state, locate: true)
    }

    nonisolated private static func performRead(_ controller: SiteController, secret: String) async -> ReadResult {
        let reader = ControllerReader(controller: controller, secret: secret, transport: ControllerURLSessionTransport(controller: controller))
        do {
            return .success(try await reader.read())
        } catch let failure as ControllerReadFailure {
            return .failure(failure.error, failure.calls)
        } catch {
            return .failure(.cannotConnect("erreur inattendue."), [])
        }
    }

    /// Message affiché (sans secret) et certificat à accepter, s'il y a lieu.
    nonisolated static func describe(_ error: ControllerError, controller: SiteController, secret: String?) -> (String, PendingCertificate?) {
        let message = ControllerRedact.clean(error.errorDescription ?? "Lecture impossible.", secrets: secret.map { [$0] } ?? [])
        switch error {
        case .certificateUnknown(let fingerprint, let subject):
            return (message, PendingCertificate(fingerprint: fingerprint, subject: subject, changed: false,
                                                host: controller.cleanHost, port: controller.effectivePort))
        case .certificateChanged(_, let presented):
            return (message, PendingCertificate(fingerprint: presented, subject: "", changed: true,
                                                host: controller.cleanHost, port: controller.effectivePort))
        default:
            return (message, nil)
        }
    }

    // MARK: Tester

    /// « Tester » de la feuille : lecture complète avec le brouillon et le secret saisi (ou celui
    /// du Trousseau). Rien n'est enregistré.
    func test(_ draft: SiteController, typedSecret: String) async -> TestOutcome {
        if isDemo {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ControllerDemo.testOutcome(for: draft)
        }
        await loadSecrets()
        let secret = typedSecret.isEmpty ? (secrets[draft.id] ?? "") : typedSecret
        guard !secret.isEmpty else {
            return TestOutcome(error: ControllerError.missingSecret.errorDescription)
        }
        switch await Self.performRead(draft, secret: secret) {
        case .success(let report):
            return TestOutcome(report: report, calls: report.calls)
        case .failure(let error, let calls):
            let (message, pending) = Self.describe(error, controller: draft, secret: secret)
            return TestOutcome(error: message, pending: pending, calls: calls)
        }
    }

    /// Enregistre le résultat d'un essai dans l'état du contrôleur (Réglages › Sites).
    func recordTest(_ outcome: TestOutcome, for id: UUID) {
        if let report = outcome.report {
            setStatus(id, ControllerStatus.success(report, date: outcome.date))
        } else if let error = outcome.error {
            setStatus(id, ControllerStatus(kind: outcome.pending != nil ? .certificate : .error, message: error, date: outcome.date))
        }
        runtime[id, default: Runtime()].calls = outcome.calls
    }

    // MARK: Diagnostic

    /// Réponses brutes de la dernière lecture (ou du dernier essai), sans secret.
    func diagnosticText(_ controller: SiteController, calls: [ControllerCallRecord]? = nil, report: ControllerReport? = nil) -> String {
        let list = calls ?? runtime[controller.id]?.calls ?? []
        return ControllerDiagnostic.text(calls: list, controller: controller, report: report ?? runtime[controller.id]?.reading?.report,
                                         secrets: secrets[controller.id].map { [$0] } ?? [], date: Date())
    }

    func copyDiagnostic(_ controller: SiteController, calls: [ControllerCallRecord]? = nil, report: ControllerReport? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticText(controller, calls: calls, report: report), forType: .string)
    }
}
