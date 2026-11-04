import NetScopeCore
import SwiftUI

// Note 27 : tableaux standard (note 8) de la partie FortiAP : bornes, clients, SSID, AP voisins.
// Chaque tableau a sa clé (« wifi.fortiap.… ») et son propre filtre local. Filtre local et recherche
// de la barre d'outils passent par le même moteur (note 26 : préfixes, exclusion) ; chaque tableau
// applique les critères des champs qu'il connaît.

private let fortiRowHeight: CGFloat = 28
private let last = "\u{10FFFF}"

/// En-tête des tableaux FortiAP : titre, champ de recherche, filtre, « Colonnes ».
private struct FortiAPTableHeader<Row: Identifiable, Filter: View>: View {
    let title: String
    let summary: String
    @Binding var search: String
    let prompt: String
    @ObservedObject var model: StandardTableModel<Row>
    @ViewBuilder var filter: Filter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                WifiHeading(title).fixedSize()
                field
                filter
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
                HStack(spacing: 8) {
                    filter
                    Spacer(minLength: 4)
                    Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                }
            }
            // Petite fenêtre : filtres sur leur propre ligne, résumé dessous.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading(title).fixedSize()
                    field
                    Spacer(minLength: 4)
                    StandardColumnsMenu(model: model)
                }
                HStack(spacing: 8) {
                    filter
                    Spacer(minLength: 0)
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

/// Cadre commun des tableaux FortiAP.
private struct FortiAPTableFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }
}

/// Filtre local du tableau et recherche de l'écran, réduite aux champs du tableau.
private struct FortiSearch {
    let local: SearchQuery
    let global: SearchQuery

    init(_ text: String, global: SearchQuery, schema: SearchSchema) {
        local = SearchQuery(text, schema: schema)
        self.global = global.restricted(to: schema)
    }

    var isFiltering: Bool { !local.isEmpty || !global.isEmpty }

    func matches(_ values: [String: [String?]], freeText: [String?]) -> Bool {
        guard isFiltering else { return true }
        let document = SearchDocument(values.mapValues { $0.compactMap { $0 } },
                                      freeText: [freeText.compactMap { $0 }.joined(separator: " ")])
        return local.matches(document) && global.matches(document)
    }
}

private func bandTerms(_ band: WifiBand?) -> [String?] { band.map { [$0.label, $0.label.replacingOccurrences(of: "\u{00A0}GHz", with: "")] } ?? [] }

private func emptyLine(_ text: String) -> some View {
    Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity).padding(20)
}

// MARK: - Bornes

struct FortiAPRow: Identifiable {
    let ap: FortiManagedAP
    var id: FortiManagedAP.ID { ap.id }
    var name: String { ap.name.lowercased() }
    var site: String { ap.site.lowercased() }
    var model: String { ap.model.isEmpty ? last : ap.model }
    var ipSort: UInt32 { ap.ip?.value ?? UInt32.max }
    var stateRank: Int { ap.connected == false ? 0 : (ap.connected == nil ? 1 : 2) }
    var clients: Int { ap.totalClients }
    var radios: String { FortiAPText.radios(ap) }
    var firmware: String { ap.firmwareShort.isEmpty ? last : ap.firmwareShort }
    var uptime: Double { ap.isOffline ? -1 : (ap.uptime ?? -1) }
    var serial: String { ap.serial.isEmpty ? last : ap.serial }
    var profile: String { ap.profile ?? last }
    var location: String { ap.location ?? last }
    var utilization: Double { ap.radios.compactMap(\.channelUtilization).max() ?? -1 }
}

struct FortiAPTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @Binding var selection: FortiManagedAP.ID?
    @StateObject private var table = StandardTableModel<FortiAPRow>(id: "wifi.fortiap.bornes", columns: Self.columns,
                                                                    sortKeys: Self.sortKeys, defaultSort: "etat")
    @State private var search = ""

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Borne", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "ip", title: "Adresse IP"),
        StandardColumn(id: "radios", title: "Radios (canal)"),
        StandardColumn(id: "clients", title: "Clients"),
        StandardColumn(id: "utilisation", title: "Utilisation du canal"),
        StandardColumn(id: "firmware", title: "Firmware", isDefaultVisible: false),
        StandardColumn(id: "service", title: "En service", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
        StandardColumn(id: "serie", title: "Numéro de série", isDefaultVisible: false),
        StandardColumn(id: "profil", title: "Profil", isDefaultVisible: false),
        StandardColumn(id: "emplacement", title: "Emplacement", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FortiAPRow>] = [
        "nom": KeyPathComparator(\FortiAPRow.name),
        "etat": KeyPathComparator(\FortiAPRow.stateRank),
        "modele": KeyPathComparator(\FortiAPRow.model),
        "ip": KeyPathComparator(\FortiAPRow.ipSort),
        "radios": KeyPathComparator(\FortiAPRow.radios),
        "clients": KeyPathComparator(\FortiAPRow.clients),
        "utilisation": KeyPathComparator(\FortiAPRow.utilization),
        "firmware": KeyPathComparator(\FortiAPRow.firmware),
        "service": KeyPathComparator(\FortiAPRow.uptime),
        "site": KeyPathComparator(\FortiAPRow.site),
        "serie": KeyPathComparator(\FortiAPRow.serial),
        "profil": KeyPathComparator(\FortiAPRow.profile),
        "emplacement": KeyPathComparator(\FortiAPRow.location),
    ]

    var body: some View {
        let all = store.shownOverview.aps
        let query = FortiSearch(search, global: state.searchQuery(for: .wifi), schema: .wifiBornes)
        let rows = all.filter { ap in
            query.matches(["borne": [ap.name, ap.serial, ap.location], "modele": [ap.model], "ip": [ap.ip?.description],
                           "etat": [FortiAPText.statePill(ap).text, ap.state], "canal": ap.radios.map { $0.channel.map(String.init) },
                           "bande": ap.radios.flatMap { bandTerms($0.band) }, "site": [ap.site]],
                          freeText: [ap.name, ap.model, ap.ip?.description, ap.serial, ap.site, ap.location, ap.firmware, FortiAPText.radios(ap)])
        }
        .map(FortiAPRow.init)
        .sorted(using: table.sortOrder + [KeyPathComparator(\FortiAPRow.name)])
        FortiAPTableFrame {
            FortiAPTableHeader(title: "Bornes FortiAP", summary: "\(store.shownOverview.onlineAPs.count) en ligne sur \(all.count)",
                               search: $search, prompt: "Nom, modèle, IP…", model: table) { EmptyView() }
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyLine(all.isEmpty ? "Aucune borne lue (accès aux bornes absent ou refusé par la FortiGate)."
                          : (search.isEmpty ? "Aucune borne ne correspond à la recherche." : "Aucune borne ne correspond à «\u{00A0}\(search)\u{00A0}»."))
            } else {
                tableView(rows).standardTableHeight(rows: rows.count, rowHeight: fortiRowHeight, maxRows: 12)
            }
        }
        .searchResults(rows.count, "borne", "bornes")
    }

    private func tableView(_ rows: [FortiAPRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("BORNE"), sortUsing: table.sort("nom")) { row in
                    Text(row.ap.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        .help(row.ap.location ?? row.ap.name)
                }
                .width(min: 100, ideal: 124)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in FortiAPText.statePill(row.ap) }
                    .width(min: 70, ideal: 82)
                    .customizationID("etat")

                TableColumn(StandardTableHeading("MODÈLE"), sortUsing: table.sort("modele")) { row in
                    WifiCell(row.ap.model.isEmpty ? "—" : row.ap.model, mono: 11, dimmed: row.ap.model.isEmpty)
                }
                .width(min: 64, ideal: 74)
                .customizationID("modele")

                TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                    WifiCell(row.ap.ip?.description ?? "—", mono: 12, dimmed: row.ap.ip == nil || row.ap.isOffline)
                }
                .width(min: 104, ideal: 112)
                .customizationID("ip")

                TableColumn(StandardTableHeading("RADIOS (CANAL)"), sortUsing: table.sort("radios")) { row in
                    WifiCell(row.radios, mono: 11, color: radioColor(row.ap), dimmed: row.ap.isOffline)
                        .help(row.ap.radios.map { "Radio \($0.radioID)\u{00A0}: \($0.label)" }.joined(separator: "\n"))
                }
                .width(min: 110, ideal: 170)
                .customizationID("radios")

                TableColumn(StandardTableHeading("CLIENTS"), sortUsing: table.sort("clients")) { row in
                    WifiCell(row.ap.isOffline ? "—" : "\(row.clients)", mono: 12, weight: .semibold, color: Theme.text, dimmed: row.ap.isOffline)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 68)
                .customizationID("clients")

                TableColumn(StandardTableHeading("UTILISATION"), sortUsing: table.sort("utilisation")) { row in
                    let u = row.utilization
                    let busy = u > store.thresholds.maxChannelUtilization
                    WifiCell(u < 0 ? "—" : FortiAPText.percent(u), mono: 12, weight: busy ? .bold : .regular,
                             color: busy ? Theme.warning : Theme.neutralText, dimmed: u < 0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Utilisation la plus haute parmi les radios")
                }
                .width(min: 84, ideal: 88)
                .customizationID("utilisation")

                TableColumn(StandardTableHeading("FIRMWARE"), sortUsing: table.sort("firmware")) { row in
                    WifiCell(row.ap.firmwareShort.isEmpty ? "—" : row.ap.firmwareShort, mono: 11, dimmed: row.ap.firmwareShort.isEmpty)
                        .help(row.ap.firmware)
                }
                .width(min: 56, ideal: 64)
                .customizationID("firmware")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("EN SERVICE"), sortUsing: table.sort("service")) { row in
                    WifiCell(row.ap.isOffline ? "hors ligne" : FortiAPText.duration(row.ap.uptime), dimmed: row.ap.isOffline || row.ap.uptime == nil)
                }
                .width(min: 64, ideal: 76)
                .customizationID("service")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { row in WifiCell(row.ap.site) }
                    .width(min: 60, ideal: 92)
                    .customizationID("site")
                    .defaultVisibility(.hidden)
            }
            Group {
                TableColumn(StandardTableHeading("SÉRIE"), sortUsing: table.sort("serie")) { row in WifiCell(row.ap.serial, mono: 11) }
                    .width(min: 100, ideal: 130)
                    .customizationID("serie")
                    .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("PROFIL"), sortUsing: table.sort("profil")) { row in
                    WifiCell(row.ap.profile ?? "—", mono: 11, dimmed: row.ap.profile == nil)
                }
                .width(min: 80, ideal: 120)
                .customizationID("profil")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("EMPLACEMENT"), sortUsing: table.sort("emplacement")) { row in
                    WifiCell(row.ap.location ?? "—", dimmed: row.ap.location == nil)
                }
                .width(min: 80, ideal: 150)
                .customizationID("emplacement")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 48 : plusieurs sites affichés, colonne « Site » montrée d’office.
        .standardSiteColumn(table, multiple: store.shownOverview.isMultiSite)
        // Note 34 : double-clic ou ↩︎ sur une borne → sa fiche Appareil (déjà choisie ici) ;
        // clic droit → « Ouvrir dans › » (fiche, Inventaire, Carte, Switchs et ports, Ping…).
        .standardRowNavigation(selection: selection.map { [$0] } ?? [], object: { id in
            store.shownOverview.aps.first { $0.id == id }.map { .accessPoint(id: $0.id, name: $0.name, ip: $0.ip?.description) }
        }, primary: { ids in
            guard let ap = store.shownOverview.aps.first(where: { ids.contains($0.id) }) else { return true }
            if let ip = ap.ip?.description, state.device(withID: ip) != nil { state.showDevice(ip) }
            return true
        })
    }

    /// Radios en orange quand la borne est dans un chevauchement.
    private func radioColor(_ ap: FortiManagedAP) -> Color {
        store.shownDiagnosis.overlaps.contains { $0.site == ap.site && ($0.first == ap.name || $0.second == ap.name) && $0.kind != .sameChannel }
            ? Theme.warning : Theme.neutralText
    }
}

// MARK: - Clients

struct FortiClientRow: Identifiable {
    let client: FortiWifiClient
    let isWeak: Bool
    let deviceName: String?
    var id: FortiWifiClient.ID { client.id }
    var name: String { client.hostname?.lowercased() ?? last }
    var mac: UInt64 { client.mac.value }
    var ip: UInt32 { client.ip?.value ?? UInt32.max }
    var ssid: String { client.ssid ?? last }
    var ap: String { client.apName ?? last }
    var band: Int { client.band.flatMap { WifiBand.allCases.firstIndex(of: $0) } ?? 9 }
    var channel: Int { client.channel ?? Int.max }
    var rssi: Int { client.rssi ?? Int.min }
    var snr: Int { client.snr ?? Int.min }
    var rate: Double { client.rateMbps ?? -1 }
    var duration: Double { client.associatedFor ?? -1 }
    var os: String { client.os ?? last }
    var vlan: Int { client.vlan ?? Int.max }
    var site: String { client.site }
    var device: String { deviceName ?? last }
}

struct FortiAPClientTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @StateObject private var table = StandardTableModel<FortiClientRow>(id: "wifi.fortiap.clients", columns: Self.columns,
                                                                        sortKeys: Self.sortKeys, defaultSort: "rssi", defaultAscending: true)
    /// Vue par SSID : colonnes à part, sans la colonne SSID (elle répéterait le titre du groupe).
    @StateObject private var groupTable = StandardTableModel<FortiClientRow>(id: "wifi.fortiap.clients.ssid", columns: Self.columns,
                                                                             sortKeys: Self.sortKeys, defaultSort: "rssi", defaultAscending: true)
    @State private var search = ""
    /// Note 46 : filtres SSID, borne, bande et signal faible.
    @State private var filter = FortiWifiClientFilter()
    @State private var selection: FortiClientRow.ID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Client", isRequired: true),
        StandardColumn(id: "rssi", title: "Signal (RSSI)"),
        StandardColumn(id: "snr", title: "SNR"),
        StandardColumn(id: "borne", title: "Borne"),
        StandardColumn(id: "ssid", title: "SSID"),
        StandardColumn(id: "bande", title: "Bande"),
        StandardColumn(id: "canal", title: "Canal"),
        StandardColumn(id: "ip", title: "Adresse IP"),
        StandardColumn(id: "debit", title: "Débit", isDefaultVisible: false),
        StandardColumn(id: "mac", title: "MAC", isDefaultVisible: false),
        StandardColumn(id: "duree", title: "Associé depuis", isDefaultVisible: false),
        StandardColumn(id: "systeme", title: "Système", isDefaultVisible: false),
        StandardColumn(id: "vlan", title: "VLAN", isDefaultVisible: false),
        StandardColumn(id: "appareil", title: "Appareil du Scanner", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FortiClientRow>] = [
        "nom": KeyPathComparator(\FortiClientRow.name), "ip": KeyPathComparator(\FortiClientRow.ip),
        "mac": KeyPathComparator(\FortiClientRow.mac), "ssid": KeyPathComparator(\FortiClientRow.ssid),
        "borne": KeyPathComparator(\FortiClientRow.ap), "bande": KeyPathComparator(\FortiClientRow.band),
        "canal": KeyPathComparator(\FortiClientRow.channel), "rssi": KeyPathComparator(\FortiClientRow.rssi),
        "snr": KeyPathComparator(\FortiClientRow.snr), "debit": KeyPathComparator(\FortiClientRow.rate),
        "duree": KeyPathComparator(\FortiClientRow.duration), "systeme": KeyPathComparator(\FortiClientRow.os),
        "vlan": KeyPathComparator(\FortiClientRow.vlan), "appareil": KeyPathComparator(\FortiClientRow.device),
        "site": KeyPathComparator(\FortiClientRow.site),
    ]

    var body: some View {
        let all = store.shownOverview.clients
        let devices = deviceNames()
        let query = FortiSearch(search, global: state.searchQuery(for: .wifi), schema: .wifiClients)
        let kept = all.filter { c in
            guard filter.matches(c, thresholds: store.thresholds) else { return false }
            return query.matches(["nom": [c.hostname, devices[c.id]], "mac": [c.mac.formatted(.colon)], "ip": [c.ip?.description],
                                  "ssid": [c.ssid], "borne": [c.apName], "bande": bandTerms(c.band), "canal": [c.channel.map(String.init)],
                                  "vlan": [c.vlan.map(String.init)], "site": [c.site]],
                                 freeText: [c.hostname, c.mac.formatted(.upperColon), c.mac.formatted(.bare), c.ip?.description, c.ssid,
                                            c.apName, c.os, c.site, devices[c.id]])
        }
        let rows = kept
            .map { FortiClientRow(client: $0, isWeak: store.isWeak($0), deviceName: devices[$0.id]) }
            .sorted(using: table.sortOrder + [KeyPathComparator(\FortiClientRow.mac)])
        FortiAPTableFrame {
            FortiAPTableHeader(title: "Clients Wi-Fi", summary: "\(rows.count) affiché\(rows.count > 1 ? "s" : "") sur \(all.count)",
                               search: $search, prompt: "Nom, MAC, IP, SSID…", model: store.clientsBySSID ? groupTable : table) {
                filters(all)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyLine(all.isEmpty ? "Aucun client Wi-Fi associé (ou liste des clients non lue)." : "Aucun client ne correspond à ce filtre.")
            } else if store.clientsBySSID {
                ssidGroups(kept, rows: rows)
            } else {
                tableView(rows).standardTableHeight(rows: rows.count, rowHeight: fortiRowHeight, maxRows: 12)
            }
        }
        .searchResults(rows.count, "client", "clients")
    }

    // MARK: Filtres et vue par SSID (note 46)

    private func filters(_ all: [FortiWifiClient]) -> some View {
        let ssids = Array(Set(all.compactMap(\.ssid))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let aps = Array(Set(all.compactMap(\.apName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return HStack(spacing: 8) {
            Picker("Présentation", selection: $store.clientsBySSID) {
                Text("Liste").tag(false)
                Text("Par SSID").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Liste de tous les clients, ou regroupés par SSID (nombre de clients, bornes et bandes de chaque SSID)")
            Picker("SSID", selection: $filter.ssid) {
                Text("Tous les SSID").tag(String?.none)
                Divider()
                ForEach(ssids, id: \.self) { name in Text(name).tag(String?.some(name)) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Borne", selection: $filter.apName) {
                Text("Toutes les bornes").tag(String?.none)
                Divider()
                ForEach(aps, id: \.self) { name in Text(name).tag(String?.some(name)) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Bande", selection: $filter.band) {
                ForEach(FortiWifiClientFilter.BandChoice.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $filter.weakOnly) {
                Text("Signal faible (\(all.filter(store.isWeak).count))").font(Theme.small)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            if filter.isActive {
                Button("Effacer") { filter = FortiWifiClientFilter() }
                    .buttonStyle(.borderless)
                    .font(Theme.small)
                    .help("Retirer les filtres SSID, borne, bande et signal faible")
            }
        }
        .controlSize(.small)
    }

    /// Un groupe dépliable par SSID (site par site) : nombre de clients, bornes, bandes, sécurité.
    private func ssidGroups(_ clients: [FortiWifiClient], rows: [FortiClientRow]) -> some View {
        let groups = FortiWifiClientGroups.bySSID(store.shownOverview, clients: clients).filter { $0.count > 0 }
        return VStack(spacing: 0) {
            ForEach(groups) { group in
                let open = store.expandedSSIDs.contains(group.id)
                Button {
                    if open { store.expandedSSIDs.remove(group.id) } else { store.expandedSSIDs.insert(group.id) }
                    store.viewedSSID = open ? nil : group.id
                } label: {
                    ssidHeader(group, open: open)
                }
                .buttonStyle(.plain)
                if open {
                    // Même ordre que le tri du tableau.
                    let ids = Set(group.clients.map(\.id))
                    let shown = rows.filter { ids.contains($0.id) }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    tableView(shown, ssidGroup: group.id)
                        .standardTableHeight(rows: shown.count, rowHeight: fortiRowHeight, maxRows: 10)
                }
                if group.id != groups.last?.id { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }

    private func ssidHeader(_ group: FortiWifiSSIDGroup, open: Bool) -> some View {
        let weak = group.clients.filter(store.isWeak).count
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ssidTitle(group, open: open, weak: weak)
                Spacer(minLength: 8)
                ssidFacts(group)
            }
            VStack(alignment: .leading, spacing: 4) {
                ssidTitle(group, open: open, weak: weak)
                ssidFacts(group).padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? Theme.panelMuted : Color.clear)
        .contentShape(Rectangle())
        .help(open ? "Replier ce SSID" : "Déplier ce SSID")
    }

    private func ssidTitle(_ group: FortiWifiSSIDGroup, open: Bool, weak: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 14)
            Image(systemName: "wifi").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
            Text(group.ssid).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(group.count) client\(group.count > 1 ? "s" : "")").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.neutralSoft))
            if weak > 0 {
                WifiPill(text: "\(weak) à signal faible", foreground: Theme.critical, background: Theme.criticalSoft)
            }
            if store.shownOverview.isMultiSite {
                Text(group.site).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .fixedSize()
    }

    private func ssidFacts(_ group: FortiWifiSSIDGroup) -> some View {
        HStack(spacing: 12) {
            Label(group.apNames.count > 3 ? "\(group.apNames.count) bornes" : group.apNames.joined(separator: ", "), systemImage: "wifi.router")
                .help(group.apNames.joined(separator: ", "))
            Label(group.bandsLabel, systemImage: "antenna.radiowaves.left.and.right")
            if let config = group.config {
                Text(config.securityLabel)
                if let vlan = config.vlan { Text("VLAN\u{00A0}\(vlan)").font(Theme.mono(11)) }
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }

    /// Nom de l'appareil du Scanner de chaque client (site actif seulement, rattachement par MAC).
    private func deviceNames() -> [FortiWifiClient.ID: String] {
        var result: [FortiWifiClient.ID: String] = [:]
        for (id, deviceID) in store.deviceLinks(state.devices) {
            if let device = state.device(withID: deviceID) { result[id] = "\(device.displayName) · \(device.ip)" }
        }
        return result
    }

    private func tableView(_ rows: [FortiClientRow], ssidGroup: String? = nil) -> some View {
        let model = ssidGroup == nil ? table : groupTable
        let customization = Binding(get: { model.customization }, set: { model.customization = $0 })
        return Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: customization) {
            Group {
                TableColumn(StandardTableHeading("CLIENT"), sortUsing: table.sort("nom")) { row in
                    HStack(spacing: 5) {
                        Text(row.client.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if row.deviceName != nil {
                            Image(systemName: "link").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                                .help("Appareil du Scanner\u{00A0}: \(row.deviceName ?? "")")
                        }
                    }
                }
                .width(min: 110, ideal: 140)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("SIGNAL"), sortUsing: table.sort("rssi")) { row in
                    HStack(spacing: 6) {
                        if let rssi = row.client.rssi {
                            WifiSignalBar(rssi: rssi, width: 28)
                            Text(WifiQuality.dbm(rssi)).font(Theme.mono(12, weight: .semibold))
                                .foregroundStyle(row.isWeak ? Theme.critical : WifiText.qualityColor(rssi).foreground).lineLimit(1)
                        } else {
                            WifiCell("—", dimmed: true)
                        }
                    }
                    .frame(height: 20)
                }
                .width(min: 80, ideal: 92)
                .customizationID("rssi")

                TableColumn(StandardTableHeading("SNR"), sortUsing: table.sort("snr")) { row in
                    let weak = (row.client.snr ?? 99) < store.thresholds.weakSNR
                    WifiCell(row.client.snr.map { "\($0)\u{00A0}dB" } ?? "—", mono: 12, weight: weak ? .bold : .regular,
                             color: weak ? Theme.critical : Theme.neutralText, dimmed: row.client.snr == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 46, ideal: 54)
                .customizationID("snr")

                TableColumn(StandardTableHeading("BORNE"), sortUsing: table.sort("borne")) { row in
                    WifiCell(row.client.apName ?? "—", mono: 11, dimmed: row.client.apName == nil)
                }
                .width(min: 80, ideal: 100)
                .customizationID("borne")

                TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                    WifiCell(row.client.ssid ?? "—", dimmed: row.client.ssid == nil)
                }
                .width(min: 70, ideal: 100)
                .customizationID("ssid")

                TableColumn(StandardTableHeading("BANDE"), sortUsing: table.sort("bande")) { row in
                    WifiCell(row.client.band?.label ?? "—", dimmed: row.client.band == nil)
                }
                .width(min: 48, ideal: 56)
                .customizationID("bande")

                TableColumn(StandardTableHeading("CANAL"), sortUsing: table.sort("canal")) { row in
                    WifiCell(row.client.channel.map(String.init) ?? "—", mono: 12, dimmed: row.client.channel == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 40, ideal: 48)
                .customizationID("canal")

                TableColumn(StandardTableHeading("ADRESSE IP"), sortUsing: table.sort("ip")) { row in
                    WifiCell(row.client.ip?.description ?? "—", mono: 12, dimmed: row.client.ip == nil)
                }
                .width(min: 90, ideal: 104)
                .customizationID("ip")

                TableColumn(StandardTableHeading("DÉBIT"), sortUsing: table.sort("debit")) { row in
                    WifiCell(FortiAPText.rate(row.client.rateMbps), mono: 12, dimmed: row.client.rateMbps == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 84)
                .customizationID("debit")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("MAC"), sortUsing: table.sort("mac")) { row in
                    WifiCell(row.client.mac.formatted(.upperColon), mono: 11)
                }
                .width(min: 110, ideal: 122)
                .customizationID("mac")
                .defaultVisibility(.hidden)

            }
            Group {
                TableColumn(StandardTableHeading("ASSOCIÉ DEPUIS"), sortUsing: table.sort("duree")) { row in
                    WifiCell(FortiAPText.duration(row.client.associatedFor), dimmed: row.client.associatedFor == nil)
                }
                .width(min: 70, ideal: 90)
                .customizationID("duree")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("SYSTÈME"), sortUsing: table.sort("systeme")) { row in
                    WifiCell(row.client.os ?? "—", dimmed: row.client.os == nil)
                }
                .width(min: 60, ideal: 80)
                .customizationID("systeme")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("VLAN"), sortUsing: table.sort("vlan")) { row in
                    WifiCell(row.client.vlan.map(String.init) ?? "—", mono: 12, dimmed: row.client.vlan == nil)
                }
                .width(min: 40, ideal: 48)
                .customizationID("vlan")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("APPAREIL DU SCANNER"), sortUsing: table.sort("appareil")) { row in
                    WifiCell(row.deviceName ?? "—", dimmed: row.deviceName == nil)
                }
                .width(min: 100, ideal: 160)
                .customizationID("appareil")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { row in WifiCell(row.client.site) }
                    .width(min: 60, ideal: 100)
                    .customizationID("site")
                    .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 48 : plusieurs sites affichés, colonne « Site » montrée d’office.
        .standardSiteColumn(model, multiple: store.shownOverview.isMultiSite)
        .onAppear {
            // Colonne SSID masquée d'office dans la vue par SSID (l'utilisateur peut la remontrer).
            if ssidGroup != nil, groupTable.customization[visibility: "ssid"] == .automatic {
                groupTable.customization[visibility: "ssid"] = .hidden
            }
        }
        // Note 46 : double-clic ou ↩︎ → fiche complète du client (Wi-Fi › FortiAP), qui mène à la fiche
        // Appareil, à l'Inventaire et au Ping ; clic droit → « Fiche du client » et « Ouvrir dans › ».
        .standardRowActions(selection: selection.map { [$0] } ?? [], object: { id in
            guard let client = store.shownOverview.clients.first(where: { $0.id == id }) else { return nil }
            let matched = store.deviceLinks(state.devices)[client.id]
            return .wifiClient(mac: client.mac.formatted(.upperColon), ip: matched ?? client.ip?.description,
                               name: client.hostname ?? client.mac.formatted(.upperColon), apID: store.ap(for: client)?.id)
        }, primary: { ids in
            guard let client = store.shownOverview.clients.first(where: { ids.contains($0.id) }) else { return false }
            openClient(client, ssidGroup: ssidGroup)
            return true
        }) { ids in
            if ids.count == 1, let client = store.shownOverview.clients.first(where: { ids.contains($0.id) }) {
                Button("Fiche du client") { openClient(client, ssidGroup: ssidGroup) }
            }
        }
    }

    /// Fiche du client ; le Retour ramène au SSID déplié (vue par SSID) ou à la liste.
    private func openClient(_ client: FortiWifiClient, ssidGroup: String?) {
        store.viewedSSID = ssidGroup
        state.navigate(store.clientDestination(client))
    }
}

// MARK: - SSID

struct FortiSSIDRow: Identifiable {
    let ssid: FortiSSID
    let clients: Int
    var id: FortiSSID.ID { ssid.id }
    var name: String { ssid.ssid.lowercased() }
    var interface: String { ssid.name }
    /// Texte de la colonne « Options » (tri) ; vide en dernier.
    var options: String
    var security: String { ssid.securityLabel }
    var vlan: Int { ssid.vlan ?? Int.max }
    var site: String { ssid.site }
}

struct FortiAPSSIDTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @StateObject private var table = StandardTableModel<FortiSSIDRow>(id: "wifi.fortiap.ssid", columns: Self.columns,
                                                                      sortKeys: Self.sortKeys, defaultSort: "ssid")
    @State private var search = ""
    @State private var selection: FortiSSIDRow.ID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ssid", title: "SSID", isRequired: true),
        StandardColumn(id: "securite", title: "Sécurité"),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "clients", title: "Clients"),
        StandardColumn(id: "interface", title: "Interface (VAP)"),
        StandardColumn(id: "options", title: "Options"),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FortiSSIDRow>] = [
        "ssid": KeyPathComparator(\FortiSSIDRow.name), "securite": KeyPathComparator(\FortiSSIDRow.security),
        "vlan": KeyPathComparator(\FortiSSIDRow.vlan), "clients": KeyPathComparator(\FortiSSIDRow.clients),
        "interface": KeyPathComparator(\FortiSSIDRow.interface), "options": KeyPathComparator(\FortiSSIDRow.options),
        "site": KeyPathComparator(\FortiSSIDRow.site),
    ]

    var body: some View {
        let all = store.shownOverview.ssids
        let clients = store.shownOverview.clients
        let query = FortiSearch(search, global: state.searchQuery(for: .wifi), schema: .wifiSSID)
        let rows = all.filter { s in
            query.matches(["ssid": [s.ssid], "securite": [s.securityLabel, s.security], "vlan": [s.vlan.map(String.init)], "site": [s.site]],
                          freeText: [s.ssid, s.name, s.securityLabel, s.vlan.map { "vlan \($0)" }, s.site])
        }
            .map { s in
                FortiSSIDRow(ssid: s, clients: clients.filter { $0.site == s.site && $0.ssid == s.ssid }.count,
                             options: Self.options(s) == "—" ? last : Self.options(s))
            }
            .sorted(using: table.sortOrder + [KeyPathComparator(\FortiSSIDRow.site)])
        FortiAPTableFrame {
            FortiAPTableHeader(title: "SSID diffusés", summary: "\(store.shownOverview.distinctSSIDs.count) SSID",
                               search: $search, prompt: "SSID, VLAN…", model: table) { EmptyView() }
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyLine(all.isEmpty ? "Aucun SSID lu (configuration des SSID absente ou refusée par la FortiGate)." : "Aucun SSID ne correspond.")
            } else {
                Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                        Text(row.ssid.ssid).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .width(min: 100, ideal: 140)
                    .customizationID("ssid")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn(StandardTableHeading("SÉCURITÉ"), sortUsing: table.sort("securite")) { row in
                        let s = row.ssid
                        if s.isOpen {
                            WifiPill(text: s.securityLabel, foreground: Theme.critical, background: Theme.criticalSoft)
                        } else if s.securityLabel.contains("WPA3") {
                            WifiPill(text: s.securityLabel, foreground: Theme.success, background: Theme.successSoft)
                        } else {
                            WifiPill(text: s.securityLabel)
                        }
                    }
                    .width(min: 100, ideal: 150)
                    .customizationID("securite")
                    TableColumn(StandardTableHeading("VLAN"), sortUsing: table.sort("vlan")) { row in
                        WifiCell(row.ssid.vlan.map(String.init) ?? "—", mono: 12, dimmed: row.ssid.vlan == nil)
                    }
                    .width(min: 40, ideal: 50)
                    .customizationID("vlan")
                    TableColumn(StandardTableHeading("CLIENTS"), sortUsing: table.sort("clients")) { row in
                        WifiCell("\(row.clients)", mono: 12, weight: .semibold, color: Theme.text).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 50, ideal: 60)
                    .customizationID("clients")
                    TableColumn(StandardTableHeading("INTERFACE"), sortUsing: table.sort("interface")) { row in WifiCell(row.ssid.name, mono: 11) }
                        .width(min: 80, ideal: 110)
                        .customizationID("interface")
                    TableColumn(StandardTableHeading("OPTIONS"), sortUsing: table.sort("options")) { row in WifiCell(Self.options(row.ssid)) }
                        .width(min: 80, ideal: 170)
                        .customizationID("options")
                    TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { row in WifiCell(row.ssid.site) }
                        .width(min: 60, ideal: 100)
                        .customizationID("site")
                        .defaultVisibility(.hidden)
                }
                .standardTableStyle()
                // Note 48 : plusieurs sites affichés, colonne « Site » montrée d’office.
                .standardSiteColumn(table, multiple: store.shownOverview.isMultiSite)
                .standardTableHeight(rows: rows.count, rowHeight: fortiRowHeight, maxRows: 8)
            }
        }
    }

    static func options(_ s: FortiSSID) -> String {
        var parts: [String] = []
        if s.hidden == true { parts.append("caché") }
        if s.captivePortal == true { parts.append("portail captif") }
        if s.localBridging == true { parts.append("pont local") }
        if let max = s.maxClients { parts.append("\(max) clients max") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - AP voisins et non autorisés

struct FortiRogueRow: Identifiable {
    let rogue: FortiRogueAP
    var id: FortiRogueAP.ID { rogue.id }
    var ssid: String { rogue.ssid?.lowercased() ?? last }
    var bssid: UInt64 { rogue.bssid?.value ?? UInt64.max }
    var channel: Int { rogue.channel ?? Int.max }
    var band: Int { rogue.band.flatMap { WifiBand.allCases.firstIndex(of: $0) } ?? 9 }
    var rssi: Int { rogue.rssi ?? Int.min }
    var statusRank: Int { rogue.isUnauthorized ? 0 : (rogue.status == .unclassified ? 1 : 2) }
    var seenBy: String { rogue.seenBy.joined(separator: ", ") }
    var security: String { rogue.security ?? last }
    var vendor: String { rogue.vendor ?? last }
    var site: String { rogue.site }
}

struct FortiAPRogueTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @StateObject private var table = StandardTableModel<FortiRogueRow>(id: "wifi.fortiap.voisins", columns: Self.columns,
                                                                       sortKeys: Self.sortKeys, defaultSort: "etat")
    @State private var search = ""
    @State private var onlyUnauthorized = false
    @State private var selection: FortiRogueRow.ID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ssid", title: "SSID", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "bssid", title: "BSSID"),
        StandardColumn(id: "canal", title: "Canal"),
        StandardColumn(id: "bande", title: "Bande"),
        StandardColumn(id: "signal", title: "Signal"),
        StandardColumn(id: "vu", title: "Vu par"),
        StandardColumn(id: "securite", title: "Sécurité", isDefaultVisible: false),
        StandardColumn(id: "fabricant", title: "Fabricant", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FortiRogueRow>] = [
        "ssid": KeyPathComparator(\FortiRogueRow.ssid), "etat": KeyPathComparator(\FortiRogueRow.statusRank),
        "bssid": KeyPathComparator(\FortiRogueRow.bssid), "canal": KeyPathComparator(\FortiRogueRow.channel),
        "bande": KeyPathComparator(\FortiRogueRow.band), "signal": KeyPathComparator(\FortiRogueRow.rssi, order: .reverse),
        "vu": KeyPathComparator(\FortiRogueRow.seenBy), "securite": KeyPathComparator(\FortiRogueRow.security),
        "fabricant": KeyPathComparator(\FortiRogueRow.vendor), "site": KeyPathComparator(\FortiRogueRow.site),
    ]

    var body: some View {
        let all = store.shownOverview.rogues
        let query = FortiSearch(search, global: state.searchQuery(for: .wifi), schema: .wifiVoisins)
        let rows = all.filter { r in
            (!onlyUnauthorized || r.isUnauthorized)
                && query.matches(["ssid": [r.ssid], "mac": [r.bssid?.formatted(.colon)], "fab": [r.vendor], "canal": [r.channel.map(String.init)],
                                  "bande": bandTerms(r.band), "securite": [r.security], "etat": [r.status.label, r.isUnauthorized ? "non autorisé" : nil],
                                  "borne": r.seenBy, "site": [r.site]],
                                 freeText: [r.ssid, r.bssid?.formatted(.upperColon), r.vendor, r.seenBy.joined(separator: " "), r.site, r.channel.map { "canal \($0)" }])
        }
        .map(FortiRogueRow.init)
        .sorted(using: table.sortOrder + [KeyPathComparator(\FortiRogueRow.rssi, order: .reverse)])
        let unauthorized = all.filter(\.isUnauthorized).count
        FortiAPTableFrame {
            FortiAPTableHeader(title: "AP voisins et non autorisés", summary: "\(all.count) vus par les bornes",
                               search: $search, prompt: "SSID, BSSID, fabricant…", model: table) {
                Picker("AP affichés", selection: $onlyUnauthorized) {
                    Text("Tous (\(all.count))").tag(false)
                    Text("Non autorisés (\(unauthorized))").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                emptyLine(all.isEmpty ? "Aucun AP voisin lu (analyse WIDS désactivée sur les profils, ou liste des AP voisins absente)." : "Aucun AP ne correspond à ce filtre.")
            } else {
                Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                        Text(row.rogue.ssid ?? "(SSID caché)")
                            .font(row.rogue.ssid == nil ? Theme.small.italic() : .system(size: 12, weight: .semibold))
                            .foregroundStyle(row.rogue.ssid == nil ? Theme.textSecondary : Theme.text).lineLimit(1)
                    }
                    .width(min: 100, ideal: 140)
                    .customizationID("ssid")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in
                        statusPill(row.rogue).help(row.rogue.onWire ? "Vu aussi sur le réseau câblé de la FortiGate" : row.rogue.status.label)
                    }
                        .width(min: 80, ideal: 128)
                        .customizationID("etat")
                    TableColumn(StandardTableHeading("BSSID"), sortUsing: table.sort("bssid")) { row in
                        WifiCell(row.rogue.bssid?.formatted(.upperColon) ?? "—", mono: 11, dimmed: row.rogue.bssid == nil)
                    }
                    .width(min: 110, ideal: 122)
                    .customizationID("bssid")
                    TableColumn(StandardTableHeading("CANAL"), sortUsing: table.sort("canal")) { row in
                        WifiCell(row.rogue.channel.map(String.init) ?? "—", mono: 12, dimmed: row.rogue.channel == nil)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 40, ideal: 48)
                    .customizationID("canal")
                    TableColumn(StandardTableHeading("BANDE"), sortUsing: table.sort("bande")) { row in
                        WifiCell(row.rogue.band?.label ?? "—", dimmed: row.rogue.band == nil)
                    }
                    .width(min: 48, ideal: 56)
                    .customizationID("bande")
                    TableColumn(StandardTableHeading("SIGNAL"), sortUsing: table.sort("signal")) { row in
                        HStack(spacing: 6) {
                            if let rssi = row.rogue.rssi {
                                WifiSignalBar(rssi: rssi, width: 28)
                                Text(WifiQuality.dbm(rssi)).font(Theme.mono(12, weight: .semibold))
                                    .foregroundStyle(WifiText.qualityColor(rssi).foreground).lineLimit(1)
                            } else {
                                WifiCell("—", dimmed: true)
                            }
                        }
                        .frame(height: 20)
                    }
                    .width(min: 80, ideal: 92)
                    .customizationID("signal")
                    TableColumn(StandardTableHeading("VU PAR"), sortUsing: table.sort("vu")) { row in
                        WifiCell(row.seenBy.isEmpty ? "—" : row.seenBy, mono: 11, dimmed: row.seenBy.isEmpty)
                    }
                    .width(min: 80, ideal: 130)
                    .customizationID("vu")
                    TableColumn(StandardTableHeading("SÉCURITÉ"), sortUsing: table.sort("securite")) { row in
                        WifiCell(row.rogue.security ?? "—", dimmed: row.rogue.security == nil)
                    }
                    .width(min: 70, ideal: 110)
                    .customizationID("securite")
                    .defaultVisibility(.hidden)
                    TableColumn(StandardTableHeading("FABRICANT"), sortUsing: table.sort("fabricant")) { row in
                        WifiCell(row.rogue.vendor ?? "—", dimmed: row.rogue.vendor == nil)
                    }
                    .width(min: 60, ideal: 90)
                    .customizationID("fabricant")
                    .defaultVisibility(.hidden)
                    TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { row in WifiCell(row.rogue.site) }
                        .width(min: 60, ideal: 100)
                        .customizationID("site")
                        .defaultVisibility(.hidden)
                }
                .standardTableStyle()
                // Note 48 : plusieurs sites affichés, colonne « Site » montrée d’office.
                .standardSiteColumn(table, multiple: store.shownOverview.isMultiSite)
                .standardTableHeight(rows: rows.count, rowHeight: fortiRowHeight, maxRows: 10)
            }
        }
    }

    private func statusPill(_ r: FortiRogueAP) -> WifiPill {
        if r.isUnauthorized {
            return WifiPill(text: r.onWire ? "Non autorisé (câblé)" : "Non autorisé", foreground: Theme.critical, background: Theme.criticalSoft)
        }
        switch r.status {
        case .accepted: return WifiPill(text: "Accepté", foreground: Theme.success, background: Theme.successSoft)
        case .suppressed: return WifiPill(text: "Neutralisé", foreground: Theme.warning, background: Theme.warningSoft)
        default: return WifiPill(text: "Voisin")
        }
    }
}
