import NetScopeCore
import SwiftUI

// Note 74 : composants de l'historique du trafic des ports, partagés par Switchs et ports et
// par l'écran Trafic : courbe entrée/sortie sur 1 h à 30 j (avec lecture au survol), choix de la
// période, libellés. Couleurs dynamiques (clair et sombre) : celles des ressources.

/// Choix de la période d'un historique (1 h, 24 h, 7 j, 30 j).
struct PortHistoryRangePicker: View {
    @Binding var range: PortHistoryRange

    var body: some View {
        Picker("Période", selection: $range) {
            ForEach(PortHistoryRange.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Période de l’historique")
    }
}

enum PortHistoryText {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    private static let time = formatter("HH:mm")
    private static let dayTime = formatter("EEE HH:mm")
    private static let day = formatter("EEE d")
    private static let dateTime = formatter("d MMM HH:mm")

    /// Repère de l'axe du temps.
    static func axis(_ date: Date, range: PortHistoryRange) -> String {
        switch range {
        case .hour, .day: return time.string(from: date).replacingOccurrences(of: ":", with: "\u{00A0}h\u{00A0}")
        case .week: return day.string(from: date)
        case .month: return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_CA")))
        }
    }

    /// Début d'une colonne survolée.
    static func column(_ date: Date, range: PortHistoryRange) -> String {
        switch range {
        case .hour: return time.string(from: date).replacingOccurrences(of: ":", with: "\u{00A0}h\u{00A0}")
        case .day: return dayTime.string(from: date).replacingOccurrences(of: ":", with: "\u{00A0}h\u{00A0}")
        case .week, .month: return dateTime.string(from: date).replacingOccurrences(of: ":", with: "\u{00A0}h\u{00A0}")
        }
    }

    /// « 23 h 40 mesurées sur 24 h », « mesure complète ».
    static func coverage(_ stats: PortHistoryStats) -> String {
        guard stats.hasData else { return "aucune mesure" }
        if stats.coverage >= 0.98 { return "mesure complète" }
        return "\(duration(stats.covered)) mesurées sur \(stats.range.label)"
    }

    /// « 45 min », « 3 h 20 », « 5 j 4 h ».
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)\u{00A0}h" : String(format: "%d\u{00A0}h\u{00A0}%02d", hours, minutes % 60) }
        return hours % 24 == 0 ? "\(hours / 24)\u{00A0}j" : "\(hours / 24)\u{00A0}j\u{00A0}\(hours % 24)\u{00A0}h"
    }

    /// « 412 Mb/s (41 %) ».
    static func rate(_ bps: Double, percent: Double?) -> String {
        ResourceFormat.bitsPerSecond(bps) + (percent.map { " (\(ResourceFormat.percent($0)))" } ?? "")
    }
}

/// Courbe entrée/sortie d'un port sur une période : échelle à gauche, repères de temps dessous,
/// valeurs de la colonne survolée.
struct PortHistoryChart: View {
    let curve: PortHistoryCurve
    var speedMbps: UInt64? = nil
    var height: CGFloat = 110
    @State private var hover: Int?

    var body: some View {
        let top = scaleTop
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(0..<3) { index in
                        Text(ResourceFormat.bitsPerSecond(top * Double(2 - index) / 2))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                        if index < 2 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 58, height: height + 8, alignment: .trailing)
                .offset(y: -4)
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack(alignment: .topLeading) {
                        grid(size)
                        area(curve.inValues, top: top, size: size).fill(ResourceColors.primary.opacity(0.16))
                        line(curve.inValues, top: top, size: size)
                            .stroke(ResourceColors.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        line(curve.outValues, top: top, size: size)
                            .stroke(ResourceColors.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        if let hover { hoverMark(hover, top: top, size: size) }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let count = curve.inValues.count
                            guard count > 0, size.width > 0 else { return }
                            hover = min(count - 1, max(0, Int(point.x / size.width * CGFloat(count))))
                        case .ended:
                            hover = nil
                        }
                    }
                }
                .frame(height: height)
            }
            HStack {
                Text(PortHistoryText.axis(curve.start, range: curve.range))
                Spacer()
                Text(PortHistoryText.axis(curve.start.addingTimeInterval(curve.end.timeIntervalSince(curve.start) / 2), range: curve.range))
                Spacer()
                Text("maintenant")
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 64)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Débit du port sur \(curve.range.phrase)")
    }

    /// Haut de l'échelle : le maximum arrondi vers le haut (1, 2, 5 × 10ⁿ).
    private var scaleTop: Double {
        let peak = (curve.inValues + curve.outValues).compactMap { $0 }.max() ?? 0
        guard peak > 0 else { return 1000 }
        let magnitude = pow(10, floor(log10(peak)))
        for factor in [1.0, 2, 5, 10] where peak <= factor * magnitude { return factor * magnitude }
        return 10 * magnitude
    }

    private func x(_ index: Int, _ size: CGSize) -> CGFloat {
        let count = max(curve.inValues.count, 1)
        return (CGFloat(index) + 0.5) / CGFloat(count) * size.width
    }

    private func y(_ value: Double, top: Double, _ size: CGSize) -> CGFloat {
        size.height - CGFloat(min(max(value, 0), top) / max(top, 1)) * size.height
    }

    private func grid(_ size: CGSize) -> some View {
        Path { path in
            for index in 0...4 {
                let y = size.height * CGFloat(index) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(ResourceColors.grid, lineWidth: 1)
    }

    private func line(_ values: [Double?], top: Double, size: CGSize) -> Path {
        Path { path in
            for run in Sparkline.runs(values) {
                guard let first = run.first else { continue }
                path.move(to: CGPoint(x: x(first.0, size), y: y(first.1, top: top, size)))
                if run.count == 1 { path.addLine(to: CGPoint(x: x(first.0, size) + 1, y: y(first.1, top: top, size))) }
                for (index, value) in run.dropFirst() { path.addLine(to: CGPoint(x: x(index, size), y: y(value, top: top, size))) }
            }
        }
    }

    private func area(_ values: [Double?], top: Double, size: CGSize) -> Path {
        Path { path in
            for run in Sparkline.runs(values) {
                guard let first = run.first, let last = run.last else { continue }
                path.move(to: CGPoint(x: x(first.0, size), y: size.height))
                for (index, value) in run { path.addLine(to: CGPoint(x: x(index, size), y: y(value, top: top, size))) }
                path.addLine(to: CGPoint(x: x(last.0, size), y: size.height))
                path.closeSubpath()
            }
        }
    }

    private func hoverMark(_ index: Int, top: Double, size: CGSize) -> some View {
        let at = x(index, size)
        let start = curve.start.addingTimeInterval(Double(index) * curve.range.step)
        let inValue = curve.inValues.indices.contains(index) ? curve.inValues[index] : nil
        let outValue = curve.outValues.indices.contains(index) ? curve.outValues[index] : nil
        let percent: (Double?) -> String = { value in
            ResourceMath.linkPercent(bitsPerSecond: value, speedMbps: speedMbps).map { " · \(ResourceFormat.percent($0))" } ?? ""
        }
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: at, y: 0))
                path.addLine(to: CGPoint(x: at, y: size.height))
            }
            .stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            VStack(alignment: .leading, spacing: 2) {
                Text(PortHistoryText.column(start, range: curve.range)).font(Theme.captionSemibold)
                if inValue == nil && outValue == nil {
                    Text("aucune mesure").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("↓\u{00A0}\(ResourceFormat.bitsPerSecond(inValue))\(percent(inValue))").font(Theme.mono(10))
                    Text("↑\u{00A0}\(ResourceFormat.bitsPerSecond(outValue))\(percent(outValue))").font(Theme.mono(10))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Theme.panel).shadow(color: .black.opacity(0.15), radius: 3))
            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(Theme.border))
            .fixedSize()
            .offset(x: at > size.width * 0.6 ? at - 128 : at + 6, y: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Erreurs par heure, colorées selon les seuils (20/h : à surveiller, 200/h : alerte).
struct PortErrorRateText: View {
    let rate: Double?
    let errors: UInt64

    var body: some View {
        let perHour = rate ?? 0
        let level = perHour >= PortErrorRate.warningThreshold ? 2 : (perHour >= PortErrorRate.adviceThreshold && errors >= 5 ? 1 : 0)
        Text(PortErrorRate.label(rate))
            .font(Theme.mono(12, weight: level > 0 ? .semibold : .regular))
            .foregroundStyle(level >= 2 ? Theme.critical : level == 1 ? Theme.warning : (errors > 0 ? Theme.text : Theme.textTertiary))
    }
}
