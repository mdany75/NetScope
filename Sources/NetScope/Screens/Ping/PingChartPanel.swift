import Charts
import NetScopeCore
import SwiftUI

/// Grand graphe de la cible sélectionnée : 120 dernières mesures, moyenne, seuil d'alerte et
/// zones de perte en rouge (Swift Charts).
struct PingChartPanel: View {
    let target: PingTarget
    let interval: TimeInterval

    private struct Point: Identifiable {
        let index: Int
        let value: Double
        let run: Int
        var id: Int { index }
    }

    private struct Zone: Identifiable {
        let start: Int
        let end: Int
        var id: Int { start }
    }

    private static let window = PingController.chartWindow
    private static let niceSteps: [Double] = [2, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 200, 500, 1000, 2000, 5000]

    var body: some View {
        let values = target.history.values(last: Self.window)
        let stats = PingStatistics(values: values)
        let offset = Self.window - values.count
        let (points, zones) = Self.series(values, offset: offset)
        let top = Self.niceSteps.first { $0 >= (stats.max ?? 3.5) * 1.15 } ?? 10_000
        let status = target.status

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(target.name).font(Theme.panelTitle).foregroundStyle(Theme.text).lineLimit(1)
                Text(target.addressLabel).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                PingStatusPill(text: status.label, tone: status.tone)
                Spacer(minLength: 8)
                Text(meta)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                PingStatTile(label: "Actuel", value: currentText)
                PingStatTile(label: "Min", value: PingFormat.decimal(stats.min))
                PingStatTile(label: "Moy", value: PingFormat.decimal(stats.average))
                PingStatTile(label: "Max", value: PingFormat.decimal(stats.max))
                PingStatTile(label: "Jitter", value: PingFormat.decimal(stats.jitter))
                PingStatTile(label: "P95", value: PingFormat.decimal(stats.p95))
                PingStatTile(label: "Perte", value: PingFormat.percent(stats.lossPercent), color: pingLossColor(stats.lossPercent))
            }

            Chart {
                ForEach(zones) { zone in
                    RectangleMark(xStart: .value("Début", Double(zone.start) - 0.5),
                                  xEnd: .value("Fin", Double(zone.end) + 0.5),
                                  yStart: .value("Bas", 0), yEnd: .value("Haut", top))
                        .foregroundStyle(Theme.criticalSoft)
                    RectangleMark(xStart: .value("Début", Double(zone.start) - 0.5),
                                  xEnd: .value("Fin", Double(zone.end) + 0.5),
                                  yStart: .value("Bas", top * 0.985), yEnd: .value("Haut", top))
                        .foregroundStyle(Theme.critical)
                }
                ForEach(points) { point in
                    AreaMark(x: .value("Mesure", point.index), yStart: .value("Zéro", 0), yEnd: .value("Latence", point.value),
                             series: .value("Segment", point.run))
                        .foregroundStyle(Theme.accent.opacity(0.08))
                        .interpolationMethod(.linear)
                }
                ForEach(points) { point in
                    LineMark(x: .value("Mesure", point.index), y: .value("Latence", point.value),
                             series: .value("Segment", point.run))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                if let average = stats.average {
                    RuleMark(y: .value("Moyenne", average))
                        .foregroundStyle(Theme.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                if target.thresholdMs < top {
                    RuleMark(y: .value("Seuil", target.thresholdMs))
                        .foregroundStyle(Theme.warning)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("seuil \(PingFormat.decimal(target.thresholdMs, digits: 0)) ms")
                                .font(Theme.captionSemibold)
                                .foregroundStyle(Theme.warning)
                                .padding(.horizontal, 4)
                                .background(Theme.panel)
                        }
                }
            }
            .chartXScale(domain: 0...Double(Self.window - 1))
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: Self.xTicks) { value in
                    AxisValueLabel(anchor: value.index == 4 ? .topTrailing : value.index == 0 ? .topLeading : .top) {
                        Text(xLabel(value.index))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, top / 4, top / 2, top * 0.75, top]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(value.index == 2 ? Theme.border : Theme.neutralSoft)
                    AxisValueLabel {
                        Text(Self.yLabel(value.as(Double.self) ?? 0))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        }
                        .stroke(Theme.borderStrong, lineWidth: 1)
                    }
                }
            }
            .frame(height: 220)
            .accessibilityLabel(chartAccessibility(stats))

            HStack(spacing: 16) {
                legend { Rectangle().fill(Theme.accent).frame(width: 16, height: 2) } label: { "Latence (ms)" }
                legend { dashed(Theme.textSecondary, dash: [2, 3]) } label: { "Moyenne" }
                legend { dashed(Theme.warning, dash: [6, 4]) } label: { "Seuil d’alerte" }
                legend {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.criticalSoft)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.critical).frame(height: 2) }
                        .frame(width: 12, height: 10)
                } label: { "Paquets perdus · \(zones.count) \(zones.count > 1 ? "épisodes" : "épisode")" }
            }
            .padding(.leading, 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var meta: String {
        let role = target.role.isEmpty ? "" : "\(target.role) · "
        return "\(role)envoyés \(target.history.totalSent) · reçus \(target.history.totalReceived) · fenêtre \(PingFormat.duration(Double(Self.window) * interval))"
    }

    private var currentText: String {
        guard let last = target.history.last else { return "—" }
        return last.rttMs.map(PingFormat.ms) ?? "perdu"
    }

    /// Graduations : début, quarts, maintenant.
    private static let xTicks: [Double] = (0...4).map { Double(window - 1) * Double($0) / 4 }

    private func xLabel(_ tick: Int) -> String {
        let remaining = Double(Self.window) * interval * Double(4 - tick) / 4
        return tick >= 4 ? "maintenant" : "−" + PingFormat.duration(remaining)
    }

    private static func yLabel(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.01 ? "\(Int(value.rounded()))" : PingFormat.decimal(value)
    }

    /// Points regroupés en segments continus (interrompus par les pertes) et zones de perte.
    private static func series(_ values: [Double?], offset: Int) -> ([Point], [Zone]) {
        var points: [Point] = []
        var zones: [Zone] = []
        var run = 0
        var zoneStart: Int?
        for (position, value) in values.enumerated() {
            let index = offset + position
            if let value {
                if let start = zoneStart {
                    zones.append(Zone(start: start, end: index - 1))
                    zoneStart = nil
                    run += 1
                }
                points.append(Point(index: index, value: value, run: run))
            } else if zoneStart == nil {
                zoneStart = index
            }
        }
        if let start = zoneStart { zones.append(Zone(start: start, end: offset + values.count - 1)) }
        return (points, zones)
    }

    private func chartAccessibility(_ stats: PingStatistics) -> String {
        "Latence vers \(target.addressLabel) : moyenne \(PingFormat.ms(stats.average)), maximum \(PingFormat.ms(stats.max)), perte \(PingFormat.percent(stats.lossPercent))"
    }

    private func legend<Swatch: View>(@ViewBuilder _ swatch: () -> Swatch, label: () -> String) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(label()).font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private func dashed(_ color: Color, dash: [CGFloat]) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 16, y: 1))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
        .frame(width: 16, height: 2)
    }
}
