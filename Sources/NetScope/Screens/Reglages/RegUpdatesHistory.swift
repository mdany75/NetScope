import NetScopeCore
import SwiftUI

/// Réglages › Mises à jour : historique de toutes les versions publiées (lues dans le CHANGELOG
/// livré avec l'app, plus la version disponible sur GitHub), avec la date d'installation sur ce Mac
/// et le résumé des notes de chacune ; un clic déroule le détail par rubrique.
struct RegUpdatesHistory: View {
    @ObservedObject var updates: UpdController
    @State private var expanded: Set<String> = []
    @State private var showAll = false
    @State private var installedOnly = false
    /// Note 93 : version dont la réinstallation attend la confirmation.
    @State private var confirming: String?

    /// Versions montrées avant « Afficher les … versions plus anciennes ».
    private static let firstPage = 8

    var body: some View {
        let all = rows
        let filtered = installedOnly ? all.filter { $0.installedAt != nil || $0.state == .running } : all
        let visible = showAll ? filtered : Array(filtered.prefix(Self.firstPage))
        let installedCount = all.filter { $0.installedAt != nil || $0.state == .running }.count
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading(total: all.count, installed: installedCount)
                    Spacer(minLength: 8)
                    filter
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading(total: all.count, installed: installedCount)
                    filter
                }
            }
            VStack(spacing: 0) {
                ForEach(visible) { row in
                    rowView(row)
                    if row.id != visible.last?.id { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                if filtered.count > Self.firstPage {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                    } label: {
                        Label(showAll ? "Afficher seulement les \(Self.firstPage) plus récentes"
                                      : "Afficher les \(filtered.count - Self.firstPage) versions plus anciennes",
                              systemImage: showAll ? "chevron.up" : "chevron.down")
                            .font(Theme.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            HStack(spacing: 10) {
                let previous = previousVersion(all)
                Button {
                    confirming = previous
                } label: {
                    Label(previous.map { "Revenir à la \($0)" } ?? "Revenir à la version précédente", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.secondary)
                .regDisabled(previous == nil || updates.isBusy)
                Text("Réinstalle une version publiée depuis sa Release GitHub, signature vérifiée avant l’installation\u{00A0}; vos données sont gardées. Chaque version dépliée a aussi son bouton «\u{00A0}Réinstaller cette version\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming.flatMap { updates.rollbackPlan($0) }) { plan in
            Button(plan.confirmLabel, role: plan.warnings.isEmpty ? nil : .destructive) {
                let version = plan.target.description
                Task { await updates.reinstall(version) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { plan in
            Text(plan.message)
        }
        .onAppear {
            // La version qui tourne est dépliée d'emblée : ce qu'elle a apporté se lit sans clic.
            if expanded.isEmpty { expanded = [UpdController.currentVersionText] }
        }
    }

    // MARK: Données

    private var rows: [UpdTimelineRow] {
        var changelog = UpdController.changelog
        // Version disponible sur GitHub, plus récente que le CHANGELOG livré : ses notes viennent de la Release.
        if let release = updates.release, let version = release.version,
           !changelog.contains(where: { UpdVersion($0.version) == version }) {
            let parsed = ChangelogNotes.parse("## \(version)\(release.publishedAt.map { " — " + Self.isoDay($0) } ?? "")\n\n\(release.body ?? "")")
            changelog.insert(parsed.first ?? ChangelogVersion(version: version.description, date: release.publishedAt, summary: "", sections: []), at: 0)
        }
        return UpdTimeline.rows(changelog: changelog, history: updates.prefs.history, running: UpdController.currentVersionText)
    }

    private var confirmTitle: String {
        confirming.flatMap { updates.rollbackPlan($0)?.title } ?? "Réinstaller cette version\u{00A0}?"
    }

    /// Version précédente : la dernière installée avant celle-ci, sinon la plus récente publiée plus ancienne.
    private func previousVersion(_ rows: [UpdTimelineRow]) -> String? {
        if let row = rows.first(where: { $0.state == .previous }) { return row.version }
        let current = UpdController.currentVersion
        return UpdRollback.previousVersion(published: rows.compactMap { UpdVersion($0.version) }, current: current)?.description
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: En-tête

    private func heading(total: Int, installed: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RegLabel("Historique des versions")
            Text("\(total) version\(total > 1 ? "s" : "") publiée\(total > 1 ? "s" : "") · \(installed) installée\(installed > 1 ? "s" : "") sur ce Mac")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private var filter: some View {
        Picker("", selection: $installedOnly) {
            Text("Toutes").tag(false)
            Text("Installées sur ce Mac").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Ligne

    private func rowView(_ row: UpdTimelineRow) -> some View {
        let isOpen = expanded.contains(row.version)
        let hasDetail = (row.notes?.itemCount ?? 0) > 0
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(row.version) } else { expanded.insert(row.version) }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hasDetail ? Theme.textSecondary : Color.clear)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.version).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                                .fixedSize()
                            if row.channel == .beta { RegPill(text: "Bêta", tone: .warning).fixedSize() }
                            Text(dates(row)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            RegPill(text: stateLabel(row.state), tone: stateTone(row.state)).fixedSize()
                        }
                        Text(row.notes?.shortSummary ?? "Notes absentes du CHANGELOG de cette version.")
                            .font(Theme.small)
                            .foregroundStyle(row.notes == nil ? Theme.textTertiary : Theme.textSecondary)
                            .lineLimit(isOpen ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasDetail ? (isOpen ? "Replier les notes" : "Déplier les notes de la version \(row.version)") : "")
            if isOpen, let notes = row.notes, notes.itemCount > 0 {
                detail(notes).padding(.leading, 22)
            }
            if isOpen, row.state == .previous || row.state == .notInstalled {
                ActionRow {
                    Button {
                        confirming = row.version
                    } label: {
                        Label("Réinstaller cette version", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.secondary)
                    .regDisabled(updates.isBusy)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(row.state == .running ? Theme.accentSoft.opacity(0.45) : Color.clear)
    }

    private func detail(_ notes: ChangelogVersion) -> some View {
        // Rubriques côte à côte quand il y a la place ; l'une sous l'autre en petite fenêtre.
        RegColumns(minColumnWidth: 240, spacing: 18) {
            ForEach(notes.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(Theme.captionSemibold).foregroundStyle(sectionColor(section.title))
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Theme.textSecondary)
                            Text(item).font(Theme.small).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Libellés

    private func dates(_ row: UpdTimelineRow) -> String {
        var parts: [String] = []
        if let date = row.notes?.date { parts.append("publiée le \(RegFormat.day(date))") }
        if let installed = row.installedAt { parts.append("installée le \(RegFormat.day(installed))") }
        return parts.joined(separator: " · ")
    }

    private func stateLabel(_ state: UpdTimelineState) -> String {
        switch state {
        case .running: return "Installée"
        case .previous: return "Précédente"
        case .notInstalled: return "Non installée ici"
        case .newer: return "Disponible"
        }
    }

    private func stateTone(_ state: UpdTimelineState) -> Tone {
        switch state {
        case .running: return .success
        case .previous: return .neutral
        case .notInstalled: return .neutral
        case .newer: return .accent
        }
    }

    private func sectionColor(_ title: String) -> Color {
        switch title.lowercased() {
        case let t where t.hasPrefix("ajout"): return Theme.success
        case let t where t.hasPrefix("corrig"): return Theme.accent
        case let t where t.hasPrefix("limite"): return Theme.warning
        default: return Theme.textSecondary
        }
    }
}
