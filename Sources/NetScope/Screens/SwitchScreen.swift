import NetScopeCore
import SwiftUI

/// Écran « Switchs et ports » (croquis docs/croquis/Switch.dc.html) : interrogation SNMP v2c des
/// switchs, façade, détail du port, table MAC et localisation d'un appareil.
struct SwitchScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Note 48 : sites montrés par le menu « Site ▾ » du bandeau (le site actif par défaut).
    @ObservedObject private var scopes = SiteScopeStore.shared
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
            VStack(alignment: .leading, spacing: 16) {
                // Note 48 : le menu « Site ▾ » en haut de l'écran.
                SwitchSiteBanner(visible: visible.count, total: store.allHosts.count)
                SwitchSourcesPanel(store: store)
                SwitchFortiGatePanel()
                SwitchThisMacBanner(switches: store)

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
                    SwitchCandidates(store: store)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(max(visible.count, 1), 3)),
                              spacing: 12) {
                        ForEach(visible, id: \.self) { host in
                            SwitchCard(store: store, host: host)
                        }
                    }
                    SwitchCandidates(store: store)
                }

                if let snapshot = shown, snapshot.isViaController {
                    // FortiSwitch géré (note 24) : tout vient de la FortiGate, aucun relevé SNMP du
                    // trafic (son adresse FortiLink n'est pas joignable depuis ce Mac).
                    SidePanelSplit(sideWidth: 330, collapse: .below, spacing: 16) {
                        VStack(spacing: 16) {
                            SwitchFaceplatePanel(store: store, snapshot: snapshot)
                            SwitchFortiPortTable(store: store, snapshot: snapshot)
                                .id(snapshot.id)
                            SwitchBusiestPorts(store: store, snapshot: snapshot)   // note 74
                            SwitchMacTable(store: store, snapshot: snapshot)
                        }
                    } side: {
                        VStack(spacing: 16) {
                            if let iface = store.selectedInterface {
                                SwitchPortDetail(store: store, snapshot: snapshot, iface: iface)
                                SwitchPortHistoryPanel(store: store, snapshot: snapshot, iface: iface)   // note 74
                            } else {
                                Panel { Text("Choisissez un port sur la façade.").font(Theme.small).foregroundStyle(Theme.textSecondary) }
                            }
                            SwitchTopology(store: store)
                        }
                    }
                } else if let snapshot = shown {
                    // Relevés de trafic (note 21) du switch affiché, partagés avec sa fiche Appareil.
                    let traffic = ResourceMonitors.snmp(snapshot.host.description)
                    // Colonne principale (façade, ports chargés, table MAC) et colonne de détail (port, trafic, topologie).
                    SidePanelSplit(sideWidth: 330, collapse: .below, spacing: 16) {
                        VStack(spacing: 16) {
                            SwitchFaceplatePanel(store: store, snapshot: snapshot)
                            SwitchBusiestPorts(store: store, monitor: traffic, snapshot: snapshot)
                            SwitchMacTable(store: store, snapshot: snapshot)
                        }
                    } side: {
                        VStack(spacing: 16) {
                            if let iface = store.selectedInterface {
                                SwitchPortDetail(store: store, snapshot: snapshot, iface: iface)
                                SwitchPortTraffic(monitor: traffic, snapshot: snapshot, iface: iface)
                                SwitchPortHistoryPanel(store: store, snapshot: snapshot, iface: iface)   // note 74
                            } else {
                                Panel { Text("Choisissez un port sur la façade.").font(Theme.small).foregroundStyle(Theme.textSecondary) }
                            }
                            SwitchTopology(store: store)
                        }
                    }
                    .modifier(SwitchResourceLifecycle(monitor: traffic))
                } else if !visible.isEmpty {
                    Panel {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                            Text("Saisissez la communauté SNMP puis cliquez sur «\u{00A0}Interroger les switchs\u{00A0}» pour dessiner la façade et lire la table MAC.")
                                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // Switch choisi masqué (autre site, hors des plages) : le premier switch du site le remplace.
        .onChange(of: visible) { _, list in keepSelectionVisible(list) }
        .onAppear { keepSelectionVisible(visibleHosts) }
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
