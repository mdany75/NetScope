import AppKit
import NetScopeCore
import SwiftUI

/// Note 57 : contenu d'un onglet de terminal (croquis Remote.dc.html) : barre de l'onglet, réglages
/// de la console série, bandeaux (Telnet en clair, serveur inconnu), recherche, terminal, extraits
/// de commandes et barre d'état (sécurité, taille, journal).
struct TerminalSessionView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: RemoteModel
    @ObservedObject private var preferences = TerminalPreferences.shared
    @ObservedObject private var store = RemoteSessionStore.shared
    @ObservedObject private var snippetStore = TerminalSnippetStore.shared
    /// Note 67 : extrait en cours de création ou de modification.
    @State private var editingSnippet: TerminalSnippetDraft?
    /// Note 67 : envoi à plusieurs sessions demandé.
    @State private var broadcast: TerminalBroadcastRequest?
    /// Extrait personnalisé dont la suppression attend confirmation.
    @State private var deletingSnippet: TerminalSnippet?

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.kind == .serial { serialControls }
            // Note 78 : transfert XMODEM/YMODEM en cours ou terminé.
            if let transfer = session.transfer { SerialTransferBar(controller: transfer, session: session) }
            banners
            if session.searchVisible { searchBar }
            terminalBox
            snippetBar
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $session.transferSheetVisible) {
            SerialTransferSheet(session: session) { session.transferSheetVisible = false }
        }
        .sheet(item: $editingSnippet) { draft in
            TerminalSnippetEditor(draft: draft) { editingSnippet = nil }
        }
        .sheet(item: $broadcast) { request in
            TerminalBroadcastSheet(store: store, request: request) { broadcast = nil }
        }
        .confirmationDialog(deletingSnippet.map { "Supprimer l’extrait «\u{00A0}\($0.name)\u{00A0}»\u{00A0}?" } ?? "",
                            isPresented: Binding(get: { deletingSnippet != nil }, set: { if !$0 { deletingSnippet = nil } }),
                            presenting: deletingSnippet) { snippet in
            Button("Supprimer", role: .destructive) { snippetStore.delete(snippet.id) }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("La commande enregistrée sera perdue.")
        }
        .overlay {
            // Captures (NETSCOPE_REMOTE_VIEW=terminal-plusieurs) : la feuille d'envoi dessinée dans la page.
            if let request = TerminalDemo.broadcastRequest, store.activeID == session.id {
                ZStack {
                    Color.black.opacity(0.18)
                    TerminalBroadcastSheet(store: store, request: request, inline: true) {}
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.black.opacity(0.25), radius: 16, y: 6)
                }
            }
        }
        .overlay {
            // Captures (NETSCOPE_REMOTE_VIEW=terminal-serie-fichier) : la feuille dessinée dans la page.
            if session.kind == .serial, TerminalDemo.showsTransferSheet {
                ZStack {
                    Color.black.opacity(0.18)
                    SerialTransferSheet(session: session, inline: true, files: TerminalDemo.firmwareFiles) {}
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.black.opacity(0.25), radius: 16, y: 6)
                }
            }
        }
    }

    // MARK: Barre de l'onglet

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.connection.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            Text(session.addressLabel).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if !session.remoteTitle.isEmpty, session.remoteTitle != session.connection.name {
                Text("· \(session.remoteTitle)").font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                headerControls(compact: false)
                headerControls(compact: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func headerControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !compact {
                Picker("Encodage", selection: $session.encoding) {
                    ForEach(TerminalEncoding.allCases) { Text($0.label).tag($0) }
                }
                .font(Theme.small)
                .fixedSize()
                .help("Encodage des caractères reçus et envoyés")
                Toggle("Journaliser la session", isOn: $session.logEnabled)
                    .toggleStyle(.checkbox)
                    .font(Theme.small)
                    .fixedSize()
                    .help("Enregistre la sortie (texte brut) dans ~/Library/Logs/NetScope")
            }
            Button {
                session.copyOutput()
            } label: {
                Label("Copier la sortie", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .controlSize(.small)
            Button {
                session.searchVisible.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .help("Rechercher dans la sortie (⌘F)")
            Button("Effacer") { session.clear() }
                .buttonStyle(RemoteSmallButtonStyle())
                .help("Efface l’écran et l’historique (⌘K)")
            moreMenu(compact: compact)
        }
        .fixedSize()
    }

    private func moreMenu(compact: Bool) -> some View {
        Menu {
            if session.kind != .serial {
                if session.isActive {
                    Button("Déconnecter") { session.disconnect() }
                } else {
                    Button("Reconnecter") { session.reconnect() }
                }
            }
            if store.hasPassword(session.connection.id), session.kind != .ssh {
                Button("Taper le mot de passe du Trousseau") { session.typeSavedPassword() }
                    .disabled(session.phase != .connected)
            }
            Button("Ouvrir dans Terminal") { model.connect(session.connection, inTerminalApp: true) }
            Divider()
            Button("Enregistrer le journal…") { session.saveTranscript() }
            if compact {
                Toggle("Journaliser la session", isOn: $session.logEnabled)
                Picker("Encodage", selection: $session.encoding) {
                    ForEach(TerminalEncoding.allCases) { Text($0.label).tag($0) }
                }
            }
            if let url = session.logURL, !RegEnvironment.isSandboxed {
                Button("Afficher le journal dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Picker("Apparence", selection: $preferences.appearance) {
                ForEach(TerminalAppearance.allCases) { Text($0.label).tag($0) }
            }
            Picker("Taille du texte", selection: $preferences.fontSize) {
                ForEach(TerminalPreferences.fontSizes, id: \.self) { Text("\(Int($0)) points").tag($0) }
            }
            Toggle("Option comme touche Méta", isOn: $preferences.optionAsMeta)
            Toggle("Journaliser les nouvelles sessions", isOn: $preferences.logSessions)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Autres actions et réglages du terminal")
    }

    // MARK: Console série

    private var ports: [SerialPortInfo] {
        let present = RegEnvironment.isSandboxed ? TerminalDemo.serialPorts : SerialPortInfo.list()
        if present.contains(where: { $0.path == session.serialPath }) { return present }
        return [SerialPortInfo(path: session.serialPath)] + present
    }

    private func serialBinding<T>(_ keyPath: WritableKeyPath<SerialSettings, T>) -> Binding<T> {
        Binding(get: { session.serialSettings[keyPath: keyPath] }, set: { value in
            var settings = session.serialSettings
            settings[keyPath: keyPath] = value
            session.applySerial(path: session.serialPath, settings: settings)
            if (keyPath as AnyKeyPath) == \SerialSettings.baudRate, let baud = value as? Int {
                model.setSerialBaud(baud, for: session.connection.id)
            }
        })
    }

    private var serialControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Une rangée en grande fenêtre, deux en petite.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    portField
                    lineFields
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 10) {
                        portField
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        lineFields
                        Spacer(minLength: 0)
                    }
                }
            }
            // Une rangée si la place suffit ; sinon l'état, puis les boutons dessous (petite fenêtre).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    serialStatus(showAdapter: false)
                    Spacer(minLength: 8)
                    serialActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        serialStatus(showAdapter: true)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        serialActions
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func serialStatus(showAdapter: Bool) -> some View {
        Chip(text: session.isActive ? "Port ouvert" : "Port fermé", tone: session.isActive ? .success : .neutral)
            .help(SerialPortInfo(path: session.serialPath).adapter)
        Text("\(session.serialSettings.summary) · flux \(session.serialSettings.flowControl.shortLabel)")
            .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
        if showAdapter {
            Text(SerialPortInfo(path: session.serialPath).adapter).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder private var serialActions: some View {
        Toggle("Horodater", isOn: $session.timestamps)
            .toggleStyle(.checkbox)
            .font(Theme.small)
            .fixedSize()
            .help("Ajoute l’heure (à la milliseconde) devant chaque ligne reçue, aussi dans le journal")
        Button("9600 8N1") {
            session.applySerial(path: session.serialPath, settings: .ciscoConsole)
            model.setSerialBaud(9600, for: session.connection.id)
        }
        .buttonStyle(RemoteSmallButtonStyle())
        .help("Préréglage des consoles Cisco, Fortinet, Aruba et HPE\u{00A0}: 9600 bauds, 8 bits, sans parité, 1 bit d’arrêt, sans contrôle de flux")
        Button(session.isActive ? "Fermer le port" : "Ouvrir le port") { session.toggleSerialPort() }
            .buttonStyle(RemoteSmallButtonStyle(primary: true, tint: session.isActive ? Theme.critical : Theme.accent))
        // Note 78 : envoi et réception XMODEM/YMODEM.
        Button {
            session.transferSheetVisible = true
        } label: {
            Label("Fichier…", systemImage: "arrow.up.arrow.down.square")
        }
        .buttonStyle(RemoteSmallButtonStyle())
        .disabled(!session.isActive || session.transfer?.isActive == true)
        .help("Envoyer ou recevoir un fichier par XMODEM ou YMODEM (mise à jour de firmware par la console)")
        Button("Envoyer Break") { session.sendBreak() }
            .buttonStyle(RemoteSmallButtonStyle())
            .disabled(!session.isActive)
            .help("Signal « break »\u{00A0}: interrompt le démarrage (ROMMON, récupération du mot de passe)")
    }

    private var portField: some View {
        serialField("Port") {
            Picker("", selection: Binding(get: { session.serialPath },
                                          set: { session.applySerial(path: $0, settings: session.serialSettings) })) {
                ForEach(ports) { port in
                    Text(port.path).tag(port.path)
                }
            }
            .labelsHidden()
            .font(Theme.mono(12))
            .frame(width: 240)
        }
    }

    @ViewBuilder private var lineFields: some View {
        serialField("Débit (bauds)") {
            Picker("", selection: serialBinding(\.baudRate)) {
                ForEach(SerialSettings.baudRates, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        serialField("Bits") {
            Picker("", selection: serialBinding(\.dataBits)) {
                ForEach([8, 7, 6, 5], id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        serialField("Parité") {
            Picker("", selection: serialBinding(\.parity)) {
                ForEach(SerialSettings.Parity.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        serialField("Arrêt") {
            Picker("", selection: serialBinding(\.stopBits)) {
                ForEach([1, 2], id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        serialField("Contrôle de flux") {
            Picker("", selection: serialBinding(\.flowControl)) {
                ForEach(SerialSettings.FlowControl.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func serialField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    // MARK: Bandeaux

    @ViewBuilder private var banners: some View {
        VStack(spacing: 6) {
            if session.kind == .telnet {
                SpeedBanner(text: "Telnet transmet en clair — préférer SSH. Identifiants et configuration circulent sans chiffrement sur le réseau.")
            }
            switch session.finding {
            case .unknownHost(let fingerprint, let keyType):
                HStack(spacing: 10) {
                    Image(systemName: "key.viewfinder").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Serveur inconnu\u{00A0}: vérifiez son empreinte avant d’accepter").font(.system(size: 12, weight: .semibold))
                        Text("\(keyType ?? "Clé") \(fingerprint) · ajoutée à ~/.ssh/known_hosts si vous acceptez")
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Refuser") { session.answerHostKey(accept: false) }.buttonStyle(RemoteSmallButtonStyle())
                    Button("Accepter l’empreinte") { session.answerHostKey(accept: true) }
                        .buttonStyle(RemoteSmallButtonStyle(primary: true))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
            case .hostKeyChanged:
                SpeedBanner(text: "La clé de ce serveur a changé depuis la dernière connexion\u{00A0}: ssh refuse la session (interception possible). Si le changement est attendu (appareil remplacé), retirez l’ancienne clé avec « ssh-keygen -R \(session.connection.host) ».",
                            tone: .critical, systemImage: "exclamationmark.octagon")
            case .authenticationFailed where !session.isActive:
                SpeedBanner(text: "Identification refusée par le serveur. Vérifiez l’utilisateur (\(session.connection.username.isEmpty ? "celui du Mac" : session.connection.username)), la clé ou le mot de passe enregistré au Trousseau.",
                            tone: .critical, systemImage: "lock.slash")
            default:
                EmptyView()
            }
            if let notice = session.notice, session.noticeIsError {
                // Erreur : avertissement gardé jusqu'à sa fermeture.
                HStack(alignment: .top, spacing: 6) {
                    SpeedBanner(text: notice, tone: .warning, systemImage: "exclamationmark.triangle")
                    Button {
                        session.notice = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .help("Fermer le message")
                }
            } else if let notice = session.notice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .semibold))
                    Text(notice).font(Theme.small)
                    Spacer()
                    Button {
                        session.notice = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if session.notice == notice { session.notice = nil }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, hasBanner ? 10 : 0)
    }

    private var hasBanner: Bool {
        if session.kind == .telnet || session.notice != nil { return true }
        switch session.finding {
        case .unknownHost, .hostKeyChanged: return true
        case .authenticationFailed: return !session.isActive
        default: return false
        }
    }

    // MARK: Recherche

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            TextField("Rechercher dans la sortie", text: $session.searchText)
                .textFieldStyle(.roundedBorder)
                .font(Theme.small)
                .frame(maxWidth: 280)
                .onSubmit { session.nextMatch() }
                .onExitCommand { session.closeSearch() }
            Text(session.searchText.isEmpty ? "" : (session.matches.isEmpty ? "Aucun résultat" : "\(session.matchIndex + 1) sur \(session.matches.count)"))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            Button {
                session.nextMatch(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(session.matches.isEmpty)
            .help("Résultat précédent")
            Button {
                session.nextMatch()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(session.matches.isEmpty)
            .help("Résultat suivant (Entrée)")
            Spacer()
            Button("Terminé") { session.closeSearch() }.buttonStyle(.borderless).font(Theme.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Terminal

    private var terminalBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in preferences.appearance.palette(for: appearance).background })
    }

    private var terminalBox: some View {
        TerminalViewRepresentable(session: session)
            .background(terminalBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(light: 0xD1D5DB, dark: 0x1E293B)))
            .overlay(alignment: .bottom) { endedOverlay }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var endedOverlay: some View {
        switch session.phase {
        case .ended(let message):
            HStack(spacing: 10) {
                Image(systemName: message == nil ? "pause.circle" : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(message == nil ? Theme.textSecondary : Theme.warning)
                Text(message ?? (session.kind == .serial ? "Port fermé." : "Session terminée."))
                    .font(Theme.small).lineLimit(2)
                Spacer(minLength: 8)
                Button(session.kind == .serial ? "Rouvrir le port" : "Reconnecter") { session.reconnect() }
                    .buttonStyle(RemoteSmallButtonStyle(primary: true))
                Button("Fermer l’onglet") {
                    if let tab = store.tabs.first(where: { $0.id == session.id || $0.session === session }) { store.close(tab.id) }
                }
                .buttonStyle(RemoteSmallButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.25), radius: 8, y: 2)
            .padding(12)
        case .idle where session.kind == .serial:
            HStack(spacing: 10) {
                Image(systemName: "cable.connector").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text("Vérifiez le port et les réglages (consoles Cisco et Fortinet\u{00A0}: 9600 8N1, sans contrôle de flux), puis ouvrez le port.")
                    .font(Theme.small).lineLimit(2)
                Spacer(minLength: 8)
                Button("Ouvrir le port") { session.start() }.buttonStyle(RemoteSmallButtonStyle(primary: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .padding(12)
        default:
            EmptyView()
        }
    }

    // MARK: Extraits

    /// Note 67 : extraits de l'utilisateur (de la marque de la session ou pour toutes), puis
    /// commandes courantes de la marque (description et nom de la connexion).
    private var brand: TerminalSnippetBrand? {
        TerminalSnippetBrand.detect(description: session.connection.note + " " + session.connection.name, isSSH: session.kind == .ssh)
    }

    private var snippets: [TerminalSnippetItem] {
        TerminalSnippetLibrary.items(brand: brand, custom: snippetStore.snippets)
    }

    private var snippetBar: some View {
        HStack(spacing: 6) {
            Text("EXTRAITS").font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(snippets) { item in snippetButton(item) }
                    Button {
                        editingSnippet = TerminalSnippetDraft(snippet: TerminalSnippet(name: "", command: "", brand: brand), isNew: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(RemoteSmallButtonStyle())
                    .help("Nouvel extrait personnalisé")
                }
            }
            Button {
                broadcast = TerminalBroadcastRequest(command: "", sendsReturn: true, selected: [session.id])
            } label: {
                Label("Plusieurs sessions…", systemImage: "rectangle.stack").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .help("Envoyer une même commande à plusieurs sessions ouvertes")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func snippetButton(_ item: TerminalSnippetItem) -> some View {
        Button {
            session.sendText(TerminalBroadcast.payload(command: item.command, sendsReturn: item.sendsReturn))
        } label: {
            HStack(spacing: 4) {
                if item.isCustom { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.accentStrong) }
                Text(item.title)
            }
        }
        .buttonStyle(.plain)
        .font(item.isCustom ? Theme.small : Theme.mono(11.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(item.isCustom ? Theme.accentSoft : Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
        .help(snippetHelp(item))
        .disabled(session.phase != .connected)
        .contextMenu {
            Button("Envoyer à plusieurs sessions…") {
                broadcast = TerminalBroadcastRequest(command: item.command, sendsReturn: item.sendsReturn || !item.isCustom,
                                                     selected: [session.id])
            }
            if let id = item.customID, let snippet = snippetStore.snippet(id) {
                Divider()
                Button("Modifier…") { editingSnippet = TerminalSnippetDraft(snippet: snippet, isNew: false) }
                Button("Supprimer…", role: .destructive) { deletingSnippet = snippet }
            }
        }
    }

    /// Infobulle d'un extrait : sans Entrée finale, les lignes avant la dernière s'exécutent quand même.
    private func snippetHelp(_ item: TerminalSnippetItem) -> String {
        let lines = TerminalBroadcast.lineCount(item.command)
        if lines > 1 {
            return "Taper «\u{00A0}\(item.command)\u{00A0}» dans la session. "
                + TerminalBroadcast.executionNote(lineCount: lines, sendsReturn: item.sendsReturn)
        }
        return item.sendsReturn ? "Exécuter «\u{00A0}\(item.command)\u{00A0}» dans la session"
                                : "Taper «\u{00A0}\(item.command)\u{00A0}» dans la session (sans Entrée)"
    }

    // MARK: Barre d'état

    private var security: (text: String, tone: Tone) {
        switch session.kind {
        case .ssh:
            let auth = store.hasPassword(session.connection.id) ? "mot de passe du Trousseau" : "clés de ~/.ssh"
            return ("SSH · chiffré · \(auth)", .success)
        case .telnet: return ("Telnet · NON CHIFFRÉ", .warning)
        case .serial: return ("Console série · accès physique", .neutral)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(security.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(security.tone.foreground).lineLimit(1)
            Text(meta).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(logLabel).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .help(session.logURL?.path ?? "")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .padding(.top, 10)
    }

    private var meta: String {
        let size = "\(session.columns) col. × \(session.rows) lignes"
        if session.kind == .serial {
            return "Fin de ligne\u{00A0}: \(session.serialSettings.lineEnding.label) · \(size)"
        }
        return "\(session.encoding.label) · \(size) · xterm-256color"
    }

    private var logLabel: String {
        guard session.logEnabled, let url = session.logURL else { return "Journalisation désactivée" }
        return "Journal\u{00A0}: " + url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Note 57 : mot de passe SSH ou Telnet du formulaire, enregistré au Trousseau seulement.
struct TerminalPasswordField: View {
    @Binding var draft: RemoteDraft
    @ObservedObject private var store = RemoteSessionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mot de passe (facultatif)").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            RemoteSecureInput(placeholder: placeholder, text: Binding(get: { draft.password ?? "" }, set: { draft.password = $0 }))
            Text(draft.proto == .ssh
                 ? "Au Trousseau macOS seulement\u{00A0}; donné à ssh par SSH_ASKPASS si aucune clé de ~/.ssh n’est acceptée. Laissez vide pour utiliser vos clés."
                 : "Au Trousseau macOS seulement\u{00A0}; tapé dans la session sur demande (menu de l’onglet). Telnet l’envoie en clair.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placeholder: String {
        if let id = draft.editingID, store.hasPassword(id), draft.password == nil { return "Enregistré au Trousseau (inchangé)" }
        return "Aucun"
    }
}
