import NetScopeCore
import SwiftUI

/// Carte des canaux des bornes FortiAP (note 27) : chaque radio est un bloc couvrant sa largeur
/// sur l'axe des canaux de la bande choisie, une ligne par radio ; un bloc en chevauchement avec
/// une autre borne du même site est en orange (même canal en 2,4 GHz : jaune pâle).
struct FortiAPChannelMap: View {
    @ObservedObject private var store = FortiAPStore.shared
    @Binding var band: WifiBand
    @Binding var selectedAP: FortiManagedAP.ID?

    struct Lane: Identifiable {
        let ap: FortiManagedAP
        let radio: FortiAPRadio
        var id: String { ap.id + "|\(radio.radioID)" }
    }

    private static let laneHeight: CGFloat = 22
    private static let axisHeight: CGFloat = 22

    var body: some View {
        let current = lanes(band)
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        WifiHeading("Carte des canaux des bornes").fixedSize()
                        bandPicker
                        Spacer(minLength: 8)
                        legend
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            WifiHeading("Carte des canaux des bornes").fixedSize()
                            bandPicker
                            Spacer(minLength: 0)
                        }
                        legend
                    }
                }
                if current.isEmpty {
                    Text("Aucune radio en service en \(band.label).").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    graph(current)
                        .frame(height: Self.axisHeight + CGFloat(current.count) * Self.laneHeight + 4)
                }
                Text(summary(current)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if lanes(band).isEmpty, let other = WifiBand.allCases.first(where: { !lanes($0).isEmpty }) { band = other } }
    }

    private var bandPicker: some View {
        Picker("Bande", selection: $band) {
            ForEach(WifiBand.allCases) { b in Text("\(b.label) (\(lanes(b).count))").tag(b) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var legend: some View {
        HStack(spacing: 10) {
            swatch(Theme.accent, "Sans chevauchement")
            swatch(Theme.warning, "Chevauchement")
            if band == .ghz24 { swatch(Theme.warningDot.opacity(0.45), "Même canal") }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize()
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }

    /// Radios en service de la bande, triées par canal.
    private func lanes(_ band: WifiBand) -> [Lane] {
        store.overview.aps.filter { !$0.isOffline }.flatMap { ap in
            ap.radios.filter { $0.isServing && $0.band == band }.map { Lane(ap: ap, radio: $0) }
        }
        .sorted { ($0.radio.channel ?? 0, $0.ap.name) < ($1.radio.channel ?? 0, $1.ap.name) }
    }

    private enum Conflict { case none, sameChannel, overlap }

    private func conflict(_ lane: Lane) -> Conflict {
        let mine = store.diagnosis.overlaps.filter {
            $0.site == lane.ap.site && $0.band == band
                && (($0.first == lane.ap.name && $0.firstChannel == lane.radio.channel) || ($0.second == lane.ap.name && $0.secondChannel == lane.radio.channel))
        }
        if mine.contains(where: { $0.kind != .sameChannel || $0.band != .ghz24 }) { return .overlap }
        return mine.isEmpty ? .none : .sameChannel
    }

    private func graph(_ lanes: [Lane]) -> some View {
        GeometryReader { geo in
            let axis = WifiChannelLayout.axis(band)
            let width = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat(($0 - axis.lowerBound) / (axis.upperBound - axis.lowerBound)) * width }
            ZStack(alignment: .topLeading) {
                // Graduations.
                ForEach(Array(WifiChannelLayout.ticks(band).enumerated()), id: \.offset) { _, tick in
                    Rectangle().fill(Theme.border).frame(width: 1, height: CGFloat(lanes.count) * Self.laneHeight + 4)
                        .offset(x: x(tick.position), y: 0)
                    Text(tick.label).font(Theme.mono(9.5)).foregroundStyle(Theme.textTertiary).fixedSize()
                        .offset(x: x(tick.position) - 8, y: CGFloat(lanes.count) * Self.laneHeight + 6)
                        .frame(width: 16)
                }
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    let span = WifiChannelLayout.span(channel: lane.radio.channel ?? 0, band: band, widthMHz: lane.radio.effectiveWidth)
                    let left = x(span.center - span.half), right = x(span.center + span.half)
                    let kind = conflict(lane)
                    let fill: Color = kind == .overlap ? Theme.warning : (kind == .sameChannel ? Theme.warningDot.opacity(0.45) : Theme.accent)
                    let selected = selectedAP == lane.ap.id
                    let barWidth = max(right - left, 18)
                    let site = store.overview.isMultiSite ? " · \(lane.ap.site)" : ""
                    let label = "\(lane.ap.name) · canal \(lane.radio.channel ?? 0) · \(lane.radio.clientCount ?? 0) client\((lane.radio.clientCount ?? 0) > 1 ? "s" : "")\(site)"
                    // Étiquette à côté du bloc (à droite, ou à gauche près du bord droit) : un bloc de
                    // 20 MHz est trop étroit pour son nom.
                    let toLeft = left > width * 0.55
                    Button { selectedAP = lane.ap.id } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(fill.opacity(selected ? 0.95 : 0.75))
                            RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.text : Color.clear, lineWidth: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: barWidth, height: Self.laneHeight - 5)
                    .help("\(lane.ap.name)\(store.overview.isMultiSite ? " (\(lane.ap.site))" : "")\u{00A0}: \(lane.radio.label), \(lane.radio.clientCount ?? 0) client(s)"
                          + (lane.radio.channelUtilization.map { ", canal occupé à \(Int($0.rounded()))\u{00A0}%" } ?? ""))
                    .offset(x: left, y: CGFloat(index) * Self.laneHeight + 2)
                    Text(label)
                        .font(Theme.mono(10.5, weight: selected ? .bold : .medium))
                        .foregroundStyle(kind == .none ? Theme.text : Theme.warning)
                        .lineLimit(1).fixedSize()
                        .frame(width: 260, alignment: toLeft ? .trailing : .leading)
                        .offset(x: toLeft ? left - 266 : left + barWidth + 6, y: CGFloat(index) * Self.laneHeight + 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
    }

    private func summary(_ lanes: [Lane]) -> String {
        let overlaps = store.diagnosis.overlaps.filter { $0.band == band }
        guard !lanes.isEmpty else { return "" }
        let used = Set(lanes.compactMap(\.radio.channel)).sorted().map(String.init).joined(separator: ", ")
        var text = "\(lanes.count) radio\(lanes.count > 1 ? "s" : "") en \(band.label) · canaux \(used)"
        if overlaps.isEmpty {
            text += " · aucun chevauchement entre bornes"
        } else {
            text += " · " + overlaps.prefix(2).map { "\($0.kindLabel.lowercased())\u{00A0}: \($0.pairLabel)" }.joined(separator: "\u{00A0}; ")
        }
        if store.overview.isMultiSite { text += " (chaque site est analysé à part)" }
        return text + "."
    }
}
