import NetScopeCore
import SwiftUI

/// Courbe des appareils en ligne, d'après les instantanés de scan de la période.
struct AnaOnlineChart: View {
    let snapshots: [InvSnapshot]
    let period: AnaPeriod

    var body: some View {
        let values = snapshots.map { Double($0.onlineCount) }
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                InvPanelTitle(title: "Appareils en ligne",
                              subtitle: "\(snapshots.count) scan\(snapshots.count > 1 ? "s" : "") · \(period.span)") {
                    if let peak = values.max(), let low = values.min() {
                        HStack(spacing: 10) {
                            stat("Pic", Int(peak))
                            stat("Min", Int(low))
                            stat("Moy.", Int((values.reduce(0, +) / Double(values.count)).rounded()))
                        }
                    }
                }
                if snapshots.count < 2 {
                    Text("Pas encore assez de scans sur la période pour tracer une courbe : chaque scan qui change le résultat ajoute un point.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else {
                    chart(values)
                        .frame(height: 150)
                    HStack {
                        Text(label(snapshots.first!.date))
                        Spacer()
                        Text(label(snapshots.last!.date))
                    }
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Text("\(value)").fontWeight(.semibold).foregroundStyle(Theme.text)
        }
        .font(Theme.small)
    }

    private func label(_ date: Date) -> String {
        period == .jour ? InvFormat.time(date) : InvFormat.stamp(date)
    }

    private func chart(_ values: [Double]) -> some View {
        let dates = snapshots.map(\.date)
        return GeometryReader { geometry in
            let size = geometry.size
            let maxValue = max((values.max() ?? 1) * 1.15, 1)
            let start = dates.first!.timeIntervalSince1970
            let span = max(dates.last!.timeIntervalSince1970 - start, 1)
            let points = zip(dates, values).map { date, value in
                CGPoint(x: CGFloat((date.timeIntervalSince1970 - start) / span) * size.width,
                        y: size.height - CGFloat(value / maxValue) * size.height)
            }
            ZStack(alignment: .topLeading) {
                ForEach(1..<4) { line in
                    let y = size.height * CGFloat(line) / 4
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text("\(Int(maxValue * Double(4 - line) / 4))")
                        .font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
                        .offset(x: 2, y: y - 12)
                }
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                    path.closeSubpath()
                }
                .fill(Theme.accent.opacity(0.12))
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle().fill(index == points.count - 1 ? Theme.accent : Color.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .position(point)
                        .help("\(InvFormat.stamp(dates[index])) : \(Int(values[index])) en ligne")
                }
                if let last = points.last {
                    Text("\(Int(values.last!))").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                        .position(x: min(last.x, size.width - 12), y: max(last.y - 12, 8))
                }
            }
        }
    }
}

/// Répartition des fiches par fabricant (barres) et par type (barre empilée).
struct AnaBreakdownPanel: View {
    let records: [InvRecord]

    private static let typeColors: [(String, [DeviceType], UInt32)] = [
        ("Postes de travail", [.poste], 0x1E3A8A),
        ("Téléphones", [.telephone], 0x2563EB),
        ("IoT / affichage", [.iot], 0x60A5FA),
        ("Points d’accès", [.pointAcces], 0x0F766E),
        ("Imprimantes", [.imprimante], 0x15803D),
        ("Caméras", [.camera], 0xC2410C),
        ("Réseau", [.switch, .routeur], 0x7C3AED),
        ("Serveurs", [.serveur], 0x0891B2),
        ("Inconnu", [.inconnu], 0x9CA3AF),
    ]

    var body: some View {
        let total = max(records.count, 1)
        let vendors = vendorCounts()
        let largest = max(vendors.map(\.1).max() ?? 1, 1)
        let types = Self.typeColors.map { name, kinds, color in
            (name, records.filter { kinds.contains($0.type) }.count, color)
        }.filter { $0.1 > 0 }

        Panel(padding: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    InvPanelTitle("Répartition par fabricant")
                    ForEach(vendors, id: \.0) { name, count in
                        HStack(spacing: 8) {
                            Text(name).font(Theme.small).lineLimit(1).frame(width: 78, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Theme.neutralSoft)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(name == OUIDatabase.unknownLabel ? Color(hex: 0x9CA3AF) : Theme.accent)
                                        .frame(width: geometry.size.width * CGFloat(count) / CGFloat(largest))
                                }
                            }
                            .frame(height: 10)
                            HStack(spacing: 4) {
                                Text("\(count)").font(Theme.mono(11, weight: .semibold))
                                Text("\(Int((Double(count) / Double(total) * 100).rounded())) %")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    InvPanelTitle("Par type d’appareil")
                    GeometryReader { geometry in
                        HStack(spacing: 1) {
                            ForEach(types, id: \.0) { _, count, color in
                                Rectangle().fill(Color(hex: color))
                                    .frame(width: max(geometry.size.width * CGFloat(count) / CGFloat(total) - 1, 2))
                            }
                        }
                    }
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    ForEach(types, id: \.0) { name, count, color in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: color)).frame(width: 10, height: 10)
                            Text(name).font(Theme.small).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(count)").font(Theme.mono(11, weight: .semibold))
                            Text("\(Int((Double(count) / Double(total) * 100).rounded())) %")
                                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Huit premiers fabricants, puis « Autres » et « Inconnu ».
    private func vendorCounts() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        var unknown = 0
        for record in records {
            let label = record.vendorLabel
            if label == OUIDatabase.unknownLabel || label == OUIDatabase.randomizedLabel { unknown += 1 } else { counts[label, default: 0] += 1 }
        }
        let sorted = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var result = Array(sorted.prefix(7)).map { ($0.key, $0.value) }
        let others = sorted.dropFirst(7).map(\.value).reduce(0, +)
        if others > 0 { result.append(("Autres", others)) }
        if unknown > 0 { result.append((OUIDatabase.unknownLabel, unknown)) }
        return result
    }
}
