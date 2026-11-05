import NetScopeCore
import SwiftUI

/// Wake-on-LAN : MAC, broadcast, port, postes connus, historique des réveils.
struct WakeOnLANView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolWakeModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = WakeTargetTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Adresse MAC") {
                    ToolTextField(placeholder: "B0:7B:25:44:A1:6C", text: $model.macText,
                                  invalid: !model.macText.isEmpty && MACAddress(model.macText) == nil)
                        .frame(minWidth: 180)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    // Note 78 : automatique = broadcast local, ou dirigé vers le sous-réseau d'un poste distant.
                    ToolLabeledField(label: "Diffusion") {
                        Picker("", selection: $model.broadcastMode) {
                            ForEach(WakeBroadcastMode.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.large)
                        .fixedSize()
                        .help("Automatique\u{00A0}: broadcast du réseau local, ou broadcast dirigé vers le sous-réseau d’un poste distant")
                    }
                    // Automatique : l'adresse de chaque poste est dans la colonne « Diffusion » du tableau.
                    if model.broadcastMode == .manual {
                        ToolLabeledField(label: "Broadcast") {
                            ToolTextField(placeholder: "10.182.122.255", text: $model.broadcastText,
                                          invalid: !model.broadcastText.isEmpty && IPv4Address(model.broadcastText) == nil)
                                .frame(minWidth: 130)
                        }
                    }
                    ToolLabeledField(label: "Port UDP") {
                        Picker("", selection: $model.port) {
                            ForEach(ToolWakeModel.PortChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.large)
                        .fixedSize()
                    }
                }
            }
            let known = knownTargets
            let chosen = known.filter { model.selection.contains($0.id) }.count
            HStack(alignment: .center, spacing: 12) {
                Text(chosen > 1 ? "\(chosen) postes choisis\u{00A0}: un paquet magique pour chacun, avec son suivi par ping."
                     : "Postes connus\u{00A0}: choisissez une ligne (⌘-clic pour plusieurs) ou saisissez la MAC.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ToolColumnsMenu(model: table)
                Button { model.wake(state: state, store: store, known: known) } label: {
                    Label(chosen > 1 ? "Réveiller les \(chosen) postes" : "Réveiller", systemImage: "power")
                }
                .buttonStyle(.primary)
                .fixedSize()
            }
            WakeTargetTable(devices: known, macText: $model.macText, selection: $model.selection, table: table,
                            local: state.activeInterface?.subnet)
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            (Text("Paquet magique\u{00A0}: 6 × ") + Text("FF").font(Theme.mono(12)) + Text(" + 16 × MAC = 102 octets · si l’adresse IP du poste est connue, il est suivi par ping (et un test TCP) pendant 2\u{00A0}min\u{00A0}: «\u{00A0}réveillé en N\u{00A0}s\u{00A0}». Un poste d’un autre sous-réseau reçoit un broadcast dirigé, que le routeur doit laisser passer (ip directed-broadcast)."))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            history
        }
        .onAppear {
            if model.broadcastText.isEmpty {
                model.broadcastText = WakeOnLAN.defaultBroadcast(for: state.activeInterface).description
            }
            if model.macText.isEmpty, let mac = knownTargets.first?.mac { model.macText = mac.formatted(.upperColon) }
            // Captures : réveil groupé de trois postes (note 78).
            if store.isEphemeral, WakeDemo.preselect, model.selection.isEmpty {
                model.selection = Set(knownTargets.filter { WakeDemo.selectedIPs.contains($0.ip.description) }.map(\.id))
            }
        }
    }

    /// Postes et serveurs de l'inventaire qui ont une MAC universelle (tous : le tableau défile).
    private var knownTargets: [Device] {
        InvModel.shared.withManualTypes(state.devices).filter { device in
            guard let mac = device.mac, !mac.isRandomized, device.ip != state.activeInterface?.address else { return false }
            return device.deviceType == .poste || device.deviceType == .serveur
        }
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                ToolFieldLabel("Historique des réveils")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.panelMuted)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if store.wakeLog.isEmpty {
                Text("Aucun réveil envoyé pour l’instant.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            ForEach(store.wakeLog) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Text(ToolText.time(entry.date)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 10) {
                            Text(entry.name).font(Theme.bodySemibold).lineLimit(1)
                            Text(entry.mac).font(Theme.mono(12))
                        }
                        Text(entry.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(text: entry.status.label, tone: entry.status.tone)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Postes réveillables

/// Postes et serveurs réveillables (tableau standard « outils.wol », note 8) : nom, IP, MAC, type,
/// état ; facultatives : fabricant, VLAN, switch / port. Choisir une ligne remplit la MAC.
struct WakeTargetTable: View {
    let devices: [Device]
    @Binding var macText: String
    /// Note 78 : plusieurs postes choisis (⌘-clic) : réveil groupé.
    @Binding var selection: Set<Device.ID>
    @ObservedObject var table: StandardTableModel<Device>
    /// Sous-réseau de l'interface active : un poste hors de lui reçoit un broadcast dirigé.
    var local: Subnet?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "diffusion", title: "Diffusion", isDefaultVisible: false),
        StandardColumn(id: "mac", title: "MAC"),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "fabricant", title: "Fabricant", isDefaultVisible: false),
        StandardColumn(id: "vlan", title: "VLAN", isDefaultVisible: false),
        StandardColumn(id: "switch", title: "Switch / port", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<Device>] = [
        "nom": KeyPathComparator(\Device.wakeSortName),
        "ip": KeyPathComparator(\Device.ip),
        "mac": KeyPathComparator(\Device.scanSortMAC),
        "type": KeyPathComparator(\Device.scanSortType),
        "etat": KeyPathComparator(\Device.scanSortStatus),
        "diffusion": KeyPathComparator(\Device.wakeSortSubnet),
        "fabricant": KeyPathComparator(\Device.scanSortVendor),
        "vlan": KeyPathComparator(\Device.scanSortVLAN),
        "switch": KeyPathComparator(\Device.scanSortSwitch),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<Device> {
        StandardTableModel(id: "outils.wol", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    /// Poste hors du sous-réseau de ce Mac : broadcast dirigé (mode automatique).
    private func isDirected(_ device: Device) -> Bool {
        local.map { !$0.contains(device.ip) } ?? false
    }

    private func directedHelp(_ device: Device) -> String {
        "Autre sous-réseau\u{00A0}: broadcast dirigé vers \(WakeOnLAN.directedBroadcast(for: device.ip).description) en mode automatique (le routeur doit le laisser passer)"
    }

    var body: some View {
        let rows = devices.sorted(using: table.sortOrder)
        let selection = Binding<Set<Device.ID>>(
            get: {
                if !self.selection.isEmpty { return self.selection }
                return MACAddress(macText).flatMap { mac in rows.first { $0.mac == mac }?.id }.map { [$0] } ?? []
            },
            set: { ids in
                self.selection = ids
                if ids.count == 1, let id = ids.first, let mac = rows.first(where: { $0.id == id })?.mac {
                    macText = mac.formatted(.upperColon)
                }
            })
        ToolStandardTableFrame(rowCount: rows.count, maxRows: 6,
                               emptyText: "Aucun poste avec une adresse MAC dans l’inventaire.") {
            Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("NOM", sortUsing: table.sort("nom")) { device in
                    ToolTableText(device.wakeSortName, size: 11, mono: false, weight: .semibold)
                }
                .width(min: 60, ideal: 72)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("IP", sortUsing: table.sort("ip")) { device in
                    // Note 78 : un poste d'un autre sous-réseau recevra un broadcast dirigé.
                    HStack(spacing: 4) {
                        ToolTableText(device.ip.description, size: 11)
                        if isDirected(device) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accentStrong)
                                .help(directedHelp(device))
                                .accessibilityLabel("Broadcast dirigé")
                        }
                    }
                }
                .width(min: 90, ideal: 100)
                .customizationID("ip")

                TableColumn("DIFFUSION", sortUsing: table.sort("diffusion")) { device in
                    let directed = isDirected(device)
                    ToolTableText(directed ? "dirigée" : "locale", size: 11, mono: false,
                                  color: directed ? Theme.accentStrong : Theme.textSecondary)
                        .help(directed ? directedHelp(device) : "Même sous-réseau que ce Mac\u{00A0}: broadcast local")
                }
                .width(min: 50, ideal: 64)
                .customizationID("diffusion")
                .defaultVisibility(.hidden)

                TableColumn("MAC", sortUsing: table.sort("mac")) { device in
                    ToolTableText(device.mac?.formatted(.upperColon) ?? "—", size: 11)
                }
                .width(min: 110, ideal: 118)
                .customizationID("mac")

                TableColumn("TYPE", sortUsing: table.sort("type")) { device in
                    HStack(spacing: 5) {
                        Image(systemName: device.deviceType.symbolName)
                            .font(.system(size: 11)).foregroundStyle(Theme.neutralText).frame(width: 16)
                        ToolTableText(device.deviceType.label, size: 11, mono: false, color: Theme.neutralText)
                    }
                }
                .width(min: 60, ideal: 108)
                .customizationID("type")

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { device in
                    HStack(spacing: 6) {
                        ScanStatusDot(online: device.isOnline)
                        ToolTableText(device.isOnline ? "En ligne" : "Hors ligne", size: 11, mono: false,
                                      color: device.isOnline ? Theme.success : Theme.textSecondary)
                    }
                }
                .width(min: 60, ideal: 72)
                .customizationID("etat")

                TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { device in
                    ToolTableText(device.vendorLabel, mono: false, color: Theme.neutralText)
                }
                .width(min: 70, ideal: 110)
                .customizationID("fabricant")
                .defaultVisibility(.hidden)

                TableColumn("VLAN", sortUsing: table.sort("vlan")) { device in
                    ToolTableText(device.vlan.map(String.init) ?? "—", color: device.vlan == nil ? Theme.textTertiary : Theme.text)
                }
                .width(min: 40, ideal: 56)
                .customizationID("vlan")
                .defaultVisibility(.hidden)

                TableColumn("SWITCH / PORT", sortUsing: table.sort("switch")) { device in
                    ToolTableText(device.switchLocation ?? "—",
                                  color: device.switchLocation == nil ? Theme.textTertiary : Theme.text)
                }
                .width(min: 90, ideal: 140)
                .customizationID("switch")
                .defaultVisibility(.hidden)
            }
        }
    }
}

extension Device {
    /// Nom affiché dans la liste des postes réveillables (hostname, sinon nom affiché).
    var wakeSortName: String { hostnameLabel ?? displayName }
    /// Tri de la colonne « Diffusion » : par sous-réseau (/24).
    var wakeSortSubnet: UInt32 { ip.value >> 8 }
}
