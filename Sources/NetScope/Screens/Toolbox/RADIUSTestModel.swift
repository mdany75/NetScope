import Foundation
import NetScopeCore

extension RADIUSOutcome {
    var tone: Tone {
        switch self {
        case .accepted: return .success
        case .rejected, .challenge: return .warning
        case .invalidResponse, .silent, .networkError: return .critical
        }
    }

    fileprivate var recentStatus: ToolRecent.Status {
        switch self {
        case .accepted: return .ok
        case .rejected, .challenge: return .warning
        case .invalidResponse, .silent, .networkError: return .failure
        }
    }
}

/// Test RADIUS (note 117). Le mot de passe n'est gardé que jusqu'au clic ; le secret partagé, le
/// temps de l'écran, et au Trousseau seulement sur demande explicite.
@MainActor
final class RADIUSTestModel: ObservableObject {
    static let shared = RADIUSTestModel()

    @Published var server = "" { didSet { refreshSavedSecret() } }
    @Published var port = "\(RADIUSRequest.defaultPort)"
    @Published var sharedSecret = ""
    @Published var username = ""
    @Published var password = ""
    @Published var rememberSecret = false
    @Published private(set) var hasSavedSecret = false
    @Published private(set) var isRunning = false
    @Published private(set) var result: RADIUSResult?
    @Published var error: String?
    @Published private(set) var notice: (tone: Tone, message: String)?

    let isDemo = CommandLine.arguments.contains("--demo")
    private let keychain = UpdKeychain(service: RADIUSClient.keychainService)
    private var openViews = 0

    private init() {
        if isDemo {
            server = RADIUSDemo.server
            username = RADIUSDemo.username
            hasSavedSecret = true
            result = RADIUSDemo.result()
        }
    }

    var portValue: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    private var host: String { server.trimmingCharacters(in: .whitespaces) }
    private var account: String { username.trimmingCharacters(in: .whitespaces) }

    var canRun: Bool {
        !isRunning && !host.isEmpty && !account.isEmpty && !password.isEmpty && (!sharedSecret.isEmpty || hasSavedSecret)
    }

    /// Jamais le mot de passe ni le secret, seulement des marques à remplacer.
    var command: String {
        let target = host.isEmpty ? "<serveur>" : host
        return "radtest \(account.isEmpty ? "<compte>" : account) <mot-de-passe> \(target):\(portValue ?? RADIUSRequest.defaultPort) 0 <secret>"
    }

    private func refreshSavedSecret() {
        guard !isDemo else { return }
        hasSavedSecret = !host.isEmpty && keychain.contains(RADIUSClient.keychainAccount(server: host))
    }

    func run(store: ToolStore) {
        guard !isRunning else { return }
        guard let port = portValue, port > 0 else {
            error = "Port invalide (1 à 65\u{202F}535)."
            return
        }
        let request = RADIUSRequest(server: host, port: port, username: account)
        let typed = sharedSecret
        let secretToRemember = rememberSecret ? typed : ""
        let secret: String
        if !typed.isEmpty {
            secret = typed
        } else if isDemo {
            secret = "FICTIF"
        } else if let saved = keychain.string(for: RADIUSClient.keychainAccount(server: host)) {
            secret = saved
        } else {
            error = "Le secret de ce serveur n’a pas pu être lu au Trousseau\u{00A0}: le saisir à nouveau."
            return
        }
        let attempt = password
        do {
            try RADIUSClient.validate(request, secret: secret, password: attempt)
        } catch {
            self.error = error.localizedDescription
            return
        }
        password = ""
        error = nil
        notice = nil
        result = nil
        isRunning = true
        store.record(command: command)
        let demo = isDemo
        Task { [weak self] in
            var outcome: RADIUSResult?
            var failure: String?
            if demo {
                try? await Task.sleep(nanoseconds: 600_000_000)
                outcome = RADIUSDemo.result()
            } else {
                do { outcome = try await RADIUSClient.test(request, secret: secret, password: attempt) }
                catch { failure = error.localizedDescription }
            }
            self?.finish(outcome, failure: failure, secretToRemember: secretToRemember, store: store)
        }
    }

    private func finish(_ result: RADIUSResult?, failure: String?, secretToRemember: String, store: ToolStore) {
        isRunning = false
        self.result = result
        error = failure
        guard let result else { return }
        if !secretToRemember.isEmpty { remember(secretToRemember, outcome: result.outcome, server: result.server) }
        store.record(ToolRecent(tool: .radius, target: result.server,
                                summary: "\(result.outcome.label) · compte \(result.username)", status: result.outcome.recentStatus))
    }

    /// Seul un secret prouvé par une réponse authentifiée est retenu : un secret mal saisi ne
    /// remplace jamais celui du Trousseau.
    private func remember(_ secret: String, outcome: RADIUSOutcome, server: String) {
        guard outcome.provesSecret else {
            notice = (.warning, "Secret non mémorisé\u{00A0}: aucune réponse authentifiée du serveur ne l’a confirmé.")
            return
        }
        guard !isDemo else { return }
        do {
            try keychain.set(secret, for: RADIUSClient.keychainAccount(server: server))
            sharedSecret = ""
            rememberSecret = false
            refreshSavedSecret()
            notice = (.success, "Secret mémorisé au Trousseau pour \(server).")
        } catch {
            notice = (.warning, "Secret non mémorisé\u{00A0}: \(error.localizedDescription)")
        }
    }

    func forgetSavedSecret() {
        guard !isDemo else { return }
        do {
            try keychain.delete(RADIUSClient.keychainAccount(server: host))
            refreshSavedSecret()
            notice = (.success, "Secret retiré du Trousseau pour \(host).")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func viewAppeared() { openViews += 1 }

    /// Passer sous la largeur compacte recrée la vue sans quitter l'outil : on attend de voir si
    /// elle revient avant d'effacer ce qui a été saisi.
    func viewDisappeared() {
        openViews -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.openViews == 0 else { return }
            self.forgetEnteredSecrets()
        }
    }

    private func forgetEnteredSecrets() {
        password = ""
        sharedSecret = ""
        rememberSecret = false
    }
}
