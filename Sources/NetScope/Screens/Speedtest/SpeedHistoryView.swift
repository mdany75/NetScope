import Charts
import NetScopeCore
import SwiftUI

/// Onglet Historique : évolution sur 30 jours et tests enregistrés.
struct SpeedHistoryView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel
    @StateObject private var table = StandardTableModel<SpeedHistoryLine>(
        id: "speedtest.historique", columns: SpeedHistoryView.columns, sortKeys: SpeedHistoryView.sortKeys,
        defaultSort: "ordre")

    var body: some View {
        VStack(spacing: 14) {
            evolutionPanel
            SpeedServerComparisonPanel(model: model)
            tablePanel
        }
    }

    // MARK: Évolution

    /// Tests Internet des 30 derniers jours du site actif (note 78 : les tests faits sur un autre
    /// site ne se mélangent pas à la courbe ; les anciens tests, sans site, restent).
    private var recentInternet: [SpeedTestRecord] {
        let limit = Date().addingTimeInterval(-30 * 86_400)
        let site = SiteModel.shared.activeID
        return model.history.filter { $0.kind == .internet && $0.date >= limit && ($0.siteID == nil || $0.siteID == site) }
            .sorted { $0.date < $1.date }
    }

    private var evolutionTitle: String {
        guard let name = SiteModel.shared.activeSite?.displayName else { return "Évolution sur 30 jours · Internet" }
        return "Évolution sur 30 jours · Internet · \(name)"
    }

    private var evolutionPanel: some View {
        let records = recentInternet
        let top = SpeedMath.gaugeScale(for: max(records.map(\.downMbps).max() ?? 0, model.planDown ?? 0))
        let dip = records.min { $0.downMbps < $1.downMbps }
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SectionHeader(evolutionTitle).fixedSize()
                    legend("Descente", color: Theme.accent)
                    legend("Montée", color: speedUpColor)
                    legend("Forfait", color: Color(hex: 0x9CA3AF), dashed: true)
                    Spacer()
                    Text(evolutionSummary(records)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                }
                if records.isEmpty {
                    Text("Aucun test Internet ces 30 derniers jours.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    Chart {
                        ForEach(records) { record in
                            LineMark(x: .value("Date", record.date), y: .value("Mb/s", record.downMbps),
                                     series: .value("Sens", "Descente"))
                                .foregroundStyle(Theme.accent)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                            if let up = record.upMbps {
                                LineMark(x: .value("Date", record.date), y: .value("Mb/s", up),
                                         series: .value("Sens", "Montée"))
                                    .foregroundStyle(speedUpColor)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                            }
                        }
                        if let plan = model.planDown {
                            RuleMark(y: .value("Forfait descente", plan))
                                .foregroundStyle(Color(hex: 0x9CA3AF))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        }
                        if let plan = model.planUp {
                            RuleMark(y: .value("Forfait montée", plan))
                                .foregroundStyle(Color(hex: 0x9CA3AF))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        }
                        if let dip, records.count > 2 {
                            PointMark(x: .value("Date", dip.date), y: .value("Mb/s", dip.downMbps))
                                .symbol {
                                    Circle().strokeBorder(Theme.warning, lineWidth: 2).background(Circle().fill(Theme.panel))
                                        .frame(width: 9, height: 9)
                                }
                                .annotation(position: .bottom, spacing: 4) {
                                    Text("\(dip.interfaceLabel)").font(.system(size: 10)).foregroundStyle(Color(light: 0x9A3412, dark: 0xF2AA91))
                                }
                        }
                    }
                    .chartYScale(domain: 0...top)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                            AxisGridLine().foregroundStyle(Theme.neutralSoft)
                            AxisValueLabel {
                                if let mbps = value.as(Double.self) {
                                    Text(SpeedFormat.integer(mbps)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(SpeedFormat.shortDay.string(from: date)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 190)
                }
            }
        }
    }

    private func legend(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 14, height: 2)
            Text(label).font(Theme.small).foregroundStyle(Theme.neutralText)
        }
        .fixedSize()
    }

    private func evolutionSummary(_ records: [SpeedTestRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let down = records.map(\.downMbps)
        let ups = records.compactMap(\.upMbps)
        let averageDown = down.reduce(0, +) / Double(down.count)
        var text = "\(records.count) tests · moy. \(SpeedFormat.integer(averageDown))"
        if !ups.isEmpty { text += " / \(SpeedFormat.integer(ups.reduce(0, +) / Double(ups.count)))" }
        return text + " Mb/s · min. \(SpeedFormat.integer(down.min() ?? 0))"
    }

    // MARK: Tableau

    /// Filtres natifs (contrôle segmenté) : « Tous 32 », « Internet 20 », « Réseau local 12 ».
    private func historyFilterPicker(_ all: [SpeedTestRecord]) -> some View {
        Picker("Filtre de l’historique", selection: $model.historyFilter) {
            Text("Tous \(all.count)").tag(SpeedTestKind?.none)
            Text("Internet \(all.filter { $0.kind == .internet }.count)").tag(SpeedTestKind?.some(.internet))
            Text("Réseau local \(all.filter { $0.kind == .lan }.count)").tag(SpeedTestKind?.some(.lan))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var historyTools: some View {
        HStack(spacing: 8) {
            Button {
                model.exportCSV()
            } label: {
                Label("Exporter CSV", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondary)
            .speedDisabled(model.filteredHistory.isEmpty)
            StandardColumnsMenu(model: table)
        }
    }

    private var tablePanel: some View {
        let all = model.history
        return VStack(spacing: 0) {
            // Une ligne, ou deux en petite fenêtre (au lieu d'élargir l'écran).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    SectionHeader("Tests enregistrés").fixedSize().padding(.trailing, 6)
                    historyFilterPicker(all)
                    Spacer()
                    historyTools
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SectionHeader("Tests enregistrés").fixedSize().padding(.trailing, 6)
                        historyFilterPicker(all)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        historyTools
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            let rows = Array(model.filteredHistory.prefix(200)).enumerated()
                .map { SpeedHistoryLine(record: $1, order: $0) }
                .sorted(using: table.sortOrder)
            if rows.isEmpty {
                Text("Aucun test enregistré.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(20)
            } else {
                SpeedHistoryTable(rows: rows, model: model, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.visibleRows)
            }

            HStack(spacing: 12) {
                let schedule = SpeedScheduleStore.shared.schedule(for: SiteModel.shared.activeID)
                Image(systemName: "calendar.badge.clock").font(.system(size: 16)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.isEnabled ? "Test planifié chaque jour à \(schedule.time.text)" : "Aucun test planifié pour ce site")
                        .font(Theme.bodySemibold)
                    Text("Un test par jour et par site, avec seuil d’alerte et courbe sur 30 jours (onglet Planifié).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    model.tab = .planifie
                } label: {
                    Label("Régler la planification", systemImage: "arrow.right").labelStyle(SpeedTrailingIconLabelStyle())
                }
                .buttonStyle(.ghost)
            }
            .padding(12)
            .background(Theme.panelMuted)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }


    // MARK: Colonnes

    /// Ligne du croquis : 34 ; au-delà de `visibleRows` tests, le tableau défile.
    static let rowHeight: CGFloat = 34
    static let visibleRows = 12

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date / heure", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "serveur", title: "Serveur"),
        StandardColumn(id: "interface", title: "Interface"),
        StandardColumn(id: "descente", title: "Descente"),
        StandardColumn(id: "montee", title: "Montée"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "gigue", title: "Gigue"),
        StandardColumn(id: "latenceCharge", title: "Latence en charge", isDefaultVisible: false),
        StandardColumn(id: "flux", title: "Flux", isDefaultVisible: false),
        StandardColumn(id: "origine", title: "Origine", isDefaultVisible: false),
        StandardColumn(id: "source", title: "Source", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    /// « ordre » : ordre de l'historique (le plus récent d'abord), sans colonne. Les débits et
    /// latences se trient en nombres, pas en texte.
    static let sortKeys: [String: KeyPathComparator<SpeedHistoryLine>] = [
        "ordre": KeyPathComparator(\SpeedHistoryLine.order),
        "date": KeyPathComparator(\SpeedHistoryLine.sortDate),
        "type": KeyPathComparator(\SpeedHistoryLine.sortKind),
        "serveur": KeyPathComparator(\SpeedHistoryLine.sortServer),
        "interface": KeyPathComparator(\SpeedHistoryLine.sortInterface),
        "descente": KeyPathComparator(\SpeedHistoryLine.sortDown),
        "montee": KeyPathComparator(\SpeedHistoryLine.sortUp),
        "latence": KeyPathComparator(\SpeedHistoryLine.sortLatency),
        "gigue": KeyPathComparator(\SpeedHistoryLine.sortJitter),
        "latenceCharge": KeyPathComparator(\SpeedHistoryLine.sortLoadedLatency),
        "flux": KeyPathComparator(\SpeedHistoryLine.sortStreams),
        "origine": KeyPathComparator(\SpeedHistoryLine.sortOrigin),
        "source": KeyPathComparator(\SpeedHistoryLine.sortSource),
        "site": KeyPathComparator(\SpeedHistoryLine.sortSite),
    ]
}

/// Une ligne de l'historique des tests, avec ses clés de tri.
struct SpeedHistoryLine: Identifiable {
    let record: SpeedTestRecord
    /// Rang dans l'historique (le plus récent d'abord) : tri par défaut.
    let order: Int

    var id: UUID { record.id }

    // Une valeur absente passe après les autres en ordre croissant.
    var sortDate: Date { record.date }
    var sortKind: String { record.kind.label }
    var sortServer: String { record.server }
    var sortInterface: String { record.interfaceLabel }
    var sortDown: Double { record.downMbps }
    var sortUp: Double { record.upMbps ?? -1 }
    var sortLatency: Double { record.latencyMs ?? .greatestFiniteMagnitude }
    var sortJitter: Double { record.jitterMs ?? .greatestFiniteMagnitude }
    var sortLoadedLatency: Double { record.loadedLatencyMs ?? .greatestFiniteMagnitude }
    var sortStreams: Int { record.streams }
    var sortOrigin: String { record.origin }
    var sortSource: String { record.sourceLabel }
    var sortSite: String { record.siteName ?? "" }
}

/// Tableau des tests enregistrés : le test qui vient de se terminer est sélectionné.
private struct SpeedHistoryTable: View {
    let rows: [SpeedHistoryLine]
    @ObservedObject var model: SpeedtestModel
    @ObservedObject var table: StandardTableModel<SpeedHistoryLine>
    @State private var selection: Set<UUID> = []

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("DATE / HEURE"), sortUsing: table.sort("date")) { line in
                    Text(SpeedFormat.dateTime.string(from: line.record.date))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(height: 26)
                }
                .width(min: 140, ideal: 150)
                .customizationID("date")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("TYPE"), sortUsing: table.sort("type")) { line in
                    let isLan = line.record.kind == .lan
                    HStack(spacing: 6) {
                        Text(line.record.kind.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isLan ? Theme.neutralText : Theme.accentStrong)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(isLan ? Theme.neutralSoft : speedDownSoft))
                            .fixedSize()
                        Text(line.record.origin).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 150)
                .customizationID("type")

                TableColumn(StandardTableHeading("SERVEUR"), sortUsing: table.sort("serveur")) { line in
                    Text(line.record.server).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                        .help(line.record.server)
                }
                .width(min: 120, ideal: 200)
                .customizationID("serveur")

                TableColumn(StandardTableHeading("INTERFACE"), sortUsing: table.sort("interface")) { line in
                    Text(line.record.interfaceLabel).font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
                }
                .width(min: 100, ideal: 130)
                .customizationID("interface")

                TableColumn(StandardTableHeading("DESCENTE"), sortUsing: table.sort("descente")) { line in
                    // Le forfait est celui du site actif : un test fait sur un autre site n'y est pas comparé.
                    let sameSite = line.record.siteID == nil || line.record.siteID == SiteModel.shared.activeID
                    let plan = line.record.kind == .internet && sameSite ? model.planDown : nil
                    let low = plan.map { line.record.downMbps < $0 * SpeedMath.planThreshold } ?? false
                    SpeedNumberCell("\(SpeedFormat.rate(line.record.downMbps)) Mb/s", bold: true,
                                    color: low ? Theme.warning : Theme.text)
                        .help(low ? "Sous le seuil du forfait" : "")
                }
                .width(min: 90, ideal: 104)
                .customizationID("descente")

                TableColumn(StandardTableHeading("MONTÉE"), sortUsing: table.sort("montee")) { line in
                    SpeedNumberCell(line.record.upMbps.map { "\(SpeedFormat.rate($0)) Mb/s" } ?? "—")
                }
                .width(min: 80, ideal: 96)
                .customizationID("montee")

                TableColumn(StandardTableHeading("LATENCE"), sortUsing: table.sort("latence")) { line in
                    SpeedNumberCell(line.record.latencyMs.map { "\(SpeedFormat.latency($0)) ms" } ?? "—")
                }
                .width(min: 66, ideal: 80)
                .customizationID("latence")

                TableColumn(StandardTableHeading("GIGUE"), sortUsing: table.sort("gigue")) { line in
                    SpeedNumberCell(line.record.jitterMs.map { "\(SpeedFormat.number($0, digits: $0 < 1 ? 2 : 1)) ms" } ?? "—")
                }
                .width(min: 60, ideal: 80)
                .customizationID("gigue")
            }

            Group {
                TableColumn(StandardTableHeading("LATENCE EN CHARGE"), sortUsing: table.sort("latenceCharge")) { line in
                    SpeedNumberCell(line.record.loadedLatencyMs.map { "\(SpeedFormat.latency($0)) ms" } ?? "—")
                        .help("Latence mesurée pendant le transfert")
                }
                .width(min: 90, ideal: 130)
                .customizationID("latenceCharge")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("FLUX"), sortUsing: table.sort("flux")) { line in
                    SpeedNumberCell("\(line.record.streams)")
                        .help("Connexions parallèles du test")
                }
                .width(min: 44, ideal: 56)
                .customizationID("flux")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("ORIGINE"), sortUsing: table.sort("origine")) { line in
                    Text(line.record.origin.prefix(1).uppercased() + line.record.origin.dropFirst())
                        .font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                }
                .width(min: 70, ideal: 90)
                .customizationID("origine")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("SOURCE"), sortUsing: table.sort("source")) { line in
                    Text(line.record.sourceLabel).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                }
                .width(min: 70, ideal: 90)
                .customizationID("source")
                .defaultVisibility(.hidden)

                // Note 78 : site actif au moment du test (tests planifiés par site).
                TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { line in
                    Text(line.record.siteName ?? "—").font(Theme.small)
                        .foregroundStyle(line.record.siteName == nil ? Theme.textTertiary : Theme.neutralText).lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                .customizationID("site")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .onAppear { selection = model.freshRecordID.map { [$0] } ?? [] }
        .onChange(of: model.freshRecordID) { _, id in selection = id.map { [$0] } ?? [] }
    }
}

/// Valeur numérique alignée à droite (police mono, 12 pt).
private struct SpeedNumberCell: View {
    let text: String
    var bold = false
    var color: Color = Theme.text

    init(_ text: String, bold: Bool = false, color: Color = Theme.text) {
        self.text = text
        self.bold = bold
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(12, weight: bold ? .semibold : .regular))
            .foregroundStyle(text == "—" ? Theme.textTertiary : color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
