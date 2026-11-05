import NetScopeCore
import SwiftUI

// Tableau standard des journaux (note 43) : heure, appareil, site, source, gravité, message,
// répétitions ; colonnes facultatives adresse IP, programme et événement. Double-clic ou ↩︎ :
// fiche de l'appareil (note 34) ; menu contextuel : « Comprendre une coupure » à cette heure,
// copier, « Ouvrir dans › ».

struct LogTable: View {
    @EnvironmentObject private var state: AppState
    let rows: [LogRow]
    let grouped: Bool
    let multiSite: Bool
    @ObservedObject var table: StandardTableModel<LogRow>
    @Binding var selection: Set<UUID>
    let outage: (Date) -> Void

    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "appareil", title: "Appareil"),
        StandardColumn.site,
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "gravite", title: "Gravité"),
        StandardColumn(id: "message", title: "Message"),
        StandardColumn(id: "nombre", title: "Fois (répétitions)"),
        StandardColumn(id: "ip", title: "Adresse IP", isDefaultVisible: false),
        StandardColumn(id: "app", title: "Programme", isDefaultVisible: false),
        StandardColumn(id: "evenement", title: "Événement", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<LogRow>] = [
        "heure": KeyPathComparator(\.sortDate, order: .reverse), "appareil": KeyPathComparator(\.sortName),
        "site": KeyPathComparator(\.sortSite), "source": KeyPathComparator(\.sortSource),
        "gravite": KeyPathComparator(\.sortSeverity), "message": KeyPathComparator(\.sortMessage),
        "nombre": KeyPathComparator(\.sortCount, order: .reverse), "ip": KeyPathComparator(\.sortIP),
        "app": KeyPathComparator(\.sortApp), "evenement": KeyPathComparator(\.sortEvent),
    ]

    @MainActor static func makeModel() -> StandardTableModel<LogRow> {
        StandardTableModel(id: "journaux", columns: columns, sortKeys: sortKeys, defaultSort: "heure", defaultAscending: false)
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Messages")
                Text("· " + LogFormat.count(sorted.count, grouped ? "ligne" : "message", grouped ? "lignes" : "messages"))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: sorted.count, maxRows: 18, emptyText: "Aucun message pour ces critères.") {
                Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    Group {
                        TableColumn("Heure", sortUsing: table.sort("heure")) { row in
                            ToolTableText(LogTable.timeText(row.message.date, now: LogStore.shared.now), size: 11.5)
                                .help(LogFormat.dayTime(row.message.date) + (row.count > 1 ? " · première fois \(LogFormat.dayTime(row.firstDate))" : ""))
                        }
                        .width(min: 62, ideal: 70, max: 130)
                        .customizationID("heure").disabledCustomizationBehavior(.visibility)
                        TableColumn("Appareil", sortUsing: table.sort("appareil")) { row in
                            ToolTableText(row.name, mono: false, weight: .medium)
                                .help(row.name == row.message.host ? row.message.host : "\(row.name) · \(row.message.host)")
                        }
                        .width(min: 80, ideal: 110)
                        .customizationID("appareil")
                        TableColumn("Site", sortUsing: table.sort("site")) { row in
                            ToolTableText(row.message.siteName, mono: false)
                        }
                        .width(min: 70, ideal: 110)
                        .customizationID("site").defaultVisibility(.hidden)
                        TableColumn("Source", sortUsing: table.sort("source")) { row in
                            LogSourceChip(source: row.message.source)
                        }
                        .width(min: 58, ideal: 68, max: 110)
                        .customizationID("source")
                        TableColumn("Gravité", sortUsing: table.sort("gravite")) { row in
                            LogSeverityChip(severity: row.message.severity)
                        }
                        .width(min: 74, ideal: 96, max: 130)
                        .customizationID("gravite")
                    }
                    Group {
                        TableColumn("Message", sortUsing: table.sort("message")) { row in
                            ToolTableText(row.message.message, mono: false)
                                .help(row.message.message)
                        }
                        .width(min: 140, ideal: 220)
                        .customizationID("message")
                        TableColumn("Fois", sortUsing: table.sort("nombre")) { row in
                            ToolTableText(row.count > 1 ? "×\(row.count)" : "—", size: 11.5,
                                          weight: row.count > 1 ? .semibold : .regular,
                                          color: row.count > 1 ? Theme.accentStrong : Theme.textTertiary, alignment: .trailing)
                                .help(row.count > 1 ? "\(row.count) messages identiques, de \(LogFormat.dayTime(row.firstDate)) à \(LogFormat.dayTime(row.message.date))" : "Message unique")
                        }
                        .width(min: 40, ideal: 52, max: 90)
                        .customizationID("nombre")
                        TableColumn("Adresse IP", sortUsing: table.sort("ip")) { row in
                            ToolTableText(row.message.host, size: 11.5)
                        }
                        .width(min: 90, ideal: 110)
                        .customizationID("ip").defaultVisibility(.hidden)
                        TableColumn("Programme", sortUsing: table.sort("app")) { row in
                            ToolTableText(row.message.app ?? "—", size: 11.5)
                        }
                        .width(min: 70, ideal: 120)
                        .customizationID("app").defaultVisibility(.hidden)
                        TableColumn("Événement", sortUsing: table.sort("evenement")) { row in
                            ToolTableText(row.message.eventID ?? "—", size: 11.5)
                        }
                        .width(min: 70, ideal: 130)
                        .customizationID("evenement").defaultVisibility(.hidden)
                    }
                }
                .standardRowActions(selection: sorted.map(\.id).filter(selection.contains), object: { id in
                    sorted.first { $0.id == id }?.ref.map { NavObject.device($0) }
                }) { ids in
                    if let row = sorted.first(where: { ids.contains($0.id) }) { menu(row) }
                }
            }
            .standardSiteColumn(table, multiple: multiSite)
        }
    }

    @ViewBuilder private func menu(_ row: LogRow) -> some View {
        Button("Comprendre une coupure à \(LogFormat.time(row.message.date))") { outage(row.message.date) }
        Button("Copier le message") { ToolActions.copy(row.message.message) }
        Button("Copier le texte brut") { ToolActions.copy(row.message.raw.isEmpty ? row.message.message : row.message.raw) }
        Button("Filtrer sur cet appareil") {
            let name = row.name.contains(" ") ? "\"\(row.name)\"" : row.name
            state.searchTexts[.journaux] = "appareil:" + name
        }
    }

    /// « 14:02:05 » aujourd'hui, sinon « 3 nov. 14:02:05 ».
    static func timeText(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? LogFormat.time(date) : LogFormat.dayTime(date)
    }
}

// MARK: - Puces

struct LogSeverityChip: View {
    let severity: LogSeverity

    var body: some View {
        Chip(text: severity.label, tone: Self.tone(severity))
            .help("Gravité Syslog \(severity.rawValue) (\(severity.keyword))")
    }

    static func tone(_ severity: LogSeverity) -> Tone {
        switch severity {
        case .emergency, .alert, .critical, .error: return .critical
        case .warning: return .warning
        case .notice: return .accent
        case .info, .debug: return .neutral
        }
    }
}

struct LogSourceChip: View {
    let source: LogSource

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(source)).font(.system(size: 10, weight: .semibold))
            Text(source == .trap ? "Trap" : source.label).font(Theme.small)
        }
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .fixedSize()
        .help(source.label)
    }

    static func symbol(_ source: LogSource) -> String {
        switch source {
        case .syslog: return "text.alignleft"
        case .trap: return "bell"
        case .fortigate: return "shield.lefthalf.filled"
        }
    }
}

// MARK: - Détail du message choisi

struct LogDetailPanel: View {
    @EnvironmentObject private var state: AppState
    let row: LogRow
    let outage: () -> Void

    var body: some View {
        let m = row.message
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    HStack(spacing: 8) { buttons }
                }
            }
            Text(m.message)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            let columns = [GridItem(.adaptive(minimum: 230), alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                KeyValueRow(key: "Heure", value: LogFormat.dayTime(m.date) + (m.received.map { $0 != m.date ? " (reçu \(LogFormat.time($0)))" : "" } ?? ""), keyWidth: 92)
                KeyValueRow(key: "Appareil", value: row.name == m.host ? m.host : "\(row.name) · \(m.host)", keyWidth: 92)
                KeyValueRow(key: "Site", value: m.siteName.isEmpty ? "—" : m.siteName, keyWidth: 92)
                KeyValueRow(key: "Source", value: m.source.label + (m.app.map { " · \($0)" } ?? ""), keyWidth: 92)
                KeyValueRow(key: "Gravité", value: "\(m.severity.label) (\(m.severity.rawValue))"
                            + (m.facility.flatMap(LogFacility.name).map { " · \($0)" } ?? ""), keyWidth: 92)
                KeyValueRow(key: "Événement", value: m.eventID ?? "—", mono: true, keyWidth: 92)
                if row.count > 1 {
                    KeyValueRow(key: "Répétitions", value: "×\(row.count) depuis \(LogFormat.dayTime(row.firstDate))", keyWidth: 92)
                }
            }
            if !m.raw.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ToolFieldLabel(m.source == .trap ? "Données de la trap" : "Texte brut")
                    ScrollView(.horizontal) {
                        Text(m.raw)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.consoleText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private var title: some View {
        HStack(spacing: 8) {
            ToolFieldLabel("Détail du message")
            LogSeverityChip(severity: row.message.severity)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { outage() } label: { Label("Comprendre une coupure à cette heure", systemImage: "clock.arrow.circlepath") }
            .buttonStyle(.secondary).controlSize(.small).fixedSize()
        if let ref = row.ref {
            Button { state.perform(.device(ref)) } label: { Label("Fiche de l’appareil", systemImage: "desktopcomputer") }
                .buttonStyle(.secondary).controlSize(.small).fixedSize()
        }
        Button { ToolActions.copy(row.message.raw.isEmpty ? row.message.message : row.message.raw) } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.secondary).controlSize(.small)
        .help("Copier le texte brut")
    }
}
