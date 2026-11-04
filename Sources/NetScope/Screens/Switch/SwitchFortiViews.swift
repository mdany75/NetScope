import AppKit
import NetScopeCore
import SwiftUI

// Note 24 : FortiSwitch gérés par la FortiGate dans l'écran Switchs et ports : bandeau du
// contrôleur et tableau des ports (état, vitesse, VLAN, PoE, appareil branché).

extension SwitchText {
    /// « 10.255.1.2 (FortiLink) », ou « adresse FortiLink inconnue » (adresse de remplacement 0.0.0.n).
    static func fortiLinkAddress(_ snapshot: SNMPSwitchSnapshot) -> String {
        if let real = snapshot.fortiLinkIP { return "\(real) (FortiLink)" }
        return snapshot.host.value < (1 << 24) ? "adresse FortiLink inconnue" : "\(snapshot.host) (FortiLink)"
    }

    /// Uptime pour un switch SNMP ; nom du contrôleur pour un FortiSwitch (FortiOS ne publie pas
    /// l'uptime des switchs dans les adresses lues).
    static func uptimeOrController(_ snapshot: SNMPSwitchSnapshot) -> String {
        if let controller = snapshot.controllerName { return controller }
        return snapshot.system.uptimeText ?? "—"
    }
}

/// Bandeau des FortiGate (notes 24 et 25) : « FortiGate utilisée : Siège (10.182.0.0/16) », la
/// liste quand plusieurs sites sont scannés, ou « Aucune FortiGate pour cette plage : SNMP
/// seulement » ; état de chaque lecture, relecture à la demande.
struct SwitchFortiGatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        if fortigate.isConfigured {
            let selection = currentSelection
            Panel(padding: 14) {
                AdaptiveStack(breakpoint: 900, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(SwitchSource.fortigate.colors.background)
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 15)).foregroundStyle(SwitchSource.fortigate.colors.foreground)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            headline(selection)
                                .font(Theme.bodySemibold)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !fortigate.isEnabled {
                                Text("Lecture des FortiGate désactivée dans Réglages › Switchs\u{00A0}: SNMP seulement.")
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            } else if selection.picks.count == 1, let pick = selection.picks.first {
                                pickDetail(pick)
                            } else if selection.picks.count > 1 {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(selection.picks) { pick in pickRow(pick) }
                                }
                                .padding(.top, 2)
                            } else {
                                Text(emptyDetail(selection))
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if fortigate.conflicts.contains(where: \.isAmbiguous) {
                                Label("Conflit de plages entre FortiGate\u{00A0}: voir Réglages › Switchs › Contrôleurs FortiGate.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(Theme.small).foregroundStyle(Theme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
                                Text(fortigate.isBusy ? "Lecture…" : (selection.picks.count > 1 ? "Relire les FortiGate" : "Relire la FortiGate"))
                            }
                        }
                        .buttonStyle(.secondary)
                        .disabled(fortigate.isBusy || !fortigate.isEnabled || selection.isEmpty || !(fortigate.isReady || fortigate.isDemo))
                        .help("Relit, par leur API REST (HTTPS, lecture seule), les FortiGate qui couvrent les plages cochées du Scanner (sinon l’adresse de ce Mac)\u{00A0}: FortiSwitch, ports et appareils détectés.")
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// Choix de la dernière lecture ; avant toute lecture, celui des plages cochées.
    private var currentSelection: FortiControllerSelection {
        fortigate.lastRefresh != nil ? fortigate.selection : fortigate.previewSelection(state: state)
    }

    private func headline(_ selection: FortiControllerSelection) -> Text {
        guard fortigate.isEnabled else { return Text("FortiGate\u{00A0}: lecture désactivée") }
        switch selection.picks.count {
        case 0:
            return Text("Aucune FortiGate pour cette plage\u{00A0}: SNMP seulement")
        case 1:
            let pick = selection.picks[0]
            return Text("FortiGate utilisée\u{00A0}: ") + Text(pick.site)
                + (pick.coveredRanges.isEmpty ? Text("") : Text(" (") + Text(pick.rangeLabel).font(Theme.mono(12.5, weight: .semibold)) + Text(")"))
        default:
            return Text("FortiGate utilisées\u{00A0}: \(selection.picks.count) sites")
        }
    }

    private func emptyDetail(_ selection: FortiControllerSelection) -> String {
        let ranges = selection.uncovered.prefix(3).joined(separator: ", ")
        let head = ranges.isEmpty ? "Ni les plages cochées ni l’adresse de ce Mac" : "\(ranges)\(selection.uncovered.count > 3 ? "…" : "")\u{00A0}:"
        return ranges.isEmpty
            ? "\(head) ne sont couvertes par une FortiGate de la liste. Ajoutez la plage au site concerné dans Réglages › Switchs."
            : "\(head) aucune FortiGate de la liste ne couvre ces adresses. Ajoutez la plage au site concerné dans Réglages › Switchs."
    }

    /// Détail d'une FortiGate choisie seule : sa lecture ou la raison de l'échec.
    private func pickDetail(_ pick: FortiControllerSelection.Pick) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusChip(pick.controllerID)
            detail(pick)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ligne d'une FortiGate parmi plusieurs.
    private func pickRow(_ pick: FortiControllerSelection.Pick) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusChip(pick.controllerID)
            (Text(pick.site).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text)
                + (pick.coveredRanges.isEmpty ? Text("") : Text(" (\(pick.rangeLabel))").font(Theme.mono(11.5)).foregroundStyle(Theme.text))
                + Text(" · ") + detail(pick))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ pick: FortiControllerSelection.Pick) -> Text {
        let id = pick.controllerID
        let why: String
        switch pick.reason {
        case .scannedRange: why = ""
        case .macAddress: why = "choisie par l’adresse de ce Mac · "
        case .noRanges: why = "plages couvertes à renseigner · "
        }
        if fortigate.runtime[id]?.busy == true { return Text(why + "lecture en cours…") }
        if let site = fortigate.sites.first(where: { $0.controllerID == id }) {
            let report = site.report
            let devices = report.locatedDevices.count
            return Text(why) + Text(report.controllerName).font(Theme.mono(11.5)).foregroundStyle(Theme.text)
                + Text(" · \(report.system.model) · \(report.system.versionLabel) · \(report.switches.count) FortiSwitch · \(devices) appareil\(devices > 1 ? "s" : "") détecté\(devices > 1 ? "s" : "") · lu \(SwitchText.ago(report.readAt)) · prioritaire sur SNMP")
        }
        if let c = fortigate.controller(id), let reason = fortigate.notReadyReason(c) { return Text(why + reason) }
        if let error = fortigate.runtime[id]?.error { return Text(why + error) }
        return Text(why + "Les FortiSwitch seront lus à la fin du prochain scan, ou avec «\u{00A0}Relire\u{00A0}».")
    }

    @ViewBuilder private func statusChip(_ id: UUID) -> some View {
        let r = fortigate.runtime[id]
        if r?.busy == true {
            Chip(text: "Lecture…", tone: .accent)
        } else if fortigate.sites.contains(where: { $0.controllerID == id }) {
            Chip(text: "Lue", tone: .success)
        } else if let c = fortigate.controller(id), !fortigate.hasToken(id), !fortigate.isDemo || c.lastStatus?.kind == .missingToken {
            Chip(text: "Jeton manquant", tone: .warning)
        } else if r?.pending != nil || fortigate.controller(id).map({ fortigate.notReadyReason($0) != nil }) == true {
            Chip(text: "À configurer", tone: .warning)
        } else if r?.error != nil {
            Chip(text: "Erreur", tone: .critical)
        } else {
            Chip(text: "Pas encore lue", tone: .neutral)
        }
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
                    let up = rows.filter { $0.stateRank == 0 }.count
                    Text("\(up) actif\(up > 1 ? "s" : "") sur \(rows.count) · d’après \(snapshot.controllerName ?? "la FortiGate")")
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
                    // « port10 » entier à côté de la puce « Uplink ».
                    Text(row.port).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                    if row.isUplink { SwitchSourceTag(source: .uplink) }
                }
            }
            .width(min: 116, ideal: 124)
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
        let uplinks = snapshot.locatedUplinks
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
