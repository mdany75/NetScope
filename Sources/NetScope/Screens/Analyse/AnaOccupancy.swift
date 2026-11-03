import NetScopeCore
import SwiftUI

/// Carte d'occupation 16 × 16 d'un /24, avec le détail de l'adresse survolée ou choisie.
struct AnaOccupancyPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let network: IPv4Address
    let records: [InvRecord]
    let now: Date
    let recentWindow: TimeInterval

    @State private var selected: Int?
    @State private var hovered: Int?

    private static let cell: CGFloat = 19
    private static let gap: CGFloat = 3

    var body: some View {
        let grid = InvOccupancy(network: network, records: records, now: now, recentWindow: recentWindow)
        let focus = hovered ?? selected ?? defaultFocus(grid)

        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                InvPanelTitle("Carte d’occupation", subtitle: "\(grid.network) · survolez une case pour voir l’adresse")
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        HStack(spacing: Self.gap) {
                            Text("").frame(width: 30)
                            ForEach(0..<16, id: \.self) { column in
                                Text("\(column)").font(Theme.mono(9)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: Self.cell)
                            }
                        }
                        ForEach(0..<16, id: \.self) { row in
                            HStack(spacing: Self.gap) {
                                Text(".\(row * 16)").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 30, alignment: .leading)
                                ForEach(0..<16, id: \.self) { column in
                                    cellView(grid.cells[row * 16 + column], isFocus: row * 16 + column == (selected ?? -1))
                                }
                            }
                        }
                        legend(grid).padding(.top, 8)
                    }
                    detail(grid.cells[focus])
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func defaultFocus(_ grid: InvOccupancy) -> Int {
        grid.cells.first { $0.state == .conflit }?.index ?? grid.cells.first { $0.state == .enLigne }?.index ?? 1
    }

    static func colors(_ state: InvCellState) -> (fill: Color, border: Color) {
        switch state {
        case .enLigne: return (Color(hex: 0x16A34A), Color(hex: 0x15803D))
        case .horsLigne: return (Color(hex: 0xCBD5E1), Color(hex: 0x94A3B8))
        case .libre: return (Color.white, Color(hex: 0xD1D5DB))
        case .conflit: return (Color(hex: 0xB91C1C), Color(hex: 0x7F1D1D))
        case .reseau: return (Color(hex: 0x374151), Color(hex: 0x1F2937))
        }
    }

    private func cellView(_ cell: InvOccupancy.Cell, isFocus: Bool) -> some View {
        let colors = Self.colors(cell.state)
        return RoundedRectangle(cornerRadius: 3)
            .fill(colors.fill)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colors.border))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isFocus ? Theme.text : Color.clear, lineWidth: 2).padding(-2))
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
            .help("\(cell.ip.description) : \(cell.state.label)")
            .onHover { inside in
                if inside { hovered = cell.index } else if hovered == cell.index { hovered = nil }
            }
            .onTapGesture { selected = cell.index }
    }

    private func legend(_ grid: InvOccupancy) -> some View {
        InvFlowLayout(spacing: 12) {
            ForEach([InvCellState.enLigne, .horsLigne, .libre, .conflit, .reseau], id: \.self) { state in
                let colors = Self.colors(state)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(colors.fill)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colors.border))
                        .frame(width: 12, height: 12)
                    Text(state.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Text("\(grid.count(state))").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
        }
        .frame(width: 30 + 16 * (Self.cell + Self.gap), alignment: .leading)
    }

    @ViewBuilder
    private func detail(_ cell: InvOccupancy.Cell) -> some View {
        let here = records.filter { $0.ip == cell.ip }.sorted { $0.lastSeen > $1.lastSeen }
        let record = cell.recordKey.flatMap { key in records.first { $0.key == key } }
        VStack(alignment: .leading, spacing: 8) {
            Text("ADRESSE CHOISIE").font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
            Text(cell.ip.description).font(Theme.mono(17, weight: .semibold)).textSelection(.enabled)
            pill(cell.state)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                switch cell.state {
                case .reseau:
                    row("Rôle", cell.index == 0 ? "Adresse réseau" : "Adresse de diffusion")
                case .libre:
                    row("Nom", "Libre")
                    row("Vu", "Aucune réponse récente")
                case .conflit:
                    row("Nom", "\(max(here.filter(\.isOnline).count, 2)) appareils en conflit")
                    row("MAC", here.compactMap { $0.mac?.formatted(.upperColon) }.joined(separator: "\n"), mono: true)
                    row("Fabricant", here.map(\.vendorLabel).joined(separator: " / "))
                    row("Port", here.compactMap(\.switchLocation).joined(separator: "\n"), mono: true)
                default:
                    if let record {
                        row("Nom", record.displayName)
                        row("Fabricant", record.vendorLabel)
                        row("MAC", record.mac?.formatted(.upperColon) ?? "—", mono: true)
                        row("Port", record.switchLocation ?? "—", mono: true)
                        row("VLAN", record.vlan.map(String.init) ?? "—")
                        row("Vu", record.isOnline ? "Maintenant" : InvFormat.relative(record.lastSeen, now: now))
                    }
                }
            }
            Text(note(cell, record: record))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let record, cell.state != .libre {
                HStack(spacing: 2) {
                    Button("Ouvrir la fiche") {
                        model.selectedKey = record.key
                        state.open(.inventaire)
                    }
                    .buttonStyle(.ghost)
                    Button("Ping continu") { state.sendToPing(cell.ip.description) }.buttonStyle(.ghost)
                }
                .padding(.leading, -8)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func note(_ cell: InvOccupancy.Cell, record: InvRecord?) -> String {
        switch cell.state {
        case .reseau: return "Non attribuable dans un /24."
        case .libre: return "Aucune fiche récente à cette adresse : candidate pour une IP fixe, à confirmer par un ping."
        case .conflit: return "Plusieurs MAC répondent à cette adresse : IP fixe en double probable."
        case .horsLigne: return "Ne répond plus, mais l’adresse a servi récemment : à éviter pour une IP fixe."
        case .enLigne: return record?.openPorts.isEmpty == false
            ? "Ports ouverts : " + (record?.openPorts.map(String.init).joined(separator: ", ") ?? "") + "."
            : "Répond au scan."
        }
    }

    private func pill(_ state: InvCellState) -> some View {
        let (fg, bg): (Color, Color)
        switch state {
        case .enLigne: (fg, bg) = (Theme.success, Theme.successSoft)
        case .conflit: (fg, bg) = (Theme.critical, Theme.criticalSoft)
        default: (fg, bg) = (Theme.neutralText, Color(hex: 0xE5E7EB))
        }
        return InvPill(text: state.label, foreground: fg, background: bg, size: 12)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary)
            if mono {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array((value.isEmpty ? "—" : value).split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(String(line)).font(Theme.mono(10.5)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            } else {
                Text(value.isEmpty ? "—" : value).font(Theme.small)
                    .fontWeight(key == "Nom" ? .medium : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
