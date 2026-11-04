import NetScopeCore
import SwiftUI

// MARK: - Tableau des sites (tableau standard « reglages.sites », note 28)

/// Ligne du tableau des sites.
struct RegSiteRowData: Identifiable {
    let site: Site
    let isActive: Bool
    let fortiGates: [String]
    let switchCount: Int
    let inventory: Int
    let sharesRanges: Bool

    var id: UUID { site.id }
    var name: String { site.displayName }
    var sortName: String { name.lowercased() }
    var ranges: [String] { site.ranges.map(\.text) }
    var rangesSort: String { site.rangesLabel }
    var fortiGatesSort: String { fortiGates.joined(separator: ", ") }
    var lastScanSort: Date { site.lastScan ?? .distantPast }
    var notes: String { site.notes }
    var hintsLabel: String {
        var parts: [String] = []
        if !site.hints.gatewayMACs.isEmpty { parts.append("MAC \(site.hints.gatewayMACs.map { $0.formatted(.upperColon) }.joined(separator: ", "))") }
        if !site.hints.fortiGateSerials.isEmpty { parts.append(site.hints.fortiGateSerials.joined(separator: ", ")) }
        if !site.hints.fortiGateHostnames.isEmpty { parts.append(site.hints.fortiGateHostnames.joined(separator: ", ")) }
        if let ssid = site.hints.ssid { parts.append("SSID \(ssid)") }
        return parts.joined(separator: " · ")
    }
    var createdSort: Date { site.created }
}

/// Sites : nom (site actif marqué), plages, FortiGate, switchs SNMP, appareils en inventaire,
/// dernier scan. Un clic choisit le site affiché dessous ; double-clic : l'activer.
struct RegSiteTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var inventory = InvModel.shared
    @ObservedObject var table: StandardTableModel<RegSiteRowData>
    @Binding var selection: UUID?
    var onDelete: (Site) -> Void
    var onRename: (Site) -> Void

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "plages", title: "Plages"),
        StandardColumn(id: "fortigate", title: "FortiGate"),
        StandardColumn(id: "switchs", title: "Switchs SNMP"),
        StandardColumn(id: "appareils", title: "Appareils en inventaire"),
        StandardColumn(id: "dernierScan", title: "Dernier scan"),
        StandardColumn(id: "indices", title: "Indices de détection", isDefaultVisible: false),
        StandardColumn(id: "notes", title: "Notes", isDefaultVisible: false),
        StandardColumn(id: "creation", title: "Créé le", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegSiteRowData>] = [
        "nom": KeyPathComparator(\RegSiteRowData.sortName),
        "plages": KeyPathComparator(\RegSiteRowData.rangesSort),
        "fortigate": KeyPathComparator(\RegSiteRowData.fortiGatesSort),
        "switchs": KeyPathComparator(\RegSiteRowData.switchCount),
        "appareils": KeyPathComparator(\RegSiteRowData.inventory),
        "dernierScan": KeyPathComparator(\RegSiteRowData.lastScanSort),
        "indices": KeyPathComparator(\RegSiteRowData.hintsLabel),
        "notes": KeyPathComparator(\RegSiteRowData.notes),
        "creation": KeyPathComparator(\RegSiteRowData.createdSort),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegSiteRowData> {
        StandardTableModel(id: "reglages.sites", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    static let rowHeight: CGFloat = 30

    private var rows: [RegSiteRowData] {
        let fortigate = FortiGateStore.shared
        return sites.sites.map { site in
            RegSiteRowData(site: site, isActive: site.id == sites.activeID,
                           fortiGates: site.fortiGateIDs.compactMap { fortigate.controller($0)?.displayName },
                           switchCount: site.switchHosts.count, inventory: sites.inventoryCount(site),
                           sharesRanges: !sites.list.sharingAddresses(with: site.id).isEmpty)
        }
        .sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isActive ? "mappin.circle.fill" : "mappin")
                            .font(.system(size: 12)).foregroundStyle(row.isActive ? Theme.accent : Theme.textSecondary)
                            .frame(width: 14)
                        Text(row.name).font(.system(size: 12.5, weight: row.isActive ? .semibold : .regular)).lineLimit(1)
                        if row.isActive { Chip(text: "Actif", tone: .accent) }
                    }
                    .frame(height: Self.rowHeight - 8)
                    .help(row.isActive ? "Site actif" : "Double-clic pour activer ce site")
                }
                .width(min: 130, ideal: 170)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("PLAGES", sortUsing: table.sort("plages")) { row in
                    HStack(spacing: 4) {
                        StandardTagList(tags: row.ranges)
                        if row.sharesRanges {
                            Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                .help("Un autre site a des adresses en commun (même plage)\u{00A0}: le site se choisit par la passerelle.")
                        }
                    }
                }
                .width(min: 120, ideal: 200)
                .customizationID("plages")

                TableColumn("FORTIGATE", sortUsing: table.sort("fortigate")) { row in
                    RegSwitchCell(row.fortiGatesSort, secondary: true)
                        .help(row.fortiGates.isEmpty ? "Aucune FortiGate associée\u{00A0}: SNMP seulement" : row.fortiGatesSort)
                }
                .width(min: 80, ideal: 130)
                .customizationID("fortigate")

                TableColumn("SWITCHS", sortUsing: table.sort("switchs")) { row in
                    Text(row.switchCount == 0 ? "—" : "\(row.switchCount)")
                        .font(Theme.mono(12)).foregroundStyle(row.switchCount == 0 ? Theme.textTertiary : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.site.switchHosts.joined(separator: ", "))
                }
                .width(min: 60, ideal: 90)
                .customizationID("switchs")

                TableColumn("APPAREILS", sortUsing: table.sort("appareils")) { row in
                    Text(row.inventory == 0 ? "—" : RegFormat.count(row.inventory))
                        .font(Theme.mono(12)).foregroundStyle(row.inventory == 0 ? Theme.textTertiary : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Fiches de l’inventaire propre à ce site")
                }
                .width(min: 60, ideal: 90)
                .customizationID("appareils")

                TableColumn("DERNIER SCAN", sortUsing: table.sort("dernierScan")) { row in
                    Text(row.site.lastScan.map { ScanFormat.relative($0) } ?? "Jamais")
                        .font(Theme.small)
                        .foregroundStyle(row.site.lastScan == nil ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                .customizationID("dernierScan")
            }
            Group {
                TableColumn("INDICES", sortUsing: table.sort("indices")) { row in
                    RegSwitchCell(row.hintsLabel, mono: true)
                        .help(row.hintsLabel.isEmpty ? "Aucun indice\u{00A0}: «\u{00A0}Détecter mon site\u{00A0}» demandera" : row.hintsLabel)
                }
                .width(min: 100, ideal: 200)
                .customizationID("indices")
                .defaultVisibility(.hidden)

                TableColumn("NOTES", sortUsing: table.sort("notes")) { row in
                    RegSwitchCell(row.notes, secondary: true).help(row.notes)
                }
                .width(min: 80, ideal: 180)
                .customizationID("notes")
                .defaultVisibility(.hidden)

                TableColumn("CRÉÉ LE", sortUsing: table.sort("creation")) { row in
                    RegSwitchCell(row.site.created.formatted(date: .abbreviated, time: .omitted), secondary: true)
                }
                .width(min: 80, ideal: 110)
                .customizationID("creation")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegSiteRowData.ID.self) { ids in
            if let id = ids.first, let site = sites.site(id) {
                if id != sites.activeID {
                    Button("Activer «\u{00A0}\(site.displayName)\u{00A0}»") { sites.activate(id, state: state) }
                    Divider()
                }
                Button("Renommer…") { onRename(site) }
                Button("Dupliquer (sans l’inventaire)") { selection = sites.duplicate(id)?.id }
                Divider()
                Button("Supprimer le site et son inventaire…", role: .destructive) { onDelete(site) }
            }
        } primaryAction: { ids in
            if let id = ids.first { sites.activate(id, state: state) }
        }
        .standardTableHeight(rows: max(rows.count, 1), rowHeight: Self.rowHeight, maxRows: 10, extra: 8)
    }
}
