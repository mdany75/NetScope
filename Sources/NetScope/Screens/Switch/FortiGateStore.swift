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

    /// Réglages enregistrés (adresse, port, VDOM, empreinte acceptée), jamais le jeton.
    @Published private(set) var config: FortiGateConfig
    /// Lecture à chaque scan et avec « Interroger les switchs ».
    @Published var isEnabled: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) } }
    }
    @Published private(set) var hasToken = false
    @Published private(set) var report: FortiGateReport?
    @Published private(set) var lastError: String?
    /// Certificat présenté au premier contact (ou changé), en attente de l'accord de l'utilisateur.
    @Published private(set) var pendingCertificate: (fingerprint: String, subject: String, changed: Bool)?
    @Published private(set) var isBusy = false
    /// Résultat du dernier bouton Tester (vrai = réussi).
    @Published private(set) var testOK: Bool?
    @Published private(set) var lastCalls: [FortiCallRecord] = []
    @Published private(set) var lastAttempt: Date?

    let isDemo: Bool
    private var token: String?
    private var tokenLoaded = false
    private var task: Task<Void, Never>?

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

    func update(host: String, port: Int, vdom: String) {
        var next = config
        let before = (config.cleanHost.lowercased(), config.effectivePort)
        next.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        next.port = port
        next.vdom = vdom.trimmingCharacters(in: .whitespacesAndNewlines)
        // Autre FortiGate : l'empreinte acceptée ne vaut plus.
        if (next.cleanHost.lowercased(), next.effectivePort) != before { next.pinnedFingerprint = nil }
        config = next
        saveConfig()
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
    }

    /// Accepte l'empreinte du certificat présenté (premier contact ou renouvellement vérifié).
    func acceptPendingCertificate() {
        guard let pending = pendingCertificate else { return }
        config.pinnedFingerprint = pending.fingerprint
        pendingCertificate = nil
        lastError = nil
        saveConfig()
    }

    func rejectPendingCertificate() {
        pendingCertificate = nil
    }

    /// Oublie l'empreinte acceptée : le prochain contact demandera de nouveau l'accord.
    func forgetCertificate() {
        guard !isDemo else { return }
        config.pinnedFingerprint = nil
        saveConfig()
    }

    // MARK: Lecture

    /// Bouton Tester : lecture complète, sans toucher aux appareils du scan.
    func test() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            _ = await self.read()
        }
    }

    /// Lecture puis report sur l'écran Switchs et ports et les appareils du scan (fin de scan,
    /// « Interroger les switchs », bouton Rafraîchir).
    func refresh(state: AppState) async {
        guard isEnabled else { return }
        if isDemo {
            isBusy = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            isBusy = false
            let fresh = FortiGateDemo.report()
            report = fresh
            lastCalls = fresh.calls
            lastAttempt = Date()
            SwitchStore.shared.applyController(fresh, state: state)
            return
        }
        await loadToken()
        guard isReady else { return }
        if let fresh = await read() {
            SwitchStore.shared.applyController(fresh, state: state)
        }
    }

    func refreshNow(state: AppState) {
        task?.cancel()
        task = Task { [weak self] in await self?.refresh(state: state) }
    }

    /// Lit la FortiGate ; nil en cas d'échec (message dans `lastError`).
    private func read() async -> FortiGateReport? {
        if isDemo {
            isBusy = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            isBusy = false
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
        isBusy = true
        defer { isBusy = false }
        lastAttempt = Date()
        let transport = FortiURLSessionTransport(config: config, token: token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: token)
        do {
            let fresh = try await reader.read()
            guard !Task.isCancelled else { return nil }
            report = fresh
            lastCalls = fresh.calls
            lastError = nil
            testOK = true
            return fresh
        } catch is CancellationError {
            return nil
        } catch let error as FortiGateError {
            fail(error)
            return nil
        } catch {
            fail(.cannotConnect("erreur inattendue."))
            return nil
        }
    }

    private func fail(_ error: FortiGateError) {
        testOK = false
        switch error {
        case .certificateUnknown(let fingerprint, let subject):
            pendingCertificate = (fingerprint, subject, false)
            lastError = "Premier contact\u{00A0}: vérifiez l’empreinte du certificat ci-dessous puis acceptez-la."
        case .certificateChanged(_, let presented):
            pendingCertificate = (presented, "", true)
            lastError = error.errorDescription
        default:
            lastError = FortiRedact.clean(error.errorDescription ?? "Lecture impossible.", token: token)
        }
        lastCalls = []
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
