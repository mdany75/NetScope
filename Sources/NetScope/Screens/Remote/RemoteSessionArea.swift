import NetScopeCore
import SwiftUI

/// Zone centrale : barre d'onglets de session (note 57), puis l'onglet choisi — terminal intégré
/// (SSH, Telnet, console série) — ou l'accueil « Sessions » : formulaire de connexion, ou aperçu de
/// ce que « Connecter » va ouvrir.
struct RemoteSessionArea: View {
    @ObservedObject var model: RemoteModel
    /// telnet installé depuis l’encadré : la commande affichée (telnet ou nc) se met à jour.
    @ObservedObject private var telnet = ToolInstallMonitor.shared(.telnet)
    @ObservedObject private var files = FileTransferStore.shared
    @ObservedObject private var sessions = RemoteSessionStore.shared

    var body: some View {
        VStack(spacing: 0) {
            RemoteSessionTabBar(model: model)

            if model.draft == nil, let tab = sessions.activeTab {
                sessionContent(tab)
            } else {
                ScrollView {
                    if model.draft != nil {
                        RemoteForm(model: model)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                    } else {
                        launchOverview
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        // Formulaire ouvert (Nouvelle connexion, Modifier) : il s'affiche dans l'onglet « Sessions ».
        .onChange(of: model.draft != nil) { _, editing in
            if editing { sessions.select(nil) }
        }
        .confirmationDialog("Fermer l’onglet « \(sessions.pendingClose?.connection.name ?? "") » ?",
                            isPresented: Binding(get: { sessions.pendingClose != nil },
                                                 set: { if !$0 { sessions.pendingClose = nil } }),
                            titleVisibility: .visible) {
            Button("Fermer la session", role: .destructive) {
                if let tab = sessions.pendingClose { sessions.close(tab.id) }
            }
            Button("Annuler", role: .cancel) { sessions.pendingClose = nil }
        } message: {
            Text(sessions.pendingClose?.connection.proto == .serie
                 ? "Le port série est refermé. Le journal déjà enregistré est gardé."
                 : "La session encore ouverte est déconnectée. Le journal déjà enregistré est gardé.")
        }
    }

    /// Contenu d'un onglet de session.
    @ViewBuilder private func sessionContent(_ tab: RemoteSessionStore.Tab) -> some View {
        switch tab.content {
        case .terminal(let session):
            TerminalSessionView(session: session, model: model)
                .id(tab.id)
        case .vnc(let connection):
            if let view = RemoteSessionStore.vncView {
                view(connection).id(tab.id)
            }
        }
    }

    // MARK: Aperçu

    @ViewBuilder private var launchOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connection = model.selected {
                selectedLaunch(connection)
            } else {
                EmptyState(systemImage: "rectangle.connected.to.line.below", title: "Aucune connexion choisie",
                           message: "Choisissez une connexion à gauche, ou créez-en une.") {
                    Button("Nouvelle connexion") { model.startNew() }.buttonStyle(.secondary)
                }
                .frame(height: 220)
            }
            // Note 50 : session de fichiers ouverte pour une autre connexion (transferts en arrière-plan).
            if let session = files.session, session.connection.id != model.selected?.id {
                FileTransferBackgroundBanner(session: session, model: model)
            }
            if !sessions.tabs.isEmpty { openSessionsBox }
            FTPServerCard()

            SectionHeader("Ouvrir une connexion enregistrée").padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(recent) { connection in
                    Button {
                        model.selectedID = connection.id
                        model.connect(connection)
                    } label: {
                        HStack(spacing: 8) {
                            RemoteProtoIcon(proto: connection.proto, size: 22)
                            Text(connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(connection.address).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ouvrir \(connection.name) \(RemoteSessionArea.destination(connection.proto))")
                }
            }
            if recent.isEmpty {
                Text("Les connexions utilisées récemment apparaîtront ici.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Connexions joignables (ou non vérifiées), les plus récentes d'abord.
    private var recent: [RemoteConnection] {
        model.connections
            .filter { model.state(of: $0.id) != .unreachable }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(7)
            .map { $0 }
    }

    private func selectedLaunch(_ connection: RemoteConnection) -> some View {
        let plan = model.plan(for: connection)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RemoteProtoIcon(proto: connection.proto, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name).font(Theme.panelTitle)
                    Text(launchSubtitle(connection, plan: plan)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                RemoteConnectButton(model: model, connection: connection, large: true,
                                    isEnabled: (try? plan.get()) != nil)
            }
            terminalPreview(connection, plan: plan)
            if connection.proto == .telnet {
                SpeedBanner(text: "Telnet n’est pas chiffré : le mot de passe circule en clair. Utilisez SSH si l’appareil le permet.")
            }
            if connection.proto == .ftp {
                SpeedBanner(text: FileTransferTexts.ftpWarning)
            }
            // Note 57 : session VNC intégrée masquée (toujours ouverte).
            if connection.proto == .vnc, let vnc = VNCSessionStore.shared.session(for: connection.id), !vnc.isVisible {
                Button {
                    vnc.isVisible = true
                } label: {
                    Label("Revenir à la session VNC", systemImage: "display")
                }
                .buttonStyle(.secondary)
            }
            if connection.proto.isFileTransfer, files.session?.connection.id == connection.id, files.session?.isVisible == false {
                Button {
                    files.session?.isVisible = true
                } label: {
                    Label("Revenir au navigateur de fichiers", systemImage: "folder")
                }
                .buttonStyle(.secondary)
            }
            if connection.proto == .telnet {
                // telnet n'est plus livré avec macOS : utile seulement pour « Ouvrir dans Terminal »
                // (l'onglet intégré de NetScope fait sa propre négociation Telnet).
                InstallToolPanel(tool: .telnet, note: "Seulement pour « Ouvrir dans Terminal »\u{00A0}: l’onglet de NetScope n’en a pas besoin. Sans telnet, Terminal utilise nc.")
            }
            if connection.proto == .serie, !model.serialPorts.contains(connection.host) {
                SpeedBanner(text: "\(connection.host) n’est pas branché. Ports série présents : "
                            + (model.serialPorts.isEmpty ? "aucun." : model.serialPorts.joined(separator: ", ")),
                            tone: .neutral, systemImage: "cable.connector")
            }
        }
    }

    private func launchSubtitle(_ connection: RemoteConnection, plan: Result<RemoteLaunchPlan, Error>) -> String {
        // Note 57 : VNC s'ouvre dans NetScope (Partage d'écran reste au menu du bouton).
        if connection.proto == .vnc, (try? plan.get()) != nil { return "« Connecter » ouvre la session VNC intégrée" }
        switch plan {
        case .success(let plan):
            if RemoteSessionStore.opensInTab(connection.proto) {
                return connection.proto == .vnc ? "« Connecter » ouvre un onglet VNC dans NetScope"
                    : "« Connecter » ouvre un onglet de terminal dans NetScope"
            }
            return "« Connecter » ouvre \(plan.appName)"
        case .failure: return "Connexion à corriger avant de l’ouvrir"
        }
    }

    /// « dans un onglet de NetScope », « dans Windows App »… (bulles d'aide).
    static func destination(_ proto: RemoteProtocol) -> String {
        RemoteSessionStore.opensInTab(proto) ? "dans un onglet de NetScope" : "dans \(proto.externalApp)"
    }

    /// Bloc sombre façon terminal : la commande, le fichier .rdp ou l'URL.
    private func terminalPreview(_ connection: RemoteConnection, plan: Result<RemoteLaunchPlan, Error>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch plan {
            case .success(.terminal(let command)):
                // Note 57 : session dans un onglet de NetScope ; la commande reste celle de « Ouvrir dans Terminal ».
                (Text("NetScope › ").foregroundColor(Color(hex: 0x4ADE80)) + Text(integratedCommand(connection, fallback: command)))
                Text(integratedHint(connection)).foregroundStyle(Theme.consoleMuted)
            case .success(.rdpFile(let contents, let fileName)):
                Text(fileName).foregroundColor(Color(hex: 0x4ADE80))
                ForEach(rdpPreviewLines(contents), id: \.self) { line in
                    Text(line).foregroundStyle(Theme.consoleMuted)
                }
            case .success(.url) where connection.proto == .vnc:
                // Note 57 : client RFB intégré (VNCSessionView).
                Text("NetScope › ").foregroundColor(Color(hex: 0x4ADE80)) + Text(verbatim: "vnc://\(connection.host):\(connection.port)")
                Text("Session VNC intégrée\u{00A0}: mot de passe VNC ou compte macOS, au Trousseau\u{00A0}; ZRLE, Hextile, CopyRect.")
                    .foregroundStyle(Theme.consoleMuted)
                Text("Affichage\u{00A0}: \(connection.display.mode == .fullScreen ? "plein écran" : "dans NetScope") · "
                     + (connection.display.vncScale == .actual ? "100\u{00A0}%" : "ajusté à la fenêtre"))
                    .foregroundStyle(Theme.consoleMuted)
            case .success(.url(let url)):
                Text("open ").foregroundColor(Color(hex: 0x4ADE80)) + Text(url.absoluteString)
                Text("Partage d’écran demande le mot de passe du compte distant.").foregroundStyle(Theme.consoleMuted)
                Text("Affichage\u{00A0}: \(connection.display.summary(for: .vnc).lowercased())"
                     + (connection.display.mode == .fullScreen ? " (après l’identification, avec l’autorisation Accessibilité)" : ""))
                    .foregroundStyle(Theme.consoleMuted)
            case .success(.fileBrowser(let address)):
                Text("NetScope › ").foregroundColor(Color(hex: 0x4ADE80)) + Text(address)
                Text("Navigateur de fichiers intégré\u{00A0}: Ce Mac ↔ serveur, glisser-déposer, file des transferts avec reprise.")
                    .foregroundStyle(Theme.consoleMuted)
                Text("Mode\u{00A0}: \(connection.fileTransferModeLabel.lowercased())"
                     + (connection.transfer.remoteDirectory.isEmpty ? "" : " · dossier \(connection.transfer.remoteDirectory)"))
                    .foregroundStyle(Theme.consoleMuted)
            case .failure(let error):
                Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    .foregroundColor(Color(hex: 0xFCA5A5))
            }
        }
        .font(Theme.mono(12.5))
        .foregroundStyle(Theme.consoleText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
    }

    /// Lignes du .rdp montrées dans l'aperçu : adresse, utilisateur et affichage.
    private func rdpPreviewLines(_ contents: String) -> [String] {
        let keys = ["full address", "username", "screen mode id", "desktopwidth", "desktopheight", "use multimon"]
        return contents.components(separatedBy: "\r\n").filter { line in keys.contains { line.hasPrefix($0 + ":") } }
    }

    /// Ce que l'onglet intégré lance (jamais de secret).
    private func integratedCommand(_ connection: RemoteConnection, fallback: String) -> String {
        switch connection.proto {
        case .ssh: return SSHTerminalCommand.displayCommand(user: connection.username, host: connection.host, port: connection.port)
        case .telnet: return "telnet \(connection.host) \(connection.port)"
        case .serie: return "console \(connection.host) · \(TerminalSerialMemory.settings(for: connection).summary)"
        default: return fallback
        }
    }

    private func integratedHint(_ connection: RemoteConnection) -> String {
        switch connection.proto {
        case .ssh: return "Onglet xterm-256color\u{00A0}: clés et known_hosts de ~/.ssh, mot de passe du Trousseau. Terminal\u{00A0}: menu de « Connecter »."
        case .telnet: return "Onglet intégré avec négociation Telnet (écho, taille, type de terminal)\u{00A0}; non chiffré."
        case .serie: return "Console intégrée\u{00A0}: le port s’ouvre par « Connecter » et se referme avec l’onglet\u{00A0}; débit, bits, parité, arrêt et flux réglables."
        default: return ""
        }
    }

    /// Sessions ouvertes (accueil) : un clic revient à l'onglet.
    private var openSessionsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Sessions ouvertes")
            ForEach(sessions.tabs) { tab in
                Button {
                    sessions.select(tab.id)
                    model.selectedID = tab.connection.id
                } label: {
                    HStack(spacing: 8) {
                        RemoteProtoIcon(proto: tab.connection.proto, size: 22)
                        Text(tab.session?.tabLabel ?? tab.connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(tab.session?.addressLabel ?? tab.connection.address).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let session = tab.session { RemoteSessionStateChip(session: session) }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// État d'une session (pastille de l'accueil).
struct RemoteSessionStateChip: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        switch session.phase {
        case .connected: Chip(text: session.kind == .serial ? "Port ouvert" : "Connectée", tone: .success)
        case .connecting: Chip(text: "Connexion…", tone: .accent)
        case .idle: Chip(text: "Port fermé", tone: .neutral)
        case .ended: Chip(text: "Déconnectée", tone: .neutral)
        }
    }
}

// MARK: - Formulaire

/// Formulaire « Nouvelle connexion » / « Modifier la connexion ».
struct RemoteForm: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        if let binding = Binding($model.draft) {
            content(binding)
        }
    }

    private func content(_ draft: Binding<RemoteDraft>) -> some View {
        let proto = draft.wrappedValue.proto
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.wrappedValue.editingID == nil ? "Nouvelle connexion" : "Modifier la connexion").font(Theme.panelTitle)
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Protocole")
                    HStack(spacing: 2) {
                        ForEach(RemoteProtocol.allCases) { option in
                            let on = proto == option
                            Button {
                                draft.wrappedValue.switchProtocol(to: option)
                                draft.wrappedValue.port = String(draft.wrappedValue.defaultPort)
                                if option == .serie, !draft.wrappedValue.host.hasPrefix("/dev/") {
                                    draft.wrappedValue.host = model.serialPorts.first ?? ""
                                } else if option != .serie, draft.wrappedValue.host.hasPrefix("/dev/") {
                                    draft.wrappedValue.host = ""
                                }
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(on ? Theme.accentStrong : Theme.neutralText)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Theme.panel : .clear))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(on ? Theme.accent : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.neutralSoft))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Nom")
                    RemoteInput(placeholder: "SW-CORE-01", text: draft.name, mono: false)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel(proto == .serie ? "Port série" : "Hôte ou adresse IP")
                        if proto == .serie {
                            serialPicker(draft)
                        } else {
                            RemoteInput(placeholder: "10.182.122.2", text: draft.host)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel(proto == .serie ? "Débit" : "Port")
                        if proto == .serie {
                            Picker("", selection: draft.port) {
                                ForEach(RemoteValidator.baudRates, id: \.self) { Text("\($0) bauds").tag(String($0)) }
                            }
                            .labelsHidden()
                            .frame(height: 32)
                        } else {
                            RemoteInput(placeholder: String(draft.wrappedValue.defaultPort), text: draft.port)
                        }
                    }
                    .frame(width: 120)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Utilisateur")
                        RemoteInput(placeholder: proto == .rdp ? "CORP\\utilisateur" : "netadmin", text: draft.username, mono: false)
                            .disabled(proto == .serie)
                            .opacity(proto == .serie ? 0.5 : 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Dossier")
                        HStack(spacing: 4) {
                            RemoteInput(placeholder: "Siège › Réseau", text: draft.folder, mono: false)
                            Menu {
                                ForEach(model.folders, id: \.self) { folder in
                                    Button(folder) { draft.wrappedValue.folder = folder }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 26, height: 32)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Description")
                    RemoteInput(placeholder: "Modèle, système, emplacement…", text: draft.note, mono: false)
                }
                if proto == .rdp || proto == .vnc {
                    RemoteDisplayForm(draft: draft)
                }
                Toggle("Favori", isOn: draft.isFavorite).toggleStyle(.checkbox).font(Theme.small)
                if proto == .telnet {
                    SpeedBanner(text: "Telnet n’est pas chiffré. Utilisez SSH si l’appareil le permet.")
                }
                // Note 57 : mot de passe SSH ou Telnet au Trousseau (facultatif).
                if proto == .ssh || proto == .telnet {
                    TerminalPasswordField(draft: draft)
                }
                if proto.isFileTransfer {
                    FileTransferFormSection(draft: draft)
                }
                if let error = model.draftError {
                    SpeedBanner(text: error, tone: .critical, systemImage: "xmark.octagon")
                }
                HStack(spacing: 8) {
                    Button("Enregistrer et connecter") {
                        if let saved = model.commitDraft() { model.connect(saved) }
                    }
                    .buttonStyle(.primary)
                    Button("Enregistrer seulement") { model.commitDraft() }
                        .buttonStyle(.secondary)
                    Button("Annuler") { model.cancelDraft() }
                        .buttonStyle(.ghost)
                }
                .fixedSize()
                helpBox.padding(.top, 4)
            }
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    /// Rappel du comportement de chaque protocole, sous le formulaire.
    private var helpBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Ce que fait « Connecter »")
            helpLine("SSH", "Onglet de terminal de NetScope (ssh de macOS\u{00A0}: clés et known_hosts de ~/.ssh, mot de passe du Trousseau)\u{00A0}; Terminal par le menu de « Connecter ».")
            helpLine("Telnet", "Onglet de terminal de NetScope, négociation Telnet intégrée (aucun client à installer)\u{00A0}; non chiffré.")
            helpLine("RDP", "Windows App, en fenêtre ou en plein écran (fichier .rdp)\u{00A0}; RDP est trop vaste pour être réécrit sans bibliothèque externe, il reste donc dans Windows App.")
            helpLine("VNC", "Session intégrée à NetScope (mot de passe VNC ou compte macOS)\u{00A0}; Partage d’écran au menu du bouton.")
            helpLine("FTP", "Navigateur de fichiers de NetScope (Ce Mac ↔ serveur)\u{00A0}; non chiffré, à réserver au réseau local.")
            helpLine("FTPS", "Même navigateur, chiffré par TLS (explicite sur 21, implicite sur 990).")
            helpLine("SFTP", "Même navigateur, par SSH (/usr/bin/sftp)\u{00A0}; clés et known_hosts de ~/.ssh.")
            helpLine("Série", "Console intégrée (/dev/cu.*)\u{00A0}: débit, bits, parité, arrêt, contrôle de flux, Break\u{00A0}; Cisco et Fortinet en 9600 8N1.")
            Text("Hôte : lettres, chiffres, point, tiret et deux-points seulement.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
    }

    private func helpLine(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(width: 48, alignment: .leading)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func serialPicker(_ draft: Binding<RemoteDraft>) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: draft.host) {
                if model.serialPorts.isEmpty { Text("Aucun port série détecté").tag("") }
                if !draft.wrappedValue.host.isEmpty, !model.serialPorts.contains(draft.wrappedValue.host) {
                    Text(draft.wrappedValue.host).tag(draft.wrappedValue.host)
                }
                ForEach(model.serialPorts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .font(Theme.mono(12))
            Button {
                model.refreshSerialPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.ghost)
            .help("Relire les ports /dev/cu.*")
        }
        .frame(height: 32)
    }
}

/// Champ de saisie du formulaire (32 pt, bordure grise).
struct RemoteInput: View {
    let placeholder: String
    @Binding var text: String
    var mono = true

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(13) : Theme.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}
