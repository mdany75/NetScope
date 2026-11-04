import AppKit
import NetScopeCore
import SwiftUI

/// Note 28 : « Site : <nom> ▾ » en haut de « Plages à scanner ». Choisir un site remplace les plages
/// du Scanner par les siennes et recharge ses résultats et son inventaire ; on peut aussi
/// enregistrer les plages comme site, mettre à jour le site, le détecter par la passerelle et
/// ouvrir la gestion des sites. Une plage modifiée et non enregistrée est signalée.
struct ScanSiteBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @State private var showMenu = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showMenu.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 11, weight: .semibold))
                    (Text("Site\u{00A0}: ").foregroundColor(Theme.textSecondary) + Text(sites.activeName).foregroundColor(Theme.text))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choisir le site\u{00A0}: ses plages, son inventaire et ses résultats")
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                SiteMenuContent(close: { showMenu = false })
                    .environmentObject(state)
            }
            status
            Spacer(minLength: 0)
        }
        .sheet(item: $sites.prompt) { prompt in
            SitePromptSheet(prompt: prompt).environmentObject(state)
        }
    }

    @ViewBuilder private var status: some View {
        if sites.hasUnsavedRanges(state) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                Text("Plages modifiées, non enregistrées dans le site")
                    .font(Theme.small).foregroundStyle(Theme.warning).lineLimit(1)
                Button("Mettre à jour ce site") { sites.updateActiveSite(state) }
                    .buttonStyle(RegSmallButtonStyle())
                    .fixedSize()
            }
        } else if let site = sites.activeSite {
            let twins = sites.activeTwins
            Text(twins.isEmpty ? detail(site)
                               : "Plages en commun avec «\u{00A0}\(twins[0].displayName)\u{00A0}»\(twins.count > 1 ? " et \(twins.count - 1) autre\(twins.count > 2 ? "s" : "")" : "")\u{00A0}: le site se choisit par la passerelle, jamais par l’adresse IP.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                .help(twins.isEmpty ? detail(site) : "Plusieurs sites ont des adresses en commun\u{00A0}: «\u{00A0}Détecter mon site\u{00A0}» reconnaît le site par la MAC de sa passerelle ou par sa FortiGate.")
        } else {
            Text("Plages libres\u{00A0}: enregistrez-les comme site pour les retrouver.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private func detail(_ site: Site) -> String {
        let count = sites.inventoryCount(site)
        var parts = ["\(count) fiche\(count > 1 ? "s" : "") en inventaire"]
        let fortiGates = site.fortiGateIDs.compactMap { FortiGateStore.shared.controller($0)?.displayName }
        if !fortiGates.isEmpty { parts.append("FortiGate \(fortiGates.joined(separator: ", "))") }
        if let last = site.lastScan { parts.append("dernier scan \(ScanFormat.relative(last))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu des sites

/// Contenu du menu « Site » : recherche (au-delà de six sites), sites, plages libres, actions.
struct SiteMenuContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @State private var query = ""
    let close: () -> Void

    private var filtered: [Site] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return sites.sortedSites }
        return sites.sortedSites.filter { site in
            let haystack = ([site.displayName, site.notes] + site.ranges.flatMap { [$0.text, $0.label] }).joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sites.sites.count > 6 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Rechercher un site, une plage", text: $query)
                        .textFieldStyle(.plain)
                }
                .font(Theme.small)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .padding(10)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SITES").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                    if filtered.isEmpty {
                        Text(sites.sites.isEmpty ? "Aucun site enregistré." : "Aucun site ne correspond.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(filtered) { site in
                        SiteMenuRow(title: site.displayName, detail: site.rangesLabel, isActive: site.id == sites.activeID,
                                    shared: !sites.list.sharingAddresses(with: site.id).isEmpty) {
                            close()
                            sites.activate(site.id, state: state)
                        }
                    }
                    Divider().padding(.vertical, 4)
                    SiteMenuRow(title: "Aucun site (plages libres)", detail: "FortiGate choisie par plage", isActive: sites.activeID == nil,
                                shared: false, italic: true) {
                        close()
                        sites.activate(nil, state: state)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 300)
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                SiteMenuAction(title: "Enregistrer les plages comme site…", symbol: "plus.square.on.square") {
                    close()
                    sites.prompt = .saveAs
                }
                SiteMenuAction(title: "Mettre à jour ce site", symbol: "arrow.down.doc",
                               enabled: sites.hasUnsavedRanges(state)) {
                    close()
                    sites.updateActiveSite(state)
                }
                SiteMenuAction(title: "Détecter mon site", symbol: "scope") {
                    close()
                    sites.detect(state: state)
                }
                SiteMenuAction(title: "Gérer les sites…", symbol: "gearshape") {
                    close()
                    RegNavigation.shared.section = .sites
                    state.open(.reglages)
                }
            }
            .padding(4)
        }
        .frame(width: 330)
    }
}

private struct SiteMenuRow: View {
    let title: String
    let detail: String
    let isActive: Bool
    let shared: Bool
    var italic = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).opacity(isActive ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: isActive ? .semibold : .regular)).italic(italic)
                        .foregroundStyle(Theme.text).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if shared {
                    Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        .help("Un autre site a des adresses en commun")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SiteMenuAction: View {
    let title: String
    let symbol: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.text : Theme.textTertiary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

// MARK: - Questions (feuilles)

/// Feuille d'une question du Scanner : enregistrer les plages comme site, confirmer le site
/// détecté, ou choisir parmi plusieurs sites possibles.
struct SitePromptSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @Environment(\.dismiss) private var dismiss
    let prompt: SitePrompt

    var body: some View {
        switch prompt {
        case .saveAs: SiteSaveSheet(close: { dismiss() })
        case .detected(let id, let hint): detected(id, hint: hint)
        case .choose(let ids, let reason, let mac): SiteChooseSheet(candidates: ids, reason: reason, gatewayMAC: mac, close: { dismiss() })
        }
    }

    private func detected(_ id: UUID, hint: SiteHintKind) -> some View {
        let name = sites.site(id)?.displayName ?? "?"
        return VStack(alignment: .leading, spacing: 12) {
            Label("Site détecté\u{00A0}: «\u{00A0}\(name)\u{00A0}»", systemImage: "scope").font(Theme.panelTitle)
            Text("Reconnu par la \(hint.label). Le site actif est «\u{00A0}\(sites.activeName)\u{00A0}». Passer à «\u{00A0}\(name)\u{00A0}» recharge ses plages, son inventaire et ses résultats.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Rester sur «\u{00A0}\(sites.activeName)\u{00A0}»") { dismiss() }.buttonStyle(.secondary)
                Button("Passer à «\u{00A0}\(name)\u{00A0}»") {
                    dismiss()
                    sites.activate(id, state: state)
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// « Enregistrer les plages comme site… » : nom, notes et FortiGate associées.
struct SiteSaveSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @State private var name = ""
    @State private var notes = ""
    @State private var chosen: Set<UUID> = []
    @State private var prepared = false
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enregistrer les plages comme site").font(Theme.panelTitle)
            Text(sites.activeID == nil
                 ? "Les plages libres, les résultats en cours et leur inventaire deviennent ceux du nouveau site."
                 : "Le nouveau site part de ces plages et d’un inventaire vide\u{00A0}; «\u{00A0}\(sites.activeName)\u{00A0}» garde ses plages enregistrées et son inventaire.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            RegField(label: "Nom du site (au besoin, celui du client)") {
                RegTextField(placeholder: "Ex. Clinique Exemple ou Groupe X · Laval", text: $name)
            }
            RegField(label: "Notes") {
                RegTextField(placeholder: "Facultatif", text: $notes)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Plages").font(.system(size: 12, weight: .semibold))
                Text(state.ranges.map { "\($0.text) · \($0.label)" }.joined(separator: "\n"))
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !fortigate.controllers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FortiGate du site").font(.system(size: 12, weight: .semibold))
                    ForEach(fortigate.controllers) { controller in
                        Toggle(isOn: Binding(get: { chosen.contains(controller.id) },
                                             set: { if $0 { chosen.insert(controller.id) } else { chosen.remove(controller.id) } })) {
                            Text(controller.displayName).font(Theme.small)
                                + Text("  \(controller.addressLabel)").font(Theme.mono(11)).foregroundColor(Theme.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text("Cochées d’office\u{00A0}: celles dont les plages couvrent les plages du Scanner.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack {
                Spacer()
                Button("Annuler", action: close).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer le site") {
                    close()
                    sites.saveRangesAsSite(name: name, notes: notes, fortiGateIDs: fortigate.controllers.map(\.id).filter(chosen.contains),
                                           state: state)
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || state.ranges.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            chosen = Set(SiteFortiGate.matching(fortigate.controllers, ranges: state.checkedRanges))
        }
    }
}

/// Plusieurs sites possibles (mêmes plages, passerelle inconnue) : on demande, jamais de choix
/// automatique. Le site choisi retient la MAC de la passerelle.
struct SiteChooseSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    let candidates: [UUID]
    let reason: String
    let gatewayMAC: MACAddress?
    let close: () -> Void
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quel site\u{00A0}?").font(Theme.panelTitle)
            Text(reason).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(candidates, id: \.self) { id in
                    if let site = sites.site(id) {
                        Button { selection = id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selection == id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selection == id ? Theme.accent : Theme.textTertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.displayName).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                                    Text(site.rangesLabel).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                if site.id == sites.activeID { Chip(text: "Actif", tone: .accent) }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(selection == id ? Theme.accentSoft : Theme.panelMuted))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let gatewayMAC {
                Text("La MAC de la passerelle (\(gatewayMAC.formatted(.upperColon))) sera retenue pour le site choisi\u{00A0}: la prochaine détection sera automatique.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annuler", action: close).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Choisir ce site") {
                    guard let selection else { return }
                    close()
                    sites.choose(selection, learning: gatewayMAC, state: state)
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
