import AppKit
import NetScopeCore
import SwiftUI

// Note 49 (demande de Dany, 0.15.0) : un sélecteur de site unique, toujours visible juste sous le
// logo NetScope. Il montre le site actif et la pastille de sa FortiGate (jointe ou non) ; il ouvre
// la liste des sites avec recherche (flèches et ↩︎ au clavier), « Aucun site (plages libres) »,
// « Tous les sites » (vue de tous les sites dans les modules qui ont un menu « Site ▾ »),
// « Détecter mon site » et « Gérer les sites… ». Choisir un site ici change le site actif de toute
// l'app (SiteModel.activate) ; le titre de la fenêtre le rappelle ; ⌘⇧S et le menu « Site » de la
// barre de menus font la même chose. Changer de site vide l'historique Retour (note 45).
//
// Captures : NETSCOPE_SITE_CHOIX=1 dessine la liste ouverte sous le bouton (une fenêtre surgissante
// n'entre pas dans la capture) ; toute autre valeur sert de recherche (« NETSCOPE_SITE_CHOIX=lav »).

/// Ouverture du sélecteur, depuis le bouton, ⌘⇧S ou le menu « Site ».
@MainActor
final class SitePickerPresenter: ObservableObject {
    static let shared = SitePickerPresenter()
    @Published var isPresented = false
    /// Demande à ContentView de montrer la barre latérale (le sélecteur y est accroché).
    @Published private(set) var sidebarRequest = 0
    /// Barre latérale visible (tenu à jour par ContentView).
    var sidebarVisible = true

    /// Liste ouverte dans les captures, et sa recherche.
    static var snapshotQuery: String? {
        guard CommandLine.arguments.contains("--snapshot"),
              let value = ProcessInfo.processInfo.environment["NETSCOPE_SITE_CHOIX"], !value.isEmpty else { return nil }
        return value == "1" ? "" : value
    }

    /// ⌘⇧S : ouvre le sélecteur (fenêtre principale au premier plan, barre latérale montrée si
    /// elle était masquée, puis la fenêtre surgissante une fois le bouton en place).
    func open() {
        MonWindow.open()
        guard !sidebarVisible else {
            isPresented = true
            return
        }
        sidebarRequest += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isPresented = true
        }
    }
}

// MARK: - État d'un site

extension SiteModel {
    /// Pastille du site : sa FortiGate a-t-elle répondu (cette session ou à la dernière lecture) ?
    func linkState(_ site: Site) -> SiteLinkState {
        let fortigate = FortiGateStore.shared
        let probes = site.fortiGateIDs.compactMap { id -> SiteFortiGateProbe? in
            guard let controller = fortigate.controller(id) else { return nil }
            let runtime = fortigate.runtime[id]
            return SiteFortiGateProbe(name: controller.displayName, isEnabled: controller.isEnabled && fortigate.isEnabled,
                                      readAt: runtime?.report?.readAt, error: runtime?.error, status: controller.lastStatus)
        }
        return SiteLinkState.evaluate(probes)
    }

    /// Résumé d'une ligne : « 3 plages · FortiGate jointe ».
    func pickerDetail(_ site: Site) -> String {
        let count = site.ranges.count
        return "\(count) plage\(count > 1 ? "s" : "") · " + linkState(site).label
    }
}

extension SiteLinkState {
    var dotColor: Color {
        switch self {
        case .joined: return Theme.successDot
        case .problem: return Theme.warningDot
        case .notRead, .noFortiGate: return Theme.neutralDot
        }
    }

    var helpText: String { help(time: SitePickerFormat.time) }
}

enum SitePickerFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ date: Date) -> String { formatter.string(from: date) }
}

/// Pastille ronde : pleine si une FortiGate est associée, cerclée sinon (site sans FortiGate).
struct SiteLinkDot: View {
    let state: SiteLinkState
    var size: CGFloat = 8

    var body: some View {
        Group {
            if case .noFortiGate = state {
                Circle().strokeBorder(Theme.neutralDot, lineWidth: 1.3)
            } else {
                Circle().fill(state.dotColor)
            }
        }
        .frame(width: size, height: size)
        .help(state.helpText)
        .accessibilityLabel(state.helpText)
    }
}

// MARK: - « Tous les sites »

extension SiteScopeStore {
    /// Vrai quand chaque module qui a un menu « Site ▾ » montre tous les sites.
    var showsAllEverywhere: Bool {
        Self.screens.allSatisfy { selection(for: $0) == .all }
    }

    /// « Tous les sites » du sélecteur : tous les modules montrent tous les sites (ou reviennent au
    /// site actif). Le site actif, celui du Scanner, ne change pas.
    func showAllEverywhere(_ on: Bool) {
        for screen in Self.screens { set(on ? .all : .active, for: screen) }
    }
}

// MARK: - Bouton sous le logo

/// « ● Siège ⌃⌄ » sous le logo : nom du site actif, pastille de sa FortiGate, nombre de plages.
struct SidebarSitePicker: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var presenter = SitePickerPresenter.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var shortcuts = RegShortcutStore.shared
    @State private var hover = false

    var body: some View {
        let site = sites.activeSite
        let link = site.map { sites.linkState($0) }
        Button { presenter.isPresented = true } label: {
            VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: site == nil ? "mappin.slash" : "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(site == nil ? Theme.textSecondary : Theme.accent)
                        .frame(width: 20, height: 20)
                    if let link {
                        SiteLinkDot(state: link, size: 7)
                            .background(Circle().fill(Theme.panel).frame(width: 10, height: 10))
                            .offset(x: 2, y: 1)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(sites.activeName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Barre latérale étroite : l'état de la FortiGate seul plutôt qu'une ligne coupée.
                    ViewThatFits(in: .horizontal) {
                        Text(subtitle(site)).lineLimit(1).fixedSize()
                        Text(shortSubtitle(site, link: link)).lineLimit(1).truncationMode(.tail)
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            // Croquis 2 : les plages du site et un petit résumé, dans la même carte.
            Divider().opacity(0.8)
            siteDetails
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Même carte que « Interface active » en bas de la barre latérale.
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(hover || presenter.isPresented ? Theme.hover.opacity(1.6) : Theme.hover))
            .contentShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Site actif\u{00A0}: \(sites.activeName)" + (link.map { " · \($0.helpText)" } ?? "")
              + ". Choisir un autre site" + (shortcuts.combo(ShortcutID.chooseSite).map { " (\($0.display))" } ?? ""))
        .accessibilityLabel("Site actif\u{00A0}: \(sites.activeName). Choisir un autre site")
        .popover(isPresented: $presenter.isPresented, arrowEdge: .trailing) {
            SitePickerPanel(close: { presenter.isPresented = false })
                .environmentObject(state)
        }
    }

    private static let rangesShown = 3

    /// Plages du site actif (au plus trois, puis « +N plages »), dans le style des plages du
    /// Scanner, puis le résumé : appareils du dernier scan et alertes de la Surveillance.
    @ViewBuilder private var siteDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.ranges.isEmpty {
                Text("Aucune plage").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(state.ranges.prefix(Self.rangesShown)) { range in
                HStack(spacing: 6) {
                    Text(range.text).font(Theme.mono(11)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(range.label).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .opacity(range.isEnabled ? 1 : 0.55)
            }
            if state.ranges.count > Self.rangesShown {
                let extra = state.ranges.count - Self.rangesShown
                Text("+\(extra) plage\(extra > 1 ? "s" : "")").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                if sites.hasUnsavedRanges(state) {
                    Circle().fill(Theme.warningDot).frame(width: 6, height: 6)
                        .help("Plages modifiées, non enregistrées dans le site")
                }
                Text(summary).lineLimit(1).truncationMode(.tail)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 2)
        }
    }

    private var summary: String {
        let count = state.devices.count
        let devices = count == 0 ? "Aucun scan" : "\(count) appareil\(count > 1 ? "s" : "")"
        let alerts = state.sidebarBadges[.surveillance] ?? 0
        guard alerts > 0 else { return devices }
        return devices + " · \(alerts) alerte\(alerts > 1 ? "s" : "")"
    }

    private func shortSubtitle(_ site: Site?, link: SiteLinkState?) -> String {
        guard site != nil else { return "Plages libres" }
        if scopes.showsAllEverywhere { return "Tous les sites" }
        return link?.label ?? ""
    }

    private func subtitle(_ site: Site?) -> String {
        guard let site else { return "Plages libres" }
        if scopes.showsAllEverywhere { return "Vue\u{00A0}: tous les sites" }
        return sites.pickerDetail(site)
    }
}

// MARK: - Liste des sites

/// Contenu du sélecteur : recherche, sites (pastille, plages), plages libres, « Tous les sites »,
/// « Détecter mon site », « Gérer les sites… ». ↑ ↓ choisissent une ligne, ↩︎ l'ouvre.
struct SitePickerPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @State private var query: String
    @State private var highlighted: UUID?
    @FocusState private var searchFocused: Bool
    let close: () -> Void

    init(close: @escaping () -> Void, query: String = "") {
        self.close = close
        _query = State(initialValue: query)
    }

    private var filtered: [Site] { SitePicker.filter(sites.sortedSites, query: query) }

    var body: some View {
        let rows = filtered
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("Rechercher un site, une plage, un VLAN", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { choose(highlighted ?? rows.first?.id, among: rows) }
                    .onKeyPress(.downArrow) { move(1, rows); return .handled }
                    .onKeyPress(.upArrow) { move(-1, rows); return .handled }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("SITES").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(rows.count == sites.sites.count ? "\(rows.count)" : "\(rows.count) sur \(sites.sites.count)")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                        if rows.isEmpty {
                            Text(sites.sites.isEmpty ? "Aucun site enregistré." : "Aucun site ne correspond à «\u{00A0}\(query)\u{00A0}».")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        ForEach(rows) { site in
                            SitePickerRow(site: site, link: sites.linkState(site), isActive: site.id == sites.activeID,
                                          isHighlighted: site.id == highlighted,
                                          shared: !sites.list.sharingAddresses(with: site.id).isEmpty) {
                                choose(site.id, among: rows)
                            }
                            .id(site.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
                .frame(height: min(CGFloat(max(rows.count, 1)) * 41 + 34, 300))
                .onChange(of: highlighted) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                SitePickerAction(title: "Aucun site (plages libres)", detail: "FortiGate choisie par plage", symbol: "mappin.slash",
                                 checked: sites.activeID == nil) {
                    act { sites.activate(nil, state: state) }
                }
                SitePickerAction(title: "Tous les sites", detail: "Inventaire, Carte, Analyse, Rapports, Switchs et Wi-Fi\u{00A0}; le Scanner garde le site actif",
                                 symbol: "square.stack.3d.up", checked: scopes.showsAllEverywhere) {
                    let on = !scopes.showsAllEverywhere
                    act { scopes.showAllEverywhere(on) }
                }
                Divider().padding(.vertical, 3)
                SitePickerAction(title: "Détecter mon site", detail: "Par la passerelle, jamais par l’adresse IP seule", symbol: "scope") {
                    act {
                        state.open(.scanner)
                        sites.detect(state: state)
                    }
                }
                SitePickerAction(title: "Gérer les sites…", detail: "Réglages › Sites et plages", symbol: "gearshape") {
                    act {
                        RegNavigation.shared.section = .sites
                        state.open(.reglages)
                    }
                }
            }
            .padding(4)
        }
        .frame(width: 340)
        .onAppear {
            highlighted = sites.activeID ?? filtered.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            let rows = filtered
            if let current = highlighted, rows.contains(where: { $0.id == current }) { return }
            highlighted = rows.first?.id
        }
    }

    private func move(_ offset: Int, _ rows: [Site]) {
        highlighted = SitePicker.step(from: highlighted, in: rows.map(\.id), by: offset)
    }

    /// Ferme la liste puis agit (une question « Plages non enregistrées » s'ouvre après la fermeture).
    private func act(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.async { action() }
    }

    private func choose(_ id: UUID?, among rows: [Site]) {
        guard let id, rows.contains(where: { $0.id == id }) else { return }
        act { sites.activate(id, state: state) }
    }
}

/// Une ligne de site : pastille, nom (gras pour le site actif), plages, coche.
private struct SitePickerRow: View {
    let site: Site
    let link: SiteLinkState
    let isActive: Bool
    let isHighlighted: Bool
    let shared: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).opacity(isActive ? 1 : 0)
                    .frame(width: 10)
                SiteLinkDot(state: link)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.displayName).font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text(site.ranges.isEmpty ? "Aucune plage" : site.rangesLabel)
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if shared {
                    Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        .help("Un autre site a des adresses en commun\u{00A0}: jamais de mélange entre les deux")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(isHighlighted ? Theme.accentSoft : (hover ? Theme.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(site.displayName) · \(link.helpText)")
    }
}

/// Action du bas du sélecteur (avec une coche facultative).
private struct SitePickerAction: View {
    let title: String
    let detail: String
    let symbol: String
    var checked: Bool? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).opacity(checked == true ? 1 : 0)
                    .frame(width: 10)
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(detail)
    }
}

// MARK: - Captures

/// Captures (NETSCOPE_SITE_CHOIX) : la liste dessinée sous le bouton, comme une fenêtre surgissante.
struct SitePickerSnapshotOverlay: View {
    var body: some View {
        if let query = SitePickerPresenter.snapshotQuery {
            SitePickerPanel(close: {}, query: query)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.leading, 206)
                .padding(.top, 70)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Menu « Site » de la barre de menus

/// Menu « Site » : choisir le site (⌘⇧S), la liste des sites, plages libres, détecter, gérer.
struct SiteCommandsMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var shortcuts = RegShortcutStore.shared

    var body: some View {
        Button("Choisir le site…") { SitePickerPresenter.shared.open() }
            .regShortcut(ShortcutID.chooseSite, shortcuts)
        Divider()
        Section("Sites") {
            ForEach(sites.sortedSites) { site in
                Toggle(site.displayName, isOn: Binding(get: { site.id == sites.activeID },
                                                       set: { if $0 { sites.activate(site.id, state: state) } }))
            }
            if sites.sites.isEmpty { Text("Aucun site enregistré") }
        }
        Toggle("Aucun site (plages libres)", isOn: Binding(get: { sites.activeID == nil },
                                                           set: { if $0 { sites.activate(nil, state: state) } }))
        Divider()
        Button("Détecter mon site") {
            MonWindow.open()
            state.open(.scanner)
            sites.detect(state: state)
        }
        Button("Gérer les sites…") {
            MonWindow.open()
            RegNavigation.shared.section = .sites
            state.open(.reglages)
        }
    }
}
