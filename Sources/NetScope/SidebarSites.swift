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

    var body: some View {
        Section("Sites") {
            if let active = sites.activeSite {
                activeRow(active.displayName)
                ForEach(state.ranges.prefix(Self.rangesShown)) { range in
                    rangeRow(range)
                }
                if state.ranges.count > Self.rangesShown {
                    Text("+\(state.ranges.count - Self.rangesShown) plage\(state.ranges.count - Self.rangesShown > 1 ? "s" : "")")
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .padding(.leading, 22)
                        .selectionDisabled()
                }
            } else {
                activeRow("Aucun site")
                ForEach(state.ranges.prefix(Self.rangesShown)) { range in
                    rangeRow(range)
                }
            }
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
        .help(sites.activeSite == nil ? "Plages libres (aucun site actif)" : "Site actif\u{00A0}: «\u{00A0}\(name)\u{00A0}»")
        .selectionDisabled()
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
    }
}
