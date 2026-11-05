import NetScopeCore
import SwiftUI

/// Note 42 : « Suivi depuis le dernier rapport » dans la colonne des Rapports : base de comparaison
/// (dernier rapport du site, un rapport précis ou une date), écarts en bref, et rapports passés du
/// site (ouvrir, afficher dans le Finder, comparer, supprimer).
struct RapportFollowUpPanel: View {
    @ObservedObject var model: RapportModel
    @ObservedObject private var history = RapportHistoryStore.shared
    /// Site décrit (le premier du rapport) et sa comparaison.
    let siteKey: String
    let siteName: String
    let result: ReportFollowUpResult?
    /// Plusieurs sites dans le rapport : chacun est comparé à son propre dernier rapport.
    let multisite: Bool

    @State private var showAll = false
    @State private var datePopover = false
    @State private var pickedDate = Date()
    @State private var pendingDelete: ReportSnapshot?

    private static let collapsed = 3

    var body: some View {
        let snapshots = history.history(forKey: siteKey).snapshots
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Suivi", subtitle: siteName) {
                    if model.config.includes(.suivi) {
                        Chip(text: "Dans le rapport", tone: .accent)
                    } else {
                        Button("Ajouter au rapport") { model.toggle(.suivi) }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .medium))
                            .help("Coche la section «\u{00A0}Depuis le dernier rapport\u{00A0}»")
                    }
                }
                .padding(.bottom, 8)
                basePicker(snapshots)
                summary
                    .padding(.top, 10)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
                pastReports(snapshots)
            }
        }
        .confirmationDialog("Supprimer ce rapport\u{00A0}?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { snapshot in
            Button("Supprimer «\u{00A0}\(snapshot.title)\u{00A0}»", role: .destructive) {
                model.show(history.delete(snapshot))
            }
            Button("Annuler", role: .cancel) {}
        } message: { snapshot in
            Text("Le fichier \(snapshot.fileName) va dans la Corbeille et son instantané est oublié\u{00A0}: il ne servira plus de base de comparaison.")
        }
    }

    // MARK: Base

    private func basePicker(_ snapshots: [ReportSnapshot]) -> some View {
        HStack(spacing: 6) {
            Text("Comparer à").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            Menu {
                Button(multisite ? "Dernier rapport de chaque site" : "Dernier rapport du site") { history.base = .last }
                if !multisite && !snapshots.isEmpty {
                    Divider()
                    ForEach(snapshots) { snapshot in
                        Button("\(snapshot.reportDate) · \(snapshot.title)") { history.base = .report(snapshot.id) }
                    }
                }
                Divider()
                Button("Le dernier rapport au plus tard le…") { datePopover = true }
            } label: {
                Text(baseLabel(snapshots)).font(Theme.small).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .popover(isPresented: $datePopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Comparer au dernier rapport produit au plus tard le\u{00A0}:").font(Theme.small)
                    DatePicker("", selection: $pickedDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "fr_CA"))
                    HStack {
                        Spacer()
                        Button("Annuler") { datePopover = false }
                        Button("Comparer") {
                            history.base = .date(ReportText.isoDay(pickedDate))
                            datePopover = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
            }
            Spacer(minLength: 0)
        }
    }

    private func baseLabel(_ snapshots: [ReportSnapshot]) -> String {
        switch history.base {
        case .last:
            if multisite { return "Dernier rapport de chaque site" }
            return snapshots.first.map { "Dernier rapport · \($0.reportDate)" } ?? "Dernier rapport (aucun)"
        case .report(let id):
            return snapshots.first { $0.id == id }.map { "Rapport du \($0.reportDate)" } ?? "Dernier rapport"
        case .date(let day):
            return "Au plus tard le \(day)"
        }
    }

    // MARK: Écarts

    @ViewBuilder private var summary: some View {
        switch result {
        case .compared(let diff):
            VStack(alignment: .leading, spacing: 8) {
                Text("Depuis «\u{00A0}\(diff.baseTitle)\u{00A0}» du \(ReportText.longDate(diff.baseDate) ?? diff.baseDate)")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    tile("+\(diff.added.count)", diff.added.count > 1 ? "nouveaux" : "nouveau", Theme.success)
                    tile("−\(diff.removed.count)", diff.removed.count > 1 ? "disparus" : "disparu", diff.removed.isEmpty ? Theme.text : Theme.critical)
                    tile("\(diff.changedDeviceCount)", diff.changedDeviceCount > 1 ? "changés" : "changé", diff.changedDeviceCount == 0 ? Theme.text : Theme.warning)
                }
                HStack(spacing: 6) {
                    tile("\(diff.resolved.count)", diff.resolved.count > 1 ? "problèmes réglés" : "problème réglé",
                         diff.resolved.isEmpty ? Theme.text : Theme.success)
                    tile("\(diff.newIssues.count)", diff.newIssues.count > 1 ? "nouveaux problèmes" : "nouveau problème",
                         diff.newIssues.isEmpty ? Theme.text : (diff.newIssues.contains { $0.severity <= .eleve } ? Theme.critical : Theme.warning))
                }
                .help(issueHelp(diff))
            }
        case .noBase(let reason):
            Text(reason).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("Comparaison indisponible.").font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private func issueHelp(_ diff: ReportFollowUpDiff) -> String {
        var lines = diff.resolved.map { "Réglé\u{00A0}: \($0.title)" }
        lines += diff.newIssues.map { "Nouveau\u{00A0}: \($0.title)" }
        return lines.isEmpty ? "Aucun problème réglé ni nouveau." : lines.joined(separator: "\n")
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.mono(17, weight: .bold)).foregroundStyle(color)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    // MARK: Rapports passés

    @ViewBuilder private func pastReports(_ snapshots: [ReportSnapshot]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("RAPPORTS PASSÉS").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(snapshots.count)").font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
        if snapshots.isEmpty {
            Text("Aucun rapport produit pour ce site. Chaque rapport produit garde un instantané léger (appareils et problèmes) pour le suivant.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
        let shown = showAll ? snapshots : Array(snapshots.prefix(Self.collapsed))
        let baseID = result?.diff?.baseID
        ForEach(shown) { snapshot in
            row(snapshot, isBase: snapshot.id == baseID)
        }
        if snapshots.count > Self.collapsed {
            Button(showAll ? "Afficher moins" : "Afficher les \(snapshots.count) rapports") { showAll.toggle() }
                .buttonStyle(.link)
                .font(Theme.small)
                .padding(.top, 6)
        }
    }

    private func row(_ snapshot: ReportSnapshot, isBase: Bool) -> some View {
        let exists = history.fileExists(snapshot)
        return HStack(spacing: 10) {
            Text(snapshot.format.label)
                .font(Theme.mono(10, weight: .bold))
                .foregroundStyle(Self.formatColors(snapshot.format).0)
                .frame(width: 40, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Self.formatColors(snapshot.format).1))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snapshot.title).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                    if isBase { Chip(text: "base", tone: .accent) }
                }
                Text(snapshot.meta + (exists ? "" : " · fichier absent"))
                    .font(Theme.caption).foregroundStyle(exists ? Theme.textSecondary : Theme.warning).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Ouvrir") { if let error = history.open(snapshot) { model.show(error) } }
                Button("Comparer à ce rapport") { history.base = .report(snapshot.id) }
                    .disabled(multisite)
                Button("Afficher dans le Finder") { if let error = history.reveal(snapshot) { model.show(error) } }
                Divider()
                Button("Supprimer…", role: .destructive) { pendingDelete = snapshot }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Plus d’actions")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let error = history.open(snapshot) { model.show(error) } }
        .help(snapshot.fileName + " · double-clic pour ouvrir")
        .contextMenu {
            Button("Ouvrir") { if let error = history.open(snapshot) { model.show(error) } }
            Button("Comparer à ce rapport") { history.base = .report(snapshot.id) }.disabled(multisite)
            Button("Afficher dans le Finder") { if let error = history.reveal(snapshot) { model.show(error) } }
            Divider()
            Button("Supprimer…", role: .destructive) { pendingDelete = snapshot }
        }
    }

    static func formatColors(_ format: ReportFormat) -> (Color, Color) {
        switch format {
        case .pdf: return (Theme.critical, Theme.criticalSoft)
        case .html: return (Theme.accentStrong, Theme.accentSoft)
        case .csv, .json: return (Theme.success, Theme.successSoft)
        }
    }
}
