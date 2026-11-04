import NetScopeCore
import SwiftUI

// Note 29 : Réglages › Switchs › Relecture automatique. Intervalle de chaque site (Désactivée,
// 1, 2, 5, 10, 15 ou 30 min ; 5 min par défaut) ; seul le site actif est relu, sans scan.

/// Ligne du tableau des sites (tableau standard « reglages.relecture »).
struct RegAutoRefreshRow: Identifiable {
    let key: String
    let name: String
    let isActive: Bool
    let interval: AutoRefreshInterval
    let isCustom: Bool
    /// FortiGate et switchs SNMP associés (« 1 FortiGate · 2 switchs SNMP »).
    let sources: String

    var id: String { key }
    var sortName: String { (isActive ? "0" : "1") + name.lowercased() }
    var sortInterval: Int { interval.isOn ? interval.rawValue : Int.max }
}

/// Panneau « Relecture automatique » de Réglages › Switchs.
struct RegAutoRefreshPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = AutoRefreshStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @StateObject private var table = StandardTableModel<RegAutoRefreshRow>(id: "reglages.relecture", columns: Self.columns,
                                                                            sortKeys: Self.sortKeys, defaultSort: "site")

    static let columns: [StandardColumn] = [
        StandardColumn(id: "site", title: "Site", isRequired: true),
        StandardColumn(id: "intervalle", title: "Relecture", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "sources", title: "Relu automatiquement", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegAutoRefreshRow>] = [
        "site": KeyPathComparator(\RegAutoRefreshRow.sortName),
        "intervalle": KeyPathComparator(\RegAutoRefreshRow.sortInterval),
        "etat": KeyPathComparator(\RegAutoRefreshRow.sortName),
        "sources": KeyPathComparator(\RegAutoRefreshRow.sources),
    ]

    var body: some View {
        RegPanel(title: "Relecture automatique",
                 subtitle: "Sans relancer de scan, NetScope relit à intervalle régulier la FortiGate du site actif (FortiSwitch, emplacement des appareils, table ARP et baux DHCP), ses bornes FortiAP et ses switchs SNMP. Lecture seule\u{00A0}: requêtes GET et SNMP en lecture, rien n’est jamais modifié.",
                 accessory: { StandardColumnsMenu(model: table) }) {
            activeRow
            VStack(alignment: .leading, spacing: 6) {
                rule("pause.circle", "En pause pendant un scan (la fin du scan relit elle-même), Mac en veille ou hors réseau, et pour tout site qui n’est pas le site actif.")
                rule("arrow.triangle.2.circlepath", "Une lecture faite ailleurs («\u{00A0}Relire\u{00A0}», fin de scan, sondes de la Surveillance) repousse la suivante\u{00A0}: jamais deux lectures à la fois vers la même FortiGate.")
                rule("exclamationmark.arrow.triangle.2.circlepath", "FortiGate ou switch en erreur\u{00A0}: les essais s’espacent (le double à chaque échec, jusqu’à 1\u{00A0}h)\u{00A0}; jeton absent ou certificat à accepter\u{00A0}: plus d’essai avant d’avoir réglé le problème.")
                rule("lock.shield", "Switchs SNMP\u{00A0}: seulement ceux du site actif, jamais ceux d’un autre site (la communauté ne part jamais vers l’appareil qui porte la même adresse chez un autre client).")
            }
            .padding(.vertical, 12)
            siteTable
        }
    }

    // MARK: Site actif

    private var activeRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Site actif\u{00A0}: \(sites.activeName)").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    if !store.isCustom(sites.activeKey) { Chip(text: "Par défaut", tone: .neutral) }
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Label(store.statusText(now: context.date),
                          systemImage: store.isTroubled ? "exclamationmark.arrow.triangle.2.circlepath" : "clock.arrow.2.circlepath")
                        .font(Theme.small)
                        .foregroundStyle(store.isTroubled ? Theme.warning : Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            intervalPicker(key: sites.activeKey, label: "Relecture du site actif")
                .frame(width: 240)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func intervalPicker(key: String, label: String) -> some View {
        Picker(label, selection: Binding(get: { store.interval(forSiteKey: key) },
                                         set: { store.setInterval($0, forSiteKey: key) })) {
            ForEach(AutoRefreshInterval.allCases) { interval in
                Text(interval.menuLabel + (interval == .standard ? " (par défaut)" : "")).tag(interval)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help("Intervalle de la relecture automatique de ce site")
    }

    private func rule(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 16)
        }
    }

    // MARK: Tableau des sites

    private var rows: [RegAutoRefreshRow] {
        var list = sites.sortedSites.map { site -> RegAutoRefreshRow in
            let key = SiteFiles.key(for: site.id)
            let forti = site.fortiGateIDs.filter { fortigate.controller($0) != nil }.count
            let snmp = site.switchHosts.count
            var parts: [String] = []
            if forti > 0 { parts.append("\(forti) FortiGate (switchs, bornes)") }
            if snmp > 0 { parts.append("\(snmp) switch\(snmp > 1 ? "s" : "") SNMP") }
            return RegAutoRefreshRow(key: key, name: site.displayName, isActive: key == sites.activeKey,
                                     interval: store.interval(forSiteKey: key), isCustom: store.isCustom(key),
                                     sources: parts.isEmpty ? "Switchs SNMP relevés dans ce site" : parts.joined(separator: " · "))
        }
        if sites.activeID == nil {
            let key = SiteFiles.noSiteKey
            list.append(RegAutoRefreshRow(key: key, name: "Aucun site (plages du Scanner)", isActive: true,
                                          interval: store.interval(forSiteKey: key), isCustom: store.isCustom(key),
                                          sources: "FortiGate qui couvrent les plages cochées"))
        }
        return list.sorted(using: table.sortOrder)
    }

    @ViewBuilder private var siteTable: some View {
        let rows = rows
        if rows.count > 1 || sites.activeID != nil {
            VStack(alignment: .leading, spacing: 8) {
                RegLabel("Intervalle par site")
                Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn("SITE", sortUsing: table.sort("site")) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            Text(row.name).font(Theme.small.weight(row.isActive ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                            if row.isActive { Chip(text: "Actif", tone: .accent) }
                        }
                        .frame(height: RegSwitchTableMetrics.rowHeight - 8)
                    }
                    .width(min: 150, ideal: 200)
                    .customizationID("site")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("RELECTURE", sortUsing: table.sort("intervalle")) { row in
                        intervalPicker(key: row.key, label: "Relecture de \(row.name)")
                            .controlSize(.small)
                            .fixedSize()
                    }
                    .width(min: 150, ideal: 190)
                    .customizationID("intervalle")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            RegSwitchCell(store.statusText(forSiteKey: row.key, now: context.date), secondary: !row.isActive)
                                .help(store.statusText(forSiteKey: row.key, now: context.date))
                        }
                    }
                    .width(min: 160, ideal: 320)
                    .customizationID("etat")

                    TableColumn("RELU AUTOMATIQUEMENT", sortUsing: table.sort("sources")) { row in
                        RegSwitchCell(row.sources, secondary: true)
                    }
                    .width(min: 120, ideal: 220)
                    .customizationID("sources")
                    .defaultVisibility(.hidden)
                }
                .standardTableStyle()
                .frame(height: RegSwitchTableMetrics.height(rows: rows.count))
                .regTableFrame()
            }
        }
    }
}
