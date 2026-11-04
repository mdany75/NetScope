import AppKit
import NetScopeCore
import SwiftUI

// Navigation entre les modules (notes 31, 33 et 34) : le même geste partout (double-clic ou ↩︎)
// mène à la suite logique de l'objet, un menu contextuel « Ouvrir dans › » propose les autres
// modules, et Retour / Avancer (⌘[ et ⌘], menu Aller, boutons ‹ › de la barre d'outils) rendent
// l'écran, la recherche, le filtre transmis, la sélection et les sites d'avant.
//
// Le moteur (NavResolver, NavPortResolver, NavHistory) est dans NetScopeCore/Navigation ; ce
// fichier rassemble ce que l'app sait (NavContext) et applique les destinations.
//
// BRANCHER UN TABLEAU STANDARD : `.standardRowActions(selection: lignesChoisies, object: { id in … }) { ids in
// menu propre au tableau }` remplace `.contextMenu(forSelectionType:menu:primaryAction:)` : double-clic
// et ↩︎ → `state.perform(objet)`, et le menu reçoit « Ouvrir dans › » à la fin. Sans menu propre :
// `.standardRowNavigation(selection:object:)`. `primary:` : action du tableau essayée d'abord
// (Accès distant : « Connecter »). Ailleurs (façade, Carte, barre latérale) : `state.perform(objet)`
// au double-clic et `OpenInMenu(object:)` dans le menu contextuel.
//
// Captures : NETSCOPE_NAV="carte:imprimantes>inventaire" ouvre l'Inventaire depuis le groupe
// « Imprimantes ×N » de la Carte (étiquette du filtre et bouton Retour actif) ; voir NavDemo.

extension Screen {
    var navModule: NavModule { NavModule(rawValue: rawValue) ?? .scanner }

    init(_ module: NavModule) {
        self = Screen(rawValue: module.rawValue) ?? .scanner
    }
}

/// Liste à choisir (plusieurs appareils sur un port) ou message (port vide, uplink…) d'un double-clic.
struct NavPrompt: Identifiable {
    enum Kind { case choose, message }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
    var options: [NavOption] = []
    /// Suite commune (Inventaire filtré sur le port).
    var all: NavOption?
    /// Suite proposée par un message (Ouvrir le Scanner, le switch voisin…).
    var suggestion: NavOption?
}

// MARK: - Routeur

extension AppState {
    /// L'endroit où l'on est sur un écran : recherche, filtre transmis, sélection, sites.
    func location(of screen: Screen) -> NavLocation {
        NavLocation(screen.navModule, search: searchTexts[screen] ?? "", filter: navFilters[screen],
                    deviceID: selectedDeviceID,
                    sites: SiteScopeStore.screens.contains(screen) ? SiteScopeStore.shared.selection(for: screen) : nil,
                    focus: currentFocus(of: screen))
    }

    /// Ce que l'écran montre en ce moment (port du switch, sonde, connexion, outil…).
    private func currentFocus(of screen: Screen) -> NavFocus? {
        switch screen {
        case .switchs:
            let store = SwitchStore.shared
            // Note 48 : switch choisi dans la vue d'un autre site (ou de plusieurs).
            if SiteScopeStore.shared.keys(for: .switchs) != [SiteModel.shared.activeKey] {
                return store.browseSelection.flatMap(SiteScope.split).map { .switchPort(host: $0.key, port: nil) }
            }
            return store.selectedHost.map { .switchPort(host: $0, port: store.selectedInterface?.name) }
        case .surveillance:
            return MonStore.shared.selectedID.map { .probe($0.uuidString) }
        case .acces:
            return RemoteModel.shared.selectedID.map { .remote($0.uuidString) }
        case .outils:
            return .tool(ToolStore.shared.selectedTool.rawValue)
        default:
            return shownFocus[screen]
        }
    }

    /// Appelé à chaque changement d'écran (barre latérale, menus, boutons) : l'écran quitté est retenu.
    func screenChanged(from old: Screen) {
        guard recordsHistory, !isNavigating, old != screen else { return }
        history.leave(location(of: old))
    }

    /// Va à une destination : écran, ce qu'il montre, filtre transmis, recherche et sites.
    func navigate(_ destination: NavDestination) {
        let target = Screen(destination.module)
        let here = location(of: screen)
        isNavigating = true
        defer { isNavigating = false }
        if let search = destination.search { searchTexts[target] = search.isEmpty ? nil : search }
        // Une nouvelle recherche ou un nouveau filtre remplace le filtre transmis précédent.
        if destination.filter != nil || destination.search != nil {
            navFilters[target] = destination.filter
        } else if destination.focus != nil {
            // Un objet précis à montrer : le filtre transmis précédent pourrait le cacher.
            navFilters[target] = nil
        }
        if let sites = destination.sites, SiteScopeStore.screens.contains(target) {
            switch sites {
            case .include(let key): SiteScopeStore.shared.include(key, in: target)
            case .only(let keys): SiteScopeStore.shared.set(.sites(keys), for: target, persist: false)
            }
        }
        // Note 48 : Switchs et Wi-Fi suivent le site de l'objet ; un objet du site actif (sans site
        // donné) y ramène le site actif s'il n'est plus affiché.
        if destination.focus != nil, destination.sites == nil, target == .switchs || target == .wifi,
           !SiteScopeStore.shared.keys(for: target).contains(SiteModel.shared.activeKey) {
            SiteScopeStore.shared.set(.active, for: target, persist: false)
        }
        if let focus = destination.focus { apply(focus, on: target, siteKey: destination.sites?.siteKey) }
        if screen != target { screen = target }
        if recordsHistory { history.leave(here, to: location(of: target)) }
    }

    /// Double-clic ou ↩︎ sur un objet : sa suite logique, une liste à choisir ou un message.
    func perform(_ object: NavObject) {
        apply(NavResolver.primary(object, in: navContext(for: object)))
    }

    func apply(_ outcome: NavOutcome) {
        switch outcome {
        case .go(let destination):
            navigate(destination)
        case .choose(let title, let message, let options, let all):
            navPrompt = NavPrompt(kind: .choose, title: title, message: message, options: options, all: all)
        case .message(let title, let text, let suggestion):
            navPrompt = NavPrompt(kind: .message, title: title, message: text, suggestion: suggestion)
        }
    }

    /// Entrées du menu « Ouvrir dans › » de l'objet.
    func openInItems(_ object: NavObject) -> [NavMenuItem] {
        NavResolver.openIn(object, in: navContext(for: object))
    }

    /// « Voir le port » : Switchs et ports sur ce switch et ce port s'il a été relevé, sinon l'écran tel quel.
    func showSwitchPort(switchName: String?, port: String?) {
        if let snapshot = navContext().switchSnapshot(named: switchName) {
            navigate(NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: port)))
        } else {
            open(.switchs)
        }
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func goBack() {
        guard let previous = history.goBack(from: location(of: screen)) else { return }
        restore(previous)
    }

    func goForward() {
        guard let next = history.goForward(from: location(of: screen)) else { return }
        restore(next)
    }

    /// Rend un endroit de l'historique tel qu'il était.
    private func restore(_ location: NavLocation) {
        let target = Screen(location.module)
        isNavigating = true
        defer { isNavigating = false }
        searchTexts[target] = location.search.isEmpty ? nil : location.search
        navFilters[target] = location.filter
        if let id = location.deviceID { selectedDeviceID = id }
        if let sites = location.sites, SiteScopeStore.screens.contains(target) {
            SiteScopeStore.shared.set(sites, for: target, persist: false)
        }
        // Note 48 : le switch d'un autre site revient dans la vue de ce site.
        var siteKey: String?
        if case .sites(let keys)? = location.sites, keys.count == 1 { siteKey = keys[0] }
        if let focus = location.focus { apply(focus, on: target, siteKey: siteKey) }
        screen = target
    }

    /// Montre l'objet dans l'écran d'arrivée (les écrans lisent les magasins communs).
    /// `siteKey` : site de l'objet quand la destination le donne (sinon le site actif).
    private func apply(_ focus: NavFocus, on screen: Screen, siteKey: String? = nil) {
        switch focus {
        case .device(let id):
            if screen == .carte {
                pendingFocus[.carte] = focus
                // Sélection du Scanner : seulement un appareil du site actif (même IP sur un autre
                // site = autre appareil).
                let sameSite = siteKey == nil || siteKey == SiteModel.shared.activeKey
                if sameSite, device(withID: id) != nil { selectedDeviceID = id }
            } else {
                selectedDeviceID = id
            }
        case .record(let site, let key):
            InvModel.shared.selectedSite = site
            InvModel.shared.selectedKey = key
            shownFocus[.inventaire] = focus
        case .switchPort(let host, let port):
            let store = SwitchStore.shared
            // Note 48 : switch d'un autre site, montré dans la vue de ce site (host : adresse ou nom).
            if let siteKey, siteKey != SiteModel.shared.activeKey {
                store.browseFocus = SwitchBrowseFocus(siteKey: siteKey, hostOrName: host, port: port)
                return
            }
            let index = port.flatMap { name in store.snapshots[host]?.interfaces.first { $0.name == name }?.index }
            store.select(host: host, port: index)
        case .accessPoint(let id):
            FortiAPStore.shared.focusAP = id
        case .probe(let id):
            MonStore.shared.selectedID = UUID(uuidString: id)
        case .remote(let id):
            RemoteModel.shared.selectedID = UUID(uuidString: id)
        case .tool(let raw):
            if let tool = ToolKind(rawValue: raw) { ToolStore.shared.selectedTool = tool }
        case .service(let id):
            ToolStore.shared.selectedTool = .cloud
            let svc = SvcStore.shared
            let wanted = SearchText.fold(id)
            svc.selectedServiceID = svc.service(id)?.id
                ?? svc.services.first { SearchText.fold($0.name).contains(wanted) || wanted.contains(SearchText.fold($0.name)) }?.id
        case .backup:
            RegNavigation.shared.section = .export
        case .node:
            pendingFocus[.carte] = focus
        case .pingTarget(let target):
            sendToPing(target, open: false)
        }
    }

    /// Ce que l'app sait au moment du double-clic (site actif et site de l'objet).
    func navContext(for object: NavObject? = nil) -> NavContext {
        let active = SiteModel.shared.activeKey
        var keys = [active]
        switch object {
        case .device(let ref)?: if let site = ref.siteKey { keys.append(site) }
        case .group(let group)?: keys.append(group.siteKey)
        case .analysisEvent(let site, _, _)?: keys.append(site)
        default: break
        }
        // Un seul appareil (menu Appareil › Ouvrir dans, recalculé souvent) : seulement ses fiches,
        // pas tout l'inventaire du site.
        var only: (ip: String, mac: String?)?
        switch object {
        case .device(let ref)?: only = (ref.ip, ref.mac)
        case .wifiClient(let mac, let ip, _, _)?: only = (ip ?? "", mac)
        case .accessPoint(_, _, let ip?)?: only = (ip, nil)
        default: break
        }
        var inventories: [String: [InvRecord]] = [:]
        for key in Set(keys) {
            let records = InvModel.shared.inventory(for: key).records.values
            if let only {
                inventories[key] = records.filter { $0.ip.description == only.ip || ($0.mac?.formatted(.upperColon)).map { $0 == only.mac } == true }
            } else {
                inventories[key] = Array(records)
            }
        }
        let fortiAP = FortiAPStore.shared.overview
        // Note 48 : bornes d'un autre site montrées dans Wi-Fi (double-clic sur une ligne).
        let shownAPs = FortiAPStore.shared.shownOverview.aps.filter { ap in !fortiAP.aps.contains { $0.id == ap.id } }
        var clients: [String: String] = [:]
        for client in fortiAP.clients {
            if let ap = fortiAP.ap(for: client) { clients[client.mac.formatted(.upperColon)] = ap.id }
        }
        var remotes: [String: String] = [:]
        for connection in RemoteModel.shared.connections { remotes[connection.host] = connection.id.uuidString }
        return NavContext(activeSiteKey: active,
                          scanner: devices.map { NavDeviceRef($0) },
                          inventories: inventories,
                          switches: SwitchStore.shared.orderedSnapshots,
                          accessPoints: (fortiAP.aps + shownAPs).map { (id: $0.id, name: $0.name, ip: $0.ip?.description) },
                          wifiClients: clients,
                          probes: MonStore.shared.probes.map(NavProbeRef.init),
                          remoteHosts: remotes)
    }
}

// MARK: - Retour / Avancer

/// Boutons ‹ › de la barre d'outils, comme le Finder.
struct NavHistoryButtons: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var shortcuts = RegShortcutStore.shared

    /// Raccourci en vigueur (Réglages › Raccourcis), s'il y en a un.
    private func shortcutSuffix(_ id: String) -> String {
        shortcuts.combo(id).map { " (\($0.display))" } ?? ""
    }

    var body: some View {
        ControlGroup {
            // Note 45 : le bouton nomme l'écran d'origine (« ‹ Inventaire »).
            Button { state.goBack() } label: {
                if let previous = state.history.previous {
                    Label(previous.module.shortTitle, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                } else {
                    Label("Retour", systemImage: "chevron.left")
                }
            }
                .disabled(!state.canGoBack)
                .help((state.history.previous.map { "Retour à «\u{00A0}\(Screen($0.module).title)\u{00A0}»" } ?? "Retour") + shortcutSuffix(ShortcutID.back))
            Button { state.goForward() } label: { Label("Avancer", systemImage: "chevron.right") }
                .disabled(!state.canGoForward)
                .help((state.history.next.map { "Avancer vers «\u{00A0}\(Screen($0.module).title)\u{00A0}»" } ?? "Avancer") + shortcutSuffix(ShortcutID.forward))
        } label: {
            Label("Retour et Avancer", systemImage: "chevron.left")
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
        .modifier(SnapshotActiveState())
    }
}

// MARK: - Ouvrir dans ›

/// Sous-menu « Ouvrir dans › » d'un objet : les modules pertinents, raccourcis ⌥⌘1 à ⌥⌘9 (rang
/// du module dans la barre latérale) et ⌥⌘0 pour l'Analyse.
struct OpenInMenu: View {
    @EnvironmentObject private var state: AppState
    let object: NavObject

    var body: some View {
        let items = state.openInItems(object)
        if !items.isEmpty {
            Menu("Ouvrir dans") {
                ForEach(items) { item in
                    NavMenuButton(item: item)
                }
            }
        }
    }
}

/// Entrée d'un menu « Ouvrir dans › » (avec son raccourci ⌥⌘).
struct NavMenuButton: View {
    @EnvironmentObject private var state: AppState
    let item: NavMenuItem

    var body: some View {
        let button = Button {
            state.navigate(item.destination)
        } label: {
            Label(item.title, systemImage: Screen(item.destination.module).symbol)
        }
        if let digit = item.shortcutDigit, let key = digit.first {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: [.option, .command])
        } else {
            button
        }
    }
}

// MARK: - Tableaux standard

extension View {
    /// Point d'accroche commun des tableaux standard (note 34) : double-clic et ↩︎ sur une ligne
    /// mènent à la suite logique de son objet ; le menu contextuel du tableau reçoit « Ouvrir dans › ».
    /// - `selection` : lignes choisies (pour ↩︎).
    /// - `object` : objet d'une ligne (nil : ligne sans suite, ex. une MAC inconnue).
    /// - `primary` : action propre au tableau, essayée d'abord (vrai : elle a tout fait).
    func standardRowActions<ID: Hashable, Menu: View>(selection: [ID], object: @escaping (ID) -> NavObject?,
                                                      primary: ((Set<ID>) -> Bool)? = nil,
                                                      @ViewBuilder menu: @escaping (Set<ID>) -> Menu) -> some View {
        modifier(StandardRowActions(selection: selection, object: object, primary: primary, menu: menu))
    }

    func standardRowNavigation<ID: Hashable>(selection: [ID], object: @escaping (ID) -> NavObject?,
                                          primary: ((Set<ID>) -> Bool)? = nil) -> some View {
        modifier(StandardRowActions(selection: selection, object: object, primary: primary, menu: { _ in EmptyView() }))
    }
}

private struct StandardRowActions<ID: Hashable, Menu: View>: ViewModifier {
    @EnvironmentObject private var state: AppState
    let selection: [ID]
    let object: (ID) -> NavObject?
    let primary: ((Set<ID>) -> Bool)?
    let menu: (Set<ID>) -> Menu

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: ID.self) { ids in
            menu(ids)
            if ids.count == 1, let id = ids.first, let object = object(id) {
                Divider()
                OpenInMenu(object: object)
            }
        } primaryAction: { ids in
            open(ids)
        }
        // ↩︎ sur la ligne choisie : même suite que le double-clic.
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            open(Set(selection))
            return .handled
        }
    }

    private func open(_ ids: Set<ID>) {
        if let primary, primary(ids) { return }
        // Plusieurs lignes : la première dans l'ordre du tableau.
        guard let id = selection.first(where: ids.contains) ?? ids.first, let object = object(id) else { return }
        state.perform(object)
    }
}

// MARK: - Étiquette du filtre transmis

/// Étiquette d'un filtre transmis (« Carte : Téléphones ×11 · SW-ETG2-01 ») : comme celles de la
/// recherche multiple, préfixe en gras, × pour la retirer.
struct NavFilterChip: View {
    let filter: NavFilter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: filter.origin == .carte ? Screen.carte.symbol : Screen.switchs.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(filter.prefix + "\u{00A0}:").font(.system(size: 11.5, weight: .semibold))
            Text(filter.value).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.hover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer le filtre \(filter.label)")
        }
        .foregroundStyle(Theme.accentStrong)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(Capsule().fill(Theme.accentSoft))
        .fixedSize()
        .help(filter.help)
    }
}

// MARK: - Liste à choisir et messages

extension View {
    /// Fenêtre « Plusieurs appareils sur … » et messages clairs (port vide, uplink…) des double-clics.
    func navigationPrompts() -> some View {
        modifier(NavPromptPresenter())
    }
}

private struct NavPromptPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { state.navPrompt?.kind == .choose ? state.navPrompt : nil },
                                 set: { if $0 == nil { state.navPrompt = nil } })) { prompt in
                NavChooseSheet(prompt: prompt).environmentObject(state)
            }
            .alert(state.navPrompt?.title ?? "",
                   isPresented: Binding(get: { state.navPrompt?.kind == .message },
                                        set: { if !$0 { state.navPrompt = nil } }),
                   presenting: state.navPrompt) { prompt in
                if let suggestion = prompt.suggestion, let destination = suggestion.destination {
                    Button(suggestion.title) { state.navigate(destination) }
                }
                Button("OK", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
    }
}

/// Petite liste à choisir : les appareils vus derrière un port (note 33).
struct NavChooseSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let prompt: NavPrompt
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(Theme.panelTitle)
            Text(prompt.message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            List(prompt.options, selection: $selection) { option in
                HStack(spacing: 10) {
                    Image(systemName: option.destination == nil ? "questionmark.circle" : Screen((option.destination?.module) ?? .appareil).symbol)
                        .foregroundStyle(option.destination == nil ? Theme.textTertiary : Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title).font(Theme.bodySemibold)
                            .foregroundStyle(option.destination == nil ? Theme.textSecondary : Theme.text)
                        Text(option.detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .tag(option.id)
                .selectionDisabled(option.destination == nil)
            }
            .listStyle(.bordered)
            .frame(minHeight: 120, idealHeight: CGFloat(min(prompt.options.count, 6)) * 44 + 8)
            .contextMenu(forSelectionType: String.self) { _ in EmptyView() } primaryAction: { ids in
                if let id = ids.first { choose(id) }
            }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                choose(selection)
                return .handled
            }
            HStack {
                if let all = prompt.all, let destination = all.destination {
                    Button {
                        dismiss()
                        state.navigate(destination)
                    } label: { Label(all.title, systemImage: Screen.inventaire.symbol) }
                        .help(all.detail)
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ouvrir") { if let selection { choose(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.options.first { $0.id == selection }?.destination == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { selection = prompt.options.first { $0.destination != nil }?.id }
    }

    private func choose(_ id: String) {
        guard let destination = prompt.options.first(where: { $0.id == id })?.destination else { return }
        dismiss()
        state.navigate(destination)
    }
}
