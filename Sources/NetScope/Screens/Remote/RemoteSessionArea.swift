import NetScopeCore
import SwiftUI

/// Zone centrale : formulaire de connexion, ou aperçu de ce que « Connecter » va ouvrir.
/// Le terminal intégré n'existe pas encore : les sessions s'ouvrent dans l'app externe.
struct RemoteSessionArea: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(model.draft == nil ? "Sessions" : (model.draft?.editingID == nil ? "Nouvelle connexion" : "Modifier la connexion"))
                    .font(.system(size: 12, weight: .semibold))
                Text("SSH · Telnet · Console série · RDP · VNC").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Chip(text: "Terminal intégré : bientôt", tone: .neutral, systemImage: "clock")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.neutralSoft)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
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
            soonBox

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
                    .help("Ouvrir \(connection.name) dans \(connection.proto.externalApp)")
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
            if connection.proto.isInsecure {
                SpeedBanner(text: "Telnet n’est pas chiffré : le mot de passe circule en clair. Utilisez SSH si l’appareil le permet.")
            }
            if connection.proto == .telnet, RemoteLauncher.findTelnet() == nil {
                SpeedBanner(text: "telnet n’est plus livré avec macOS : NetScope utilisera nc. Pour le vrai client : brew install telnet.",
                            tone: .neutral, systemImage: "info.circle")
            }
            if connection.proto == .serie, !model.serialPorts.contains(connection.host) {
                SpeedBanner(text: "\(connection.host) n’est pas branché. Ports série présents : "
                            + (model.serialPorts.isEmpty ? "aucun." : model.serialPorts.joined(separator: ", ")),
                            tone: .neutral, systemImage: "cable.connector")
            }
        }
    }

    private func launchSubtitle(_ connection: RemoteConnection, plan: Result<RemoteLaunchPlan, Error>) -> String {
        switch plan {
        case .success(let plan): return "« Connecter » ouvre \(plan.appName)"
        case .failure: return "Connexion à corriger avant de l’ouvrir"
        }
    }

    /// Bloc sombre façon terminal : la commande, le fichier .rdp ou l'URL.
    private func terminalPreview(_ connection: RemoteConnection, plan: Result<RemoteLaunchPlan, Error>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch plan {
            case .success(.terminal(let command)):
                (Text("\(speedLocalHostName) ~ % ").foregroundColor(Color(hex: 0x4ADE80)) + Text(command))
                Text(connection.proto == .serie ? "Quitter screen : Ctrl-A puis K" : "La session s’ouvre dans une nouvelle fenêtre de Terminal.")
                    .foregroundStyle(Theme.sidebarHeading)
            case .success(.rdpFile(let contents, let fileName)):
                Text(fileName).foregroundColor(Color(hex: 0x4ADE80))
                ForEach(rdpPreviewLines(contents), id: \.self) { line in
                    Text(line).foregroundStyle(Theme.sidebarHeading)
                }
            case .success(.url(let url)):
                Text("open ").foregroundColor(Color(hex: 0x4ADE80)) + Text(url.absoluteString)
                Text("Partage d’écran demande le mot de passe du compte distant.").foregroundStyle(Theme.sidebarHeading)
                Text("Affichage\u{00A0}: \(connection.display.summary(for: .vnc).lowercased())"
                     + (connection.display.mode == .fullScreen ? " (après l’identification, avec l’autorisation Accessibilité)" : ""))
                    .foregroundStyle(Theme.sidebarHeading)
            case .failure(let error):
                Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    .foregroundColor(Color(hex: 0xFCA5A5))
            }
        }
        .font(Theme.mono(12.5))
        .foregroundStyle(Theme.sidebarText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Color(hex: 0x0B1220)))
    }

    /// Lignes du .rdp montrées dans l'aperçu : adresse, utilisateur et affichage.
    private func rdpPreviewLines(_ contents: String) -> [String] {
        let keys = ["full address", "username", "screen mode id", "desktopwidth", "desktopheight", "use multimon"]
        return contents.components(separatedBy: "\r\n").filter { line in keys.contains { line.hasPrefix($0 + ":") } }
    }

    private var soonBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal intégré : bientôt").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.neutralText)
                Text("Les onglets de session (SSH, Telnet, console série, RDP et VNC dans NetScope) arriveront dans une prochaine version. Pour l’instant, « Connecter » ouvre l’application externe.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
                                draft.wrappedValue.port = String(option.defaultPort)
                                if option == .serie, !draft.wrappedValue.host.hasPrefix("/dev/") {
                                    draft.wrappedValue.host = model.serialPorts.first ?? ""
                                } else if option != .serie, draft.wrappedValue.host.hasPrefix("/dev/") {
                                    draft.wrappedValue.host = ""
                                }
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(on ? Theme.accentStrong : Theme.neutralText)
                                    .padding(.horizontal, 12)
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
                            RemoteInput(placeholder: String(proto.defaultPort), text: draft.port)
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
                if proto.isInsecure {
                    SpeedBanner(text: "Telnet n’est pas chiffré. Utilisez SSH si l’appareil le permet.")
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
            helpLine("SSH", "Terminal ; clés et empreintes de ~/.ssh, vérifiées par ssh.")
            helpLine("Telnet", "Terminal ; client Homebrew (brew install telnet), sinon nc.")
            helpLine("RDP", "Windows App, en fenêtre ou en plein écran (fichier .rdp) ; identifiants demandés à l’ouverture.")
            helpLine("VNC", "Partage d’écran de macOS (vnc://)\u{00A0}; plein écran par l’accessibilité.")
            helpLine("Série", "screen dans Terminal ; quitter avec Ctrl-A puis K.")
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
