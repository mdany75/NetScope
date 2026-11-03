import NetScopeCore
import SwiftUI

/// Barre latérale bleu nuit de 220 pt, fidèle aux croquis : logo, groupes d'écrans, plages
/// enregistrées, Réglages, puis l'interface active, la version et la mise à jour disponible.
struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            // Le milieu défile quand la fenêtre est basse ; logo, Réglages et interface restent visibles.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(Screen.Group.allCases.enumerated()), id: \.element) { index, group in
                            groupHeading(group.title, first: index == 0)
                            ForEach(group.screens) { screen in
                                SidebarItem(screen: screen, badge: badge(for: screen))
                            }
                        }
                    }
                    savedRanges
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 10) {
                divider
                SidebarItem(screen: .reglages, badge: nil)
                interfaceCard
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    // MARK: Parties

    private var logo: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.sidebarText, lineWidth: 1.6).frame(width: 22, height: 22)
                Circle().stroke(Theme.sidebarText, lineWidth: 1.6).frame(width: 12, height: 12)
                Circle().fill(Theme.sidebarText).frame(width: 3, height: 3)
                Path { path in
                    path.move(to: CGPoint(x: 13, y: 13))
                    path.addLine(to: CGPoint(x: 19.5, y: 6.5))
                }
                .stroke(Theme.sidebarText, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("NetScope").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text("Boîte à outils réseau").font(Theme.caption).foregroundStyle(Theme.sidebarHeading)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func groupHeading(_ title: String, first: Bool) -> some View {
        Text(title.uppercased())
            .font(Theme.caption)
            .kerning(0.44)
            .foregroundStyle(Theme.sidebarHeading)
            .padding(.horizontal, 10)
            .padding(.top, first ? 0 : 8)
            .padding(.bottom, 3)
    }

    private var divider: some View {
        Rectangle().fill(Theme.sidebarActive).frame(height: 1)
    }

    private var savedRanges: some View {
        VStack(alignment: .leading, spacing: 6) {
            divider.padding(.bottom, 6)
            Text("PLAGES ENREGISTRÉES")
                .font(Theme.caption).kerning(0.44)
                .foregroundStyle(Theme.sidebarHeading)
                .padding(.horizontal, 6)
            ForEach(state.ranges.prefix(4)) { range in
                HStack {
                    Text(range.text).font(Theme.mono(12)).foregroundStyle(Theme.sidebarText).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(range.label).font(Theme.mono(12)).foregroundStyle(Theme.sidebarHeading).lineLimit(1)
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTERFACE ACTIVE")
                .font(Theme.caption).kerning(0.44)
                .foregroundStyle(Theme.sidebarHeading)
            HStack(spacing: 8) {
                Circle()
                    .fill(state.activeInterface == nil ? Color(hex: 0x64748B) : Theme.successDot)
                    .frame(width: 8, height: 8)
                Text(state.activeInterface?.summary ?? "Aucune interface active")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.sidebarText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let line = gatewayLine {
                Text(line)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.sidebarHeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Version \(AppInfo.version)").font(Theme.caption).foregroundStyle(Theme.sidebarHeading)
            if let update = state.updateAvailable {
                Button {
                    state.open(.reglages)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        (Text("Mise à jour disponible · ") + Text(update).font(Theme.mono(11)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.sidebarText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.sidebarActive))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Mise à jour disponible : NetScope \(update). Ouvrir les réglages Mises à jour")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.sidebarActive))
    }

    private var gatewayLine: String? {
        var parts: [String] = []
        if let gateway = state.activeInterface?.gateway { parts.append("Passerelle \(gateway)") }
        if let dns = state.dnsServers.first { parts.append("DNS \(dns)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func badge(for screen: Screen) -> (Int, Color)? {
        guard let count = state.sidebarBadges[screen], count > 0 else { return nil }
        return (count, screen == .surveillance ? Theme.criticalBadge : Theme.accent)
    }
}

/// Un élément de la barre latérale : icône, libellé, compteur éventuel.
private struct SidebarItem: View {
    @EnvironmentObject private var state: AppState
    let screen: Screen
    let badge: (Int, Color)?
    @State private var hovering = false

    var body: some View {
        let active = state.screen == screen
        Button {
            state.open(screen)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16, height: 16)
                Text(screen.title).font(Theme.bodyMedium)
                Spacer(minLength: 4)
                if let badge {
                    CountBadge(count: badge.0, color: badge.1)
                }
            }
            .foregroundStyle(active || hovering ? Color.white : Theme.sidebarText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(active || hovering ? Theme.sidebarActive : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
