import NetScopeCore
import SwiftUI

// Note 29 : indication de la relecture automatique dans Switchs et ports et dans Wi-Fi
// (« Relu il y a 2 min · prochaine dans 3 min »), avec le menu de l'intervalle du site actif.

/// Indication et menu « Relecture automatique » du site actif. Le texte suit l'horloge (toutes
/// les 15 s), sans rien relire lui-même.
struct AutoRefreshBadge: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = AutoRefreshStore.shared
    @ObservedObject private var sites = SiteModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Menu {
                Picker("Relecture automatique de «\u{00A0}\(sites.activeName)\u{00A0}»",
                       selection: Binding(get: { store.activeInterval }, set: { store.setActiveInterval($0) })) {
                    ForEach(AutoRefreshInterval.allCases) { interval in
                        Text(interval.menuLabel).tag(interval)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Réglages de la relecture automatique…") {
                    RegNavigation.shared.section = .switchs
                    state.open(.reglages)
                }
            } label: {
                Label(store.statusText(now: context.date), systemImage: icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .font(Theme.small)
            .foregroundStyle(store.isTroubled ? Theme.warning : Theme.textSecondary)
            .tint(store.isTroubled ? Theme.warning : Theme.textSecondary)
            .fixedSize()
            .help(store.helpText)
            .accessibilityLabel("Relecture automatique\u{00A0}: " + store.statusText(now: context.date))
        }
    }

    private var icon: String {
        if store.isTroubled { return "exclamationmark.arrow.triangle.2.circlepath" }
        return store.activeInterval.isOn ? "clock.arrow.2.circlepath" : "pause.circle"
    }
}
