import AppKit
import NetScopeCore
import SwiftUI

// MARK: - Tableau des connexions (tableau standard « acces.connexions », note 8)
//
// La colonne « Connexions » reste une liste groupée (croquis Remote.dc.html) ; elle partage le tri
// de ce tableau (menu « Trier ») et ouvre le tableau complet dans une feuille (bouton « Tableau ») :
// tri par en-tête, colonnes réglables et masquables, état retenu.

extension RemoteConnection {
    /// Sécurité du transport, telle qu'elle est annoncée dans la liste et le tableau.
    var remoteSecurityLabel: String {
        switch proto {
        case .telnet: return "Non sécurisé"
        case .ssh: return "Chiffré (SSH)"
        case .rdp: return "Chiffré (TLS)"
        case .vnc: return "Selon le serveur"
        case .serie: return "Liaison locale"
        }
    }

    /// Affichage (RDP, VNC) : « Plein écran », « Fenêtre · 1440 × 900 » ; vide ailleurs.
    var remoteResolutionLabel: String {
        switch proto {
        case .rdp:
            if display.mode == .fullScreen { return display.allMonitors ? "Plein écran · tous les écrans" : "Plein écran" }
            if let size = display.resolvedWindowSize {
                return "Fenêtre · " + RemoteDisplaySettings.sizeLabel(size.width, size.height)
            }
            return "Fenêtre · ajustée"
        case .vnc:
            return display.mode.label + " · " + display.vncScale.label
        case .ssh, .telnet, .serie:
            return ""
        }
    }

    var remoteSortProto: String { proto.label }
    var remoteSortLastConnected: Date { lastConnected ?? .distantPast }
}

/// Colonnes, tri et modèle du tableau des connexions.
enum RemoteConnectionColumns {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "protocole", title: "Protocole"),
        StandardColumn(id: "hote", title: "Hôte"),
        StandardColumn(id: "port", title: "Port"),
        StandardColumn(id: "securite", title: "Sécurité"),
        StandardColumn(id: "derniere", title: "Dernière connexion"),
        StandardColumn(id: "utilisateur", title: "Utilisateur", isDefaultVisible: false),
        StandardColumn(id: "groupe", title: "Groupe", isDefaultVisible: false),
        StandardColumn(id: "notes", title: "Notes", isDefaultVisible: false),
        StandardColumn(id: "resolution", title: "Affichage (RDP, VNC)", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RemoteConnection>] = [
        "nom": KeyPathComparator(\RemoteConnection.name),
        "protocole": KeyPathComparator(\RemoteConnection.remoteSortProto),
        "hote": KeyPathComparator(\RemoteConnection.host),
        "port": KeyPathComparator(\RemoteConnection.port),
        "securite": KeyPathComparator(\RemoteConnection.remoteSecurityLabel),
        "derniere": KeyPathComparator(\RemoteConnection.remoteSortLastConnected),
        "utilisateur": KeyPathComparator(\RemoteConnection.username),
        "groupe": KeyPathComparator(\RemoteConnection.folderLabel),
        "notes": KeyPathComparator(\RemoteConnection.note),
        "resolution": KeyPathComparator(\RemoteConnection.remoteResolutionLabel),
    ]

    /// Tris proposés par le menu « Trier » de la liste (dans cet ordre).
    static let listSorts = ["nom", "protocole", "hote", "port", "securite", "derniere"]

    @MainActor
    static func makeModel() -> StandardTableModel<RemoteConnection> {
        StandardTableModel(id: "acces.connexions", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }
}

/// Menu « Trier » de la liste latérale : même tri que l'en-tête du tableau.
struct RemoteSortMenu: View {
    @ObservedObject var table: StandardTableModel<RemoteConnection>

    var body: some View {
        let current = table.currentSort
        Menu {
            Section("Trier chaque groupe par") {
                ForEach(RemoteConnectionColumns.listSorts, id: \.self) { id in
                    let title = RemoteConnectionColumns.columns.first { $0.id == id }?.title ?? id
                    Toggle(title, isOn: Binding(get: { current?.column == id }, set: { _ in
                        table.setSort(id, ascending: current?.ascending ?? true)
                    }))
                }
            }
            Section {
                Toggle("Croissant", isOn: Binding(get: { current?.ascending ?? true }, set: { _ in
                    table.setSort(current?.column ?? "nom", ascending: true)
                }))
                Toggle("Décroissant", isOn: Binding(get: { !(current?.ascending ?? true) }, set: { _ in
                    table.setSort(current?.column ?? "nom", ascending: false)
                }))
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Trier les connexions (même tri que le tableau)")
    }
}

/// Feuille « Tableau des connexions » : toutes les connexions dans le tableau standard.
struct RemoteConnectionTableSheet: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject var table: StandardTableModel<RemoteConnection>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connexions").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    Text("\(model.connections.count) enregistrées · \(model.reachableCount) joignables")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 12)
                SearchField(text: $model.searchText, placeholder: "Nom, IP, protocole…")
                    .frame(width: 240)
                StandardColumnsMenu(model: table)
            }
            .padding(14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            RemoteConnectionTable(model: model, table: table)

            HStack(spacing: 8) {
                Text("Double-clic pour se connecter")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let connection = model.selected { model.connect(connection) }
                } label: {
                    Label("Connecter", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .disabled(model.selected == nil)
            }
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(minWidth: 980, idealWidth: 1040, minHeight: 460, idealHeight: 560)
        .background(Theme.panel)
    }
}

/// Tableau standard des connexions (filtré par la recherche de la liste).
struct RemoteConnectionTable: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject var table: StandardTableModel<RemoteConnection>

    private var selection: Binding<UUID?> {
        Binding(get: { model.draft == nil ? model.selectedID : nil }, set: { id in
            guard let id else { return }
            model.selectedID = id
            model.cancelDraft()
        })
    }

    var body: some View {
        let rows = model.connections.filter { $0.matches(model.searchText) }.sorted(using: table.sortOrder)
        Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("NOM", sortUsing: table.sort("nom")) { connection in
                    HStack(spacing: 8) {
                        RemoteReachDot(state: model.state(of: connection.id))
                            .help(model.state(of: connection.id).label)
                        Text(connection.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if connection.isFavorite {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xD97706))
                                .help("Favori")
                        }
                    }
                    .frame(height: 26)
                }
                .width(min: 130, ideal: 190)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("PROTOCOLE", sortUsing: table.sort("protocole")) { connection in
                    RemoteProtoBadge(proto: connection.proto)
                }
                .width(min: 70, ideal: 90)
                .customizationID("protocole")

                TableColumn("HÔTE", sortUsing: table.sort("hote")) { connection in
                    RemoteCellText(connection.host, mono: true)
                        .help(connection.address)
                }
                .width(min: 100, ideal: 170)
                .customizationID("hote")

                TableColumn("PORT", sortUsing: table.sort("port")) { connection in
                    RemoteCellText(connection.proto == .serie ? "\(connection.port) bauds" : "\(connection.port)", mono: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 80)
                .customizationID("port")

                TableColumn("SÉCURITÉ", sortUsing: table.sort("securite")) { connection in
                    if connection.proto.isInsecure {
                        Text("NON SÉCURISÉ").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.warning)
                            .fixedSize()
                            .help("Le mot de passe circule en clair sur le réseau")
                    } else {
                        RemoteCellText(connection.remoteSecurityLabel, secondary: true)
                    }
                }
                .width(min: 90, ideal: 120)
                .customizationID("securite")

                TableColumn("DERNIÈRE CONNEXION", sortUsing: table.sort("derniere")) { connection in
                    RemoteCellText(RemoteFormat.relative(connection.lastConnected), secondary: true,
                                   dimmed: connection.lastConnected == nil)
                }
                .width(min: 100, ideal: 165)
                .customizationID("derniere")
            }

            Group {
                TableColumn("UTILISATEUR", sortUsing: table.sort("utilisateur")) { connection in
                    RemoteCellText(connection.username.isEmpty ? "—" : connection.username, mono: true,
                                   dimmed: connection.username.isEmpty)
                }
                .width(min: 70, ideal: 110)
                .customizationID("utilisateur")
                .defaultVisibility(.hidden)

                TableColumn("GROUPE", sortUsing: table.sort("groupe")) { connection in
                    RemoteCellText(connection.folderLabel, secondary: true)
                }
                .width(min: 70, ideal: 130)
                .customizationID("groupe")
                .defaultVisibility(.hidden)

                TableColumn("NOTES", sortUsing: table.sort("notes")) { connection in
                    RemoteCellText(connection.note.isEmpty ? "—" : connection.note, secondary: true,
                                   dimmed: connection.note.isEmpty)
                        .help(connection.note)
                }
                .width(min: 80, ideal: 180)
                .customizationID("notes")
                .defaultVisibility(.hidden)

                TableColumn("AFFICHAGE (RDP, VNC)", sortUsing: table.sort("resolution")) { connection in
                    let label = connection.remoteResolutionLabel
                    RemoteCellText(label.isEmpty ? "—" : label, secondary: true, dimmed: label.isEmpty)
                }
                .width(min: 90, ideal: 160)
                .customizationID("resolution")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let connection = model.connections.first(where: { $0.id == id }) {
                Button("Connecter") { model.connect(connection) }
                Button(connection.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") {
                    model.toggleFavorite(connection.id)
                }
                Divider()
                Button("Copier l’adresse") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.host, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let connection = model.connections.first(where: { $0.id == id }) {
                model.connect(connection)
            }
        }
    }
}

/// Texte d'une cellule du tableau des connexions.
private struct RemoteCellText: View {
    let text: String
    var mono = false
    var secondary = false
    var dimmed = false

    init(_ text: String, mono: Bool = false, secondary: Bool = false, dimmed: Bool = false) {
        self.text = text
        self.mono = mono
        self.secondary = secondary
        self.dimmed = dimmed
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(12) : Theme.small)
            .foregroundStyle(dimmed ? Theme.textTertiary : (secondary ? Theme.textSecondary : Theme.text))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
