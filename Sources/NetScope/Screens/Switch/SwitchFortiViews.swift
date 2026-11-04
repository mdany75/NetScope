import AppKit
import NetScopeCore
import SwiftUI

// Note 24 : FortiSwitch gérés par la FortiGate dans l'écran Switchs et ports : bandeau du
// contrôleur et tableau des ports (état, vitesse, VLAN, PoE, appareil branché).

extension SwitchText {
    /// « 10.255.1.2 (FortiLink) », ou « adresse FortiLink inconnue » (adresse de remplacement 0.0.0.n).
    static func fortiLinkAddress(_ snapshot: SNMPSwitchSnapshot) -> String {
        snapshot.host.value < 256 ? "adresse FortiLink inconnue" : "\(snapshot.host) (FortiLink)"
    }

    /// Uptime pour un switch SNMP ; nom du contrôleur pour un FortiSwitch (FortiOS ne publie pas
    /// l'uptime des switchs dans les adresses lues).
    static func uptimeOrController(_ snapshot: SNMPSwitchSnapshot) -> String {
        if let controller = snapshot.controllerName { return controller }
        return snapshot.system.uptimeText ?? "—"
    }
}

/// Bandeau du contrôleur FortiGate : modèle, version, nombre de FortiSwitch et d'appareils,
/// dernière lecture, rafraîchissement à la demande ; erreur expliquée sinon.
struct SwitchFortiGatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        if fortigate.isConfigured {
            Panel(padding: 14) {
                AdaptiveStack(breakpoint: 900, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(SwitchSource.fortigate.colors.background)
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 15)).foregroundStyle(SwitchSource.fortigate.colors.foreground)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Contrôleur FortiGate").font(Theme.bodySemibold)
                                statusChip
                            }
                            summary
                                .font(Theme.small)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button("Réglages…") {
                            RegNavigation.shared.section = .switchs
                            state.open(.reglages)
                        }
                        .buttonStyle(.secondary)
                        Button { fortigate.refreshNow(state: state) } label: {
                            HStack(spacing: 6) {
                                if fortigate.isBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                                }
                                Text(fortigate.isBusy ? "Lecture…" : "Relire la FortiGate")
                            }
                        }
                        .buttonStyle(.secondary)
                        .disabled(fortigate.isBusy || !fortigate.isEnabled || !(fortigate.isReady || fortigate.isDemo))
                        .help("Relit les FortiSwitch, les ports et les appareils détectés par l’API REST de la FortiGate (HTTPS, lecture seule).")
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var statusChip: some View {
        if fortigate.isBusy {
            Chip(text: "Lecture…", tone: .accent)
        } else if !fortigate.isEnabled {
            Chip(text: "Désactivé", tone: .neutral)
        } else if fortigate.lastError != nil {
            Chip(text: "Erreur", tone: .critical)
        } else if fortigate.report != nil {
            Chip(text: "Connecté", tone: .success)
        } else {
            Chip(text: "Pas encore lu", tone: .neutral)
        }
    }

    private var summary: Text {
        if let error = fortigate.lastError { return Text(error) }
        guard let report = fortigate.report else {
            return Text("Les FortiSwitch gérés par FortiLink seront lus à la fin du prochain scan, ou avec «\u{00A0}Relire la FortiGate\u{00A0}».")
        }
        let switches = report.switches.count
        let devices = report.locatedDevices.count
        return Text(report.controllerName).font(Theme.mono(12)).foregroundStyle(Theme.text)
            + Text(" · \(report.system.model) · \(report.system.versionLabel) · ")
            + Text("\(switches) FortiSwitch · \(devices) appareil\(devices > 1 ? "s" : "") détecté\(devices > 1 ? "s" : "") · lu \(SwitchText.ago(report.readAt)) · ")
            + Text("prioritaire sur SNMP pour l’emplacement")
    }
}

/// Ligne du tableau des ports d'un FortiSwitch.
struct SwitchFortiPortRow: Identifiable {
    let id: Int
    let port: String
    let number: Int
    let state: String
    let stateRank: Int
    let speed: String
    let speedSort: UInt64
    let vlan: String
    let vlanSort: Int
    let poe: String
    let poeSort: Double
    let device: String
    let deviceIP: String
    let deviceCount: Int
    let description: String
    let isUplink: Bool
}

/// Ports du FortiSwitch affiché (tableau standard « switchs.fortiswitch.ports ») : état, vitesse,
/// VLAN natif, PoE et appareil branché d'après la FortiGate. Un clic choisit le port sur la façade.
struct SwitchFortiPortTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot
    @StateObject private var table = Self.makeModel()
    @State private var selection: Int?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "port", title: "Port", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "vitesse", title: "Vitesse"),
        StandardColumn(id: "vlan", title: "VLAN natif"),
        StandardColumn(id: "poe", title: "PoE"),
        StandardColumn(id: "appareil", title: "Appareil branché"),
        StandardColumn(id: "description", title: "Description"),
        StandardColumn(id: "ip", title: "Adresse IP", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SwitchFortiPortRow>] = [
        "port": KeyPathComparator(\SwitchFortiPortRow.number),
        "etat": KeyPathComparator(\SwitchFortiPortRow.stateRank),
        "vitesse": KeyPathComparator(\SwitchFortiPortRow.speedSort),
        "vlan": KeyPathComparator(\SwitchFortiPortRow.vlanSort),
        "poe": KeyPathComparator(\SwitchFortiPortRow.poeSort),
        "appareil": KeyPathComparator(\SwitchFortiPortRow.device),
        "description": KeyPathComparator(\SwitchFortiPortRow.description),
        "ip": KeyPathComparator(\SwitchFortiPortRow.deviceIP),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<SwitchFortiPortRow> {
        StandardTableModel(id: "switchs.fortiswitch.ports", columns: columns, sortKeys: sortKeys, defaultSort: "port")
    }

    private static let rowHeight: CGFloat = 26

    var body: some View {
        let rows = makeRows().sorted(using: table.sortOrder)
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Ports du FortiSwitch").font(Theme.panelTitle)
                    SwitchSourceTag(source: .fortigate)
                    Spacer(minLength: 8)
                    Text("\(rows.filter { $0.stateRank == 0 }.count) actifs sur \(rows.count) · d’après \(snapshot.controllerName ?? "la FortiGate")")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    StandardColumnsMenu(model: table)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(Theme.border).frame(height: 1)
                tableView(rows)
                    .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: 14)
            }
        }
        .onAppear { selection = store.selectedPort }
        .onChange(of: store.selectedPort) { _, port in if selection != port { selection = port } }
        .onChange(of: selection) { _, port in
            if let port, port != store.selectedPort { store.select(host: snapshot.host.description, port: port) }
        }
    }

    private func tableView(_ rows: [SwitchFortiPortRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("PORT"), sortUsing: table.sort("port")) { row in
                HStack(spacing: 6) {
                    Text(row.port).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                    if row.isUplink { SwitchSourceTag(source: .uplink) }
                }
            }
            .width(min: 70, ideal: 96)
            .customizationID("port")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in
                Chip(text: row.state, tone: row.stateRank == 0 ? .success : (row.stateRank == 2 ? .warning : .neutral))
            }
            .width(min: 70, ideal: 86)
            .customizationID("etat")

            TableColumn(StandardTableHeading("VITESSE"), sortUsing: table.sort("vitesse")) { row in
                Text(row.speed).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .width(min: 60, ideal: 80)
            .customizationID("vitesse")

            TableColumn(StandardTableHeading("VLAN NATIF"), sortUsing: table.sort("vlan")) { row in
                Text(row.vlan).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .width(min: 60, ideal: 84)
            .customizationID("vlan")

            TableColumn(StandardTableHeading("POE"), sortUsing: table.sort("poe")) { row in
                Text(row.poe).font(Theme.small).foregroundStyle(row.poeSort > 0 ? Theme.success : Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            .customizationID("poe")

            TableColumn(StandardTableHeading("APPAREIL BRANCHÉ"), sortUsing: table.sort("appareil")) { row in
                HStack(spacing: 4) {
                    Text(row.device.isEmpty ? "—" : row.device).font(Theme.small).foregroundStyle(row.device.isEmpty ? Theme.textTertiary : Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    if row.deviceCount > 1 {
                        Text("+\(row.deviceCount - 1)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .help(row.deviceIP.isEmpty ? row.device : "\(row.device) · \(row.deviceIP)")
            }
            .width(min: 110, ideal: 170)
            .customizationID("appareil")

            TableColumn(StandardTableHeading("DESCRIPTION"), sortUsing: table.sort("description")) { row in
                Text(row.description).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    .help(row.description)
            }
            .width(min: 100, ideal: 190)
            .customizationID("description")

            TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                Text(row.deviceIP).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .width(min: 90, ideal: 110)
            .customizationID("ip")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
    }

    private func makeRows() -> [SwitchFortiPortRow] {
        let uplinks = snapshot.uplinkInterfaces()
        return snapshot.physicalPorts.map { iface in
            let entries = snapshot.entries(on: iface.index)
            let isUplink = uplinks.contains(iface.index)
            let first = entries.first.map { store.describe($0.mac, devices: state.devices) }
            let neighbor = snapshot.neighbor(on: iface.index)
            let stateText: String
            let rank: Int
            if !iface.adminUp {
                (stateText, rank) = ("Désactivé", 2)
            } else if iface.isUp {
                (stateText, rank) = ("Actif", 0)
            } else if iface.operStatus == .unknown {
                (stateText, rank) = ("Inconnu", 3)
            } else {
                (stateText, rank) = ("Inactif", 1)
            }
            let poePort = snapshot.poePort(iface.index)
            let watts = poePort?.consumptionW ?? 0
            let device: String
            if isUplink, let neighbor {
                device = (neighbor.portID == "FortiLink" ? "FortiLink → " : "ISL → ") + neighbor.sysName
            } else {
                device = first.map { $0.name == "—" ? entries.first!.mac.formatted(.upperColon) : $0.name } ?? ""
            }
            let vlan = snapshot.pvid[iface.index]
            return SwitchFortiPortRow(
                id: iface.index, port: iface.name, number: iface.index, state: stateText, stateRank: rank,
                speed: iface.isUp ? SNMPFormat.speed(mbps: iface.speedMbps) : "—", speedSort: iface.isUp ? (iface.speedMbps ?? 0) : 0,
                vlan: isUplink ? "Trunk" + (vlan.map { " · \($0)" } ?? "") : (vlan.map(String.init) ?? "—"),
                vlanSort: vlan ?? Int.max,
                poe: SwitchText.poeLine(iface, snapshot: snapshot), poeSort: watts,
                device: device, deviceIP: isUplink ? "" : (first?.ip == "—" ? "" : first?.ip ?? ""),
                deviceCount: isUplink ? 0 : entries.count,
                description: iface.alias, isUplink: isUplink)
        }
    }
}
