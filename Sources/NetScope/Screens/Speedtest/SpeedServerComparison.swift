import NetScopeCore
import SwiftUI

/// Historique › Comparaison par serveur (note 16) : moyennes des tests de chaque serveur, en
/// tableau standard, avec une barre de descente relative au meilleur serveur.
struct SpeedServerComparisonPanel: View {
    @ObservedObject var model: SpeedtestModel
    @StateObject private var table = StandardTableModel<SpeedServerStatsLine>(
        id: "speedtest.comparaison", columns: SpeedServerComparisonPanel.columns,
        sortKeys: SpeedServerComparisonPanel.sortKeys, defaultSort: "ordre")

    var body: some View {
        let stats = SpeedServerStats.compute(model.history, kind: model.historyFilter)
        let top = SpeedMath.gaugeScale(for: stats.map(\.averageDown).max() ?? 0)
        let rows = stats.enumerated().map { SpeedServerStatsLine(stats: $1, order: $0, scale: top) }
            .sorted(using: table.sortOrder)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionHeader("Comparaison par serveur").fixedSize()
                Text(summary(stats)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                StandardColumnsMenu(model: table)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if rows.isEmpty {
                Text("Aucun test à comparer.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(20)
            } else {
                SpeedComparisonTable(rows: rows, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: 30, maxRows: 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func summary(_ stats: [SpeedServerStats]) -> String {
        guard let best = stats.filter({ $0.kind == .internet }).max(by: { $0.averageDown < $1.averageDown }) else {
            return stats.isEmpty ? "" : "\(stats.count) serveurs"
        }
        return "\(stats.count) serveurs · meilleure moyenne : \(best.server) (\(SpeedFormat.rate(best.averageDown)) Mb/s)"
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "serveur", title: "Serveur", isRequired: true),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "tests", title: "Tests"),
        StandardColumn(id: "descente", title: "Descente moyenne"),
        StandardColumn(id: "montee", title: "Montée moyenne"),
        StandardColumn(id: "latence", title: "Latence moyenne"),
        StandardColumn(id: "meilleure", title: "Meilleure descente", isDefaultVisible: false),
        StandardColumn(id: "dernier", title: "Dernier test"),
    ]

    static let sortKeys: [String: KeyPathComparator<SpeedServerStatsLine>] = [
        "ordre": KeyPathComparator(\SpeedServerStatsLine.order),
        "serveur": KeyPathComparator(\SpeedServerStatsLine.sortServer),
        "source": KeyPathComparator(\SpeedServerStatsLine.sortSource),
        "tests": KeyPathComparator(\SpeedServerStatsLine.sortCount),
        "descente": KeyPathComparator(\SpeedServerStatsLine.sortDown),
        "montee": KeyPathComparator(\SpeedServerStatsLine.sortUp),
        "latence": KeyPathComparator(\SpeedServerStatsLine.sortLatency),
        "meilleure": KeyPathComparator(\SpeedServerStatsLine.sortBest),
        "dernier": KeyPathComparator(\SpeedServerStatsLine.sortLast),
    ]
}

/// Ligne de la comparaison, avec ses clés de tri.
struct SpeedServerStatsLine: Identifiable {
    let stats: SpeedServerStats
    let order: Int
    /// Échelle des barres (Mb/s).
    let scale: Double

    var id: String { stats.id }
    var sortServer: String { stats.server }
    var sortSource: String { stats.source }
    var sortCount: Int { stats.count }
    var sortDown: Double { stats.averageDown }
    var sortUp: Double { stats.averageUp ?? -1 }
    var sortLatency: Double { stats.averageLatency ?? .greatestFiniteMagnitude }
    var sortBest: Double { stats.bestDown }
    var sortLast: Date { stats.lastDate }
}

private struct SpeedComparisonTable: View {
    let rows: [SpeedServerStatsLine]
    @ObservedObject var table: StandardTableModel<SpeedServerStatsLine>
    @State private var selection: Set<String> = []

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("SERVEUR"), sortUsing: table.sort("serveur")) { line in
                Text(line.stats.server).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .help(line.stats.server)
            }
            .width(min: 140, ideal: 240)
            .customizationID("serveur")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("SOURCE"), sortUsing: table.sort("source")) { line in
                Text(line.stats.source).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
            }
            .width(min: 70, ideal: 90)
            .customizationID("source")

            TableColumn(StandardTableHeading("TESTS"), sortUsing: table.sort("tests")) { line in
                Text("\(line.stats.count)").font(Theme.mono(12)).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 56)
            .customizationID("tests")

            TableColumn(StandardTableHeading("DESCENTE MOY."), sortUsing: table.sort("descente")) { line in
                HStack(spacing: 8) {
                    SpeedBar(fraction: line.stats.averageDown / max(line.scale, 1), color: Theme.accent, height: 6)
                        .frame(minWidth: 40)
                    Text("\(SpeedFormat.rate(line.stats.averageDown)) Mb/s").font(Theme.mono(12, weight: .semibold))
                        .fixedSize()
                }
            }
            .width(min: 140, ideal: 200)
            .customizationID("descente")

            TableColumn(StandardTableHeading("MONTÉE MOY."), sortUsing: table.sort("montee")) { line in
                number(line.stats.averageUp.map { "\(SpeedFormat.rate($0)) Mb/s" })
            }
            .width(min: 80, ideal: 100)
            .customizationID("montee")

            TableColumn(StandardTableHeading("LATENCE MOY."), sortUsing: table.sort("latence")) { line in
                number(line.stats.averageLatency.map { "\(SpeedFormat.latency($0)) ms" })
            }
            .width(min: 70, ideal: 90)
            .customizationID("latence")

            TableColumn(StandardTableHeading("MEILLEURE"), sortUsing: table.sort("meilleure")) { line in
                number("\(SpeedFormat.rate(line.stats.bestDown)) Mb/s")
            }
            .width(min: 80, ideal: 96)
            .customizationID("meilleure")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("DERNIER TEST"), sortUsing: table.sort("dernier")) { line in
                Text(SpeedFormat.dateTime.string(from: line.stats.lastDate)).font(Theme.mono(12)).foregroundStyle(Theme.neutralText)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 150)
            .customizationID("dernier")
        }
        .standardTableStyle()
    }

    private func number(_ text: String?) -> some View {
        Text(text ?? "—").font(Theme.mono(12)).foregroundStyle(text == nil ? Theme.textTertiary : Theme.text)
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
    }
}
