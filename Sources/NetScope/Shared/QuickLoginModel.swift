import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 52 : connexion rapide avec nom d'utilisateur. Chaque bouton « SSH » (Scanner, fiche
// Appareil, scan des ports) et chaque connexion SSH ou Telnet du carnet sans utilisateur passent
// par `QuickLoginModel.ask` : la feuille demande le nom (prérempli : appareil, site, identifiant
// SSH des Réglages), puis Terminal ouvre « ssh user@ip ». Le choix est retenu par appareil dans
// ssh-utilisateurs.json, sans aucun secret (le mot de passe reste au Trousseau ou est demandé par
// ssh dans Terminal).

/// Appareil ou connexion visé par la feuille.
struct QuickLoginTarget: Identifiable, Equatable {
    let id = UUID()
    /// Nom affiché (« Switch cœur », « SW-CORE-01 »).
    var name: String
    var device: QuickLoginDevice
    var proto: RemoteProtocol
    /// Port connu d'avance (connexion du carnet, port SSH ouvert non standard).
    var port: Int?
    /// Dossier du carnet si la connexion y est enregistrée.
    var folder: String?
    /// Connexion du carnet d'où vient la feuille (mise à jour au lieu d'en ajouter une autre).
    var connectionID: UUID?

    init(name: String, device: QuickLoginDevice, proto: RemoteProtocol = .ssh, port: Int? = nil, folder: String? = nil,
         connectionID: UUID? = nil) {
        self.name = name
        self.device = device
        self.proto = proto
        self.port = port
        self.folder = folder
        self.connectionID = connectionID
    }

    /// Appareil du Scanner, de la fiche Appareil ou de l'Inventaire.
    @MainActor
    init(device: Device, proto: RemoteProtocol = .ssh) {
        self.init(name: device.displayName,
                  device: QuickLoginDevice(host: device.ip.description, mac: device.mac?.formatted(.upperColon),
                                           siteID: SiteModel.shared.list.activeID),
                  proto: proto,
                  port: Self.alternateSSHPort(device, proto: proto))
    }

    /// SSH sur un port non standard ouvert (2222, 8022, 22222) quand le 22 est fermé.
    private static func alternateSSHPort(_ device: Device, proto: RemoteProtocol) -> Int? {
        guard proto == .ssh, !device.openPorts.contains(22) else { return nil }
        return device.openPorts.first { [2222, 8022, 22_222].contains($0) }.map(Int.init)
    }

    /// Adresse seule (scan des ports d'un hôte saisi) : l'appareil est retrouvé dans l'état par son IP.
    @MainActor
    init(host: String, state: AppState?) {
        if let device = state?.devices.first(where: { $0.ip.description == host }) {
            self.init(device: device)
        } else {
            self.init(name: host, device: QuickLoginDevice(host: host, siteID: SiteModel.shared.list.activeID))
        }
    }

    /// Note 57 : connexion du carnet ouverte dans Terminal plutôt que dans un onglet de NetScope.
    var inTerminalApp = false

    /// Connexion du carnet (Accès distant) enregistrée sans utilisateur.
    @MainActor
    init(connection: RemoteConnection, inTerminalApp: Bool = false) {
        self.init(name: connection.name,
                  device: QuickLoginDevice(host: connection.host, siteID: SiteModel.shared.list.activeID),
                  proto: connection.proto, port: connection.port, folder: connection.folder, connectionID: connection.id)
        self.inTerminalApp = inTerminalApp
    }
}

@MainActor
final class QuickLoginModel: ObservableObject {
    static let shared = QuickLoginModel()

    @Published private(set) var memory: QuickLoginMemory
    /// Feuille ouverte.
    @Published var target: QuickLoginTarget?
    /// Erreur d'ouverture d'une connexion lancée sans feuille (« Ne plus demander »).
    @Published var failure: String?
    /// Dernière connexion ouverte (« SSH admin@10.0.0.2 ouvert dans Terminal »), montrée
    /// quelques secondes en bas de la fenêtre (seul retour quand « Ne plus demander » est coché).
    @Published private(set) var lastOpened: String?
    private var lastOpenedTask: Task<Void, Never>?

    private let url: URL?

    static var fileURL: URL { RegBackupController.dataDirectory.appendingPathComponent(QuickLoginMemory.fileName) }

    private init() {
        if RegEnvironment.isDemo {
            url = nil
            memory = QuickLoginDemo.memory(credentials: RegRemoteCredentialStore.shared.credentials)
        } else if RegEnvironment.isSandboxed {
            url = nil
            memory = QuickLoginMemory()
        } else {
            url = Self.fileURL
            memory = QuickLoginMemory.load(from: Self.fileURL)
        }
    }

    var credentials: [RemoteCredential] {
        RegRemoteCredentialStore.shared.credentials.filter { $0.kind == .ssh }
    }

    /// Préremplissage de la feuille pour cette cible.
    func suggestion(for target: QuickLoginTarget) -> QuickLoginSuggestion {
        var suggestion = memory.suggestion(for: target.device, proto: target.proto, credentials: credentials)
        // Port de la connexion du carnet, ou port SSH non standard ouvert, s'il n'est pas déjà retenu.
        if let port = target.port, suggestion.source != .device { suggestion.choice.port = port }
        return suggestion
    }

    /// Choix retenu pour l'appareil (nom affiché sur le bouton SSH), ou nil.
    func remembered(_ target: QuickLoginTarget) -> QuickLoginEntry? {
        memory.entry(for: target.device, proto: target.proto)
    }

    /// Noms proposés dans la liste de la feuille.
    var knownUsers: [String] { memory.knownUsers(credentials: credentials) }

    /// Bouton SSH : feuille, ou connexion directe si « Ne plus demander » est coché pour
    /// l'appareil (⌥ au clic ou `force` : feuille quand même).
    func ask(_ target: QuickLoginTarget, force: Bool = false) {
        let suggestion = suggestion(for: target)
        let optionDown = NSEvent.modifierFlags.contains(.option)
        if suggestion.skipPrompt, !force, !optionDown {
            do {
                try open(suggestion.choice, for: target, skipPrompt: true, saveToBook: false)
            } catch {
                failure = Self.describe(error)
            }
            return
        }
        self.target = target
    }

    /// Lance la connexion, retient le choix pour l'appareil et, au besoin, l'ajoute au carnet.
    func open(_ choice: QuickLoginChoice, for target: QuickLoginTarget, skipPrompt: Bool, saveToBook: Bool) throws {
        let valid = try choice.validated()
        // Forme user@ip vers un autre hôte que l'appareil : le choix est retenu pour CET hôte
        // (sans la MAC de l'appareil d'origine), jamais pour l'appareil de la feuille.
        let otherHost = valid.host.caseInsensitiveCompare(target.device.host) != .orderedSame
        let device = otherHost ? QuickLoginDevice(host: valid.host, siteID: target.device.siteID) : target.device
        let name = otherHost ? valid.host : RemoteShell.sanitizedTitle(target.name)
        let plan = try QuickLogin.plan(for: valid, name: name)
        let address = QuickLoginAddress(user: valid.user, host: valid.host, port: valid.port)
            .formatted(defaultPort: valid.proto.defaultPort)
        let title = "\(name) · " + address
        // Note 57 : connexion du carnet d'Accès distant : onglet de terminal intégré à NetScope.
        if let connectionID = target.connectionID, !target.inTerminalApp,
           var connection = RemoteModel.shared.connections.first(where: { $0.id == connectionID }),
           connection.host.caseInsensitiveCompare(valid.host) == .orderedSame {
            connection.username = valid.user
            connection.port = valid.port
            memory.remember(valid, for: device, skipPrompt: skipPrompt)
            persist()
            RemoteModel.shared.saveQuickConnection(QuickLogin.connection(for: valid, name: name, folder: target.folder ?? ""),
                                                   originID: connectionID, saveToBook: saveToBook)
            // Nom choisi dans la feuille (même vide : celui du Mac) : la feuille ne revient pas.
            RemoteModel.shared.connect(connection, askUser: false)
            return
        }
        if RegEnvironment.isSandboxed {
            // Captures et démonstration : rien n'est lancé (aucun trafic vers les adresses fictives).
            showOpened("Démonstration\u{00A0}: \(valid.proto.label.lowercased()) \(address) non lancé")
        } else {
            try RemoteExecutor.execute(plan, title: title)
            showOpened("\(valid.proto.label) \(address) ouvert dans \(plan.appName)")
        }
        memory.remember(valid, for: device, skipPrompt: skipPrompt)
        persist()
        if saveToBook || target.connectionID != nil {
            let folder = target.folder ?? SiteModel.shared.list.active?.name ?? ""
            RemoteModel.shared.saveQuickConnection(QuickLogin.connection(for: valid, name: name, folder: folder),
                                                   originID: target.connectionID, saveToBook: saveToBook)
        }
    }

    private func showOpened(_ message: String) {
        lastOpened = message
        lastOpenedTask?.cancel()
        lastOpenedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastOpened = nil
        }
    }

    /// Note 78 : nom utilisé en RDP ou en SFTP (carnet, navigateur de fichiers) retenu pour
    /// l'appareil et son site, comme ceux de la feuille ; « Ne plus demander » de l'appareil est gardé.
    func rememberUse(proto: RemoteProtocol, host: String, user: String, port: Int) {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let choice = try? QuickLoginChoice(proto: proto, host: host, user: trimmed, port: port).validated() else { return }
        let device = QuickLoginDevice(host: choice.host, siteID: SiteModel.shared.list.activeID)
        let previous = memory.entry(for: device, proto: proto)
        memory.remember(choice, for: device, skipPrompt: previous?.skipPrompt ?? false)
        persist()
    }

    /// Note 78 : nom proposé pour une connexion ouverte sans utilisateur (appareil, site, compte SSH
    /// de l'appareil pour SFTP), ou "".
    func suggestedUser(proto: RemoteProtocol, host: String) -> String {
        let device = QuickLoginDevice(host: host, siteID: SiteModel.shared.list.activeID)
        return memory.suggestion(for: device, proto: proto, credentials: credentials).choice.user
    }

    /// « Oublier cet appareil » : la feuille revient, sans le nom retenu.
    func forget(_ target: QuickLoginTarget) {
        memory.forget(target.device, proto: target.proto)
        persist()
    }

    /// Feuille de nouveau montrée à chaque connexion (décoche « Ne plus demander »).
    func askAgain(_ target: QuickLoginTarget) {
        guard let entry = remembered(target) else { return }
        memory.remember(entry.choice, for: target.device, skipPrompt: false, now: entry.lastUsed)
        persist()
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Note 86 : noms retenus reçus d'un autre Mac, relus sans redémarrer.
    func reloadFromDisk() {
        guard let url else { return }
        memory = QuickLoginMemory.load(from: url)
    }

    private func persist() {
        guard let url else { return }
        do {
            try memory.save(to: url)
        } catch {
            AppLog.shared.error("Connexion SSH", "Enregistrement des noms d’utilisateur SSH impossible\u{00A0}: \(error.localizedDescription)")
        }
    }
}

// MARK: - Présentation

extension View {
    /// Feuille de connexion rapide (note 52), une seule pour toute la fenêtre.
    func quickLoginPrompt() -> some View {
        modifier(QuickLoginPresenter())
    }
}

private struct QuickLoginPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = QuickLoginModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { snapshotSheet }
            .overlay(alignment: .bottom) { openedToast }
            .sheet(item: $model.target) { target in
                QuickLoginSheet(target: target, dismiss: { model.target = nil })
            }
            .alert("Connexion impossible", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK", role: .cancel) { model.failure = nil }
            } message: {
                Text(model.failure ?? "")
            }
    }

    /// Confirmation de la dernière connexion ouverte (« SSH admin@10.0.0.2 ouvert dans Terminal »).
    @ViewBuilder private var openedToast: some View {
        if let message = model.lastOpened {
            Label(message, systemImage: "terminal")
                .font(Theme.bodyMedium)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().strokeBorder(Theme.border))
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.2), radius: 8, y: 3)
                .padding(.bottom, 18)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Captures (NETSCOPE_SSH_FEUILLE) : la feuille dessinée par-dessus la fiche Appareil, sous
    /// la barre d'outils, comme une feuille de macOS (une vraie feuille ne se capture pas hors écran).
    @ViewBuilder private var snapshotSheet: some View {
        if QuickLoginDemo.showsSheet, state.screen == .appareil, let device = state.selectedDevice {
            ZStack(alignment: .top) {
                Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                QuickLoginSheet(target: QuickLoginTarget(device: device), inline: true, dismiss: {})
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
            }
        }
    }
}

/// Bouton « SSH » commun (fiche Appareil, Scanner) : nom retenu dans le libellé, menu pour en
/// changer ou l'oublier.
struct QuickLoginSSHButton<MenuLabel: View>: View {
    @ObservedObject private var model = QuickLoginModel.shared
    let target: QuickLoginTarget
    @ViewBuilder var label: (QuickLoginEntry?) -> MenuLabel

    var body: some View {
        let entry = model.remembered(target)
        // Bouton ordinaire (un menu à action principale s'afficherait grisé) ; changer ou oublier
        // l'utilisateur : clic droit, ou ⌥-clic pour la feuille.
        Button { model.ask(target) } label: { label(entry) }
            .contextMenu {
                Button("Se connecter en tant que…") { model.ask(target, force: true) }
                if let entry {
                    Divider()
                    if entry.skipPrompt {
                        Button("Demander l’utilisateur à chaque connexion") { model.askAgain(target) }
                    }
                    Button("Oublier l’utilisateur de cet appareil") { model.forget(target) }
                }
            }
            .help(QuickLoginFormat.help(entry: entry, host: target.device.host))
    }
}

enum QuickLoginFormat {
    /// « SSH · admin », « SSH… ».
    static func buttonTitle(_ entry: QuickLoginEntry?) -> String {
        guard let entry, !entry.user.isEmpty else { return entry == nil ? "SSH…" : "SSH" }
        return "SSH · \(entry.user)"
    }

    static func help(entry: QuickLoginEntry?, host: String) -> String {
        guard let entry else { return "Se connecter en SSH à \(host)\u{00A0}: l’utilisateur est demandé" }
        let address = QuickLoginAddress(user: entry.user, host: host, port: entry.port).formatted()
        return entry.skipPrompt
            ? "Ouvre ssh \(address) dans Terminal sans rien demander (⌥-clic\u{00A0}: changer d’utilisateur\u{00A0}; clic droit\u{00A0}: l’oublier)"
            : "Se connecter en SSH à \(host) (dernier utilisateur\u{00A0}: \(entry.user.isEmpty ? "celui du Mac" : entry.user)\u{00A0}; clic droit\u{00A0}: l’oublier)"
    }
}
