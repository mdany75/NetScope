import AppKit
import NetScopeCore
import SwiftUI

/// Note 52 : feuille « Se connecter en SSH » demandée avant chaque connexion rapide — utilisateur
/// (prérempli, liste des noms déjà utilisés, saisie libre ou « user@ip »), port, identifiant SSH
/// des Réglages, méthode (automatique, clé, mot de passe), commande exacte, « Ne plus demander
/// pour cet appareil » et « Enregistrer dans le carnet ». ↩︎ se connecte, Échap annule.
struct QuickLoginSheet: View {
    @ObservedObject private var model = QuickLoginModel.shared
    let target: QuickLoginTarget
    /// Dessinée dans la page (captures) plutôt que dans une feuille.
    var inline = false
    let dismiss: () -> Void

    @State private var user = ""
    @State private var port = ""
    @State private var auth: QuickLoginAuth = .automatic
    @State private var keyPath = ""
    @State private var credentialID: UUID?
    @State private var skipPrompt = false
    @State private var saveToBook = false
    @State private var source: QuickLoginSuggestion.Source = .none
    @State private var openError: String?
    @State private var loaded = false
    @FocusState private var userFocused: Bool

    private var isSSH: Bool { target.proto == .ssh }

    /// Choix lu dans les champs ; « admin@10.0.0.2:2222 » collé dans Utilisateur est découpé.
    private var choice: Result<QuickLoginChoice, Error> {
        Result {
            // Forme user@ip : l'hôte (et le port) écrits remplacent ceux de l'appareil.
            let address = QuickLoginAddress.splitUserField(user, defaultHost: target.device.host)
            let portText = address.port.map(String.init) ?? port
            guard let portValue = Int(portText.trimmingCharacters(in: .whitespaces)) else {
                throw RemoteValidationError.invalidPort(0)
            }
            return try QuickLoginChoice(proto: target.proto, host: address.host, user: address.user, port: portValue,
                                        auth: isSSH ? auth : .automatic, keyPath: keyPath, credentialID: credentialID).validated()
        }
    }

    private var command: Result<String, Error> {
        // Captures : dossier personnel fixe (rien du Mac qui les produit dans les images).
        let home = RegEnvironment.isSnapshot ? "/Users/dany" : NSHomeDirectory()
        return choice.flatMap { c in Result { try QuickLogin.plan(for: c, name: target.name, home: home).preview } }
    }

    private var errorText: String? {
        if case .failure(let error) = command { return QuickLoginModel.describe(error) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            Divider()
            footer
        }
        .frame(width: 500)
        .background(Theme.panel)
        .onAppear(perform: load)
    }

    // MARK: Formulaire

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isSSH, !model.credentials.isEmpty { credentialRow }
            HStack(alignment: .top, spacing: 12) {
                RegField(label: "Utilisateur") { userField }
                RegField(label: "Port") {
                    RegTextField(placeholder: String(target.proto.defaultPort), text: $port, mono: true)
                        .frame(width: 76)
                }
            }
            sourceLine
            if isSSH { methodRows }
            commandPreview
            options
        }
        .padding(20)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                Image(systemName: "terminal").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Se connecter en \(target.proto.label) à \(target.name)")
                    .font(Theme.panelTitle).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts = [target.device.host]
        if let mac = target.device.mac { parts.append(mac) }
        if let site = SiteModel.shared.list.active?.name { parts.append("site\u{00A0}: \(site)") }
        return parts.joined(separator: " · ")
    }

    /// Identifiant SSH des Réglages : reprend son nom, son port et sa clé.
    private var credentialRow: some View {
        RegField(label: "Identifiant enregistré") {
            Picker("", selection: Binding(get: { credentialID }, set: { applyCredential($0) })) {
                Text("Aucun (saisie libre)").tag(UUID?.none)
                Divider()
                ForEach(model.credentials) { credential in
                    Text("\(credential.name) · \(credential.user.isEmpty ? "sans utilisateur" : credential.user) · \(credential.methodSummary)")
                        .tag(UUID?.some(credential.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Champ libre et, à côté, menu natif des noms déjà utilisés.
    private var userField: some View {
        HStack(spacing: 6) {
            RegTextField(placeholder: "ex. admin (vide\u{00A0}: \(RegEnvironment.isSnapshot ? "dany" : NSUserName()))", text: $user, mono: true,
                         invalid: userInvalid)
                .focused($userFocused)
                .onSubmit(connect)
            Menu("Noms") {
                ForEach(model.knownUsers, id: \.self) { name in
                    Button(name) { user = name }
                }
            }
            .menuStyle(.button)
            .controlSize(.regular)
            .fixedSize()
            .help("Noms déjà utilisés")
        }
    }

    private var userInvalid: Bool {
        if case .failure(let error) = choice, let validation = error as? RemoteValidationError, case .invalidUser = validation { return true }
        return false
    }

    @ViewBuilder private var sourceLine: some View {
        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.small).foregroundStyle(Theme.critical)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(sourceText).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceText: String {
        // Exemple de saisie « utilisateur@adresse » pris sur l'appareil visé, pas sur une adresse fictive.
        let host = target.device.host
        switch source {
        case .device: return "Dernier utilisateur de cet appareil («\u{00A0}admin@\(host)\u{00A0}» est aussi accepté)."
        case .site: return "Dernier utilisateur de ce site («\u{00A0}admin@\(host):2222\u{00A0}» est aussi accepté)."
        case .credential(let name): return "Repris de l’identifiant «\u{00A0}\(name)\u{00A0}» (Réglages › Identifiants)."
        case .none: return "Lettres, chiffres, «\u{00A0}.\u{00A0}», «\u{00A0}_\u{00A0}», «\u{00A0}-\u{00A0}» et «\u{00A0}@\u{00A0}»\u{00A0}; «\u{00A0}admin@\(host)\u{00A0}» est accepté."
        }
    }

    @ViewBuilder private var methodRows: some View {
        RegField(label: "Identification") {
            RegSegmented(selection: $auth, options: QuickLoginAuth.allCases.map { .init(value: $0, label: $0.label) })
        }
        switch auth {
        case .automatic:
            hint("Clés de ~/.ssh et agent SSH, puis mot de passe demandé par ssh dans Terminal.")
        case .key:
            RegField(label: "Clé privée") {
                HStack(spacing: 6) {
                    RegTextField(placeholder: "~/.ssh/id_ed25519", text: $keyPath, mono: true)
                    Button("Choisir…", action: chooseKey).buttonStyle(.secondary)
                }
            }
        case .password:
            hint(passwordHint)
        }
    }

    private var passwordHint: String {
        let credential = credentialID.flatMap { id in model.credentials.first { $0.id == id } }
        let keychain = credential.map { " Le mot de passe de «\u{00A0}\($0.name)\u{00A0}» reste au Trousseau\u{00A0}: NetScope ne l’écrit jamais dans la commande ni sur le disque." } ?? ""
        return "ssh demande le mot de passe dans Terminal (clés désactivées).\(keychain)"
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var commandPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text((try? command.get()) ?? "—")
                .font(Theme.mono()).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(target.proto.externalApp).font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .help("Commande ouverte dans Terminal (chaque mot échappé, rien n’est interprété par le shell)")
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $skipPrompt) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ne plus demander pour cet appareil").font(Theme.body).foregroundStyle(Theme.text)
                    Text(target.proto == .ssh
                         ? "Le bouton SSH se connecte directement\u{00A0}; ⌥-clic ou clic droit pour changer d’utilisateur."
                         : "La connexion \(target.proto.label) se lance directement, sans cette feuille.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            Toggle(isOn: $saveToBook) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enregistrer dans le carnet").font(Theme.body).foregroundStyle(Theme.text)
                    Text("Ajoute ou met à jour la connexion dans Accès distant › \(bookFolder).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var bookFolder: String {
        let folder = target.folder ?? SiteModel.shared.list.active?.name ?? ""
        return folder.isEmpty ? "Non classé" : folder
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let openError {
                Text(openError).font(Theme.small).foregroundStyle(Theme.critical).lineLimit(2)
            } else {
                Text("Aucun mot de passe n’est retenu par NetScope.").font(Theme.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button("Se connecter", action: connect)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .regDisabled(errorText != nil)
                .help("Ouvre la connexion dans \(target.proto.externalApp) (↩︎)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        let suggestion = model.suggestion(for: target)
        let c = suggestion.choice
        user = c.user
        port = String(c.port)
        auth = c.auth
        keyPath = c.keyPath
        credentialID = c.credentialID.flatMap { id in model.credentials.contains { $0.id == id } ? id : nil }
        skipPrompt = suggestion.skipPrompt
        source = suggestion.source
        if !inline { userFocused = true }
    }

    private func applyCredential(_ id: UUID?) {
        credentialID = id
        guard let id, let credential = model.credentials.first(where: { $0.id == id }) else { return }
        let c = QuickLoginMemory.choice(from: credential, host: target.device.host)
        user = c.user
        port = String(c.port)
        auth = c.auth
        keyPath = c.keyPath
        source = .credential(credential.name)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Clé privée SSH"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        keyPath = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func connect() {
        guard !inline else { return }
        do {
            try model.open(try choice.get(), for: target, skipPrompt: skipPrompt, saveToBook: saveToBook)
            dismiss()
        } catch {
            openError = QuickLoginModel.describe(error)
        }
    }
}
