import NetScopeCore
import SwiftUI

/// Colonne « Connexions » : recherche, ajout, import, groupes par dossier, favoris. Le tri des
/// groupes est celui du tableau standard « acces.connexions », ouvert par le bouton « Tableau ».
struct RemoteConnectionList: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var table = RemoteConnectionColumns.makeModel()
    @State private var showTable = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CONNEXIONS").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Text("\(model.connections.count) enregistrées · \(model.reachableCount) joignables")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    SearchField(text: $model.searchText, placeholder: "Nom, IP, protocole…")
                    RemoteSortMenu(table: table)
                    Button { showTable = true } label: { Image(systemName: "tablecells") }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .help("Ouvrir le tableau des connexions (tri, colonnes)")
                }
                // Côte à côte s'ils tiennent, sinon l'un sous l'autre (colonne étroite).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { newButton; importButton }
                    VStack(spacing: 6) { newButton; importButton }
                }
            }
            .padding(12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let groups = model.groups
                    ForEach(groups) { group in groupView(group) }
                    if groups.isEmpty {
                        Text(model.searchText.isEmpty
                             ? "Aucune connexion enregistrée. Créez-en une ou importez les appareils du scan."
                             : "Aucune connexion ne correspond à « \(model.searchText) ».")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) { RemoteReachDot(state: .reachable, size: 8); Text("Joignable") }
                HStack(spacing: 5) { RemoteReachDot(state: .unreachable, size: 8); Text("Non joignable") }
                Spacer()
                Label(model.lastCheck.map { RemoteFormat.time($0) } ?? "—", systemImage: "clock")
                    .labelStyle(RemoteCompactLabelStyle())
                    .help(model.lastCheck.map { "Joignabilité vérifiée à \(RemoteFormat.time($0))" } ?? "Joignabilité jamais vérifiée")
            }
            .lineLimit(1)
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .sheet(isPresented: $showTable) {
            RemoteConnectionTableSheet(model: model, table: table)
        }
    }

    private var newButton: some View {
        Button {
            model.startNew()
        } label: {
            Label("Nouvelle connexion", systemImage: "plus").frame(maxWidth: .infinity)
        }
        .buttonStyle(RemoteSmallButtonStyle(primary: true, fixed: false))
        .help("Créer une connexion SSH, Telnet, console série, RDP ou VNC")
    }

    private var importButton: some View {
        Button { model.showImport = true } label: {
            Text("Importer du scan").frame(maxWidth: .infinity)
        }
        .buttonStyle(RemoteSmallButtonStyle(fixed: false))
        .help("Ajouter les appareils du scan qui ont 22, 23, 3389 ou 5900 ouverts")
    }

    private func groupView(_ group: RemoteModel.RemoteGroup) -> some View {
        let open = !model.collapsedGroups.contains(group.id) || !model.searchText.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                model.toggleGroup(group.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: group.symbol).font(.system(size: 11))
                    Text(group.label.uppercased()).font(Theme.captionSemibold).kerning(0.4).lineLimit(1)
                    Spacer()
                    Text("\(group.items.count)").font(Theme.mono(11, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(group.items.sorted(using: table.sortOrder)) { connection in row(connection) }
            }
        }
    }

    private func addressLine(_ connection: RemoteConnection, compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Text(connection.address).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if connection.proto.isInsecure {
                Group {
                    if compact {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    } else {
                        Text("NON SÉCURISÉ").font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(Theme.warning)
                .fixedSize()
                .help("Non sécurisé\u{00A0}: \(connection.proto.label) circule en clair sur le réseau")
            }
        }
    }

    private func row(_ connection: RemoteConnection) -> some View {
        let selected = model.selectedID == connection.id && model.draft == nil
        let reach = model.state(of: connection.id)
        return HStack(spacing: 0) {
            Button {
                model.selectedID = connection.id
                model.cancelDraft()
            } label: {
                HStack(spacing: 8) {
                    RemoteProtoIcon(proto: connection.proto)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(connection.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            RemoteProtoBadge(proto: connection.proto)
                        }
                        // « NON SÉCURISÉ » en toutes lettres s'il tient, sinon un triangle : l'adresse reste entière.
                        ViewThatFits(in: .horizontal) {
                            addressLine(connection, compact: false)
                            addressLine(connection, compact: true)
                        }
                    }
                    Spacer(minLength: 4)
                    RemoteReachDot(state: reach).help(reach.label)
                }
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.connect(connection) })
            .help("Double-clic pour se connecter")

            Button {
                model.toggleFavorite(connection.id)
            } label: {
                Image(systemName: connection.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(connection.isFavorite ? Color(hex: 0xD97706) : Theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(connection.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        }
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(selected ? Theme.accentSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(selected ? Theme.accent.opacity(0.35) : Color.clear))
    }
}

/// Étiquette compacte (icône 11 pt, espacement serré) pour les boutons étroits.
struct RemoteCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

/// Bouton des colonnes étroites, natif de macOS (grande taille, hauteur des croquis) : bouton à
/// bordure, ou proéminent à la couleur `tint` avec `primary`.
struct RemoteSmallButtonStyle: PrimitiveButtonStyle {
    var primary = false
    var tint: Color = Theme.accent
    /// false : le bouton s'étire et le texte peut rétrécir un peu.
    var fixed = true

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .lineLimit(1)
                .minimumScaleFactor(fixed ? 1 : 0.8)
                .frame(maxWidth: fixed ? nil : .infinity)
        }
        .controlSize(.large)
        .fixedSize(horizontal: fixed, vertical: false)
        return Group {
            if primary {
                button.buttonStyle(.borderedProminent).tint(tint)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }
}
