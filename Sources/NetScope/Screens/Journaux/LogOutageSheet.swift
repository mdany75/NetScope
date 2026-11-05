import NetScopeCore
import SwiftUI

/// « Comprendre une coupure » (note 43) : autour d'une heure choisie, les messages de tous les
/// appareils des sites affichés, mis en ordre, avec les constats (port qui tombe et remonte,
/// redémarrage, authentification refusée, tunnel tombé…) et l'écart à l'heure choisie.
struct LogOutageSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var screen = JournauxScreenState.shared
    let siteKeys: Set<String>
    @State private var selection: Set<UUID> = []
    @StateObject private var table = LogOutageRow.makeModel()

    static let spans: [(TimeInterval, String)] = [(120, "±\u{00A0}2\u{00A0}min"), (300, "±\u{00A0}5\u{00A0}min"), (600, "±\u{00A0}10\u{00A0}min"),
                                                  (1800, "±\u{00A0}30\u{00A0}min"), (3600, "±\u{00A0}1\u{00A0}h")]

    var body: some View {
        let report = store.outage(around: screen.outageCenter, span: screen.outageSpan, siteKeys: siteKeys)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comprendre une coupure").font(Theme.panelTitle)
                    Text("Messages de tous les appareils autour de l’heure choisie, du plus ancien au plus récent.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Fermer") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Text("Heure").font(Theme.small).foregroundStyle(Theme.textSecondary)
                DatePicker("Heure", selection: $screen.outageCenter, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .fixedSize()
                InvSegmented(options: Self.spans.map { ($0.0, $0.1) }, selection: $screen.outageSpan)
                Spacer(minLength: 0)
                Text(LogFormat.count(report.messages.count, "message", "messages") + " · "
                     + LogFormat.count(report.devices.count, "appareil", "appareils"))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    .fixedSize()
            }
            findings(report)
            if !report.devices.isEmpty {
                HStack(spacing: 6) {
                    Text("Appareils").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    StandardTagList(tags: report.devices.map { "\($0.name) ×\($0.count)" })
                }
            }
            timeline(report)
        }
        .padding(18)
        .frame(minWidth: 760, idealWidth: 900, maxWidth: 1000, minHeight: 520, idealHeight: 620)
    }

    private func close() {
        if RegEnvironment.isSnapshot { return }
        screen.showOutage = false
        dismiss()
    }

    @ViewBuilder private func findings(_ report: LogAnalysis.OutageReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.findings.isEmpty {
                Text("Aucun constat\u{00A0}: port, redémarrage, authentification ou tunnel.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            }
            ForEach(Array(report.findings.prefix(6).enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .top, spacing: 8) {
                    Text(LogFormat.time(finding.date))
                        .font(Theme.mono(11.5, weight: .semibold))
                        .foregroundStyle(LogSeverityChip.tone(finding.severity).foreground)
                        .frame(width: 62, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(LogSeverityChip.tone(finding.severity).background.opacity(0.6)))
            }
        }
    }

    private func timeline(_ report: LogAnalysis.OutageReport) -> some View {
        let names = store.names(for: report.messages)
        let rows = report.messages.map { LogOutageRow(message: $0, center: report.center, name: names[$0.host] ?? $0.deviceLabel) }
            .sorted(using: table.sortOrder)
        let spanLabel = Self.spans.first { $0.0 == screen.outageSpan }?.1 ?? "±\u{00A0}\(Int(screen.outageSpan / 60))\u{00A0}min"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Chronologie · \(rows.count)")
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
            }
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 8,
                                   emptyText: "Aucun message à \(spanLabel) autour de cette heure. Élargissez la fenêtre.") {
                Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn("ÉCART", sortUsing: table.sort("ecart")) { row in
                        ToolTableText(LogFormat.offset(row.offset), size: 11.5,
                                      color: row.offset < 0 ? Theme.textSecondary : Theme.text)
                    }
                    .width(min: 70, ideal: 86, max: 110)
                    .customizationID("ecart")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("HEURE", sortUsing: table.sort("heure")) { row in ToolTableText(LogFormat.time(row.message.date), size: 11.5) }
                        .width(min: 60, ideal: 70, max: 90)
                        .customizationID("heure")
                    TableColumn("APPAREIL", sortUsing: table.sort("appareil")) { row in ToolTableText(row.name, mono: false, weight: .medium) }
                        .width(min: 90, ideal: 150)
                        .customizationID("appareil")
                    TableColumn("SOURCE", sortUsing: table.sort("source")) { row in LogSourceChip(source: row.message.source) }
                        .width(min: 60, ideal: 76, max: 100)
                        .customizationID("source")
                    TableColumn("GRAVITÉ", sortUsing: table.sort("gravite")) { row in LogSeverityChip(severity: row.message.severity) }
                        .width(min: 74, ideal: 100, max: 120)
                        .customizationID("gravite")
                    TableColumn("MESSAGE", sortUsing: table.sort("message")) { row in
                        ToolTableText(row.message.message, mono: false).help(row.message.message)
                    }
                    .width(min: 200, ideal: 420)
                    .customizationID("message")
                }
            }
            .standardRowNavigation(selection: rows.map(\.id).filter(selection.contains), object: { id in
                guard let row = rows.first(where: { $0.id == id }) else { return nil }
                return store.device(for: row.message).ref.map { NavObject.device($0) }
            })
        }
    }
}

/// Ligne de la chronologie de « Comprendre une coupure » (tableau standard « journaux-coupure »).
struct LogOutageRow: Identifiable {
    let message: LogMessage
    let center: Date
    let name: String
    var id: UUID { message.id }

    var offset: TimeInterval { message.date.timeIntervalSince(center) }
    var sortOffset: TimeInterval { offset }
    var sortName: String { SearchText.fold(name) }
    var sortSource: String { message.source.label }
    var sortSeverity: Int { message.severity.rawValue }
    var sortMessage: String { SearchText.fold(message.message) }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ecart", title: "Écart", isRequired: true),
        StandardColumn(id: "heure", title: "Heure"),
        StandardColumn(id: "appareil", title: "Appareil"),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "gravite", title: "Gravité"),
        StandardColumn(id: "message", title: "Message"),
    ]

    static let sortKeys: [String: KeyPathComparator<LogOutageRow>] = [
        "ecart": KeyPathComparator(\LogOutageRow.sortOffset),
        "heure": KeyPathComparator(\LogOutageRow.sortOffset),
        "appareil": KeyPathComparator(\LogOutageRow.sortName),
        "source": KeyPathComparator(\LogOutageRow.sortSource),
        "gravite": KeyPathComparator(\LogOutageRow.sortSeverity),
        "message": KeyPathComparator(\LogOutageRow.sortMessage),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<LogOutageRow> {
        StandardTableModel(id: "journaux-coupure", columns: columns, sortKeys: sortKeys, defaultSort: "ecart")
    }
}