import NetScopeCore
import SwiftUI

/// Fenêtre principale, à la manière d'une app macOS : barre latérale translucide du système,
/// barre d'outils unifiée (titre de l'écran, actions de l'écran, recherche globale) et contenu de
/// l'écran courant. Les couleurs suivent le mode clair ou sombre de macOS.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    /// Note 49 : le site actif est rappelé dans le titre de la fenêtre.
    @ObservedObject private var sites = SiteModel.shared
    @State private var columns = NavigationSplitViewVisibility.all
    /// ⌘⇧S avec la barre latérale masquée : elle est remise pour montrer le sélecteur de site.
    @ObservedObject private var sitePicker = SitePickerPresenter.shared
    /// Nombre de résultats de la recherche, annoncé par l'écran courant.
    @State private var searchResults: [String] = []

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: Theme.sidebarWidth, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Note 35 : plantage précédent, bannière discrète au lancement.
                CrashBanner()
                // Note 26 : étiquettes des critères de la recherche, sous la barre d'outils.
                // Notes 31 et 33 : un filtre transmis (groupe de la Carte, port) s'affiche aussi ici.
                if let schema = state.screen.searchSchema,
                   !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty || state.navFilters[state.screen] != nil {
                    SearchTokensBar(schema: schema, results: searchResults)
                }
                // Petite fenêtre : un écran plus grand que la place disponible défile au lieu d'être coupé.
                MinimumSizeScroller {
                    screenView
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .onPreferenceChange(SearchResultsKey.self) { searchResults = $0 }
            }
            .background(Theme.appBackground)
            // Note 52 : feuille « Se connecter en SSH » des boutons SSH de tous les écrans.
            .quickLoginPrompt()
            .id(state.screen)
                .navigationTitle(state.screen.pageTitle)
                .navigationSubtitle(SitePicker.windowSubtitle(activeName: sites.activeSite?.displayName))
                .searchable(text: $state.searchText, placement: .toolbar,
                            prompt: Text("Rechercher"))
                .searchSuggestions {
                    if let schema = state.screen.searchSchema {
                        SearchPrefixSuggestions(text: state.searchText, schema: schema)
                    }
                }
                // Note 32 : ↩︎ résultat suivant, ⇧↩︎ précédent (Carte du réseau).
                .onSubmit(of: .search) { state.submitSearch(backwards: NSEvent.modifierFlags.contains(.shift)) }
                // Note 34 : Retour / Avancer (⌘[ et ⌘]), boutons natifs ‹ › comme le Finder.
                .toolbar {
                    ToolbarItem(placement: .navigation) { NavHistoryButtons() }
                }
        }
        .navigationPrompts()
        .onChange(of: columns) { _, value in sitePicker.sidebarVisible = value != .detailOnly }
        .onChange(of: sitePicker.sidebarRequest) { _, _ in columns = .all }
        // Captures (NETSCOPE_SITE_CHOIX) : le sélecteur de site ouvert sous son bouton.
        .overlay(alignment: .topLeading) { SitePickerSnapshotOverlay() }
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
        case .outils, .speedtest: ToolboxScreen()
        case .surveillance: SurveillanceScreen()
        case .trafic: TraficScreen()
        case .journaux: JournauxScreen()
        case .analyse: AnalyseScreen()
        case .rapports: RapportScreen()
        case .acces: RemoteScreen()
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
