import NetScopeCore
import SwiftUI

// Tableaux de l'écran Trafic (note 54) : un tableau standard par vue FortiView (tri par débit,
// octets ou sessions, colonnes à choisir, retenues par tableau). Chaque source, menace ou session
// est reliée à son appareil : double-clic ou ↩︎ → fiche Appareil, « Ouvrir dans › » → port de
// switch, borne Wi-Fi, Inventaire, Analyse…

/// Ligne d'une vue FortiView, avec ce que NetScope sait de l'appareil.
struct TrafficRow: Identifiable {
    let entry: TrafficEntry
    /// Nom connu de NetScope (nom saisi, Scanner), sinon celui de FortiView.
    let name: String
    let ref: NavDeviceRef?
    /// « SW-ETG2-01 · 1/14 ».
    let location: String?
    let accessPoint: String?
    /// Capacité du lien (interfaces) et charge.
    let link: TrafficLink?

    var id: String { entry.id }

    var sortName: String { SearchText.fold(name) }
    var sortIP: UInt32 { entry.ip?.value ?? .max }
    var sortRate: Double { entry.bandwidth }
    var sortBytes: UInt64 { entry.bytes }
    var sortSent: UInt64 { entry.sentBytes }
    var sortReceived: UInt64 { entry.receivedBytes }
    var sortSessions: Int { entry.sessions }
    var sortIncidents: Int { entry.incidents }
    var sortBlocked: Int { entry.blocked }
    var sortCountry: String { entry.country.map(TrafficFormat.country) ?? "~" }
    var sortCategory: String { entry.category ?? "~" }
    var sortRisk: Int { entry.risk ?? 0 }
    var sortLevel: Int { -(entry.threatLevel?.rawValue ?? 9) }
    var sortLocation: String { location ?? "~" }
    var sortAP: String { accessPoint ?? "~" }
    var sortInterface: String { entry.interface ?? "~" }
    var sortPolicy: Int { entry.policyID ?? .max }
    var sortSite: String { entry.site }
    var sortLoad: Double { link?.utilization ?? -1 }
    var sortType: String { entry.threatType ?? "~" }
    var sortMAC: String { entry.mac?.description ?? "~" }

    static let sortKeys: [String: KeyPathComparator<TrafficRow>] = [
        "nom": KeyPathComparator(\.sortName), "ip": KeyPathComparator(\.sortIP),
        "debit": KeyPathComparator(\.sortRate, order: .reverse), "octets": KeyPathComparator(\.sortBytes, order: .reverse),
        "envoye": KeyPathComparator(\.sortSent, order: .reverse), "recu": KeyPathComparator(\.sortReceived, order: .reverse),
        "sessions": KeyPathComparator(\.sortSessions, order: .reverse), "evenements": KeyPathComparator(\.sortIncidents, order: .reverse),
        "bloques": KeyPathComparator(\.sortBlocked, order: .reverse), "pays": KeyPathComparator(\.sortCountry),
        "categorie": KeyPathComparator(\.sortCategory), "risque": KeyPathComparator(\.sortRisk, order: .reverse),
        "niveau": KeyPathComparator(\.sortLevel, order: .reverse), "port": KeyPathComparator(\.sortLocation),
        "borne": KeyPathComparator(\.sortAP), "interface": KeyPathComparator(\.sortInterface),
        "politique": KeyPathComparator(\.sortPolicy), "site": KeyPathComparator(\.sortSite),
        "charge": KeyPathComparator(\.sortLoad, order: .reverse), "type": KeyPathComparator(\.sortType),
        "mac": KeyPathComparator(\.sortMAC),
    ]

    /// Colonnes de chaque vue (identifiants stables, enregistrés).
    static func columns(_ view: TrafficView) -> [StandardColumn] {
        let site = StandardColumn.site
        switch view {
        case .sources:
            return [StandardColumn(id: "nom", title: "Appareil", isRequired: true), StandardColumn(id: "ip", title: "Adresse IP"),
                    StandardColumn(id: "debit", title: "Débit"), StandardColumn(id: "envoye", title: "Envoyé"),
                    StandardColumn(id: "recu", title: "Reçu"), StandardColumn(id: "sessions", title: "Sessions"),
                    StandardColumn(id: "port", title: "Port de switch"), StandardColumn(id: "borne", title: "Borne Wi-Fi"),
                    StandardColumn(id: "interface", title: "Interface", isDefaultVisible: false),
                    StandardColumn(id: "mac", title: "Adresse MAC", isDefaultVisible: false), site]
        case .destinations:
            return [StandardColumn(id: "nom", title: "Destination", isRequired: true), StandardColumn(id: "ip", title: "Adresse IP"),
                    StandardColumn(id: "pays", title: "Pays"), StandardColumn(id: "debit", title: "Débit"),
                    StandardColumn(id: "octets", title: "Octets"), StandardColumn(id: "sessions", title: "Sessions"), site]
        case .applications:
            return [StandardColumn(id: "nom", title: "Application", isRequired: true), StandardColumn(id: "categorie", title: "Catégorie"),
                    StandardColumn(id: "risque", title: "Risque"), StandardColumn(id: "debit", title: "Débit"),
                    StandardColumn(id: "octets", title: "Octets"), StandardColumn(id: "sessions", title: "Sessions"), site]
        case .webCategories:
            return [StandardColumn(id: "nom", title: "Catégorie web", isRequired: true), StandardColumn(id: "debit", title: "Débit"),
                    StandardColumn(id: "octets", title: "Octets"), StandardColumn(id: "sessions", title: "Sessions"),
                    StandardColumn(id: "bloques", title: "Requêtes bloquées"), site]
        case .interfaces:
            return [StandardColumn(id: "nom", title: "Interface", isRequired: true), StandardColumn(id: "charge", title: "Charge du lien"),
                    StandardColumn(id: "debit", title: "Débit"), StandardColumn(id: "octets", title: "Octets"),
                    StandardColumn(id: "sessions", title: "Sessions"), site]
        case .policies:
            return [StandardColumn(id: "politique", title: "N°", isRequired: true), StandardColumn(id: "nom", title: "Politique"),
                    StandardColumn(id: "debit", title: "Débit"), StandardColumn(id: "octets", title: "Octets"),
                    StandardColumn(id: "sessions", title: "Sessions"), site]
        case .threats:
            return [StandardColumn(id: "nom", title: "Menace", isRequired: true), StandardColumn(id: "type", title: "Type"),
                    StandardColumn(id: "niveau", title: "Niveau"), StandardColumn(id: "ip", title: "Appareil"),
                    StandardColumn(id: "evenements", title: "Événements"), StandardColumn(id: "bloques", title: "Action"),
                    StandardColumn(id: "pays", title: "Pays"), site]
        case .sessions:
            return []
        }
    }

    /// Clé de tri d'un critère du menu « Trier par ».
    static func sortColumn(_ sort: TrafficSort, view: TrafficView, period: TrafficPeriod) -> String {
        if view == .threats { return sort == .sessions ? "evenements" : "niveau" }
        switch sort {
        case .bandwidth: return period.isRealtime ? "debit" : (view == .sources ? "envoye" : "octets")
        case .bytes: return view == .sources ? "envoye" : "octets"
        case .sessions: return "sessions"
        }
    }

    static func defaultSort(_ view: TrafficView) -> String {
        view == .threats ? "niveau" : (view == .policies ? "octets" : "debit")
    }
}

/// Ligne du tableau des sessions.
struct TrafficSessionRow: Identifiable {
    let session: TrafficSession
    let sourceName: String
    let ref: NavDeviceRef?
    /// Fiche Appareil : deux listes réunies, dont les numéros d'ordre se répètent.
    var rowID: String? = nil
    var id: String { rowID ?? session.id }

    var sortSource: UInt32 { session.source?.value ?? .max }
    var sortDestination: UInt32 { session.destination?.value ?? .max }
    var sortPort: Int { session.destinationPort ?? .max }
    var sortProto: String { session.proto }
    var sortApp: String { session.application ?? "~" }
    var sortBytes: UInt64 { session.bytes }
    var sortDuration: Int { session.duration ?? -1 }
    var sortPolicy: Int { session.policyID ?? .max }
    var sortSite: String { session.site }
    var sortCountry: String { session.country.map(TrafficFormat.country) ?? "~" }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "source", title: "Source", isRequired: true), StandardColumn(id: "destination", title: "Destination"),
        StandardColumn(id: "port", title: "Port"), StandardColumn(id: "proto", title: "Protocole"),
        StandardColumn(id: "app", title: "Application"), StandardColumn(id: "octets", title: "Octets"),
        StandardColumn(id: "duree", title: "Durée"), StandardColumn(id: "politique", title: "Politique", isDefaultVisible: false),
        StandardColumn(id: "pays", title: "Pays", isDefaultVisible: false), StandardColumn.site,
    ]

    static let sortKeys: [String: KeyPathComparator<TrafficSessionRow>] = [
        "source": KeyPathComparator(\.sortSource), "destination": KeyPathComparator(\.sortDestination),
        "port": KeyPathComparator(\.sortPort), "proto": KeyPathComparator(\.sortProto), "app": KeyPathComparator(\.sortApp),
        "octets": KeyPathComparator(\.sortBytes, order: .reverse), "duree": KeyPathComparator(\.sortDuration, order: .reverse),
        "politique": KeyPathComparator(\.sortPolicy), "site": KeyPathComparator(\.sortSite), "pays": KeyPathComparator(\.sortCountry),
    ]
}

// MARK: - Tableau d'une vue FortiView

struct TrafficEntryTable<Tools: View>: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = TrafficStore.shared
    let view: TrafficView
    let rows: [TrafficRow]
    let multiSite: Bool
    /// Texte du tableau vide quand la période de l'écran Trafic ne s'applique pas (fiche Appareil).
    let emptyOverride: String?
    let tools: Tools
    @StateObject private var table: StandardTableModel<TrafficRow>
    @State private var selection: Set<String> = []

    init(view: TrafficView, rows: [TrafficRow], multiSite: Bool, emptyOverride: String? = nil, @ViewBuilder tools: () -> Tools) {
        self.view = view
        self.rows = rows
        self.multiSite = multiSite
        self.emptyOverride = emptyOverride
        self.tools = tools()
        _table = StateObject(wrappedValue: StandardTableModel(id: "trafic.\(view.rawValue)", columns: TrafficRow.columns(view),
                                                              sortKeys: TrafficRow.sortKeys, defaultSort: TrafficRow.defaultSort(view)))
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            TrafficTableBar(title: view.label, count: sorted.count) {
                tools
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 16, emptyText: emptyOverride ?? emptyText) {
                tableView(sorted)
                .standardRowActions(selection: sorted.map(\.id).filter(selection.contains), object: { id in
                    sorted.first { $0.id == id }?.ref.map { NavObject.device($0) }
                }) { ids in
                    if let row = sorted.first(where: { ids.contains($0.id) }) { menu(row) }
                }
            }
            .standardSiteColumn(table, multiple: multiSite)
        }
        .onAppear { applySort() }
        .onChange(of: store.sort) { _, _ in applySort() }
        // La colonne du tri dépend de la période (débit en temps réel, volume sur l'historique).
        .onChange(of: store.period) { _, _ in applySort() }
    }

    private var emptyText: String {
        switch view {
        case .threats: return "Aucune menace \(store.period.span)."
        default: return "Aucune donnée \(store.period.span)."
        }
    }

    private func applySort() {
        // Fiche Appareil : toujours en temps réel, quel que soit le réglage de l'écran Trafic.
        let live = emptyOverride != nil
        table.setSort(TrafficRow.sortColumn(live ? .bandwidth : store.sort, view: view, period: live ? .realtime : store.period), ascending: false)
    }

    @ViewBuilder private func menu(_ row: TrafficRow) -> some View {
        if let ip = row.entry.ip {
            Button("Copier l’adresse " + ip.description) { ToolActions.copy(ip.description) }
            Button("Ajouter au ping continu") { state.sendToPing(ip.description) }
        }
        if view == .sources, row.location != nil, let ref = row.ref {
            Button("Voir le port de switch") { state.showSwitchPort(switchName: ref.switchName, port: ref.switchPort) }
        }
        if view == .sources {
            Button("Qui sature le lien\u{00A0}?") { TrafficScreenState.shared.showSaturation = true }
        }
        Button("Copier la ligne") {
            ToolActions.copy([row.name, row.entry.ip?.description ?? "", TrafficFormat.rate(row.entry.bandwidth),
                              TrafficFormat.bytes(row.entry.bytes), "\(row.entry.sessions) sessions"].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    @ViewBuilder private func tableView(_ sorted: [TrafficRow]) -> some View {
        switch view {
        case .sources:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group { nameColumn; ipColumn; rateColumn; sentColumn; receivedColumn; sessionsColumn; portColumn; apColumn }
                Group { interfaceColumn; macColumn; siteColumn }
            }
        case .destinations:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; ipColumn; countryColumn; rateColumn; bytesColumn; sessionsColumn; siteColumn
            }
        case .applications:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; categoryColumn; riskColumn; rateColumn; bytesColumn; sessionsColumn; siteColumn
            }
        case .webCategories:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; rateColumn; bytesColumn; sessionsColumn; blockedColumn; siteColumn
            }
        case .interfaces:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; loadColumn; rateColumn; bytesColumn; sessionsColumn; siteColumn
            }
        case .policies:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; policyNameColumn; rateColumn; bytesColumn; sessionsColumn; siteColumn
            }
        case .threats, .sessions:
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                nameColumn; typeColumn; levelColumn; ipColumn; incidentsColumn; blockedColumn; countryColumn; siteColumn
            }
        }
    }

    private var nameColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn(nameTitle.uppercased(), sortUsing: table.sort(view == .policies ? "politique" : "nom")) { row in
            nameCell(row)
        }
        .width(min: 110, ideal: view == .threats ? 240 : 170)
        .customizationID(view == .policies ? "politique" : "nom")
        .disabledCustomizationBehavior(.visibility)
    }

    private var ipColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn(view == .threats ? "APPAREIL" : "ADRESSE IP", sortUsing: table.sort("ip")) { row in
            if view == .threats {
                ToolTableText(row.entry.ip.map { row.name == $0.description ? $0.description : "\(row.name) (\($0))" } ?? "Internet",
                              mono: false, color: row.entry.ip == nil ? Theme.textSecondary : Theme.text)
            } else {
                ToolTableText(row.entry.ip?.description ?? "—", color: Theme.textSecondary)
            }
        }
        .width(min: 90, ideal: view == .threats ? 220 : 104)
        .customizationID("ip")
    }

    private var countryColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("PAYS", sortUsing: table.sort("pays")) { row in
            ToolTableText(row.entry.country.map(TrafficFormat.country) ?? "—", mono: false, color: row.entry.country == nil ? Theme.textTertiary : Theme.text)
        }
        .width(min: 70, ideal: 120)
        .customizationID("pays")
    }

    private var categoryColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("CATÉGORIE", sortUsing: table.sort("categorie")) { row in
            ToolTableText(row.entry.category ?? "—", mono: false, color: Theme.textSecondary)
        }
        .width(min: 80, ideal: 130)
        .customizationID("categorie")
    }

    private var riskColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
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

    private var typeColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("TYPE", sortUsing: table.sort("type")) { row in
            ToolTableText(row.entry.threatType ?? "—", mono: false)
        }
        .width(min: 70, ideal: 110)
        .customizationID("type")
    }

    private var levelColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("NIVEAU", sortUsing: table.sort("niveau")) { row in
            let level = row.entry.threatLevel ?? .info
            Chip(text: level.label, tone: level <= .high ? .critical : (level == .medium ? .warning : .neutral))
        }
        .width(min: 64, ideal: 80)
        .customizationID("niveau")
    }

    private var loadColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("CHARGE DU LIEN", sortUsing: table.sort("charge")) { row in
            TrafficLoadCell(link: row.link)
        }
        .width(min: 100, ideal: 150)
        .customizationID("charge")
    }

    private var rateColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("DÉBIT", sortUsing: table.sort("debit")) { row in
            ToolTableText(TrafficFormat.rate(row.entry.bandwidth), alignment: .trailing)
        }
        .width(min: 64, ideal: 84)
        .customizationID("debit")
    }

    private var sentColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("ENVOYÉ", sortUsing: table.sort("envoye")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.sentBytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 82)
        .customizationID("envoye")
    }

    private var receivedColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("REÇU", sortUsing: table.sort("recu")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.receivedBytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 82)
        .customizationID("recu")
    }

    private var bytesColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("OCTETS", sortUsing: table.sort("octets")) { row in
            ToolTableText(TrafficFormat.bytes(row.entry.bytes), alignment: .trailing)
        }
        .width(min: 64, ideal: 86)
        .customizationID("octets")
    }

    private var sessionsColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("SESSIONS", sortUsing: table.sort("sessions")) { row in
            ToolTableText(ToolFormat.integer(row.entry.sessions), alignment: .trailing)
        }
        .width(min: 56, ideal: 70)
        .customizationID("sessions")
    }

    private var incidentsColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("ÉVÉNEMENTS", sortUsing: table.sort("evenements")) { row in
            ToolTableText(ToolFormat.integer(row.entry.incidents), alignment: .trailing)
        }
        .width(min: 60, ideal: 80)
        .customizationID("evenements")
    }

    private var blockedColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn(view == .threats ? "ACTION" : "REQUÊTES BLOQUÉES", sortUsing: table.sort("bloques")) { row in
            if view == .threats {
                Chip(text: row.entry.isBlocked ? "Bloquée" : "Non bloquée", tone: row.entry.isBlocked ? .success : .critical,
                     systemImage: row.entry.isBlocked ? "hand.raised.fill" : "exclamationmark.triangle.fill")
            } else if row.entry.blocked > 0 {
                Chip(text: "\(ToolFormat.integer(row.entry.blocked)) bloquée\(row.entry.blocked > 1 ? "s" : "")", tone: .warning)
            } else {
                ToolTableText("—", color: Theme.textTertiary, alignment: .trailing)
            }
        }
        .width(min: 80, ideal: 110)
        .customizationID("bloques")
    }

    private var portColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("PORT DE SWITCH", sortUsing: table.sort("port")) { row in
            ToolTableText(row.location ?? "—", color: row.location == nil ? Theme.textTertiary : Theme.text)
                .help(row.location.map { "Branché sur \($0) (double-clic\u{00A0}: fiche de l’appareil, clic droit\u{00A0}: Voir le port)" } ?? "")
        }
        .width(min: 90, ideal: 130)
        .customizationID("port")
    }

    private var apColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("BORNE WI-FI", sortUsing: table.sort("borne")) { row in
            ToolTableText(row.accessPoint ?? "—", mono: false, color: row.accessPoint == nil ? Theme.textTertiary : Theme.text)
        }
        .width(min: 70, ideal: 104)
        .customizationID("borne")
    }

    private var interfaceColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("INTERFACE", sortUsing: table.sort("interface")) { row in
            ToolTableText(row.entry.interface ?? "—", color: Theme.textSecondary)
        }
        .width(min: 60, ideal: 90)
        .customizationID("interface")
        .defaultVisibility(.hidden)
    }

    private var macColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("ADRESSE MAC", sortUsing: table.sort("mac")) { row in
            ToolTableText(row.entry.mac?.formatted(.upperColon) ?? "—", color: Theme.textSecondary)
        }
        .width(min: 120, ideal: 140)
        .customizationID("mac")
        .defaultVisibility(.hidden)
    }

    private var policyNameColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("POLITIQUE", sortUsing: table.sort("nom")) { row in
            ToolTableText(row.entry.name, mono: false)
        }
        .width(min: 120, ideal: 200)
        .customizationID("nom")
    }

    private var siteColumn: some TableColumnContent<TrafficRow, KeyPathComparator<TrafficRow>> {
        TableColumn("SITE", sortUsing: table.sort("site")) { row in
            ToolTableText(row.entry.site, mono: false, color: Theme.textSecondary)
        }
        .width(min: 70, ideal: 110)
        .customizationID("site")
        .defaultVisibility(.hidden)
    }

    private var nameTitle: String {
        switch view {
        case .sources: return "Appareil"
        case .destinations: return "Destination"
        case .applications: return "Application"
        case .webCategories: return "Catégorie web"
        case .interfaces: return "Interface"
        case .policies: return "N°"
        case .threats: return "Menace"
        case .sessions: return "Session"
        }
    }

    @ViewBuilder private func nameCell(_ row: TrafficRow) -> some View {
        switch view {
        case .policies:
            ToolTableText(row.entry.policyID.map(String.init) ?? "—", weight: .semibold)
        case .interfaces:
            HStack(spacing: 6) {
                ToolTableText(row.link?.label ?? row.entry.name, weight: .semibold)
                if row.link?.isWAN == true { Chip(text: "WAN", tone: .accent) }
            }
        case .sources:
            HStack(spacing: 5) {
                Image(systemName: row.ref?.switchName == nil && row.accessPoint == nil ? "questionmark.circle" : "desktopcomputer")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                ToolTableText(row.name, mono: false, weight: .semibold)
            }
            .help(row.ref == nil ? row.name : "\(row.name) · double-clic\u{00A0}: fiche de l’appareil")
        case .threats:
            ToolTableText(row.entry.name, mono: false, weight: .semibold).help(row.entry.name)
        default:
            ToolTableText(row.name, mono: view == .destinations && row.entry.hostname == nil, weight: .semibold)
                .help(row.name)
        }
    }
}

/// Barre au-dessus d'un tableau : titre, nombre, accessoires.
struct TrafficTableBar<Accessory: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            ToolFieldLabel("\(title) · \(count)")
            Spacer(minLength: 8)
            accessory
        }
    }
}

/// Charge d'un lien : barre et pourcentage.
struct TrafficLoadCell: View {
    let link: TrafficLink?

    var body: some View {
        if let link, let percent = link.utilization {
            HStack(spacing: 6) {
                ProgressBar(fraction: percent / 100, color: TrafficStyle.color(percent: percent))
                    .frame(width: 60)
                Text(ResourceFormat.percent(percent)).font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(TrafficStyle.color(percent: percent, text: true))
                    .fixedSize()
            }
            .help(TrafficStyle.capacityLabel(link))
        } else {
            ToolTableText(link == nil ? "—" : "capacité inconnue", mono: false, color: Theme.textTertiary)
        }
    }
}

@MainActor
enum TrafficStyle {
    static func color(percent: Double, text: Bool = false) -> Color {
        let t = TrafficStore.shared.thresholds
        if percent >= t.linkCriticalPercent { return Theme.critical }
        if percent >= t.linkWarningPercent { return Theme.warning }
        return text ? Theme.text : Theme.accent
    }

    /// « ↓ 500 Mb/s · ↑ 50 Mb/s (débits déclarés) ».
    static func capacityLabel(_ link: TrafficLink) -> String {
        let declared = link.downstreamKbps != nil || link.upstreamKbps != nil
        let down = link.downCapacity.map(ResourceFormat.bitsPerSecond) ?? "?"
        let up = link.upCapacity.map(ResourceFormat.bitsPerSecond) ?? "?"
        return "Capacité\u{00A0}: ↓\u{00A0}\(down) · ↑\u{00A0}\(up) (" + (declared ? "débits déclarés sur la FortiGate" : "vitesse du port") + ")"
    }
}

// MARK: - Sessions

struct TrafficSessionTable<Tools: View>: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = TrafficStore.shared
    let rows: [TrafficSessionRow]
    let multiSite: Bool
    /// Texte du tableau vide quand la période de l'écran Trafic ne s'applique pas (fiche Appareil).
    var emptyOverride: String? = nil
    @ViewBuilder let tools: () -> Tools
    @StateObject private var table = StandardTableModel<TrafficSessionRow>(id: "trafic.sessions", columns: TrafficSessionRow.columns,
                                                                           sortKeys: TrafficSessionRow.sortKeys, defaultSort: "octets")
    @State private var selection: Set<String> = []

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            TrafficTableBar(title: "Sessions en cours", count: sorted.count) {
                tools()
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 16,
                                   emptyText: emptyOverride ?? (store.period.isRealtime ? "Aucune session lue." : "Sessions\u{00A0}: seulement en temps réel.")) {
                Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    Group {
                        TableColumn("SOURCE", sortUsing: table.sort("source")) { row in
                            ToolTableText(row.session.source.map { ip in row.sourceName == ip.description ? ip.description : "\(row.sourceName) (\(ip))" } ?? "—",
                                          mono: false, weight: .semibold)
                        }
                        .width(min: 120, ideal: 220)
                        .customizationID("source").disabledCustomizationBehavior(.visibility)
                        TableColumn("DESTINATION", sortUsing: table.sort("destination")) { row in
                            ToolTableText(row.session.destination?.description ?? "—")
                        }
                        .width(min: 90, ideal: 120).customizationID("destination")
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
                        .width(min: 90, ideal: 170).customizationID("app")
                    }
                    Group {
                        TableColumn("OCTETS", sortUsing: table.sort("octets")) { row in
                            ToolTableText(TrafficFormat.bytes(row.session.bytes), alignment: .trailing)
                                .help("Envoyé\u{00A0}: \(TrafficFormat.bytes(row.session.sentBytes)) · reçu\u{00A0}: \(TrafficFormat.bytes(row.session.receivedBytes))")
                        }
                        .width(min: 64, ideal: 86).customizationID("octets")
                        TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                            ToolTableText(TrafficFormat.duration(row.session.duration), alignment: .trailing)
                        }
                        .width(min: 56, ideal: 80).customizationID("duree")
                        TableColumn("POLITIQUE", sortUsing: table.sort("politique")) { row in
                            ToolTableText(row.session.policyID.map(String.init) ?? "—", alignment: .trailing)
                        }
                        .width(min: 50, ideal: 64).customizationID("politique").defaultVisibility(.hidden)
                        TableColumn("PAYS", sortUsing: table.sort("pays")) { row in
                            ToolTableText(row.session.country.map(TrafficFormat.country) ?? "—", mono: false)
                        }
                        .width(min: 60, ideal: 110).customizationID("pays").defaultVisibility(.hidden)
                        TableColumn("SITE", sortUsing: table.sort("site")) { row in
                            ToolTableText(row.session.site, mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 70, ideal: 110).customizationID("site").defaultVisibility(.hidden)
                    }
                }
                .standardRowActions(selection: sorted.map(\.id).filter(selection.contains), object: { id in
                    sorted.first { $0.id == id }?.ref.map { NavObject.device($0) }
                }) { ids in
                    if let row = sorted.first(where: { ids.contains($0.id) }) {
                        if let destination = row.session.destination {
                            Button("Copier la destination " + destination.description) { ToolActions.copy(destination.description) }
                            Button("Ajouter la destination au ping continu") { state.sendToPing(destination.description) }
                        }
                    }
                }
            }
            .standardSiteColumn(table, multiple: multiSite)
        }
    }
}
