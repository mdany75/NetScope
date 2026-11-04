import NetScopeCore
import SwiftUI

// Note 28 : chaque switch SNMP (non Fortinet) peut être associé à un site, plusieurs, ou aucun.
// « Switchs et ports » n'affiche que les switchs du site actif ; un switch sans site n'y apparaît
// que s'il est dans les plages du dernier scan. Les FortiSwitch suivent leur FortiGate.

struct RegSwitchSitesTarget: Identifiable {
    let host: String
    var id: String { host }
}

/// Cellule « Site » du tableau des switchs : menu à cases (aucun, un ou plusieurs sites).
struct RegSwitchSiteMenu: View {
    @ObservedObject private var sites = SiteModel.shared
    let host: String
    let names: [String]

    var body: some View {
        Menu {
            let chosen = Set(sites.sites(forSwitch: host).map(\.id))
            Button {
                sites.setSwitch(host, sites: [])
            } label: {
                if chosen.isEmpty { Label("Aucun site", systemImage: "checkmark") } else { Text("Aucun site") }
            }
            Divider()
            ForEach(sites.sortedSites) { site in
                Toggle(site.displayName, isOn: Binding(get: { chosen.contains(site.id) }, set: { on in
                    var ids = Set(sites.sites(forSwitch: host).map(\.id))
                    if on { ids.insert(site.id) } else { ids.remove(site.id) }
                    sites.setSwitch(host, sites: ids)
                }))
            }
        } label: {
            Text(names.isEmpty ? "Aucun" : names.joined(separator: ", "))
                .font(Theme.small)
                .foregroundStyle(names.isEmpty ? Theme.textTertiary : Theme.text)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help(names.isEmpty ? "Sans site\u{00A0}: affiché dans «\u{00A0}Switchs et ports\u{00A0}» seulement s’il est dans les plages scannées"
                            : "Affiché quand l’un de ces sites est actif\u{00A0}: \(names.joined(separator: ", "))")
    }
}

/// Feuille « Choisir les sites du switch » (clic droit dans le tableau des switchs).
struct RegSwitchSitesSheet: View {
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var store = SwitchStore.shared
    @Environment(\.dismiss) private var dismiss
    let host: String
    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sites du switch \(host)").font(Theme.panelTitle)
            if let name = store.snapshots[host]?.displayName {
                Text(name).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            Text("Le switch est affiché dans «\u{00A0}Switchs et ports\u{00A0}» quand l’un des sites cochés est actif. Sans site, il n’y apparaît que s’il est dans les plages du dernier scan.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sites.sortedSites) { site in
                        Toggle(isOn: Binding(get: { chosen.contains(site.id) },
                                             set: { if $0 { chosen.insert(site.id) } else { chosen.remove(site.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.displayName).font(Theme.small)
                                Text(site.rangesLabel).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Aucun site") { chosen = [] }.buttonStyle(.secondary)
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    sites.setSwitch(host, sites: chosen)
                    dismiss()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { chosen = Set(sites.sites(forSwitch: host).map(\.id)) }
    }
}
