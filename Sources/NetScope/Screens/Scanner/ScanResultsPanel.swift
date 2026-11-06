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
    @ObservedObject var table: StandardTableModel<Device>
    @ObservedObject private var inventory = InvModel.shared

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

    /// Lignes affichées, filtrées et triées (aussi pour l'export), avec le type choisi à la main.
    static func visibleRows(state: AppState, scan: ScanController, filter: ScanFilter,
                            sortOrder: [KeyPathComparator<Device>]) -> [Device] {
        InvModel.shared.withManualTypes(scoped(state: state, filter: filter)
            .filter { matches($0, filter.quick, newIDs: scan.newIDs) })
            .sorted(using: sortOrder)
    }

    private func matches(_ device: Device, _ quick: ScanFilter.Quick) -> Bool {
        ScanResultsPanel.matches(device, quick, newIDs: scan.newIDs)
    }

    var body: some View {
        let scoped = ScanResultsPanel.scoped(state: state, filter: filter)
        let rows = ScanResultsPanel.visibleRows(state: state, scan: scan, filter: filter, sortOrder: table.sortOrder)
        VStack(spacing: 0) {
            filterBar(scoped)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyView
            } else {
                ScanDeviceTable(rows: rows, scan: scan, table: table)
            }
            footer(shown: rows.count, inView: scoped.count)
        }
        .searchResults(rows.count, "appareil", "appareils")
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
                    .help(SearchTokensBar.help(.scanner, .scanner))
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
            StandardColumnsMenu(model: table)
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
            let navFilter = state.navFilters[.scanner]
            EmptyState(systemImage: "line.3.horizontal.decrease.circle", title: "Aucun résultat",
                       message: navFilter.map { "Aucun appareil du filtre «\u{00A0}\($0.label)\u{00A0}» n’est dans le dernier scan." }
                           ?? (query.isEmpty ? "Aucun appareil ne correspond aux filtres actifs."
                               : "Aucun appareil ne correspond à « \(query) » avec les filtres actifs.")) {
                Button("Réinitialiser les filtres") {
                    filter = ScanFilter()
                    state.searchText = ""
                    state.navFilters[.scanner] = nil
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
                if let probe = scan.portProbe {
                    Text("Ports\u{00A0}: \(probe.done)/\(probe.total) appareils")
                        .monospacedDigit()
                        .help("Sonde des ports en cours (\(probe.label))\u{00A0}; bouton Arrêter pour l’interrompre")
                }
                // Même police que le reste du pied ; chiffres à chasse fixe pour que la durée ne danse pas.
                Text("Durée du scan\u{00A0}: \(durationLabel(at: context.date))").monospacedDigit()
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

/// Tableau des appareils : tableau standard (note 8), colonnes facultatives masquées par défaut,
/// sélection multiple pour le menu contextuel (type, ports).
struct ScanDeviceTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var switches = SwitchStore.shared
    @ObservedObject private var inventory = InvModel.shared
    @ObservedObject private var fortiAP = FortiAPStore.shared
    /// Appareils affichés, avec le type choisi à la main.
    let rows: [Device]
    @ObservedObject var scan: ScanController
    @ObservedObject var table: StandardTableModel<Device>
    @State private var selection: Set<Device.ID> = []

    // MARK: Colonnes

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ip", title: "IP", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "nom", title: "Nom personnalisé"),
        // Hostname, latence et dernière vue : facultatifs (on les rajoute par « Colonnes ») ; à côté du
        // panneau de détail, le tableau défile horizontalement plutôt que de rogner Type et Nom.
        StandardColumn(id: "hostname", title: "Hostname", isDefaultVisible: false),
        StandardColumn(id: "mac", title: "MAC"),
        StandardColumn(id: "switch", title: "Switch / port"),
        StandardColumn(id: "vlan", title: "VLAN"),
        // « Suis-je sur un port PoE ? » (note 12) : d'après le relevé SNMP du switch où l'appareil est localisé.
        StandardColumn(id: "poe", title: "PoE", isDefaultVisible: false),
        StandardColumn(id: "fabricant", title: "Fabricant"),
        StandardColumn(id: "ports", title: "Ports ouverts"),
        StandardColumn(id: "latence", title: "Latence", isDefaultVisible: false),
        StandardColumn(id: "derniereVue", title: "Vu la dernière fois", isDefaultVisible: false),
        StandardColumn(id: "premiereVue", title: "Première vue", isDefaultVisible: false),
        StandardColumn(id: "sourceNom", title: "Source du nom", isDefaultVisible: false),
        StandardColumn(id: "groupe", title: "Groupe NetBIOS", isDefaultVisible: false),
        StandardColumn(id: "plage", title: "Plage", isDefaultVisible: false),
        StandardColumn(id: "snmp", title: "Nature SNMP", isDefaultVisible: false),
        // Note 68 : empreinte légère (système déduit, versions annoncées).
        StandardColumn(id: "systeme", title: "Système", isDefaultVisible: false),
        StandardColumn(id: "version", title: "Versions", isDefaultVisible: false),
        StandardColumn(id: "oui", title: "OUI", isDefaultVisible: false),
        StandardColumn(id: "emplacement", title: "État de l’emplacement", isDefaultVisible: false),
        // Note 27 : client Wi-Fi vu par la FortiGate (borne FortiAP et SSID), comme Switch / port.
        StandardColumn(id: "borneWifi", title: "Borne Wi-Fi", isDefaultVisible: false),
        StandardColumn(id: "ssid", title: "SSID", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<Device>] = [
        "ip": KeyPathComparator(\Device.ip),
        "type": KeyPathComparator(\Device.scanSortType),
        "nom": KeyPathComparator(\Device.scanSortName),
        "hostname": KeyPathComparator(\Device.scanSortHostname),
        "fabricant": KeyPathComparator(\Device.scanSortVendor),
        "mac": KeyPathComparator(\Device.scanSortMAC),
        "latence": KeyPathComparator(\Device.scanSortLatency),
        "ports": KeyPathComparator(\Device.scanSortPorts),
        "switch": KeyPathComparator(\Device.scanSortSwitch),
        "poe": KeyPathComparator(\Device.scanSortPoE),
        "vlan": KeyPathComparator(\Device.scanSortVLAN),
        "derniereVue": KeyPathComparator(\Device.lastSeen),
        "premiereVue": KeyPathComparator(\Device.firstSeen),
        "sourceNom": KeyPathComparator(\Device.scanSortNameSource),
        "groupe": KeyPathComparator(\Device.scanSortDomain),
        "plage": KeyPathComparator(\Device.scanSortRange),
        "snmp": KeyPathComparator(\Device.scanSortSNMP),
        "systeme": KeyPathComparator(\Device.scanSortSystem),
        "version": KeyPathComparator(\Device.scanSortVersions),
        "oui": KeyPathComparator(\Device.scanSortVendorOUI),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<Device> {
        StandardTableModel(id: "scanner", columns: columns, sortKeys: sortKeys, defaultSort: "ip")
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("IP"), sortUsing: table.sort("ip")) { device in
                    HStack(spacing: 8) {
                        ScanStatusDot(online: device.isOnline)
                        Text(device.ip.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .frame(height: 26)
                }
                .width(min: 122, ideal: 122)
                .customizationID("ip")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("TYPE"), sortUsing: table.sort("type")) { device in
                    ScanTypeCell(type: device.deviceType, isManual: inventory.typeChoice(for: device).isManual,
                                 role: RustDeskPorts.role(openPorts: device.openPorts))
                }
                // Emplacement (Switch / port, VLAN) juste après la MAC : si le tableau défile
                // horizontalement, ce sont Fabricant et Ports qui sortent de la vue en premier.
                .width(min: 112, ideal: 128)
                .customizationID("type")

                TableColumn(StandardTableHeading("NOM"), sortUsing: table.sort("nom")) { device in
                    HStack(spacing: 6) {
                        Text(device.customName ?? "—")
                            .font(Theme.small)
                            .foregroundStyle(device.customName == nil ? Theme.textTertiary : Theme.text)
                            .lineLimit(1)
                        if scan.newIDs.contains(device.id) { ScanNewBadge() }
                    }
                }
                .width(min: 120, ideal: 150)
                .customizationID("nom")

                TableColumn(StandardTableHeading("HOSTNAME"), sortUsing: table.sort("hostname")) { device in
                    ScanCellText(device.hostnameLabel ?? "—", dimmed: device.hostname == nil)
                        .help(device.nameSourceLabel.map { "Nom obtenu par \($0)" } ?? "")
                }
                .width(min: 100, ideal: 135)
                .customizationID("hostname")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("MAC"), sortUsing: table.sort("mac")) { device in
                    ScanCellText(device.mac?.formatted(.upperColon) ?? "—", mono: true, dimmed: device.mac == nil)
                }
                // Toujours l'adresse complète (17 caractères en chasse fixe).
                .width(min: 132, ideal: 132)
                .customizationID("mac")

                TableColumn(StandardTableHeading("SWITCH / PORT"), sortUsing: table.sort("switch")) { device in
                    let status = state.locationStatus(device)
                    SwitchPortCell(name: device.switchName, port: device.switchPort, dimmed: !status.isCurrent,
                                   note: status.explanation)
                }
                .width(min: 94, ideal: 110)
                .customizationID("switch")

                TableColumn(StandardTableHeading("VLAN"), sortUsing: table.sort("vlan")) { device in
                    if let vlan = device.vlan {
                        Chip(text: "\(vlan)", mono: true)
                            .opacity(state.vlanStatus(device).isCurrent ? 1 : 0.5)
                    } else {
                        ScanCellText("—", dimmed: true)
                    }
                }
                .width(min: 40, ideal: 44)
                .customizationID("vlan")

                TableColumn(StandardTableHeading("POE"), sortUsing: table.sort("poe")) { device in
                    PoECell(status: switches.poeStatus(for: device), dimmed: !state.locationStatus(device).isCurrent)
                }
                .width(min: 70, ideal: 140)
                .customizationID("poe")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("FABRICANT"), sortUsing: table.sort("fabricant")) { device in
                    ScanCellText(device.vendorLabel, dimmed: device.vendor == nil && device.mac == nil)
                }
                .width(min: 70, ideal: 90)
                .customizationID("fabricant")

                TableColumn(StandardTableHeading("PORTS"), sortUsing: table.sort("ports")) { device in
                    ScanPortTags(ports: device.openPorts)
                }
                .width(min: 58, ideal: 66)
                .customizationID("ports")







            }

            Group {
                TableColumn(StandardTableHeading("LATENCE"), sortUsing: table.sort("latence")) { device in
                    Text(ScanFormat.latency(device.latencyMs))
                        .font(Theme.mono(12))
                        .foregroundStyle(latencyColor(device.latencyMs))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 72)
                .customizationID("latence")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("VU LA DERNIÈRE FOIS"), sortUsing: table.sort("derniereVue")) { device in
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScanCellText(ScanFormat.relative(device.lastSeen, now: context.date), secondary: true)
                    }
                }
                .width(min: 90, ideal: 120)
                .customizationID("derniereVue")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("PREMIÈRE VUE"), sortUsing: table.sort("premiereVue")) { device in
                    ScanCellText(ScanFormat.date(device.firstSeen), secondary: true)
                }
                .width(min: 110, ideal: 150)
                .customizationID("premiereVue")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("SOURCE DU NOM"), sortUsing: table.sort("sourceNom")) { device in
                    ScanCellText(device.nameSourceLabel ?? "—", dimmed: device.nameSourceLabel == nil)
                }
                .width(min: 80, ideal: 165)
                .customizationID("sourceNom")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("GROUPE NETBIOS"), sortUsing: table.sort("groupe")) { device in
                    ScanCellText(device.nameDomain ?? "—", mono: true, dimmed: device.nameDomain == nil)
                }
                .width(min: 80, ideal: 135)
                .customizationID("groupe")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("PLAGE"), sortUsing: table.sort("plage")) { device in
                    ScanCellText(device.rangeLabel ?? "—", dimmed: device.rangeLabel == nil)
                }
                .width(min: 70, ideal: 100)
                .customizationID("plage")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("NATURE SNMP"), sortUsing: table.sort("snmp")) { device in
                    ScanCellText(device.snmpKind?.label ?? "—", dimmed: device.snmpKind == nil)
                        .help(device.snmpKind == nil ? "N’a pas répondu à la découverte SNMP" : "D’après la découverte SNMP")
                }
                .width(min: 70, ideal: 150)
                .customizationID("snmp")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("OUI"), sortUsing: table.sort("oui")) { device in
                    ScanCellText(device.scanSortVendorOUI.isEmpty ? "—" : device.scanSortVendorOUI, mono: true,
                                 dimmed: device.mac == nil)
                }
                .width(min: 70, ideal: 80)
                .customizationID("oui")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("ÉTAT DE L’EMPLACEMENT")) { device in
                    let status = state.locationStatus(device)
                    ScanCellText(device.switchName == nil ? "—" : Self.locationLabel(status),
                                 dimmed: device.switchName == nil || !status.isCurrent)
                        .help(device.switchName == nil ? "" : status.explanation ?? "Relevé sur le réseau actuel")
                }
                .width(min: 90, ideal: 175)
                .customizationID("emplacement")
                .defaultVisibility(.hidden)
            }

            Group {
                TableColumn(StandardTableHeading("BORNE WI-FI")) { device in
                    let client = fortiAP.client(for: device)
                    ScanCellText(client.map { c in [c.apName ?? "?", c.band?.label, c.rssi.map(WifiQuality.dbm)].compactMap { $0 }.joined(separator: " · ") } ?? "—",
                                 mono: client != nil, dimmed: client == nil)
                        .help(client.map { "Client Wi-Fi vu par la FortiGate «\u{00A0}\($0.site)\u{00A0}»" + ($0.channel.map { ", canal \($0)" } ?? "") } ?? "")
                }
                .width(min: 90, ideal: 170)
                .customizationID("borneWifi")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("SSID")) { device in
                    let ssid = fortiAP.client(for: device)?.ssid
                    ScanCellText(ssid ?? "—", dimmed: ssid == nil)
                }
                .width(min: 70, ideal: 110)
                .customizationID("ssid")
                .defaultVisibility(.hidden)
            }

            // Note 68 : système déduit (confiance, indices en infobulle) et versions annoncées.
            Group {
                TableColumn(StandardTableHeading("SYSTÈME"), sortUsing: table.sort("systeme")) { device in
                    ScanSystemCell(device: device)
                }
                .width(min: 90, ideal: 190)
                .customizationID("systeme")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("VERSIONS"), sortUsing: table.sort("version")) { device in
                    ScanVersionsCell(device: device)
                }
                .width(min: 90, ideal: 180)
                .customizationID("version")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 34 : double-clic ou ↩︎ → fiche Appareil ; clic droit → « Ouvrir dans › ».
        .standardRowActions(selection: rows.map(\.id).filter(selection.contains), object: { id in
            state.device(withID: id).map { .device(NavDeviceRef($0)) }
        }) { ids in
            let devices = ids.compactMap { state.device(withID: $0) }.sorted { $0.ip < $1.ip }
            if !devices.isEmpty {
                ScanDeviceMenu(devices: devices, scan: scan)
            }
        }
        .onAppear {
            selection = state.selectedDeviceID.map { [$0] } ?? []
            Self.applySnapshotColumns(to: table)
        }
        // Note 45 : au retour, l'appareil choisi est ramené en vue (même position dans la liste).
        .revealRow(id: state.selectedDeviceID) { state.selectedDeviceID.flatMap { id in rows.firstIndex { $0.id == id } } }
        .onChange(of: selection) { _, ids in
            // Le panneau de détail suit la ligne choisie (la première d'une sélection multiple).
            if let current = state.selectedDeviceID, ids.contains(current) { return }
            state.selectedDeviceID = rows.first { ids.contains($0.id) }?.id
        }
        .onChange(of: state.selectedDeviceID) { _, id in
            if let id, !selection.contains(id) { selection = [id] }
        }
    }

    private func latencyColor(_ value: Double?) -> Color {
        guard let value else { return Theme.textTertiary }
        return value > 15 ? Theme.warning : Theme.text
    }

    static func locationLabel(_ status: LocationStatus) -> String {
        switch status {
        case .current: return "Actuel"
        case .rangeUnchecked: return "Plage décochée"
        case .networkChanged: return "Réseau changé"
        case .unconfirmed: return "Non confirmé"
        }
    }
}

/// Menu contextuel d'un ou de plusieurs appareils (tableau).
struct ScanDeviceMenu: View {
    @EnvironmentObject private var state: AppState
    let devices: [Device]
    @ObservedObject var scan: ScanController

    var body: some View {
        if devices.count == 1, let device = devices.first {
            Button("Copier l’IP") { scan.copy(device.ip.description, label: "IP") }
            Button("Copier la MAC") { if let mac = device.mac { scan.copy(mac.formatted(.upperColon), label: "MAC") } }
                .disabled(device.mac == nil)
            Divider()
            Button("Ping continu") { state.sendToPing(device.ip.description) }
            // Note 52 : utilisateur demandé (ou retenu) avant ssh user@ip.
            Button("Se connecter en SSH…") { QuickLoginModel.shared.ask(QuickLoginTarget(device: device)) }
            // Note 50 : FTP, FTPS ou SFTP si le port est ouvert au dernier scan.
            FileTransferOpenMenu(host: device.ip.description, name: device.displayName, openPorts: device.openPorts, deviceID: device.id)
            Button("Ouvrir dans le navigateur (http)") { ScanFormat.open(URL(string: "http://\(device.ip)")!) }
            Button("Ouvrir dans le navigateur (https)") { ScanFormat.open(URL(string: "https://\(device.ip)")!) }
        } else {
            Text("\(devices.count) appareils sélectionnés")
            Button("Copier les IP") {
                scan.copy(devices.map(\.ip.description).joined(separator: "\n"), label: "Liste d’IP")
            }
            Divider()
        }
        ScanPortPresetMenu(devices: devices, scan: scan)
        DeviceTypeMenu(devices: devices) { scan.show($0, place: .actions) }
        // Note 10 : ajout choisi (utile quand l'ajout automatique du site est désactivé).
        ScanInventoryAddButton(devices: devices) { scan.show($0, place: .actions) }
        if devices.count == 1, let device = devices.first {
            Button("Wake-on-LAN") { scan.wake(device, state: state) }.disabled(device.mac == nil)
            // Note 51 : client TFTP prérempli avec cet appareil.
            Button("Transfert TFTP…") { TFTPModel.shared.prepareClient(for: device, state: state) }
            // Note 72 : partages de l'hôte par smbutil view (lancé seulement dans la feuille, sur clic).
            Button("Partages SMB…") { SMBSharesModel.shared.ask(device) }
            Divider()
            Button("Voir la fiche complète") { state.showDevice(device.id) }
        }
    }
}

/// « Ajouter à l'inventaire » (note 10) : appareils choisis pas encore dans l'inventaire du site actif.
struct ScanInventoryAddButton: View {
    @ObservedObject private var inventory = InvModel.shared
    let devices: [Device]
    var report: (String) -> Void = { _ in }

    var body: some View {
        let missing = inventory.store.notInInventory(devices)
        let excluded = devices.filter { inventory.store.existingKey(for: $0) == nil && inventory.store.isExcluded($0) }
        let wanted = missing + excluded
        Button(wanted.isEmpty ? "Déjà dans l’inventaire"
               : devices.count > 1 ? "Ajouter \(wanted.count) appareil\(wanted.count > 1 ? "s" : "") à l’inventaire" : "Ajouter à l’inventaire") {
            inventory.addToInventory(wanted)
            if let message = inventory.toast { report(message) }
        }
        .disabled(wanted.isEmpty)
    }
}

/// Sous-menu « Scanner les ports › <préréglage> » (note 19), mêmes préréglages que les Réglages.
struct ScanPortPresetMenu: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var prefs = RegPrefs.shared
    let devices: [Device]
    @ObservedObject var scan: ScanController

    var body: some View {
        Menu("Scanner les ports") {
            ForEach(scan.portPresets) { preset in
                Button(preset.label) { scan.probePorts(of: devices, preset: preset, state: state) }
                    .disabled(preset.ports.isEmpty)
            }
            Divider()
            // Note 6 : SSH, Telnet, RDP, VNC et RustDesk (21115 à 21119).
            ForEach(PortPreset.thematic) { preset in
                Button(preset.label) { scan.probePorts(of: devices, preset: preset, state: state) }
            }
            Divider()
            // Note 69 : sonde propre à chaque protocole UDP (DNS, NTP, SNMP, SIP, IPMI…), un appareil à la fois.
            Button(devices.count == 1 ? "UDP ciblé…" : "UDP ciblé… (un appareil à la fois)") {
                if let device = devices.first { UDPScanModel.shared.ask(device) }
            }
            .disabled(devices.count != 1)
            Divider()
            Button("Modifier les préréglages…") {
                RegNavigation.shared.section = .profils
                state.open(.reglages)
            }
        }
        .disabled(scan.isBusy)
    }
}

/// Cellule « Type » : icône, libellé, marque « choisi à la main ».
struct ScanTypeCell: View {
    let type: DeviceType
    let isManual: Bool
    /// Note 6 : rôle RustDesk reconnu aux ports (« Serveur RustDesk »), affiché à la place du type
    /// détecté quand celui-ci est « Serveur » et n'a pas été choisi à la main.
    var role: RustDeskPorts.Role? = nil

    private var label: String {
        guard !isManual, let role, role.isServer, type == .serveur else { return type.label }
        return role.label
    }

    private var helpText: String {
        let base = isManual ? "\(type.label) · choisi à la main" : "\(type.label) · détecté par le scan"
        return role.map { base + "\n" + $0.label } ?? base
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(type == .inconnu ? Theme.textTertiary : Theme.neutralText)
                .frame(width: 16)
            Text(label)
                .font(Theme.small)
                .foregroundStyle(type == .inconnu ? Theme.textTertiary : Theme.neutralText)
                .lineLimit(1)
                .truncationMode(.tail)
            if isManual { ManualTypeMark() }
        }
        .help(helpText)
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
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(light: 0xDBEAFE, dark: 0x1B3250)))
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

/// Cellule « Switch / port » : « SW-CORE-01 · Gi1/0/40 » sur une ligne quand la colonne le permet,
/// sinon le switch au-dessus du port (11 pt) pour que le port reste lisible ; emplacement complet
/// en infobulle.
struct SwitchPortCell: View {
    let name: String?
    let port: String?
    var dimmed = false
    /// Précision ajoutée à l'infobulle (ex. emplacement relevé sur un autre réseau).
    var note: String? = nil

    var body: some View {
        if name == nil && port == nil {
            ScanCellText("—", dimmed: true)
        } else {
            let full = [name, port].compactMap { $0 }.joined(separator: " · ")
            ViewThatFits(in: .horizontal) {
                Text(full).font(Theme.mono(12)).lineLimit(1).fixedSize()
                if let name, let port {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Text(port).lineLimit(1).truncationMode(.tail).foregroundStyle(Theme.textSecondary)
                    }
                    .font(Theme.mono(11))
                } else {
                    Text(full).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(dimmed ? Theme.textTertiary : Theme.neutralText)
            .help(note.map { "\(full)\n\($0)" } ?? full)
        }
    }
}

/// Étiquettes de ports : autant que la largeur de la colonne le permet, puis « +N » (ports web en bleu).
struct ScanPortTags: View {
    let ports: [UInt16]

    var body: some View {
        StandardTagList(tags: ports.map(String.init),
                        highlighted: { UInt16($0).map { ScanFormat.webPorts.contains($0) } ?? false },
                        help: "Ports ouverts\u{00A0}: " + ports.map(String.init).joined(separator: ", "))
    }
}
