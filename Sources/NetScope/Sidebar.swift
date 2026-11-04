import AppKit
import NetScopeCore
import SwiftUI

/// Barre latérale translucide de macOS (liste « sidebar » du système), fidèle aux croquis pour
/// l'ordre et les libellés : logo, groupes d'écrans avec leurs compteurs, plages enregistrées,
/// l'interface active, la version et la mise à jour disponible. La carte de l'interface et
/// Réglages restent épinglés en bas, toujours entiers ; la liste du haut défile quand la fenêtre
/// est basse. En petite fenêtre, la carte laisse place à la seule mise à jour disponible.
struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    /// Hauteur de liste sous laquelle « Plages enregistrées » serait coupée sous son titre (petite
    /// fenêtre) : les quatre groupes d'écrans, puis le titre et au moins une plage.
    private static let rangesMinListHeight: CGFloat = 576

    /// Hauteur de la barre latérale (sous la barre de titre) à partir de laquelle la carte
    /// « Interface active » s'affiche entière au-dessus de Réglages : logo, quatre groupes d'écrans,
    /// carte et pied. En dessous (fenêtre 1000 × 650), seule la pastille de mise à jour reste.
    private static let cardMinSidebarHeight: CGFloat = 700

    var body: some View {
        GeometryReader { sidebar in
            let showsCard = sidebar.size.height >= Self.cardMinSidebarHeight
            // Hauteur de la liste (entre le logo et le pied), lue dans la même passe de mise en page :
            // les plages enregistrées sont masquées quand elles n'ont pas la place.
            GeometryReader { geometry in
                list(height: geometry.size.height)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Note 49 : le site actif, toujours visible juste sous le logo.
                VStack(spacing: 0) {
                    logo
                    SidebarSitePicker()
                        .padding(.horizontal, 10)
                        .padding(.trailing, Self.legacyScrollerWidth)
                        .padding(.bottom, 6)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer(showsCard: showsCard) }
        }
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
            if listHeight >= Self.rangesMinListHeight {
                // Note 28 : les sites remplacent « Plages enregistrées » ; le site actif est marqué,
                // ses plages en dessous ; un clic change de site.
                SidebarSites()
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

    /// Pied épinglé en bas : la carte de l'interface active (ou, en petite fenêtre, la seule mise à
    /// jour disponible), puis Réglages, une seconde liste « sidebar » d'une ligne pour que sa
    /// sélection ait exactement l'allure (teinte, forme, fenêtre inactive) de celle des autres écrans.
    private func footer(showsCard: Bool) -> some View {
        VStack(spacing: 0) {
            if showsCard {
                interfaceCard
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .padding(.trailing, Self.legacyScrollerWidth)
            } else if let update = state.updateAvailable {
                updateButton(update)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .padding(.trailing, Self.legacyScrollerWidth)
            }
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

    /// Carte compacte : titre et version, interface, passerelle et DNS (sur une ligne quand elle
    /// tient), puis la mise à jour disponible.
    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("INTERFACE ACTIVE")
                    .font(Theme.captionSemibold).kerning(0.44)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("v\(AppInfo.version)").font(Theme.caption).lineLimit(1).fixedSize()
                    .help("Version \(AppInfo.version)")
            }
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(state.activeInterface == nil ? Theme.neutralDot : Theme.successDot)
                    .frame(width: 8, height: 8)
                if let interface = state.activeInterface {
                    // « en0 · 10.182.122.135 · Wi-Fi » quand la ligne tient ; sinon le type passe à la
                    // ligne, puis l'IP sous le nom plutôt que d'être coupée.
                    ViewThatFits(in: .horizontal) {
                        (Text("\(interface.name) · \(interface.address.description)").font(Theme.mono(11))
                            + Text(" · \(interface.kind.label)").font(Theme.caption).foregroundColor(.secondary))
                            .lineLimit(1).fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(interface.name) · \(interface.address.description)").font(Theme.mono(11))
                                .lineLimit(1).fixedSize()
                            Text(interface.kind.label).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(interface.name).font(Theme.mono(11)).lineLimit(1)
                            Text(interface.address.description).font(Theme.mono(11)).lineLimit(1)
                            Text(interface.kind.label).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text("Aucune interface active").font(Theme.mono(11)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Passerelle et DNS sur une ligne quand elle tient, sinon une ligne chacun (jamais coupés).
            if !gatewayLines.isEmpty {
                ViewThatFits(in: .horizontal) {
                    Text(gatewayLines.joined(separator: " · ")).lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(gatewayLines, id: \.self) { line in
                            Text(line).lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            }
            if let update = state.updateAvailable {
                updateButton(update)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.hover))
    }

    /// Pastille « Mise à jour disponible · 1.1.0 » (ouvre les réglages Mises à jour), toujours sur une
    /// ligne : libellé raccourci quand la barre latérale est étroite.
    private func updateButton(_ update: String) -> some View {
        Button {
            state.open(.reglages)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                ViewThatFits(in: .horizontal) {
                    (Text("Mise à jour disponible · ") + Text(update).font(Theme.mono(11)))
                        .lineLimit(1).fixedSize()
                    (Text("Mise à jour · ") + Text(update).font(Theme.mono(11)))
                        .lineLimit(1).fixedSize()
                    Text(update).font(Theme.mono(11)).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mise à jour disponible\u{00A0}: NetScope \(update). Ouvrir les réglages Mises à jour")
    }

    private var gatewayLines: [String] {
        var lines: [String] = []
        if let gateway = state.activeInterface?.gateway { lines.append("Passerelle \(gateway)") }
        if let dns = state.dnsServers.first { lines.append("DNS \(dns)") }
        return lines
    }
}
