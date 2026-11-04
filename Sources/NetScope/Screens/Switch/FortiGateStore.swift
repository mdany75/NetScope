import AppKit
import Foundation
import NetScopeCore

/// Contrôleur FortiGate (note 24) : réglages de connexion (préférences), jeton de l'administrateur
/// API REST (Trousseau, service com.danymenard.netscope.fortigate), empreinte du certificat
/// acceptée, dernière lecture. Les FortiSwitch lus sont confiés à `SwitchStore`, qui les montre avec
/// les switchs SNMP ; l'emplacement donné par la FortiGate passe avant celui de SNMP.
///
/// Rien n'est envoyé en démonstration ni pendant les captures : la lecture vient de FortiGateDemo.
@MainActor
final class FortiGateStore: ObservableObject {
    static let shared = FortiGateStore()

    nonisolated static let keychain = UpdKeychain(service: "com.danymenard.netscope.fortigate")
    nonisolated static let tokenAccount = "jeton"
    private static let configKey = "NetScope.fortigate.reglages"
    private static let enabledKey = "NetScope.fortigate.actif"

    /// Certificat présenté au premier contact (ou changé), avec l'adresse et le port de la FortiGate
    /// qui l'a présenté : l'empreinte n'est jamais acceptée pour une autre adresse.
    struct PendingCertificate: Equatable {
        var fingerprint: String
        var subject: String
        var changed: Bool
        var host: String
        var port: Int
    }

    /// Réglages enregistrés (adresse, port, VDOM, empreinte acceptée), jamais le jeton.
    @Published private(set) var config: FortiGateConfig
    /// Lecture à chaque scan et avec « Interroger les switchs ».
    @Published var isEnabled: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) } }
    }
    @Published private(set) var hasToken = false
    @Published private(set) var report: FortiGateReport?
    @Published private(set) var lastError: String?
    /// Certificat en attente de l'accord de l'utilisateur.
    @Published private(set) var pendingCertificate: PendingCertificate?
    @Published private(set) var isBusy = false
    /// Résultat du dernier bouton Tester (vrai = réussi).
    @Published private(set) var testOK: Bool?
    @Published private(set) var lastCalls: [FortiCallRecord] = []
    @Published private(set) var lastAttempt: Date?

    let isDemo: Bool
    private var token: String?
    private var tokenLoaded = false
    private var task: Task<Void, Never>?
    /// Numéro de la lecture la plus récente : seul son résultat est appliqué.
    private var generation = 0
    /// Lectures en cours (`isBusy` tant qu'il en reste une).
    private var activeReads = 0 {
        didSet { isBusy = activeReads > 0 }
    }

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            config = FortiGateDemo.config
            isEnabled = true
            hasToken = true
            tokenLoaded = true
            let report = FortiGateDemo.report()
            self.report = report
            lastCalls = report.calls
            lastAttempt = report.readAt
            testOK = true
        } else {
            let data = UserDefaults.standard.data(forKey: Self.configKey)
            config = data.flatMap { try? JSONDecoder().decode(FortiGateConfig.self, from: $0) } ?? FortiGateConfig()
            isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        }
    }

    // MARK: Réglages et Trousseau

    /// Contrôleur prêt à être lu : adresse valide, jeton présent, empreinte acceptée.
    var isReady: Bool { config.isValid && hasToken && config.pinnedFingerprint != nil }
    /// Adresse saisie (même sans jeton) : la section mérite d'être montrée.
    var isConfigured: Bool { config.isValid }

    /// Raison pour laquelle la FortiGate ne peut pas encore être lue (nil si elle est prête).
    var notReadyReason: String? {
        guard !isDemo, config.isValid else { return nil }
        if !hasToken { return "Jeton absent\u{00A0}: enregistrez-le dans Réglages › Switchs." }
        if pendingCertificate != nil {
            return "Empreinte du certificat à vérifier dans Réglages › Switchs."
        }
        if config.pinnedFingerprint == nil {
            return "Empreinte du certificat à accepter\u{00A0}: cliquez sur «\u{00A0}Tester\u{00A0}» dans Réglages › Switchs."
        }
        return nil
    }

    /// Clé de comparaison de l'adresse configurée.
    private var currentTarget: (host: String, port: Int) { (config.cleanHost.lowercased(), config.effectivePort) }

    func update(host: String, port: Int, vdom: String) {
        var next = config
        let before = currentTarget
        next.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        next.port = port
        next.vdom = vdom.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = (next.cleanHost.lowercased(), next.effectivePort) != before
        // Autre FortiGate : l'empreinte acceptée ne vaut plus.
        if changed { next.pinnedFingerprint = nil }
        config = next
        saveConfig()
        if changed { forgetLastRead() }
    }

    /// Oublie tout ce qui venait de l'ancienne FortiGate : lecture en cours, résultat, empreinte en
    /// attente et FortiSwitch affichés.
    private func forgetLastRead() {
        task?.cancel()
        task = nil
        generation += 1
        pendingCertificate = nil
        testOK = nil
        lastError = nil
        report = nil
        lastCalls = []
        SwitchStore.shared.clearController()
    }

    private func saveConfig() {
        guard !isDemo, let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }

    /// Lit au Trousseau, hors du fil principal, si un jeton existe (une seule fois).
    func loadToken() async {
        guard !isDemo, !tokenLoaded else { return }
        tokenLoaded = true
        let value = await Task.detached(priority: .userInitiated) {
            FortiGateStore.keychain.string(for: FortiGateStore.tokenAccount)
        }.value
        token = value
        hasToken = !(value ?? "").isEmpty
    }

    /// Enregistre le jeton au Trousseau ; renvoie un message d'erreur.
    func saveToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Jeton vide." }
        guard trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
            return "Le jeton ne doit contenir que des lettres et des chiffres (copiez-le tel que la FortiGate l’a affiché)."
        }
        guard !isDemo else { return nil }
        do {
            try Self.keychain.set(trimmed, for: Self.tokenAccount)
            token = trimmed
            tokenLoaded = true
            hasToken = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func eraseToken() {
        guard !isDemo else { return }
        try? Self.keychain.delete(Self.tokenAccount)
        token = nil
        hasToken = false
        testOK = nil
    }

    /// Accepte l'empreinte du certificat présenté (premier contact ou renouvellement vérifié), si
    /// elle vient bien de la FortiGate configurée.
    func acceptPendingCertificate() {
        guard let pending = pendingCertificate else { return }
        pendingCertificate = nil
        testOK = nil
        guard pending.host == currentTarget.host, pending.port == currentTarget.port else {
            lastError = "L’adresse de la FortiGate a changé depuis\u{00A0}: cliquez de nouveau sur «\u{00A0}Tester\u{00A0}» pour vérifier son certificat."
            return
        }
        config.pinnedFingerprint = pending.fingerprint
        lastError = nil
        saveConfig()
    }

    func rejectPendingCertificate() {
        pendingCertificate = nil
        lastError = "Certificat refusé\u{00A0}: aucune connexion à cette FortiGate."
    }

    /// Oublie l'empreinte acceptée : le prochain contact demandera de nouveau l'accord.
    func forgetCertificate() {
        guard !isDemo else { return }
        config.pinnedFingerprint = nil
        saveConfig()
    }

    // MARK: Lecture

    /// Bouton Tester : lecture complète ; les FortiSwitch lus apparaissent aussitôt dans
    /// « Switchs et ports » (même source que le bandeau et le tableau des Réglages).
    func test(state: AppState) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            if let fresh = await self.read() {
                SwitchStore.shared.applyController(fresh, state: state)
            }
        }
    }

    /// Lecture puis report sur l'écran Switchs et ports et les appareils du scan (« Interroger les
    /// switchs », bouton Relire). Sans lecture réussie, les FortiSwitch d'une lecture précédente
    /// sont retirés : ils ne servent plus à situer les appareils.
    func refresh(state: AppState) async {
        guard isEnabled else {
            if !isDemo { SwitchStore.shared.clearController() }
            return
        }
        if isDemo {
            activeReads += 1
            try? await Task.sleep(nanoseconds: 600_000_000)
            activeReads -= 1
            let fresh = FortiGateDemo.report()
            report = fresh
            lastCalls = fresh.calls
            lastAttempt = Date()
            SwitchStore.shared.applyController(fresh, state: state)
            return
        }
        await loadToken()
        guard isReady else {
            SwitchStore.shared.clearController()
            return
        }
        let target = currentTarget
        if let fresh = await read() {
            SwitchStore.shared.applyController(fresh, state: state)
        } else if !Task.isCancelled, !isBusy, currentTarget == target {
            SwitchStore.shared.clearController()
        }
    }

    /// Lecture de fin de scan : attend une lecture déjà lancée, puis passe par `task` comme les
    /// autres (jamais deux lectures à la fois).
    func refreshAfterScan(state: AppState) async {
        if let running = task { await running.value }
        let next: Task<Void, Never> = Task { [weak self] in await self?.refresh(state: state) }
        task = next
        await withTaskCancellationHandler { await next.value } onCancel: { next.cancel() }
    }

    func refreshNow(state: AppState) {
        task?.cancel()
        task = Task { [weak self] in await self?.refresh(state: state) }
    }

    /// Lit la FortiGate ; nil en cas d'échec (message dans `lastError`) ou quand une lecture plus
    /// récente l'a remplacée (son résultat n'écrase jamais celui d'une lecture plus récente).
    private func read() async -> FortiGateReport? {
        if isDemo {
            activeReads += 1
            try? await Task.sleep(nanoseconds: 600_000_000)
            activeReads -= 1
            testOK = true
            lastError = nil
            return report
        }
        await loadToken()
        guard config.isValid else {
            fail(FortiGateError.invalidAddress)
            return nil
        }
        guard let token, !token.isEmpty else {
            fail(FortiGateError.missingToken)
            return nil
        }
        generation += 1
        let mine = generation
        let target = currentTarget
        activeReads += 1
        defer { activeReads -= 1 }
        lastAttempt = Date()
        let transport = FortiURLSessionTransport(config: config, token: token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: token)
        do {
            let fresh = try await reader.readKeepingCalls()
            guard !Task.isCancelled, mine == generation else { return nil }
            report = fresh
            lastCalls = fresh.calls
            lastError = nil
            testOK = true
            return fresh
        } catch is CancellationError {
            return nil
        } catch let failure as FortiReadFailure {
            if mine == generation { fail(failure.error, calls: failure.calls, target: target) }
            return nil
        } catch let error as FortiGateError {
            if mine == generation { fail(error, target: target) }
            return nil
        } catch {
            if mine == generation { fail(.cannotConnect("erreur inattendue."), target: target) }
            return nil
        }
    }

    private func fail(_ error: FortiGateError, calls: [FortiCallRecord] = [], target: (host: String, port: Int)? = nil) {
        testOK = false
        let target = target ?? currentTarget
        switch error {
        case .certificateUnknown(let fingerprint, let subject):
            pendingCertificate = PendingCertificate(fingerprint: fingerprint, subject: subject, changed: false,
                                                    host: target.host, port: target.port)
            lastError = "Premier contact\u{00A0}: vérifiez l’empreinte du certificat ci-dessous puis acceptez-la."
        case .certificateChanged(_, let presented):
            pendingCertificate = PendingCertificate(fingerprint: presented, subject: "", changed: true,
                                                    host: target.host, port: target.port)
            lastError = error.errorDescription
        default:
            lastError = FortiRedact.clean(error.errorDescription ?? "Lecture impossible.", token: token)
        }
        // Les réponses reçues avant l'échec restent copiables (diagnostic).
        lastCalls = calls
    }

    // MARK: Diagnostic

    /// Réponses brutes de la dernière lecture, sans le jeton.
    var diagnosticText: String {
        FortiDiagnostic.text(calls: lastCalls, config: config, system: report?.system, token: token, date: lastAttempt ?? Date())
    }

    func copyDiagnostic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText, forType: .string)
    }

    // MARK: Résumé

    var switchCount: Int { report?.switches.count ?? 0 }
    var deviceCount: Int { report?.locatedDevices.count ?? 0 }
}
