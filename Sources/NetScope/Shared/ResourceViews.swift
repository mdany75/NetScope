import NetScopeCore
import SwiftUI

// Composants des ressources (note 21) : courbe sur quelques minutes, tuile de mesure, barre
// d'occupation, charge par cœur, choix de l'intervalle. Couleurs dynamiques (clair et sombre).

enum ResourceColors {
    /// Entrée / processeur : couleur d'accent du système.
    static let primary = Theme.accent
    /// Sortie / deuxième série : sarcelle lisible en clair et en sombre.
    static let secondary = Color(light: 0x0F766E, dark: 0x2DD4BF)
    static let grid = Color(light: 0xE5E7EB, dark: 0x3A3A3E)

    /// Couleur d'une charge : normale, élevée (≥ 75 %), critique (≥ 90 %).
    static func load(_ percent: Double?) -> Color {
        guard let percent else { return Theme.neutralDot }
        if percent >= 90 { return Theme.criticalBadge }
        if percent >= 75 { return Theme.warningDot }
        return Theme.accent
    }

    static func tone(_ percent: Double?) -> Tone {
        guard let percent else { return .neutral }
        if percent >= 90 { return .critical }
        if percent >= 75 { return .warning }
        return .success
    }
}

/// Une série d'une courbe.
struct ResourceChartSeries: Identifiable {
    var id: String { label }
    var label: String
    var color: Color
    var values: [Double?]
}

/// Courbe des dernières minutes : quadrillage, échelle à gauche, repères de temps dessous.
struct ResourceChart: View {
    let series: [ResourceChartSeries]
    /// Échelle fixe (100 pour des pourcentages) ; nil : adaptée au maximum.
    var maxValue: Double? = nil
    /// Libellé d'une graduation (« 50 % », « 200 Mb/s »).
    var axisLabel: (Double) -> String
    /// Durée couverte, pour les repères (« −5 min », « maintenant »).
    var span: TimeInterval = 300
    var height: CGFloat = 120
    var filled = true
    /// Ligne de seuil (pourcentage), en pointillés.
    var threshold: Double? = nil

    var body: some View {
        let top = scaleTop
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(0..<3) { index in
                        Text(axisLabel(top * Double(2 - index) / 2))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                        if index < 2 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: height + 8)
                .offset(y: -4)
                ZStack {
                    grid
                    if let threshold, threshold <= top {
                        GeometryReader { proxy in
                            let y = proxy.size.height * (1 - threshold / top)
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }
                            .stroke(Theme.warningDot.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    ForEach(series) { item in
                        ScaledLine(values: item.values, top: top, color: item.color, filled: filled && series.count == 1)
                    }
                }
                .frame(height: height)
            }
            HStack {
                Text("−\(ResourceTime.label(span))")
                Spacer()
                Text("−\(ResourceTime.label(span / 2))")
                Spacer()
                Text("maintenant")
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 40)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map { "\($0.label)\u{00A0}: \($0.values.compactMap { $0 }.last.map(axisLabel) ?? "—")" }.joined(separator: ", "))
    }

    /// Haut de l'échelle : fixe, ou maximum arrondi vers le haut (1, 2, 5 × 10ⁿ).
    private var scaleTop: Double {
        if let maxValue { return maxValue }
        let peak = series.flatMap { $0.values.compactMap { $0 } }.max() ?? 0
        guard peak > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        for factor in [1.0, 2, 5, 10] where peak <= factor * magnitude { return factor * magnitude }
        return 10 * magnitude
    }

    private var grid: some View {
        GeometryReader { proxy in
            Path { path in
                for index in 0...4 {
                    let y = proxy.size.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(ResourceColors.grid, lineWidth: 1)
        }
    }
}

/// Courbe sur une échelle donnée (0 à `top`), trous compris.
private struct ScaledLine: View {
    let values: [Double?]
    let top: Double
    let color: Color
    let filled: Bool

    var body: some View {
        GeometryReader { geometry in
            let stepX = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            let point: (Int, Double) -> CGPoint = { index, value in
                CGPoint(x: CGFloat(index) * stepX,
                        y: geometry.size.height - CGFloat(min(max(value, 0), top) / max(top, 0.0001)) * geometry.size.height)
            }
            ZStack {
                if filled {
                    Path { path in
                        for run in Sparkline.runs(values) {
                            guard let first = run.first, let last = run.last else { continue }
                            path.move(to: CGPoint(x: point(first.0, first.1).x, y: geometry.size.height))
                            for (index, value) in run { path.addLine(to: point(index, value)) }
                            path.addLine(to: CGPoint(x: point(last.0, last.1).x, y: geometry.size.height))
                            path.closeSubpath()
                        }
                    }
                    .fill(color.opacity(0.14))
                }
                Path { path in
                    for run in Sparkline.runs(values) {
                        guard let first = run.first else { continue }
                        path.move(to: point(first.0, first.1))
                        for (index, value) in run.dropFirst() { path.addLine(to: point(index, value)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

enum ResourceTime {
    /// « 5 min », « 2 min 30 s », « 45 s ».
    static func label(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 {
            let minutes = total / 60, rest = total % 60
            return rest == 0 ? "\(minutes)\u{00A0}min" : "\(minutes)\u{00A0}min\u{00A0}\(rest)\u{00A0}s"
        }
        return "\(total)\u{00A0}s"
    }
}

/// Légende d'une courbe : pastille et libellé de chaque série.
struct ResourceLegend: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(item.1).frame(width: 12, height: 3)
                    Text(item.0).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// Barre d'occupation fine (pourcentage), colorée selon la charge.
struct ResourceBar: View {
    let percent: Double?
    var height: CGFloat = 6
    var color: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.neutralSoft)
                Capsule().fill(color ?? ResourceColors.load(percent))
                    .frame(width: proxy.size.width * CGFloat(min(max(percent ?? 0, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .accessibilityValue(ResourceFormat.percent(percent))
    }
}

/// Tuile de mesure : intitulé, grande valeur, précision, petite courbe.
struct ResourceTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var tone: Tone = .neutral
    var spark: [Double?] = []
    var sparkColor: Color = ResourceColors.primary
    var percent: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                if tone != .neutral { Circle().fill(tone.dot).frame(width: 7, height: 7) }
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let percent { ResourceBar(percent: percent) }
            Text(detail.isEmpty ? " " : detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            if spark.count > 1 {
                Sparkline(values: spark, color: sparkColor).frame(height: 28)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Rangée de tuiles de même hauteur (trois colonnes égales).
struct ResourceTileRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            content.frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Charge de chaque cœur : une colonne par cœur, P et E sur Apple silicon.
struct ResourceCoreBars: View {
    let loads: [Double]
    /// Nombre de cœurs de performance (les premiers), pour les étiquettes.
    var performanceCores: Int? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: loads.count > 16 ? 2 : 4) {
            ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                VStack(spacing: 3) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.neutralSoft)
                            RoundedRectangle(cornerRadius: 2).fill(ResourceColors.load(load))
                                .frame(height: proxy.size.height * CGFloat(min(max(load, 0), 100) / 100))
                        }
                    }
                    Text(label(index)).font(Theme.mono(9)).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                }
                .help("Cœur \(index + 1)\(kind(index))\u{00A0}: \(ResourceFormat.percent(load))")
            }
        }
        .frame(height: 64)
    }

    private func label(_ index: Int) -> String {
        guard let performanceCores else { return "\(index + 1)" }
        return index < performanceCores ? "P\(index + 1)" : "E\(index - performanceCores + 1)"
    }

    private func kind(_ index: Int) -> String {
        guard let performanceCores else { return "" }
        return index < performanceCores ? " (performance)" : " (efficacité)"
    }
}

/// Choix de l'intervalle des relevés.
struct ResourceIntervalMenu: View {
    @Binding var interval: Double
    let choices: [Double]

    var body: some View {
        Picker(selection: $interval) {
            ForEach(choices, id: \.self) { seconds in
                Text(ResourceInterval.everyLabel(seconds)).tag(seconds)
            }
        } label: {
            Text("Intervalle")
        }
        .pickerStyle(.menu)
        .font(Theme.small)
        .fixedSize()
        .help("Intervalle entre deux relevés")
    }
}

/// Ligne « clé : valeur » compacte des panneaux de ressources.
struct ResourceKeyValue: View {
    let key: String
    let value: String
    var color: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) }
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
        }
    }
}

/// En-tête d'un panneau de ressources : titre, précision et accessoire à droite.
struct ResourcePanelHeader<Accessory: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
            if !subtitle.isEmpty {
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            accessory
        }
    }
}

extension ResourcePanelHeader where Accessory == EmptyView {
    init(title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Message d'un export : vert en cas de succès, rouge en cas d'échec.
struct ResourceToastText: View {
    let toast: ResourceToast

    var body: some View {
        Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(Theme.small)
            .foregroundStyle(toast.isError ? Theme.critical : Theme.success)
            .fixedSize(horizontal: false, vertical: true)
    }
}
