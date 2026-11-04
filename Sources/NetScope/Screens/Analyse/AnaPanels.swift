import AppKit
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

/// Mesures communes des tableaux de l'analyse (hauteur fixe dans l'écran qui défile).
enum AnaTableMetrics {
    static let headerHeight: CGFloat = 40

    static func height(rows: Int, rowHeight: CGFloat, maxRows: Int) -> CGFloat {
        headerHeight + CGFloat(min(max(rows, 1), maxRows)) * rowHeight
    }

    @MainActor
    static func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        InvModel.shared.show("\(label) copiée\u{00A0}: \(text)")
    }
}

// MARK: - Alertes

/// Une ligne du tableau des alertes : l'événement, son site et ce que l'inventaire du site sait de
/// l'appareil. Identifiant « site|événement » : deux sites ne se mélangent jamais.
struct AnaAlertRow: Identifiable {
    let event: InvEvent
    let siteKey: String
    let siteName: String
    /// Rang du site dans le choix (regroupement par site).
    let siteRank: Int
    /// Nom de la fiche (« — » si la fiche n'existe plus).
    let device: String
    let mac: String

    var id: String { siteKey + "|" + event.id.uuidString }
    var date: Date { event.date }
    var severity: InvSeverity { event.severity }
    var kind: String { event.kind.label }
    var ip: IPv4Address { event.ip }
    var title: String { event.title }
    var detail: String { event.detail }
    var key: String { event.key }
    var statusRank: Int {
        switch event.status {
        case .aTraiter: return 0
        case .accepte: return 1
        case .ignore: return 2
        }
    }
    var statusDate: Date { event.statusDate ?? .distantPast }

    var statusLabel: String {
        switch event.status {
        case .aTraiter: return "À traiter"
        case .accepte: return "Accepté"
        case .ignore: return "Ignoré"
        }
    }
}

/// Alertes et changements issus des événements de l'inventaire : tableau standard (note 8).
struct AnaAlertsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let alerts: [SiteScopedEvent]
    let period: AnaPeriod
    /// Recherche multiple de l'écran (note 26).
    let query: SearchQuery
    /// Plusieurs sites : colonne « Site » et lignes regroupées par site.
    var multiple = false
    /// Ordre des sites (regroupement).
    var siteOrder: [String] = []

    @State private var filter: AnaSeverityFilter = .toutes
    @State private var selection: Set<String> = []
    @StateObject private var table = Self.makeModel()

    // MARK: Colonnes

    static let columns: [StandardColumn] = [
        StandardColumn.site,
        StandardColumn(id: "date", title: "Date"),
        StandardColumn(id: "gravite", title: "Gravité"),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "appareil", title: "Appareil"),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "titre", title: "Titre", isRequired: true),
        StandardColumn(id: "statut", title: "Statut"),
        StandardColumn(id: "mac", title: "MAC", isDefaultVisible: false),
        StandardColumn(id: "detail", title: "Détail", isDefaultVisible: false),
        StandardColumn(id: "dateStatut", title: "Date du statut", isDefaultVisible: false),
        StandardColumn(id: "cle", title: "Clé de fiche", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<AnaAlertRow>] = [
        // Date : la plus récente d'abord au premier clic.
        "date": KeyPathComparator(\AnaAlertRow.date, order: .reverse),
        "site": KeyPathComparator(\AnaAlertRow.siteName, comparator: .localizedStandard),
        "gravite": KeyPathComparator(\AnaAlertRow.severity),
        "type": KeyPathComparator(\AnaAlertRow.kind, comparator: .localizedStandard),
        "appareil": KeyPathComparator(\AnaAlertRow.device, comparator: .localizedStandard),
        "ip": KeyPathComparator(\AnaAlertRow.ip),
        "titre": KeyPathComparator(\AnaAlertRow.title, comparator: .localizedStandard),
        "statut": KeyPathComparator(\AnaAlertRow.statusRank),
        "mac": KeyPathComparator(\AnaAlertRow.mac),
        "detail": KeyPathComparator(\AnaAlertRow.detail, comparator: .localizedStandard),
        "dateStatut": KeyPathComparator(\AnaAlertRow.statusDate, order: .reverse),
        "cle": KeyPathComparator(\AnaAlertRow.key),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<AnaAlertRow> {
        StandardTableModel(id: "analyse.alertes", columns: columns, sortKeys: sortKeys, defaultSort: "date")
    }

    /// Boutons de 28 pt dans la colonne Statut : lignes de 36 pt.
    private static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 8

    // MARK: Vue

    var body: some View {
        let matching = alerts.filter { matches($0) }
        let shown = matching.filter { filter.includes($0.event) }
        let pending = alerts.filter { $0.event.status == .aTraiter }.count
        // Plusieurs sites : alertes regroupées par site (ordre du choix), triées dans chaque site.
        let order = (multiple ? [KeyPathComparator(\AnaAlertRow.siteRank)] : []) + table.sortOrder
            + [KeyPathComparator(\AnaAlertRow.date, order: .reverse)]
        let rows = shown.map(row).sorted(using: order)

        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Alertes et changements").font(.system(size: 14, weight: .semibold))
                        Text("\(pending) à traiter · \(alerts.count) changement\(alerts.count > 1 ? "s" : "") sur \(period.label)"
                             + (multiple ? " · \(siteOrder.count) sites, regroupés par site" : ""))
                            .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer(minLength: 0)
                        StandardColumnsMenu(model: table)
                    }
                    tabs(matching)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Rectangle().fill(Theme.border).frame(height: 1)
                if rows.isEmpty {
                    Text(alerts.isEmpty ? "Aucun changement sur la période. Les alertes apparaissent après le deuxième scan."
                         : "Aucune alerte ne correspond au filtre ou à la recherche.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                } else {
                    tableView(rows)
                        .frame(height: AnaTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight,
                                                              maxRows: Self.maxVisibleRows))
                        .scrollIndicators(rows.count > Self.maxVisibleRows ? .automatic : .never, axes: .vertical)
                }
            }
        }
        .searchResults(rows.count, "alerte", "alertes")
        .standardSiteColumn(table, multiple: multiple)
    }

    private func row(_ item: SiteScopedEvent) -> AnaAlertRow {
        AnaAlertRow(event: item.event, siteKey: item.siteKey, siteName: item.siteName,
                    siteRank: siteOrder.firstIndex(of: item.siteKey) ?? 0, device: item.record?.displayName ?? "—",
                    mac: item.record?.mac?.formatted(.upperColon) ?? "")
    }

    private func matches(_ item: SiteScopedEvent) -> Bool {
        guard !query.isEmpty else { return true }
        return query.matches(InvEventSearchItem(item.event, deviceName: item.record?.displayName ?? "", mac: item.record?.mac,
                                                siteName: item.siteName))
    }

    private func tabs(_ items: [SiteScopedEvent]) -> some View {
        let alerts = items.map(\.event)
        let options: [(AnaSeverityFilter, String)] = [
            (.toutes, "Toutes (\(alerts.count))"),
            (.critiques, "Critiques (\(alerts.filter { $0.severity == .critique }.count))"),
            (.alertes, "Alertes (\(alerts.filter { $0.severity == .alerte }.count))"),
            (.info, "Info (\(alerts.filter { $0.severity == .info }.count))"),
        ]
        return InvSegmented(options: options, selection: $filter)
    }

    // MARK: Tableau

    private func tableView(_ rows: [AnaAlertRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("SITE", sortUsing: table.sort("site")) { row in
                    Text(row.siteName).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentStrong)
                        .lineLimit(1).help("Inventaire du site «\u{00A0}\(row.siteName)\u{00A0}»")
                }
                .width(min: 70, ideal: 110)
                .customizationID("site")
                .defaultVisibility(.hidden)

                TableColumn("DATE", sortUsing: table.sort("date")) { row in
                    Text(Date().timeIntervalSince(row.date) < 86_400 ? InvFormat.time(row.date) : InvFormat.day(row.date))
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        .help(InvFormat.stamp(row.date))
                }
                .width(min: 44, ideal: 74)
                .customizationID("date")

                TableColumn("GRAVITÉ", sortUsing: table.sort("gravite")) { row in
                    let colors = InvStyle.severity(row.severity)
                    Text(row.severity.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(colors.0)
                        .frame(width: 66, height: 20)
                        .background(Capsule().fill(colors.1))
                }
                .width(min: 70, ideal: 72)
                .customizationID("gravite")

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    ScanCellText(row.kind)
                }
                .width(min: 60, ideal: 100)
                .customizationID("type")

                TableColumn("APPAREIL", sortUsing: table.sort("appareil")) { row in
                    Text(row.device).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        .help(row.device)
                }
                .width(min: 70, ideal: 140)
                .customizationID("appareil")

                TableColumn("IP", sortUsing: table.sort("ip")) { row in
                    ScanCellText(row.ip.description, mono: true)
                }
                .width(min: 90, ideal: 110)
                .customizationID("ip")

                TableColumn("TITRE", sortUsing: table.sort("titre")) { row in
                    Text(row.title).font(Theme.small).fontWeight(.semibold).foregroundStyle(Theme.text).lineLimit(1)
                        .help(row.title + "\n" + row.detail)
                }
                .width(min: 120, ideal: 290)
                .customizationID("titre")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("STATUT", sortUsing: table.sort("statut")) { row in
                    statusCell(row)
                }
                .width(min: 150, ideal: 210)
                .customizationID("statut")
            }

            Group {
                TableColumn("MAC", sortUsing: table.sort("mac")) { row in
                    ScanCellText(row.mac.isEmpty ? "—" : row.mac, mono: true, dimmed: row.mac.isEmpty)
                }
                .width(min: 110, ideal: 130)
                .customizationID("mac")
                .defaultVisibility(.hidden)

                TableColumn("DÉTAIL", sortUsing: table.sort("detail")) { row in
                    ScanCellText(row.detail, secondary: true)
                        .help(row.detail)
                }
                .width(min: 100, ideal: 260)
                .customizationID("detail")
                .defaultVisibility(.hidden)

                TableColumn("DATE DU STATUT", sortUsing: table.sort("dateStatut")) { row in
                    ScanCellText(row.event.statusDate.map(InvFormat.stamp) ?? "—", mono: true,
                                 dimmed: row.event.statusDate == nil)
                }
                .width(min: 90, ideal: 120)
                .customizationID("dateStatut")
                .defaultVisibility(.hidden)

                TableColumn("CLÉ DE FICHE", sortUsing: table.sort("cle")) { row in
                    ScanCellText(row.key, mono: true, secondary: true)
                        .help(row.key)
                }
                .width(min: 100, ideal: 170)
                .customizationID("cle")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if !chosen.isEmpty { menu(chosen) }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { open(row) }
        }
    }

    @ViewBuilder
    private func statusCell(_ row: AnaAlertRow) -> some View {
        HStack(spacing: 6) {
            if row.event.status == .aTraiter {
                Button("Accepter") { set(.accepte, [row]) }.anaSmallButton()
                Button("Ignorer") { set(.ignore, [row]) }.anaSmallButton()
            } else {
                Text(row.statusLabel + (row.event.statusDate.map { " · \(InvFormat.time($0))" } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Button("Annuler") { set(.aTraiter, [row]) }.anaSmallButton()
            }
            Button("Voir") { open(row) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .help("Ouvrir la fiche dans l’inventaire")
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func menu(_ rows: [AnaAlertRow]) -> some View {
        if rows.count > 1 { Text("\(rows.count) alertes sélectionnées") }
        Button("Accepter") { set(.accepte, rows) }
        Button("Ignorer") { set(.ignore, rows) }
        Button("Remettre à traiter") { set(.aTraiter, rows) }
            .disabled(rows.allSatisfy { $0.event.status == .aTraiter })
        Divider()
        if rows.count == 1, let row = rows.first {
            Button("Ouvrir la fiche dans l’inventaire") { open(row) }
            Button("Copier l’IP") { AnaTableMetrics.copy(row.ip.description, label: "IP") }
            Button("Ping continu") { state.sendToPing(row.ip.description) }
        } else {
            Button("Copier les IP") {
                AnaTableMetrics.copy(rows.map(\.ip.description).joined(separator: "\n"), label: "Liste d’IP")
            }
        }
    }

    private func open(_ row: AnaAlertRow) {
        model.selectedSite = row.siteKey
        model.selectedKey = row.key
        state.open(.inventaire)
    }

    /// Statut écrit dans l'inventaire du site de chaque alerte, et lui seul.
    private func set(_ status: InvEventStatus, _ rows: [AnaAlertRow]) {
        for row in rows { model.setEventStatus(status, for: row.event.id, site: row.siteKey) }
        model.updateBadge(state)
    }
}

/// Petit bouton de ligne (Accepter, Ignorer, Annuler, Exporter) : bouton natif de macOS, petite taille.
private extension View {
    func anaSmallButton() -> some View {
        buttonStyle(.bordered).controlSize(.small)
    }
}

// MARK: - Comparaison de deux scans

/// Onglets de la comparaison.
enum AnaDiffTab: Hashable {
    case added, removed, modified

    var label: String {
        switch self {
        case .added: return "Ajouté"
        case .removed: return "Disparu"
        case .modified: return "Modifié"
        }
    }
}

/// Une ligne de la comparaison : l'écart et sa catégorie.
struct AnaDiffLine: Identifiable {
    let kind: AnaDiffTab
    let row: InvDiffRow

    var id: String { row.id }
    var change: String { kind.label }
    var ip: IPv4Address { row.ip }
    var name: String { row.name }
    var mac: String { row.mac }
    var before: String { row.before }
    var after: String { row.after }
    var key: String { row.key }
}

/// Comparaison de deux instantanés de scan : ajoutés, disparus, modifiés (tableau standard, note 8).
struct AnaComparePanel: View {
    let snapshots: [InvSnapshot]
    /// Plusieurs sites affichés : le site des deux scans comparés.
    var siteName: String?
    let onExport: (String, String) -> Void

    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var tab: AnaDiffTab = .modified
    @StateObject private var table = Self.makeModel()

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ip", title: "IP", isRequired: true),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "mac", title: "MAC"),
        StandardColumn(id: "avant", title: "Avant"),
        StandardColumn(id: "apres", title: "Après"),
        StandardColumn(id: "changement", title: "Changement", isDefaultVisible: false),
        StandardColumn(id: "cle", title: "Clé de fiche", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<AnaDiffLine>] = [
        "ip": KeyPathComparator(\AnaDiffLine.ip),
        "nom": KeyPathComparator(\AnaDiffLine.name, comparator: .localizedStandard),
        "mac": KeyPathComparator(\AnaDiffLine.mac),
        "avant": KeyPathComparator(\AnaDiffLine.before, comparator: .localizedStandard),
        "apres": KeyPathComparator(\AnaDiffLine.after, comparator: .localizedStandard),
        "changement": KeyPathComparator(\AnaDiffLine.change, comparator: .localizedStandard),
        "cle": KeyPathComparator(\AnaDiffLine.key),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<AnaDiffLine> {
        StandardTableModel(id: "analyse.comparaison", columns: columns, sortKeys: sortKeys, defaultSort: "ip")
    }

    private static let rowHeight: CGFloat = 32
    private static let maxVisibleRows = 10

    var body: some View {
        let after = snapshots.first { $0.id == afterID } ?? snapshots.last
        let before = snapshots.first { $0.id == beforeID }
            ?? snapshots.last { snapshot in after.map { snapshot.date < $0.date } ?? false }

        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Comparer deux scans" + (siteName.map { " · " + $0 } ?? "")).font(.system(size: 14, weight: .semibold))
                        if let before, let after {
                            Text("\(Self.label(before.date)) → \(Self.label(after.date))")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        StandardColumnsMenu(model: table)
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
            Text("\(title) : \(current.map { Self.label($0.date) } ?? "—")").font(Theme.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(snapshots.count < 2)
    }

    @ViewBuilder
    private func content(_ diff: InvDiff, before: InvSnapshot, after: InvSnapshot) -> some View {
        let source: [InvDiffRow] = {
            switch tab {
            case .added: return diff.added
            case .removed: return diff.removed
            case .modified: return diff.modified
            }
        }()
        let rows = source.map { AnaDiffLine(kind: tab, row: $0) }.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tabButton(.added, number: "+\(diff.added.count)", label: "ajoutés", fg: Theme.success, bg: Theme.successSoft)
                tabButton(.removed, number: "−\(diff.removed.count)", label: "disparus", fg: Theme.critical, bg: Theme.criticalSoft)
                tabButton(.modified, number: "\(diff.modified.count)", label: "modifiés", fg: Theme.warning, bg: Theme.warningSoft)
            }
            if rows.isEmpty {
                Text("Aucun appareil dans cette catégorie.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                tableView(rows)
                    .frame(height: AnaTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight,
                                                          maxRows: Self.maxVisibleRows))
                    .scrollIndicators(rows.count > Self.maxVisibleRows ? .automatic : .never, axes: .vertical)
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
            HStack {
                Text("Base\u{00A0}: \(before.total) appareils avant → \(after.total) après (+\(diff.added.count) −\(diff.removed.count)).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Exporter l’écart CSV") {
                    onExport(csv(diff), "ecart-scans-\(InvFormat.day(after.date)).csv")
                }
                .anaSmallButton()
            }
        }
        .padding(16)
    }

    private func tableView(_ rows: [AnaDiffLine]) -> some View {
        let afterColor: Color = tab == .added ? Theme.success : (tab == .removed ? Theme.critical : Theme.warning)
        return Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("IP", sortUsing: table.sort("ip")) { line in
                Text(line.ip.description).font(Theme.mono(11.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .frame(height: 24)
            }
            .width(min: 90, ideal: 112)
            .customizationID("ip")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("NOM", sortUsing: table.sort("nom")) { line in
                Text(line.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    .help(line.name)
            }
            .width(min: 80, ideal: 170)
            .customizationID("nom")

            TableColumn("MAC", sortUsing: table.sort("mac")) { line in
                ScanCellText(line.mac, mono: true)
            }
            .width(min: 100, ideal: 130)
            .customizationID("mac")

            TableColumn("AVANT", sortUsing: table.sort("avant")) { line in
                ScanCellText(line.before, secondary: true)
                    .help(line.before)
            }
            .width(min: 80, ideal: 220)
            .customizationID("avant")

            TableColumn("APRÈS", sortUsing: table.sort("apres")) { line in
                Text(line.after).font(.system(size: 12, weight: .semibold)).foregroundStyle(afterColor).lineLimit(1)
                    .help(line.after)
            }
            .width(min: 80, ideal: 220)
            .customizationID("apres")

            TableColumn("CHANGEMENT", sortUsing: table.sort("changement")) { line in
                ScanCellText(line.change)
            }
            .width(min: 70, ideal: 90)
            .customizationID("changement")
            .defaultVisibility(.hidden)

            TableColumn("CLÉ DE FICHE", sortUsing: table.sort("cle")) { line in
                ScanCellText(line.key, mono: true, secondary: true)
                    .help(line.key)
            }
            .width(min: 100, ideal: 170)
            .customizationID("cle")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { ids in
            if let line = rows.first(where: { ids.contains($0.id) }) {
                Button("Copier l’IP") { AnaTableMetrics.copy(line.ip.description, label: "IP") }
                Button("Copier la MAC") { AnaTableMetrics.copy(line.mac, label: "MAC") }
                    .disabled(line.mac.isEmpty || line.mac == "—")
            }
        }
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
