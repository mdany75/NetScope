import NetScopeCore
import SwiftUI

private enum MonJournalColumns {
    static let time: CGFloat = 150
    static let severity: CGFloat = 80
    static let probe: CGFloat = 156
    static let follow: CGFloat = 214
}

/// Panneau « Journal des alertes » : filtres, « Tout accuser réception », tableau.
struct MonJournalPanel: View {
    @ObservedObject private var store = MonStore.shared
    @State private var filter: MonJournalFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            header
            columns
            let alerts = store.journal.filtered(filter)
            if alerts.isEmpty {
                Text(store.journal.alerts.isEmpty ? "Aucune alerte pour l’instant." : "Aucune entrée pour ce filtre.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if alerts.count > 8 {
                ScrollView { rows(alerts) }.frame(height: 330)
            } else {
                rows(alerts)
            }
        }
        .monPanel()
    }

    private func rows(_ alerts: [MonAlert]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(alerts) { alert in
                MonJournalRow(alert: alert)
            }
        }
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

    private var columns: some View {
        HStack(spacing: 0) {
            heading("Horodatage").padding(.leading, 12).frame(width: MonJournalColumns.time, alignment: .leading)
            heading("Gravité").padding(.horizontal, 8).frame(width: MonJournalColumns.severity, alignment: .leading)
            heading("Sonde").padding(.horizontal, 8).frame(width: MonJournalColumns.probe, alignment: .leading)
            heading("Événement").padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            heading("Suivi").padding(.horizontal, 8).frame(width: MonJournalColumns.follow, alignment: .leading)
        }
        .frame(height: 30)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.3)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct MonJournalRow: View {
    @ObservedObject private var store = MonStore.shared
    let alert: MonAlert

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(MonJournal.timestamp(alert.date, now: store.now))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.neutralText)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 12)
                .padding(.top, 1)
                .frame(width: MonJournalColumns.time, alignment: .leading)
            RegPill(text: alert.severity.label, tone: MonText.tone(alert.severity))
                .padding(.horizontal, 8)
                .frame(width: MonJournalColumns.severity, alignment: .leading)
            Text(alert.probeName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(width: MonJournalColumns.probe, alignment: .leading)
            Text(alert.fullMessage)
                .font(Theme.small)
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            follow
                .padding(.horizontal, 8)
                .frame(width: MonJournalColumns.follow, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var follow: some View {
        HStack(spacing: 6) {
            if alert.isResolved {
                RegPill(text: "Résolue", tone: .success)
            }
            if let date = alert.acknowledgedAt {
                Text(alert.acknowledgedBy.map { "Accusé par \($0) · \(ackTime(date))" } ?? "Aucune action requise")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
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
