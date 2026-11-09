import NetScopeCore
import SwiftUI

// Note 77 : partie « Contrôleurs » de l'écran Wi-Fi : bornes et clients Wi-Fi lus par les
// contrôleurs UniFi, Omada et Meraki du site actif (lecture seule), à côté de la partie FortiAP.
// Tableaux standard (note 8), clés « wifi.controleurs.bornes » et « wifi.controleurs.clients ».

private let rowHeight: CGFloat = 28
private let lastKey = "\u{10FFFF}"

struct ControllerWifiView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SiteControllerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.activeControllers.isEmpty {
                Panel(padding: 0) {
                    EmptyState(systemImage: "wifi.router",
                               title: "Aucun contrôleur pour ce site",
                               message: "Les bornes UniFi, Omada et Meraki sont lues par le contrôleur du site (lecture seule). Ajoutez-le dans Réglages › Sites et plages › Contrôleur.") {
                        Button("Ouvrir Réglages › Sites") {
                            RegNavigation.shared.section = .sites
                            state.open(.reglages)
                        }
                        .buttonStyle(.primary)
                    }
                    .frame(height: 230)
                }
            } else {
                ControllerSitePanel(subject: "bornes")
                if store.readings.isEmpty {
                    Panel(padding: 0) {
                        EmptyState(systemImage: store.isBusy ? "hourglass" : "wifi.exclamationmark",
                                   title: store.isBusy ? "Lecture des contrôleurs…" : "Aucune borne lue",
                                   message: "Les bornes et leurs clients sont lus à la fin de chaque scan du site, ou avec «\u{00A0}Relire\u{00A0}».")
                            .frame(height: 200)
                    }
                } else {
                    tiles
                    ControllerAPTable(readings: store.readings)
                    ControllerClientTable(readings: store.readings)
                }
            }
        }
    }

    private var tiles: some View {
        let summary = ControllerSummary(store.readings)
        let shownBands = [WifiBand.ghz24, .ghz5, .ghz6].filter { $0 != .ghz6 || summary.byBand[.ghz6] != nil }
        let offline = store.readings.flatMap(\.report.aps).filter { $0.online == false }
        let hasSignal = store.readings.flatMap(\.report.wirelessClients).contains { $0.rssi != nil }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.tileMinWidth), spacing: 10, alignment: .top)], spacing: 10) {
            tile("Bornes en ligne", "\(summary.apsOnline) / \(summary.aps)",
                 sub: offline.isEmpty ? "aucune hors ligne" : "hors ligne\u{00A0}: \(offline.map(\.name).joined(separator: ", "))",
                 color: offline.isEmpty ? Theme.success : Theme.warning)
            tile("Clients Wi-Fi", "\(summary.wirelessClients)", sub: hasSignal ? "\(summary.weakClients) à signal faible" : "signal non fourni", color: Theme.text)
            tile(shownBands.map { [.ghz24: "2,4", .ghz5: "5", .ghz6: "6"][$0] ?? "" }.joined(separator: " / ") + "\u{00A0}GHz",
                 shownBands.map { String(summary.byBand[$0] ?? 0) }.joined(separator: " / "), sub: "clients par bande", color: Theme.text)
            tile("SSID", "\(summary.ssids.count)", sub: summary.ssids.prefix(2).joined(separator: ", "), color: Theme.text)
            tile("Clients filaires", "\(summary.wiredClients)", sub: "\(summary.switches) switch\(summary.switches > 1 ? "s" : "") géré\(summary.switches > 1 ? "s" : "")",
                 color: Theme.text)
        }
    }

    private func tile(_ title: String, _ value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(Theme.mono(18, weight: .bold)).foregroundStyle(color).lineLimit(1)
            Text(sub).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
        .modifier(WifiTileStyle())
        .help(sub)
    }
}

// MARK: - Cadre et en-tête

private struct ControllerTableFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }
}

private struct ControllerTableHeader<Row: Identifiable>: View {
    let title: String
    let summary: String
    @Binding var search: String
    let prompt: String
    @ObservedObject var model: StandardTableModel<Row>

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                WifiHeading(title).fixedSize()
                field
                Spacer(minLength: 4)
                Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                StandardColumnsMenu(model: model)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading(title).fixedSize()
                    field
                    Spacer(minLength: 4)
                    StandardColumnsMenu(model: model)
                }
                Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var field: some View {
        TextField(title, text: $search, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(Theme.small)
            .frame(minWidth: 110, idealWidth: 150, maxWidth: 180)
    }
}

private func matches(_ search: String, _ fields: [String?]) -> Bool {
    let words = search.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return true }
    let text = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
    return words.allSatisfy { text.contains($0) }
}

// MARK: - Bornes

struct ControllerAPRow: Identifiable {
    let ap: ControllerAP
    let report: ControllerReport
    let site: String
    var id: String { site + "|" + ap.id }
    var name: String { ap.name.lowercased() }
    var stateRank: Int { ap.online == false ? 0 : (ap.online == nil ? 1 : 2) }
    var model: String { ap.model.isEmpty ? lastKey : ap.model }
    var ipSort: UInt32 { ap.ip?.value ?? UInt32.max }
    var channels: String { ap.radios.map(\.label).joined(separator: " · ") }
    var clients: Int { ap.online == false ? -1 : report.clientCount(of: ap) }
    var utilization: Double { ap.radios.compactMap(\.utilization).max() ?? -1 }
    var uplink: String {
        guard let sw = ap.uplinkSwitchName else { return lastKey }
        return ap.uplinkPort.map { "\(sw) · Port \($0)" } ?? sw
    }
    var firmware: String { ap.firmware.isEmpty ? lastKey : ap.firmware }
    var serial: String { ap.serial.isEmpty ? lastKey : ap.serial }
    var ssids: String { ap.ssids.isEmpty ? lastKey : ap.ssids.joined(separator: ", ") }
    var source: String { report.kind.shortLabel }
}

struct ControllerAPTable: View {
    let readings: [ControllerSiteReading]
    @StateObject private var table = StandardTableModel<ControllerAPRow>(id: "wifi.controleurs.bornes", columns: Self.columns,
                                                                         sortKeys: Self.sortKeys, defaultSort: "etat")
    @State private var search = ""
    @State private var selection: ControllerAPRow.ID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Borne", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "ip", title: "Adresse IP"),
        StandardColumn(id: "canaux", title: "Canaux"),
        StandardColumn(id: "clients", title: "Clients"),
        StandardColumn(id: "utilisation", title: "Utilisation du canal"),
        StandardColumn(id: "branchement", title: "Branchée sur"),
        StandardColumn(id: "firmware", title: "Firmware", isDefaultVisible: false),
        StandardColumn(id: "ssid", title: "SSID diffusés", isDefaultVisible: false),
        StandardColumn(id: "serie", title: "Numéro de série", isDefaultVisible: false),
        StandardColumn(id: "source", title: "Contrôleur", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<ControllerAPRow>] = [
        "nom": KeyPathComparator(\ControllerAPRow.name),
        "etat": KeyPathComparator(\ControllerAPRow.stateRank),
        "modele": KeyPathComparator(\ControllerAPRow.model),
        "ip": KeyPathComparator(\ControllerAPRow.ipSort),
        "canaux": KeyPathComparator(\ControllerAPRow.channels),
        "clients": KeyPathComparator(\ControllerAPRow.clients),
        "utilisation": KeyPathComparator(\ControllerAPRow.utilization),
        "branchement": KeyPathComparator(\ControllerAPRow.uplink),
        "firmware": KeyPathComparator(\ControllerAPRow.firmware),
        "ssid": KeyPathComparator(\ControllerAPRow.ssids),
        "serie": KeyPathComparator(\ControllerAPRow.serial),
        "source": KeyPathComparator(\ControllerAPRow.source),
    ]

    var body: some View {
        let all = readings.flatMap { reading in reading.report.aps.map { ControllerAPRow(ap: $0, report: reading.report, site: reading.siteName) } }
        let rows = all.filter { row in
            matches(search, [row.ap.name, row.ap.model, row.ap.ip?.description, row.ap.serial, row.channels, row.ap.uplinkSwitchName]
                    + row.ap.ssids.map(Optional.some))
        }
        .sorted(using: table.sortOrder + [KeyPathComparator(\ControllerAPRow.name)])
        let online = all.filter { $0.ap.online != false }.count
        ControllerTableFrame {
            ControllerTableHeader(title: "Bornes", summary: "\(online) en ligne sur \(all.count)", search: $search,
                                  prompt: "Nom, modèle, IP, SSID…", model: table)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(all.isEmpty ? "Le contrôleur n’a renvoyé aucune borne." : "Aucune borne ne correspond à «\u{00A0}\(search)\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(20)
            } else {
                tableView(rows).standardTableHeight(rows: rows.count, rowHeight: rowHeight, maxRows: 10)
            }
        }
    }

    private func tableView(_ rows: [ControllerAPRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("BORNE"), sortUsing: table.sort("nom")) { row in
                    Text(row.ap.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 110, ideal: 140)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in
                    switch row.ap.online {
                    case false?: WifiPill(text: "Hors ligne", foreground: Theme.critical, background: Theme.criticalSoft)
                    case true?: WifiPill(text: "En ligne", foreground: Theme.success, background: Theme.successSoft)
                    case nil: WifiPill(text: "Inconnu")
                    }
                }
                .width(min: 74, ideal: 84)
                .customizationID("etat")

                TableColumn(StandardTableHeading("MODÈLE"), sortUsing: table.sort("modele")) { row in
                    WifiCell(row.ap.model.isEmpty ? "—" : row.ap.model, mono: 11, dimmed: row.ap.model.isEmpty)
                }
                .width(min: 64, ideal: 80)
                .customizationID("modele")

                TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                    WifiCell(row.ap.ip?.description ?? "—", mono: 12, dimmed: row.ap.ip == nil || row.ap.online == false)
                }
                .width(min: 100, ideal: 112)
                .customizationID("ip")

                TableColumn(StandardTableHeading("CANAUX"), sortUsing: table.sort("canaux")) { row in
                    WifiCell(row.ap.online == false || row.ap.radios.isEmpty ? "—" : row.ap.channelsLabel, mono: 11,
                             dimmed: row.ap.online == false || row.ap.radios.isEmpty)
                        .help(row.ap.radios.map(\.label).joined(separator: "\n"))
                }
                .width(min: 70, ideal: 90)
                .customizationID("canaux")

                TableColumn(StandardTableHeading("CLIENTS"), sortUsing: table.sort("clients")) { row in
                    WifiCell(row.clients < 0 ? "—" : "\(row.clients)", mono: 12, weight: .semibold, color: Theme.text, dimmed: row.clients < 0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 66)
                .customizationID("clients")

                TableColumn(StandardTableHeading("UTILISATION"), sortUsing: table.sort("utilisation")) { row in
                    let u = row.utilization
                    WifiCell(u < 0 ? "—" : FortiAPText.percent(u), mono: 12, weight: u > 60 ? .bold : .regular,
                             color: u > 60 ? Theme.warning : Theme.neutralText, dimmed: u < 0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Utilisation la plus haute parmi les radios (si le contrôleur la publie)")
                }
                .width(min: 80, ideal: 88)
                .customizationID("utilisation")

                TableColumn(StandardTableHeading("BRANCHÉE SUR"), sortUsing: table.sort("branchement")) { row in
                    WifiCell(row.uplink == lastKey ? "—" : row.uplink, mono: 11, dimmed: row.uplink == lastKey)
                }
                .width(min: 110, ideal: 170)
                .customizationID("branchement")

                TableColumn(StandardTableHeading("FIRMWARE"), sortUsing: table.sort("firmware")) { row in
                    WifiCell(row.ap.firmware.isEmpty ? "—" : row.ap.firmware, mono: 11, dimmed: row.ap.firmware.isEmpty)
                }
                .width(min: 56, ideal: 70)
                .customizationID("firmware")
                .defaultVisibility(.hidden)
            }
            Group {
                TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                    WifiCell(row.ssids == lastKey ? "—" : row.ssids, dimmed: row.ssids == lastKey)
                }
                .width(min: 90, ideal: 180)
                .customizationID("ssid")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("SÉRIE"), sortUsing: table.sort("serie")) { row in WifiCell(row.ap.serial, mono: 11) }
                    .width(min: 90, ideal: 130)
                    .customizationID("serie")
                    .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("CONTRÔLEUR"), sortUsing: table.sort("source")) { row in WifiCell(row.report.kind.label) }
                    .width(min: 80, ideal: 110)
                    .customizationID("source")
                    .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
    }
}

// MARK: - Clients Wi-Fi

struct ControllerClientRow: Identifiable {
    let client: ControllerClient
    let report: ControllerReport
    let site: String
    var id: String { site + "|" + client.id }
    var name: String { client.displayName.lowercased() }
    var macSort: UInt64 { client.mac.value }
    var ipSort: UInt32 { client.ip?.value ?? UInt32.max }
    var ssid: String { client.ssid ?? lastKey }
    var ap: String { client.apName ?? report.ap(for: client)?.name ?? lastKey }
    var bandSort: String { (client.band?.rawValue ?? "z") + String(format: "%03d", client.channel ?? 999) }
    /// Signal : dBm s'il est connu, sinon le pourcentage ramené à une échelle comparable.
    var signal: Int { client.rssi ?? client.signalPercent.map { $0 / 2 - 100 } ?? -999 }
    var vlan: Int { client.vlan ?? 99_999 }
    var rate: Double { client.rateMbps ?? -1 }
    var vendor: String { client.manufacturer ?? lastKey }
}

struct ControllerClientTable: View {
    let readings: [ControllerSiteReading]
    @StateObject private var table = StandardTableModel<ControllerClientRow>(id: "wifi.controleurs.clients", columns: Self.columns,
                                                                             sortKeys: Self.sortKeys, defaultSort: "signal", defaultAscending: false)
    @State private var search = ""
    @State private var selection: ControllerClientRow.ID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Client", isRequired: true),
        StandardColumn(id: "ip", title: "Adresse IP"),
        StandardColumn(id: "mac", title: "Adresse MAC"),
        StandardColumn(id: "ssid", title: "SSID"),
        StandardColumn(id: "borne", title: "Borne"),
        StandardColumn(id: "bande", title: "Bande et canal"),
        StandardColumn(id: "signal", title: "Signal"),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "debit", title: "Débit", isDefaultVisible: false),
        StandardColumn(id: "fabricant", title: "Fabricant", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<ControllerClientRow>] = [
        "nom": KeyPathComparator(\ControllerClientRow.name),
        "ip": KeyPathComparator(\ControllerClientRow.ipSort),
        "mac": KeyPathComparator(\ControllerClientRow.macSort),
        "ssid": KeyPathComparator(\ControllerClientRow.ssid),
        "borne": KeyPathComparator(\ControllerClientRow.ap),
        "bande": KeyPathComparator(\ControllerClientRow.bandSort),
        "signal": KeyPathComparator(\ControllerClientRow.signal),
        "vlan": KeyPathComparator(\ControllerClientRow.vlan),
        "debit": KeyPathComparator(\ControllerClientRow.rate),
        "fabricant": KeyPathComparator(\ControllerClientRow.vendor),
    ]

    var body: some View {
        let all = readings.flatMap { reading in
            reading.report.wirelessClients.map { ControllerClientRow(client: $0, report: reading.report, site: reading.siteName) }
        }
        let rows = all.filter { row in
            matches(search, [row.client.hostname, row.client.mac.formatted(.upperColon), row.client.ip?.description, row.client.ssid,
                             row.client.apName, row.client.manufacturer, row.client.band?.label])
        }
        .sorted(using: table.sortOrder + [KeyPathComparator(\ControllerClientRow.name)])
        let weak = all.filter { ($0.client.rssi ?? 0) < ControllerSummary.weakThreshold && $0.client.rssi != nil }.count
        ControllerTableFrame {
            ControllerTableHeader(title: "Clients Wi-Fi",
                                  summary: "\(all.count) client\(all.count > 1 ? "s" : "")" + (weak > 0 ? " · \(weak) à signal faible" : ""),
                                  search: $search, prompt: "Nom, MAC, IP, SSID…", model: table)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(all.isEmpty ? "Aucun client Wi-Fi lu." : "Aucun client ne correspond à «\u{00A0}\(search)\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(20)
            } else {
                tableView(rows).standardTableHeight(rows: rows.count, rowHeight: rowHeight, maxRows: 14)
            }
        }
    }

    private func tableView(_ rows: [ControllerClientRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("CLIENT"), sortUsing: table.sort("nom")) { row in
                    Text(row.client.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 110, ideal: 150)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                    WifiCell(row.client.ip?.description ?? "—", mono: 12, dimmed: row.client.ip == nil)
                }
                .width(min: 96, ideal: 108)
                .customizationID("ip")

                TableColumn(StandardTableHeading("ADRESSE MAC"), sortUsing: table.sort("mac")) { row in
                    WifiCell(row.client.mac.formatted(.upperColon), mono: 11)
                }
                .width(min: 120, ideal: 130)
                .customizationID("mac")

                TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                    WifiCell(row.client.ssid ?? "—", dimmed: row.client.ssid == nil)
                }
                .width(min: 80, ideal: 130)
                .customizationID("ssid")

                TableColumn(StandardTableHeading("BORNE"), sortUsing: table.sort("borne")) { row in
                    WifiCell(row.ap == lastKey ? "—" : row.ap, mono: 11, dimmed: row.ap == lastKey)
                }
                .width(min: 90, ideal: 130)
                .customizationID("borne")

                TableColumn(StandardTableHeading("BANDE ET CANAL"), sortUsing: table.sort("bande")) { row in
                    let parts = [row.client.band?.label, row.client.channel.map { "canal \($0)" }].compactMap { $0 }
                    WifiCell(parts.isEmpty ? "—" : parts.joined(separator: " · "), dimmed: parts.isEmpty)
                }
                .width(min: 90, ideal: 120)
                .customizationID("bande")

                TableColumn(StandardTableHeading("SIGNAL"), sortUsing: table.sort("signal")) { row in signalCell(row.client) }
                    .width(min: 100, ideal: 120)
                    .customizationID("signal")

                TableColumn(StandardTableHeading("VLAN"), sortUsing: table.sort("vlan")) { row in
                    WifiCell(row.client.vlan.map(String.init) ?? "—", mono: 12, dimmed: row.client.vlan == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 44, ideal: 52)
                .customizationID("vlan")
            }
            Group {
                TableColumn(StandardTableHeading("DÉBIT"), sortUsing: table.sort("debit")) { row in
                    WifiCell(row.client.rateMbps.map { "\(Int($0.rounded()))\u{00A0}Mb/s" } ?? "—", mono: 11, dimmed: row.client.rateMbps == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 84)
                .customizationID("debit")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("FABRICANT"), sortUsing: table.sort("fabricant")) { row in
                    WifiCell(row.client.manufacturer ?? "—", dimmed: row.client.manufacturer == nil)
                }
                .width(min: 80, ideal: 120)
                .customizationID("fabricant")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
    }

    @ViewBuilder private func signalCell(_ client: ControllerClient) -> some View {
        if let rssi = client.rssi {
            HStack(spacing: 6) {
                WifiSignalBar(rssi: rssi, width: 40)
                WifiCell("\(rssi)\u{00A0}dBm", mono: 11, weight: rssi < ControllerSummary.weakThreshold ? .bold : .regular,
                         color: rssi < ControllerSummary.weakThreshold ? Theme.warning : Theme.neutralText)
            }
        } else if let percent = client.signalPercent {
            WifiCell("\(percent)\u{00A0}%", mono: 11)
        } else {
            WifiCell("non fourni", dimmed: true)
                .help("Le contrôleur ne donne pas le signal de ce client (API Meraki).")
        }
    }
}
