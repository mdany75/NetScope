import NetScopeCore
import SwiftUI

/// Fenêtre principale : barre latérale, puis barre d'outils (titre, recherche globale, actions
/// de l'écran) et contenu de l'écran courant.
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                Color.clear.frame(height: ContentToolbar.height)
                screenView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(state.screen)
            }
            .overlayPreferenceValue(ToolbarActionsKey.self, alignment: .top) { actions in
                ContentToolbar(title: state.screen.pageTitle, actions: actions?.view)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.appBackground)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.light)
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

/// Barre d'outils du contenu : titre de l'écran, recherche globale, actions propres à l'écran.
struct ContentToolbar: View {
    static let height: CGFloat = 57

    @EnvironmentObject private var state: AppState
    let title: String
    let actions: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.screenTitle)
                .foregroundStyle(Theme.text)
                .padding(.trailing, 6)
                .fixedSize()
            SearchField(text: $state.searchText,
                        placeholder: "Rechercher IP, MAC, hostname, fabricant, port de switch…")
                .frame(minWidth: 220, maxWidth: .infinity)
            if let actions {
                HStack(spacing: 8) { actions }.fixedSize()
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: ContentToolbar.height - 1)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1).offset(y: 1) }
    }
}

/// Champ de recherche aux couleurs des croquis (fond #F9FAFB, loupe à gauche).
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

/// Boutons qu'un écran place dans la barre d'outils, à droite de la recherche.
struct ToolbarActions {
    let view: AnyView
}

struct ToolbarActionsKey: PreferenceKey {
    static var defaultValue: ToolbarActions? = nil
    static func reduce(value: inout ToolbarActions?, nextValue: () -> ToolbarActions?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Place des boutons dans la barre d'outils du contenu (ex. « Lancer le scan », « Exporter »).
    func screenToolbar<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        preference(key: ToolbarActionsKey.self, value: ToolbarActions(view: AnyView(actions())))
    }
}
