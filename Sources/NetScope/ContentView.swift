import NetScopeCore
import SwiftUI

/// Fenêtre principale, à la manière d'une app macOS : barre latérale translucide du système,
/// barre d'outils unifiée (titre de l'écran, actions de l'écran, recherche globale) et contenu de
/// l'écran courant. Les couleurs suivent le mode clair ou sombre de macOS.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: Theme.sidebarWidth, max: 300)
        } detail: {
            // Petite fenêtre : un écran plus grand que la place disponible défile au lieu d'être coupé.
            MinimumSizeScroller {
                screenView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.appBackground)
            .id(state.screen)
                .navigationTitle(state.screen.pageTitle)
                .searchable(text: $state.searchText, placement: .toolbar,
                            prompt: Text("Rechercher IP, MAC, nom…"))
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        // Pastille Analyse dès le lancement (alertes « à traiter » enregistrées), sans attendre
        // l'ouverture d'un écran branché sur l'inventaire.
        .onAppear { InvModel.shared.updateBadge(state) }
    }

    @ViewBuilder private var screenView: some View {
        switch state.screen {
        case .scanner: ScannerScreen()
        case .carte: TopologieScreen()
        case .inventaire: InventaireScreen()
        case .appareil: DeviceScreen()
        case .ping: PingScreen()
        case .switchs: SwitchScreen()
        case .wifi: WifiScreen()
        case .outils: ToolboxScreen()
        case .surveillance: SurveillanceScreen()
        case .analyse: AnalyseScreen()
        case .rapports: RapportScreen()
        case .acces: RemoteScreen()
        case .speedtest: SpeedtestScreen()
        case .reglages: ReglagesScreen()
        }
    }
}

/// Champ de recherche d’un panneau (loupe à gauche, fond système).
struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer la recherche")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Actions de la barre d'outils

extension View {
    /// Place des boutons dans la barre d'outils unifiée de la fenêtre (ex. « Lancer le scan »,
    /// « Exporter »). Quand la fenêtre est étroite, macOS range les boutons qui ne tiennent pas
    /// dans le menu de débordement de la barre (»).
    func screenToolbar<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                actions()
                    .labelStyle(.titleAndIcon)
                    .modifier(SnapshotActiveState())
            }
        }
    }
}

/// Pour les captures (--snapshot), qui dessinent une fenêtre d'une app en arrière-plan : les
/// contrôles de la barre d'outils prennent l'aspect d'une fenêtre active au lieu d'être grisés.
struct SnapshotActiveState: ViewModifier {
    @MainActor static var forceActive = false

    func body(content: Content) -> some View {
        if SnapshotActiveState.forceActive {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
    }
}
