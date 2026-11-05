import AppKit
import NetScopeCore
import SwiftUI

// Note 83 : onglet Ports de Switchs et ports. Tous les ports du switch choisi dans un tableau
// standard (« switchs.ports », SNMP et FortiSwitch lus par la FortiGate), filtres « Tous, Actifs,
// Inactifs, PoE, Uplinks, Erreurs » avec leurs compteurs, erreurs récentes au-dessus, et le
// détail du port choisi à droite (appareils, voisin, cycle PoE et redémarrage du port).

/// Ligne du tableau des ports : la ligne du moteur et ce que l'app sait des appareils branchés.
struct SwitchPortTableRow: Identifiable {
    let port: SwitchPortRow
    var id: Int { port.ifIndex }
    let order: Int
    let stateText: String
    let stateTone: Tone
    let speed: String
    let speedSort: UInt64
    let vlan: String
    let poe: String
    let poeSort: Double
    let device: String
    let deviceIP: String
    let deviceCount: Int
    let errors: String
    let errorsSort: UInt64
    let neighbor: String
    let lastChange: String
    let lastChangeSort: UInt32

    var name: String { port.name }
    var alias: String { port.alias }
    var statusSort: Int { port.status.rawValue }
    var vlanSort: Int { port.vlanSort }
    var deviceSort: String { device.isEmpty ? "\u{10FFFF}" : device.lowercased() }
    var aliasSort: String { alias.isEmpty ? "\u{10FFFF}" : alias.lowercased() }
    var neighborSort: String { neighbor.isEmpty ? "\u{10FFFF}" : neighbor.lowercased() }
    var macSort: Int { port.macCount }
}

/// Contenu de l'onglet Ports.
struct SwitchPortsTab: View {
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot

    var body: some View {
        SidePanelSplit(sideWidth: 330, collapse: .below, spacing: 16) {
            VStack(spacing: 16) {
                SwitchRecentErrorsPanel(store: store, snapshot: snapshot)
                SwitchPortTable(store: store, snapshot: snapshot)
                    .id(snapshot.id)
            }
        } side: {
            if let iface = store.selectedInterface {
                SwitchPortDetail(store: store, snapshot: snapshot, iface: iface)
            } else {
                Panel { Text("Choisissez un port dans le tableau.").font(Theme.small).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

/// « Erreurs récentes » : ports dont les erreurs en entrée augmentent, un clic choisit le port.
struct SwitchRecentErrorsPanel: View {
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot

    var body: some View {
        let recent = store.recentErrors(snapshot.id)
        let alerts = recent.alerts
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                    Text("Erreurs récentes").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text("\(alerts.count) port\(alerts.count > 1 ? "s" : "") dont les erreurs en entrée augmentent depuis \(PortErrorTracker.durationLabel(recent.seconds))")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                SwitchFlowLayout(spacing: 8) {
                    ForEach(alerts.prefix(8), id: \.ifIndex) { delta in
                        let iface = snapshot.interface(delta.ifIndex)
                        Button { store.select(host: snapshot.id, port: delta.ifIndex) } label: {
                            HStack(spacing: 6) {
                                Text(iface?.name ?? "port \(delta.ifIndex)").font(Theme.mono(12, weight: .semibold))
                                Text("+\(SwitchText.grouped(delta.newErrors)) en \(delta.durationLabel)").font(Theme.small)
                                if let alias = iface?.alias, !alias.isEmpty {
                                    Text(alias).font(Theme.small).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(SwitchTokenButtonStyle())
                        .help("Choisir ce port\u{00A0}: câble, prise ou carte réseau à vérifier (CRC, collisions, duplex).")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.criticalSoft))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(light: 0xFCA5A5, dark: 0x822B2B)))
        }
    }
}

/// Tableau de tous les ports du switch affiché, avec ses filtres.
struct SwitchPortTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    @ObservedObject private var tabs = SwitchTabState.shared
    let snapshot: SNMPSwitchSnapshot
    @StateObject private var table = StandardTableModel<SwitchPortTableRow>(id: "switchs.ports", columns: Self.columns,
                                                                             sortKeys: Self.sortKeys, defaultSort: "port")
    @State private var selection: Int?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "port", title: "Port", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "vitesse", title: "Vitesse"),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "poe", title: "PoE"),
        StandardColumn(id: "appareil", title: "Appareil branché"),
        StandardColumn(id: "erreurs", title: "Erreurs récentes"),
        StandardColumn(id: "description", title: "Description", isDefaultVisible: false),
        StandardColumn(id: "voisin", title: "Voisin LLDP", isDefaultVisible: false),
        StandardColumn(id: "ip", title: "Adresse IP", isDefaultVisible: false),
        StandardColumn(id: "macs", title: "Adresses MAC", isDefaultVisible: false),
        StandardColumn(id: "changement", title: "Dernier changement", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SwitchPortTableRow>] = [
        "port": KeyPathComparator(\SwitchPortTableRow.order),
        "etat": KeyPathComparator(\SwitchPortTableRow.statusSort),
        "vitesse": KeyPathComparator(\SwitchPortTableRow.speedSort),
        "vlan": KeyPathComparator(\SwitchPortTableRow.vlanSort),
        "poe": KeyPathComparator(\SwitchPortTableRow.poeSort),
        "appareil": KeyPathComparator(\SwitchPortTableRow.deviceSort),
        "erreurs": KeyPathComparator(\SwitchPortTableRow.errorsSort),
        "description": KeyPathComparator(\SwitchPortTableRow.aliasSort),
        "voisin": KeyPathComparator(\SwitchPortTableRow.neighborSort),
        "ip": KeyPathComparator(\SwitchPortTableRow.deviceIP),
        "macs": KeyPathComparator(\SwitchPortTableRow.macSort),
        "changement": KeyPathComparator(\SwitchPortTableRow.lastChangeSort),
    ]

    private static let rowHeight: CGFloat = 26
    private static let maxRows = 18

    /// Largeurs idéales des colonnes : le tableau défile à gauche et à droite quand elles ne
    /// tiennent pas (petite fenêtre, colonnes ajoutées).
    static let widths: [String: CGFloat] = [
        "port": 104, "etat": 74, "vitesse": 66, "vlan": 84, "poe": 104, "appareil": 150, "erreurs": 90,
        "description": 140, "voisin": 170, "ip": 110, "macs": 90, "changement": 130,
    ]

    var body: some View {
        let recent = store.recentErrors(snapshot.id)
        let ports = SwitchPortRows.make(snapshot, recent: recent)
        let counts = SwitchPortRows.counts(ports)
        let kept = SwitchPortRows.filter(ports, by: tabs.portFilter, text: tabs.portText, keep: store.selectedPort)
        let position = Dictionary(uniqueKeysWithValues: ports.enumerated().map { ($1.ifIndex, $0) })
        let rows = kept.map { makeRow($0, order: position[$0.ifIndex] ?? $0.ifIndex) }
            .sorted(using: table.sortOrder + [KeyPathComparator(\SwitchPortTableRow.order)])
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(counts: counts, shown: rows.count, total: ports.count)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(Theme.border).frame(height: 1)
                if rows.isEmpty {
                    Text(tabs.portText.isEmpty ? "Aucun port «\u{00A0}\(tabs.portFilter.label.lowercased())\u{00A0}» sur ce switch."
                         : "Aucun port ne correspond à «\u{00A0}\(tabs.portText)\u{00A0}».")
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
        .onAppear { selection = store.selectedPort }
        .onChange(of: store.selectedPort) { _, port in if selection != port { selection = port } }
        .onChange(of: selection) { _, port in
            if let port, port != store.selectedPort { store.select(host: snapshot.id, port: port) }
        }
    }

    private func header(counts: [SwitchPortFilter: Int], shown: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                (Text("Ports · ").font(.system(size: 14, weight: .semibold))
                    + Text(snapshot.displayName).font(Theme.mono(14, weight: .semibold)))
                    .lineLimit(1).fixedSize()
                SwitchSourceTag(source: snapshot.isViaController ? .fortigate : .fdb)
                Spacer(minLength: 8)
                Text(poeText).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .help("PoE utilisé sur le budget publié par le switch")
                StandardColumnsMenu(model: table)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filterPicker(counts, short: false)
                    Spacer(minLength: 8)
                    filterField
                }
                HStack(spacing: 10) {
                    filterPicker(counts, short: true)
                    Spacer(minLength: 8)
                    filterField
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterPicker(counts, short: true)
                    filterField
                }
            }
        }
    }

    private var poeText: String {
        if let budget = snapshot.poeBudgetW, budget > 0 {
            let used = snapshot.poeUsedW ?? 0
            return "PoE \(used)\u{00A0}W / \(budget)\u{00A0}W · \(Int((Double(used) / Double(budget) * 100).rounded()))\u{00A0}%"
        }
        return snapshot.hasPoE ? "PoE sans budget publié" : "Aucun port PoE"
    }

    private func filterPicker(_ counts: [SwitchPortFilter: Int], short: Bool) -> some View {
        Picker("Ports", selection: $tabs.portFilter) {
            ForEach(SwitchPortFilter.allCases, id: \.self) { filter in
                Text(short ? "\(filter.label) \(counts[filter] ?? 0)" : "\(filter.label) (\(counts[filter] ?? 0))").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Tous les ports, actifs, inactifs, qui délivrent du PoE, uplinks ou dont les erreurs augmentent")
    }

    private var filterField: some View {
        TextField("Filtrer les ports", text: $tabs.portText, prompt: Text("Filtrer port, VLAN, voisin…"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(Theme.small)
            .frame(minWidth: 120, idealWidth: 190, maxWidth: 220)
    }

    private func tableView(_ rows: [SwitchPortTableRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("PORT"), sortUsing: table.sort("port")) { row in
                    HStack(spacing: 6) {
                        Text(row.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                        if row.port.isUplink { SwitchSourceTag(source: .uplink) }
                    }
                    .help(row.alias)
                }
                .width(min: 86, ideal: Self.widths["port"]!)
                .customizationID("port")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in
                    Chip(text: row.stateText, tone: row.stateTone)
                }
                .width(min: 64, ideal: Self.widths["etat"]!)
                .customizationID("etat")

                TableColumn(StandardTableHeading("VITESSE"), sortUsing: table.sort("vitesse")) { row in
                    SwitchCell(row.speed, mono: true, dimmed: row.speed == "—")
                }
                .width(min: 56, ideal: Self.widths["vitesse"]!)
                .customizationID("vitesse")

                TableColumn(StandardTableHeading("VLAN"), sortUsing: table.sort("vlan")) { row in
                    SwitchCell(row.vlan, mono: true, dimmed: row.vlan == "—").help(row.vlan)
                }
                .width(min: 60, ideal: Self.widths["vlan"]!)
                .customizationID("vlan")

                TableColumn(StandardTableHeading("POE"), sortUsing: table.sort("poe")) { row in
                    Text(row.poe).font(Theme.small).foregroundStyle(row.port.poeDelivering ? Theme.success : (row.port.poeFault ? Theme.critical : Theme.textSecondary))
                        .lineLimit(1).help(row.poe)
                }
                .width(min: 70, ideal: Self.widths["poe"]!)
                .customizationID("poe")

                TableColumn(StandardTableHeading("APPAREIL BRANCHÉ"), sortUsing: table.sort("appareil")) { row in
                    HStack(spacing: 4) {
                        Text(row.device.isEmpty ? "—" : row.device).font(Theme.small)
                            .foregroundStyle(row.device.isEmpty ? Theme.textTertiary : Theme.text)
                            .lineLimit(1).truncationMode(.tail)
                        if row.deviceCount > 1 {
                            Text("+\(row.deviceCount - 1)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .help(row.deviceIP.isEmpty ? row.device : "\(row.device) · \(row.deviceIP)")
                }
                .width(min: 100, ideal: Self.widths["appareil"]!)
                .customizationID("appareil")
            }

            Group {
                TableColumn(StandardTableHeading("ERREURS"), sortUsing: table.sort("erreurs")) { row in
                    Text(row.errors).font(Theme.mono(12, weight: row.port.hasRecentErrors ? .semibold : .regular))
                        .foregroundStyle(row.port.hasRecentErrors ? Theme.critical : (row.errorsSort == 0 ? Theme.textTertiary : Theme.text))
                        .lineLimit(1)
                        .help("Erreurs en entrée apparues"
                              + (row.port.errorSeconds.map { " en \(PortErrorTracker.durationLabel($0))" } ?? "")
                              + (row.port.totalErrors.map { " · total depuis le démarrage du switch\u{00A0}: \(SwitchText.grouped($0))" } ?? ""))
                }
                .width(min: 60, ideal: Self.widths["erreurs"]!)
                .customizationID("erreurs")

                TableColumn(StandardTableHeading("DESCRIPTION"), sortUsing: table.sort("description")) { row in
                    SwitchCell(row.alias.isEmpty ? "—" : row.alias, dimmed: row.alias.isEmpty, secondary: true).help(row.alias)
                }
                .width(min: 80, ideal: Self.widths["description"]!)
                .customizationID("description")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("VOISIN LLDP"), sortUsing: table.sort("voisin")) { row in
                    SwitchCell(row.neighbor.isEmpty ? "—" : row.neighbor, mono: !row.neighbor.isEmpty, dimmed: row.neighbor.isEmpty).help(row.neighbor)
                }
                .width(min: 90, ideal: Self.widths["voisin"]!)
                .customizationID("voisin")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                    SwitchCell(row.deviceIP.isEmpty ? "—" : row.deviceIP, mono: true, dimmed: row.deviceIP.isEmpty)
                }
                .width(min: 90, ideal: Self.widths["ip"]!)
                .customizationID("ip")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("ADRESSES MAC"), sortUsing: table.sort("macs")) { row in
                    SwitchCell("\(row.port.macCount)", mono: true, dimmed: row.port.macCount == 0)
                }
                .width(min: 60, ideal: Self.widths["macs"]!)
                .customizationID("macs")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("DERNIER CHANGEMENT"), sortUsing: table.sort("changement")) { row in
                    SwitchCell(row.lastChange, secondary: true)
                }
                .width(min: 90, ideal: Self.widths["changement"]!)
                .customizationID("changement")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 33 : double-clic ou ↩︎ sur un port → l'appareil branché (liste s'il y en a
        // plusieurs, message clair pour un port vide, un uplink ou un appareil pas encore vu).
        .standardRowActions(selection: selection.map { [$0] } ?? [], object: { index in
            .port(NavPortRef(host: snapshot.id, ifIndex: index))
        }) { ids in
            if let index = ids.first, let row = rows.first(where: { $0.id == index }) {
                Button("Ouvrir l’appareil branché") { state.perform(.port(NavPortRef(host: snapshot.id, ifIndex: index))) }
                Button("Voir le trafic du port") { SwitchTabState.shared.jump(.trafic, host: snapshot.id, port: index, in: state) }
                Button("Voir les appareils du port") { showDevices(of: row) }
                    .disabled(row.port.macCount == 0)
                Divider()
                Button("Copier le nom du port") { copy(row.name) }
            }
        }
    }

    private func showDevices(of row: SwitchPortTableRow) {
        store.tableFilter = "port:\(row.name)"
        SwitchTabState.shared.jump(.appareils, host: snapshot.id, port: row.id, in: state)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func makeRow(_ port: SwitchPortRow, order: Int) -> SwitchPortTableRow {
        let iface = snapshot.interface(port.ifIndex)
        let first = port.macs.first.map { store.describe($0, devices: state.devices) }
        let device: String
        if port.isUplink, let name = port.neighborName {
            let fortiLink = port.neighborPort == "FortiLink"
            device = (fortiLink ? "FortiLink → " : (snapshot.isViaController ? "ISL → " : "Uplink → ")) + name
        } else {
            device = first.map { $0.name == "—" ? port.macs[0].formatted(.upperColon) : $0.name } ?? ""
        }
        let (stateText, tone): (String, Tone) = {
            switch port.status {
            case .active: return ("Actif", .success)
            case .uplink: return ("Actif", .success)
            case .errors: return ("Erreurs", .critical)
            case .inactive: return (port.operStatus == .unknown ? "Inconnu" : "Inactif", .neutral)
            case .disabled: return ("Désactivé", .warning)
            }
        }()
        let errors: String
        if let fresh = port.newErrors {
            // La durée couverte est dans l'infobulle et dans le bandeau « Erreurs récentes ».
            errors = fresh == 0 ? "0" : "+\(SwitchText.grouped(fresh))"
        } else {
            errors = port.isUp && port.totalErrors != nil ? "en cours" : "—"
        }
        return SwitchPortTableRow(
            port: port, order: order, stateText: stateText, stateTone: tone,
            speed: port.isUp ? SNMPFormat.speed(mbps: port.speedMbps) : "—", speedSort: port.isUp ? (port.speedMbps ?? 0) : 0,
            vlan: port.vlanText,
            poe: iface.map { SwitchText.poeLine($0, snapshot: snapshot) } ?? "—", poeSort: port.poeWatts ?? (port.poeDelivering ? 0.1 : 0),
            device: device, deviceIP: port.isUplink ? "" : (first?.ip == "—" ? "" : first?.ip ?? ""),
            deviceCount: port.isUplink ? 0 : port.macCount,
            errors: errors, errorsSort: port.newErrors ?? 0,
            neighbor: port.neighborName.map { name in name + (port.neighborPort.map { " · \($0)" } ?? "") } ?? "",
            lastChange: iface.map { SwitchText.lastChange($0, uptime: snapshot.system.uptimeTicks) } ?? "—",
            lastChangeSort: port.lastChangeTicks ?? 0)
    }
}
