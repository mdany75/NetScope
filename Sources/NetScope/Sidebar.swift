import AppKit
import NetScopeCore
import SwiftUI

/// Barre latérale translucide de macOS (liste « sidebar » du système), fidèle aux croquis pour
/// l'ordre et les libellés : logo, groupes d'écrans avec leurs compteurs, plages enregistrées,
/// l'interface active, la version et la mise à jour disponible ; Réglages reste épinglé en bas.
/// La liste défile quand la fenêtre est basse.
struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    /// Hauteur de liste sous laquelle « Plages enregistrées » serait coupée sous son titre (petite
    /// fenêtre) : les quatre groupes d'écrans, puis le titre et au moins une plage.
    private static let rangesMinListHeight: CGFloat = 548

    var body: some View {
        // Hauteur de la liste (entre le logo et Réglages), lue dans la même passe de mise en page :
        // les plages enregistrées sont masquées quand elles n'ont pas la place.
        GeometryReader { geometry in
            list(height: geometry.size.height)
        }
        .safeAreaInset(edge: .top, spacing: 0) { logo }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func list(height listHeight: CGFloat) -> some View {
        List(selection: selection) {
            ForEach(Screen.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(group.screens) { screen in
                        row(screen)
                    }
                }
            }
            if !state.ranges.isEmpty && listHeight >= Self.rangesMinListHeight {
                Section("Plages enregistrées") {
                    ForEach(state.ranges.prefix(4)) { range in
                        HStack {
                            Text(range.text).font(Theme.mono(11)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(range.label).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .selectionDisabled()
                    }
                }
            }
            // Interface active, version et mise à jour : en fin de liste, pour que la barre latérale
            // défile au lieu d'imposer sa hauteur quand la fenêtre est basse.
            Section {
                interfaceCard
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
    }

    /// Sélection de la liste : l'écran courant (Réglages est en bas, hors de la liste).
    private var selection: Binding<Screen?> {
        Binding(get: { state.screen == .reglages ? nil : state.screen },
                set: { if let screen = $0 { state.open(screen) } })
    }

    /// Ligne d'un écran. Les alertes de Surveillance gardent leur pastille rouge ; les autres
    /// compteurs prennent l'allure native de macOS.
    @ViewBuilder private func row(_ screen: Screen) -> some View {
        let count = badgeCount(for: screen)
        if screen == .surveillance && count > 0 {
            HStack {
                Label(screen.title, systemImage: screen.symbol)
                Spacer(minLength: 4)
                CountBadge(count: count, color: Theme.criticalBadge)
            }
            .tag(screen)
        } else {
            Label(screen.title, systemImage: screen.symbol)
                .badge(count)
                .tag(screen)
        }
    }

    private func badgeCount(for screen: Screen) -> Int {
        state.sidebarBadges[screen] ?? 0
    }

    // MARK: Parties

    private var logo: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().stroke(Theme.accent, lineWidth: 1.6).frame(width: 20, height: 20)
                Circle().stroke(Theme.accent, lineWidth: 1.6).frame(width: 11, height: 11)
                Circle().fill(Theme.accent).frame(width: 3, height: 3)
                Path { path in
                    path.move(to: CGPoint(x: 12, y: 12))
                    path.addLine(to: CGPoint(x: 18, y: 6))
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("NetScope").font(.system(size: 13, weight: .bold))
                Text("Boîte à outils réseau").font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// Réglages épinglé en bas : une seconde liste « sidebar » d'une ligne, pour que sa sélection ait
    /// exactement l'allure (teinte, forme, fenêtre inactive) de celle des autres écrans.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 16)
            List(selection: settingsSelection) {
                Label(Screen.reglages.title, systemImage: Screen.reglages.symbol)
                    .tag(Screen.reglages)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: 44)
            // Barres de défilement classiques (souris) : la liste du haut perd la largeur de la sienne ;
            // on retire la même largeur ici pour que les deux sélections aient la même longueur.
            .padding(.trailing, Self.legacyScrollerWidth)
        }
    }

    private static var legacyScrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private var settingsSelection: Binding<Screen?> {
        Binding(get: { state.screen == .reglages ? .reglages : nil },
                set: { if $0 == .reglages { state.open(.reglages) } })
    }

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INTERFACE ACTIVE")
                .font(Theme.captionSemibold).kerning(0.44)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(state.activeInterface == nil ? Theme.neutralDot : Theme.successDot)
                    .frame(width: 8, height: 8)
                // Lignes logiques : « en0 · 10.182.122.135 », puis le type (« Wi-Fi »).
                if let interface = state.activeInterface {
                    VStack(alignment: .leading, spacing: 1) {
                        // Barre latérale étroite : l'IP passe sous le nom plutôt que d'être coupée.
                        ViewThatFits(in: .horizontal) {
                            Text("\(interface.name) · \(interface.address.description)").lineLimit(1).fixedSize()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(interface.name).lineLimit(1)
                                Text(interface.address.description).lineLimit(1)
                            }
                        }
                        .font(Theme.mono(11))
                        Text(interface.kind.label)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Aucune interface active").font(Theme.mono(11)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Une ligne pour la passerelle, une pour le DNS (jamais coupées au milieu).
            ForEach(gatewayLines, id: \.self) { line in
                Text(line)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text("Version \(AppInfo.version)").font(Theme.caption).foregroundStyle(.secondary)
            if let update = state.updateAvailable {
                Button {
                    state.open(.reglages)
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        // Barre latérale étroite : le numéro passe à la ligne plutôt que d'être coupé.
                        ViewThatFits(in: .horizontal) {
                            (Text("Mise à jour disponible · ") + Text(update).font(Theme.mono(11)))
                                .lineLimit(1).fixedSize()
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Mise à jour disponible").lineLimit(1).fixedSize()
                                Text(update).font(Theme.mono(11)).lineLimit(1)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Mise à jour disponible\u{00A0}: NetScope \(update). Ouvrir les réglages Mises à jour")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.hover))
    }

    private var gatewayLines: [String] {
        var lines: [String] = []
        if let gateway = state.activeInterface?.gateway { lines.append("Passerelle \(gateway)") }
        if let dns = state.dnsServers.first { lines.append("DNS \(dns)") }
        return lines
    }
}
