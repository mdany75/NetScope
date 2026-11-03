import NetScopeCore
import SwiftUI

/// Écran `Screen.acces` (croquis docs/croquis/Remote.dc.html) : connexions enregistrées,
/// ouverture dans l'app externe (Terminal, Windows App, Partage d'écran), import depuis le scan.
struct RemoteScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = RemoteModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if let toast = model.toast {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .semibold))
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
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 12) {
                RemoteConnectionList(model: model)
                    .frame(width: 272)
                RemoteSessionArea(model: model)
                detailColumn
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay {
            if model.showImport { RemoteImportOverlay(model: model) }
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
                model.showDetails.toggle()
            } label: {
                Label(model.showDetails ? "Masquer les détails" : "Afficher les détails", systemImage: "sidebar.right")
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

    @ViewBuilder private var detailColumn: some View {
        if model.showDetails, let connection = model.selected {
            RemoteDetailPanel(model: model, connection: connection)
                .frame(width: 300)
        } else if let connection = model.selected {
            Button {
                model.showDetails = true
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("DÉTAILS · \(connection.name.uppercased())")
                        .font(Theme.captionSemibold)
                        .kerning(0.5)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: 200)
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
