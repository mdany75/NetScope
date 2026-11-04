import NetScopeCore
import SwiftUI

// Menu « Site ▾ » commun à l'Analyse, l'Inventaire, la Carte et les Rapports (demande de Dany,
// 0.12.0) : un, plusieurs ou tous les sites affichés, SANS changer le site actif du Scanner. Par
// défaut le site actif ; le choix est retenu par écran (UserDefaults « sites.vue.<écran> »).
// Les lignes de deux sites ne fusionnent jamais (identifiant composé « site|fiche », SiteScope).
//
// Captures : NETSCOPE_SITES_VUE="siege,laval" (parties de noms) ou « tous » choisit les sites des
// quatre écrans ; rien n'est lu ni écrit en démonstration.

/// Sites affichés par chaque écran.
@MainActor
final class SiteScopeStore: ObservableObject {
    static let shared = SiteScopeStore()
    static let screens: [Screen] = [.analyse, .inventaire, .carte, .rapports]

    @Published private var choices: [Screen: SiteSelection] = [:]
    private let defaults: UserDefaults?

    init() {
        let arguments = CommandLine.arguments
        let ephemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        defaults = ephemeral ? nil : .standard
        if let defaults {
            for screen in Self.screens {
                if let text = defaults.string(forKey: Self.defaultsKey(screen)) { choices[screen] = SiteSelection(stored: text) }
            }
        } else if let wanted = ProcessInfo.processInfo.environment["NETSCOPE_SITES_VUE"] {
            let sites = SiteModel.shared.sortedSites.map { (key: SiteFiles.key(for: $0.id), name: $0.displayName) }
            if let selection = SiteSelection.parse(wanted, sites: sites) {
                for screen in Self.screens { choices[screen] = selection }
            }
        }
    }

    private static func defaultsKey(_ screen: Screen) -> String { "sites.vue.\(screen.rawValue)" }

    func selection(for screen: Screen) -> SiteSelection { choices[screen] ?? .active }

    func set(_ selection: SiteSelection, for screen: Screen) {
        choices[screen] = selection
        defaults?.set(selection.stored, forKey: Self.defaultsKey(screen))
    }

    /// Clés des sites existants, triés par nom.
    var availableKeys: [String] { SiteModel.shared.sortedSites.map { SiteFiles.key(for: $0.id) } }

    /// Sites affichés par l'écran : le site actif d'abord, puis les autres par nom.
    func keys(for screen: Screen) -> [String] {
        selection(for: screen).resolve(activeKey: SiteModel.shared.activeKey, available: availableKeys)
    }

    func isMultiple(_ screen: Screen) -> Bool { keys(for: screen).count > 1 }

    /// Inventaires des sites affichés (lus depuis leur fichier pour les autres sites).
    func inventories(for screen: Screen) -> [SiteInventory] {
        let model = InvModel.shared
        return keys(for: screen).map { key in
            SiteInventory(key: key, name: SiteModel.shared.name(forKey: key), store: model.inventory(for: key))
        }
    }

    func toggle(_ key: String, for screen: Screen) {
        set(selection(for: screen).toggling(key, activeKey: SiteModel.shared.activeKey, available: availableKeys), for: screen)
    }

    /// Ajoute un site au choix de l'écran (« Voir » une alerte d'un autre site dans l'Inventaire).
    func include(_ key: String, in screen: Screen) {
        guard !keys(for: screen).contains(key) else { return }
        toggle(key, for: screen)
    }

    /// Libellé du bouton : « Siège », « Siège, Entrepôt Laval », « Siège + 3 sites », « Tous les sites (5) ».
    func label(for screen: Screen) -> String {
        let keys = keys(for: screen)
        let names = keys.map { SiteModel.shared.name(forKey: $0) }
        if case .all = selection(for: screen), keys.count > 1 { return "Tous les sites (\(keys.count))" }
        switch names.count {
        case 0, 1: return names.first ?? SiteModel.shared.activeName
        case 2: return names.joined(separator: ", ")
        default: return "\(names[0]) + \(names.count - 1) sites"
        }
    }
}

/// Bouton-menu natif « Site ▾ » : site actif seulement, cases des sites, tous les sites. Le nom du
/// ou des sites affichés est écrit sur le bouton, bien en vue en haut de l'écran.
struct SiteScopeMenu: View {
    let screen: Screen
    @ObservedObject private var store = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared

    var body: some View {
        let selection = store.selection(for: screen)
        let shown = Set(store.keys(for: screen))
        let names = store.keys(for: screen).map { sites.name(forKey: $0) }
        Menu {
            Toggle("Site actif seulement (\(sites.activeName))", isOn: Binding(
                get: { selection == .active }, set: { _ in store.set(.active, for: screen) }))
            if !sites.sortedSites.isEmpty {
                Section("Sites affichés") {
                    ForEach(sites.sortedSites) { site in
                        let key = SiteFiles.key(for: site.id)
                        Toggle(site.displayName + (key == sites.activeKey ? " (site actif)" : ""), isOn: Binding(
                            get: { shown.contains(key) }, set: { _ in store.toggle(key, for: screen) }))
                    }
                }
                Toggle("Tous les sites (\(sites.sortedSites.count))", isOn: Binding(
                    get: { selection == .all }, set: { _ in store.set(.all, for: screen) }))
            }
            Divider()
            Text("Le site actif du Scanner ne change pas")
        } label: {
            Label(store.label(for: screen), systemImage: "mappin.and.ellipse")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .help((names.count > 1 ? "Sites affichés\u{00A0}: " : "Site affiché\u{00A0}: ") + names.joined(separator: ", ")
              + ". Choisir un, plusieurs ou tous les sites sans changer le site actif du Scanner.")
        .accessibilityLabel("Sites affichés\u{00A0}: " + names.joined(separator: ", "))
    }
}
