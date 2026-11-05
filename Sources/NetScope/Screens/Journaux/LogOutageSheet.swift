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
        let rows = report.messages
        return Table(rows, selection: $selection) {
            TableColumn("Écart") { m in
                ToolTableText(LogFormat.offset(m.date.timeIntervalSince(report.center)), size: 11.5,
                              color: m.date < report.center ? Theme.textSecondary : Theme.text)
            }
            .width(min: 70, ideal: 86, max: 110)
            TableColumn("Heure") { m in ToolTableText(LogFormat.time(m.date), size: 11.5) }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("Appareil") { m in ToolTableText(names[m.host] ?? m.deviceLabel, mono: false, weight: .medium) }
                .width(min: 90, ideal: 150)
            TableColumn("Source") { m in LogSourceChip(source: m.source) }
                .width(min: 60, ideal: 76, max: 100)
            TableColumn("Gravité") { m in LogSeverityChip(severity: m.severity) }
                .width(min: 74, ideal: 100, max: 120)
            TableColumn("Message") { m in ToolTableText(m.message, mono: false).help(m.message) }
                .width(min: 200, ideal: 420)
        }
        .standardTableStyle()
        .frame(minHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .standardRowNavigation(selection: rows.map(\.id).filter(selection.contains), object: { id in
            guard let m = rows.first(where: { $0.id == id }) else { return nil }
            return store.device(for: m).ref.map { NavObject.device($0) }
        })
    }
}
