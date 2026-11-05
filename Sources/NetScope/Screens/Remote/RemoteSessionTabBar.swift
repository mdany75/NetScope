import NetScopeCore
import SwiftUI

/// Note 57 : barre d'onglets de la zone des sessions (croquis Remote.dc.html). Le premier onglet,
/// « Sessions », montre l'aperçu, le formulaire et les connexions récentes ; chaque session ouverte
/// a le sien (pastille d'état, icône, nom, protocole, fermeture).
struct RemoteSessionTabBar: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject var store = RemoteSessionStore.shared
    /// Note 6 (0.26.2) : onglet fixe « Serveur RustDesk » (tableau de bord du serveur).
    @ObservedObject private var server = RustDeskServerModel.shared
    /// Correctif 0.27.3 : onglet fixe « Assistance RustDesk » (ID de l'usager, sessions récentes).
    @ObservedObject private var rustdesk = RustDeskModel.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            homeTab
            assistanceTab
            if server.isAvailable { serverTab }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(store.tabs) { tab in
                            RemoteSessionTabButton(tab: tab, selected: store.activeID == tab.id, model: model, store: store)
                                .id(tab.id)
                        }
                    }
                }
                // Petite fenêtre : l'onglet actif reste entièrement visible, même au bout de la barre.
                .onAppear { reveal(store.activeID, proxy) }
                .onChange(of: store.activeID) { _, id in reveal(id, proxy) }
            }
            .fixedSize(horizontal: false, vertical: true)
            addMenu
                .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .frame(height: 38, alignment: .bottom)
        .background(Theme.neutralSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func reveal(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .trailing) }
    }

    private var homeTitle: String {
        if let tunnel = model.tunnelDraft { return tunnel.editingID == nil ? "Nouveau tunnel" : "Modifier le tunnel" }
        guard let draft = model.draft else { return "Sessions" }
        return draft.editingID == nil ? "Nouvelle connexion" : "Modifier la connexion"
    }

    private var homeTab: some View {
        let selected = store.activeID == nil && !dashboardShown && !assistanceShown
        return Button {
            store.select(nil)
            server.isShown = false
            rustdesk.isAssistanceShown = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 12))
                Text(homeTitle).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTabShape(selected: selected))
        .fixedSize()
        .help("Aperçu, connexions récentes et formulaire (SSH, Telnet, console série, RDP, VNC, FTP, SFTP, tunnels)")
    }

    /// Page d'assistance affichée (aucun onglet de session ni formulaire par-dessus).
    private var assistanceShown: Bool {
        store.activeID == nil && rustdesk.isAssistanceShown && model.draft == nil && model.tunnelDraft == nil
    }

    /// Correctif 0.27.3 : assistance RustDesk par l'ID de l'usager et historique des sessions.
    /// Toujours présent (comme l'était la section de la page « Sessions »), jamais fermé.
    private var assistanceTab: some View {
        let selected = assistanceShown
        return Button {
            model.draft = nil
            model.tunnelDraft = nil
            store.select(nil)
            rustdesk.isAssistanceShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: RemoteProtocol.rustdesk.symbol).font(.system(size: 12))
                Text("Assistance RustDesk").font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                // Recalculée chaque minute : la pastille se vide après minuit, app ouverte. Pastille
                // neutre, pour ne pas la confondre avec les sessions en cours du « Serveur RustDesk ».
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let today = RustDeskAssistance.todayCount(rustdesk.history, now: context.date)
                    if today > 0 {
                        Text("\(today)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.neutralText)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Theme.neutralSoft))
                            .overlay(Capsule().strokeBorder(Theme.border))
                            .fixedSize()
                            .help(today == 1 ? "1 session RustDesk lancée aujourd’hui" : "\(today) sessions RustDesk lancées aujourd’hui")
                    }
                }
            }
            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTabShape(selected: selected))
        .fixedSize()
        .help("Assistance RustDesk\u{00A0}: ID de l’usager, sessions récentes, reconnexion et ajout au carnet")
    }

    /// Tableau de bord affiché (aucun onglet de session ni formulaire par-dessus).
    private var dashboardShown: Bool {
        store.activeID == nil && server.isShown && model.draft == nil && model.tunnelDraft == nil
    }

    /// Note 6 (0.26.2) : tableau de bord du serveur RustDesk (lecture seule par SSH).
    private var serverTab: some View {
        let selected = dashboardShown
        return Button {
            model.draft = nil
            model.tunnelDraft = nil
            store.select(nil)
            server.isShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 12))
                Text("Serveur RustDesk").font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                if let status = server.status, status.relayConsole == .ok, !status.relaySessions.isEmpty {
                    CountBadge(count: status.relaySessions.count, color: RemoteProtocol.rustdesk.tint)
                        .help("Sessions relayées en cours")
                }
                if server.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
            }
            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTabShape(selected: selected))
        // Toujours lisible en entier : ce sont les onglets de session qui défilent.
        .fixedSize()
        .help("Tableau de bord du serveur RustDesk\u{00A0}: sessions relayées, demandes de connexion, état de hbbs et hbbr (lecture seule par SSH)")
    }

    private var addMenu: some View {
        Menu {
            let candidates = model.connections.filter { RemoteSessionStore.opensInTab($0.proto) }
                .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            Section("Ouvrir une session") {
                ForEach(candidates.prefix(12)) { connection in
                    Button("\(connection.name) · \(connection.proto.label)") {
                        model.selectedID = connection.id
                        model.connect(connection, newTab: true)
                    }
                }
            }
            Divider()
            Button("Nouvelle connexion…") {
                store.select(nil)
                model.startNew()
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Ouvrir un nouvel onglet de session")
    }
}

/// Fond d'un onglet : l'onglet choisi prend la couleur du panneau et se soude à la zone dessous.
struct RemoteTabShape: View {
    let selected: Bool

    var body: some View {
        if selected {
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(Theme.panel)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                        .strokeBorder(Theme.border)
                )
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.panel).frame(height: 2).padding(.horizontal, 1).offset(y: 1) }
        } else {
            Color.clear
        }
    }
}

/// Un onglet de session.
struct RemoteSessionTabButton: View {
    let tab: RemoteSessionStore.Tab
    let selected: Bool
    @ObservedObject var model: RemoteModel
    @ObservedObject var store: RemoteSessionStore

    var body: some View {
        if let session = tab.session {
            TerminalTabLabel(session: session, selected: selected, select: select, close: { store.requestClose(tab) })
                .contextMenu { terminalMenu(session) }
        } else if let vnc = tab.vncSession {
            VNCTabLabel(session: vnc, selected: selected, select: select, close: { store.requestClose(tab) })
                .contextMenu { vncMenu(vnc) }
        } else if let tunnel = tab.tunnelSession {
            SSHTunnelTabLabel(session: tunnel, selected: selected, select: select, close: { store.requestClose(tab) })
                .contextMenu { tunnelMenu(tunnel) }
        }
    }

    @ViewBuilder private func tunnelMenu(_ session: SSHTunnelSession) -> some View {
        if session.isActive {
            Button("Arrêter le tunnel") { session.stop() }
        } else {
            Button("Démarrer le tunnel") { session.start(reserved: SSHTunnelStore.shared.reservedPorts(except: session.id)) }
        }
        Button("Copier l’adresse locale") { session.copyLocalAddress() }
            .disabled(session.localPort == nil)
        Divider()
        Button("Fermer l’onglet") { store.requestClose(tab) }
    }

    private func select() {
        store.select(tab.id)
        model.selectedID = tab.connection.id
        model.draft = nil
    }

    @ViewBuilder private func vncMenu(_ session: VNCSession) -> some View {
        if session.isActive {
            Button("Déconnecter") { session.disconnect() }
        } else {
            Button("Reconnecter") { session.reconnect() }
        }
        Button("Ouvrir dans Partage d’écran") { model.connect(session.connection, external: true) }
        Divider()
        Button("Fermer l’onglet") { store.requestClose(tab) }
    }

    @ViewBuilder private func terminalMenu(_ session: TerminalSession) -> some View {
        if session.isActive {
            Button(session.kind == .serial ? "Fermer le port" : "Déconnecter") { session.disconnect() }
        } else {
            Button(session.kind == .serial ? "Ouvrir le port" : "Reconnecter") { session.reconnect() }
        }
        if session.kind != .serial {
            Button("Dupliquer l’onglet") { model.connect(session.connection, newTab: true) }
        }
        Button("Ouvrir dans Terminal") { model.connect(session.connection, inTerminalApp: true) }
        Divider()
        Button("Fermer l’onglet") { store.requestClose(tab) }
    }
}

/// Étiquette d'un onglet de terminal (suit l'état de la session).
struct TerminalTabLabel: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        RemoteTabContent(label: session.tabLabel, proto: session.connection.proto, dot: dot, state: state,
                         selected: selected, select: select, close: close)
    }

    private var dot: Color {
        switch session.phase {
        case .connected: return Theme.successDot
        case .connecting: return Theme.warningDot
        case .idle, .ended: return Theme.neutralDot
        }
    }

    private var state: String {
        switch session.phase {
        case .connected: return "Connectée"
        case .connecting: return "Connexion…"
        case .idle: return "Port fermé"
        case .ended: return "Déconnectée"
        }
    }
}

/// Étiquette d'un onglet VNC (suit l'état de la session : « Connecté », « Échec »…).
struct VNCTabLabel: View {
    @ObservedObject var session: VNCSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        RemoteTabContent(label: session.connection.name, proto: .vnc, dot: dot, state: session.phaseLabel.text,
                         selected: selected, select: select, close: close)
    }

    private var dot: Color {
        switch session.phase {
        case .connected: return Theme.successDot
        case .connecting, .authenticating, .needsCredentials: return Theme.warningDot
        case .failed: return Color(nsColor: .systemRed)
        case .closed: return Theme.neutralDot
        }
    }
}

struct RemoteTabContent: View {
    let label: String
    let proto: RemoteProtocol
    let dot: Color
    let state: String
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    /// Note 66 : icône et étiquette propres (onglet de tunnel).
    var symbol: String? = nil
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityLabel(state)
                    Image(systemName: symbol ?? proto.symbol).font(.system(size: 12))
                    Text(label).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    RemoteProtoBadge(proto: proto, text: badge ?? (proto == .serie ? "SÉRIE" : nil))
                }
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(label) · \(state)")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("Fermer l’onglet \(label)")
        }
        .background(RemoteTabShape(selected: selected))
        .fixedSize()
    }
}
