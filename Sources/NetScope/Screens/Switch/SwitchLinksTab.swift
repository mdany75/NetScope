import AppKit
import NetScopeCore
import SwiftUI

// Note 83 : onglets Appareils (appareils par VLAN, à côté de la table MAC) et Voisins et liens
// (voisins LLDP de tous les switchs du site, liens entre switchs, uplinks, topologie, ce Mac).

// MARK: - Appareils par VLAN

/// VLAN du switch affiché : un clic filtre la table MAC sur ce VLAN (un second clic retire le filtre).
struct SwitchVLANPanel: View {
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot

    var body: some View {
        let vlans = SwitchVLANSummary.make(snapshot)
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Appareils par VLAN").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(vlans.count) VLAN").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                if vlans.isEmpty {
                    Text("Aucun VLAN relevé sur ce switch (Q-BRIDGE-MIB absente ou table MAC vide).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(vlans) { usage in row(usage) }
                    }
                    Text("Clic\u{00A0}: filtrer la table MAC sur ce VLAN.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func filter(_ vlan: Int) -> String { "vlan:\(vlan)" }

    private func row(_ usage: SwitchVLANUsage) -> some View {
        let active = store.tableFilter == filter(usage.vlan)
        return Button {
            store.tableFilter = active ? "" : filter(usage.vlan)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("VLAN \(usage.vlan)").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    Text("\(usage.devices) appareil\(usage.devices > 1 ? "s" : "")")
                        .font(Theme.small).foregroundStyle(usage.devices > 0 ? Theme.text : Theme.textTertiary)
                }
                if !usage.accessPorts.isEmpty {
                    Text("Accès\u{00A0}: " + list(usage.accessPorts))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if !usage.trunkPorts.isEmpty {
                    Text("Trunk\u{00A0}: " + list(usage.trunkPorts))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(active ? Theme.accentSoft : Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(active ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((usage.accessPorts + usage.trunkPorts).joined(separator: ", "))
        .contextMenu { OpenInMenu(object: .vlan(usage.vlan)) }
    }

    private func list(_ ports: [String]) -> String {
        ports.count > 5 ? ports.prefix(5).joined(separator: ", ") + " +\(ports.count - 5)" : ports.joined(separator: ", ")
    }
}

// MARK: - Voisins et liens

/// Ligne du tableau des voisins.
struct SwitchNeighborTableRow: Identifiable {
    let neighbor: SwitchNeighborRow
    var id: String { neighbor.id }
    let order: Int
    let speed: String
    let speedSort: UInt64

    var switchName: String { neighbor.switchName }
    var localPort: String { neighbor.localPort }
    var name: String { neighbor.neighborName }
    var remotePort: String { neighbor.neighborPort }
    var kindLabel: String { neighbor.kind.label }
    var capabilities: String { neighbor.capabilities.isEmpty ? "—" : neighbor.capabilities.joined(separator: ", ") }
    var platform: String { neighbor.platform ?? "—" }
    var nameSort: String { name.lowercased() }
}

/// Voisins LLDP (et liens FortiLink / inter-switch des FortiSwitch) de tous les switchs du site.
struct SwitchNeighborTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshots: [SNMPSwitchSnapshot]
    @StateObject private var table = StandardTableModel<SwitchNeighborTableRow>(id: "switchs.voisins", columns: Self.columns,
                                                                                 sortKeys: Self.sortKeys, defaultSort: "switch")
    @State private var selection: SwitchNeighborTableRow.ID?
    @State private var infrastructureOnly = false

    static let columns: [StandardColumn] = [
        StandardColumn(id: "switch", title: "Switch", isRequired: true),
        StandardColumn(id: "port", title: "Port local"),
        StandardColumn(id: "voisin", title: "Voisin"),
        StandardColumn(id: "portDistant", title: "Port distant"),
        StandardColumn(id: "nature", title: "Nature"),
        StandardColumn(id: "vitesse", title: "Vitesse"),
        StandardColumn(id: "capacites", title: "Capacités LLDP", isDefaultVisible: false),
        StandardColumn(id: "plateforme", title: "Plateforme", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SwitchNeighborTableRow>] = [
        "switch": KeyPathComparator(\SwitchNeighborTableRow.order),
        "port": KeyPathComparator(\SwitchNeighborTableRow.localPort),
        "voisin": KeyPathComparator(\SwitchNeighborTableRow.nameSort),
        "portDistant": KeyPathComparator(\SwitchNeighborTableRow.remotePort),
        "nature": KeyPathComparator(\SwitchNeighborTableRow.kindLabel),
        "vitesse": KeyPathComparator(\SwitchNeighborTableRow.speedSort),
        "capacites": KeyPathComparator(\SwitchNeighborTableRow.capabilities),
        "plateforme": KeyPathComparator(\SwitchNeighborTableRow.platform),
    ]

    private static let rowHeight: CGFloat = 26
    private static let maxRows = 16
    /// Largeurs idéales : le tableau défile à gauche et à droite quand elles ne tiennent pas.
    static let widths: [String: CGFloat] = [
        "switch": 120, "port": 116, "voisin": 170, "portDistant": 100, "nature": 140, "vitesse": 76,
        "capacites": 150, "plateforme": 200,
    ]

    var body: some View {
        let all = SwitchNeighborRows.make(snapshots)
        let links = SwitchNeighborRows.interSwitchLinks(all)
        let rows = all.enumerated()
            .filter { !infrastructureOnly || $1.kind.isInfrastructure }
            .map { position, neighbor in
                SwitchNeighborTableRow(neighbor: neighbor, order: position,
                                       speed: neighbor.speedMbps.map { SNMPFormat.speed(mbps: $0) } ?? "—",
                                       speedSort: neighbor.speedMbps ?? 0)
            }
            .sorted(using: table.sortOrder + [KeyPathComparator(\SwitchNeighborTableRow.order)])
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        heading(count: all.count, links: links)
                        Spacer(minLength: 8)
                        toggle
                        StandardColumnsMenu(model: table)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        heading(count: all.count, links: links)
                        HStack(spacing: 10) {
                            toggle
                            Spacer(minLength: 0)
                            StandardColumnsMenu(model: table)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(Theme.border).frame(height: 1)
                if rows.isEmpty {
                    Text(all.isEmpty ? "Aucun voisin LLDP relevé\u{00A0}: activez LLDP sur les switchs, puis interrogez-les de nouveau."
                         : "Aucun lien d’infrastructure parmi les voisins.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    StandardTableHorizontalScroll(
                        minWidth: table.contentWidth(Self.widths),
                        height: StandardTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)) {
                        tableView(rows)
                            .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)
                    }
                }
            }
        }
    }

    private func heading(count: Int, links: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Voisins LLDP").font(.system(size: 14, weight: .semibold)).fixedSize()
            Text("\(count) voisin\(count > 1 ? "s" : "") · \(links) lien\(links > 1 ? "s" : "") entre switchs · \(snapshots.count) switch\(snapshots.count > 1 ? "s" : "")")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var toggle: some View {
        Toggle("Liens d’infrastructure seulement", isOn: $infrastructureOnly)
            .toggleStyle(.checkbox)
            .font(Theme.small)
            .fixedSize()
            .help("Masquer les postes, téléphones et bornes\u{00A0}: garder les switchs, routeurs et liens FortiLink")
    }

    private func tableView(_ rows: [SwitchNeighborTableRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("SWITCH"), sortUsing: table.sort("switch")) { row in
                SwitchCell(row.switchName, mono: true, strong: true)
            }
            .width(min: 90, ideal: Self.widths["switch"]!)
            .customizationID("switch")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("PORT LOCAL"), sortUsing: table.sort("port")) { row in
                HStack(spacing: 6) {
                    Text(row.localPort).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                    if row.neighbor.isUplink { SwitchSourceTag(source: .uplink) }
                }
            }
            .width(min: 80, ideal: Self.widths["port"]!)
            .customizationID("port")

            TableColumn(StandardTableHeading("VOISIN"), sortUsing: table.sort("voisin")) { row in
                HStack(spacing: 4) {
                    Text(row.name).font(Theme.mono(12, weight: row.neighbor.neighborHost != nil ? .semibold : .regular))
                        .foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    if row.neighbor.neighborHost != nil {
                        Image(systemName: "arrow.right.circle").font(.system(size: 10)).foregroundStyle(Theme.accent)
                            .help("Switch relevé\u{00A0}: menu contextuel «\u{00A0}Ouvrir le switch voisin\u{00A0}»")
                    }
                }
                .help(row.name)
            }
            .width(min: 100, ideal: Self.widths["voisin"]!)
            .customizationID("voisin")

            TableColumn(StandardTableHeading("PORT DISTANT"), sortUsing: table.sort("portDistant")) { row in
                SwitchCell(row.remotePort, mono: true).help(row.neighbor.neighborPortDescr ?? row.remotePort)
            }
            .width(min: 70, ideal: Self.widths["portDistant"]!)
            .customizationID("portDistant")

            TableColumn(StandardTableHeading("NATURE"), sortUsing: table.sort("nature")) { row in
                Chip(text: row.kindLabel, tone: row.neighbor.kind.isInfrastructure ? .accent : .neutral)
            }
            .width(min: 90, ideal: Self.widths["nature"]!)
            .customizationID("nature")

            TableColumn(StandardTableHeading("VITESSE"), sortUsing: table.sort("vitesse")) { row in
                SwitchCell(row.speed, mono: true, dimmed: row.speed == "—")
            }
            .width(min: 60, ideal: Self.widths["vitesse"]!)
            .customizationID("vitesse")

            TableColumn(StandardTableHeading("CAPACITÉS LLDP"), sortUsing: table.sort("capacites")) { row in
                SwitchCell(row.capabilities, dimmed: row.capabilities == "—").help(row.capabilities)
            }
            .width(min: 90, ideal: Self.widths["capacites"]!)
            .customizationID("capacites")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("PLATEFORME"), sortUsing: table.sort("plateforme")) { row in
                SwitchCell(row.platform, dimmed: row.platform == "—", secondary: true).help(row.platform)
            }
            .width(min: 100, ideal: Self.widths["plateforme"]!)
            .customizationID("plateforme")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        // Double-clic ou ↩︎ : la suite logique du port local (appareil branché, ou switch voisin
        // pour un uplink) ; le menu ouvre le port dans l'onglet Ports ou le switch voisin.
        .standardRowActions(selection: selection.map { [$0] } ?? [], object: { id in
            guard let row = rows.first(where: { $0.id == id }), let index = row.neighbor.ifIndex else { return nil }
            return .port(NavPortRef(host: row.neighbor.switchHost, ifIndex: index))
        }) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button("Voir le port dans l’onglet Ports") {
                    SwitchTabState.shared.jump(.ports, host: row.neighbor.switchHost, port: row.neighbor.ifIndex, in: state)
                }
                .disabled(row.neighbor.ifIndex == nil)
                if let host = row.neighbor.neighborHost {
                    Button("Ouvrir le switch voisin") { SwitchTabState.shared.jump(.switchs, host: host, in: state) }
                }
                Divider()
                Button("Copier le nom du voisin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.name, forType: .string)
                }
            }
        }
    }
}
