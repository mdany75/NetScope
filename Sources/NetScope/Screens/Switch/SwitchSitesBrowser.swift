import NetScopeCore
import SwiftUI

// Note 48 (demande de Dany, 0.15.0) : « Switchs et ports » d'un autre site, ou de plusieurs, choisis
// par le menu « Site ▾ » du bandeau, SANS changer le site actif du Scanner. Rien n'est relu en
// arrivant : les FortiSwitch viennent de la dernière lecture des FortiGate du site (cette session),
// les switchs SNMP du dernier relevé fait POUR CE SITE. « Lire la FortiGate » interroge, à la
// demande et en lecture seule, les FortiGate du site ; le relevé SNMP, lui, se fait sur place
// (site actif), sa communauté ne part jamais vers l'adresse d'un autre client.
//
// Plusieurs sites : une carte par site (état de sa FortiGate, nombre de switchs, remarques), un
// tableau commun groupé par site (colonne « Site », recherche de la barre d'outils), puis la façade
// et les ports du switch choisi. Deux sites aux mêmes adresses ne se mélangent jamais (lignes
// « site|adresse »).

/// Une ligne du tableau des switchs de plusieurs sites.
struct SwitchSiteRow: Identifiable, Hashable {
    let entry: SiteSwitchEntry
    let siteOrder: Int
    var id: String { entry.id }
    var site: String { entry.siteName }
    var name: String { entry.name.lowercased() }
    var model: String { SwitchText.model(entry.snapshot) }
    var source: String { entry.sourceLabel }
    var address: String { entry.snapshot.fortiLinkIP?.description ?? entry.snapshot.host.description }
    var addressSort: UInt32 { entry.snapshot.fortiLinkIP?.value ?? entry.snapshot.host.value }
    var ports: Int { entry.portsUp }
    var polled: Date { entry.snapshot.polledAt }
    /// Tri par défaut : site (ordre du menu), puis nom.
    var groupKey: String { String(format: "%03d|", siteOrder) + name }
}

/// Un site de la vue : ses switchs, son état et ses remarques.
struct SwitchSiteGroup: Identifiable {
    let key: String
    let name: String
    let site: Site?
    let isActive: Bool
    let view: SiteSwitchView
    var id: String { key }
}

struct SwitchSitesBrowser: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    let keys: [String]

    @StateObject private var table = StandardTableModel<SwitchSiteRow>(id: "switchs.sites", columns: Self.columns,
                                                                        sortKeys: Self.sortKeys, defaultSort: "groupe")
    @State private var selection: Set<String> = []
    @State private var selectedPort: Int?
    /// Port demandé par un focus : repris par `onChange(of: selection)` au lieu d'être effacé.
    @State private var pendingPort: Int??

    static let columns: [StandardColumn] = [
        StandardColumn.site,
        StandardColumn(id: "nom", title: "Switch", isRequired: true),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "adresse", title: "Adresse"),
        StandardColumn(id: "ports", title: "Ports actifs"),
        StandardColumn(id: "releve", title: "Relevé"),
    ]
    static let sortKeys: [String: KeyPathComparator<SwitchSiteRow>] = [
        "groupe": KeyPathComparator(\SwitchSiteRow.groupKey),
        "site": KeyPathComparator(\SwitchSiteRow.site),
        "nom": KeyPathComparator(\SwitchSiteRow.name),
        "modele": KeyPathComparator(\SwitchSiteRow.model),
        "source": KeyPathComparator(\SwitchSiteRow.source),
        "adresse": KeyPathComparator(\SwitchSiteRow.addressSort),
        "ports": KeyPathComparator(\SwitchSiteRow.ports),
        "releve": KeyPathComparator(\SwitchSiteRow.polled),
    ]

    // MARK: Données

    private var groups: [SwitchSiteGroup] {
        keys.map { key in
            let isActive = key == sites.activeKey
            let site = sites.site(forKey: key)
            if isActive {
                // Le site actif : exactement les switchs de sa vue habituelle.
                let entries = store.siteHosts(ignoringShowAll: true).compactMap { host -> SiteSwitchEntry? in
                    guard let snapshot = store.snapshots[host] else { return nil }
                    return SiteSwitchEntry(siteKey: key, siteName: sites.activeName, snapshot: snapshot,
                                           source: store.isController(host) ? .fortiGate(snapshot.controllerName ?? "FortiGate") : .snmp)
                }
                return SwitchSiteGroup(key: key, name: sites.activeName, site: site, isActive: true,
                                       view: SiteSwitchView(entries: entries,
                                                            emptyMessage: entries.isEmpty ? "Aucun switch relevé sur le site actif\u{00A0}: «\u{00A0}Interroger les switchs\u{00A0}» dans sa vue." : nil,
                                                            fortiGatesToRead: site?.fortiGateIDs ?? []))
            }
            guard let site else {
                return SwitchSiteGroup(key: key, name: sites.name(forKey: key), site: nil, isActive: false,
                                       view: SiteSwitchView(emptyMessage: "Site introuvable."))
            }
            let view = SiteSwitchBrowse.view(site: site, siteKey: key, fortiReports: fortigate.reports(for: site),
                                             fortiGateNames: fortigate.controllerNames, snmp: store.snmpReadings)
            return SwitchSiteGroup(key: key, name: site.displayName, site: site, isActive: false, view: view)
        }
    }

    var body: some View {
        let groups = groups
        let search = state.searchTexts[.switchs] ?? ""
        let rows = groups.enumerated().flatMap { index, group in
            group.view.entries.filter { $0.matches(search) }.map { SwitchSiteRow(entry: $0, siteOrder: index) }
        }.sorted(using: table.sortOrder)
        let chosen = rows.first { selection.contains($0.id) } ?? rows.first
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(groups) { group in
                    SwitchSiteCard(group: group, shown: rows.filter { $0.entry.siteKey == group.key }.count)
                }
            }
            if !rows.isEmpty || !search.isEmpty {
                tablePanel(rows, total: groups.reduce(0) { $0 + $1.view.entries.count }, multiple: groups.count > 1)
            }
            if let chosen {
                detail(chosen.entry)
            }
        }
        .preference(key: SearchResultsKey.self, value: search.isEmpty ? [] : ["\(rows.count) switch\(rows.count > 1 ? "s" : "")"])
        .onAppear { applyFocus(rows) }
        .onChange(of: store.browseFocus) { _, _ in applyFocus(rows) }
        .onChange(of: selection) { _, ids in
            if let pending = pendingPort {
                selectedPort = pending
                pendingPort = nil
            } else {
                selectedPort = nil
            }
            store.browseSelection = ids.count == 1 ? ids.first : nil
        }
    }

    /// Switch demandé par un autre écran (double-clic, « Ouvrir dans », Retour) : choisi dans la vue.
    private func applyFocus(_ rows: [SwitchSiteRow]) {
        if let focus = store.browseFocus {
            if let row = rows.first(where: { $0.entry.siteKey == focus.siteKey && $0.entry.answers(to: focus.hostOrName) }) {
                let port = focus.port.flatMap { name in row.entry.snapshot.interfaces.first { $0.name == name }?.index }
                if selection == [row.id] {
                    selectedPort = port
                } else {
                    // Le changement de sélection efface le port : il le reprendra d'ici.
                    pendingPort = .some(port)
                    selection = [row.id]
                }
            }
            store.browseFocus = nil
        } else if selection.isEmpty, let kept = store.browseSelection, rows.contains(where: { $0.id == kept }) {
            selection = [kept]
        } else if selection.isEmpty, let first = rows.first {
            selection = [first.id]
        }
    }

    // MARK: Tableau

    private func tablePanel(_ rows: [SwitchSiteRow], total: Int, multiple: Bool) -> some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(multiple ? "Switchs des sites choisis" : "Switchs du site").font(Theme.bodySemibold)
                    Text(rows.count == total ? "\(total) switch\(total > 1 ? "s" : "")" : "\(rows.count) sur \(total)")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    StandardColumnsMenu(model: table, compact: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                if rows.isEmpty {
                    Text("Aucun switch ne correspond à la recherche.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(14)
                } else {
                    table(rows)
                        .standardTableHeight(rows: rows.count, rowHeight: 28, maxRows: 10)
                        .standardSiteColumn(table, multiple: multiple)
                }
            }
        }
    }

    private func table(_ rows: [SwitchSiteRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { row in
                HStack(spacing: 5) {
                    Image(systemName: row.entry.siteKey == sites.activeKey ? "mappin.circle.fill" : "mappin")
                        .font(.system(size: 10.5))
                        .foregroundStyle(row.entry.siteKey == sites.activeKey ? Theme.accent : Theme.textSecondary)
                        .frame(width: 12)
                    Text(row.entry.siteName).font(Theme.small).lineLimit(1)
                }
            }
            .width(min: 110, ideal: 150)
            .customizationID("site")
            .defaultVisibility(.hidden)
            TableColumn(StandardTableHeading("SWITCH"), sortUsing: table.sort("nom")) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.entry.portsUp > 0 ? .success : .neutral, size: 7)
                    Text(row.entry.name).font(Theme.mono(12, weight: .semibold)).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 170)
            .customizationID("nom")
            .disabledCustomizationBehavior(.visibility)
            TableColumn(StandardTableHeading("MODÈLE"), sortUsing: table.sort("modele")) { row in
                Text(row.model).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 120, ideal: 220)
            .customizationID("modele")
            TableColumn(StandardTableHeading("SOURCE"), sortUsing: table.sort("source")) { row in
                switch row.entry.source {
                case .fortiGate(let name): Chip(text: "FortiGate · \(name)", tone: .accent)
                case .snmp: Chip(text: "SNMP", tone: .neutral)
                }
            }
            .width(min: 90, ideal: 170)
            .customizationID("source")
            TableColumn(StandardTableHeading("ADRESSE"), sortUsing: table.sort("adresse")) { row in
                Text(row.address).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 90, ideal: 120)
            .customizationID("adresse")
            TableColumn(StandardTableHeading("PORTS ACTIFS"), sortUsing: table.sort("ports")) { row in
                Text("\(row.entry.portsUp) / \(row.entry.portsTotal)").font(Theme.mono(12))
            }
            .width(min: 70, ideal: 90)
            .customizationID("ports")
            TableColumn(StandardTableHeading("RELEVÉ"), sortUsing: table.sort("releve")) { row in
                Text(ScanFormat.relative(row.polled)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            .customizationID("releve")
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) { rowMenu(row.entry) }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) { open(row.entry) }
        }
    }

    @ViewBuilder private func rowMenu(_ entry: SiteSwitchEntry) -> some View {
        if entry.siteKey == sites.activeKey {
            Button("Voir sur la façade du site actif") { open(entry) }
        } else {
            Button("Afficher ce site seulement") { scopes.set(.sites([entry.siteKey]), for: .switchs) }
            if let site = sites.site(forKey: entry.siteKey) {
                Button("Faire de «\u{00A0}\(site.displayName)\u{00A0}» le site actif") { sites.activate(site.id, state: state) }
            }
        }
        Divider()
        Button("Appareils de ce switch dans l’Inventaire") { openInventory(entry, port: nil) }
    }

    /// Double-clic : un switch du site actif s'ouvre dans sa vue habituelle (façade, trafic) ; celui
    /// d'un autre site est montré ici.
    private func open(_ entry: SiteSwitchEntry) {
        if entry.siteKey == sites.activeKey {
            state.navigate(NavDestination(.switchs, focus: .switchPort(host: entry.snapshot.id, port: nil), sites: .only([entry.siteKey])))
            scopes.set(.active, for: .switchs, persist: false)
            store.select(host: entry.snapshot.id)
            // Note 83 : la façade est dans l'onglet Switchs.
            SwitchTabState.shared.tab = .switchs
        } else {
            selection = [entry.id]
        }
    }

    /// Inventaire du site du switch, filtré sur ce switch (et ce port).
    private func openInventory(_ entry: SiteSwitchEntry, port: String?) {
        let name = entry.name.contains(" ") ? "switch:\"\(entry.name)\"" : "switch:\(entry.name)"
        let search = port.map { name + " port:\($0)" } ?? name
        state.navigate(NavDestination(.inventaire, search: search, sites: entry.siteKey == sites.activeKey ? nil : .include(entry.siteKey)))
    }

    // MARK: Détail du switch choisi

    private func detail(_ entry: SiteSwitchEntry) -> some View {
        let snapshot = entry.snapshot
        let ports = snapshot.physicalPorts
        let port = selectedPort.flatMap { snapshot.interface($0) } ?? ports.first(where: \.isUp) ?? ports.first
        return SidePanelSplit(sideWidth: 320, collapse: .below, spacing: 16) {
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        (Text("Façade · ").font(.system(size: 14, weight: .semibold))
                            + Text(snapshot.displayName).font(Theme.mono(14, weight: .semibold)))
                            .lineLimit(1)
                        Chip(text: entry.siteName, tone: entry.siteKey == sites.activeKey ? .accent : .neutral, systemImage: "mappin")
                        Spacer(minLength: 8)
                        Text("Relevé \(ScanFormat.relative(snapshot.polledAt).lowercased())")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        SwitchFaceplate(snapshot: snapshot, selected: port?.index, found: nil,
                                        recent: store.recentErrors(snapshot.id),
                                        onOpen: { index in
                                            selectedPort = index
                                            openInventory(entry, port: snapshot.interface(index)?.name)
                                        }) { index in
                            selectedPort = index
                        }
                    }
                    SwitchLegend()
                    Text(entry.siteKey == sites.activeKey
                         ? "Double-cliquez sur la ligne du switch pour l’ouvrir dans la vue du site actif (trafic, table MAC, recherche)."
                         : "Vue en lecture seule de «\u{00A0}\(entry.siteName)\u{00A0}» (dernière lecture connue). Double-clic sur un port\u{00A0}: ses appareils dans l’Inventaire de ce site.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } side: {
            Panel(padding: 14) {
                if let port {
                    portDetail(port, snapshot: snapshot, entry: entry)
                } else {
                    Text("Ce switch n’a aucun port physique relevé.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func portDetail(_ port: SNMPInterface, snapshot: SNMPSwitchSnapshot, entry: SiteSwitchEntry) -> some View {
        let macs = snapshot.entries(on: port.index)
        let neighbor = snapshot.neighbor(on: port.index)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Port sélectionné · \(snapshot.displayName)")
            HStack(spacing: 8) {
                Text(port.name).font(Theme.mono(16, weight: .bold))
                Chip(text: port.isUp ? "Actif" : (port.adminUp ? "Inactif" : "Désactivé"), tone: port.isUp ? .success : .neutral)
            }
            KeyValueRow(key: "Description", value: port.alias.isEmpty ? "—" : port.alias, keyWidth: 110)
            KeyValueRow(key: "Vitesse", value: port.speedMbps.map { $0 >= 1000 ? "\($0 / 1000)\u{00A0}Gb/s" : "\($0)\u{00A0}Mb/s" } ?? "—", mono: true, keyWidth: 110)
            KeyValueRow(key: "VLAN", value: snapshot.pvid[port.index].map(String.init) ?? "—", mono: true, keyWidth: 110)
            KeyValueRow(key: "PoE", value: snapshot.poePorts.contains(port.index) ? "Oui" : "Non", keyWidth: 110)
            KeyValueRow(key: "Voisin LLDP", value: neighbor.map { "\($0.sysName) · \($0.portID)" } ?? "—", keyWidth: 110)
            KeyValueRow(key: "MAC apprises", value: "\(macs.count)", mono: true, keyWidth: 110)
            if !macs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(macs.prefix(6), id: \.self) { item in
                        Text(item.mac.formatted(.upperColon)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    }
                    if macs.count > 6 {
                        Text("+\(macs.count - 6) autres").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Button { openInventory(entry, port: port.name) } label: {
                Label("Appareils de ce port dans l’Inventaire", systemImage: Screen.inventaire.symbol)
            }
            .buttonStyle(.secondary)
            .padding(.top, 4)
        }
    }
}

/// Carte d'un site : pastille et état de sa FortiGate, nombre de switchs, remarques, lecture.
private struct SwitchSiteCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    let group: SwitchSiteGroup
    let shown: Int

    var body: some View {
        let link = group.site.map { sites.linkState($0) } ?? .noFortiGate
        let count = group.view.entries.count
        let reading = fortigate.isReading(group.view.fortiGatesToRead)
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: group.isActive ? "mappin.circle.fill" : "mappin.and.ellipse")
                        .font(.system(size: 13)).foregroundStyle(group.isActive ? Theme.accent : Theme.textSecondary)
                    Text(group.name).font(Theme.bodySemibold).lineLimit(1)
                    if group.isActive { Chip(text: "Site actif", tone: .accent) }
                    Spacer(minLength: 6)
                    Text("\(count) switch\(count > 1 ? "s" : "")").font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(count > 0 ? Theme.text : Theme.textTertiary)
                }
                // Texte complet sur plusieurs lignes : la raison d'un échec ne doit pas être coupée.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SiteLinkDot(state: link, size: 7)
                    Text(link.helpText).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = group.view.emptyMessage {
                    Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(group.view.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ActionRow {
                    if !group.view.fortiGatesToRead.isEmpty, !group.isActive {
                        Button { fortigate.readForView(group.view.fortiGatesToRead) } label: {
                            HStack(spacing: 6) {
                                if reading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                                Text(reading ? "Lecture…" : "Lire la FortiGate")
                            }
                        }
                        .buttonStyle(.secondary)
                        .disabled(reading || !fortigate.isEnabled)
                        .help("Relit, par l’API REST (HTTPS, lecture seule), les FortiSwitch des FortiGate de ce site. Le site actif ne change pas.")
                    }
                    if group.isActive {
                        Button("Ouvrir la vue du site actif") { scopes.set(.active, for: .switchs) }
                            .buttonStyle(.secondary)
                    } else if group.site == nil || group.view.emptyMessage != nil {
                        Button("Réglages…") {
                            RegNavigation.shared.section = group.site?.fortiGateIDs.isEmpty == false ? .switchs : .sites
                            state.open(.reglages)
                        }
                        .buttonStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            if !group.isActive, let site = group.site {
                Button("Faire de «\u{00A0}\(site.displayName)\u{00A0}» le site actif") { sites.activate(site.id, state: state) }
            }
            if group.key != sites.activeKey || scopes.keys(for: .switchs).count > 1 {
                Button("Afficher ce site seulement") { scopes.set(group.isActive ? .active : .sites([group.key]), for: .switchs) }
            }
        }
    }
}
