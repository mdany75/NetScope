import NetScopeCore
import SwiftUI

/// Section « Sites » de la barre latérale (note 28) : le site actif en tête, marqué, avec ses
/// plages en dessous ; puis les autres sites, un clic pour changer de site. Au-delà de quatre autres
/// sites, la liste se replie (« N autres sites »).
struct SidebarSites: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @State private var expanded = false

    private static let shownWhenFolded = 4
    private static let rangesShown = 3

    /// Plages du Scanner (au plus trois), puis « +N plages ».
    @ViewBuilder private var rangeRows: some View {
        ForEach(state.ranges.prefix(Self.rangesShown)) { range in
            rangeRow(range)
        }
        if state.ranges.count > Self.rangesShown {
            let extra = state.ranges.count - Self.rangesShown
            Text("+\(extra) plage\(extra > 1 ? "s" : "")")
                .font(Theme.caption).foregroundStyle(.secondary)
                .padding(.leading, 22)
                .selectionDisabled()
        }
    }

    var body: some View {
        Section("Sites") {
            activeRow(sites.activeSite?.displayName ?? "Aucun site")
            rangeRows
            let others = sites.sortedSites.filter { $0.id != sites.activeID }
            let visible = expanded ? others : Array(others.prefix(Self.shownWhenFolded))
            ForEach(visible) { site in
                Button {
                    sites.activate(site.id, state: state)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                        Text(site.displayName).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Passer au site «\u{00A0}\(site.displayName)\u{00A0}» (\(site.rangesLabel))")
                .selectionDisabled()
                // Note 34 : voir ce site (Inventaire, Carte, Analyse, Rapports) sans en changer.
                .contextMenu { OpenInMenu(object: .site(key: SiteFiles.key(for: site.id), name: site.displayName)) }
            }
            if others.count > Self.shownWhenFolded {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                            .frame(width: 14)
                        Text(expanded ? "Replier" : "\(others.count - Self.shownWhenFolded) autre\(others.count - Self.shownWhenFolded > 1 ? "s" : "") site\(others.count - Self.shownWhenFolded > 1 ? "s" : "")")
                        Spacer(minLength: 0)
                    }
                    .font(Theme.small)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
        }
    }

    private func activeRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 14)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if sites.hasUnsavedRanges(state) {
                Circle().fill(Theme.warningDot).frame(width: 6, height: 6)
                    .help("Plages modifiées, non enregistrées dans le site")
            }
        }
        .help(sites.activeSite == nil ? "Plages libres (aucun site actif)"
              : "Site actif\u{00A0}: «\u{00A0}\(name)\u{00A0}» · double-clic\u{00A0}: son inventaire")
        .selectionDisabled()
        // Note 34 : double-clic → l'Inventaire de ce site ; clic droit → « Ouvrir dans › ».
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.perform(.site(key: sites.activeKey, name: name)) }
        .contextMenu { OpenInMenu(object: .site(key: sites.activeKey, name: name)) }
    }

    private func rangeRow(_ range: ScanRangeConfig) -> some View {
        HStack {
            Text(range.text).font(Theme.mono(11)).lineLimit(1)
            Spacer(minLength: 6)
            Text(range.label).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.leading, 22)
        .opacity(range.isEnabled ? 1 : 0.55)
        .selectionDisabled()
        // Note 34 : double-clic → le Scanner filtré sur cette plage ; clic droit → « Ouvrir dans › »
        // et le VLAN de la plage.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.perform(.range(text: range.text, label: range.label)) }
        .contextMenu {
            OpenInMenu(object: .range(text: range.text, label: range.label))
            if let vlan = range.vlan {
                Button("Appareils du VLAN \(vlan) dans le Scanner") { state.perform(.vlan(vlan)) }
            }
        }
        .help("\(range.text) · \(range.label) · double-clic\u{00A0}: appareils de cette plage dans le Scanner")
    }
}
