import NetScopeCore
import SwiftUI

/// Écran « Switchs et ports » (croquis docs/croquis/Switch.dc.html) : interrogation SNMP v2c des
/// switchs, façade, détail du port, table MAC et localisation d'un appareil.
struct SwitchScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var addError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SwitchSourcesPanel(store: store)
                SwitchThisMacBanner(switches: store)

                if store.hosts.isEmpty {
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(max(store.hosts.count, 1), 3)),
                              spacing: 12) {
                        ForEach(store.hosts, id: \.self) { host in
                            SwitchCard(store: store, host: host)
                        }
                    }
                    SwitchCandidates(store: store)
                }

                if let snapshot = store.current {
                    // Colonne principale (façade, table MAC) et colonne de détail (port, topologie).
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            SwitchFaceplatePanel(store: store, snapshot: snapshot)
                            SwitchMacTable(store: store, snapshot: snapshot)
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 16) {
                            if let iface = store.selectedInterface {
                                SwitchPortDetail(store: store, snapshot: snapshot, iface: iface)
                            } else {
                                Panel { Text("Choisissez un port sur la façade.").font(Theme.small).foregroundStyle(Theme.textSecondary) }
                            }
                            SwitchTopology(store: store)
                        }
                        .frame(width: 330)
                    }
                } else if !store.hosts.isEmpty {
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
        // Communautés lues au Trousseau à l'ouverture de l'écran, hors du fil principal.
        .task { await store.loadVault() }
        .screenToolbar {
            Button { showAdd = true } label: { Label("Ajouter un switch", systemImage: "plus") }
                .buttonStyle(.secondary)
                .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
            Button { store.exportCSV(devices: state.devices) } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .disabled(store.orderedSnapshots.isEmpty)
        }
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
