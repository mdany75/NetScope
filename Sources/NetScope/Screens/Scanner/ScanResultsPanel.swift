import AppKit
import NetScopeCore
import SwiftUI

/// Filtres du tableau des résultats.
struct ScanFilter: Equatable {
    enum Quick: String, CaseIterable, Identifiable {
        case all, online, offline, new, web
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "Tous"
            case .online: return "En ligne"
            case .offline: return "Hors ligne"
            case .new: return "Nouveaux"
            case .web: return "Ports web"
            }
        }

        var dot: Color? {
            switch self {
            case .all: return nil
            case .online: return Theme.success
            case .offline: return Theme.textTertiary
            case .new: return Theme.accent
            case .web: return Theme.accentStrong
            }
        }
    }

    var quick: Quick = .all
    var rangeID: UUID?
    var vlan: Int?
}

/// Résultats du scan : filtres, tableau trié, pied avec les totaux.
struct ScanResultsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController
    @Binding var filter: ScanFilter
    @Binding var sortOrder: [KeyPathComparator<Device>]

    /// Appareils après la recherche, la plage et le VLAN (avant le filtre rapide).
    static func scoped(state: AppState, filter: ScanFilter) -> [Device] {
        let range = filter.rangeID.flatMap { id in state.ranges.first { $0.id == id } }.flatMap { try? $0.parsed() }
        return state.filteredDevices.filter { device in
            if filter.rangeID != nil, !(range?.contains(device.ip) ?? false) { return false }
            if let vlan = filter.vlan, device.vlan != vlan { return false }
            return true
        }
    }

    static func matches(_ device: Device, _ quick: ScanFilter.Quick, newIDs: Set<Device.ID>) -> Bool {
        switch quick {
        case .all: return true
        case .online: return device.isOnline
        case .offline: return !device.isOnline
        case .new: return newIDs.contains(device.id)
        case .web: return device.scanHasWebPort
        }
    }

    /// Lignes affichées, filtrées et triées (aussi pour l'export).
    static func visibleRows(state: AppState, scan: ScanController, filter: ScanFilter,
                            sortOrder: [KeyPathComparator<Device>]) -> [Device] {
        scoped(state: state, filter: filter)
            .filter { matches($0, filter.quick, newIDs: scan.newIDs) }
            .sorted(using: sortOrder)
    }

    private func matches(_ device: Device, _ quick: ScanFilter.Quick) -> Bool {
        ScanResultsPanel.matches(device, quick, newIDs: scan.newIDs)
    }

    var body: some View {
        let scoped = ScanResultsPanel.scoped(state: state, filter: filter)
        let rows = scoped.filter { matches($0, filter.quick) }.sorted(using: sortOrder)
        VStack(spacing: 0) {
            filterBar(scoped)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyView
            } else {
                ScanDeviceTable(rows: rows, scan: scan, sortOrder: $sortOrder)
            }
            footer(shown: rows.count, inView: scoped.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Filtres

    private func filterBar(_ scoped: [Device]) -> some View {
        // Les éléments passent à la ligne quand le panneau est étroit (comme le croquis).
        ScanFlowLayout(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("", text: $state.searchText, prompt: Text("Filtrer : IP, MAC, hostname…").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.small)
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))

            ForEach(ScanFilter.Quick.allCases) { quick in
                ScanQuickChip(quick: quick, count: scoped.filter { matches($0, quick) }.count,
                              isSelected: filter.quick == quick) { filter.quick = quick }
                    .fixedSize()
            }
            rangePicker
            vlanPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var rangePicker: some View {
        Menu {
            Button("Toutes les plages") { filter.rangeID = nil }
            Divider()
            ForEach(state.ranges) { range in
                Button("\(range.text) · \(range.label)") { filter.rangeID = range.id }
            }
        } label: {
            Text(filter.rangeID.flatMap { id in state.ranges.first { $0.id == id }?.text } ?? "Toutes les plages")
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .font(Theme.small)
        .fixedSize()
    }

    private var vlanPicker: some View {
        let vlans = Array(Set(state.devices.compactMap(\.vlan) + state.ranges.compactMap(\.vlan))).sorted()
        return Menu {
            Button("Tous les VLAN") { filter.vlan = nil }
            Divider()
            ForEach(vlans, id: \.self) { vlan in
                Button(vlanLabel(vlan)) { filter.vlan = vlan }
            }
        } label: {
            Text(filter.vlan.map(vlanLabel) ?? "Tous les VLAN")
        }
        .menuStyle(.button)
        .font(Theme.small)
        .fixedSize()
    }

    /// « VLAN 40 · Caméras » si une plage porte ce VLAN.
    private func vlanLabel(_ vlan: Int) -> String {
        if let range = state.ranges.first(where: { $0.vlan == vlan }) { return "VLAN \(vlan) · \(range.label)" }
        return "VLAN \(vlan)"
    }

    // MARK: États vides et pied

    @ViewBuilder private var emptyView: some View {
        if state.devices.isEmpty {
            EmptyState(systemImage: "dot.radiowaves.left.and.right", title: "Aucun appareil pour l’instant",
                       message: "Cochez les plages à scanner, puis lancez le scan. Les appareils apparaissent au fur et à mesure.") {
                Button { scan.start(state) } label: { Label("Lancer le scan", systemImage: "play.fill") }
                    .buttonStyle(.primary)
                    .disabled(scan.isRunning)
            }
        } else {
            let query = state.searchText.trimmingCharacters(in: .whitespaces)
            EmptyState(systemImage: "line.3.horizontal.decrease.circle", title: "Aucun résultat",
                       message: query.isEmpty ? "Aucun appareil ne correspond aux filtres actifs."
                           : "Aucun appareil ne correspond à « \(query) » avec les filtres actifs.") {
                Button("Réinitialiser les filtres") {
                    filter = ScanFilter()
                    state.searchText = ""
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private func footer(shown: Int, inView: Int) -> some View {
        let devices = state.devices
        let online = devices.filter(\.isOnline).count
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                footerCount(devices.count, "appareils", color: Theme.text)
                footerCount(online, "vus récemment", color: Theme.success)
                footerCount(scan.newIDs.count, "nouveaux", color: Theme.accentStrong)
                Spacer(minLength: 8)
                Text("\(shown) affichés sur \(inView) dans cette vue")
                Text("Durée du scan : \(durationLabel(at: context.date))").font(Theme.mono(12))
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.panelMuted)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private func footerCount(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            Text(label)
        }
    }

    private func durationLabel(at now: Date) -> String {
        guard let duration = scan.duration(at: now) else { return "—" }
        return ScanFormat.seconds(duration) + (scan.isRunning ? " (en cours)" : "")
    }
}

/// Puce de filtre rapide du croquis : pastille colorée, libellé, compteur.
struct ScanQuickChip: View {
    let quick: ScanFilter.Quick
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot = quick.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(quick.label).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(isSelected ? Theme.accentStrong : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(isSelected ? Theme.accentSoft : Theme.panel))
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tableau

struct ScanDeviceTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var switches = SwitchStore.shared
    let rows: [Device]
    @ObservedObject var scan: ScanController
    @Binding var sortOrder: [KeyPathComparator<Device>]

    var body: some View {
        Table(rows, selection: $state.selectedDeviceID, sortOrder: $sortOrder) {
            TableColumn("IP", value: \Device.ip) { device in
                HStack(spacing: 8) {
                    ScanStatusDot(online: device.isOnline)
                    Text(device.ip.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                .frame(height: 26)
            }
            .width(min: 118, ideal: 128)

            TableColumn("NOM PERSONNALISÉ", value: \Device.scanSortName) { device in
                HStack(spacing: 6) {
                    Text(device.customName ?? "—")
                        .font(Theme.small)
                        .foregroundStyle(device.customName == nil ? Theme.textTertiary : Theme.text)
                        .lineLimit(1)
                    if scan.newIDs.contains(device.id) { ScanNewBadge() }
                }
            }
            .width(min: 100, ideal: 125)

            TableColumn("HOSTNAME", value: \Device.scanSortHostname) { device in
                ScanCellText(device.hostnameLabel ?? "—", dimmed: device.hostname == nil)
                    .help(device.nameSourceLabel.map { "Nom obtenu par \($0)" } ?? "")
            }
            .width(min: 100, ideal: 135)

            TableColumn("FABRICANT", value: \Device.scanSortVendor) { device in
                ScanCellText(device.vendorLabel, dimmed: device.vendor == nil && device.mac == nil)
            }
            .width(min: 80, ideal: 95)

            TableColumn("MAC", value: \Device.scanSortMAC) { device in
                ScanCellText(device.mac?.formatted(.upperColon) ?? "—", mono: true, dimmed: device.mac == nil)
            }
            .width(min: 120, ideal: 128)

            TableColumn("LATENCE", value: \Device.scanSortLatency) { device in
                Text(ScanFormat.latency(device.latencyMs))
                    .font(Theme.mono(12))
                    .foregroundStyle(latencyColor(device.latencyMs))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 72)

            TableColumn("PORTS OUVERTS", value: \Device.scanSortPorts) { device in
                ScanPortTags(ports: device.openPorts)
            }
            .width(min: 100, ideal: 130)

            TableColumn("SWITCH / PORT", value: \Device.scanSortSwitch) { device in
                let status = state.locationStatus(device)
                ScanCellText(device.switchLocation ?? "—", mono: true, dimmed: device.switchLocation == nil || !status.isCurrent)
                    .help(device.switchLocation != nil ? status.explanation ?? "" : "")
            }
            .width(min: 110, ideal: 150)

            TableColumn("VLAN", value: \Device.scanSortVLAN) { device in
                if let vlan = device.vlan {
                    Chip(text: "\(vlan)", mono: true)
                        .opacity(state.vlanStatus(device).isCurrent ? 1 : 0.5)
                } else {
                    ScanCellText("—", dimmed: true)
                }
            }
            .width(min: 44, ideal: 52)

            TableColumn("VU LA DERNIÈRE FOIS", value: \Device.lastSeen) { device in
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScanCellText(ScanFormat.relative(device.lastSeen, now: context.date), secondary: true)
                }
            }
            .width(min: 90, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            if let id = ids.first, let device = state.device(withID: id) {
                ScanDeviceMenu(device: device, scan: scan)
            }
        } primaryAction: { ids in
            if let id = ids.first { state.showDevice(id) }
        }
    }

    private func latencyColor(_ value: Double?) -> Color {
        guard let value else { return Theme.textTertiary }
        return value > 15 ? Theme.warning : Theme.text
    }
}

/// Menu contextuel d'un appareil (tableau).
struct ScanDeviceMenu: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    @ObservedObject var scan: ScanController

    var body: some View {
        Button("Copier l’IP") { scan.copy(device.ip.description, label: "IP") }
        Button("Copier la MAC") { if let mac = device.mac { scan.copy(mac.formatted(.upperColon), label: "MAC") } }
            .disabled(device.mac == nil)
        Divider()
        Button("Ping continu") { state.sendToPing(device.ip.description) }
        Button("Ouvrir dans le navigateur (http)") { ScanFormat.open(URL(string: "http://\(device.ip)")!) }
        Button("Ouvrir dans le navigateur (https)") { ScanFormat.open(URL(string: "https://\(device.ip)")!) }
        Button("Scanner les ports (approfondi, \(ScanProfile.extendedPorts.count) ports)") { scan.probePorts(of: device, state: state) }
        Button("Wake-on-LAN") { scan.wake(device, state: state) }.disabled(device.mac == nil)
        Divider()
        Button("Voir la fiche complète") { state.showDevice(device.id) }
    }
}

// MARK: - Cellules

/// Pastille d'état du croquis : pleine et verte en ligne, anneau gris hors ligne.
struct ScanStatusDot: View {
    let online: Bool

    var body: some View {
        Group {
            if online {
                Circle().fill(Theme.success)
            } else {
                Circle().strokeBorder(Theme.textTertiary, lineWidth: 2)
            }
        }
        .frame(width: 9, height: 9)
        .help(online ? "En ligne" : "Hors ligne")
    }
}

struct ScanNewBadge: View {
    var body: some View {
        Text("NOUVEAU")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.accentStrong)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xDBEAFE)))
            .fixedSize()
    }
}

struct ScanCellText: View {
    let text: String
    var mono = false
    var dimmed = false
    var secondary = false

    init(_ text: String, mono: Bool = false, dimmed: Bool = false, secondary: Bool = false) {
        self.text = text
        self.mono = mono
        self.dimmed = dimmed
        self.secondary = secondary
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(12) : Theme.small)
            .foregroundStyle(dimmed ? Theme.textTertiary : (secondary ? Theme.textSecondary : Theme.neutralText))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Étiquettes de ports (4 au plus, ports web en bleu).
struct ScanPortTags: View {
    let ports: [UInt16]

    var body: some View {
        if ports.isEmpty {
            ScanCellText("—", dimmed: true)
        } else {
            HStack(spacing: 3) {
                ForEach(ports.prefix(4), id: \.self) { port in
                    Text("\(port)")
                        .font(Theme.mono(11))
                        .foregroundStyle(ScanFormat.webPorts.contains(port) ? Theme.accentStrong : Theme.neutralText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(ScanFormat.webPorts.contains(port) ? Color(hex: 0xDBEAFE) : Theme.neutralSoft))
                }
                if ports.count > 4 {
                    Text("+\(ports.count - 4)").font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .help(ports.map(String.init).joined(separator: ", "))
        }
    }
}
