import NetScopeCore
import SwiftUI

// Note 32 : recherche dans la Carte du réseau. Le moteur (TopoSearch) est dans NetScopeCore ;
// ici, le bandeau du résultat au-dessus de la carte et la fiche du résultat dans le détail.

/// Recherche de la carte, calculée par l'écran à chaque rendu.
struct TopoSearchContext {
    let text: String
    let hits: [TopoSearchHit]
    /// Rang du résultat courant, ramené dans la liste.
    let index: Int
    /// Autres sites où la recherche trouve aussi des appareils.
    let otherSites: [TopoSiteMatch]
    /// Appareils trouvés parmi ceux des scans précédents, masqués sur la carte.
    let previousCount: Int
    /// Site dessiné.
    let siteName: String
    /// Début d'adresse du site dessiné, pour l'exemple du message « aucun résultat » (« 10.182.122. »).
    var ipExample = "10.0.0."

    var current: TopoSearchHit? { hits.isEmpty ? nil : hits[min(max(index, 0), hits.count - 1)] }
    var counter: String { TopoSearch.position(index, count: hits.count) }

    /// Ce que la carte surligne ; nil sans résultat (rien n'est atténué).
    func highlight(_ graph: TopoGraph) -> TopoSearchHighlight? {
        guard let current else { return nil }
        return TopoSearchHighlight(current: current.nodeID, counts: TopoSearch.countsByNode(hits),
                                   path: TopoSearch.path(to: current.nodeID, in: graph))
    }
}

/// Actions de la recherche (écran Carte).
struct TopoSearchActions {
    /// Résultat suivant (1) ou précédent (−1).
    var step: (Int) -> Void
    /// Dessiner un autre site et y montrer le premier résultat.
    var showSite: (String) -> Void
    /// Montrer aussi les appareils des scans précédents.
    var showPrevious: () -> Void
    var clear: () -> Void
}

// MARK: - Bandeau au-dessus de la carte

/// « « 10.182.122.140 » · 1 sur 1 · Imprimantes ×2 · Switch étage 2   Aussi sur : Laval   ‹ › ».
struct TopoSearchBand: View {
    let search: TopoSearchContext
    let graph: TopoGraph
    let actions: TopoSearchActions

    var body: some View {
        let found = search.current
        HStack(spacing: 10) {
            Image(systemName: found == nil ? "exclamationmark.magnifyingglass" : "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(found == nil ? Theme.warning : Theme.accentStrong)
            if let found {
                Text(search.counter)
                    .font(Theme.mono(11.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(Theme.accentSoft))
                    .foregroundStyle(Theme.accentStrong)
                    .fixedSize()
                ViewThatFits(in: .horizontal) {
                    resultText(found, withLocation: true)
                    resultText(found, withLocation: false)
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(1)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text("Aucun appareil ne correspond à «\u{00A0}\(search.text)\u{00A0}» sur ce dessin").fixedSize()
                    Text("Aucun appareil trouvé sur ce dessin").fixedSize()
                    Text("Aucun résultat").fixedSize()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .layoutPriority(1)
            }
            Spacer(minLength: 6)
            if !search.otherSites.isEmpty {
                ViewThatFits(in: .horizontal) {
                    alsoOn(search.otherSites, title: "Aussi sur\u{00A0}:")
                    alsoOn(Array(search.otherSites.prefix(1)), title: "Aussi sur\u{00A0}:")
                    alsoOnMenu
                }
            }
            if search.hits.count > 1 {
                HStack(spacing: 4) {
                    stepButton("chevron.up", "Résultat précédent (⇧↩︎ ou ⇧⌘G)", delta: -1)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    stepButton("chevron.down", "Résultat suivant (↩︎ ou ⌘G)", delta: 1)
                        .keyboardShortcut("g", modifiers: .command)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(found == nil ? Theme.warningSoft : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func resultText(_ hit: TopoSearchHit, withLocation: Bool) -> some View {
        let location = TopoSearch.location(of: hit, in: graph)
        let name = graph.node(hit.nodeID).flatMap { node in node.kind == .groupe ? nil : node.title }
        return HStack(spacing: 6) {
            Text(hit.deviceID).font(Theme.mono(12, weight: .semibold))
            if let name, name != hit.deviceID {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            if withLocation, !location.isEmpty {
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(location).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .fixedSize()
    }

    private func alsoOn(_ sites: [TopoSiteMatch], title: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
            ForEach(sites, id: \.key) { site in
                Button { actions.showSite(site.key) } label: { Label(site.label, systemImage: "mappin.and.ellipse") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .help("Dessiner «\u{00A0}\(site.name)\u{00A0}» et y montrer \(site.count > 1 ? "les \(site.count) résultats" : "le résultat")")
            }
        }
        .fixedSize()
    }

    private var alsoOnMenu: some View {
        Menu {
            ForEach(search.otherSites, id: \.key) { site in
                Button(site.label) { actions.showSite(site.key) }
            }
        } label: {
            Label("Aussi sur \(search.otherSites.count) site\(search.otherSites.count > 1 ? "s" : "")", systemImage: "mappin.and.ellipse")
                .font(Theme.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Autres sites où la recherche trouve des appareils")
    }

    private func stepButton(_ symbol: String, _ help: String, delta: Int) -> some View {
        // Même style que les flèches du panneau de détail (état enfoncé et désactivé natifs).
        Button { actions.step(delta) } label: { Image(systemName: symbol) }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Fiche du résultat (détail)

/// En tête du détail : le résultat courant (fiche de l'appareil : IP, MAC, switch / port, VLAN,
/// borne Wi-Fi, « Ouvrir la fiche »), ou un message clair quand rien n'est trouvé.
struct TopoSearchPanel: View {
    let search: TopoSearchContext
    let graph: TopoGraph
    let devices: [Device]
    let actions: TopoSearchActions
    /// Ouvre la fiche de l'appareil (Appareil, ou Inventaire d'un autre site).
    let open: (Device) -> Void
    /// Montre le nœud du résultat sur la carte (après un clic sur un autre nœud).
    let select: (String) -> Void
    let selectedID: String?

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let hit = search.current, let device = devices.first(where: { $0.id == hit.deviceID }) {
                    card(device, hit: hit)
                } else {
                    noResult
                }
                if !search.otherSites.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(search.current == nil ? "Trouvé sur d’autres sites" : "Aussi sur")
                        ForEach(search.otherSites, id: \.key) { site in
                            Button { actions.showSite(site.key) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(Theme.neutralText)
                                        .frame(width: 16)
                                    Text(site.name).font(Theme.small).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(site.count > 1 ? "\(site.count) appareils" : "1 appareil")
                                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Dessiner «\u{00A0}\(site.name)\u{00A0}» et y montrer le résultat")
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentStrong)
            Text(search.hits.isEmpty ? "Recherche" : "Résultat \(search.counter)").font(Theme.panelTitle).fixedSize()
            Spacer(minLength: 4)
            if search.hits.count > 1 {
                HStack(spacing: 4) {
                    Button { actions.step(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Résultat précédent (⇧↩︎)")
                    Button { actions.step(1) } label: { Image(systemName: "chevron.down") }
                        .help("Résultat suivant (↩︎)")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .fixedSize()
            }
            Button { actions.clear() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Effacer la recherche")
        }
    }

    private func card(_ device: Device, hit: TopoSearchHit) -> some View {
        let node = graph.node(hit.nodeID)
        let colors = TopoStyle.colors(kind: node?.kind == .groupe ? .appareil : (node?.kind ?? .appareil), type: device.deviceType)
        let wireless = (device.switchPort ?? "").lowercased() == "wi-fi"
        let accessPoint = TopoSearch.accessPoints(of: device, graph: graph).last
        let location = TopoSearch.location(of: hit, in: graph)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: InvStyle.symbol(device.deviceType))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.fg)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).fill(colors.bg))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        InvPill(text: device.isOnline ? "En ligne" : "Hors ligne",
                                foreground: device.isOnline ? Theme.success : Theme.textSecondary,
                                background: device.isOnline ? Theme.successSoft : Theme.neutralSoft)
                        InvPill(text: device.deviceType.label, foreground: Theme.neutralText, background: Theme.neutralSoft)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                KeyValueRow(key: "IP", value: device.ip.description, mono: true, keyWidth: 92)
                KeyValueRow(key: "MAC", value: device.mac?.formatted(.upperColon) ?? "—", mono: true, keyWidth: 92)
                if wireless {
                    KeyValueRow(key: "Borne Wi-Fi", value: accessPoint ?? "—", keyWidth: 92)
                } else {
                    KeyValueRow(key: "Switch / port", value: device.switchLocation ?? "Port inconnu",
                                mono: device.switchLocation != nil, keyWidth: 92)
                }
                KeyValueRow(key: "VLAN", value: device.vlan.map(String.init) ?? "—", keyWidth: 92)
                if !location.isEmpty {
                    KeyValueRow(key: "Sur la carte", value: location, keyWidth: 92)
                }
            }
            if hit.isInGroup, let node {
                Text("Dans le groupe «\u{00A0}\(node.title)\u{00A0}», surligné sur la carte\u{00A0}; l’appareil est marqué dans la liste des membres ci-dessous.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InvFlowLayout(spacing: 8) {
                Button { open(device) } label: { Label("Ouvrir la fiche", systemImage: "doc.text") }
                    .buttonStyle(.primary)
                if selectedID != hit.nodeID {
                    Button { select(hit.nodeID) } label: { Label("Montrer sur la carte", systemImage: "scope") }
                        .buttonStyle(.secondary)
                }
            }
        }
    }

    private var noResult: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aucun appareil trouvé").font(.system(size: 13, weight: .semibold))
            Text("«\u{00A0}\(search.text)\u{00A0}» ne correspond à aucun appareil sur la carte de «\u{00A0}\(search.siteName)\u{00A0}».")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if search.previousCount > 0 {
                Button { actions.showPrevious() } label: {
                    Label("Afficher les scans précédents (\(search.previousCount) trouvé\(search.previousCount > 1 ? "s" : ""))",
                          systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.secondary)
                .help("La carte montre le dernier scan\u{00A0}; \(search.previousCount) appareil\(search.previousCount > 1 ? "s" : "") des scans précédents correspond\(search.previousCount > 1 ? "ent" : "")")
            }
            Text("Essayez une partie de l’IP (\(search.ipExample)), un nom, une MAC ou un préfixe\u{00A0}: switch:, port:, vlan:, type:, borne:.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ActionRow {
                Button("Effacer la recherche") { actions.clear() }.buttonStyle(.secondary)
            }
        }
    }
}
