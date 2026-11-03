import Charts
import NetScopeCore
import SwiftUI

/// Onglet Historique : évolution sur 30 jours et tests enregistrés.
struct SpeedHistoryView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel

    var body: some View {
        VStack(spacing: 14) {
            evolutionPanel
            tablePanel
        }
    }

    // MARK: Évolution

    private var recentInternet: [SpeedTestRecord] {
        let limit = Date().addingTimeInterval(-30 * 86_400)
        return model.history.filter { $0.kind == .internet && $0.date >= limit }.sorted { $0.date < $1.date }
    }

    private var evolutionPanel: some View {
        let records = recentInternet
        let top = SpeedMath.gaugeScale(for: max(records.map(\.downMbps).max() ?? 0, model.planDown ?? 0))
        let dip = records.min { $0.downMbps < $1.downMbps }
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SectionHeader("Évolution sur 30 jours · Internet").fixedSize()
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
                                    Circle().strokeBorder(Theme.warning, lineWidth: 2).background(Circle().fill(.white))
                                        .frame(width: 9, height: 9)
                                }
                                .annotation(position: .bottom, spacing: 4) {
                                    Text("\(dip.interfaceLabel)").font(.system(size: 10)).foregroundStyle(Color(hex: 0x9A3412))
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

    private var tablePanel: some View {
        let all = model.history
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionHeader("Tests enregistrés").fixedSize().padding(.trailing, 6)
                FilterChip(title: "Tous", count: all.count, isSelected: model.historyFilter == nil) { model.historyFilter = nil }
                FilterChip(title: "Internet", count: all.filter { $0.kind == .internet }.count,
                           isSelected: model.historyFilter == .internet) { model.historyFilter = .internet }
                FilterChip(title: "Réseau local", count: all.filter { $0.kind == .lan }.count,
                           isSelected: model.historyFilter == .lan) { model.historyFilter = .lan }
                Spacer()
                Button {
                    model.exportCSV()
                } label: {
                    Label("Exporter CSV", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.secondary)
                .speedDisabled(model.filteredHistory.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            TableHeader(columns: Self.columns)
            let rows = Array(model.filteredHistory.prefix(200))
            if rows.isEmpty {
                Text("Aucun test enregistré.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(20)
            }
            ForEach(rows) { record in row(record) }

            HStack(spacing: 12) {
                Toggle("", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Planifier un test toutes les heures").font(Theme.bodySemibold)
                        Chip(text: "Bientôt", tone: .neutral)
                    }
                    Text("Les tests planifiés passeront par l’écran Surveillance et s’ajouteront à cet historique.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    state.open(.surveillance)
                } label: {
                    Label("Ouvrir Surveillance", systemImage: "arrow.right").labelStyle(SpeedTrailingIconLabelStyle())
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

    private static let columns: [TableHeader.Column] = [
        .init(title: "Date / heure", width: 190),
        .init(title: "Type", width: 170),
        .init(title: "Serveur"),
        .init(title: "Interface", width: 140),
        .init(title: "Descente", width: 110, alignment: .trailing),
        .init(title: "Montée", width: 100, alignment: .trailing),
        .init(title: "Latence", width: 90, alignment: .trailing),
        .init(title: "Gigue", width: 90, alignment: .trailing),
    ]

    private func row(_ record: SpeedTestRecord) -> some View {
        let plan = record.kind == .internet ? model.planDown : nil
        let low = plan.map { record.downMbps < $0 * SpeedMath.planThreshold } ?? false
        let isLan = record.kind == .lan
        return HStack(spacing: 0) {
            Text(SpeedFormat.dateTime.string(from: record.date)).font(Theme.mono(12))
                .padding(.horizontal, 8).frame(width: 190, alignment: .leading)
            HStack(spacing: 6) {
                Text(record.kind.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLan ? Theme.neutralText : Theme.accentStrong)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(isLan ? Theme.neutralSoft : speedDownSoft))
                Text(record.origin).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8).frame(width: 170, alignment: .leading)
            Text(record.server).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            Text(record.interfaceLabel).font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
                .padding(.horizontal, 8).frame(width: 140, alignment: .leading)
            Text("\(SpeedFormat.rate(record.downMbps)) Mb/s").font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(low ? Theme.warning : Theme.text)
                .padding(.horizontal, 8).frame(width: 110, alignment: .trailing)
            Text(record.upMbps.map { "\(SpeedFormat.rate($0)) Mb/s" } ?? "—").font(Theme.mono(12))
                .padding(.horizontal, 8).frame(width: 100, alignment: .trailing)
            Text(record.latencyMs.map { "\(SpeedFormat.latency($0)) ms" } ?? "—").font(Theme.mono(12))
                .padding(.horizontal, 8).frame(width: 90, alignment: .trailing)
            Text(record.jitterMs.map { "\(SpeedFormat.number($0, digits: $0 < 1 ? 2 : 1)) ms" } ?? "—").font(Theme.mono(12))
                .padding(.horizontal, 8).frame(width: 90, alignment: .trailing)
        }
        .frame(height: 34)
        .background(record.id == model.freshRecordID ? Theme.accentSoft : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
