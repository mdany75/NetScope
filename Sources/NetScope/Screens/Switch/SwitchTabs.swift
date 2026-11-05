import NetScopeCore
import SwiftUI

// Note 83 : Switchs et ports en onglets natifs sous le bandeau du site et les tuiles de résumé.
// Les règles (onglets, ports, VLAN, voisins, résumé) sont dans NetScopeCore/SwitchPages ; ce
// fichier garde l'onglet choisi, dessine la barre des onglets et les tuiles.
//
// Captures : NETSCOPE_SWITCH_ONGLET=switchs | ports | trafic | appareils | voisins ;
// NETSCOPE_SWITCH_PORTS=tous | actifs | inactifs | poe | uplinks | erreurs (filtre de l'onglet Ports).

/// Onglet et filtres de Switchs et ports, gardés d'une visite à l'autre (l'onglet aussi d'un
/// lancement à l'autre, hors démonstration).
@MainActor
final class SwitchTabState: ObservableObject {
    static let shared = SwitchTabState()

    @Published var tab: SwitchPageTab {
        didSet { if !isDemo, tab != oldValue { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) } }
    }
    /// Filtre de l'onglet Ports.
    @Published var portFilter: SwitchPortFilter = .all
    /// Texte du champ « Filtrer » de l'onglet Ports.
    @Published var portText = ""

    private let isDemo: Bool
    private static let tabKey = "NetScope.switchs.onglet"

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            let env = ProcessInfo.processInfo.environment
            // Sans onglet demandé, les anciennes variables de capture gardent leur vue : un port
            // (NETSCOPE_PORT, actions sur le port) s'ouvre dans Ports, l'historique dans Trafic.
            let implied: SwitchPageTab
            if ["NETSCOPE_PORT", "NETSCOPE_PORT_ACTION", "NETSCOPE_PORT_FEUILLE"].contains(where: { env[$0] != nil }) {
                implied = .ports
            } else if env["NETSCOPE_SWITCH_HISTORIQUE"] != nil || env["NETSCOPE_SWITCH_TABLEAU"] != nil {
                implied = .trafic
            } else {
                implied = .switchs
            }
            tab = env["NETSCOPE_SWITCH_ONGLET"].flatMap(SwitchPageTab.init(capture:)) ?? implied
            portFilter = env["NETSCOPE_SWITCH_PORTS"].flatMap(SwitchPortFilter.init(capture:)) ?? .all
        } else {
            tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(SwitchPageTab.init(rawValue:)) ?? .switchs
        }
    }

    /// Lien d'un onglet vers un autre (clic sur un port de la façade, « Voir le port »…) : le
    /// switch et le port sont choisis, l'onglet change, et Retour (⌘[) ramène à l'onglet quitté.
    func jump(_ tab: SwitchPageTab, host: String? = nil, port: Int? = nil, filter: SwitchPortFilter? = nil, in state: AppState) {
        let store = SwitchStore.shared
        let records = state.recordsHistory && !state.isNavigating && state.screen == .switchs
        let here = records ? state.location(of: .switchs) : nil
        if let host { store.select(host: host, port: port) } else if let port { store.selectedPort = port }
        if let filter { portFilter = filter }
        // Un port choisi ailleurs reste visible dans le tableau : le filtre qui le cacherait est levé.
        if tab == .ports, let port, filter == nil, let snapshot = store.current,
           let row = SwitchPortRows.make(snapshot, recent: store.recentErrors(snapshot.id)).first(where: { $0.ifIndex == port }),
           !portFilter.matches(row) {
            portFilter = .all
        }
        self.tab = tab
        if let here { state.history.leave(here, to: state.location(of: .switchs)) }
    }
}

// MARK: - Barre des onglets

/// Onglets natifs (contrôle segmenté, menu en petite fenêtre) et, pour les onglets d'un seul
/// switch, le choix du switch à droite.
struct SwitchTabBar: View {
    @ObservedObject var tabs: SwitchTabState
    @ObservedObject var store: SwitchStore
    /// Switchs relevés du site (ordre des cartes).
    let snapshots: [SNMPSwitchSnapshot]
    let shown: SNMPSwitchSnapshot?
    let summary: SwitchPageSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                segmented(counts: true)
                Spacer(minLength: 8)
                switchPicker
            }
            HStack(spacing: 10) {
                segmented(counts: false)
                Spacer(minLength: 8)
                switchPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                segmented(counts: false)
                switchPicker
            }
            HStack(spacing: 10) {
                menu
                Spacer(minLength: 8)
                switchPicker
            }
        }
    }

    /// Compteur affiché sur l'onglet : ports en erreur de tout le site (même chiffre que la tuile
    /// « Ports en erreur »), switchs, voisins.
    private func badge(_ tab: SwitchPageTab) -> Int? {
        switch tab {
        case .switchs: return snapshots.count
        case .ports: return summary.errorPorts.count
        case .voisins: return summary.neighbors
        case .trafic, .appareils: return nil
        }
    }

    private func segmented(counts: Bool) -> some View {
        Picker("Onglet", selection: $tabs.tab) {
            ForEach(SwitchPageTab.allCases, id: \.self) { tab in
                Text(counts ? tab.title(badge: badge(tab)) : tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(tabs.tab.hint)
    }

    private var menu: some View {
        HStack(spacing: 8) {
            Text("Onglet").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            Picker("Onglet", selection: $tabs.tab) {
                ForEach(SwitchPageTab.allCases, id: \.self) { tab in
                    Label(tab.title(badge: badge(tab)), systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Choix du switch des onglets Ports, Trafic et Appareils (les cartes sont dans Switchs).
    @ViewBuilder private var switchPicker: some View {
        if tabs.tab.isPerSwitch, let shown, snapshots.count > 1 {
            HStack(spacing: 6) {
                Text("Switch").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                Picker("Switch", selection: Binding(get: { shown.id }, set: { store.select(host: $0) })) {
                    ForEach(snapshots) { snapshot in
                        Text(snapshot.displayName + (snapshot.isViaController ? " · FortiGate" : "")).tag(snapshot.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Switch montré dans les onglets Ports, Trafic et Appareils")
            }
        }
    }
}

// MARK: - Tuiles de résumé

/// Tuiles sous le bandeau du site : un clic ouvre l'onglet qui détaille le chiffre.
struct SwitchSummaryTiles: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let summary: SwitchPageSummary
    let snapshots: [SNMPSwitchSnapshot]

    var body: some View {
        let tabs = SwitchTabState.shared
        // Six tuiles sur une seule ligne, même en petite fenêtre : les onglets restent en vue.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 96), spacing: 12, alignment: .top), count: 6),
                  alignment: .leading, spacing: 12) {
            InvTile(title: "Switchs", value: "\(summary.answered) / \(summary.switches)",
                    subtitle: "en ligne" + (summary.viaController > 0 ? " · \(summary.viaController) via FortiGate" : ""),
                    valueSize: 20, action: { tabs.jump(.switchs, in: state) })
            InvTile(title: "Ports actifs", value: "\(summary.activePorts) / \(summary.ports)", subtitle: "ports physiques",
                    valueSize: 20, action: { tabs.jump(.ports, filter: .active, in: state) })
            InvTile(title: "Ports en erreur", value: "\(summary.errorPorts.count)",
                    subtitle: errorSubtitle,
                    valueColor: summary.errorPorts.isEmpty ? Theme.text : Theme.critical,
                    tint: summary.errorPorts.isEmpty ? nil : .critical, valueSize: 20,
                    action: { openErrors() })
            InvTile(title: "PoE utilisé", value: summary.poeBudgetW > 0 ? "\(summary.poeUsedW)\u{00A0}W" : "—",
                    subtitle: poeSubtitle, valueSize: 20, action: { tabs.jump(.ports, filter: .poe, in: state) }) {
                if let fraction = summary.poeFraction {
                    ProgressBar(fraction: fraction, color: fraction > 0.8 ? Theme.warning : Theme.accent).padding(.top, 2)
                }
            }
            InvTile(title: "Appareils", value: "\(summary.devices)",
                    subtitle: "\(summary.vlans) VLAN · ports d’accès",
                    valueSize: 20, action: { tabs.jump(.appareils, in: state) })
            InvTile(title: "Voisins LLDP", value: "\(summary.neighbors)",
                    subtitle: summary.interSwitchLinks > 0 ? "\(summary.interSwitchLinks) lien\(summary.interSwitchLinks > 1 ? "s" : "") entre switchs" : "aucun lien entre switchs",
                    valueSize: 20, action: { tabs.jump(.voisins, in: state) })
        }
    }

    private var poeSubtitle: String {
        let ports = "\(summary.poePorts) port\(summary.poePorts > 1 ? "s" : "")"
        guard let fraction = summary.poeFraction else { return ports + " alimenté" + (summary.poePorts > 1 ? "s" : "") }
        return "\(Int((fraction * 100).rounded()))\u{00A0}% de \(SwitchText.grouped(UInt64(summary.poeBudgetW)))\u{00A0}W · \(ports)"
    }

    /// « SW-CORE-01 · Gi1/0/18 et 1 autre » : le premier port touché, puis le nombre des autres.
    private var errorSubtitle: String {
        guard let first = summary.errorPorts.first else { return "Aucune erreur récente" }
        let others = summary.errorPorts.count - 1
        return others == 0 ? first : "\(first) et \(others) autre\(others > 1 ? "s" : "")"
    }

    /// Ports en erreur : l'onglet Ports du premier switch touché, filtré sur les erreurs.
    private func openErrors() {
        let current = store.current
        let touched = snapshots.first { !store.recentErrors($0.id).alerts.isEmpty }
        let target = (current.map { !store.recentErrors($0.id).alerts.isEmpty } ?? false) ? current : touched
        let port = target.flatMap { store.recentErrors($0.id).alerts.first?.ifIndex }
        SwitchTabState.shared.jump(.ports, host: target?.id, port: port, filter: target == nil ? nil : .errors, in: state)
    }
}

/// Onglet d'un seul switch sans relevé à montrer.
struct SwitchTabPlaceholder: View {
    let tab: SwitchPageTab
    var hasSwitches: Bool

    var body: some View {
        Panel(padding: 0) {
            EmptyState(systemImage: tab.symbol,
                       title: hasSwitches ? "Aucun relevé à montrer" : "Aucun switch à interroger",
                       message: hasSwitches
                       ? "Interrogez les switchs dans l’onglet Switchs (communauté SNMP en lecture, ou FortiGate du site) pour remplir cet onglet."
                       : "Ajoutez un switch ou la FortiGate du site dans l’onglet Switchs.") {
                Button { SwitchTabState.shared.tab = .switchs } label: { Label("Onglet Switchs", systemImage: SwitchPageTab.switchs.symbol) }
                    .buttonStyle(.secondary)
            }
            .frame(height: 220)
        }
    }
}
