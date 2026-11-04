import NetScopeCore
import SwiftUI

/// Couleurs et textes communs de l'analyseur Wi-Fi.
enum WifiText {
    static let palette: [UInt32] = [0x2563EB, 0x15803D, 0x7C3AED, 0xC2410C, 0x0E7490, 0xB91C1C, 0xA16207, 0xBE185D,
                                    0x4338CA, 0x047857, 0x9333EA, 0x0369A1, 0x4D7C0F, 0x374151, 0x9A3412]
    /// Même palette, éclaircie pour rester lisible sur fond sombre (mêmes teintes, dans le même ordre).
    static let darkPalette: [UInt32] = [0x60A5FA, 0x4ADE80, 0xA78BFA, 0xFB923C, 0x22D3EE, 0xF87171, 0xFACC15, 0xF472B6,
                                        0x818CF8, 0x34D399, 0xC084FC, 0x38BDF8, 0xA3E635, 0xD1D5DB, 0xFDBA74]

    static func color(of network: WifiNetwork, in networks: [WifiNetwork]) -> Color {
        let index = networks.firstIndex { $0.id == network.id } ?? 0
        return Color(light: palette[index % palette.count], dark: darkPalette[index % darkPalette.count])
    }

    static func qualityColor(_ rssi: Int) -> (foreground: Color, background: Color) {
        switch WifiQuality(rssi: rssi) {
        case .bon: return (Theme.success, Theme.successSoft)
        case .moyen: return (Theme.warning, Theme.warningSoft)
        case .faible: return (Theme.critical, Theme.criticalSoft)
        }
    }

    static func vendor(_ network: WifiNetwork) -> String {
        guard let bssid = network.bssid else { return "—" }
        if let vendor = OUIDatabase.builtIn.vendor(for: bssid) { return vendor }
        // Les points d'accès dérivent souvent leurs BSSID secondaires d'une adresse administrée localement.
        if bssid.isLocallyAdministered {
            var bytes = bssid.bytes
            bytes[0] &= ~0x02
            if let vendor = OUIDatabase.builtIn.vendor(for: MACAddress(bytes: bytes)) { return vendor }
            return "Inconnu (adresse locale)"
        }
        return OUIDatabase.unknownLabel
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func timeSeconds(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Bornes du bloc de canaux en 5 GHz (« 36–48 »).
    static func block(_ network: WifiNetwork) -> String? {
        guard network.band == .ghz5, network.widthMHz > 20 else { return nil }
        let span = WifiChannelLayout.span(of: network)
        let first = Int((span.center - span.half + 0.5).rounded())
        let last = Int((span.center + span.half - 0.5).rounded())
        let list = WifiChannelLayout.channels5
        guard first >= 0, last < list.count else { return nil }
        return "\(list[first])–\(list[last])"
    }
}

/// Graphe d'occupation des canaux : une cloche par réseau, hauteur selon le RSSI.
struct WifiChannelGraph: View {
    let networks: [WifiNetwork]
    let all: [WifiNetwork]
    let band: WifiBand
    let selectedID: String?
    let noise: Int?
    let label: (WifiNetwork) -> String

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 44, right = size.width - 8, top: CGFloat = 12, bottom: CGFloat = size.height - 36
            let axis = WifiChannelLayout.axis(band)
            func x(_ unit: Double) -> CGFloat { left + CGFloat((unit - axis.lowerBound) / (axis.upperBound - axis.lowerBound)) * (right - left) }
            func y(_ rssi: Int) -> CGFloat { top + CGFloat(Double(-30 - max(-95, min(-30, rssi))) / 65) * (bottom - top) }
            let labelColor = Color(light: 0x4B5563, dark: 0xB9C0CA)

            if band == .ghz5 {
                let range = WifiChannelLayout.dfsRange5
                let rect = CGRect(x: x(range.lowerBound), y: top, width: x(range.upperBound) - x(range.lowerBound), height: bottom - top)
                context.fill(Path(rect), with: .color(Color(light: 0xF3F4F6, dark: 0x2E333D)))
                context.draw(Text("Canaux DFS (52–144)").font(.system(size: 10)).foregroundStyle(labelColor),
                             at: CGPoint(x: rect.midX, y: top + 10))
            }
            for level in [-40, -50, -60, -70, -80, -90] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(level)))
                line.addLine(to: CGPoint(x: right, y: y(level)))
                context.stroke(line, with: .color(Theme.border), lineWidth: 1)
                context.draw(Text("\u{2212}\(abs(level))").font(.system(size: 10, design: .monospaced)).foregroundStyle(labelColor),
                             at: CGPoint(x: left - 6, y: y(level)), anchor: .trailing)
            }
            if let noise {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(noise)))
                line.addLine(to: CGPoint(x: right, y: y(noise)))
                context.stroke(line, with: .color(Color(hex: 0x6B7280)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                context.draw(Text("Bruit \(WifiQuality.dbm(noise))").font(.system(size: 10)).foregroundStyle(labelColor),
                             at: CGPoint(x: right - 2, y: y(noise) - 3), anchor: .bottomTrailing)
            }

            // Le réseau sélectionné est dessiné en dernier, par-dessus les autres.
            let order = networks.sorted { $0.rssi > $1.rssi }
            let drawn = order.filter { $0.id != selectedID } + order.filter { $0.id == selectedID }
            for network in drawn {
                let span = WifiChannelLayout.span(of: network)
                let x0 = x(span.center - span.half), x1 = x(span.center + span.half)
                let yt = y(network.rssi)
                let slope = min(16, (x1 - x0) * 0.22)
                var bell = Path()
                bell.move(to: CGPoint(x: x0, y: bottom))
                bell.addCurve(to: CGPoint(x: x0 + slope, y: yt), control1: CGPoint(x: x0 + slope * 0.6, y: bottom),
                              control2: CGPoint(x: x0 + slope * 0.4, y: yt))
                bell.addLine(to: CGPoint(x: x1 - slope, y: yt))
                bell.addCurve(to: CGPoint(x: x1, y: bottom), control1: CGPoint(x: x1 - slope * 0.4, y: yt),
                              control2: CGPoint(x: x1 - slope * 0.6, y: bottom))
                bell.closeSubpath()
                let isSelected = network.id == selectedID
                let color = WifiText.color(of: network, in: all)
                context.fill(bell, with: .color(color.opacity(isSelected ? 0.30 : 0.08)))
                context.stroke(bell, with: .color(color.opacity(isSelected ? 1 : (selectedID == nil ? 0.85 : 0.55))),
                               lineWidth: isSelected ? 2.4 : 1.3)
            }

            // Étiquettes : le plus fort de chaque position, et le réseau sélectionné.
            var strongest: [Double: WifiNetwork] = [:]
            for network in networks {
                let center = WifiChannelLayout.span(of: network).center
                if (strongest[center]?.rssi ?? -200) < network.rssi { strongest[center] = network }
            }
            for network in networks where network.id == selectedID || strongest[WifiChannelLayout.span(of: network).center]?.id == network.id {
                let center = WifiChannelLayout.span(of: network).center
                var labelY = y(network.rssi) - 6
                if network.id == selectedID, strongest[center]?.id != network.id { labelY = y(network.rssi) + 12 }
                let name = network.isHidden ? "(caché)" : label(network)
                context.draw(Text("\(name) \u{2212}\(abs(network.rssi))").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(WifiText.color(of: network, in: all)),
                             at: CGPoint(x: x(center), y: max(top + 9, labelY)), anchor: .bottom)
            }

            var axisLine = Path()
            axisLine.move(to: CGPoint(x: left, y: bottom))
            axisLine.addLine(to: CGPoint(x: right, y: bottom))
            context.stroke(axisLine, with: .color(Color(hex: 0x9CA3AF)), lineWidth: 1)
            for tick in WifiChannelLayout.ticks(band) {
                var mark = Path()
                mark.move(to: CGPoint(x: x(tick.position), y: bottom))
                mark.addLine(to: CGPoint(x: x(tick.position), y: bottom + 4))
                context.stroke(mark, with: .color(Color(hex: 0x9CA3AF)), lineWidth: 1)
                context.draw(Text(tick.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(labelColor),
                             at: CGPoint(x: x(tick.position), y: bottom + 14))
            }
            context.draw(Text("Canal").font(.system(size: 10)).foregroundStyle(labelColor),
                         at: CGPoint(x: (left + right) / 2, y: bottom + 28))
            context.draw(Text("dBm").font(.system(size: 10)).foregroundStyle(labelColor), at: CGPoint(x: 6, y: 4), anchor: .topLeading)
        }
        .frame(height: 196)
    }
}

/// RSSI de la connexion sur les 2 dernières minutes.
struct WifiHistoryChart: View {
    let values: [Int?]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 30, right = size.width - 4, top: CGFloat = 8, bottom = size.height - 18
            func y(_ rssi: Int) -> CGFloat { top + CGFloat(Double(-40 - max(-90, min(-40, rssi))) / 50) * (bottom - top) }
            let labelColor = Color(light: 0x4B5563, dark: 0xB9C0CA)
            for level in [-50, -60, -70, -80] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(level)))
                line.addLine(to: CGPoint(x: right, y: y(level)))
                context.stroke(line, with: .color(Theme.border), lineWidth: 1)
                context.draw(Text("\u{2212}\(abs(level))").font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                             at: CGPoint(x: left - 4, y: y(level)), anchor: .trailing)
            }
            let count = WifiStore.historyLength
            let step = (right - left) / CGFloat(count - 1)
            let offset = count - values.count
            var path = Path()
            var drawing = false
            for (k, value) in values.enumerated() {
                guard let value else { drawing = false; continue }
                let point = CGPoint(x: left + CGFloat(offset + k) * step, y: y(value))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            var axis = Path()
            axis.move(to: CGPoint(x: left, y: bottom))
            axis.addLine(to: CGPoint(x: right, y: bottom))
            context.stroke(axis, with: .color(Color(hex: 0x9CA3AF)), lineWidth: 1)
            context.draw(Text("\u{2212}2\u{00A0}min").font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: left, y: bottom + 9), anchor: .leading)
            context.draw(Text("\u{2212}1\u{00A0}min").font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: (left + right) / 2, y: bottom + 9))
            context.draw(Text("maintenant").font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: right, y: bottom + 9), anchor: .trailing)
        }
        .frame(height: 146)
    }
}
