import NetScopeCore
import SwiftUI

@MainActor
final class ToolWakeModel: ObservableObject {
    enum PortChoice: String, CaseIterable, Identifiable {
        case nine, seven, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nine: return "9 (discard)"
            case .seven: return "7 (echo)"
            case .both: return "9 et 7"
            }
        }
        var ports: [UInt16] {
            switch self {
            case .nine: return [9]
            case .seven: return [7]
            case .both: return [9, 7]
            }
        }
    }

    @Published var macText = ""
    @Published var broadcastText = ""
    @Published var port: PortChoice = .nine
    @Published var error: String?
    @Published private(set) var lastSent: String?

    /// Délai de vérification après l'envoi.
    static let verifyDuration: TimeInterval = 60

    var command: String {
        "wol \(macText.trimmingCharacters(in: .whitespaces).uppercased()) -b \(broadcastText) -p " + port.ports.map(String.init).joined(separator: ",")
    }

    /// Envoie le paquet magique ; si l'adresse IP du poste est connue, vérifie pendant 60 s qu'il répond.
    func wake(state: AppState, store: ToolStore) {
        guard let mac = MACAddress(macText) else {
            error = "MAC invalide\u{00A0}: 12 caractères hexadécimaux attendus."
            return
        }
        guard let broadcast = IPv4Address(broadcastText) else {
            error = "Adresse de broadcast invalide (exemple\u{00A0}: 10.182.122.255)."
            return
        }
        error = nil
        let device = state.devices.first { $0.mac == mac }
        let name = device?.hostnameLabel ?? device?.displayName ?? "Manuel"
        store.record(command: command)
        let destination = "\(broadcast):" + port.ports.map(String.init).joined(separator: ",")
        do {
            try WakeOnLAN.send(to: mac, broadcast: broadcast, ports: port.ports)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.error = message
            store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon), detail: message, status: .failed))
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac.formatted(.upperColon))", summary: message, status: .failure))
            return
        }
        lastSent = "Paquet magique envoyé (102 octets) à \(destination)."
        guard let ip = device?.ip.description else {
            store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon),
                                        detail: "Paquet magique envoyé (102 octets) à \(destination) · adresse IP inconnue, pas de vérification",
                                        status: .sent))
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac.formatted(.upperColon))", summary: "Paquet envoyé à \(destination)", status: .info))
            return
        }
        let id = store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon),
                                             detail: "Paquet magique envoyé (102 octets) à \(destination) · vérification de \(ip) en cours",
                                             status: .pending))
        let start = Date()
        Task {
            while Date().timeIntervalSince(start) < ToolWakeModel.verifyDuration {
                if await PortScanner.isHostUp(host: ip, timeout: 1.5) {
                    let seconds = Int(Date().timeIntervalSince(start).rounded())
                    store.updateWake(id, status: .awake, detail: "Paquet envoyé à \(destination) · \(ip) répond après \(seconds)\u{00A0}s")
                    store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Réveillé après \(seconds)\u{00A0}s", status: .ok))
                    return
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            store.updateWake(id, status: .noReply, detail: "Aucune réponse de \(ip) après 60\u{00A0}s (WoL désactivé dans le BIOS\u{00A0}?)")
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Aucune réponse après 60\u{00A0}s", status: .warning))
        }
    }
}

/// Wake-on-LAN : MAC, broadcast, port, postes connus, historique des réveils.
struct WakeOnLANView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolWakeModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = WakeTargetTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Adresse MAC") {
                    ToolTextField(placeholder: "B0:7B:25:44:A1:6C", text: $model.macText,
                                  invalid: !model.macText.isEmpty && MACAddress(model.macText) == nil)
                }
                ToolLabeledField(label: "Broadcast") {
                    ToolTextField(placeholder: "10.182.122.255", text: $model.broadcastText,
                                  invalid: !model.broadcastText.isEmpty && IPv4Address(model.broadcastText) == nil)
                }
                ToolLabeledField(label: "Port UDP") {
                    Picker("", selection: $model.port) {
                        ForEach(ToolWakeModel.PortChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(height: 34)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text("Postes connus\u{00A0}: choisissez une ligne ou saisissez la MAC.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ToolColumnsMenu(model: table)
                Button { model.wake(state: state, store: store) } label: {
                    Label("Réveiller", systemImage: "power")
                }
                .buttonStyle(.primary)
                .fixedSize()
            }
            WakeTargetTable(devices: knownTargets, macText: $model.macText, table: table)
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            (Text("Paquet magique\u{00A0}: 6 × ") + Text("FF").font(Theme.mono(12)) + Text(" + 16 × MAC = 102 octets · un test de présence (connexion TCP) est fait pendant 60\u{00A0}s après l’envoi si l’adresse IP du poste est connue."))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            history
        }
        .onAppear {
            if model.broadcastText.isEmpty {
                model.broadcastText = WakeOnLAN.defaultBroadcast(for: state.activeInterface).description
            }
            if model.macText.isEmpty, let mac = knownTargets.first?.mac { model.macText = mac.formatted(.upperColon) }
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
    @ObservedObject var table: StandardTableModel<Device>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "ip", title: "IP"),
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
        "fabricant": KeyPathComparator(\Device.scanSortVendor),
        "vlan": KeyPathComparator(\Device.scanSortVLAN),
        "switch": KeyPathComparator(\Device.scanSortSwitch),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<Device> {
        StandardTableModel(id: "outils.wol", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    var body: some View {
        let rows = devices.sorted(using: table.sortOrder)
        let selection = Binding<Device.ID?>(
            get: { MACAddress(macText).flatMap { mac in rows.first { $0.mac == mac }?.id } },
            set: { id in
                if let id, let mac = rows.first(where: { $0.id == id })?.mac { macText = mac.formatted(.upperColon) }
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
                    ToolTableText(device.ip.description, size: 11)
                }
                .width(min: 90, ideal: 100)
                .customizationID("ip")

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
}
