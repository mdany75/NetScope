import NetScopeCore
import SwiftUI

/// Note 57 : barre d'onglets de la zone des sessions (croquis Remote.dc.html). Le premier onglet,
/// « Sessions », montre l'aperçu, le formulaire et les connexions récentes ; chaque session ouverte
/// a le sien (pastille d'état, icône, nom, protocole, fermeture).
struct RemoteSessionTabBar: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject var store = RemoteSessionStore.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            homeTab
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
        guard let draft = model.draft else { return "Sessions" }
        return draft.editingID == nil ? "Nouvelle connexion" : "Modifier la connexion"
    }

    private var homeTab: some View {
        let selected = store.activeID == nil
        return Button {
            store.select(nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 12))
                Text(homeTitle).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                if store.tabs.isEmpty, model.draft == nil {
                    Text("SSH · Telnet · Console série · RDP · VNC · FTP · SFTP").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTabShape(selected: selected))
        .help("Aperçu, connexions récentes et formulaire")
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
        }
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

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityLabel(state)
                    Image(systemName: proto.symbol).font(.system(size: 12))
                    Text(label).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    RemoteProtoBadge(proto: proto, text: proto == .serie ? "SÉRIE" : nil)
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
