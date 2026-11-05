import NetScopeCore
import SwiftUI

// Note 74 : tableau standard « Ports les plus chargés » sur une période (1 h à 30 j), d'après
// l'historique des ports. Employé par Switchs et ports (un switch) et par l'écran Trafic (tous les
// switchs des sites montrés, secours quand FortiView n'est pas lu). Double-clic ou ↩︎ : l'appareil
// branché sur le port (note 33).

/// Une ligne : un port et ses chiffres sur la période.
struct PortHistoryRow: Identifiable, Hashable {
    let summary: PortHistorySummary
    var id: String { summary.id }
    var host: String { summary.host }
    var ifIndex: Int { summary.ifIndex }
    var switchName: String { summary.switchName }
    var port: String { summary.name }
    var alias: String { summary.alias }
    var stats: PortHistoryStats { summary.stats }

    // Clés de tri (toujours Comparable).
    var portSort: String { "\(switchName)|\(String(format: "%06d", ifIndex))" }
    var speedSort: Int { Int(stats.speedMbps ?? 0) }
    var inSort: Double { stats.inAverage }
    var outSort: Double { stats.outAverage }
    var peakSort: Double { stats.peakBitsPerSecond }
    var peakPercentSort: Double { stats.peakPercent ?? -1 }
    var averagePercentSort: Double { stats.averagePercent ?? -1 }
    var errorsSort: Double { stats.errorsPerHour ?? -1 }
    var coveredSort: Double { stats.covered }

    var speedText: String { SNMPFormat.speed(mbps: stats.speedMbps) }
}

/// Tableau des ports ; `header` reçoit le menu « Colonnes » à placer dans la barre du panneau.
struct PortHistoryTable<Header: View>: View {
    @EnvironmentObject private var state: AppState
    let rows: [PortHistoryRow]
    /// Colonne « Switch » (plusieurs switchs) ou non.
    let showsSwitch: Bool
    @Binding var selection: String?
    var maxRows = 10
    let header: (StandardColumnsMenu<PortHistoryRow>) -> Header
    @StateObject private var table: StandardTableModel<PortHistoryRow>

    init(id: String, rows: [PortHistoryRow], showsSwitch: Bool, selection: Binding<String?>, maxRows: Int = 10,
         @ViewBuilder header: @escaping (StandardColumnsMenu<PortHistoryRow>) -> Header) {
        self.rows = rows
        self.showsSwitch = showsSwitch
        _selection = selection
        self.maxRows = maxRows
        self.header = header
        _table = StateObject(wrappedValue: StandardTableModel(id: id, columns: showsSwitch ? PortHistoryColumns.siteColumns : PortHistoryColumns.columns,
                                                              sortKeys: PortHistoryColumns.sortKeys, defaultSort: "chargeMax", defaultAscending: false))
    }


    private var rowHeight: CGFloat { 28 }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(spacing: 0) {
            header(StandardColumnsMenu(model: table, compact: true))
            StandardTableHorizontalScroll(minWidth: table.contentWidth(PortHistoryColumns.widths),
                                          height: StandardTableMetrics.height(rows: rows.count, rowHeight: rowHeight, maxRows: maxRows)) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                TableColumn(StandardTableHeading("SWITCH"), sortUsing: table.sort("switch")) { row in
                    Text(row.switchName).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 90, ideal: PortHistoryColumns.widths["switch"])
                .customizationID("switch")
                .defaultVisibility(showsSwitch ? .automatic : .hidden)

                TableColumn(StandardTableHeading("PORT"), sortUsing: table.sort("port")) { row in
                    Text(row.port).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 64, ideal: PortHistoryColumns.widths["port"])
                .customizationID("port")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("DESCRIPTION"), sortUsing: table.sort("description")) { row in
                    Text(row.alias.isEmpty ? "—" : row.alias).font(Theme.small)
                        .foregroundStyle(row.alias.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(row.alias)
                }
                .width(min: 90, ideal: PortHistoryColumns.widths["description"])
                .customizationID("description")

                TableColumn(StandardTableHeading("VITESSE"), sortUsing: table.sort("vitesse")) { row in
                    Text(row.speedText).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .width(min: 54, ideal: PortHistoryColumns.widths["vitesse"])
                .customizationID("vitesse")
                .defaultVisibility(.hidden)
                }

                Group {
                TableColumn(StandardTableHeading("ENTRÉE MOY."), sortUsing: table.sort("entree")) { row in
                    rate(row.stats.inAverage)
                }
                .width(min: 70, ideal: PortHistoryColumns.widths["entree"])
                .customizationID("entree")

                TableColumn(StandardTableHeading("SORTIE MOY."), sortUsing: table.sort("sortie")) { row in
                    rate(row.stats.outAverage)
                }
                .width(min: 70, ideal: PortHistoryColumns.widths["sortie"])
                .customizationID("sortie")

                TableColumn(StandardTableHeading("DÉBIT MAX"), sortUsing: table.sort("max")) { row in
                    rate(row.stats.peakBitsPerSecond)
                }
                .width(min: 70, ideal: PortHistoryColumns.widths["max"])
                .customizationID("max")
                }

                Group {
                TableColumn(StandardTableHeading("CHARGE MAX"), sortUsing: table.sort("chargeMax")) { row in
                    load(row.stats.peakPercent)
                }
                .width(min: 90, ideal: PortHistoryColumns.widths["chargeMax"])
                .customizationID("chargeMax")

                TableColumn(StandardTableHeading("CHARGE MOY."), sortUsing: table.sort("chargeMoy")) { row in
                    load(row.stats.averagePercent)
                }
                .width(min: 90, ideal: PortHistoryColumns.widths["chargeMoy"])
                .customizationID("chargeMoy")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("ERREURS/H"), sortUsing: table.sort("erreurs")) { row in
                    PortErrorRateText(rate: row.stats.errorsPerHour, errors: row.stats.errors)
                        .help("\(ToolFormat.integer(row.stats.errors)) erreurs en entrée sur \(PortHistoryText.duration(row.stats.covered)) mesurées")
                }
                .width(min: 64, ideal: PortHistoryColumns.widths["erreurs"])
                .customizationID("erreurs")

                TableColumn(StandardTableHeading("MESURÉ"), sortUsing: table.sort("mesure")) { row in
                    Text(PortHistoryText.duration(row.stats.covered)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .width(min: 64, ideal: PortHistoryColumns.widths["mesure"])
                .customizationID("mesure")
                .defaultVisibility(.hidden)
                }
            }
            .standardTableStyle()
            .standardRowActions(selection: selection.map { [$0] } ?? [], object: { (id: String) -> NavObject? in
                guard let row = rows.first(where: { $0.id == id }) else { return nil }
                return .port(NavPortRef(host: row.host, ifIndex: row.ifIndex))
            }) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Ouvrir l’appareil branché") { state.perform(.port(NavPortRef(host: row.host, ifIndex: row.ifIndex))) }
                }
            }
            }
        }
    }

    private func rate(_ bps: Double) -> some View {
        Text(ResourceFormat.bitsPerSecond(bps)).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
    }

    private func load(_ percent: Double?) -> some View {
        HStack(spacing: 6) {
            ResourceBar(percent: percent, height: 5, color: ResourceColors.load(percent))
                .frame(width: 36)
            Text(ResourceFormat.percent(percent))
                .font(Theme.mono(12, weight: (percent ?? 0) >= 75 ? .semibold : .regular))
                .foregroundStyle(ResourceColors.tone(percent) == .success ? Theme.text : ResourceColors.tone(percent).foreground)
                .lineLimit(1)
        }
    }
}

/// Colonnes et clés de tri du tableau des ports.
enum PortHistoryColumns {
    /// Largeur idéale de chaque colonne (défilement horizontal quand le panneau est plus étroit).
    static let widths: [String: CGFloat] = ["switch": 110, "port": 76, "description": 140, "vitesse": 60, "entree": 80,
                                            "sortie": 80, "max": 80, "chargeMax": 100, "chargeMoy": 100, "erreurs": 70, "mesure": 70]

    static let columns: [StandardColumn] = [
        StandardColumn(id: "port", title: "Port", isRequired: true),
        StandardColumn(id: "description", title: "Description"),
        StandardColumn(id: "vitesse", title: "Vitesse", isDefaultVisible: false),
        StandardColumn(id: "entree", title: "Entrée moyenne"),
        StandardColumn(id: "sortie", title: "Sortie moyenne"),
        StandardColumn(id: "max", title: "Débit max"),
        StandardColumn(id: "chargeMax", title: "Charge max"),
        StandardColumn(id: "chargeMoy", title: "Charge moyenne", isDefaultVisible: false),
        StandardColumn(id: "erreurs", title: "Erreurs par heure"),
        StandardColumn(id: "mesure", title: "Durée mesurée", isDefaultVisible: false),
    ]

    static let siteColumns: [StandardColumn] = [StandardColumn(id: "switch", title: "Switch", isRequired: true)] + columns

    static let sortKeys: [String: KeyPathComparator<PortHistoryRow>] = [
        "switch": KeyPathComparator(\PortHistoryRow.portSort),
        "port": KeyPathComparator(\PortHistoryRow.portSort),
        "description": KeyPathComparator(\PortHistoryRow.alias),
        "vitesse": KeyPathComparator(\PortHistoryRow.speedSort),
        "entree": KeyPathComparator(\PortHistoryRow.inSort),
        "sortie": KeyPathComparator(\PortHistoryRow.outSort),
        "max": KeyPathComparator(\PortHistoryRow.peakSort),
        "chargeMax": KeyPathComparator(\PortHistoryRow.peakPercentSort),
        "chargeMoy": KeyPathComparator(\PortHistoryRow.averagePercentSort),
        "erreurs": KeyPathComparator(\PortHistoryRow.errorsSort),
        "mesure": KeyPathComparator(\PortHistoryRow.coveredSort),
    ]
}
