import AppKit
import Foundation
import NetScopeCore

/// Note 6 (suite, 0.26.2) : tableau de bord du serveur RustDesk (lecture seule par SSH).
/// Lecture au clic sur « Actualiser » et toutes les N secondes, seulement pendant que l'onglet
/// « Serveur RustDesk » d'Accès distant est affiché. Mot de passe SSH au Trousseau seulement.
/// En démonstration et en capture : données fixes, aucun ssh, aucun fichier, aucun Trousseau.
@MainActor
final class RustDeskServerModel: ObservableObject {
    static let shared = RustDeskServerModel()

    /// Mot de passe du compte saisi à la main (compte du carnet : celui de la connexion SSH).
    nonisolated static let manualPasswordAccount = "tableau-serveur-ssh"

    @Published var settings: RustDeskDashboardSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if settings.refreshSeconds != oldValue.refreshSeconds, loop != nil { restartLoop() }
            if settings.connectionID != oldValue.connectionID || settings.manualAccount != oldValue.manualAccount {
                status = nil
                error = nil
            }
        }
    }
    @Published private(set) var samples: [RustDeskServerSample] = []
    @Published private(set) var status: RustDeskServerStatus?
    @Published private(set) var error: RustDeskServerReadError?
    @Published private(set) var reading = false
    @Published private(set) var hasManualPassword = false
    /// Onglet « Serveur RustDesk » choisi dans Accès distant.
    @Published var isShown = false {
        didSet { if isShown != oldValue { updateLoop() } }
    }
    /// Écran Accès distant à l'écran (la lecture s'arrête dès qu'on le quitte).
    var screenVisible = false {
        didSet { if screenVisible != oldValue { updateLoop() } }
    }
    @Published var copied: String?

    private let store: RustDeskDashboardStore?
    private let sandboxed: Bool
    private var loop: Task<Void, Never>?

    private init() {
        sandboxed = RegEnvironment.isSandboxed
        store = sandboxed ? nil : RustDeskDashboardStore.standard
        if RegEnvironment.isDemo {
            settings = RustDeskServerDemo.settings
            samples = RustDeskServerDemo.samples(now: Date())
            status = RustDeskServerDemo.status(now: Date())
            // Captures : NETSCOPE_REMOTE_VIEW=rustdesk-serveur ouvre le tableau de bord ;
            // « rustdesk-serveur-erreur » : serveur injoignable par SSH (dernière lecture grisée) ;
            // « rustdesk-serveur-ancien » : hbbs sans « pr », console hbbr fermée, base illisible.
            switch ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            case "rustdesk-serveur"?:
                isShown = true
            case "rustdesk-serveur-erreur"?:
                isShown = true
                error = RustDeskServerDemo.unreachable
            case "rustdesk-serveur-ancien"?:
                isShown = true
                status = RustDeskServerDemo.degraded(now: Date())
            default:
                break
            }
        } else {
            let contents = store?.load()
            settings = contents?.settings ?? RustDeskDashboardSettings()
            samples = contents?.samples ?? []
            if !sandboxed {
                hasManualPassword = RustDeskModel.keychain.string(for: Self.manualPasswordAccount) != nil
            }
        }
    }

    // MARK: Compte

    /// Connexions SSH du carnet proposées dans les réglages.
    var sshConnections: [RemoteConnection] {
        RemoteModel.shared.connections.filter { $0.proto == .ssh }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Connexion du carnet choisie (nil : compte saisi, ou connexion supprimée depuis).
    var chosenConnection: RemoteConnection? {
        settings.connectionID.flatMap { id in RemoteModel.shared.connections.first { $0.id == id && $0.proto == .ssh } }
    }

    /// Compte à utiliser, ou l'erreur à montrer.
    func resolvedAccount() -> Result<RustDeskServerAccount, RustDeskServerReadError> {
        if settings.connectionID != nil {
            guard let connection = chosenConnection else {
                return .failure(RustDeskServerReadError(kind: .account, detail: "La connexion SSH choisie n’existe plus dans le carnet."))
            }
            guard let account = RustDeskServerAccount(connection: connection) else {
                return .failure(RustDeskServerReadError(kind: .account, detail: "La connexion «\u{00A0}\(connection.name)\u{00A0}» n’a pas d’utilisateur SSH."))
            }
            return .success(account)
        }
        let text = settings.manualAccount.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return .failure(RustDeskServerReadError(kind: .account, detail: "Aucun compte SSH n’est choisi pour le serveur."))
        }
        do {
            return .success(try RustDeskServerAccount.parse(text))
        } catch {
            return .failure(RustDeskServerReadError(kind: .account, detail: (error as? LocalizedError)?.errorDescription ?? "Compte invalide."))
        }
    }

    /// « admin@assistance.exemple.ca » ou nil.
    var accountLabel: String? {
        try? resolvedAccount().get().label
    }

    /// Secret du compte : mot de passe de la connexion SSH du carnet, ou celui saisi ici (Trousseau).
    private func secret() -> String? {
        guard !sandboxed else { return nil }
        if let id = settings.connectionID {
            return RemoteSessionStore.keychain.string(for: id.uuidString)
        }
        return RustDeskModel.keychain.string(for: Self.manualPasswordAccount)
    }

    /// Enregistre (ou efface, si vide) le mot de passe du compte saisi.
    func setManualPassword(_ value: String) {
        hasManualPassword = !value.isEmpty
        guard !sandboxed else { return }
        do {
            try RustDeskModel.keychain.set(value.isEmpty ? nil : value, for: Self.manualPasswordAccount)
        } catch {
            AppLog.shared.error("RustDesk", "Mot de passe du serveur non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Onglet proposé : compte choisi, ou serveur RustDesk déjà réglé.
    var isAvailable: Bool {
        settings.hasAccount || RustDeskModel.shared.settings.isConfigured
    }

    // MARK: Carnet

    /// ID RustDesk → nom du poste (connexions RustDesk par ID du carnet).
    var book: [String: String] {
        var result: [String: String] = [:]
        for connection in RemoteModel.shared.connections where connection.proto == .rustdesk {
            if let id = RustDeskID.parse(connection.host), result[id] == nil { result[id] = connection.name }
        }
        return result
    }

    // MARK: Lecture

    /// Ouvre l'onglet du tableau de bord dans Accès distant.
    func open(in state: AppState) {
        RemoteSessionStore.shared.select(nil)
        RemoteModel.shared.draft = nil
        RemoteModel.shared.tunnelDraft = nil
        isShown = true
        state.open(.acces)
    }

    func refresh() {
        guard !reading else { return }
        if RegEnvironment.isDemo {
            reading = true
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let now = Date()
                self.status = RustDeskServerDemo.status(now: now)
                self.error = nil
                self.reading = false
            }
            return
        }
        guard !sandboxed else { return }
        let account: RustDeskServerAccount
        switch resolvedAccount() {
        case .success(let value): account = value
        case .failure(let failure):
            error = failure
            return
        }
        reading = true
        let secret = secret()
        Task {
            let result = await RustDeskServerSSH.run(account, secret: secret)
            self.reading = false
            switch result {
            case .success(let value):
                self.status = value
                self.error = nil
                if let sample = RustDeskServerSamples.sample(from: value) {
                    self.samples = RustDeskServerSamples.adding(sample, to: self.samples, now: Date())
                    self.save()
                }
            case .failure(let failure):
                // L'état précédent reste affiché (grisé par l'écran) avec l'erreur au-dessus.
                if self.error != failure {
                    AppLog.shared.warning("RustDesk", "Tableau de bord du serveur\u{00A0}: \(failure.title) — \(failure.detail)")
                }
                self.error = failure
            }
        }
    }

    private func updateLoop() {
        if isShown && screenVisible {
            if loop == nil { restartLoop() }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    private func restartLoop() {
        loop?.cancel()
        // Pas de lecture répétée en capture : l'état de démonstration est déjà là.
        guard !RegEnvironment.isSnapshot else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.hasAccount { self.refresh() }
                let delay = UInt64(RustDeskDashboardSettings.clampRefresh(self.settings.refreshSeconds)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    // MARK: Copies

    /// « Copier la commande » : la commande ssh équivalente avec le script complet (aucun secret).
    func copyCommand() {
        guard let account = try? resolvedAccount().get() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RustDeskServerSSH.copyableCommand(account), forType: .string)
        flash("Commande copiée")
    }

    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self.copied == text { self.copied = nil }
        }
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(RustDeskDashboardStore.Contents(settings: settings, samples: samples))
        } catch {
            AppLog.shared.error("RustDesk", "Tableau de bord du serveur non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }
}
