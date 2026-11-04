import NetScopeCore
import SwiftUI

// Réglages › Alertes : règles d'envoi (événements, gravité, anti-rafale, regroupement, heures de
// silence) et journal des envois (tableau standard, sans secret).

// MARK: - Règles

struct RegAlertRulesPanel: View {
    @ObservedObject private var alerts = AlertDispatcher.shared

    private var rules: Binding<AlertRules> { $alerts.settings.rules }

    var body: some View {
        RegPanel(title: "Règles d’envoi",
                 subtitle: "Quels événements partent hors du Mac, et à quel rythme. Les notifications macOS se règlent à part.") {
            RegColumns(minColumnWidth: 320) {
                events
                limits
            }
        }
    }

    // Événements, au format du croquis (libellé, puce de gravité, description, interrupteur).
    private var events: some View {
        VStack(alignment: .leading, spacing: 0) {
            RegLabel("Événements")
                .padding(.bottom, 4)
            ForEach(AlertEventKind.configurable) { kind in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(kind.label).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            RegSeverityTag(severity: kind.typicalSeverity)
                        }
                        Text(kind.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RegSwitch(isOn: Binding(get: { alerts.settings.rules.kinds.contains(kind) },
                                            set: { on in
                                                if on { alerts.settings.rules.kinds.insert(kind) } else { alerts.settings.rules.kinds.remove(kind) }
                                            }))
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 12) {
            RegLabel("Gravité, rythme et silence")
            limitRow("Gravité minimale", detail: "Les rétablissements suivent toujours une panne signalée.") {
                RegSegmented(selection: rules.minimumSeverity,
                             options: AlertSeverity.allCases.map { .init(value: $0, label: $0.label) })
            }
            limitRow("Anti-rafale", detail: "Au plus une alerte par événement et par objet dans l’intervalle\u{00A0}; les répétitions sont comptées dans la suivante.") {
                Picker("", selection: rules.throttleMinutes) {
                    ForEach(AlertRules.throttleChoices, id: \.self) { Text(AlertRules.minutesLabel($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            limitRow("Regroupement", detail: "Les événements d’une même fenêtre partent en un seul résumé.") {
                Picker("", selection: rules.groupingSeconds) {
                    ForEach(AlertRules.groupingChoices, id: \.self) { Text(AlertRules.secondsLabel($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            Rectangle().fill(Theme.neutralSoft).frame(height: 1)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heures de silence").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text("Rien ne part pendant cette période.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RegSwitch(isOn: rules.quietHours.isEnabled)
            }
            HStack(spacing: 8) {
                Text("De").font(Theme.small).foregroundStyle(Theme.textSecondary)
                timePicker(rules.quietHours.startMinute, label: "Début des heures de silence")
                Text("à").font(Theme.small).foregroundStyle(Theme.textSecondary)
                timePicker(rules.quietHours.endMinute, label: "Fin des heures de silence")
                Spacer(minLength: 0)
            }
            .regDisabled(!alerts.settings.rules.quietHours.isEnabled)
            Toggle(isOn: rules.quietHours.criticalBypass) {
                Text("Les alertes critiques passent quand même (sonde hors ligne, DHCP non autorisé)")
                    .font(Theme.small).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .regDisabled(!alerts.settings.rules.quietHours.isEnabled)
            if alerts.skippedCount > 0, let reason = alerts.lastSkipReason {
                Text("\(alerts.skippedCount) événement\(alerts.skippedCount > 1 ? "s" : "") retenu\(alerts.skippedCount > 1 ? "s" : "") depuis le lancement (dernier\u{00A0}: \(reason.label)).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func limitRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                control()
            }
            Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Heure native (HH:mm) liée à des minutes depuis minuit.
    private func timePicker(_ minutes: Binding<Int>, label: String) -> some View {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let date = Binding<Date>(
            get: { base.addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { value in
                let parts = calendar.dateComponents([.hour, .minute], from: value)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
        return DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .controlSize(.small)
            .environment(\.locale, Locale(identifier: "fr_CA"))
            .fixedSize()
    }
}

// MARK: - Journal

/// Une ligne du journal des envois (valeurs figées pour le tri).
struct RegAlertJournalRow: Identifiable {
    let entry: AlertLogEntry
    var id: UUID { entry.id }
    var date: Date { entry.date }
    var channel: String { entry.channelName }
    var title: String { entry.title }
    var outcome: String { entry.outcome.label }
    var detail: String { entry.detail }
    var duration: Double { entry.durationMs ?? -1 }
}

struct RegAlertJournalPanel: View {
    @ObservedObject private var alerts = AlertDispatcher.shared
    @StateObject private var table = StandardTableModel<RegAlertJournalRow>(
        id: "reglages.alertes.journal", columns: RegAlertJournalPanel.columns, sortKeys: RegAlertJournalPanel.sortKeys,
        defaultSort: "date", defaultAscending: false)
    @State private var confirmClear = false

    static let rowHeight: CGFloat = 30
    static let maxRows = 10

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date", isRequired: true),
        StandardColumn(id: "canal", title: "Canal"),
        StandardColumn(id: "alerte", title: "Alerte"),
        StandardColumn(id: "resultat", title: "Résultat"),
        StandardColumn(id: "detail", title: "Détail"),
        StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegAlertJournalRow>] = [
        "date": KeyPathComparator(\RegAlertJournalRow.date),
        "canal": KeyPathComparator(\RegAlertJournalRow.channel),
        "alerte": KeyPathComparator(\RegAlertJournalRow.title),
        "resultat": KeyPathComparator(\RegAlertJournalRow.outcome),
        "detail": KeyPathComparator(\RegAlertJournalRow.detail),
        "duree": KeyPathComparator(\RegAlertJournalRow.duration),
    ]

    private var rows: [RegAlertJournalRow] {
        alerts.journal.map(RegAlertJournalRow.init).sorted(using: table.sortOrder)
    }

    private var failures: Int { alerts.journal.filter { $0.outcome == .failed }.count }

    var body: some View {
        RegPanel(title: "Journal des envois",
                 subtitle: "\(alerts.journal.count) envoi\(alerts.journal.count > 1 ? "s" : "")" + (failures > 0 ? " · \(failures) échec\(failures > 1 ? "s" : "")" : "")
                    + " · sans aucun secret (mots de passe et adresses de webhook masqués).",
                 accessory: {
                     HStack(spacing: 8) {
                         StandardColumnsMenu(model: table, compact: true)
                         Button("Effacer…") { confirmClear = true }
                             .buttonStyle(.secondary)
                             .regDisabled(alerts.journal.isEmpty)
                     }
                     .fixedSize()
                 }) {
            if alerts.journal.isEmpty {
                Text("Aucun envoi pour l’instant.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                journalTable
            }
        }
        .confirmationDialog("Effacer le journal des envois\u{00A0}?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Effacer", role: .destructive) { alerts.clearJournal() }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var journalTable: some View {
        let rows = rows
        return Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("DATE"), sortUsing: table.sort("date")) { row in
                Text(RegFormat.moment(row.date)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            .customizationID("date")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("CANAL"), sortUsing: table.sort("canal")) { row in
                HStack(spacing: 6) {
                    Image(systemName: symbol(row.entry.channelKind)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(row.channel).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                }
                .help(row.channel)
            }
            .width(min: 110, ideal: 170)
            .customizationID("canal")

            TableColumn(StandardTableHeading("ALERTE"), sortUsing: table.sort("alerte")) { row in
                HStack(spacing: 6) {
                    Circle().fill(dot(row.entry.severity)).frame(width: 7, height: 7)
                    Text(row.title).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    if row.entry.isTest { Chip(text: "Essai", tone: .neutral) }
                }
                .help(row.title + (row.entry.eventCount > 1 ? " (\(row.entry.eventCount) événements)" : ""))
            }
            .width(min: 120, ideal: 190)
            .customizationID("alerte")

            TableColumn(StandardTableHeading("RÉSULTAT"), sortUsing: table.sort("resultat")) { row in
                RegPill(text: row.outcome, tone: row.entry.outcome == .sent ? .success : row.entry.outcome == .failed ? .critical : .neutral)
            }
            .width(min: 70, ideal: 80)
            .customizationID("resultat")

            TableColumn(StandardTableHeading("DÉTAIL"), sortUsing: table.sort("detail")) { row in
                Text(row.detail).font(Theme.small)
                    .foregroundStyle(row.entry.outcome == .failed ? Theme.critical : Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(row.detail)
            }
            .width(min: 120, ideal: 220)
            .customizationID("detail")

            TableColumn(StandardTableHeading("DURÉE"), sortUsing: table.sort("duree")) { row in
                Text(row.entry.durationMs.map { ToolFormat.milliseconds($0) } ?? "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("duree")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)
    }

    private func symbol(_ kind: String) -> String {
        if kind == "courriel" { return "envelope" }
        return AlertWebhookKind(rawValue: kind)?.symbol ?? "link"
    }

    private func dot(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .critical: return Theme.criticalBadge
        case .warning: return Theme.warningDot
        case .info: return Theme.accent
        }
    }
}
