import NetScopeCore
import SwiftUI

/// Bandeau « Site : <nom> · N switchs » de Switchs et ports (note 28) : seuls les switchs du site
/// actif sont affichés (FortiSwitch de ses FortiGate, switchs SNMP associés, et ceux sans site qui
/// sont dans les plages du dernier scan) ; « Afficher tous les switchs » lève le filtre.
struct SwitchSiteBanner: View {
    @ObservedObject private var sites = SiteModel.shared
    @EnvironmentObject private var state: AppState
    let visible: Int
    let total: Int

    var body: some View {
        let hidden = total - visible
        if sites.activeSite != nil || hidden > 0 || sites.showAllSwitches {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                (Text("Site\u{00A0}: ").foregroundColor(Theme.textSecondary)
                    + Text(sites.activeName).fontWeight(.semibold).foregroundColor(Theme.text)
                    + Text(" · \(visible) switch\(visible > 1 ? "s" : "")").foregroundColor(Theme.text))
                    .font(Theme.small)
                    .lineLimit(1)
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
    }

    private func detail(hidden: Int) -> String {
        if sites.showAllSwitches { return "Tous les switchs connus sont affichés, quel que soit leur site." }
        guard hidden > 0 else {
            return sites.activeSite == nil ? "Aucun site actif\u{00A0}: switchs des plages scannées." : "FortiSwitch de ses FortiGate et switchs SNMP associés."
        }
        return "\(hidden) masqué\(hidden > 1 ? "s" : "") (autre site, ou sans site hors des plages scannées)"
    }
}
