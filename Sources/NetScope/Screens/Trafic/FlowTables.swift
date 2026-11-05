import NetScopeCore
import SwiftUI

// Tableaux de la source « Flux » de l'écran Trafic (note 75) : tableaux standard (tri, colonnes à
// choisir, retenues par tableau). Les sources sont reliées à leur appareil comme celles de
// FortiView : double-clic ou ↩︎ → fiche Appareil, clic droit → ping, port de switch.

/// Onglets et tableau choisi.
struct FlowTabsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var flows = FlowStore.shared
    let overview: TrafficOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                Picker("Vue", selection: $flows.tab) {
                    ForEach(FlowTab.allCases) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                HStack(spacing: 10) {
                    Text("Vue").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                    Picker("Vue", selection: $flows.tab) {
                        ForEach(FlowTab.allCases) { Label(label($0), systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            switch flows.tab {
            case .conversations:
                FlowConversationTable(rows: conversationRows, multiExporter: overview.isMultiSite, period: overview.period)
            case .exporters:
                FlowExporterTable()
            default:
                if let view = flows.tab.view {
                    FlowEntryTable(tab: flows.tab, rows: rows(view), multiExporter: overview.isMultiSite, period: overview.period)
                        .id(flows.tab)
                }
            }
        }
    }

    private func label(_ tab: FlowTab) -> String {
        switch tab {
        case .exporters: return "Exportateurs (\(flows.status.exporters.count))"
        case .applications:
            let risky = TrafficAnalysis.unexpectedApplications(overview).count
            return risky > 0 ? "Applications ⚠︎" : tab.label
        default: return tab.label
        }
    }

    private func rows(_ view: TrafficView) -> [FlowRow] {
        let store = TrafficStore.shared
        let linksBySite = Dictionary(grouping: overview.links, by: \.site)
        return overview.entries(view).map { entry in
            var ref: NavDeviceRef?
            var name = entry.name
            if view == .sources || view == .destinations, let ip = entry.ip, FlowApplications.isLocal(ip) {
                ref = store.deviceRef(ip: ip, mac: nil, name: entry.name, site: entry.site, state: state)
                if let known = ref, known.name != known.ip { name = known.name }
            }
            let location = ref.flatMap { r in r.switchName.map { $0 + (r.switchPort.map { " · " + $0 } ?? "") } }
            let link = view == .interfaces ? linksBySite[entry.site]?.first { $0.name == entry.key } : nil
            return FlowRow(entry: entry, name: name, ref: ref, location: location, link: link)
        }
    }

    private var conversationRows: [FlowConversationRow] {
        let store = TrafficStore.shared
        return overview.sessions.map { session in
            let ref = session.source.flatMap { store.deviceRef(ip: $0, mac: nil, name: $0.description, site: session.site, state: state) }
            var remoteName: String?
            if let destination = session.destination, FlowApplications.isLocal(destination),
               let known = store.deviceRef(ip: destination, mac: nil, name: destination.description, site: session.site, state: state),
               known.name != known.ip {
                remoteName = known.name
            }
            return FlowConversationRow(session: session, localName: ref.map { $0.name != $0.ip ? $0.name : nil } ?? nil, remoteName: remoteName, ref: ref)
        }
    }
}

// MARK: - Lignes

struct FlowRow: Identifiable {
    let entry: TrafficEntry
    let name: String
    let ref: NavDeviceRef?
    let location: String?
    let link: TrafficLink?

    var id: String { entry.id }

    var sortName: String { SearchText.fold(name) }
    var sortIP: UInt32 { entry.ip?.value ?? .max }
    var sortRate: Double { entry.bandwidth }
    var sortBytes: UInt64 { entry.bytes }
    var sortSent: UInt64 { entry.sentBytes }
    var sortReceived: UInt64 { entry.receivedBytes }
    var sortFlows: Int { entry.sessions }
    var sortCategory: String { entry.category ?? "~" }
    var sortRisk: Int { entry.risk ?? 0 }
    var sortLocation: String { location ?? "~" }
    var sortSite: String { entry.site }
    var sortLoad: Double { link?.utilization ?? -1 }

    static let sortKeys: [String: KeyPathComparator<FlowRow>] = [
        "nom": KeyPathComparator(\.sortName), "ip": KeyPathComparator(\.sortIP),
        "debit": KeyPathComparator(\.sortRate, order: .reverse), "octets": KeyPathComparator(\.sortBytes, order: .reverse),
        "envoye": KeyPathComparator(\.sortSent, order: .reverse), "recu": KeyPathComparator(\.sortReceived, order: .reverse),
        "flux": KeyPathComparator(\.sortFlows, order: .reverse), "categorie": KeyPathComparator(\.sortCategory),
        "risque": KeyPathComparator(\.sortRisk, order: .reverse), "port": KeyPathComparator(\.sortLocation),
        "site": KeyPathComparator(\.sortSite), "charge": KeyPathComparator(\.sortLoad, order: .reverse),
    ]

    static let exporterColumn = StandardColumn(id: "site", title: "Exportateur", isDefaultVisible: false)

    static func columns(_ tab: FlowTab) -> [StandardColumn] {
        switch tab {
        case .sources:
            return [StandardColumn(id: "nom", title: "Appareil", isRequired: true), StandardColumn(id: "ip", title: "Adresse IP"),
                    StandardColumn(id: "debit", title: "Débit"), StandardColumn(id: "envoye", title: "Envoyé"),
                    StandardColumn(id: "recu", title: "Reçu"), StandardColumn(id: "flux", title: "Flux"),
                    StandardColumn(id: "port", title: "Port de switch"), exporterColumn]
        case .destinations:
            return [StandardColumn(id: "nom", title: "Destination", isRequired: true), StandardColumn(id: "debit", title: "Débit"),
                    StandardColumn(id: "envoye", title: "Envoyé vers"), StandardColumn(id: "recu", title: "Reçu de"),
                    StandardColumn(id: "flux", title: "Flux"), exporterColumn]
        case .applications:
            return [StandardColumn(id: "nom", title: "Application", isRequired: true), StandardColumn(id: "categorie", title: "Catégorie"),
                    StandardColumn(id: "risque", title: "Risque"), StandardColumn(id: "debit", title: "Débit"),
                    StandardColumn(id: "octets", title: "Octets"), StandardColumn(id: "flux", title: "Flux"), exporterColumn]
        case .interfaces:
            return [StandardColumn(id: "nom", title: "Interface", isRequired: true), StandardColumn(id: "charge", title: "Charge du lien"),
                    StandardColumn(id: "debit", title: "Débit"), StandardColumn(id: "recu", title: "Entré"),
                    StandardColumn(id: "envoye", title: "Sorti"), StandardColumn(id: "flux", title: "Flux"), exporterColumn]
        case .conversations, .exporters:
            return []
        }
    }
}

struct FlowConversationRow: Identifiable {
    let session: TrafficSession
    let localName: String?
    let remoteName: String?
    let ref: NavDeviceRef?
    var id: String { session.id }

    var localText: String {
        guard let ip = session.source?.description else { return "—" }
        return localName.map { "\($0) (\(ip))" } ?? ip
    }

    var remoteText: String {
        guard let ip = session.destination?.description else { return "—" }
        return remoteName.map { "\($0) (\(ip))" } ?? ip
    }

    var sortLocal: UInt32 { session.source?.value ?? .max }
    var sortRemote: UInt32 { session.destination?.value ?? .max }
    var sortPort: Int { session.destinationPort ?? .max }
    var sortProto: String { session.proto }
    var sortApp: String { session.application ?? "~" }
    var sortSent: UInt64 { session.sentBytes }
    var sortReceived: UInt64 { session.receivedBytes }
    var sortBytes: UInt64 { session.bytes }
    var sortDuration: Int { session.duration ?? -1 }
    var sortSite: String { session.site }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "local", title: "Appareil", isRequired: true), StandardColumn(id: "distant", title: "Destination"),
        StandardColumn(id: "port", title: "Port"), StandardColumn(id: "proto", title: "Protocole"),
        StandardColumn(id: "app", title: "Application"), StandardColumn(id: "envoye", title: "Envoyé"),
        StandardColumn(id: "recu", title: "Reçu"), StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
        FlowRow.exporterColumn,
    ]

    static let sortKeys: [String: KeyPathComparator<FlowConversationRow>] = [
        "local": KeyPathComparator(\.sortLocal), "distant": KeyPathComparator(\.sortRemote),
        "port": KeyPathComparator(\.sortPort), "proto": KeyPathComparator(\.sortProto), "app": KeyPathComparator(\.sortApp),
        "envoye": KeyPathComparator(\.sortSent, order: .reverse), "recu": KeyPathComparator(\.sortReceived, order: .reverse),
        "octets": KeyPathComparator(\.sortBytes, order: .reverse), "duree": KeyPathComparator(\.sortDuration, order: .reverse),
        "site": KeyPathComparator(\.sortSite),
    ]
}

// MARK: - Sources, destinations, applications, interfaces

struct FlowEntryTable: View {
    @EnvironmentObject private var state: AppState
    let tab: FlowTab
    let rows: [FlowRow]
    let multiExporter: Bool
    let period: TrafficPeriod
    @StateObject private var table: StandardTableModel<FlowRow>
    @State private var selection: Set<String> = []

    init(tab: FlowTab, rows: [FlowRow], multiExporter: Bool, period: TrafficPeriod) {
        self.tab = tab
        self.rows = rows
        self.multiExporter = multiExporter
        self.period = period
        _table = StateObject(wrappedValue: StandardTableModel(id: "flux.\(tab.rawValue)", columns: FlowRow.columns(tab),
                                                              sortKeys: FlowRow.sortKeys, defaultSort: "debit"))
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            TrafficTableBar(title: tab.label + " " + FlowTrafficBridge.span(period), count: sorted.count) {
                FlowCSVButton(name: "flux-\(tab.rawValue)") { FlowCSV.entries(sorted, multi: multiExporter) }
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 14, emptyText: "Aucun flux \(FlowTrafficBridge.span(period)).") {
                tableView(sorted)
                    .standardRowActions(selection: sorted.map(\.id).filter(selection.contains), object: { id in
                        sorted.first { $0.id == id }?.ref.map { NavObject.device($0) }
                    }) { ids in
                        if let row = sorted.first(where: { ids.contains($0.id) }) { menu(row) }
                    }
            }
            .standardSiteColumn(table, multiple: multiExporter)
        }
    }

    @ViewBuilder private func menu(_ row: FlowRow) -> some View {
        if let ip = row.entry.ip {
            Button("Copier l’adresse " + ip.description) { ToolActions.copy(ip.description) }
            Button("Ajouter au ping continu") { state.sendToPing(ip.description) }
        }
        if tab == .sources, row.location != nil, let ref = row.ref {
            Button("Voir le port de switch") { state.showSwitchPort(switchName: ref.switchName, port: ref.switchPort) }
        }
        if tab == .sources {
            Button("Qui sature le lien\u{00A0}?") { TrafficScreenState.shared.showSaturation = true }
        }
        Button("Copier la ligne") {
            ToolActions.copy([row.name, row.entry.ip?.description ?? "", TrafficFormat.rate(row.entry.bandwidth),
                              TrafficFormat.bytes(row.entry.bytes), "\(row.entry.sessions) flux"].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    @ViewBuilder private func tableView(_ sorted: [FlowRow]) -> some View {
        switch tab {
        case .sources:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; ipColumn; rateColumn; sentColumn; receivedColumn; flowsColumn; portColumn; siteColumn
            }
        case .destinations:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; rateColumn; sentColumn; receivedColumn; flowsColumn; siteColumn
            }
        case .applications:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; categoryColumn; riskColumn; rateColumn; bytesColumn; flowsColumn; siteColumn
            }
        default:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; loadColumn; rateColumn; receivedColumn; sentColumn; flowsColumn; siteColumn
            }
        }
    }

    private var nameTitle: String {
        switch tab {
        case .sources: return "APPAREIL"
        case .destinations: return "DESTINATION"
        case .applications: return "APPLICATION"
        default: return "INTERFACE"
        }
    }

    private var nameColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn(nameTitle, sortUsing: table.sort("nom")) { row in
            switch tab {
            case .interfaces:
                HStack(spacing: 6) {
                    ToolTableText(row.link?.label ?? row.entry.name, weight: .semibold)
                    if row.link?.isWAN == true { Chip(text: "WAN", tone: .accent) }
                }
            case .sources:
                HStack(spacing: 5) {
                    Image(systemName: row.ref?.switchName == nil ? "questionmark.circle" : "desktopcomputer")
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    ToolTableText(row.name, mono: row.name == row.entry.ip?.description, weight: .semibold)
                }
                .help(row.ref == nil ? row.name : "\(row.name) · double-clic\u{00A0}: fiche de l’appareil")
            case .destinations:
                HStack(spacing: 5) {
                    ToolTableText(row.name, mono: row.name == row.entry.ip?.description, weight: .semibold)
                    if let ip = row.entry.ip, FlowApplications.isLocal(ip) {
                        Chip(text: "Réseau local", tone: .neutral)
                    }
                }
            default:
                ToolTableText(row.name, mono: false, weight: .semibold).help(row.name)
            }
        }
        .width(min: 110, ideal: 190)
        .customizationID("nom")
        .disabledCustomizationBehavior(.visibility)
    }

    private var ipColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("ADRESSE IP", sortUsing: table.sort("ip")) { row in
            ToolTableText(row.entry.ip?.description ?? "—", color: Theme.textSecondary)
        }
        .width(min: 90, ideal: 110)
        .customizationID("ip")
    }

    private var rateColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("DÉBIT", sortUsing: table.sort("debit")) { row in
            ToolTableText(TrafficFormat.rate(row.entry.bandwidth), alignment: .trailing)
                .help(period.isRealtime ? "Débit moyen sur la dernière minute" : "Débit moyen \(FlowTrafficBridge.span(period))")
        }
        .width(min: 64, ideal: 90)
        .customizationID("debit")
    }

    private var sentColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn(tab == .destinations ? "ENVOYÉ VERS" : (tab == .interfaces ? "SORTI" : "ENVOYÉ"), sortUsing: table.sort("envoye")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.sentBytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 86)
        .customizationID("envoye")
    }

    private var receivedColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn(tab == .destinations ? "REÇU DE" : (tab == .interfaces ? "ENTRÉ" : "REÇU"), sortUsing: table.sort("recu")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.receivedBytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 86)
        .customizationID("recu")
    }

    private var bytesColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("OCTETS", sortUsing: table.sort("octets")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.bytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 86)
        .customizationID("octets")
    }

    private var flowsColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("FLUX", sortUsing: table.sort("flux")) { row in
            ToolTableText(ToolFormat.integer(row.entry.sessions), alignment: .trailing)
        }
        .width(min: 50, ideal: 64)
        .customizationID("flux")
    }

    private var categoryColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("CATÉGORIE", sortUsing: table.sort("categorie")) { row in
            ToolTableText(row.entry.category ?? "—", mono: false, color: Theme.textSecondary)
        }
        .width(min: 80, ideal: 140)
        .customizationID("categorie")
    }

    private var riskColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("RISQUE", sortUsing: table.sort("risque")) { row in
            if let risk = row.entry.risk {
                Chip(text: TrafficFormat.risk(risk), tone: risk >= 4 ? .critical : (risk == 3 ? .warning : .neutral))
            } else {
                ToolTableText("—", color: Theme.textTertiary)
            }
        }
        .width(min: 80, ideal: 110)
        .customizationID("risque")
    }

    private var portColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("PORT DE SWITCH", sortUsing: table.sort("port")) { row in
            ToolTableText(row.location ?? "—", color: row.location == nil ? Theme.textTertiary : Theme.text)
        }
        .width(min: 90, ideal: 140)
        .customizationID("port")
    }

    private var loadColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("CHARGE DU LIEN", sortUsing: table.sort("charge")) { row in
            TrafficLoadCell(link: row.link)
        }
        .width(min: 100, ideal: 150)
        .customizationID("charge")
    }

    private var siteColumn: some TableColumnContent<FlowRow, KeyPathComparator<FlowRow>> {
        TableColumn("EXPORTATEUR", sortUsing: table.sort("site")) { row in
            ToolTableText(row.entry.site, mono: false, color: Theme.textSecondary)
        }
        .width(min: 80, ideal: 150)
        .customizationID("site")
        .defaultVisibility(.hidden)
    }
}

// MARK: - Conversations

struct FlowConversationTable: View {
    @EnvironmentObject private var state: AppState
    let rows: [FlowConversationRow]
    let multiExporter: Bool
    let period: TrafficPeriod
    @StateObject private var table = StandardTableModel<FlowConversationRow>(id: "flux.conversations", columns: FlowConversationRow.columns,
                                                                             sortKeys: FlowConversationRow.sortKeys, defaultSort: "envoye")
    @State private var selection: Set<String> = []

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            TrafficTableBar(title: "Conversations " + FlowTrafficBridge.span(period), count: sorted.count) {
                FlowCSVButton(name: "flux-conversations") { FlowCSV.conversations(sorted, multi: multiExporter) }
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 14, emptyText: "Aucune conversation \(FlowTrafficBridge.span(period)).") {
                Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    Group {
                        TableColumn("APPAREIL", sortUsing: table.sort("local")) { row in
                            ToolTableText(row.localText, mono: row.localName == nil, weight: .semibold)
                        }
                        .width(min: 120, ideal: 230)
                        .customizationID("local").disabledCustomizationBehavior(.visibility)
                        TableColumn("DESTINATION", sortUsing: table.sort("distant")) { row in
                            ToolTableText(row.remoteText, mono: row.remoteName == nil)
                        }
                        .width(min: 100, ideal: 170).customizationID("distant")
                        TableColumn("PORT", sortUsing: table.sort("port")) { row in
                            ToolTableText(row.session.destinationPort.map(String.init) ?? "—", alignment: .trailing)
                        }
                        .width(min: 44, ideal: 56).customizationID("port")
                        TableColumn("PROTOCOLE", sortUsing: table.sort("proto")) { row in
                            ToolTableText(row.session.proto, color: Theme.textSecondary)
                        }
                        .width(min: 50, ideal: 64).customizationID("proto")
                        TableColumn("APPLICATION", sortUsing: table.sort("app")) { row in
                            ToolTableText(row.session.application ?? "—", mono: false)
                        }
                        .width(min: 90, ideal: 150).customizationID("app")
                    }
                    Group {
                        TableColumn("ENVOYÉ", sortUsing: table.sort("envoye")) { row in
                            ToolTableText(TrafficFormat.bytes(row.session.sentBytes), alignment: .trailing)
                        }
                        .width(min: 64, ideal: 84).customizationID("envoye")
                        TableColumn("REÇU", sortUsing: table.sort("recu")) { row in
                            ToolTableText(TrafficFormat.bytes(row.session.receivedBytes), alignment: .trailing)
                        }
                        .width(min: 64, ideal: 84).customizationID("recu")
                        TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                            ToolTableText(TrafficFormat.duration(row.session.duration), alignment: .trailing)
                        }
                        .width(min: 56, ideal: 80).customizationID("duree").defaultVisibility(.hidden)
                        TableColumn("EXPORTATEUR", sortUsing: table.sort("site")) { row in
                            ToolTableText(row.session.site, mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 80, ideal: 150).customizationID("site").defaultVisibility(.hidden)
                    }
                }
                .standardRowActions(selection: sorted.map(\.id).filter(selection.contains), object: { id in
                    sorted.first { $0.id == id }?.ref.map { NavObject.device($0) }
                }) { ids in
                    if let row = sorted.first(where: { ids.contains($0.id) }), let destination = row.session.destination {
                        Button("Copier la destination " + destination.description) { ToolActions.copy(destination.description) }
                        Button("Ajouter la destination au ping continu") { state.sendToPing(destination.description) }
                    }
                }
            }
            .standardSiteColumn(table, multiple: multiExporter)
        }
    }
}

// MARK: - Exportateurs

struct FlowExporterRow: Identifiable {
    let status: FlowExporterStatus
    let name: String
    let settings: FlowExporterSettings
    let summary: FlowSummary?

    var id: IPv4Address { status.address }

    var wanText: String {
        let wan = settings.wanInterface ?? summary?.wanInterface
        guard let wan else { return "—" }
        var text = FlowTrafficBridge.interfaceName(wan)
        if let down = settings.downMbps, let up = settings.upMbps {
            text += " · \(ToolFormat.integer(Int(down)))/\(ToolFormat.integer(Int(up)))\u{00A0}Mb/s"
        } else if let speed = summary?.interfaces.first(where: { $0.index == wan })?.speed {
            text += " · " + ResourceFormat.bitsPerSecond(Double(speed))
        }
        return text + (settings.wanInterface == nil ? " (devinée)" : "")
    }

    var sortName: String { SearchText.fold(name) }
    var sortIP: UInt32 { status.address.value }
    var sortKinds: String { status.kindsLabel }
    var sortDatagrams: Int { status.datagrams }
    var sortRecords: Int { status.records }
    var sortRejected: Int { status.rejected }
    var sortTemplates: Int { status.templates }
    var sortWaiting: Int { status.waiting }
    var sortSampling: UInt32 { status.sampling }
    var sortLast: Date { status.lastSeen }
    var sortWAN: String { wanText }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Exportateur", isRequired: true), StandardColumn(id: "ip", title: "Adresse"),
        StandardColumn(id: "formats", title: "Formats"), StandardColumn(id: "datagrammes", title: "Datagrammes"),
        StandardColumn(id: "enregistrements", title: "Enregistrements"), StandardColumn(id: "rejetes", title: "Rejetés", isDefaultVisible: false),
        StandardColumn(id: "gabarits", title: "Gabarits", isDefaultVisible: false), StandardColumn(id: "attente", title: "En attente", isDefaultVisible: false),
        StandardColumn(id: "echantillon", title: "Échantillonnage"), StandardColumn(id: "wan", title: "Lien Internet"),
        StandardColumn(id: "dernier", title: "Dernier reçu"),
    ]

    static let sortKeys: [String: KeyPathComparator<FlowExporterRow>] = [
        "nom": KeyPathComparator(\.sortName), "ip": KeyPathComparator(\.sortIP), "formats": KeyPathComparator(\.sortKinds),
        "datagrammes": KeyPathComparator(\.sortDatagrams, order: .reverse), "enregistrements": KeyPathComparator(\.sortRecords, order: .reverse),
        "rejetes": KeyPathComparator(\.sortRejected, order: .reverse), "gabarits": KeyPathComparator(\.sortTemplates, order: .reverse),
        "attente": KeyPathComparator(\.sortWaiting, order: .reverse), "echantillon": KeyPathComparator(\.sortSampling, order: .reverse),
        "wan": KeyPathComparator(\.sortWAN), "dernier": KeyPathComparator(\.sortLast, order: .reverse),
    ]
}

struct FlowExporterTable: View {
    @ObservedObject private var flows = FlowStore.shared
    @StateObject private var table = StandardTableModel<FlowExporterRow>(id: "flux.exportateurs", columns: FlowExporterRow.columns,
                                                                         sortKeys: FlowExporterRow.sortKeys, defaultSort: "nom")
    @State private var selection: Set<IPv4Address> = []
    @State private var editing: IPv4Address?

    var body: some View {
        let rows = flows.status.exporters.map { status in
            FlowExporterRow(status: status, name: flows.name(of: status.address), settings: flows.settings(for: status.address),
                            summary: flows.summary(status.address))
        }
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            TrafficTableBar(title: "Exportateurs vus", count: sorted.count) {
                Button {
                    editing = sorted.first { selection.contains($0.id) }?.id ?? sorted.first?.id
                } label: { Label("Nom et lien Internet…", systemImage: "pencil") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(sorted.isEmpty)
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 10, emptyText: "Aucun exportateur n’a encore envoyé de flux.") {
                Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    Group {
                        TableColumn("EXPORTATEUR", sortUsing: table.sort("nom")) { row in
                            HStack(spacing: 6) {
                                StatusDot(tone: row.status.lastError != nil ? .warning : (Date().timeIntervalSince(row.status.lastSeen) < 300 ? .success : .neutral))
                                ToolTableText(row.name, mono: false, weight: .semibold)
                            }
                            .help(row.status.lastError.map { "Dernier rejet\u{00A0}: " + $0 } ?? row.name)
                        }
                        .width(min: 110, ideal: 170).customizationID("nom").disabledCustomizationBehavior(.visibility)
                        TableColumn("ADRESSE", sortUsing: table.sort("ip")) { row in
                            ToolTableText(row.status.address.description, color: Theme.textSecondary)
                        }
                        .width(min: 84, ideal: 96).customizationID("ip")
                        TableColumn("FORMATS", sortUsing: table.sort("formats")) { row in
                            ToolTableText(row.status.kindsLabel + " · UDP \(row.status.port)", mono: false)
                        }
                        .width(min: 90, ideal: 140).customizationID("formats")
                        TableColumn("DATAGRAMMES", sortUsing: table.sort("datagrammes")) { row in
                            ToolTableText(ToolFormat.integer(row.status.datagrams), alignment: .trailing)
                        }
                        .width(min: 56, ideal: 76).customizationID("datagrammes")
                        TableColumn("ENREGISTREMENTS", sortUsing: table.sort("enregistrements")) { row in
                            ToolTableText(ToolFormat.integer(row.status.records), alignment: .trailing)
                        }
                        .width(min: 56, ideal: 84).customizationID("enregistrements")
                        TableColumn("REJETÉS", sortUsing: table.sort("rejetes")) { row in
                            ToolTableText(ToolFormat.integer(row.status.rejected), color: row.status.rejected > 0 ? Theme.warning : Theme.textTertiary,
                                          alignment: .trailing)
                        }
                        .width(min: 44, ideal: 56).customizationID("rejetes").defaultVisibility(.hidden)
                    }
                    Group {
                        TableColumn("GABARITS", sortUsing: table.sort("gabarits")) { row in
                            ToolTableText(row.status.kinds.contains(.netflow9) || row.status.kinds.contains(.ipfix) ? ToolFormat.integer(row.status.templates) : "—",
                                          alignment: .trailing)
                        }
                        .width(min: 44, ideal: 60).customizationID("gabarits").defaultVisibility(.hidden)
                        TableColumn("EN ATTENTE", sortUsing: table.sort("attente")) { row in
                            ToolTableText(row.status.waiting > 0 ? ToolFormat.integer(row.status.waiting) : "—",
                                          color: row.status.waiting > 0 ? Theme.warning : Theme.textTertiary, alignment: .trailing)
                                .help("Ensembles de données reçus avant leur gabarit, décodés à son arrivée")
                        }
                        .width(min: 50, ideal: 70).customizationID("attente").defaultVisibility(.hidden)
                        TableColumn("ÉCHANTILLONNAGE", sortUsing: table.sort("echantillon")) { row in
                            ToolTableText(row.status.sampling > 1 ? "1/\(ToolFormat.integer(row.status.sampling))" : "aucun",
                                          color: row.status.sampling > 1 ? Theme.text : Theme.textTertiary, alignment: .trailing)
                        }
                        .width(min: 60, ideal: 84).customizationID("echantillon")
                        TableColumn("LIEN INTERNET", sortUsing: table.sort("wan")) { row in
                            ToolTableText(row.wanText, mono: false, color: row.wanText == "—" ? Theme.textTertiary : Theme.text)
                        }
                        .width(min: 110, ideal: 190).customizationID("wan")
                        TableColumn("DERNIER REÇU", sortUsing: table.sort("dernier")) { row in
                            ToolTableText(ToolText.relative(row.status.lastSeen), mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 64, ideal: 84).customizationID("dernier")
                    }
                }
                .contextMenu(forSelectionType: IPv4Address.self) { ids in
                    if let id = ids.first {
                        Button("Nom et lien Internet…") { editing = id }
                        Button("Copier l’adresse " + id.description) { ToolActions.copy(id.description) }
                        Divider()
                        Button("Oublier cet exportateur") { flows.forget(id) }
                    }
                } primaryAction: { ids in
                    editing = ids.first
                }
            }
            Text("Double-clic\u{00A0}: nom de l’exportateur, interface vers Internet et débits du lien (pour la charge et «\u{00A0}Qui sature le lien\u{00A0}?\u{00A0}»). Réglages enregistrés sur ce Mac.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: Binding(get: { editing.map(FlowEditing.init) }, set: { editing = $0?.id })) { item in
            FlowExporterEditor(exporter: item.id)
        }
    }
}

private struct FlowEditing: Identifiable {
    let id: IPv4Address
}

/// Nom d'un exportateur, interface vers Internet et débits du lien.
struct FlowExporterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var flows = FlowStore.shared
    let exporter: IPv4Address
    @State private var name = ""
    @State private var wan: UInt32 = 0
    @State private var down = ""
    @State private var up = ""

    var body: some View {
        let summary = flows.summary(exporter)
        VStack(alignment: .leading, spacing: 14) {
            Text("Exportateur \(exporter.description)").font(Theme.panelTitle)
            Form {
                TextField("Nom", text: $name, prompt: Text(exporter.description))
                Picker("Lien Internet", selection: $wan) {
                    Text(summary?.wanInterface.map { "Deviné (\(FlowTrafficBridge.interfaceName($0)))" } ?? "Deviné d’après les flux").tag(UInt32(0))
                    let indices = summary?.interfaces.map(\.index).sorted() ?? []
                    ForEach(indices, id: \.self) { index in
                        Text(FlowTrafficBridge.interfaceName(index)).tag(index)
                    }
                    // Interface enregistrée pas encore revue dans les flux (après un redémarrage).
                    if let saved = flows.settings(for: exporter).wanInterface, saved != 0, !indices.contains(saved) {
                        Text(FlowTrafficBridge.interfaceName(saved) + " (enregistrée)").tag(saved)
                    }
                }
                TextField("Débit descendant (Mb/s)", text: $down, prompt: Text("500"))
                TextField("Débit montant (Mb/s)", text: $up, prompt: Text("50"))
            }
            Text("Les débits du forfait Internet donnent la charge du lien. Sans eux, NetScope prend la vitesse du port lue par sFlow, si elle est connue.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    flows.update(exporter, FlowExporterSettings(name: trimmed.isEmpty ? nil : trimmed, wanInterface: wan == 0 ? nil : wan,
                                                                downMbps: Self.number(down), upMbps: Self.number(up)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            let current = flows.settings(for: exporter)
            name = current.name ?? ""
            wan = current.wanInterface ?? 0
            down = current.downMbps.map { String(format: "%g", $0) } ?? ""
            up = current.upMbps.map { String(format: "%g", $0) } ?? ""
        }
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite && $0 > 0 && $0 <= 1_000_000 ? $0 : nil }
    }
}

// MARK: - Export CSV

/// Lignes des tableaux de flux en CSV (séparateur « ; », comme TrafficStore.csv), dans l'ordre affiché.
enum FlowCSV {
    static func entries(_ rows: [FlowRow], multi: Bool) -> String {
        var lines = [(multi ? "Exportateur;" : "") + "Nom;Adresse;Débit (b/s);Envoyé (octets);Reçu (octets);Flux;Catégorie;Port de switch"]
        for row in rows {
            var fields: [String] = multi ? [row.entry.site] : []
            fields += [row.name, row.entry.ip?.description ?? "", String(Int(row.entry.bandwidth)),
                       String(row.entry.sentBytes), String(row.entry.receivedBytes), String(row.entry.sessions),
                       row.entry.category ?? "", row.location ?? ""]
            lines.append(fields.map(AnaCSV.quote).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func conversations(_ rows: [FlowConversationRow], multi: Bool) -> String {
        var lines = [(multi ? "Exportateur;" : "") + "Appareil;Adresse;Destination;Port;Protocole;Application;Envoyé (octets);Reçu (octets);Durée (s)"]
        for row in rows {
            let s = row.session
            var fields: [String] = multi ? [s.site] : []
            fields += [row.localName ?? "", s.source?.description ?? "", s.destination?.description ?? "",
                       s.destinationPort.map(String.init) ?? "", s.proto, s.application ?? "",
                       String(s.sentBytes), String(s.receivedBytes), s.duration.map(String.init) ?? ""]
            lines.append(fields.map(AnaCSV.quote).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

/// Bouton « Exporter CSV » d'un tableau de flux.
struct FlowCSVButton: View {
    let name: String
    let text: () -> String
    @State private var document: InvCSVDocument?
    @State private var exporting = false

    var body: some View {
        Button {
            document = InvCSVDocument(text: text())
            exporting = true
        } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .fixedSize()
            .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                          defaultFilename: "\(name)-\(InvFormat.day(Date())).csv") { _ in }
    }
}
