import NetScopeCore
import SwiftUI

// Note 6 (suite, 0.26.2) : tableaux standard du tableau de bord du serveur RustDesk —
// sessions relayées en cours (console de hbbr, « u ») et demandes de connexion récentes (console
// de hbbs, « pr »), avec le nom du poste quand son ID est dans le carnet.

// MARK: - Sessions relayées

struct RustDeskRelayRow: Identifiable, Hashable {
    let id: String
    let address: String
    let ip: String
    /// Poste du carnet (demande « pr » récente vers son ID, sur la même adresse) ; vide : inconnu.
    let station: String
    let targetID: String
    let seconds: Int
    let megabytes: Double
    let currentKbps: Int
    let averageKbps: Int
    let maxKbps: Int

    var stationSort: String { station.isEmpty ? "\u{10FFFF}" + targetID : station.lowercased() }

    static func rows(_ status: RustDeskServerStatus, book: [String: String]) -> [RustDeskRelayRow] {
        status.relaySessions.map { session in
            let request = RustDeskServerCorrelation.request(for: session, in: status.punchRequests, now: status.now)
            let id = request?.targetID ?? ""
            return RustDeskRelayRow(id: session.id, address: session.address, ip: session.ip,
                                    station: RustDeskServerCorrelation.name(of: id, book: book) ?? "", targetID: id,
                                    seconds: session.seconds, megabytes: session.megabytes, currentKbps: session.currentKbps,
                                    averageKbps: session.averageKbps, maxKbps: session.maxKbps)
        }
    }
}

enum RustDeskRelayColumns {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "adresse", title: "Adresse", isRequired: true),
        StandardColumn(id: "poste", title: "Poste"),
        StandardColumn(id: "duree", title: "Durée"),
        StandardColumn(id: "volume", title: "Volume"),
        StandardColumn(id: "actuel", title: "Débit actuel"),
        StandardColumn(id: "moyen", title: "Débit moyen"),
        StandardColumn(id: "max", title: "Débit max"),
    ]
    static let sortKeys: [String: KeyPathComparator<RustDeskRelayRow>] = [
        "adresse": KeyPathComparator(\RustDeskRelayRow.address),
        "poste": KeyPathComparator(\RustDeskRelayRow.stationSort),
        "duree": KeyPathComparator(\RustDeskRelayRow.seconds),
        "volume": KeyPathComparator(\RustDeskRelayRow.megabytes),
        "actuel": KeyPathComparator(\RustDeskRelayRow.currentKbps),
        "moyen": KeyPathComparator(\RustDeskRelayRow.averageKbps),
        "max": KeyPathComparator(\RustDeskRelayRow.maxKbps),
    ]
    static let widths: [String: CGFloat] = ["adresse": 150, "poste": 150, "duree": 70, "volume": 70, "actuel": 90, "moyen": 90, "max": 90]
}

struct RustDeskRelayTable: View {
    let rows: [RustDeskRelayRow]
    @StateObject private var table = StandardTableModel<RustDeskRelayRow>(
        id: "rustdesk-serveur-sessions", columns: RustDeskRelayColumns.columns, sortKeys: RustDeskRelayColumns.sortKeys,
        defaultSort: "duree", defaultAscending: false)
    @State private var selection: String?

    static let rowHeight: CGFloat = 28

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Sessions relayées en cours", subtitle: "\(rows.count)") {
                StandardColumnsMenu(model: table, compact: true)
            }
            if rows.isEmpty {
                Text("Aucune session ne passe par le relais en ce moment.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 6)
            } else {
                StandardTableHorizontalScroll(minWidth: table.contentWidth(RustDeskRelayColumns.widths),
                                              height: StandardTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight, maxRows: 8)) {
                    Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                        TableColumn(StandardTableHeading("ADRESSE"), sortUsing: table.sort("adresse")) { row in
                            Text(row.address).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                                .help("Un des deux bouts de la session (celui qui a rejoint le relais en second)")
                        }
                        .width(min: 120, ideal: RustDeskRelayColumns.widths["adresse"])
                        .customizationID("adresse").disabledCustomizationBehavior(.visibility)
                        TableColumn(StandardTableHeading("POSTE"), sortUsing: table.sort("poste")) { row in
                            stationCell(row)
                        }
                        .width(min: 90, ideal: RustDeskRelayColumns.widths["poste"])
                        .customizationID("poste")
                        TableColumn(StandardTableHeading("DURÉE"), sortUsing: table.sort("duree")) { row in
                            Text(RustDeskServerFormat.duration(row.seconds)).font(Theme.mono(12)).lineLimit(1)
                        }
                        .width(min: 56, ideal: RustDeskRelayColumns.widths["duree"])
                        .customizationID("duree")
                        TableColumn(StandardTableHeading("VOLUME"), sortUsing: table.sort("volume")) { row in
                            Text(RustDeskServerFormat.megabytes(row.megabytes)).font(Theme.mono(12)).lineLimit(1)
                        }
                        .width(min: 56, ideal: RustDeskRelayColumns.widths["volume"])
                        .customizationID("volume")
                        TableColumn(StandardTableHeading("ACTUEL"), sortUsing: table.sort("actuel")) { row in
                            Text(RustDeskServerFormat.kbps(row.currentKbps)).font(Theme.mono(12, weight: .semibold)).lineLimit(1)
                        }
                        .width(min: 70, ideal: RustDeskRelayColumns.widths["actuel"])
                        .customizationID("actuel")
                        TableColumn(StandardTableHeading("MOYEN"), sortUsing: table.sort("moyen")) { row in
                            Text(RustDeskServerFormat.kbps(row.averageKbps)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .width(min: 70, ideal: RustDeskRelayColumns.widths["moyen"])
                        .customizationID("moyen")
                        TableColumn(StandardTableHeading("MAX"), sortUsing: table.sort("max")) { row in
                            Text(RustDeskServerFormat.kbps(row.maxKbps)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .width(min: 70, ideal: RustDeskRelayColumns.widths["max"])
                        .customizationID("max")
                    }
                    .standardTableStyle()
                    .scrollDisabled(rows.count <= 8)
                }
            }
        }
    }

    @ViewBuilder private func stationCell(_ row: RustDeskRelayRow) -> some View {
        if !row.station.isEmpty {
            Text(row.station).font(.system(size: 12, weight: .medium)).lineLimit(1)
        } else if !row.targetID.isEmpty {
            Text(RustDeskID.grouped(row.targetID)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .help("ID absent du carnet")
        } else {
            Text("Inconnu").font(Theme.small).foregroundStyle(Theme.textTertiary)
                .help("Aucune demande de connexion récente sur cette adresse")
        }
    }
}

// MARK: - Demandes de connexion

struct RustDeskRequestRow: Identifiable, Hashable {
    let id: Int
    let date: Date
    let fromIP: String
    let targetID: String
    let station: String
    let targetIP: String
    let relayed: Bool

    var stationSort: String { station.isEmpty ? "\u{10FFFF}" + targetID : station.lowercased() }
    var modeSort: Int { relayed ? 0 : 1 }

    /// Heure locale courte : « 14:25 » aujourd'hui, « hier 21:10 », « 3 nov. 09:10 ».
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = RemoteFormat.time(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier " + time
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_CA")
        day.dateFormat = "d MMM"
        return day.string(from: date) + " " + time
    }

    static func rows(_ status: RustDeskServerStatus, book: [String: String]) -> [RustDeskRequestRow] {
        let relayed = RustDeskServerCorrelation.relayedRequestIDs(sessions: status.relaySessions, requests: status.punchRequests, now: status.now)
        return status.punchRequests.map { request in
            RustDeskRequestRow(id: request.id, date: request.date, fromIP: request.fromIP, targetID: request.targetID,
                               station: RustDeskServerCorrelation.name(of: request.targetID, book: book) ?? "",
                               targetIP: request.targetIP, relayed: relayed.contains(request.id))
        }
    }
}

enum RustDeskRequestColumns {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "technicien", title: "IP du technicien"),
        StandardColumn(id: "id", title: "ID visé"),
        StandardColumn(id: "poste", title: "Poste"),
        StandardColumn(id: "ipPoste", title: "IP du poste"),
        StandardColumn(id: "mode", title: "Relais"),
    ]
    static let sortKeys: [String: KeyPathComparator<RustDeskRequestRow>] = [
        "heure": KeyPathComparator(\RustDeskRequestRow.date),
        "technicien": KeyPathComparator(\RustDeskRequestRow.fromIP),
        "id": KeyPathComparator(\RustDeskRequestRow.targetID),
        "poste": KeyPathComparator(\RustDeskRequestRow.stationSort),
        "ipPoste": KeyPathComparator(\RustDeskRequestRow.targetIP),
        "mode": KeyPathComparator(\RustDeskRequestRow.modeSort),
    ]
    static let widths: [String: CGFloat] = ["heure": 100, "technicien": 120, "id": 110, "poste": 140, "ipPoste": 120, "mode": 70]
}

struct RustDeskRequestTable: View {
    let rows: [RustDeskRequestRow]
    /// Liste lue tronquée (plus de demandes chez hbbs que les 500 lues).
    let total: Int
    @StateObject private var table = StandardTableModel<RustDeskRequestRow>(
        id: "rustdesk-serveur-demandes", columns: RustDeskRequestColumns.columns, sortKeys: RustDeskRequestColumns.sortKeys,
        defaultSort: "heure", defaultAscending: false)
    @State private var selection: Int?

    static let rowHeight: CGFloat = 28
    static let maxRows = 9

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Demandes de connexion récentes",
                          subtitle: total > rows.count ? "\(rows.count) plus récentes sur \(total)" : "\(rows.count)") {
                StandardColumnsMenu(model: table, compact: true)
            }
            if rows.isEmpty {
                Text("Aucune demande depuis le dernier démarrage de hbbs.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 6)
            } else {
                StandardTableHorizontalScroll(minWidth: table.contentWidth(RustDeskRequestColumns.widths),
                                              height: StandardTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)) {
                    Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                        TableColumn(StandardTableHeading("HEURE"), sortUsing: table.sort("heure")) { row in
                            Text(RustDeskRequestRow.moment(row.date)).font(Theme.mono(12)).lineLimit(1)
                                .help(RemoteFormat.relative(row.date))
                        }
                        .width(min: 96, ideal: RustDeskRequestColumns.widths["heure"])
                        .customizationID("heure").disabledCustomizationBehavior(.visibility)
                        TableColumn(StandardTableHeading("IP DU TECHNICIEN"), sortUsing: table.sort("technicien")) { row in
                            Text(row.fromIP).font(Theme.mono(12)).lineLimit(1)
                        }
                        .width(min: 90, ideal: RustDeskRequestColumns.widths["technicien"])
                        .customizationID("technicien")
                        TableColumn(StandardTableHeading("ID VISÉ"), sortUsing: table.sort("id")) { row in
                            Text(RustDeskID.parse(row.targetID).map { RustDeskID.grouped($0) } ?? row.targetID)
                                .font(Theme.mono(12)).lineLimit(1)
                        }
                        .width(min: 90, ideal: RustDeskRequestColumns.widths["id"])
                        .customizationID("id")
                        TableColumn(StandardTableHeading("POSTE"), sortUsing: table.sort("poste")) { row in
                            if row.station.isEmpty {
                                Text("Hors carnet").font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            } else {
                                Text(row.station).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                        }
                        .width(min: 90, ideal: RustDeskRequestColumns.widths["poste"])
                        .customizationID("poste")
                        TableColumn(StandardTableHeading("IP DU POSTE"), sortUsing: table.sort("ipPoste")) { row in
                            Text(row.targetIP).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .width(min: 90, ideal: RustDeskRequestColumns.widths["ipPoste"])
                        .customizationID("ipPoste")
                        TableColumn(StandardTableHeading("RELAIS"), sortUsing: table.sort("mode")) { row in
                            if row.relayed {
                                Chip(text: "relais", tone: .accent)
                            } else {
                                Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
                                    .help("Session directe, terminée, ou demande sans suite")
                            }
                        }
                        .width(min: 56, ideal: RustDeskRequestColumns.widths["mode"])
                        .customizationID("mode")
                    }
                    .standardTableStyle()
                    .scrollDisabled(rows.count <= Self.maxRows)
                }
            }
        }
    }
}
