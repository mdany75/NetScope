import AppKit
import Foundation
import NetScopeCore

/// Réglages de l'onglet « Serveur WireGuard » (fichier de NetScope, aucun secret).
struct WireGuardDashboardSettings: Codable, Equatable {
    /// « http://hôte:51821 » de wg-easy (vide : lecture par SSH seulement).
    var apiURL = ""
    /// Compte administrateur de wg-easy (mot de passe au Trousseau).
    var apiUser = "admin"
    var container = WireGuardServerScript.defaultContainer
    var watch = WireGuardWatchSettings()
    /// Clé du serveur lue la première fois (alerte si elle change).
    var knownServerKey: String?
    var samples: [WireGuardSample] = []
}

/// Action à confirmer : modifications par l'API (une ou plusieurs) ou mise à jour de l'image.
struct WireGuardPendingAction: Identifiable, Equatable {
    enum Kind: Equatable { case api([WGEasyChange]), updateImage }
    let id = UUID()
    var kind: Kind
    var title: String
    var confirmLabel: String
    var consequences: [String]
    var destructive = false
}

struct WireGuardShownConfig: Identifiable {
    let id = UUID()
    var name: String
    var text: String
}

/// Changement fait, gardé en mémoire pour le retour arrière (fiche d'avant, sans clé).
struct WireGuardChangeRecord: Identifiable, Equatable {
    let id = UUID()
    var date: Date
    var summary: String
    var ok: Bool
    /// Modification inverse (nil : rien à défaire, par exemple une suppression).
    var undo: WGEasyChange?
    var steps: [RustDeskActionStep] = []
}

/// Note 100 (1.3.0) : onglet « Serveur WireGuard » d'Accès distant. Lecture par SSH avec le compte
/// et le sudo du serveur RustDesk ; gestion des clients par l'API de wg-easy 15 (HTTP Basic, mot
/// de passe au Trousseau seulement) ; refus 401 ou 2FA → lecture seule. Démonstration et captures :
/// données fixes, aucun ssh, aucune requête, aucun Trousseau.
@MainActor
final class WireGuardServerModel: ObservableObject {
    static let shared = WireGuardServerModel()
    nonisolated static let apiPasswordPrefix = "wg-easy-api:"

    @Published var settings: WireGuardDashboardSettings {
        didSet { if settings != oldValue { save() } }
    }
    @Published private(set) var status: WireGuardServerStatus?
    @Published private(set) var error: RustDeskServerReadError?
    @Published private(set) var apiClients: [WGEasyClient]?
    @Published private(set) var apiInfo: WGEasyInformation?
    @Published private(set) var apiError: WGEasyAPIError?
    @Published private(set) var reading = false
    @Published private(set) var hasAPIPassword = false
    @Published var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            if isShown {
                RustDeskServerModel.shared.isShown = false
                RustDeskModel.shared.isAssistanceShown = false
            }
            updateLoop()
        }
    }
    var screenVisible = false {
        didSet { if screenVisible != oldValue { updateLoop() } }
    }

    // Confirmation, résultats, fichier .conf montré.
    @Published var pending: WireGuardPendingAction?
    @Published private(set) var running = false
    @Published private(set) var history: [WireGuardChangeRecord] = []
    @Published var lastResult: WireGuardChangeRecord?
    /// Fichier .conf montré (feuille) : oublié à la fermeture, jamais écrit sur disque.
    @Published var shownConfig: WireGuardShownConfig?
    @Published var selection = Set<String>()
    @Published var showSettings = false
    @Published var addingClient = false
    @Published var copied: String?

    private let fileURL: URL?
    private var loop: Task<Void, Never>?
    private let sandboxed: Bool

    private init() {
        sandboxed = RegEnvironment.isSandboxed
        if RegEnvironment.isDemo {
            fileURL = nil
            let now = Date()
            settings = WireGuardDashboardSettings(apiURL: WireGuardServerDemo.apiURL, watch: WireGuardServerDemo.watch,
                                                  knownServerKey: WireGuardServerDemo.serverKey, samples: WireGuardServerDemo.samples(now: now))
            status = WireGuardServerDemo.status(now: now)
            apiClients = WireGuardServerDemo.apiClients(now: now)
            apiInfo = WireGuardServerDemo.information
            hasAPIPassword = true
            history = [WireGuardChangeRecord(date: now.addingTimeInterval(-2 * 86_400), summary: "Client «\u{00A0}Fournisseur – accès temporaire\u{00A0}» ajouté (expire dans 5 jours).",
                                             ok: true, undo: nil)]
            // Captures : NETSCOPE_REMOTE_VIEW=wireguard-serveur (tableau de bord), « wireguard-serveur-2fa »
            // (API refusée, lecture seule), « wireguard-serveur-14 » (wg-easy 14), « wireguard-serveur-confirmer ».
            switch ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] {
            case "wireguard-serveur"?:
                isShown = true
            case "wireguard-serveur-2fa"?:
                isShown = true
                apiClients = nil
                apiInfo = nil
                apiError = WGEasyAPIError(.twoFactor, "HTTP 401")
            case "wireguard-serveur-14"?:
                isShown = true
                apiClients = nil
                apiInfo = nil
                apiError = WGEasyAPIError(.notVersion15, "HTTP 404 sur /api/client")
                status = WireGuardServerDemo.status(now: now, edition: .v14)
            case "wireguard-serveur-confirmer"?:
                isShown = true
                if let client = apiClients?.first(where: { $0.id == 6 }) { askToggle(client.id, name: client.name, enable: false) }
            default:
                break
            }
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("NetScope", isDirectory: true)
            fileURL = sandboxed ? nil : folder?.appendingPathComponent("serveur-wireguard.json")
            if let url = fileURL, let data = try? Data(contentsOf: url),
               let loaded = try? JSONDecoder().decode(WireGuardDashboardSettings.self, from: data) {
                settings = loaded
            } else {
                settings = WireGuardDashboardSettings()
            }
            refreshPasswordFlag()
        }
    }

    // MARK: Compte et API

    /// Même compte SSH que le serveur RustDesk.
    var server: RustDeskServerModel { RustDeskServerModel.shared }
    var isAvailable: Bool { server.isAvailable }
    var accountLabel: String? { server.accountLabel }

    var apiBase: URL? { try? WGEasyAPI.baseURL(settings.apiURL) }
    var apiInsecure: Bool { apiBase.map(WGEasyAPI.isInsecure) ?? false }

    /// Gestion possible : l'API a répondu avec la liste des clients.
    var canManage: Bool { apiClients != nil && apiError == nil }

    private var passwordKey: String? {
        guard let base = apiBase else { return nil }
        let user = settings.apiUser.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return nil }
        return Self.apiPasswordPrefix + user.lowercased() + "@" + (base.host ?? "") + ":" + String(base.port ?? 0)
    }

    private func refreshPasswordFlag() {
        guard !sandboxed, !RegEnvironment.isDemo else { return }
        hasAPIPassword = passwordKey.map { RustDeskModel.keychain.string(for: $0) != nil } ?? false
    }

    /// Mot de passe de wg-easy au Trousseau (vide : effacé). Faux si l'adresse ou le compte manque.
    @discardableResult
    func setAPIPassword(_ value: String) -> Bool {
        guard let key = passwordKey else { return false }
        hasAPIPassword = !value.isEmpty
        guard !sandboxed, !RegEnvironment.isDemo else { return true }
        do {
            try RustDeskModel.keychain.set(value.isEmpty ? nil : value, for: key)
        } catch {
            AppLog.shared.error("WireGuard", "Mot de passe de wg-easy non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)")
        }
        return true
    }

    private func apiPassword() -> String? {
        guard !sandboxed, !RegEnvironment.isDemo, let key = passwordKey else { return nil }
        return RustDeskModel.keychain.string(for: key)
    }

    func settingsChanged() {
        refreshPasswordFlag()
        apiClients = nil
        apiError = nil
        apiInfo = nil
        if !reading { refresh() }
    }

    // MARK: Lecture

    func open(in state: AppState) {
        RemoteSessionStore.shared.select(nil)
        RemoteModel.shared.draft = nil
        RemoteModel.shared.tunnelDraft = nil
        isShown = true
        state.open(.acces)
    }

    func hideIfUnavailable() {
        if !isAvailable, isShown { isShown = false }
    }

    func refresh() {
        guard !reading else { return }
        if RegEnvironment.isDemo {
            reading = true
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.reading = false
            }
            return
        }
        guard !sandboxed else { return }
        let account: RustDeskServerAccount
        switch server.resolvedAccount() {
        case .success(let value): account = value
        case .failure(let failure):
            error = failure
            return
        }
        reading = true
        let secret = server.secret()
        let sudo = RustDeskServerWatchModel.shared.readSudoPassword()
        let container = settings.container
        let base = apiBase
        let user = settings.apiUser
        let password = apiPassword()
        Task {
            async let ssh = RustDeskServerSSH.readWireGuard(account, secret: secret, sudoPassword: sudo, container: container)
            async let api = Self.readAPI(base: base, user: user, password: password)
            let (sshResult, apiResult) = await (ssh, api)
            self.reading = false
            switch sshResult {
            case .success(let value):
                self.status = value
                self.error = nil
                if self.settings.knownServerKey == nil, let key = value.serverKey { self.settings.knownServerKey = key }
                if let sample = WireGuardSamples.sample(from: value) {
                    self.settings.samples = WireGuardSamples.adding(sample, to: self.settings.samples, now: Date())
                }
            case .failure(let failure):
                if self.error != failure { AppLog.shared.warning("WireGuard", "Serveur WireGuard\u{00A0}: \(failure.title) — \(failure.detail)") }
                self.error = failure
            }
            switch apiResult {
            case .none:
                self.apiClients = nil
                self.apiInfo = nil
                self.apiError = nil
            case .some(.success(let (clients, info))):
                self.apiClients = clients
                self.apiInfo = info
                self.apiError = nil
            case .some(.failure(let failure)):
                if self.apiError != failure { AppLog.shared.warning("WireGuard", "API de wg-easy\u{00A0}: \(failure.title) (\(failure.detail))") }
                self.apiError = failure
                if failure.readOnly { self.apiClients = nil }
            }
        }
    }

    /// nil : aucune adresse d'API réglée (lecture SSH seulement).
    private nonisolated static func readAPI(base: URL?, user: String, password: String?) async -> Result<([WGEasyClient], WGEasyInformation?), WGEasyAPIError>? {
        guard let base else { return nil }
        guard let password, !password.isEmpty else { return .failure(WGEasyAPIError(.missingPassword)) }
        switch await WGEasyHTTP.send(WGEasyAPI.clients, base: base, user: user, password: password) {
        case .failure(let error): return .failure(error)
        case .success(let data):
            do {
                let clients = try WGEasyAPI.decodeClients(data)
                let info: WGEasyInformation?
                if case .success(let raw) = await WGEasyHTTP.send(WGEasyAPI.information, base: base, user: user, password: password) {
                    info = try? WGEasyAPI.decodeInformation(raw)
                } else {
                    info = nil
                }
                return .success((clients, info))
            } catch {
                return .failure((error as? WGEasyAPIError) ?? WGEasyAPIError(.decoding))
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
        guard !RegEnvironment.isSnapshot else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.server.settings.hasAccount { self.refresh() }
                let delay = UInt64(RustDeskDashboardSettings.clampRefresh(self.server.settings.refreshSeconds)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    // MARK: Tableau

    var rows: [WireGuardClientRow] { WireGuardClientRow.rows(status: status, api: apiClients) }

    func findings(now: Date) -> [WireGuardFinding] {
        guard let status else { return [] }
        return WireGuardServerAlerts.findings(status, rows: rows, settings: settings.watch, knownKey: settings.knownServerKey, now: now)
    }

    func isImportant(_ row: WireGuardClientRow) -> Bool { settings.watch.importantKeys.contains(row.publicKey) }

    func toggleImportant(_ row: WireGuardClientRow) {
        guard !row.publicKey.isEmpty else { return }
        if let index = settings.watch.importantKeys.firstIndex(of: row.publicKey) {
            settings.watch.importantKeys.remove(at: index)
        } else {
            settings.watch.importantKeys.append(row.publicKey)
        }
    }

    /// « Accepter la nouvelle clé » après une réinstallation voulue.
    func acceptServerKey() {
        settings.knownServerKey = status?.serverKey
    }

    // MARK: Actions (confirmées)

    private func client(_ id: Int) -> WGEasyClient? { apiClients?.first { $0.id == id } }

    func askCreate(name: String, expiresAt: Date?) {
        let clean = RemoteShell.sanitizedTitle(name, limit: 60)
        guard !clean.isEmpty else { return }
        let expiry = expiresAt.map { "expire le \(Self.day($0))" } ?? "sans expiration"
        pending = WireGuardPendingAction(kind: .api([.create(name: clean, expiresAt: expiresAt)]), title: "Ajouter le client «\u{00A0}\(clean)\u{00A0}»\u{00A0}?",
                                         confirmLabel: "Ajouter",
                                         consequences: ["wg-easy crée les clés du client et lui donne la prochaine adresse libre (\(expiry)).",
                                                        "Le fichier .conf et le code QR se montrent ensuite depuis la ligne du client\u{00A0}; NetScope ne garde pas la clé privée."])
    }

    func askToggle(_ id: Int, name: String, enable: Bool) {
        pending = WireGuardPendingAction(kind: .api([.setEnabled(id: id, enable)]),
                                         title: "\(enable ? "Activer" : "Désactiver") «\u{00A0}\(name)\u{00A0}»\u{00A0}?",
                                         confirmLabel: enable ? "Activer" : "Désactiver",
                                         consequences: enable ? ["Le client peut de nouveau se connecter avec sa configuration actuelle."]
                                             : ["Le client est coupé tout de suite et ne peut plus se connecter.", "Sa configuration est gardée\u{00A0}: «\u{00A0}Annuler la dernière modification\u{00A0}» le réactive."])
    }

    func askRename(_ id: Int, from name: String, to newName: String) {
        let clean = RemoteShell.sanitizedTitle(newName, limit: 60)
        guard !clean.isEmpty, clean != name else { return }
        pending = WireGuardPendingAction(kind: .api([.rename(id: id, to: clean)]), title: "Renommer «\u{00A0}\(name)\u{00A0}»\u{00A0}?",
                                         confirmLabel: "Renommer", consequences: ["Nouveau nom\u{00A0}: «\u{00A0}\(clean)\u{00A0}». La connexion du client n’est pas touchée."])
    }

    func askExpiry(_ id: Int, name: String, date: Date?) {
        pending = WireGuardPendingAction(kind: .api([.setExpiry(id: id, date)]), title: "Changer l’expiration de «\u{00A0}\(name)\u{00A0}»\u{00A0}?",
                                         confirmLabel: "Enregistrer",
                                         consequences: [date.map { "Accès jusqu’au \(Self.day($0))\u{00A0}; wg-easy désactive le client ensuite." } ?? "Accès sans date d’expiration."])
    }

    func askDelete(_ ids: [Int]) {
        let names = ids.compactMap { client($0)?.name }
        guard !names.isEmpty else { return }
        pending = WireGuardPendingAction(kind: .api(ids.map { .delete(id: $0) }),
                                         title: names.count == 1 ? "Supprimer «\u{00A0}\(names[0])\u{00A0}»\u{00A0}?" : "Supprimer \(names.count) clients\u{00A0}?",
                                         confirmLabel: "Supprimer",
                                         consequences: ["Les clés sont détruites par wg-easy\u{00A0}: ne se défait pas (un nouveau client devra recevoir une nouvelle configuration).",
                                                        names.count > 1 ? "Clients\u{00A0}: " + names.joined(separator: ", ") + "." : "Le client est coupé tout de suite."],
                                         destructive: true)
    }

    func askBatch(enable: Bool) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        pending = WireGuardPendingAction(kind: .api(ids.map { .setEnabled(id: $0, enable) }),
                                         title: "\(enable ? "Activer" : "Désactiver") \(ids.count) client\(ids.count > 1 ? "s" : "")\u{00A0}?",
                                         confirmLabel: enable ? "Activer" : "Désactiver",
                                         consequences: [ids.compactMap { client($0)?.name }.joined(separator: ", ") + "."])
    }

    var selectedIDs: [Int] {
        rows.filter { selection.contains($0.id) }.compactMap(\.apiID)
    }

    func askUpdateImage() {
        let current = status?.container?.image ?? "ghcr.io/wg-easy/wg-easy:15"
        let connected = rows.filter { $0.isConnected(now: Date()) }.count
        var consequences = ["Configuration (/etc/wireguard) sauvegardée sur le serveur, lisible par root seulement.",
                            "Image actuelle étiquetée «\u{00A0}netscope-avant-…\u{00A0}» pour y revenir.",
                            "docker compose pull, puis up -d\u{00A0}: wg-easy redémarre (quelques secondes de coupure).",
                            "Si wg-easy ne repart pas, retour automatique à l’image précédente."]
        if connected > 0 { consequences.insert("\(connected) client\(connected > 1 ? "s" : "") connecté\(connected > 1 ? "s" : "")\u{00A0}: reconnexion automatique après la coupure.", at: 0) }
        pending = WireGuardPendingAction(kind: .updateImage, title: "Mettre à jour wg-easy (\(current))\u{00A0}?", confirmLabel: "Mettre à jour",
                                         consequences: consequences)
    }

    func undoLast() {
        guard let record = history.first(where: { $0.undo != nil }), let change = record.undo else { return }
        let title: String
        switch change {
        case .rename(_, let name): title = "Remettre le nom «\u{00A0}\(name)\u{00A0}»\u{00A0}?"
        case .setEnabled(_, let on): title = on ? "Réactiver le client\u{00A0}?" : "Désactiver de nouveau le client\u{00A0}?"
        case .setExpiry: title = "Remettre l’expiration d’avant\u{00A0}?"
        case .setDNS: title = "Remettre les DNS d’avant\u{00A0}?"
        default: return
        }
        pending = WireGuardPendingAction(kind: .api([change]), title: title, confirmLabel: "Annuler la modification",
                                         consequences: ["Retour arrière de\u{00A0}: \(record.summary)"])
    }

    var lastUndoable: WireGuardChangeRecord? { history.first { $0.undo != nil } }

    func dismiss() {
        guard !running else { return }
        pending = nil
        lastResult = nil
    }

    func confirm() {
        guard let action = pending, !running else { return }
        // La feuille se ferme : le résultat s'affiche dans l'onglet.
        pending = nil
        lastResult = nil
        switch action.kind {
        case .api(let changes): apply(changes)
        case .updateImage: updateImage()
        }
    }

    private func apply(_ changes: [WGEasyChange]) {
        running = true
        if RegEnvironment.isDemo {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                var records: [WireGuardChangeRecord] = []
                for change in changes {
                    let before = WGEasyAPI.clientID(change).flatMap { self.client($0) }
                    self.applyDemo(change)
                    records.append(WireGuardChangeRecord(date: Date(), summary: "Démonstration, rien n’est envoyé\u{00A0}: " + Self.summary(change, before: before),
                                                         ok: true, undo: WGEasyAPI.inverse(of: change, before: before)))
                }
                self.finish(records)
            }
            return
        }
        guard let base = apiBase, let password = apiPassword() else {
            running = false
            lastResult = WireGuardChangeRecord(date: Date(), summary: "Mot de passe de wg-easy absent du Trousseau.", ok: false, undo: nil)
            return
        }
        let user = settings.apiUser
        let befores = Dictionary(changes.compactMap { change in WGEasyAPI.clientID(change).flatMap { id in client(id).map { (id, $0) } } },
                                 uniquingKeysWith: { a, _ in a })
        AppLog.shared.info("WireGuard", "Modification confirmée par l’API de wg-easy (\(changes.count)).")
        Task {
            var records: [WireGuardChangeRecord] = []
            for change in changes {
                let before = WGEasyAPI.clientID(change).flatMap { befores[$0] }
                let result = await Self.send(change, base: base, user: user, password: password)
                switch result {
                case .success:
                    records.append(WireGuardChangeRecord(date: Date(), summary: Self.summary(change, before: before), ok: true,
                                                         undo: WGEasyAPI.inverse(of: change, before: before)))
                case .failure(let error):
                    records.append(WireGuardChangeRecord(date: Date(), summary: Self.summary(change, before: before) + " — échec\u{00A0}: \(error.title) (\(error.detail))",
                                                         ok: false, undo: nil))
                    if error.readOnly { self.apiError = error }
                }
            }
            self.finish(records)
            self.refresh()
        }
    }

    private func finish(_ records: [WireGuardChangeRecord]) {
        running = false
        history.insert(contentsOf: records.reversed(), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        let failed = records.filter { !$0.ok }
        lastResult = WireGuardChangeRecord(date: Date(), summary: failed.isEmpty ? (records.count == 1 ? records[0].summary : "\(records.count) modifications faites.")
                                               : failed.map(\.summary).joined(separator: "\n"), ok: failed.isEmpty, undo: nil)
        selection = []
        for record in records { AppLog.shared.info("WireGuard", record.summary) }
    }

    private nonisolated static func send(_ change: WGEasyChange, base: URL, user: String, password: String) async -> Result<Void, WGEasyAPIError> {
        if let route = WGEasyAPI.route(for: change) {
            return await WGEasyHTTP.send(route, base: base, user: user, password: password).map { _ in () }
        }
        guard let id = WGEasyAPI.clientID(change) else { return .failure(WGEasyAPIError(.decoding)) }
        // Fiche complète relue juste avant (sauvegarde), clés retirées, modification appliquée.
        switch await WGEasyHTTP.send(WGEasyAPI.client(id), base: base, user: user, password: password) {
        case .failure(let error): return .failure(error)
        case .success(let fetched):
            do {
                let body = try WGEasyAPI.updateBody(from: fetched, applying: change)
                let route = WGEasyAPI.Route(method: "POST", path: "/api/client/\(id)", body: body)
                return await WGEasyHTTP.send(route, base: base, user: user, password: password).map { _ in () }
            } catch {
                return .failure((error as? WGEasyAPIError) ?? WGEasyAPIError(.decoding))
            }
        }
    }

    static func summary(_ change: WGEasyChange, before: WGEasyClient?) -> String {
        let name = before.map { "«\u{00A0}\($0.name)\u{00A0}»" } ?? "le client"
        switch change {
        case .create(let new, let date): return "Client «\u{00A0}\(new)\u{00A0}» ajouté" + (date.map { " (expire le \(day($0)))" } ?? "") + "."
        case .rename(_, let new): return "Client \(name) renommé «\u{00A0}\(new)\u{00A0}»."
        case .setEnabled(_, let on): return "Client \(name) \(on ? "activé" : "désactivé")."
        case .setExpiry(_, let date): return "Expiration de \(name)\u{00A0}: " + (date.map(day) ?? "aucune") + "."
        case .setDNS(_, let servers): return "DNS de \(name)\u{00A0}: " + (servers?.joined(separator: ", ") ?? "ceux du serveur") + "."
        case .delete: return "Client \(name) supprimé."
        }
    }

    private func applyDemo(_ change: WGEasyChange) {
        guard var clients = apiClients else { return }
        switch change {
        case .create(let name, let date):
            let id = (clients.map(\.id).max() ?? 0) + 1
            clients.append(WGEasyClient(id: id, name: name, ipv4Address: "10.8.0.\(id + 1)", publicKey: WireGuardServerDemo.key(name), expiresAt: date,
                                        createdAt: Date()))
        case .rename(let id, let name): if let i = clients.firstIndex(where: { $0.id == id }) { clients[i].name = name }
        case .setEnabled(let id, let on): if let i = clients.firstIndex(where: { $0.id == id }) { clients[i].enabled = on }
        case .setExpiry(let id, let date): if let i = clients.firstIndex(where: { $0.id == id }) { clients[i].expiresAt = date }
        case .setDNS(let id, let dns): if let i = clients.firstIndex(where: { $0.id == id }) { clients[i].dns = dns }
        case .delete(let id): clients.removeAll { $0.id == id }
        }
        apiClients = clients.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func updateImage() {
        running = true
        if RegEnvironment.isDemo {
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let steps = [RustDeskActionStep(level: "ok", text: "Compose relu sans erreur (/srv/exemple/wg-easy)."),
                             RustDeskActionStep(level: "ok", text: "Configuration sauvegardée (lisible par root seulement)\u{00A0}: /var/backups/netscope-wgeasy-20261107-1405.tar.gz"),
                             RustDeskActionStep(level: "ok", text: "Image actuelle étiquetée ghcr.io/wg-easy/wg-easy:netscope-avant-20261107-1405."),
                             RustDeskActionStep(level: "ok", text: "docker compose pull terminé."),
                             RustDeskActionStep(level: "ok", text: "wg-easy tourne, interface wg0 active."),
                             RustDeskActionStep(level: "ok", text: "Clé publique du serveur inchangée.")]
                self.running = false
                let record = WireGuardChangeRecord(date: Date(), summary: "Démonstration, rien n’est envoyé\u{00A0}: wg-easy 15.1.0 → 15.1.2.", ok: true, undo: nil, steps: steps)
                self.history.insert(record, at: 0)
                self.lastResult = record
            }
            return
        }
        guard let account = try? server.resolvedAccount().get() else {
            running = false
            return
        }
        let secret = server.secret()
        let sudo = RustDeskServerWatchModel.shared.actionSudoPassword()
        let container = status?.container?.name ?? settings.container
        AppLog.shared.info("WireGuard", "Mise à jour de wg-easy confirmée.")
        Task {
            let outcome = await RustDeskServerSSH.updateWireGuard(account, secret: secret, sudoPassword: sudo, container: container)
            let record: WireGuardChangeRecord
            switch outcome {
            case .success(let output):
                let before = output.values["version_avant"] ?? "", after = output.values["version_apres"] ?? ""
                let summary = output.outcome == .ok ? (before.isEmpty || after.isEmpty ? "wg-easy mis à jour." : "wg-easy \(before) → \(after).")
                    : output.summary(for: .updateRustDesk)
                record = WireGuardChangeRecord(date: Date(), summary: summary, ok: output.outcome == .ok, undo: nil, steps: output.steps)
            case .failure(let error):
                record = WireGuardChangeRecord(date: Date(), summary: error.title + "\u{00A0}: " + error.detail, ok: false, undo: nil)
            }
            self.running = false
            self.history.insert(record, at: 0)
            self.lastResult = record
            AppLog.shared.info("WireGuard", record.summary)
            self.refresh()
        }
    }

    // MARK: Fichier .conf, code QR, lien à usage unique

    /// Montre le .conf (et son code QR) ; le texte est oublié à la fermeture de la feuille.
    func showConfiguration(_ id: Int) {
        guard let client = client(id) else { return }
        if RegEnvironment.isDemo {
            shownConfig = WireGuardShownConfig(name: client.name, text: WireGuardServerDemo.configuration(for: client))
            return
        }
        guard let base = apiBase, let password = apiPassword() else { return }
        let user = settings.apiUser
        Task {
            switch await WGEasyHTTP.send(WGEasyAPI.configuration(id), base: base, user: user, password: password) {
            case .success(let data):
                self.shownConfig = WireGuardShownConfig(name: client.name, text: String(decoding: data, as: UTF8.self))
            case .failure(let error):
                self.lastResult = WireGuardChangeRecord(date: Date(), summary: "Fichier .conf non lu\u{00A0}: \(error.title)", ok: false, undo: nil)
            }
        }
    }

    func copyOneTimeLink(_ id: Int) {
        if RegEnvironment.isDemo {
            flash("Lien copié (démonstration)")
            return
        }
        guard let base = apiBase, let password = apiPassword() else { return }
        let user = settings.apiUser
        Task {
            var token: String?
            if case .success(let data) = await WGEasyHTTP.send(WGEasyAPI.oneTimeLink(id), base: base, user: user, password: password) {
                token = WGEasyAPI.decodeOneTimeToken(data)
                if token == nil, case .success(let fresh) = await WGEasyHTTP.send(WGEasyAPI.client(id), base: base, user: user, password: password) {
                    token = WGEasyAPI.decodeOneTimeToken(fresh)
                }
            }
            guard let token, let url = WGEasyAPI.oneTimeURL(base: base, token: token) else {
                self.flash("Lien non créé")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            self.flash("Lien à usage unique copié")
        }
    }

    func openWebInterface() {
        guard let base = apiBase, !RegEnvironment.isDemo else { return }
        NSWorkspace.shared.open(base)
    }

    func copyCommand() {
        guard let account = try? server.resolvedAccount().get() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RustDeskServerSSH.copyableWireGuardCommand(account, container: settings.container), forType: .string)
        flash("Commande copiée")
    }

    func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self.copied == text { self.copied = nil }
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.error("WireGuard", "Réglages du serveur WireGuard non enregistrés\u{00A0}: \(error.localizedDescription)")
        }
    }
}
