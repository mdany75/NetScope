import NetScopeCore
import SwiftUI

/// Bandeau « Site ▾ · N switchs » de Switchs et ports (notes 28 et 48) : seuls les switchs du site
/// actif sont affichés (FortiSwitch de ses FortiGate, switchs SNMP associés, et ceux sans site qui
/// sont dans les plages du dernier scan) ; « Afficher tous les switchs » lève le filtre. Le menu
/// « Site ▾ » montre un autre site, ou plusieurs, sans changer le site actif (SwitchSitesBrowser).
struct SwitchSiteBanner: View {
    @ObservedObject private var sites = SiteModel.shared
    @EnvironmentObject private var state: AppState
    let visible: Int
    let total: Int

    @ObservedObject private var scopes = SiteScopeStore.shared

    var body: some View {
        let hidden = total - visible
        let browsing = scopes.keys(for: .switchs) != [sites.activeKey]
        HStack(spacing: 10) {
            // Note 48 : menu « Site ▾ », ouvert par défaut sur le site actif ; un autre choix ne
            // change pas le site actif du Scanner.
            SiteScopeMenu(screen: .switchs)
            if browsing {
                Text("Vue des sites choisis, en lecture seule\u{00A0}: le site actif «\u{00A0}\(sites.activeName)\u{00A0}» ne change pas.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Site actif seulement") { scopes.set(.active, for: .switchs) }
                    .buttonStyle(.secondary)
                    .fixedSize()
            } else {
                Text("\(visible) switch\(visible > 1 ? "s" : "")").font(Theme.small).fontWeight(.semibold)
                    .foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                Text(detail(hidden: hidden))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if hidden > 0 || sites.showAllSwitches {
                    Button(sites.showAllSwitches ? "Switchs du site seulement" : "Afficher tous les switchs") {
                        sites.showAllSwitches.toggle()
                    }
                    .buttonStyle(.secondary)
                    .fixedSize()
                }
            }
            Button("Gérer…") {
                RegNavigation.shared.section = .switchs
                state.open(.reglages)
            }
            .buttonStyle(.ghost)
            .fixedSize()
            .help("Associer un switch SNMP à un site (Réglages › Switchs)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func detail(hidden: Int) -> String {
        if sites.showAllSwitches { return "Tous les switchs connus sont affichés, quel que soit leur site." }
        guard hidden > 0 else {
            return sites.activeSite == nil ? "Aucun site actif\u{00A0}: switchs des plages scannées." : "FortiSwitch de ses FortiGate et switchs SNMP associés."
        }
        return "\(hidden) masqué\(hidden > 1 ? "s" : "") (autre site, ou sans site hors des plages scannées)"
    }
}
