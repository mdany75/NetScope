import NetScopeCore
import SwiftUI

/// Une ligne du journal des alertes, avec ses clés de tri.
struct MonJournalLine: Identifiable {
    let alert: MonAlert
    /// Rang dans le journal (le plus récent d'abord) : tri par défaut.
    let order: Int
    /// Date de référence des durées (maintenant, figée en démonstration).
    let now: Date

    var id: UUID { alert.id }

    /// Durée de l'incident : jusqu'à la résolution, ou jusqu'à maintenant s'il est encore ouvert.
    var duration: TimeInterval? {
        guard alert.severity == .critical || alert.severity == .warning else { return nil }
        return (alert.resolvedAt ?? now).timeIntervalSince(alert.date)
    }

    /// « 2 h 04 », « 12 min (en cours) ».
    @MainActor var durationLabel: String {
        guard let duration else { return "—" }
        return MonStore.duration(duration) + (alert.isResolved ? "" : " (en cours)")
    }

    // MARK: Clés de tri

    var sortDate: Date { alert.date }
    var sortSeverity: Int {
        switch alert.severity {
        case .critical: return 0
        case .warning: return 1
        case .info: return 2
        case .success: return 3
        }
    }
    var sortProbe: String { alert.probeName }
    var sortMessage: String { alert.fullMessage }
    /// À accuser d'abord, puis accusées, puis résolues.
    var sortFollow: Int { alert.isAcknowledged ? (alert.isResolved ? 2 : 1) : 0 }
    var sortDuration: Double { duration ?? -1 }
    var sortResolvedAt: Date { alert.resolvedAt ?? .distantFuture }
    var sortResolution: String { alert.resolution ?? "" }
    var sortAcknowledgedBy: String { alert.acknowledgedBy ?? "" }
}

/// Panneau « Journal des alertes » : filtres, « Tout accuser réception », tableau standard (note 8).
struct MonJournalPanel: View {
    @ObservedObject private var store = MonStore.shared
    @State private var filter: MonJournalFilter = .all
    @StateObject private var table = StandardTableModel<MonJournalLine>(
        id: "surveillance.journal", columns: MonJournalPanel.columns, sortKeys: MonJournalPanel.sortKeys,
        defaultSort: "ordre")

    /// Ligne de deux lignes de texte (croquis : message sur deux lignes) ; au-delà de `maxRows`
    /// entrées, le tableau défile.
    static let rowHeight: CGFloat = 44
    static let maxRows = 8

    static let columns: [StandardColumn] = [
        StandardColumn(id: "horodatage", title: "Horodatage"),
        StandardColumn(id: "gravite", title: "Gravité"),
        StandardColumn(id: "sonde", title: "Sonde"),
        StandardColumn(id: "evenement", title: "Événement", isRequired: true),
        StandardColumn(id: "suivi", title: "Suivi"),
        StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
        StandardColumn(id: "resolueLe", title: "Résolue le", isDefaultVisible: false),
        StandardColumn(id: "resolution", title: "Résolution", isDefaultVisible: false),
        StandardColumn(id: "accusePar", title: "Accusé par", isDefaultVisible: false),
    ]

    /// « ordre » : ordre du journal (le plus récent d'abord), sans colonne.
    static let sortKeys: [String: KeyPathComparator<MonJournalLine>] = [
        "ordre": KeyPathComparator(\MonJournalLine.order),
        "horodatage": KeyPathComparator(\MonJournalLine.sortDate),
        "gravite": KeyPathComparator(\MonJournalLine.sortSeverity),
        "sonde": KeyPathComparator(\MonJournalLine.sortProbe),
        "evenement": KeyPathComparator(\MonJournalLine.sortMessage),
        "suivi": KeyPathComparator(\MonJournalLine.sortFollow),
        "duree": KeyPathComparator(\MonJournalLine.sortDuration),
        "resolueLe": KeyPathComparator(\MonJournalLine.sortResolvedAt),
        "resolution": KeyPathComparator(\MonJournalLine.sortResolution),
        "accusePar": KeyPathComparator(\MonJournalLine.sortAcknowledgedBy),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            let alerts = store.journal.filtered(filter)
            if alerts.isEmpty {
                Text(store.journal.alerts.isEmpty ? "Aucune alerte pour l’instant." : "Aucune entrée pour ce filtre.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                let now = store.now
                let rows = alerts.enumerated().map { MonJournalLine(alert: $1, order: $0, now: now) }
                    .sorted(using: table.sortOrder)
                MonJournalTable(rows: rows, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)
            }
        }
        .monPanel()
    }

    private var header: some View {
        HStack(spacing: 8) {
            MonHeading("Journal des alertes").padding(.trailing, 6)
            ForEach(MonJournalFilter.allCases, id: \.self) { item in
                MonFilterChip(title: item.label, count: store.journal.count(item), isOn: filter == item) { filter = item }
            }
            let unacknowledged = store.journal.unacknowledgedCount
            Text(unacknowledged > 0 ? MonText.plural(unacknowledged, "non accusée", "non accusées") : "Tout est accusé")
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            // Icône seule : l'en-tête du croquis est déjà plein (aussi au clic droit sur l'en-tête).
            StandardColumnsMenu(model: table, compact: true)
            Button { store.acknowledgeAll() } label: {
                Label("Tout accuser réception", systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(MonCompactButtonStyle(height: 30))
            .disabled(unacknowledged == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Tableau du journal des alertes.
private struct MonJournalTable: View {
    @ObservedObject private var store = MonStore.shared
    let rows: [MonJournalLine]
    @ObservedObject var table: StandardTableModel<MonJournalLine>

    /// Hauteur du contenu d'une cellule : deux lignes de texte.
    static let cellHeight: CGFloat = 36

    var body: some View {
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("HORODATAGE"), sortUsing: table.sort("horodatage")) { line in
                MonCellText(MonJournal.timestamp(line.alert.date, now: store.now), mono: true, size: 11)
                    .frame(height: Self.cellHeight)
            }
            .width(min: 120, ideal: 138)
            .customizationID("horodatage")

            TableColumn(StandardTableHeading("GRAVITÉ"), sortUsing: table.sort("gravite")) { line in
                RegPill(text: line.alert.severity.label, tone: MonText.tone(line.alert.severity))
            }
            .width(min: 56, ideal: 62)
            .customizationID("gravite")

            TableColumn(StandardTableHeading("SONDE"), sortUsing: table.sort("sonde")) { line in
                Text(line.alert.probeName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .frame(height: Self.cellHeight, alignment: .leading)
                    .help(line.alert.probeName)
            }
            .width(min: 80, ideal: 104)
            .customizationID("sonde")

            TableColumn(StandardTableHeading("ÉVÉNEMENT"), sortUsing: table.sort("evenement")) { line in
                Text(line.alert.fullMessage)
                    .font(Theme.small)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(height: Self.cellHeight, alignment: .leading)
                    .help(line.alert.fullMessage)
            }
            .width(min: 140, ideal: 192)
            .customizationID("evenement")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("SUIVI"), sortUsing: table.sort("suivi")) { line in
                MonJournalFollow(alert: line.alert)
            }
            .width(min: 120, ideal: 206)
            .customizationID("suivi")

            TableColumn(StandardTableHeading("DURÉE"), sortUsing: table.sort("duree")) { line in
                MonCellText(line.durationLabel, mono: true, dimmed: line.duration == nil)
            }
            .width(min: 70, ideal: 110)
            .customizationID("duree")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("RÉSOLUE LE"), sortUsing: table.sort("resolueLe")) { line in
                MonCellText(line.alert.resolvedAt.map { MonJournal.timestamp($0, now: store.now) } ?? "—", mono: true,
                            dimmed: line.alert.resolvedAt == nil)
            }
            .width(min: 100, ideal: 132)
            .customizationID("resolueLe")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("RÉSOLUTION"), sortUsing: table.sort("resolution")) { line in
                MonCellText(line.alert.resolution ?? "—", dimmed: line.alert.resolution == nil)
                    .help(line.alert.resolution ?? "")
            }
            .width(min: 100, ideal: 180)
            .customizationID("resolution")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("ACCUSÉ PAR"), sortUsing: table.sort("accusePar")) { line in
                MonCellText(line.alert.acknowledgedBy ?? "—", dimmed: line.alert.acknowledgedBy == nil)
            }
            .width(min: 70, ideal: 110)
            .customizationID("accusePar")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .textSelection(.enabled)
    }
}

/// Cellule « Suivi » : « Résolue », accusé de réception ou bouton « Accuser réception ».
private struct MonJournalFollow: View {
    @ObservedObject private var store = MonStore.shared
    let alert: MonAlert

    var body: some View {
        HStack(spacing: 6) {
            if alert.isResolved {
                RegPill(text: "Résolue", tone: .success)
            }
            if let date = alert.acknowledgedAt {
                let text = alert.acknowledgedBy.map { "Accusé par \($0) · \(ackTime(date))" } ?? "Aucune action requise"
                Text(text)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
            } else {
                Button("Accuser réception") { store.acknowledge(alert.id) }
                    .buttonStyle(MonCompactButtonStyle(height: 26))
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    /// « 11:49 », ou « hier 23:05 » si l'accusé date d'un autre jour.
    private func ackTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: store.now) { return MonJournal.clock(date, seconds: false) }
        return MonJournal.timestamp(date, now: store.now).lowercased().split(separator: " ").first.map(String.init)
            .map { "\($0) \(MonJournal.clock(date, seconds: false))" } ?? MonJournal.clock(date, seconds: false)
    }
}

/// Petit bouton secondaire (26 à 30 pt) du journal.
struct MonCompactButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.text : Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.panelMuted : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(configuration.isPressed ? Theme.borderStrong : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .fixedSize()
    }
}
