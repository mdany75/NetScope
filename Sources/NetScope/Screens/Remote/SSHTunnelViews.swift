import AppKit
import NetScopeCore
import SwiftUI

// Note 66 : vues des tunnels SSH — onglet de session (état, ouverture à travers le tunnel,
// journal de ssh), section « Rebond et tunnels » du panneau de détails (croquis Remote.dc.html :
// « Hôte de rebond (jump host) » et « Tunnels / redirections ») et formulaire d'un tunnel.

// MARK: - Onglet de session

struct SSHTunnelSessionView: View {
    @ObservedObject var session: SSHTunnelSession
    @ObservedObject var model: RemoteModel

    var body: some View {
        VStack(spacing: 0) {
            header
            banners
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    openCard
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            routeCard
                            consoleCard
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            routeCard
                            consoleCard
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Barre de l'onglet

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: SSHTunnelStyle.symbol(session.tunnel.kind)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RemoteProtocol.ssh.tint)
            Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            Text(session.routeLabel).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            Chip(text: session.phaseLabel.text, tone: session.phaseLabel.tone)
            Button(session.isActive ? "Arrêter" : "Démarrer") {
                if session.isActive {
                    session.stop()
                } else {
                    session.start(reserved: SSHTunnelStore.shared.reservedPorts(except: session.id))
                }
            }
            .buttonStyle(RemoteSmallButtonStyle(primary: true, tint: session.isActive ? Theme.critical : Theme.accent))
            .help(session.isActive ? "Ferme le tunnel (ssh s’arrête)" : "Rouvre le tunnel avec un port local libre")
            Menu {
                Button("Copier l’adresse locale") { session.copyLocalAddress() }
                    .disabled(session.localPort == nil)
                Button("Copier la commande") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.commandLine, forType: .string)
                }
                .disabled(session.commandLine.isEmpty)
                Divider()
                Button("Modifier le tunnel…") { model.editTunnel(session.tunnel, of: session.connection) }
                Button("Ouvrir \(session.connection.name) en SSH") { model.connect(session.connection) }
                Divider()
                Button("Fermer l’onglet") {
                    if let tab = RemoteSessionStore.shared.tunnelTab(session.id) { RemoteSessionStore.shared.requestClose(tab) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Autres actions du tunnel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Bandeaux

    @ViewBuilder private var banners: some View {
        VStack(spacing: 6) {
            if let key = session.hostKey {
                HStack(spacing: 10) {
                    Image(systemName: "key.viewfinder").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Serveur inconnu\u{00A0}: vérifiez son empreinte avant d’accepter").font(.system(size: 12, weight: .semibold))
                        Text("\(key.keyType ?? "Clé") \(key.fingerprint) · ajoutée à ~/.ssh/known_hosts si vous acceptez")
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
            }
            if let prompt = session.passwordPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                    Text(prompt).font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                    SecureField("Mot de passe", text: $session.passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140, maxWidth: 220)
                        .onSubmit { session.sendPassword() }
                    Button("Envoyer") { session.sendPassword() }
                        .buttonStyle(RemoteSmallButtonStyle(primary: true))
                        .disabled(session.passwordInput.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                .help("Le mot de passe va à ssh seulement (jamais au disque ni au journal)")
            }
            if case .failed(let message) = session.phase {
                SpeedBanner(text: message, tone: .critical, systemImage: "xmark.octagon")
            } else if let warning = session.warning {
                SpeedBanner(text: warning.message, tone: .warning)
            }
            if session.portChanged, let port = session.localPort {
                SpeedBanner(text: "Le port \(session.tunnel.localPort) était pris sur ce Mac\u{00A0}: le tunnel écoute sur \(port).",
                            tone: .neutral, systemImage: "info.circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, session.hostKey != nil || session.passwordPrompt != nil || hasBanner ? 8 : 0)
    }

    private var hasBanner: Bool {
        if case .failed = session.phase { return true }
        return session.warning != nil || session.portChanged
    }

    // MARK: Ouvrir à travers le tunnel

    private var openCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: session.tunnel.kind == .dynamic ? "Proxy SOCKS5" : "Ouvrir à travers le tunnel") {
                    if let port = session.localPort {
                        Text(SSHTunnelCommand.localAddress(port: port)).font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(session.phase == .open ? Theme.text : Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                if session.tunnel.kind == .dynamic {
                    Text("Réglez l’application sur le proxy SOCKS5 127.0.0.1:\(session.localPort.map(String.init) ?? "1080") (DNS par le proxy)\u{00A0}: tout le réseau vu depuis \(session.connection.name) devient joignable.")
                        .font(Theme.small).foregroundStyle(Theme.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button {
                            session.copyLocalAddress()
                            model.toast = "Adresse du proxy copiée\u{00A0}: \(session.localPort.map { SSHTunnelCommand.localAddress(port: $0) } ?? "")."
                        } label: {
                            Label("Copier l’adresse du proxy", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
                        }
                        .buttonStyle(RemoteSmallButtonStyle(primary: true))
                        .disabled(session.phase != .open)
                        Spacer(minLength: 0)
                    }
                    // Exemple neutre ; l'adresse du croquis seulement en démonstration.
                    Text(verbatim: "curl --socks5-hostname 127.0.0.1:\(session.localPort ?? 1080) " + (session.demo ? "http://10.182.122.111/" : "http://<adresse-interne>/"))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { openButtons }
                        VStack(alignment: .leading, spacing: 6) { openButtons }
                    }
                    Text(openHint).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var openButtons: some View {
        let suggested = session.tunnel.use
        let others: [SSHTunnelUse] = [.rdp, .vnc, .https, .http].filter { $0 != suggested }
        if suggested != .none {
            Button {
                model.openThroughTunnel(session, use: suggested)
            } label: {
                Label(SSHTunnelStyle.buttonTitle(suggested), systemImage: SSHTunnelStyle.symbol(suggested)).labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle(primary: true))
            .disabled(session.phase != .open)
            .help(SSHTunnelStyle.help(suggested, port: session.localPort))
        }
        Menu {
            ForEach(others) { use in
                Button(SSHTunnelStyle.buttonTitle(use)) { model.openThroughTunnel(session, use: use) }
                    .help(SSHTunnelStyle.help(use, port: session.localPort))
            }
        } label: {
            HStack(spacing: 4) {
                Text(suggested == .none ? "Ouvrir avec" : "Ouvrir avec…")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
        .disabled(session.phase != .open)
        .help("Ouvrir 127.0.0.1 avec une autre application")
        Button {
            session.copyLocalAddress()
            model.toast = "Adresse copiée\u{00A0}: \(session.localPort.map { SSHTunnelCommand.localAddress(port: $0) } ?? "")."
        } label: {
            Label("Copier l’adresse", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
        }
        .buttonStyle(RemoteSmallButtonStyle())
        .disabled(session.localPort == nil)
        .help("Copier l’adresse locale du tunnel")
    }

    private var openHint: String {
        switch session.tunnel.use {
        case .rdp: return "Windows App s’ouvre sur 127.0.0.1:\(session.localPort.map(String.init) ?? "…") avec l’utilisateur de la connexion RDP du carnet (même destination), s’il y en a une."
        case .vnc: return "La session VNC intégrée se connecte à 127.0.0.1\u{00A0}: l’image passe chiffrée par le tunnel jusqu’au serveur SSH."
        case .http, .https: return "Le navigateur par défaut ouvre 127.0.0.1\u{00A0}: un certificat émis pour l’adresse d’origine sera signalé comme ne correspondant pas."
        case .none: return "Toute application peut se connecter à l’adresse locale tant que le tunnel est ouvert."
        }
    }

    // MARK: Itinéraire

    private var routeCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Itinéraire")
                VStack(spacing: 0) {
                    KeyValueRow(key: "Type", value: session.tunnel.kind.label, keyWidth: 104)
                    KeyValueRow(key: "Ce Mac", value: session.localPort.map { SSHTunnelCommand.localAddress(port: $0) } ?? "127.0.0.1 (port à choisir)",
                                mono: true, keyWidth: 104)
                    KeyValueRow(key: "Rebond", value: session.connection.proxyJump.isEmpty ? "Aucun (accès direct)" : session.connection.proxyJump,
                                mono: !session.connection.proxyJump.isEmpty, keyWidth: 104)
                    KeyValueRow(key: "Serveur SSH", value: session.serverLabel, mono: true, keyWidth: 104)
                    if session.tunnel.kind == .local {
                        KeyValueRow(key: "Destination", value: "\(session.tunnel.remoteHost):\(session.tunnel.remotePort)", mono: true, keyWidth: 104)
                    } else {
                        KeyValueRow(key: "Destination", value: "Toute adresse vue du serveur SSH", keyWidth: 104)
                    }
                    KeyValueRow(key: "Port local", value: session.tunnel.localPort > 0 ? "\(session.tunnel.localPort) (imposé)" : "Choisi libre automatiquement",
                                keyWidth: 104)
                    KeyValueRow(key: "Ouvert depuis", value: session.phase == .open ? SSHTunnelStyle.since(session.openedAt) : "—", keyWidth: 104)
                    KeyValueRow(key: "Identification", value: identification, keyWidth: 104)
                }
            }
        }
        .frame(minWidth: 280)
    }

    private var identification: String {
        let key = session.connection.identityFile.isEmpty ? "Clés de ~/.ssh et agent" : "Clé \(session.connection.identityFile)"
        return RemoteSessionStore.shared.hasPassword(session.connection.id) ? key + ", puis mot de passe du Trousseau" : key
    }

    // MARK: Journal

    private var consoleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Journal de ssh")
            VStack(alignment: .leading, spacing: 3) {
                if session.log.isEmpty {
                    Text("Le tunnel n’a pas encore été ouvert.").foregroundStyle(Theme.consoleMuted)
                }
                ForEach(session.log.suffix(60)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(SSHTunnelStyle.clock(line.date)).foregroundStyle(Theme.consoleMuted)
                        Text(line.text).foregroundColor(SSHTunnelStyle.consoleColor(line.tone))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.consoleText)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
        }
        .frame(minWidth: 280)
    }
}

/// Étiquette d'un onglet de tunnel.
struct SSHTunnelTabLabel: View {
    @ObservedObject var session: SSHTunnelSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        RemoteTabContent(label: session.title, proto: .ssh, dot: session.dot, state: session.phaseLabel.text,
                         selected: selected, select: select, close: close,
                         symbol: SSHTunnelStyle.symbol(session.tunnel.kind), badge: "TUNNEL")
    }
}

/// Puce d'état d'un tunnel (accueil « Sessions »).
struct SSHTunnelStateChip: View {
    @ObservedObject var session: SSHTunnelSession

    var body: some View {
        Chip(text: session.phaseLabel.text, tone: session.phaseLabel.tone)
    }
}

// MARK: - Panneau de détails

/// Croquis : « Hôte de rebond (jump host) » et « Tunnels / redirections » d'une connexion SSH.
struct SSHTunnelDetailSection: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject private var store = SSHTunnelStore.shared
    let connection: RemoteConnection

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                jumpPicker
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Tunnels / redirections") {
                        Button {
                            model.startTunnel(for: connection)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.ghost)
                        .help("Ajouter une redirection de port (-L) ou un proxy SOCKS (-D)")
                    }
                    ForEach(connection.tunnels) { tunnel in
                        SSHTunnelRow(model: model, connection: connection, tunnel: tunnel, session: store.session(for: tunnel.id))
                    }
                    if connection.tunnels.isEmpty {
                        Text("Aucune redirection.").font(Theme.small).foregroundStyle(Theme.neutralText)
                    }
                }
            }
        }
    }

    private var jumpPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HÔTE DE REBOND (JUMP HOST)").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
            Picker("", selection: Binding(get: { connection.proxyJump }, set: { model.setProxyJump($0, for: connection.id) })) {
                Text("Aucun (accès direct)").tag("")
                ForEach(model.jumpCandidates(excluding: connection.id), id: \.spec) { candidate in
                    Text(candidate.label).tag(candidate.spec)
                }
                if !connection.proxyJump.isEmpty, !model.jumpCandidates(excluding: connection.id).contains(where: { $0.spec == connection.proxyJump }) {
                    Text(connection.proxyJump).tag(connection.proxyJump)
                }
            }
            .labelsHidden()
            .help("ssh passe d’abord par cet hôte (-J, ProxyJump)\u{00A0}: terminal, tunnels et «\u{00A0}Ouvrir dans Terminal\u{00A0}»")
        }
    }
}

/// Une redirection : genre, spécification, état, démarrer ou arrêter, retirer.
struct SSHTunnelRow: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection
    let tunnel: SSHTunnelSpec
    let session: SSHTunnelSession?

    var body: some View {
        if let session {
            SSHTunnelLiveRow(model: model, connection: connection, tunnel: tunnel, session: session)
        } else {
            SSHTunnelRowContent(model: model, connection: connection, tunnel: tunnel, dot: Theme.neutralDot, state: "Arrêté",
                                activePort: nil, active: false)
        }
    }
}

private struct SSHTunnelLiveRow: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection
    let tunnel: SSHTunnelSpec
    @ObservedObject var session: SSHTunnelSession

    var body: some View {
        SSHTunnelRowContent(model: model, connection: connection, tunnel: tunnel, dot: session.dot, state: session.phaseLabel.text,
                            activePort: session.isActive ? session.localPort : nil, active: session.isActive)
    }
}

private struct SSHTunnelRowContent: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection
    let tunnel: SSHTunnelSpec
    let dot: Color
    let state: String
    let activePort: Int?
    let active: Bool
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7).accessibilityLabel(state).help(state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(tunnel.kind.badge)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(RemoteProtocol.ssh.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(RemoteProtocol.ssh.soft))
                        .fixedSize()
                    if !tunnel.label.isEmpty {
                        Text(tunnel.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }
                }
                Text(tunnel.spec(activePort: activePort)).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(tunnel.label.isEmpty ? Theme.text : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openTunnel(tunnel, of: connection) }
            Button {
                if active { model.stopTunnel(tunnel.id) } else { model.openTunnel(tunnel, of: connection) }
            } label: {
                Image(systemName: active ? "stop.fill" : "play.fill").font(.system(size: 10))
            }
            .buttonStyle(.ghost)
            .help(active ? "Arrêter le tunnel" : "Ouvrir le tunnel (onglet de session)")
            Menu {
                Button("Ouvrir l’onglet du tunnel") { model.openTunnel(tunnel, of: connection) }
                Button("Modifier…") { model.editTunnel(tunnel, of: connection) }
                Divider()
                Button("Supprimer la redirection", role: .destructive) {
                    // Tunnel ouvert : confirmation, comme la fermeture de son onglet.
                    if SSHTunnelStore.shared.isActive(tunnel.id) {
                        confirmDelete = true
                    } else {
                        model.deleteTunnel(tunnel.id, from: connection.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Modifier ou supprimer la redirection \(tunnel.spec())")
        }
        .confirmationDialog("Supprimer la redirection «\u{00A0}\(tunnel.title)\u{00A0}»\u{00A0}?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { model.deleteTunnel(tunnel.id, from: connection.id) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le tunnel ouvert sera arrêté\u{00A0}: les applications qui passent par lui seront déconnectées.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Formulaire

/// Formulaire « Nouveau tunnel » / « Modifier le tunnel » (onglet « Sessions »).
struct SSHTunnelForm: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        // Jamais `Binding($model.tunnelDraft)` : même plantage que RemoteForm quand le brouillon
        // est remis à nil (enregistrement ou annulation) pendant qu'un interrupteur le relit.
        if let current = model.tunnelDraft {
            content(Binding(get: { model.tunnelDraft ?? current },
                            set: { if model.tunnelDraft != nil { model.tunnelDraft = $0 } }))
        }
    }

    private func content(_ draft: Binding<SSHTunnelDraft>) -> some View {
        let value = draft.wrappedValue
        let server = model.connections.first { $0.id == value.connectionID }
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.editingID == nil ? "Nouveau tunnel SSH" : "Modifier le tunnel").font(Theme.panelTitle)
                    if let server {
                        Text("Par \(server.name) · \(server.username.isEmpty ? "" : server.username + "@")\(server.host):\(server.port)"
                             + (server.proxyJump.isEmpty ? "" : " · rebond \(server.proxyJump)"))
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Type")
                    Picker("", selection: draft.kind) {
                        ForEach(SSHTunnelKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Nom")
                    RemoteInput(placeholder: value.kind == .dynamic ? "Proxy SOCKS du siège" : "SRV-LAVAL (RDP)", text: draft.label, mono: false)
                }
                if value.kind == .local {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            label("Destination (vue du serveur SSH)")
                            HStack(spacing: 4) {
                                RemoteInput(placeholder: "10.20.0.15", text: draft.remoteHost)
                                destinationMenu(draft)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            label("Port distant")
                            RemoteInput(placeholder: "3389", text: draft.remotePort)
                                .onChange(of: value.remotePort) { _, port in
                                    if !draft.wrappedValue.useEdited, let number = Int(port) {
                                        draft.wrappedValue.use = SSHTunnelUse.suggested(forRemotePort: number)
                                    }
                                }
                        }
                        .frame(width: 120)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Port local (127.0.0.1)")
                        RemoteInput(placeholder: "Automatique (\(value.suggestedLocalPort))", text: draft.localPort)
                    }
                    .frame(width: 200)
                    if value.kind == .local {
                        VStack(alignment: .leading, spacing: 4) {
                            label("Ouvrir avec")
                            Picker("", selection: Binding(get: { draft.wrappedValue.use },
                                                          set: { draft.wrappedValue.use = $0; draft.wrappedValue.useEdited = true })) {
                                ForEach(SSHTunnelUse.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(height: 32)
                        }
                    }
                }
                commandPreview(value, server: server)
                if let error = model.tunnelDraftError {
                    SpeedBanner(text: error, tone: .critical, systemImage: "xmark.octagon")
                }
                ActionRow {
                    Button("Enregistrer et ouvrir") { model.commitTunnelDraft(open: true) }
                        .buttonStyle(.primary)
                    Button("Enregistrer seulement") { model.commitTunnelDraft(open: false) }
                        .buttonStyle(.secondary)
                    Button("Annuler") { model.cancelDraft() }
                        .buttonStyle(.secondary)
                }
                helpBox.padding(.top, 4)
            }
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
    }

    /// Destinations proposées : appareils RDP, VNC et web du carnet.
    private func destinationMenu(_ draft: Binding<SSHTunnelDraft>) -> some View {
        Menu {
            let targets = model.connections.filter { [.rdp, .vnc, .ssh, .telnet].contains($0.proto) && $0.id != draft.wrappedValue.connectionID }
            ForEach(targets) { target in
                Button("\(target.name) · \(target.proto.label) \(target.host):\(target.port)") {
                    draft.wrappedValue.remoteHost = target.host
                    draft.wrappedValue.remotePort = String(target.port)
                    draft.wrappedValue.use = target.proto == .rdp ? .rdp : (target.proto == .vnc ? .vnc : .none)
                    draft.wrappedValue.useEdited = true
                    if draft.wrappedValue.label.isEmpty { draft.wrappedValue.label = "\(target.name) (\(target.proto.label))" }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 32)
        .help("Reprendre la destination d’une connexion du carnet")
    }

    private func commandPreview(_ value: SSHTunnelDraft, server: RemoteConnection?) -> some View {
        let preview: Result<String, Error> = Result {
            guard let server else { throw SSHTunnelError.notSSH }
            let spec = try value.tunnel()
            let port = spec.preferredLocalPort
            let home = RegEnvironment.isSandboxed ? "/Users/dany" : NSHomeDirectory()
            return SSHTunnelCommand.displayCommand(try SSHTunnelCommand.arguments(target: SSHTarget(connection: server), tunnel: spec,
                                                                                localPort: port, home: home))
        }
        return VStack(alignment: .leading, spacing: 3) {
            switch preview {
            case .success(let command):
                Text("NetScope › ").foregroundColor(Color(hex: 0x4ADE80)) + Text(command)
                Text("Écoute sur 127.0.0.1 seulement\u{00A0}; port pris\u{00A0}: un port libre est choisi. Aucune option ajoutée par les champs.")
                    .foregroundStyle(Theme.consoleMuted)
            case .failure(let error):
                Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    .foregroundColor(Color(hex: 0xFCA5A5))
            }
        }
        .font(Theme.mono(12))
        .foregroundStyle(Theme.consoleText)
        .lineLimit(6)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
    }

    private var helpBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Les tunnels SSH")
            helpLine("-L", "Un service distant (RDP, VNC, interface web) joint par 127.0.0.1\u{00A0}: ex. le FortiSwitch derrière la FortiGate, un serveur d’un autre site.")
            helpLine("-D", "Proxy SOCKS5\u{00A0}: le navigateur voit tout le réseau du serveur SSH.")
            helpLine("-J", "Saut par bastion\u{00A0}: «\u{00A0}Hôte de rebond\u{00A0}» de la connexion SSH (ProxyJump), dans le panneau de détails.")
            Text("ssh de macOS\u{00A0}: clés, agent et known_hosts de ~/.ssh\u{00A0}; mot de passe du Trousseau donné à la seule invite du serveur SSH.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func helpLine(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.mono(12, weight: .semibold)).frame(width: 28, alignment: .leading)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Style

enum SSHTunnelStyle {
    static func symbol(_ kind: SSHTunnelKind) -> String {
        kind == .dynamic ? "globe" : "arrow.left.arrow.right"
    }

    static func symbol(_ use: SSHTunnelUse) -> String {
        switch use {
        case .rdp: return "display"
        case .vnc: return "rectangle.on.rectangle"
        case .http, .https: return "safari"
        case .none: return "doc.on.doc"
        }
    }

    static func buttonTitle(_ use: SSHTunnelUse) -> String {
        switch use {
        case .rdp: return "Ouvrir RDP"
        case .vnc: return "Ouvrir VNC"
        case .http: return "Navigateur (http)"
        case .https: return "Navigateur (https)"
        case .none: return "Copier l’adresse"
        }
    }

    static func help(_ use: SSHTunnelUse, port: Int?) -> String {
        let address = port.map { SSHTunnelCommand.localAddress(port: $0) } ?? "127.0.0.1"
        switch use {
        case .rdp: return "Windows App vers \(address)"
        case .vnc: return "Session VNC intégrée vers \(address)"
        case .http: return "http://\(address)/ dans le navigateur par défaut"
        case .https: return "https://\(address)/ dans le navigateur par défaut"
        case .none: return address
        }
    }

    static func consoleColor(_ tone: Tone) -> Color {
        switch tone {
        case .success: return Color(hex: 0x4ADE80)
        case .warning: return Color(hex: 0xFCD34D)
        case .critical: return Color(hex: 0xFCA5A5)
        case .accent: return Color(hex: 0x8FBFFF)
        case .neutral: return Theme.consoleText
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// « 10:21 (il y a 17 min) ».
    static func since(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let elapsed = minutes < 1 ? "à l’instant" : (minutes < 60 ? "il y a \(minutes)\u{00A0}min" : "il y a \(minutes / 60)\u{00A0}h\u{00A0}\(String(format: "%02d", minutes % 60))")
        return "\(RemoteFormat.time(date)) (\(elapsed))"
    }
}
