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

    /// Mot de passe du compte saisi à la main, au Trousseau sous « tableau-serveur-ssh:<utilisateur@hôte[:port]> » :
    /// lié au compte, il n'est jamais remis à un autre hôte (compte du carnet : celui de la connexion SSH).
    nonisolated static let manualPasswordPrefix = RustDeskServerCredentials.manualPasswordPrefix
    /// Ancien nom fixe (avant la liaison au compte) : effacé au lancement.
    nonisolated static let legacyManualPasswordAccount = "tableau-serveur-ssh"

    /// Nom du mot de passe au Trousseau pour un compte saisi (nil : compte absent ou invalide).
    nonisolated static func manualPasswordAccount(for manualAccount: String) -> String? {
        let text = manualAccount.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let account = try? RustDeskServerAccount.parse(text) else { return nil }
        return manualPasswordPrefix + account.label.lowercased()
    }

    @Published var settings: RustDeskDashboardSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.accountKey != oldValue.accountKey {
                // Autre serveur : l'état, l'erreur, l'empreinte acceptée et les échantillons de l'ancien
                // sont oubliés ; une lecture encore en cours sera ignorée à son retour.
                generation += 1
                reading = false
                status = nil
                error = nil
                acceptedHostKeyAccount = nil
                samples = []
                refreshManualPasswordFlag()
                RustDeskServerWatchModel.shared.accountChanged()
                if !isAvailable { isShown = false }
            }
            save()
            if settings.refreshSeconds != oldValue.refreshSeconds, loop != nil { restartLoop() }
            if settings.accountKey != oldValue.accountKey, loop != nil, settings.hasAccount { refresh() }
        }
    }
    @Published private(set) var samples: [RustDeskServerSample] = []
    @Published private(set) var status: RustDeskServerStatus?
    @Published private(set) var error: RustDeskServerReadError?
    @Published private(set) var reading = false
    @Published private(set) var hasManualPassword = false
    /// Onglet « Serveur RustDesk » choisi dans Accès distant.
    @Published var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            // Correctif 0.27.3 : l'onglet « Assistance RustDesk » et celui-ci s'excluent.
            if isShown {
                RustDeskModel.shared.isAssistanceShown = false
                WireGuardServerModel.shared.isShown = false
            }
            updateLoop()
        }
    }
    /// Écran Accès distant à l'écran (la lecture s'arrête dès qu'on le quitte).
    var screenVisible = false {
        didSet { if screenVisible != oldValue { updateLoop() } }
    }
    @Published var copied: String?

    /// Lectures lancées pour le compte en cours : une lecture d'un compte précédent est ignorée.
    private var generation = 0
    /// Compte (libellé) dont l'utilisateur a accepté l'empreinte inconnue : la lecture suivante
    /// l'ajoute à ~/.ssh/known_hosts (accept-new).
    private var acceptedHostKeyAccount: String?

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
            // « rustdesk-serveur-ancien » : hbbs sans « pr », console hbbr fermée, base illisible ;
            // « rustdesk-serveur-console » : console hbbs muette, processus invisibles pour ps ;
            // « rustdesk-serveur-empreinte » : serveur SSH inconnu, empreinte à accepter.
            switch ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            case "rustdesk-serveur"?:
                isShown = true
            case "rustdesk-serveur-erreur"?:
                isShown = true
                error = RustDeskServerDemo.unreachable
            case "rustdesk-serveur-ancien"?:
                isShown = true
                status = RustDeskServerDemo.degraded(now: Date())
                // Console hbbr fermée : les lectures récentes n'ont donné aucun échantillon
                // (voir RustDeskServerSamples.sample(from:)) ; le graphe s'arrête il y a 25 min.
                samples = samples.filter { $0.date < Date().addingTimeInterval(-25 * 60) }
            case "rustdesk-serveur-console"?:
                isShown = true
                status = RustDeskServerDemo.consoleSilent(now: Date())
            case "rustdesk-serveur-empreinte"?:
                // Première lecture refusée : aucun état encore, l'empreinte à accepter.
                isShown = true
                status = nil
                error = RustDeskServerDemo.unknownHostKey
            default:
                break
            }
        } else {
            let contents = store?.load()
            settings = contents?.settings ?? RustDeskDashboardSettings()
            // Échantillons d'un autre serveur (compte changé depuis) : écartés.
            samples = contents?.currentSamples ?? []
            if !sandboxed {
                if RustDeskModel.keychain.string(for: Self.legacyManualPasswordAccount) != nil {
                    try? RustDeskModel.keychain.set(nil, for: Self.legacyManualPasswordAccount)
                }
                refreshManualPasswordFlag()
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
    func secret() -> String? {
        guard !sandboxed else { return nil }
        if let id = settings.connectionID {
            return RemoteSessionStore.keychain.string(for: id.uuidString)
        }
        guard let key = Self.manualPasswordAccount(for: settings.manualAccount) else { return nil }
        return RustDeskModel.keychain.string(for: key)
    }

    /// Un mot de passe est enregistré pour le compte saisi actuel.
    private func refreshManualPasswordFlag() {
        guard !sandboxed, !RegEnvironment.isDemo else { return }
        hasManualPassword = Self.manualPasswordAccount(for: settings.manualAccount)
            .map { RustDeskModel.keychain.string(for: $0) != nil } ?? false
    }

    /// Enregistre (ou efface, si vide) le mot de passe du compte saisi, lié à ce compte.
    /// Faux si le compte saisi est absent ou invalide (rien n'est enregistré).
    @discardableResult
    func setManualPassword(_ value: String) -> Bool {
        guard let key = Self.manualPasswordAccount(for: settings.manualAccount) else { return false }
        hasManualPassword = !value.isEmpty
        guard !sandboxed else { return true }
        do {
            try RustDeskModel.keychain.set(value.isEmpty ? nil : value, for: key)
        } catch {
            AppLog.shared.error("RustDesk", "Mot de passe du serveur non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)")
        }
        return true
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
        let current = generation
        let acceptNew = acceptedHostKeyAccount == account.label
        Task {
            let result = await RustDeskServerSSH.run(account, secret: secret, acceptNewHostKey: acceptNew)
            // Compte changé pendant la lecture : résultat d'un autre serveur, ignoré.
            guard current == self.generation else { return }
            self.reading = false
            if case .success = result, acceptNew { self.acceptedHostKeyAccount = nil }
            switch result {
            case .success(let value):
                self.status = value
                self.error = nil
                RustDeskServerWatchModel.shared.ingest(value)
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

    /// « Accepter » l'empreinte d'un serveur inconnu : la lecture suivante l'ajoute à ~/.ssh/known_hosts.
    func acceptHostKey() {
        guard error?.kind == .unknownHostKey, let label = accountLabel else { return }
        acceptedHostKeyAccount = label
        error = nil
        refresh()
    }

    /// Plus de compte ni de serveur RustDesk réglé : l'onglet disparaît, le tableau de bord aussi.
    func hideIfUnavailable() {
        if !isAvailable, isShown { isShown = false }
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

    /// Note 86 : compte du serveur reçu d'un autre Mac (les échantillons restent ceux d'ici).
    func reloadFromDisk() {
        guard let contents = store?.load() else { return }
        if settings != contents.settings { settings = contents.settings }
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(RustDeskDashboardStore.Contents(settings: settings, samples: samples, samplesAccount: settings.accountKey))
        } catch {
            AppLog.shared.error("RustDesk", "Tableau de bord du serveur non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }
}
