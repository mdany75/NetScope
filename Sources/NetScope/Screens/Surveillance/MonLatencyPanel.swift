import Charts
import NetScopeCore
import SwiftUI

/// Note 78 : graphe de latence de la sonde choisie, sur 24 h (tranches de 10 minutes) ou 7 jours
/// (par heure) : latence moyenne, écart minimum–maximum, échecs en rouge et fenêtres de maintenance
/// en bleu. Les données viennent de l'historique de la Surveillance (MonHistory) : rien n'est mesuré ici.
struct MonLatencyPanel: View {
    @ObservedObject private var store = MonStore.shared
    @State private var range: MonLatencyRange = MonPlanningDemo.latencyRange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let probe = store.selectedProbe {
                content(probe)
            } else {
                MonHeading("Latence")
                Text("Choisissez une sonde pour voir sa latence sur 24\u{00A0}h ou 7\u{00A0}jours.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monPanel()
    }

    @ViewBuilder private func content(_ probe: MonProbe) -> some View {
        let now = store.now
        let points = store.history.latencySeries(probe: probe.id, range: range, now: now)
        let summary = MonHistory.latencySummary(points)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MonHeading("Latence")
            Text(probe.name)
                .font(Theme.bodySemibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Picker("Durée", selection: $range) {
                ForEach(MonLatencyRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Latence sur les dernières 24\u{00A0}heures (par 10 minutes) ou les 7 derniers jours (par heure)")
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { stats(summary, points: points) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) { stats(summary, points: points).prefix }
                HStack(spacing: 14) { stats(summary, points: points).suffix }
            }
        }
        if points.allSatisfy({ $0.average == nil }) && summary.failures == 0 {
            Text(points.allSatisfy { $0.checks == 0 }
                 ? "Aucune vérification sur cette durée. Le graphe se remplit à chaque vérification (historique gardé 7\u{00A0}jours, et 90\u{00A0}jours par jour pour les rapports)."
                 : "Cette sonde ne mesure pas de latence (\(probe.kind.shortLabel))\u{00A0}: seule sa disponibilité est suivie.")
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            MonLatencyChart(points: points, range: range, now: now, limit: probe.thresholds.latencyMs)
                .frame(minHeight: 150, maxHeight: .infinity)
            legend(limit: probe.thresholds.latencyMs)
        }
        longAvailability(probe, now: now)
    }

    /// Notes 62 et 78 : disponibilité des 30 derniers jours, une case par jour, et des 90 jours gardés.
    @ViewBuilder private func longAvailability(_ probe: MonProbe, now: Date) -> some View {
        let days = store.history.dailyAvailability(probe: probe.id, days: 30, end: now)
        let month = store.history.dayBuckets(probe: probe.id, from: days.first?.day ?? now, to: now)
        let quarter = store.history.dayBuckets(probe: probe.id, from: now.addingTimeInterval(-89 * 86_400), to: now)
        Divider().padding(.vertical, 2)
        HStack(spacing: 8) {
            Text("30 derniers jours").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            HStack(spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MonLatencyPanel.dayColor(day.percent))
                        .frame(height: 14)
                        .help(MonLatencyPanel.dayHelp(day.day, day.percent))
                }
            }
            .frame(maxWidth: .infinity)
            Text(MonLatencyPanel.percent(month)).font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1).fixedSize()
        }
        Text("Disponibilité sur 90\u{00A0}jours\u{00A0}: \(MonLatencyPanel.percent(quarter)) · hors ligne \(MonLatencyPanel.downtime(quarter)) · maintenance écartée. Section «\u{00A0}Disponibilité\u{00A0}» des Rapports.")
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func dayColor(_ percent: Double?) -> Color {
        guard let percent else { return Theme.border }
        if percent >= 99.9 { return Theme.success }
        if percent >= 95 { return Theme.warning }
        return Theme.critical
    }

    static func dayHelp(_ day: Date, _ percent: Double?) -> String {
        let label = MonJournal.longDate(day)
        return label + "\u{00A0}: " + (percent.map { ToolFormat.decimal($0, digits: 2) + "\u{00A0}%" } ?? "aucune vérification")
    }

    static func percent(_ buckets: [MonDayBucket]) -> String {
        let total = buckets.reduce(0) { $0 + $1.total }
        guard total > 0 else { return "—" }
        let value = Double(total - buckets.reduce(0) { $0 + $1.failures }) / Double(total) * 100
        if value >= 100 { return "100\u{00A0}%" }
        return ToolFormat.decimal(min(value, 99.99), digits: 2) + "\u{00A0}%"
    }

    static func downtime(_ buckets: [MonDayBucket]) -> String {
        MonStore.duration(buckets.reduce(0) { $0 + $1.downSeconds })
    }

    private func stats(_ summary: (average: Double?, p95: Double?, maximum: Double?, failures: Int), points: [MonLatencyPoint]) -> MonStatRow {
        let maintenance = points.filter(\.maintenance).count
        let step = range == .day ? 10 : 60
        return MonStatRow(items: [
            ("Moyenne", summary.average.map(ToolFormat.milliseconds) ?? "—", Theme.text),
            ("95e centile", summary.p95.map(ToolFormat.milliseconds) ?? "—", Theme.text),
            ("Maximum", summary.maximum.map(ToolFormat.milliseconds) ?? "—", Theme.text),
            ("Échecs", "\(summary.failures)", summary.failures > 0 ? Theme.critical : Theme.text),
            ("Maintenance", maintenance > 0 ? MonMaintenanceWindow.durationLabel(maintenance * step) : "—",
             maintenance > 0 ? Theme.accentStrong : Theme.text),
        ])
    }

    private func legend(limit: Double?) -> some View {
        HStack(spacing: 14) {
            item(Theme.accent, "Moyenne")
            item(Theme.accent.opacity(0.25), "Minimum – maximum")
            item(Theme.critical.opacity(0.55), "Échec")
            item(MonUptimeBar.maintenanceColor, "Maintenance")
            if let limit {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.warning).frame(width: 12, height: 1.5)
                    Text("Seuil \(MonFormat.number(limit))\u{00A0}ms")
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

/// Chiffres du graphe (« Moyenne 3,4 ms »), coupables en deux lignes en petite fenêtre.
struct MonStatRow: View {
    let items: [(String, String, Color)]

    var prefix: MonStatRow { MonStatRow(items: Array(items.prefix(3))) }
    var suffix: MonStatRow { MonStatRow(items: Array(items.dropFirst(3))) }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            HStack(spacing: 4) {
                Text(item.0).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Text(item.1).font(Theme.mono(12)).foregroundStyle(item.2)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// Le graphe : bande minimum–maximum, moyenne, échecs et maintenance.
struct MonLatencyChart: View {
    let points: [MonLatencyPoint]
    let range: MonLatencyRange
    let now: Date
    let limit: Double?

    /// Suites de points avec une moyenne (une suite = une série, pour couper la ligne aux trous).
    private var runs: [(id: Int, points: [MonLatencyPoint])] {
        var result: [(Int, [MonLatencyPoint])] = []
        var current: [MonLatencyPoint] = []
        for point in points {
            if point.average == nil {
                if !current.isEmpty { result.append((result.count, current)) }
                current = []
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { result.append((result.count, current)) }
        return result
    }

    private var top: Double {
        let highest = points.compactMap { $0.maximum ?? $0.average }.max() ?? 1
        // Le maximum d'un pic isolé ne doit pas écraser le reste : plafond au double du 95e centile.
        let p95 = MonHistory.latencySummary(points).p95 ?? highest
        return max(1, min(highest, p95 * 2.2), (limit ?? 0) * 1.1) * 1.08
    }

    var body: some View {
        let step = range.step
        let ceiling = top
        Chart {
            ForEach(points.filter { $0.maintenance }) { point in
                RectangleMark(xStart: .value("Début", point.start), xEnd: .value("Fin", point.start.addingTimeInterval(step)),
                              yStart: .value("Bas", 0), yEnd: .value("Haut", ceiling))
                    .foregroundStyle(MonUptimeBar.maintenanceColor.opacity(0.5))
            }
            ForEach(points.filter { $0.failures > 0 && $0.checks > 0 }) { point in
                RectangleMark(xStart: .value("Début", point.start), xEnd: .value("Fin", point.start.addingTimeInterval(step)),
                              yStart: .value("Bas", 0),
                              yEnd: .value("Haut", ceiling * min(1, 0.25 + Double(point.failures) / Double(max(1, point.checks)) * 0.75)))
                    .foregroundStyle(Theme.critical.opacity(0.45))
            }
            ForEach(runs, id: \.id) { run in
                ForEach(run.points) { point in
                    AreaMark(x: .value("Heure", point.start.addingTimeInterval(step / 2)),
                             yStart: .value("Minimum", min(ceiling, point.minimum ?? point.average ?? 0)),
                             yEnd: .value("Maximum", min(ceiling, point.maximum ?? point.average ?? 0)),
                             series: .value("Suite", "b\(run.id)"))
                        .foregroundStyle(Theme.accent.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Heure", point.start.addingTimeInterval(step / 2)),
                             y: .value("Latence", min(ceiling, point.average ?? 0)),
                             series: .value("Suite", "m\(run.id)"))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let limit {
                RuleMark(y: .value("Seuil", limit))
                    .foregroundStyle(Theme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: (points.first?.start ?? now)...(points.last.map { $0.start.addingTimeInterval(step) } ?? now))
        .chartYScale(domain: 0...ceiling)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.neutralSoft)
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(MonLatencyChart.axisLabel(ms)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            if range == .day {
                AxisMarks(values: dayTicks) { value in
                    AxisGridLine().foregroundStyle(Theme.neutralSoft)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text("\(Calendar.current.component(.hour, from: date))\u{00A0}h")
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisGridLine().foregroundStyle(Theme.neutralSoft)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(MonLatencyChart.dayLabel(date)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Latence de la sonde sur \(range.label)")
    }

    /// Heures rondes multiples de 3 dans le graphe de 24 h, sans la dernière heure (étiquette coupée).
    private var dayTicks: [Date] {
        guard let first = points.first?.start, let last = points.last?.start else { return [] }
        let calendar = Calendar.current
        var tick = calendar.dateInterval(of: .hour, for: first)?.end ?? first
        var result: [Date] = []
        while tick < last.addingTimeInterval(-3_600) {
            if calendar.component(.hour, from: tick) % 3 == 0 { result.append(tick) }
            tick = tick.addingTimeInterval(3_600)
        }
        return result
    }

    /// « 0 ms », « 2,5 ms », « 180 ms ».
    static func axisLabel(_ ms: Double) -> String {
        (ms < 10 && ms != ms.rounded() ? ToolFormat.decimal(ms) : String(Int(ms.rounded()))) + "\u{00A0}ms"
    }

    /// « lun. 2 ».
    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return MonBusinessHours.shortNames[(weekday - 1 + 7) % 7] + " \(calendar.component(.day, from: date))"
    }
}
