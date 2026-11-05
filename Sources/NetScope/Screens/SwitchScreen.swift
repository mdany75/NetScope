import NetScopeCore
import SwiftUI

/// Écran « Switchs et ports » (croquis docs/croquis/Switch.dc.html) : interrogation SNMP v2c des
/// switchs, façade, détail du port, table MAC et localisation d'un appareil. Note 83 : bandeau du
/// site et tuiles de résumé, puis des onglets natifs (Switchs, Ports, Trafic, Appareils, Voisins
/// et liens) au lieu d'une seule longue page.
struct SwitchScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Note 48 : sites montrés par le menu « Site ▾ » du bandeau (le site actif par défaut).
    @ObservedObject private var scopes = SiteScopeStore.shared
    /// Note 83 : onglet choisi (retenu d'une visite et d'un lancement à l'autre).
    @ObservedObject private var tabs = SwitchTabState.shared
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var addError: String?

    /// Note 28 : switchs du site actif (et, sans site, ceux des plages du dernier scan).
    private var visibleHosts: [String] { store.siteHosts }

    /// Switch affiché : le choisi s'il est visible, sinon le premier switch visible.
    private var shown: SNMPSwitchSnapshot? {
        let visible = visibleHosts
        if let current = store.current, visible.contains(current.host.description) { return current }
        return visible.lazy.compactMap { store.snapshots[$0] }.first
    }

    var body: some View {
        let visible = visibleHosts
        let shownSites = scopes.keys(for: .switchs)
        ScrollView {
            if shownSites != [sites.activeKey] {
                // Note 48 : un autre site, ou plusieurs, sans changer le site actif.
                VStack(alignment: .leading, spacing: 16) {
                    SwitchSiteBanner(visible: visible.count, total: store.allHosts.count)
                    SwitchSitesBrowser(keys: shownSites)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                let snapshots = visible.compactMap { store.snapshots[$0] }
                let summary = SwitchPageSummary.make(snapshots, hosts: visible.count,
                                                     recent: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, store.recentErrors($0.id)) }))
                VStack(alignment: .leading, spacing: 16) {
                    // Note 48 : le menu « Site ▾ » en haut de l'écran.
                    SwitchSiteBanner(visible: visible.count, total: store.allHosts.count)
                    // Note 83 : tuiles de résumé, puis les onglets.
                    if !snapshots.isEmpty {
                        SwitchSummaryTiles(store: store, summary: summary, snapshots: snapshots)
                    }
                    SwitchTabBar(tabs: tabs, store: store, snapshots: snapshots, shown: shown, summary: summary)
                    tabContent(visible: visible, snapshots: snapshots)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .modifier(SwitchTrafficLifecycle(snapshot: shown))
            }
        }
        // Switch choisi masqué (autre site, hors des plages) : le premier switch du site le remplace.
        .onChange(of: visible) { _, list in keepSelectionVisible(list) }
        .onAppear { keepSelectionVisible(visibleHosts) }
        // Note 83 : la recherche de la barre d'outils lit la table MAC, dans l'onglet Appareils.
        .onChange(of: state.searchTexts[.switchs] ?? "") { old, text in
            if old.isEmpty, !text.isEmpty, tabs.tab != .appareils { tabs.tab = .appareils }
        }
        // Communautés lues au Trousseau à l'ouverture de l'écran, hors du fil principal.
        .task {
            await store.loadVault()
            await FortiGateStore.shared.loadTokens()
        }
        .screenToolbar {
            Button { showAdd = true } label: { Label("Ajouter un switch", systemImage: "plus") }
                .buttonStyle(.secondary)
                .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
            Button { store.exportCSV(devices: state.devices) } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .disabled(store.orderedSnapshots.isEmpty)
        }
    }

    // MARK: Onglets (note 83)

    @ViewBuilder private func tabContent(visible: [String], snapshots: [SNMPSwitchSnapshot]) -> some View {
        switch tabs.tab {
        case .switchs:
            switchsTab(visible: visible)
        case .ports:
            if let snapshot = shown {
                SwitchPortsTab(store: store, snapshot: snapshot)
            } else {
                SwitchTabPlaceholder(tab: .ports, hasSwitches: !visible.isEmpty)
            }
        case .trafic:
            if let snapshot = shown {
                trafficTab(snapshot)
            } else {
                SwitchTabPlaceholder(tab: .trafic, hasSwitches: !visible.isEmpty)
            }
        case .appareils:
            if let snapshot = shown {
                SidePanelSplit(sideWidth: 300, collapse: .below, spacing: 16) {
                    SwitchMacTable(store: store, snapshot: snapshot, height: 560)
                } side: {
                    SwitchVLANPanel(store: store, snapshot: snapshot)
                }
            } else {
                SwitchTabPlaceholder(tab: .appareils, hasSwitches: !visible.isEmpty)
            }
        case .voisins:
            VStack(alignment: .leading, spacing: 16) {
                SwitchThisMacBanner(switches: store)
                if snapshots.isEmpty {
                    SwitchTabPlaceholder(tab: .voisins, hasSwitches: !visible.isEmpty)
                } else {
                    SidePanelSplit(sideWidth: 330, collapse: .below, spacing: 16) {
                        SwitchNeighborTable(store: store, snapshots: snapshots)
                    } side: {
                        SwitchTopology(store: store)
                    }
                }
            }
        }
    }

    /// Switchs : cartes, façade du switch choisi (un clic sur un port l'ouvre dans Ports),
    /// recherche d'un appareil, sources de la localisation et FortiGate du site.
    @ViewBuilder private func switchsTab(visible: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if visible.isEmpty {
                Panel(padding: 0) {
                    EmptyState(systemImage: "rectangle.connected.to.line.below",
                               title: "Aucun switch à interroger",
                               message: "Les switchs qui répondent en SNMP v2c sont ajoutés automatiquement à la fin de chaque scan (communauté des Réglages › Identifiants, puis «\u{00A0}public\u{00A0}»). Vous pouvez aussi ajouter un switch par son adresse IP.") {
                        Button { showAdd = true } label: { Label("Ajouter un switch", systemImage: "plus") }
                            .buttonStyle(.primary)
                    }
                    .frame(height: 220)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(max(visible.count, 1), 3)),
                          spacing: 12) {
                    ForEach(visible, id: \.self) { host in
                        SwitchCard(store: store, host: host)
                    }
                }
            }
            SwitchCandidates(store: store)
            if let snapshot = shown {
                SwitchFaceplatePanel(store: store, snapshot: snapshot) { index in
                    tabs.jump(.ports, host: snapshot.id, port: index, in: state)
                }
            } else if !visible.isEmpty {
                Panel {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                        Text("Saisissez la communauté SNMP puis cliquez sur «\u{00A0}Interroger les switchs\u{00A0}» pour dessiner la façade et lire la table MAC.")
                            .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            SwitchSourcesPanel(store: store)
            SwitchFortiGatePanel()
        }
    }

    /// Trafic : ports les plus chargés (en direct ou sur une période) et, à droite, le trafic et
    /// l'historique du port choisi. Un FortiSwitch n'a que l'historique (aucun relevé SNMP direct).
    private func trafficTab(_ snapshot: SNMPSwitchSnapshot) -> some View {
        let traffic = snapshot.isViaController ? nil : ResourceMonitors.snmp(snapshot.host.description)
        return SidePanelSplit(sideWidth: 330, collapse: .below, spacing: 16) {
            SwitchBusiestPorts(store: store, monitor: traffic, maxRows: 16, snapshot: snapshot)   // note 74
        } side: {
            VStack(spacing: 16) {
                if let iface = store.selectedInterface {
                    if let traffic {
                        SwitchPortTraffic(monitor: traffic, snapshot: snapshot, iface: iface)
                    }
                    SwitchPortHistoryPanel(store: store, snapshot: snapshot, iface: iface)   // note 74
                    Button { tabs.jump(.ports, host: snapshot.id, port: iface.index, in: state) } label: {
                        Label("Voir \(iface.name) dans l’onglet Ports", systemImage: SwitchPageTab.ports.symbol)
                    }
                    .buttonStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Panel { Text("Choisissez un port dans «\u{00A0}Ports les plus chargés\u{00A0}».").font(Theme.small).foregroundStyle(Theme.textSecondary) }
                }
            }
        }
    }

    private func keepSelectionVisible(_ list: [String]) {
        guard let first = list.first(where: { store.snapshots[$0] != nil }) else { return }
        if let selected = store.selectedHost, list.contains(selected) { return }
        store.select(host: first)
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ajouter un switch").font(Theme.bodySemibold)
            SwitchFieldLabel("Adresse IP de gestion")
            TextField("", text: $newHost, prompt: Text("ex. 10.182.122.2").foregroundStyle(Theme.textTertiary))
                .modifier(SwitchTextFieldStyle())
                .frame(width: 240)
                .onSubmit(add)
            if let addError {
                Text(addError).font(Theme.small).foregroundStyle(Theme.critical)
            }
            Text("SNMP v2c, port UDP 161. SNMP v3\u{00A0}: bientôt.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Annuler") { showAdd = false }.buttonStyle(.secondary)
                Button("Ajouter", action: add).buttonStyle(.primary)
            }
        }
        .padding(16)
    }

    private func add() {
        if let error = store.addHost(newHost) {
            addError = error
        } else {
            addError = nil
            newHost = ""
            showAdd = false
        }
    }
}

/// Relevés de trafic (note 21) du switch SNMP affiché, partagés avec sa fiche Appareil : ils
/// tournent tant que l'écran est visible, quel que soit l'onglet (l'historique des ports s'en nourrit).
private struct SwitchTrafficLifecycle: ViewModifier {
    let snapshot: SNMPSwitchSnapshot?

    /// Adresse du switch SNMP suivi (nil : FortiSwitch lu par la FortiGate, ou aucun switch).
    private var host: String? {
        guard let snapshot, !snapshot.isViaController else { return nil }
        return snapshot.host.description
    }

    func body(content: Content) -> some View {
        // Une tâche par switch : changer de switch arrête les relevés du précédent (la vue, elle,
        // garde son identité : les tableaux et les onglets ne sont pas recréés).
        content.task(id: host) {
            guard let host else { return }
            let monitor = ResourceMonitors.snmp(host)
            monitor.retain(autoStart: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            monitor.release()
        }
    }
}
