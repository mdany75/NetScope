import NetScopeCore
import SwiftUI

/// Filtre de gravité des alertes.
enum AnaSeverityFilter: String, CaseIterable, Hashable {
    case toutes, critiques, alertes, info

    func includes(_ event: InvEvent) -> Bool {
        switch self {
        case .toutes: return true
        case .critiques: return event.severity == .critique
        case .alertes: return event.severity == .alerte
        case .info: return event.severity == .info
        }
    }
}

/// Alertes et changements issus des événements de l'inventaire.
struct AnaAlertsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let alerts: [InvEvent]
    let period: AnaPeriod
    let query: String

    @State private var filter: AnaSeverityFilter = .toutes
    @State private var limit = 8

    var body: some View {
        let matching = alerts.filter { matches($0) }
        let shown = matching.filter { filter.includes($0) }
        let pending = alerts.filter { $0.status == .aTraiter }.count

        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Alertes et changements").font(.system(size: 14, weight: .semibold))
                        Text("\(pending) à traiter · \(alerts.count) changement\(alerts.count > 1 ? "s" : "") sur \(period.label)")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    tabs(matching)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Rectangle().fill(Theme.border).frame(height: 1)
                if shown.isEmpty {
                    Text(alerts.isEmpty ? "Aucun changement sur la période. Les alertes apparaissent après le deuxième scan."
                         : "Aucune alerte ne correspond au filtre ou à la recherche.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown.prefix(limit)) { alert in row(alert) }
                    }
                    if shown.count > limit {
                        Button("Afficher les \(min(shown.count - limit, 20)) suivantes (\(shown.count - limit) restantes)") { limit += 20 }
                            .buttonStyle(.ghost)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func matches(_ event: InvEvent) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return (event.title + " " + event.detail + " " + event.ip.description)
            .range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func tabs(_ alerts: [InvEvent]) -> some View {
        let options: [(AnaSeverityFilter, String)] = [
            (.toutes, "Toutes (\(alerts.count))"),
            (.critiques, "Critiques (\(alerts.filter { $0.severity == .critique }.count))"),
            (.alertes, "Alertes (\(alerts.filter { $0.severity == .alerte }.count))"),
            (.info, "Info (\(alerts.filter { $0.severity == .info }.count))"),
        ]
        return HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == filter
                Button { filter = value } label: {
                    Text(label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.panel : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Theme.border : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.neutralSoft))
        .fixedSize()
    }

    private func row(_ alert: InvEvent) -> some View {
        let colors = InvStyle.severity(alert.severity)
        let done = alert.status != .aTraiter
        return HStack(alignment: .center, spacing: 10) {
            Text(alert.severity.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(colors.0)
                .frame(width: 66, height: 20)
                .background(Capsule().fill(colors.1))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(Theme.bodySemibold).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(alert.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(alert.title + "\n" + alert.detail)
            Text(Date().timeIntervalSince(alert.date) < 86_400 ? InvFormat.time(alert.date) : InvFormat.day(alert.date))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .trailing)
            if done {
                Text((alert.status == .accepte ? "Accepté" : "Ignoré") + (alert.statusDate.map { " · \(InvFormat.time($0))" } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Button("Annuler") { set(.aTraiter, alert) }.buttonStyle(AnaSmallButtonStyle())
            } else {
                Button("Accepter") { set(.accepte, alert) }.buttonStyle(AnaSmallButtonStyle())
                Button("Ignorer") { set(.ignore, alert) }.buttonStyle(AnaSmallButtonStyle())
            }
            Button("Voir") {
                model.selectedKey = alert.key
                state.open(.inventaire)
            }
            .buttonStyle(.ghost)
            .help("Ouvrir la fiche dans l’inventaire")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .background(done ? Theme.panelMuted : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func set(_ status: InvEventStatus, _ alert: InvEvent) {
        model.setEventStatus(status, for: alert.id)
        model.updateBadge(state)
    }
}

/// Petit bouton blanc de 28 pt (Accepter, Ignorer, Annuler).
struct AnaSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(configuration.isPressed ? Theme.panelMuted : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

/// Onglets de la comparaison.
enum AnaDiffTab: Hashable {
    case added, removed, modified
}

/// Comparaison de deux instantanés de scan : ajoutés, disparus, modifiés.
struct AnaComparePanel: View {
    let snapshots: [InvSnapshot]
    let onExport: (String, String) -> Void

    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var tab: AnaDiffTab = .modified

    var body: some View {
        let after = snapshots.first { $0.id == afterID } ?? snapshots.last
        let before = snapshots.first { $0.id == beforeID }
            ?? snapshots.last { snapshot in after.map { snapshot.date < $0.date } ?? false }

        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Comparer deux scans").font(.system(size: 14, weight: .semibold))
                        if let before, let after {
                            Text("\(Self.label(before.date)) → \(Self.label(after.date))")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 16) {
                        picker("Avant", selection: $beforeID, current: before)
                        picker("Après", selection: $afterID, current: after)
                    }
                    .frame(height: 28)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Rectangle().fill(Theme.border).frame(height: 1)

                if let before, let after, before.id != after.id {
                    let diff = InventoryStore.compare(before, after)
                    content(diff, before: before, after: after)
                } else {
                    Text("Il faut au moins deux scans enregistrés pour comparer. Un instantané est gardé à chaque scan qui change le résultat.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "aujourd’hui \(InvFormat.time(date))" }
        if calendar.isDateInYesterday(date) { return "hier \(InvFormat.time(date))" }
        return InvFormat.stamp(date)
    }

    private func picker(_ title: String, selection: Binding<UUID?>, current: InvSnapshot?) -> some View {
        Menu {
            ForEach(snapshots.reversed()) { snapshot in
                Button("\(Self.label(snapshot.date)) · \(snapshot.onlineCount) en ligne") { selection.wrappedValue = snapshot.id }
            }
        } label: {
            Text("\(title) : \(current.map { Self.label($0.date) } ?? "—")").font(Theme.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(snapshots.count < 2)
    }

    @ViewBuilder
    private func content(_ diff: InvDiff, before: InvSnapshot, after: InvSnapshot) -> some View {
        let rows: [InvDiffRow] = {
            switch tab {
            case .added: return diff.added
            case .removed: return diff.removed
            case .modified: return diff.modified
            }
        }()
        let afterColor: Color = tab == .added ? Theme.success : (tab == .removed ? Theme.critical : Theme.warning)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tabButton(.added, number: "+\(diff.added.count)", label: "ajoutés", fg: Theme.success, bg: Theme.successSoft)
                tabButton(.removed, number: "−\(diff.removed.count)", label: "disparus", fg: Theme.critical, bg: Theme.criticalSoft)
                tabButton(.modified, number: "\(diff.modified.count)", label: "modifiés", fg: Theme.warning, bg: Theme.warningSoft)
            }
            VStack(spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        ForEach(["IP", "Nom", "MAC", "Avant", "Après"], id: \.self) { title in
                            Text(title.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                                .frame(height: 26, alignment: .leading)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows.prefix(40)) { row in
                        GridRow {
                            Text(row.ip.description).font(Theme.mono(11.5, weight: .semibold))
                            Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(row.mac).font(Theme.mono(10.5)).foregroundStyle(Theme.neutralText).lineLimit(1)
                            Text(row.before).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.after).font(.system(size: 12, weight: .semibold)).foregroundStyle(afterColor).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 32)
                        .padding(.vertical, 3)
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
                if rows.isEmpty {
                    Text("Aucun appareil dans cette catégorie.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
            }
            HStack {
                Text("Base : \(before.total) appareils avant → \(after.total) après (+\(diff.added.count) −\(diff.removed.count)).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Exporter l’écart CSV") {
                    onExport(csv(diff), "ecart-scans-\(InvFormat.day(after.date)).csv")
                }
                .buttonStyle(AnaSmallButtonStyle())
            }
        }
        .padding(16)
    }

    private func tabButton(_ value: AnaDiffTab, number: String, label: String, fg: Color, bg: Color) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(number).font(Theme.mono(20, weight: .bold)).foregroundStyle(fg)
                Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(on ? bg : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(on ? fg : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func csv(_ diff: InvDiff) -> String {
        var lines = ["Écart;IP;Nom;MAC;Avant;Après"]
        for (kind, rows) in [("Ajouté", diff.added), ("Disparu", diff.removed), ("Modifié", diff.modified)] {
            for row in rows {
                lines.append([kind, row.ip.description, row.name, row.mac, row.before, row.after].map(AnaCSV.quote).joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
