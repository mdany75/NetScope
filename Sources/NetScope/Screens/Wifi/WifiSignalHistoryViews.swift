import NetScopeCore
import SwiftUI

/// Note 78 : signal de la connexion sur 2 minutes à 1 heure (relevé local toutes les 2 s, écran
/// ouvert ; toutes les 10 s sinon). Bande min–max et moyenne par tranche, changements de borne en
/// pointillés, coupures sans connexion laissées vides.
struct WifiSignalHistoryPanel: View {
    @ObservedObject var store: WifiStore
    @AppStorage("NetScope.wifi.historique") private var savedSpan = WifiSignalSpan.tenMinutes.rawValue
    @State private var span: WifiSignalSpan = WifiSurveyDemo.snapshotSpan ?? .tenMinutes

    var body: some View {
        let now = Date()
        let stats = store.timeline.stats(span.seconds, now: now)
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        WifiHeading("Historique du signal").fixedSize()
                        Spacer(minLength: 4)
                        spanPicker
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        WifiHeading("Historique du signal")
                        spanPicker
                    }
                }
                if stats == nil {
                    Text("Aucune mesure sur cette durée (relevé local toutes les 2\u{00A0}s quand l’écran est ouvert).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    WifiSignalChart(timeline: store.timeline, span: span, now: now)
                    if let stats { summary(stats, now: now) }
                }
            }
        }
        .onAppear {
            if WifiSurveyDemo.snapshotSpan == nil, !RegEnvironment.isSnapshot, let saved = WifiSignalSpan(rawValue: savedSpan) { span = saved }
        }
        .onChange(of: span) { _, value in if !RegEnvironment.isSnapshot { savedSpan = value.rawValue } }
    }

    private var spanPicker: some View {
        Picker("Durée", selection: $span) {
            ForEach(WifiSignalSpan.allCases) { s in Text(s.label).tag(s) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .help("Durée affichée (l’historique garde une heure au plus)")
    }

    private func summary(_ stats: WifiSignalTimeline.Stats, now: Date) -> some View {
        let covered = store.timeline.coveredSeconds(now: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 9, height: 9)
                Text("moy.\u{00A0}\(WifiQuality.dbm(stats.average))").font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(WifiText.qualityColor(stats.average).foreground)
                Spacer(minLength: 4)
                Text("min \(stats.minimum) · max \(stats.maximum)").font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
            }
            Text(details(stats, covered: covered)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func details(_ stats: WifiSignalTimeline.Stats, covered: TimeInterval) -> String {
        var parts: [String] = []
        parts.append(stats.roams == 0 ? "aucun changement de borne"
                     : "\(stats.roams) changement\(stats.roams > 1 ? "s" : "") de borne")
        if stats.weakPercent > 0 { parts.append("\(stats.weakPercent)\u{00A0}% du temps sous \u{2212}70\u{00A0}dBm") }
        if stats.disconnected > 0 { parts.append("\(stats.disconnected) relevé\(stats.disconnected > 1 ? "s" : "") sans connexion") }
        if let noise = stats.averageNoise { parts.append("bruit \(WifiQuality.dbm(noise))") }
        var text = parts.joined(separator: " · ").capitalizedFirst
        if covered + 30 < span.seconds {
            text += ". Historique depuis \(Self.duration(covered)) (il commence à l’ouverture de l’écran Wi-Fi)."
        }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 1 ? "moins d’une minute" : "\(minutes)\u{00A0}min"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Graphe du signal : moyenne par tranche (trait), minimum–maximum (bande pâle), changements de borne.
struct WifiSignalChart: View {
    let timeline: WifiSignalTimeline
    let span: WifiSignalSpan
    let now: Date

    var body: some View {
        let buckets = timeline.drawableBuckets(span.seconds, now: now, count: span.bucketCount)
        let roams = timeline.roamTimes(span.seconds, now: now)
        Canvas { context, size in
            let left: CGFloat = 30, right = size.width - 4, top: CGFloat = 8, bottom = size.height - 18
            func y(_ rssi: Double) -> CGFloat { top + CGFloat((-40 - max(-90, min(-40, rssi))) / 50) * (bottom - top) }
            func x(_ date: Date) -> CGFloat {
                left + CGFloat(1 - now.timeIntervalSince(date) / span.seconds) * (right - left)
            }
            let labelColor = Theme.textSecondary
            for level in [-50, -60, -70, -80] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(Double(level))))
                line.addLine(to: CGPoint(x: right, y: y(Double(level))))
                context.stroke(line, with: .color(level == -70 ? Theme.warning.opacity(0.45) : Theme.border),
                               style: StrokeStyle(lineWidth: 1, dash: level == -70 ? [3, 3] : []))
                context.draw(Text("\u{2212}\(abs(level))").font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                             at: CGPoint(x: left - 4, y: y(Double(level))), anchor: .trailing)
            }
            let step = (right - left) / CGFloat(max(1, buckets.count))
            // Bande minimum–maximum, tranche par tranche.
            for (k, bucket) in buckets.enumerated() {
                guard let lo = bucket.minimum, let hi = bucket.maximum, hi > lo else { continue }
                let rect = CGRect(x: left + CGFloat(k) * step, y: y(Double(hi)), width: step + 0.5, height: y(Double(lo)) - y(Double(hi)))
                context.fill(Path(rect), with: .color(Theme.accent.opacity(0.16)))
            }
            // Changements de borne.
            for time in roams {
                var mark = Path()
                mark.move(to: CGPoint(x: x(time), y: top))
                mark.addLine(to: CGPoint(x: x(time), y: bottom))
                context.stroke(mark, with: .color(Theme.textTertiary), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            // Moyenne, coupée là où il n'y a ni relevé ni connexion.
            var path = Path()
            var drawing = false
            for (k, bucket) in buckets.enumerated() {
                guard let value = bucket.average else { drawing = false; continue }
                let point = CGPoint(x: left + (CGFloat(k) + 0.5) * step, y: y(value))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            var axis = Path()
            axis.move(to: CGPoint(x: left, y: bottom))
            axis.addLine(to: CGPoint(x: right, y: bottom))
            context.stroke(axis, with: .color(Theme.borderStrong), lineWidth: 1)
            let labels = span.axisLabels
            context.draw(Text(labels.start).font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: left, y: bottom + 9), anchor: .leading)
            context.draw(Text(labels.middle).font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: (left + right) / 2, y: bottom + 9))
            context.draw(Text("maintenant").font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: right, y: bottom + 9), anchor: .trailing)
        }
        .frame(height: 146)
        .accessibilityElement()
        .accessibilityLabel("Graphe du signal sur \(span.label)")
    }
}
