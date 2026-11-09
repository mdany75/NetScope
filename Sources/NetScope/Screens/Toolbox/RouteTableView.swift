import NetScopeCore
import SwiftUI

/// Table de routage (note 119) : consultation seule des routes IPv4 et IPv6 de ce Mac.
struct RouteTableView: View {
    @ObservedObject var model: RouteTableModel
    @StateObject private var table = RouteListTable.makeModel()
    @State private var selection = Set<Int>()

    var body: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            ToolCellGrid(cells: RouteFamily.allCases.map(defaultCell), columns: 2, valueSize: 13, minCellWidth: 240, truncatesLongValues: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filters
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    filters
                    actions
                }
            }
            RouteListTable(rows: rows, table: table, selection: $selection,
                        emptyText: model.readDate != nil ? "Aucune route ne correspond au filtre." : model.isReading ? "Lecture de la table…" : "Table non lue.")
            Text(footer(shown: rows.count))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.readIfNeeded() }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Famille", selection: $model.family) {
                Text("Toutes").tag(RouteFamily?.none)
                ForEach(RouteFamily.allCases, id: \.self) { family in
                    Text(family.rawValue).tag(RouteFamily?.some(family))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            ToolTextField(placeholder: "Destination, passerelle, interface…", text: $model.query, mono: false)
                .frame(minWidth: 160, idealWidth: 260, maxWidth: 320)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { selection = []; model.read() } label: { Label("Relire", systemImage: "arrow.clockwise") }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .fixedSize()
                .disabled(model.isReading)
            ToolColumnsMenu(model: table)
        }
    }

    private var visibleRows: [RouteRow] {
        model.entries.enumerated()
            .filter { (model.family == nil || $0.element.family == model.family) && $0.element.matches(model.query) }
            .map { RouteRow(index: $0.offset, entry: $0.element) }
    }

    private func defaultCell(_ family: RouteFamily) -> ToolCell {
        let key = "Route par défaut \(family.rawValue)"
        guard model.readDate != nil else {
            return ToolCell(key: key, value: "—", detail: model.isReading ? "Lecture de la table…" : "Table non lue")
        }
        guard let route = model.mainDefault(family) else {
            return ToolCell(key: key, value: "Aucune", detail: "Pas de sortie \(family.rawValue) hors des réseaux directs")
        }
        let others = model.defaultCount(family) - 1
        let suffix = others > 0 ? " · +\(others) liée\(others > 1 ? "s" : "") à une interface" : ""
        return ToolCell(key: key, value: route.gateway.text, detail: "Interface \(route.interface)" + suffix)
    }

    private func footer(shown: Int) -> String {
        let readOnly = "Consultation seule de la table de ce Mac\u{00A0}: rien n’est envoyé ni modifié."
        guard let readDate = model.readDate else { return readOnly }
        let total = model.entries.count
        let count = shown == total ? "\(total)\u{00A0}route\(total > 1 ? "s" : "")" : "\(shown) sur \(total)\u{00A0}routes"
        return "\(count) · lue à \(ToolText.time(readDate)) · \(readOnly)"
    }
}

// MARK: - Tableau

struct RouteRow: Identifiable {
    let index: Int
    let entry: RouteEntry

    var id: Int { index }
    var gatewayText: String { entry.gateway.text }
    var expirySort: Int {
        switch entry.expiry {
        case let .seconds(seconds)?: return seconds
        case .elapsed?: return 0
        case nil: return .max
        }
    }
    var expiryText: String {
        switch entry.expiry {
        case let .seconds(seconds)?: return "\(seconds)\u{00A0}s"
        case .elapsed?: return "écoulée"
        case nil: return "—"
        }
    }
}

/// Routes (tableau standard « outils.routes ») ; les routes par défaut restent en tête quel que
/// soit le tri.
struct RouteListTable: View {
    let rows: [RouteRow]
    @ObservedObject var table: StandardTableModel<RouteRow>
    @Binding var selection: Set<Int>
    let emptyText: String

    static let columns: [StandardColumn] = [
        StandardColumn(id: "destination", title: "Destination", isRequired: true),
        StandardColumn(id: "passerelle", title: "Passerelle"),
        StandardColumn(id: "interface", title: "Interface"),
        StandardColumn(id: "drapeaux", title: "Drapeaux"),
        StandardColumn(id: "portee", title: "Portée", isDefaultVisible: false),
        StandardColumn(id: "bruts", title: "Lettres", isDefaultVisible: false),
        StandardColumn(id: "famille", title: "Famille", isDefaultVisible: false),
        StandardColumn(id: "expiration", title: "Expiration", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RouteRow>] = [
        "destination": KeyPathComparator(\RouteRow.entry.sortKey),
        "passerelle": KeyPathComparator(\RouteRow.gatewayText),
        "interface": KeyPathComparator(\RouteRow.entry.interface),
        "drapeaux": KeyPathComparator(\RouteRow.entry.flagsText),
        "portee": KeyPathComparator(\RouteRow.entry.scope.rawValue),
        "bruts": KeyPathComparator(\RouteRow.entry.rawFlags),
        "famille": KeyPathComparator(\RouteRow.entry.family.rawValue),
        "expiration": KeyPathComparator(\RouteRow.expirySort),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RouteRow> {
        StandardTableModel(id: "outils.routes", columns: columns, sortKeys: sortKeys, defaultSort: "destination")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        let ordered = sorted.filter(\.entry.isDefault) + sorted.filter { !$0.entry.isDefault }
        ToolStandardTableFrame(rowCount: ordered.count, emptyText: emptyText) {
            Table(ordered, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("DESTINATION", sortUsing: table.sort("destination")) { row in
                    HStack(spacing: 6) {
                        ToolTableText(row.entry.destinationText, weight: row.entry.isDefault ? .semibold : .regular,
                                      color: row.entry.isDefault ? Theme.accentStrong : Theme.text)
                            .help(row.entry.destinationText)
                        if row.entry.isDefault {
                            Chip(text: row.entry.isPrimaryDefault ? "Par défaut" : "Par interface", tone: row.entry.isPrimaryDefault ? .accent : .neutral)
                        }
                    }
                }
                .width(min: 150, ideal: 190)
                .customizationID("destination")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("PASSERELLE", sortUsing: table.sort("passerelle")) { row in
                    ToolTableText(row.gatewayText, weight: row.entry.isDefault ? .semibold : .regular).help(row.gatewayText)
                }
                .width(min: 110, ideal: 140)
                .customizationID("passerelle")

                TableColumn("INTERFACE", sortUsing: table.sort("interface")) { row in
                    ToolTableText(row.entry.interface)
                }
                .width(min: 72, ideal: 78, max: 110)
                .customizationID("interface")

                TableColumn("DRAPEAUX", sortUsing: table.sort("drapeaux")) { row in
                    ToolTableText(row.entry.flagsText, mono: false, color: Theme.textSecondary)
                        .help("\(row.entry.rawFlags)\u{00A0}: \(row.entry.flagsText)")
                }
                .width(min: 120, ideal: 180)
                .customizationID("drapeaux")

                TableColumn("PORTÉE", sortUsing: table.sort("portee")) { row in
                    ToolTableText(row.entry.scope.rawValue, mono: false, color: Theme.textSecondary)
                }
                .width(min: 62, ideal: 66, max: 100)
                .customizationID("portee")
                .defaultVisibility(.hidden)

                TableColumn("LETTRES", sortUsing: table.sort("bruts")) { row in
                    ToolTableText(row.entry.rawFlags, color: Theme.textSecondary)
                }
                .width(min: 60, ideal: 76)
                .customizationID("bruts")
                .defaultVisibility(.hidden)

                TableColumn("FAMILLE", sortUsing: table.sort("famille")) { row in
                    ToolTableText(row.entry.family.rawValue, mono: false, color: Theme.textSecondary)
                }
                .width(min: 50, ideal: 60)
                .customizationID("famille")
                .defaultVisibility(.hidden)

                TableColumn("EXPIRATION", sortUsing: table.sort("expiration")) { row in
                    ToolTableText(row.expiryText, mono: false, color: Theme.textSecondary)
                        .help(row.entry.expiry == .elapsed ? "Délai écoulé («\u{00A0}!\u{00A0}» de netstat)" : "")
                }
                .width(min: 66, ideal: 80)
                .customizationID("expiration")
                .defaultVisibility(.hidden)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Copier") {
                    ToolActions.copy(ordered.filter { ids.contains($0.index) }
                        .map { "\($0.entry.destinationText)\t\($0.gatewayText)\t\($0.entry.interface)\t\($0.entry.flagsText)" }
                        .joined(separator: "\n"))
                }
                .disabled(ids.isEmpty)
            }
        }
    }
}
