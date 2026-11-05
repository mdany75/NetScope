import NetScopeCore
import SwiftUI

/// Écran `Screen.acces` (croquis docs/croquis/Remote.dc.html) : connexions enregistrées,
/// ouverture dans l'app externe (Terminal, Windows App, Partage d'écran), import depuis le scan.
struct RemoteScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = RemoteModel.shared
    @ObservedObject private var files = FileTransferStore.shared
    @ObservedObject private var ftpServer = FTPTemporaryServerModel.shared
    @ObservedObject private var sessions = RemoteSessionStore.shared
    @ObservedObject private var server = RustDeskServerModel.shared
    /// Correctif 0.27.3 : onglet « Assistance RustDesk » (mêmes règles que le tableau de bord).
    @ObservedObject private var rustdesk = RustDeskModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // Note 26 : la recherche de la barre d'outils filtre aussi les connexions.
            Color.clear.frame(height: 0)
                .onAppear { model.toolbarSearch = state.searchText }
                .onChange(of: state.searchText) { _, text in model.toolbarSearch = text }
            if let toast = model.toast {
                HStack(spacing: 10) {
                    Image(systemName: model.toastIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(toast).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button {
                        model.toast = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Fermer le message")
                }
                // Erreur : ton d'avertissement, jamais la coche verte de réussite.
                .foregroundStyle(model.toastIsError ? Theme.warning : Theme.success)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(model.toastIsError ? Theme.warningSoft : Theme.successSoft))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 12) {
                // Note 50 : navigateur de fichiers ouvert ; en petite fenêtre, il prend toute la largeur.
                let browsing = files.session.flatMap { files.isShowing(model.selectedID) ? $0 : nil }
                // Note 57 : petite fenêtre et onglet de session affiché (terminal ou VNC) : la session
                // prend toute la largeur (l'onglet « Sessions » ramène la liste des connexions).
                // Note 6 (0.26.2) : le tableau de bord du serveur RustDesk se comporte comme un onglet de session.
                let sessionShown = (sessions.activeTab != nil || server.isShown || rustdesk.isAssistanceShown) && model.draft == nil && model.tunnelDraft == nil
                if !model.compactLayout || (browsing == nil && !sessionShown) {
                    RemoteConnectionList(model: model)
                        .frame(width: 272)
                }
                if let session = browsing {
                    // Petite fenêtre : « Connexions » masque le navigateur (la session continue).
                    FileTransferBrowser(session: session, model: model, compact: model.compactLayout) {
                        session.isVisible = false
                    }
                    .frame(minWidth: 300)
                } else if model.compactLayout, model.detailsVisible, let connection = model.selected {
                    // Petite fenêtre : trois colonnes ne tiennent pas. Le détail, ouvert à la demande
                    // (bouton de la barre d'outils), prend la place des sessions au lieu de les recouvrir.
                    RemoteDetailPanel(model: model, connection: connection)
                        .frame(maxWidth: .infinity, alignment: .top)
                } else {
                    RemoteSessionArea(model: model)
                        .frame(minWidth: 300)
                    detailColumn
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateLayout(width: geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in updateLayout(width: width) }
                }
            }
        }
        // Note 6 (0.26.2) : le tableau de bord du serveur ne lit que pendant que l'écran est affiché.
        .onAppear { server.screenVisible = true }
        .onDisappear { server.screenVisible = false }
        .overlay {
            if model.showImport { RemoteImportOverlay(model: model) }
            if ftpServer.isPresented { FTPServerOverlay() }
        }
        .screenToolbar {
            Button {
                model.checkReachability()
            } label: {
                Label("Vérifier la joignabilité", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.secondary)
            .help("Tente une connexion TCP vers chaque hôte (aucune authentification)")
            Button {
                model.detailsVisible.toggle()
            } label: {
                Label(model.detailsVisible ? "Masquer les détails" : "Afficher les détails", systemImage: "sidebar.right")
            }
            .buttonStyle(.secondary)
        }
        .confirmationDialog("Supprimer la connexion « \(model.pendingDeletion?.name ?? "") » ?",
                            isPresented: Binding(get: { model.pendingDeletion != nil },
                                                 set: { if !$0 { model.pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let connection = model.pendingDeletion { model.delete(connection) }
            }
            Button("Annuler", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("La connexion enregistrée est retirée de NetScope. L’appareil n’est pas touché.")
        }
    }

    /// Largeur des trois colonnes côte à côte : marges (32), liste (272), sessions (au moins 360)
    /// et détails (300), plus les espacements.
    private static let threeColumnWidth: CGFloat = 32 + 272 + 12 + 360 + 12 + detailWidth

    /// Largeur fixe de la colonne des détails.
    static let detailWidth: CGFloat = 300

    /// Longueur du texte vertical de la languette repliée (« DÉTAILS · … »). Elle ne dépend pas de
    /// `detailWidth` : c'est la hauteur réservée au libellé tourné, pas une largeur de colonne.
    private static let collapsedLabelLength: CGFloat = 300

    private func updateLayout(width: CGFloat) {
        let compact = width < Self.threeColumnWidth
        if model.compactLayout != compact { model.compactLayout = compact }
    }

    /// Tableau de bord du serveur RustDesk ou page d'assistance RustDesk affichés : ils prennent la
    /// place de la colonne des détails (ni l'un ni l'autre ne porte sur la connexion choisie).
    private var dashboardShown: Bool {
        (server.isShown || rustdesk.isAssistanceShown) && sessions.activeTab == nil && model.draft == nil && model.tunnelDraft == nil
    }

    @ViewBuilder private var detailColumn: some View {
        if dashboardShown {
            EmptyView()
        } else if model.detailsVisible, let connection = model.selected {
            // Correctif 0.27.2 : colonne fixe à droite. Chaque ligne du panneau tient dans sa
            // largeur (passage à la ligne ou troncature) ; le `.clipped()` n'est qu'un filet de
            // sécurité : si une ligne réclamait encore plus de 300 points, le panneau ne déborderait
            // pas sur la session, et le bouton de repli, servi en premier, resterait visible.
            RemoteDetailPanel(model: model, connection: connection)
                .frame(width: Self.detailWidth, alignment: .topLeading)
                .clipped()
        } else if let connection = model.selected {
            Button {
                model.detailsVisible = true
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("DÉTAILS · \(connection.name.uppercased())")
                        .font(Theme.captionSemibold)
                        .kerning(0.5)
                        // Longueur bornée avant la rotation : un nom long est abrégé au lieu de
                        // déborder sur le chevron.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: Self.collapsedLabelLength, alignment: .leading)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: Self.collapsedLabelLength)
                    Spacer()
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 10)
                .frame(width: 40)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Afficher les détails de la connexion")
        }
    }
}
