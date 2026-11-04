import NetScopeCore
import SwiftUI

/// Une ligne du journal des événements, avec ses clés de tri.
struct PingEventLine: Identifiable {
    let event: PingEvent
    /// Rang dans le journal (le plus récent d'abord) : tri par défaut.
    let order: Int

    var id: UUID { event.id }

    var sortDate: Date { event.date }
    var sortLevel: Int {
        switch event.level {
        case .coupure: return 0
        case .alerte: return 1
        case .retabli: return 2
        case .info: return 3
        }
    }
    var sortSubject: String { event.subject }
    var sortMessage: String { event.message }
}

/// Journal horodaté des événements : coupures, alertes, retours en ligne (tableau standard, note 8).
struct PingJournalPanel: View {
    @ObservedObject var controller: PingController
    var maxRows = 40
    @StateObject private var table = StandardTableModel<PingEventLine>(
        id: "ping.journal", columns: PingJournalPanel.columns, sortKeys: PingJournalPanel.sortKeys,
        defaultSort: "ordre")

    /// Ligne : étiquette et cible, puis le message sur deux lignes au plus (croquis) ; au-delà
    /// de `visibleRows` événements, le tableau défile.
    static let rowHeight: CGFloat = 62
    static let visibleRows = 12

    /// « Événement » reprend la disposition du croquis (étiquette, cible, message) ; le niveau,
    /// la cible et la date seuls sont des colonnes facultatives, pour trier ou comparer.
    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure"),
        StandardColumn(id: "evenement", title: "Événement", isRequired: true),
        StandardColumn(id: "niveau", title: "Niveau", isDefaultVisible: false),
        StandardColumn(id: "cible", title: "Cible", isDefaultVisible: false),
        StandardColumn(id: "date", title: "Date", isDefaultVisible: false),
    ]

    /// « ordre » : ordre du journal (le plus récent d'abord), sans colonne.
    static let sortKeys: [String: KeyPathComparator<PingEventLine>] = [
        "ordre": KeyPathComparator(\PingEventLine.order),
        "heure": KeyPathComparator(\PingEventLine.sortDate),
        "evenement": KeyPathComparator(\PingEventLine.sortMessage),
        "niveau": KeyPathComparator(\PingEventLine.sortLevel),
        "cible": KeyPathComparator(\PingEventLine.sortSubject),
        "date": KeyPathComparator(\PingEventLine.sortDate),
    ]

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    var body: some View {
        let events = controller.events
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Journal des événements").font(Theme.panelTitle).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                Text("\(events.count) \(events.count > 1 ? "événements" : "événement")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                // Icône seule : la colonne du journal est étroite (aussi au clic droit sur l'en-tête).
                StandardColumnsMenu(model: table, compact: true)
                Button("Effacer") { controller.clearEvents() }
                    .buttonStyle(PingSmallButtonStyle())
                    .disabled(events.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            HStack(spacing: 8) {
                counter("Coupures", events.filter { $0.level == .coupure }.count, Theme.critical)
                counter("Alertes", events.filter { $0.level == .alerte }.count, Theme.warning)
                counter("Rétablis", events.filter { $0.level == .retabli }.count, Theme.success)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if events.isEmpty {
                Text("Aucun événement depuis la réinitialisation. Les pertes, retours en ligne et pics de latence s’afficheront ici.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let rows = events.prefix(maxRows).enumerated().map { PingEventLine(event: $1, order: $0) }
                    .sorted(using: table.sortOrder)
                PingEventTable(rows: rows, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.visibleRows)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private func counter(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PingMiniLabel(text: title, size: 11)
            Text("\(count)").font(Theme.mono(15, weight: .semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tableau des événements.
private struct PingEventTable: View {
    let rows: [PingEventLine]
    @ObservedObject var table: StandardTableModel<PingEventLine>

    /// Hauteur du contenu d'une cellule : étiquette et cible, puis deux lignes de message.
    static let cellHeight: CGFloat = 54

    var body: some View {
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("HEURE"), sortUsing: table.sort("heure")) { line in
                Text(PingJournalPanel.timeFormatter.string(from: line.event.date))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: Self.cellHeight, alignment: .top)
                    .padding(.top, 2)
            }
            .width(min: 60, ideal: 64, max: 90)
            .customizationID("heure")

            TableColumn(StandardTableHeading("ÉVÉNEMENT"), sortUsing: table.sort("evenement")) { line in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        PingLevelTag(level: line.event.level)
                        Text(line.event.subject)
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    Text(line.event.message)
                        .font(Theme.small)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(line.event.message)
                }
                .frame(height: Self.cellHeight, alignment: .top)
            }
            .width(min: 160, ideal: 300)
            .customizationID("evenement")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("NIVEAU"), sortUsing: table.sort("niveau")) { line in
                PingLevelTag(level: line.event.level)
            }
            .width(min: 70, ideal: 76)
            .customizationID("niveau")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("CIBLE"), sortUsing: table.sort("cible")) { line in
                PingCell(line.event.subject, mono: true)
            }
            .width(min: 80, ideal: 104)
            .customizationID("cible")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("DATE"), sortUsing: table.sort("date")) { line in
                PingCell(PingJournalPanel.dateFormatter.string(from: line.event.date), color: Theme.textSecondary)
            }
            .width(min: 80, ideal: 96)
            .customizationID("date")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .textSelection(.enabled)
    }
}

/// Étiquette de niveau du croquis (« COUPURE » rouge, « ALERTE » orange, « RÉTABLI » vert).
struct PingLevelTag: View {
    let level: PingEvent.Level

    var body: some View {
        let colors: (Color, Color)
        switch level {
        case .coupure: colors = (Theme.criticalSoft, Theme.critical)
        case .alerte: colors = (Theme.warningSoft, Theme.warning)
        case .retabli: colors = (Theme.successSoft, Theme.success)
        case .info: colors = (Color(light: 0xDBEAFE, dark: 0x1B3250), Color(light: 0x1E40AF, dark: 0x93C5FD))
        }
        return Text(level.label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(colors.1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(colors.0))
            .fixedSize()
    }
}
